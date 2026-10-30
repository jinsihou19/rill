import XCTest
@testable import RillCore

final class RESPPreviewTests: XCTestCase {
    func testSmallPreviewsMatchExistingPresentation() {
        let values: [RESPValue] = [.simple(""), .simple("OK"), .error("ERR message"), .integer(-5), .bulk(nil), .array(nil), .array([]),
                                  .bulk(Data("中文 🔑".utf8)), .bulk(Data([0, 255, 13])), .array([.integer(1), .array([.simple("a"), .bulk(Data())])])]
        for value in values { XCTAssertEqual(value.preview(), value.pretty) }
    }
    func testLargeBinaryArraysAndUnicodeAreBoundedWithoutChangingSource() {
        let binary = Data(repeating: 255, count: 1024 * 1024), value = RESPValue.bulk(binary)
        let preview = value.preview(maximumCharacters: 128)
        XCTAssertTrue(preview.hasPrefix("0xffff")); XCTAssertTrue(preview.hasSuffix("…显示已截断")); XCTAssertLessThan(preview.count, 145)
        XCTAssertEqual(value.data, binary)
        let array = RESPValue.array((0..<100_000).map { .integer(Int64($0)) })
        XCTAssertLessThan(array.preview(maximumCharacters: 128).count, 145)
        let unicode = RESPValue.bulk(Data(String(repeating: "中文🔑", count: 1000).utf8)).preview(maximumCharacters: 17)
        XCTAssertFalse(unicode.contains("�")); XCTAssertTrue(unicode.hasSuffix("…显示已截断"))
    }
}
