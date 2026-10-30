import XCTest
@testable import RillCore

private actor ScanScript {
    var pages: [ScanPage]
    var calls: [String] = []
    init(_ pages: [ScanPage]) { self.pages = pages }
    func fetch(_ cursor: String) throws -> ScanPage {
        calls.append(cursor)
        guard !pages.isEmpty else { throw RedisError.message("Unexpected scan") }
        return pages.removeFirst()
    }
}

private actor ScanGate {
    private var blocked: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { blocked = $0; observers.forEach { $0.resume() }; observers = [] }
    }
    func waitUntilBlocked() async {
        if blocked != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func open() { blocked?.resume(); blocked = nil }
}

final class KeyScanSessionTests: XCTestCase {
    private func key(_ name: String) -> RedisKey { RedisKey(bytes: Data(name.utf8), kind: .string, ttl: -1) }

    func testOverflowIsBufferedAndDuplicatesNeverDropUniqueKeys() async throws {
        let script = ScanScript([ScanPage(cursor: "7", keys: [key("a"), key("a"), key("b"), key("c")]),
                                 ScanPage(cursor: "0", keys: [key("c"), key("d")])])
        let session = KeyScanSession(budget: ScanBudget(results: 2))
        let first = try await session.nextPage { try await script.fetch($0) }
        let second = try await session.nextPage { try await script.fetch($0) }
        XCTAssertEqual(first.keys.map(\.name), ["a", "b"]); XCTAssertEqual(first.reason, .budget)
        XCTAssertEqual(second.keys.map(\.name), ["c", "d"]); XCTAssertEqual(second.reason, .complete)
        let cursors = await script.calls; XCTAssertEqual(cursors, ["0", "7"])
    }
    func testEmptyPagesStopAtRequestBudgetAndResumeCursor() async throws {
        let script = ScanScript([ScanPage(cursor: "1", keys: []), ScanPage(cursor: "2", keys: []), ScanPage(cursor: "0", keys: [key("found")])])
        let session = KeyScanSession(budget: ScanBudget(requests: 2))
        let first = try await session.nextPage { try await script.fetch($0) }
        XCTAssertEqual(first.reason, .budget); XCTAssertTrue(first.keys.isEmpty); XCTAssertEqual(first.requests, 2)
        let second = try await session.nextPage { try await script.fetch($0) }
        XCTAssertEqual(second.keys.map(\.name), ["found"]); XCTAssertEqual(second.reason, .complete)
        let cursors = await script.calls; XCTAssertEqual(cursors, ["0", "1", "2"])
    }
    func testPauseKeepsInflightReplyForResumeWithoutRefetching() async throws {
        let gate = ScanGate(), rows = [key("a"), key("b")]
        let session = KeyScanSession()
        let task = Task { try await session.nextPage { _ in await gate.wait(); return ScanPage(cursor: "0", keys: rows) } }
        await gate.waitUntilBlocked(); await session.pause(); await gate.open()
        let paused = try await task.value
        XCTAssertEqual(paused.reason, .paused); XCTAssertTrue(paused.keys.isEmpty)
        let resumed = try await session.nextPage { _ in throw RedisError.message("Must use buffered reply") }
        XCTAssertEqual(resumed.keys.map(\.name), ["a", "b"]); XCTAssertEqual(resumed.reason, .complete); XCTAssertEqual(resumed.requests, 0)
    }
    func testCapacityIsExplicitAndBufferedKeysRemainAvailable() async throws {
        for budget in [ScanBudget(results: 2, maximumKeys: 3), ScanBudget(results: 2, maximumKeyBytes: 3)] {
            let session = KeyScanSession(budget: budget)
            let rows = [key("a"), key("b"), key("c"), key("d")]
            let first = try await session.nextPage { _ in ScanPage(cursor: "8", keys: rows) }
            let second = try await session.nextPage { _ in throw RedisError.message("Capacity must stop scans") }
            XCTAssertEqual(first.keys.map(\.name), ["a", "b"])
            XCTAssertEqual(second.keys.map(\.name), ["c"]); XCTAssertEqual(second.reason, .capacity)
        }
    }
    func testTimeBudgetStopsAtResponseBoundary() async throws {
        let session = KeyScanSession(budget: ScanBudget(milliseconds: 50))
        let batch = try await session.nextPage { _ in
            try await Task.sleep(nanoseconds: 100_000_000)
            return ScanPage(cursor: "1", keys: [])
        }
        XCTAssertEqual(batch.reason, .budget); XCTAssertEqual(batch.requests, 1)
    }
    func testFeatureRetryConsumesBudgetWithoutFinishingAtInitialCursor() async throws {
        let session = KeyScanSession(budget: ScanBudget(requests: 1))
        let deferred = try await session.nextPage(fetchWithinBudget: { cursor, remaining in
            XCTAssertEqual(remaining, 1)
            return ScanPage(cursor: cursor, keys: [], needsRetry: true)
        })
        XCTAssertEqual(deferred.reason, .budget); XCTAssertEqual(deferred.requests, 1)
        let rows = [key("found")]
        let next = try await session.nextPage { cursor in
            XCTAssertEqual(cursor, "0")
            return ScanPage(cursor: "0", keys: rows)
        }
        XCTAssertEqual(next.reason, .complete); XCTAssertEqual(next.keys.map(\.name), ["found"])
    }
}
