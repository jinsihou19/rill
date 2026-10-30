import XCTest
@testable import RillCore

private actor AnalysisFixture {
    var scans = 0, batches: [Int] = []
    let count: Int
    init(_ count: Int = 200) { self.count = count }
    func scan(_ cursor: String) -> ScanPage {
        defer { scans += 1 }
        return ScanPage(cursor: "42", keys: (0..<count).map { RedisKey(bytes: Data("k:\(scans * count + $0)".utf8), kind: .unknown) })
    }
    func metadata(_ keys: [Data]) -> [RedisKey] {
        batches.append(keys.count)
        return keys.enumerated().map { RedisKey(bytes: $0.element, kind: .unknown, memory: $0.offset == 0 ? nil : Int64($0.offset), memoryError: $0.offset == 0 ? .server("NOPERM") : nil) }
    }
}
final class DiagnosticsTests: XCTestCase {
    func testTrendUsesMonotonicTimeAndResetsOnRestartRollbackAndMissingFields() throws {
        var trend = InfoTrend()
        func sample(_ commands: String, _ uptime: String = "100", _ run: String = "one") -> [String: String] {
            ["total_commands_processed": commands, "uptime_in_seconds": uptime, "run_id": run, "used_memory": "1048576"]
        }
        trend.append(sample("100"), monotonicSeconds: 10)
        trend.append(sample("120"), monotonicSeconds: 12, date: .distantPast)
        XCTAssertEqual(trend.points.last?.operationsPerSecond, 10)
        trend.append(sample("130", "1", "two"), monotonicSeconds: 14)
        XCTAssertTrue(try XCTUnwrap(trend.points.last).reset); XCTAssertNil(trend.points.last?.operationsPerSecond)
        trend.append(sample("10", "2", "two"), monotonicSeconds: 16)
        XCTAssertTrue(try XCTUnwrap(trend.points.last).reset)
        trend.append([:], monotonicSeconds: 18)
        XCTAssertNil(trend.points.last?.memoryBytes); XCTAssertNil(trend.points.last?.operationsPerSecond)
        for n in 0..<100 { trend.append(sample(String(n)), monotonicSeconds: Double(n + 20)) }
        XCTAssertEqual(trend.points.count, 60)
    }
    func testMemoryAnalysisActuallyStopsAtRequestAndKeyBudgetsAndBoundsBatches() async throws {
        let fixture = AnalysisFixture()
        let report = try await MemoryAnalysis.run(fetch: { await fixture.scan($0) }, metadata: { await fixture.metadata($0) }, maximumRequests: 2)
        let calls = await fixture.scans, batches = await fixture.batches
        XCTAssertEqual(calls, 2); XCTAssertEqual(report.scanRequests, 2)
        XCTAssertTrue(batches.allSatisfy { $0 <= 64 }); XCTAssertFalse(report.completeScan)
        XCTAssertLessThanOrEqual(report.largerKeys.count, 20); XCTAssertGreaterThan(report.unavailable, 0)
        let cap = AnalysisFixture()
        let limited = try await MemoryAnalysis.run(fetch: { await cap.scan($0) }, metadata: { await cap.metadata($0) }, maximumKeys: 150)
        XCTAssertEqual(limited.inspected, 150); XCTAssertFalse(limited.completeScan)
        let capCalls = await cap.scans; XCTAssertEqual(capCalls, 1)
    }
    func testTimeBudgetAndCancellationPreventFollowingScan() async throws {
        let fixture = AnalysisFixture(0)
        let report = try await MemoryAnalysis.run(fetch: { cursor in
            try await Task.sleep(nanoseconds: 5_000_000); return await fixture.scan(cursor)
        }, metadata: { await fixture.metadata($0) }, milliseconds: 1)
        XCTAssertTrue(report.state.contains("时间")); let calls = await fixture.scans; XCTAssertEqual(calls, 1)
        let cancelled = AnalysisFixture()
        let task = Task { try await MemoryAnalysis.run(fetch: { cursor in
            withUnsafeCurrentTask { $0?.cancel() }; return await cancelled.scan(cursor)
        }, metadata: { await cancelled.metadata($0) }) }
        do { _ = try await task.value; XCTFail() } catch is CancellationError { }
        let cancelledCalls = await cancelled.scans, cancelledBatches = await cancelled.batches
        XCTAssertEqual(cancelledCalls, 1); XCTAssertTrue(cancelledBatches.isEmpty)
    }
    func testSlowlogThresholdLabelsExplainDisabledAndAllCommands() {
        var report = SlowlogReport(queries: [])
        XCTAssertTrue(report.thresholdLabel.contains("未知"))
        report.thresholdMicroseconds = -1; XCTAssertTrue(report.thresholdLabel.contains("关闭"))
        report.thresholdMicroseconds = 0; XCTAssertTrue(report.thresholdLabel.contains("所有"))
        report.thresholdMicroseconds = 1500; XCTAssertTrue(report.thresholdLabel.contains("1.500 ms"))
    }
}
