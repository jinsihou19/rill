import Foundation
import CryptoKit

public extension Duration {
    var rillMilliseconds: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}

public struct ConsoleExecution: Sendable {
    public let value: RESPValue
    public let preparationMilliseconds: Double
    public let commandMilliseconds: Double
    public let reusedConnection: Bool
}

public actor ConsoleSession {
    private let idleSeconds: Double
    private var database: RedisDatabase?
    private var credentialHash: SHA256.Digest?
    private var connectionID: UUID?
    private var revision = 0
    private var executing = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var idleTask: Task<Void, Never>?
    private var connectingTask: Task<RedisDatabase, Error>?
    var queuedCount: Int { waiting.count }

    public init(idleSeconds: Double = 300) { self.idleSeconds = max(0.01, idleSeconds) }

    public func execute(_ args: [String], profile: ConnectionProfile, password: String) async throws -> ConsoleExecution {
        try CommandPolicy.validate(args, readOnly: profile.readOnly)
        let requestedRevision = revision
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        guard requestedRevision == revision else { throw CancellationError() }
        idleTask?.cancel()
        let start = ContinuousClock.now
        let (db, reused) = try await prepare(profile, password: password, revision: requestedRevision)
        try Task.checkCancellation()
        let prepared = ContinuousClock.now
        do {
            let value = try await db.wire.execute(args)
            return ConsoleExecution(value: value, preparationMilliseconds: start.duration(to: prepared).rillMilliseconds,
                                    commandMilliseconds: prepared.duration(to: .now).rillMilliseconds, reusedConnection: reused)
        } catch {
            if case .server = error as? RedisError { throw error }
            discard(connectionID)
            if !CommandPolicy.isRead(args) {
                throw RedisError.message(error.localizedDescription + "\n写入结果可能未知，请刷新核对。此命令未自动重试。")
            }
            throw error
        }
    }

    public func close() {
        revision += 1; idleTask?.cancel(); idleTask = nil; connectingTask?.cancel()
        discard(connectionID)
    }

    private func acquire() async {
        if !executing { executing = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    private func release() {
        if !waiting.isEmpty { waiting.removeFirst().resume(); return }
        executing = false
        idleTask?.cancel()
        let id = connectionID, seconds = idleSeconds
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            await self?.expire(id)
        }
    }
    private func prepare(_ profile: ConnectionProfile, password: String, revision requested: Int) async throws -> (RedisDatabase, Bool) {
        let hash = SHA256.hash(data: Data(password.utf8))
        if let existing = database, existing.profile == profile, credentialHash == hash {
            let open = await existing.wire.isOpen()
            guard revision == requested else { throw CancellationError() }
            if open { return (existing, true) }
        }
        discard(connectionID)
        let task = Task { try await RedisDatabase.connect(profile, password: password) }
        connectingTask = task
        defer { connectingTask = nil }
        let created = try await task.value
        guard revision == requested else { created.close(); throw CancellationError() }
        let id = UUID(); database = created; credentialHash = hash; connectionID = id
        created.wire.onDisconnect { [weak self] _ in Task { await self?.discard(id) } }
        return (created, false)
    }
    private func discard(_ id: UUID?) {
        guard id == connectionID else { return }
        let old = database
        database = nil; credentialHash = nil; connectionID = nil
        old?.close()
    }
    private func expire(_ id: UUID?) { if !executing { discard(id) } }
    deinit { idleTask?.cancel(); connectingTask?.cancel(); database?.close() }
}
