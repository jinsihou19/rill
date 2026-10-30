import Foundation
import Network
@testable import RillCore

final class ScriptedRedisServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "rill.tests.scripted-server")
    private var connections: [NWConnection] = []
    private var received: [[Data]] = []
    private let respond: @Sendable ([Data]) -> Data
    var port: Int { Int(listener.port!.rawValue) }

    init(respond: @escaping @Sendable ([Data]) -> Data) throws {
        self.respond = respond
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.listener.stateUpdateHandler = nil; ready.resume()
                case .failed(let error): self?.listener.stateUpdateHandler = nil; ready.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.connections.append(connection); connection.start(queue: self.queue)
                self.receive(connection, buffered: Data())
            }
            listener.start(queue: queue)
        }
    }
    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffered
            if let data { buffer.append(data) }
            do {
                var replies = Data()
                while let frame = try RESPCodec.decode(buffer) {
                    guard let items = frame.value.elements else { connection.cancel(); return }
                    let args = items.compactMap(\.data)
                    self.received.append(args); replies.append(self.respond(args))
                    buffer.removeFirst(frame.consumed)
                }
                if !replies.isEmpty { connection.send(content: replies, completion: .contentProcessed { _ in }) }
            } catch { connection.cancel(); return }
            if done || error != nil { connection.cancel() }
            else { self.receive(connection, buffered: buffer) }
        }
    }
    func commands() -> [[String]] { queue.sync { received.map { $0.map { String(decoding: $0, as: UTF8.self) } } } }
    func stop() { queue.sync { listener.cancel(); connections.forEach { $0.cancel() }; connections.removeAll() } }
}
