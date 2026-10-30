import Foundation

public struct SlowlogReport: Sendable {
    public let queries: [SlowQuery]
    public var length: Int64?
    public var thresholdMicroseconds: Int64?
    public var maximumLength: Int64?
    public var settingsError: String?
    public let fetchedAt = Date()
    public var thresholdLabel: String {
        guard let thresholdMicroseconds else { return "记录阈值未知" }
        if thresholdMicroseconds < 0 { return "服务端已关闭慢查询记录" }
        if thresholdMicroseconds == 0 { return "服务端记录所有命令" }
        return String(format: "记录阈值 %.3f ms", Double(thresholdMicroseconds) / 1000)
    }
}

public struct TrendPoint: Identifiable, Sendable {
    public let id = UUID()
    public let date: Date
    public let memoryBytes: Int64?
    public let operationsPerSecond: Double?
    public let reset: Bool
    public let segment: Int
}
public struct InfoTrend: Sendable {
    public private(set) var points: [TrendPoint] = []
    private var segment = 0
    private var previous: (time: Double, commands: Int64?, uptime: Int64?, run: String?)?
    public init() {}
    public mutating func append(_ info: [String: String], monotonicSeconds: Double, date: Date = Date()) {
        let commands = info["total_commands_processed"].flatMap(Int64.init), uptime = info["uptime_in_seconds"].flatMap(Int64.init)
        var rate: Double?, reset = false
        if let old = previous {
            reset = (old.run != nil && info["run_id"] != nil && old.run != info["run_id"]) ||
                (old.uptime != nil && uptime != nil && uptime! < old.uptime!) ||
                (old.commands != nil && commands != nil && commands! < old.commands!)
            if !reset, let now = commands, let before = old.commands, monotonicSeconds > old.time {
                rate = (Double(now) - Double(before)) / (monotonicSeconds - old.time)
            }
        }
        if rate == nil, !points.isEmpty { segment += 1 }
        let memory = info["used_memory"].flatMap(Int64.init).flatMap { $0 >= 0 ? $0 : nil }
        points.append(TrendPoint(date: date, memoryBytes: memory, operationsPerSecond: rate, reset: reset, segment: segment))
        if points.count > 60 { points.removeFirst(points.count - 60) }
        previous = (monotonicSeconds, commands, uptime, info["run_id"])
    }
}

public struct MemoryAnalysisReport: Sendable {
    public let startedAt = Date()
    public var updatedAt = Date()
    public var scanRequests = 0
    public var inspected = 0
    public var available = 0
    public var unavailable = 0
    public var largerKeys: [RedisKey] = []
    public var completeScan = false
    public var state = "正在读取"
    public init() {}
}
public enum MemoryAnalysis {
    public static func run(
        fetch: @Sendable (String) async throws -> ScanPage,
        metadata: @Sendable ([Data]) async throws -> [RedisKey],
        update: @Sendable (MemoryAnalysisReport) async -> Void = { _ in },
        maximumRequests: Int = 8, maximumKeys: Int = 1000, milliseconds: Int = 5000
    ) async throws -> MemoryAnalysisReport {
        let maximumKeys = max(1, min(1000, maximumKeys)), maximumRequests = max(1, min(8, maximumRequests))
        let session = KeyScanSession(budget: ScanBudget(results: 64, requests: 1, maximumKeys: maximumKeys, maximumKeyBytes: 1024 * 1024))
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(max(1, min(5000, milliseconds))))
        var report = MemoryAnalysisReport()
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { report.state = "时间预算已用完"; break }
            guard report.inspected < maximumKeys else { report.state = "达到键数量上限"; break }
            guard report.scanRequests < maximumRequests else { report.state = "SCAN 请求预算已用完"; break }
            let batch = try await session.nextPage(fetch: fetch)
            report.scanRequests += batch.requests
            try Task.checkCancellation()
            let keys = Array(batch.keys.prefix(maximumKeys - report.inspected))
            if !keys.isEmpty {
                let rows = try await metadata(keys.map(\.bytes))
                report.inspected += keys.count
                let measured = rows.filter { $0.memory != nil && $0.memory! >= 0 }
                report.available += measured.count; report.unavailable += keys.count - measured.count
                report.largerKeys = Array((report.largerKeys + measured).sorted { $0.memory! > $1.memory! }.prefix(20))
            }
            report.updatedAt = Date(); await update(report)
            if batch.reason == .complete { report.completeScan = true; report.state = "本轮扫描完成"; break }
            if batch.reason == .capacity { report.state = "达到键名容量上限"; break }
        }
        report.updatedAt = Date(); await update(report)
        return report
    }
}
