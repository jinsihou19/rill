import Foundation
import Network

public final class RedisConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "app.rill.redis.transport")
    private let timeout: TimeInterval
    private var decoder = RESPStreamDecoder()
    private var opening: CheckedContinuation<Void, Error>?
    private var timer: DispatchWorkItem?
    private var requests: [Request] = []
    private var active: Request?
    private var replies: [RESPValue] = []
    private var closed = false
    private var ready = false
    private var disconnectHandler: (@Sendable (String) -> Void)?

    private struct Request {
        let commands: [[Data]]
        let continuation: CheckedContinuation<[RESPValue], Error>
    }

    public init(host: String, port: Int, tls: Bool = false, timeout: TimeInterval = 10) throws {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...65535).contains(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw RedisError.message("请填写有效的主机和端口（1–65535）。")
        }
        self.timeout = timeout
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort,
                                  using: tls ? .tls : .tcp)
    }

    public func open() async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    guard !self.closed, self.opening == nil, !self.ready else {
                        continuation.resume(throwing: RedisError.message("连接已关闭或已经启动。")); return
                    }
                    self.opening = continuation
                    self.armTimeout()
                    self.connection.stateUpdateHandler = { [weak self] state in
                        guard let self, !self.closed else { return }
                        switch state {
                        case .ready:
                            self.ready = true; self.timer?.cancel()
                            self.opening?.resume(); self.opening = nil
                            self.receive(); self.sendNext()
                        case .failed(let error): self.fail(error)
                        case .cancelled: self.fail(RedisError.message("连接已断开。"))
                        default: break
                        }
                    }
                    self.connection.start(queue: self.queue)
                }
            }
        }, onCancel: { self.close() })
    }

    public func execute(_ arguments: [String]) async throws -> RESPValue {
        try await execute(arguments.map { Data($0.utf8) })
    }
    public func execute(_ arguments: [Data]) async throws -> RESPValue {
        try await pipeline([arguments])[0].checked()
    }
    public func pipeline(_ commands: [[Data]]) async throws -> [RESPValue] {
        guard !commands.isEmpty, commands.allSatisfy({ !$0.isEmpty }),
              commands.reduce(0, { $0 + $1.reduce(0, { $0 + $1.count + 32 }) }) < RESPCodec.maximumBytes else {
            throw RedisError.message("命令为空或请求超过 32 MiB。")
        }
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard self.ready, !self.closed else {
                        continuation.resume(throwing: RedisError.message("连接已断开，请重新连接。")); return
                    }
                    self.requests.append(Request(commands: commands, continuation: continuation))
                    self.sendNext()
                }
            }
        }, onCancel: { self.close() })
    }

    public func close() { queue.async { self.fail(RedisError.message("连接已断开。")) } }
    public func isOpen() async -> Bool {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.ready && !self.closed) } }
    }
    public func onDisconnect(_ handler: @escaping @Sendable (String) -> Void) {
        queue.async {
            self.disconnectHandler = handler
            if self.closed { handler("连接已断开，请重新连接。") }
        }
    }

    private func sendNext() {
        guard ready, !closed, active == nil, !requests.isEmpty else { return }
        active = requests.removeFirst(); replies = []; armTimeout()
        var data = Data()
        for command in active!.commands { data.append(RESPCodec.encode(command)) }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.fail(error) }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            do {
                if let data { try self.decoder.append(data) }
                while let value = try self.decoder.next() {
                    guard let request = self.active else { throw RedisError.message("收到未请求的响应，连接已关闭。") }
                    self.replies.append(value)
                    if self.replies.count == request.commands.count {
                        self.timer?.cancel(); self.active = nil
                        let values = self.replies; self.replies = []
                        request.continuation.resume(returning: values)
                        self.sendNext()
                    }
                }
            } catch { self.fail(error); return }
            if let error { self.fail(error) }
            else if done { self.fail(RedisError.message("服务器已关闭连接。")) }
            else { self.receive() }
        }
    }

    private func armTimeout() {
        timer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.fail(RedisError.message("连接或命令超时，连接已关闭；写入结果可能未知，请刷新核对后再操作。"))
        }
        timer = item; queue.asyncAfter(deadline: .now() + timeout, execute: item)
    }

    private func fail(_ error: Error) {
        guard !closed else { return }
        closed = true; ready = false; timer?.cancel()
        opening?.resume(throwing: error); opening = nil
        active?.continuation.resume(throwing: error); active = nil
        for request in requests { request.continuation.resume(throwing: error) }
        requests.removeAll(); decoder = RESPStreamDecoder(); replies.removeAll()
        connection.stateUpdateHandler = nil; connection.cancel()
        disconnectHandler?(error.localizedDescription); disconnectHandler = nil
    }
}
