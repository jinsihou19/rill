import XCTest
@testable import RillCore

final class CommandGuideTests: XCTestCase {
    func testOfflineHelpCoversSuggestionsAndSubcommandsWithoutParsingUnfinishedQuotes() {
        for command in CommandPolicy.suggestions { XCTAssertNotNil(CommandGuide.lookup(command), command) }
        XCTAssertTrue(CommandGuide.lookup("  hget 'unfinished")?.syntax.hasPrefix("HGET key field") == true)
        XCTAssertTrue(CommandGuide.lookup("memory usage")?.syntax.contains("SAMPLES") == true)
        XCTAssertTrue(CommandGuide.lookup("XINFO GROUPS")?.note.contains("GROUPS") == true)
        XCTAssertNil(CommandGuide.lookup("unknown.module"))
        XCTAssertThrowsError(try CommandPolicy.validate(["CONFIG", "GET", "*"], readOnly: true))
    }
    func testNameCompletionPreservesArgumentBytesQuotesAndEscapes() {
        XCTAssertEqual(CommandGuide.completingName(#"  ge "a b" 'c\\d'  "#, with: "GET"), #"  GET "a b" 'c\\d'  "#)
        XCTAssertEqual(CommandGuide.completingName("GE", with: "GET"), "GET ")
        XCTAssertEqual(CommandGuide.completingName("GET 'unfinished", with: "GET"), "GET 'unfinished")
        XCTAssertEqual(CommandGuide.completingName("\"GET\" key", with: "GET"), "\"GET\" key")
    }
    func testMemoryHistoryDeduplicatesBoundsAndNeverRewritesCommandText() {
        var history = CommandHistory()
        for index in 0..<120 { history.record("GET key:\(index)") }
        XCTAssertEqual(history.commands.count, 100); XCTAssertEqual(history.commands.first, "GET key:20")
        history.record("GET key:20"); XCTAssertEqual(history.commands.last, "GET key:20"); XCTAssertEqual(history.commands.count, 100)
        let quoted = #"SET "key space" "value\\bytes""#
        history.record(quoted); XCTAssertEqual(history.matching("KEY SPACE"), [quoted])
        history.record(String(repeating: "s", count: 20_000)); XCTAssertEqual(history.commands.last, quoted)
    }
    func testSavedSearchKeepsLiteralBinaryHexAndScopeFields() throws {
        let value = SavedKeySearch(mode: .hex, text: "00 FF 3A", kind: "string")
        XCTAssertEqual(try JSONDecoder().decode(SavedKeySearch.self, from: JSONEncoder().encode(value)), value)
        XCTAssertTrue(value.label.contains("00 FF 3A"))
    }
}
