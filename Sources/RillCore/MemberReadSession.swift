import Foundation

public struct MemberQuery: Equatable, Sendable {
    public var pattern = ""
    public var newestFirst = true
    public var streamStart = "-"
    public var streamEnd = "+"
    public init() {}
    public func validate() throws {
        func valid(_ source: String, special: String) -> Bool {
            if source == special { return true }
            let id = source.hasPrefix("(") ? String(source.dropFirst()) : source
            let parts = id.split(separator: "-", omittingEmptySubsequences: false)
            return (1...2).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) && UInt64($0) != nil }
        }
        guard pattern.utf8.count <= 4096, valid(streamStart, special: "-"), valid(streamEnd, special: "+") else {
            throw RedisError.message("成员模式最多 4096 字节；Stream 范围请使用 - / +、毫秒或 毫秒-序号，可加 ( 表示排他边界。")
        }
    }
}
private extension Character { var isASCIIDigit: Bool { self >= "0" && self <= "9" } }

public actor MemberReadSession {
    private let budget: ScanBudget
    private var cursor = "0", offset = 0
    private var last: KeyPage?
    private var finished = false, limited = false, paused = false, running = false
    private var pending: ArraySlice<ValueRow> = []
    private var seen: Set<String> = []
    private var bytes = 0
    public init(budget: ScanBudget = ScanBudget(maximumKeys: 10_000)) { self.budget = budget }
    public func pause() { paused = true }
    public func next(fetch: @Sendable (String, Int) async throws -> KeyPage) async throws -> KeyPage {
        guard !running else { throw RedisError.message("上一批成员读取尚未结束。") }
        running = true; paused = false
        defer { running = false }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(budget.milliseconds))
        var requests = 0
        while !finished, !limited, !paused, pending.count < budget.results, requests < budget.requests, ContinuousClock.now < deadline {
            let page = try await fetch(cursor, offset)
            if let last, page.key.kind != last.key.kind { throw RedisError.message("分页期间数据类型已变化，请刷新。") }
            var header = page; header.rows = []
            last = header; cursor = page.cursor; offset = page.nextOffset; finished = !page.hasMore; requests += 1
            for row in page.rows where !seen.contains(row.id) {
                let size = row.field.count + row.value.count + (row.streamFields?.reduce(0) { $0 + $1.count } ?? 0)
                guard seen.count < budget.maximumKeys, bytes + size <= budget.maximumKeyBytes else { limited = true; break }
                seen.insert(row.id); bytes += size; pending.append(row)
            }
        }
        guard var page = last else { throw RedisError.message("没有可用的成员读取结果。") }
        if paused { page.rows = []; page.hasMore = true; page.readState = .paused; return page }
        page.rows = Array(pending.prefix(budget.results)); pending = pending.dropFirst(page.rows.count)
        if pending.isEmpty { pending = [] }
        let reason: ScanStopReason = !pending.isEmpty ? .budget : limited ? .capacity : finished ? .complete : .budget
        page.hasMore = reason == .budget; page.readState = reason
        return page
    }
}
