import XCTest
@testable import RillCore

private actor MemberFixture {
    var calls = 0
    var pages: [KeyPage]
    init(_ pages: [KeyPage]) { self.pages = pages }
    func fetch(_ cursor: String, _ offset: Int) -> KeyPage { defer { calls += 1 }; return pages[min(calls, pages.count - 1)] }
}
final class MemberReadSessionTests: XCTestCase {
    private func page(_ rows: [Int], more: Bool = false) -> KeyPage {
        var page = KeyPage(key: RedisKey(bytes: Data("key".utf8), kind: .hash), count: 1000)
        page.rows = rows.map { ValueRow(field: Data(String($0).utf8), value: Data([0, 255])) }
        page.cursor = more ? "42" : "0"; page.hasMore = more
        return page
    }
    func testOverfullRepliesDeduplicateBufferAndResumeWithoutLoss() async throws {
        let fixture = MemberFixture([page([0, 0, 1, 2, 3, 4])]), session = MemberReadSession(budget: ScanBudget(results: 2))
        var rows: [ValueRow] = []
        for _ in 0..<3 { rows += try await session.next { await fixture.fetch($0, $1) }.rows }
        XCTAssertEqual(rows.map(\.fieldText), ["0", "1", "2", "3", "4"])
        let calls = await fixture.calls; XCTAssertEqual(calls, 1)
    }
    func testEmptyPagesHaveRequestBudgetAndCapacityIsExplicit() async throws {
        let fixture = MemberFixture([page([], more: true)]), session = MemberReadSession(budget: ScanBudget(requests: 3))
        let result = try await session.next { await fixture.fetch($0, $1) }
        XCTAssertEqual(result.readState, .budget); XCTAssertTrue(result.hasMore)
        let calls = await fixture.calls; XCTAssertEqual(calls, 3)
        let capacity = MemberReadSession(budget: ScanBudget(maximumKeys: 2)), many = page([0, 1, 2, 3])
        let limited = try await capacity.next { _, _ in many }
        XCTAssertEqual(limited.rows.count, 2); XCTAssertEqual(limited.readState, .capacity); XCTAssertFalse(limited.hasMore)
    }
    func testPauseRetainsInFlightResponseAndDoesNotFetchAgainOnResume() async throws {
        let fixture = MemberFixture([page([1, 2])]), session = MemberReadSession()
        let task = Task { try await session.next { cursor, offset in
            await session.pause()
            return await fixture.fetch(cursor, offset)
        } }
        let paused = try await task.value
        XCTAssertEqual(paused.readState, .paused); XCTAssertTrue(paused.rows.isEmpty)
        let resumed = try await session.next { await fixture.fetch($0, $1) }
        XCTAssertEqual(resumed.rows.count, 2); XCTAssertEqual(resumed.readState, .complete)
        let calls = await fixture.calls; XCTAssertEqual(calls, 1)
    }
    func testQueryValidation() throws {
        var query = MemberQuery()
        for id in ["0", "123-0", "(123-0", "18446744073709551615-0"] { query.streamStart = id; XCTAssertNoThrow(try query.validate()) }
        for id in ["", "+", "1--2", "1.2", "-1", "1-", "18446744073709551616-0", "中文"] { query.streamStart = id; XCTAssertThrowsError(try query.validate()) }
    }
}
