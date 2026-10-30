import Foundation

public enum ScanStopReason: Sendable {
    case complete, budget, paused, capacity
}

public struct ScanBudget: Sendable {
    public let results: Int
    public let requests: Int
    public let milliseconds: Int
    public let maximumKeys: Int
    public let maximumKeyBytes: Int
    public init(results: Int = 200, requests: Int = 8, milliseconds: Int = 500,
                maximumKeys: Int = 100_000, maximumKeyBytes: Int = 16 * 1024 * 1024) {
        self.results = max(1, results); self.requests = max(1, requests); self.milliseconds = max(1, milliseconds)
        self.maximumKeys = max(1, maximumKeys); self.maximumKeyBytes = max(1, maximumKeyBytes)
    }
}

public struct ScanBatch: Sendable {
    public let keys: [RedisKey]
    public let reason: ScanStopReason
    public let requests: Int
}

public actor KeyScanSession {
    private let budget: ScanBudget
    private var cursor = "0"
    private var started = false
    private var paused = false
    private var running = false
    private var limited = false
    private var pending: ArraySlice<RedisKey> = []
    private var seen: Set<Data> = []
    private var keyBytes = 0

    public init(budget: ScanBudget = ScanBudget()) { self.budget = budget }
    public func pause() { paused = true }

    public func nextPage(fetch: @Sendable (String) async throws -> ScanPage) async throws -> ScanBatch {
        guard !running else { throw RedisError.message("当前扫描响应尚未处理完，请稍后继续。") }
        running = true; paused = false
        defer { running = false }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(budget.milliseconds))
        var requests = 0
        while pending.count < budget.results, !limited, (!started || cursor != "0"),
              !paused, requests < budget.requests, ContinuousClock.now < deadline {
            let page = try await fetch(cursor)
            requests += 1; cursor = page.cursor; started = true
            for key in page.keys where !seen.contains(key.bytes) {
                guard seen.count < budget.maximumKeys, keyBytes + key.bytes.count <= budget.maximumKeyBytes else {
                    limited = true; break
                }
                seen.insert(key.bytes); keyBytes += key.bytes.count; pending.append(key)
            }
        }
        // A pause drains the wire reply but keeps its keys and cursor for the next request.
        if paused { return ScanBatch(keys: [], reason: .paused, requests: requests) }
        let count = min(budget.results, pending.count)
        let keys = Array(pending.prefix(count)); pending = pending.dropFirst(count)
        if pending.isEmpty { pending = [] }
        let reason: ScanStopReason = !pending.isEmpty ? .budget : limited ? .capacity : started && cursor == "0" ? .complete : .budget
        return ScanBatch(keys: keys, reason: reason, requests: requests)
    }
}
