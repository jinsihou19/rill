import XCTest
@testable import RillCore

final class ValueFormatTests: XCTestCase {
    func testCodecChainsRoundTripBinaryAndEncodeInReverseOrder() throws {
        let original = Data([0, 255, 10, 13, 128]) + Data("中文".utf8)
        for codec in ValueCodec.allCases {
            let encoded = try codec.encode(original)
            XCTAssertEqual(try codec.decode(encoded), original)
        }
        let chained = try ValueCodec.base64Gzip.encode(original)
        let gzip = try XCTUnwrap(Data(base64Encoded: chained))
        XCTAssertEqual(Array(gzip.prefix(2)), [0x1f, 0x8b])
        XCTAssertEqual(try ValueCodec.gzip.decode(gzip), original)
    }
    func testCorruptOrAmbiguousEncodingsDoNotProduceEditableData() throws {
        for text in ["YQ=", "YX==", "YQ==$", "YQ==garbage"] { XCTAssertThrowsError(try ValueCodec.base64.decode(Data(text.utf8))) }
        XCTAssertEqual(try ValueCodec.base64.decode(Data("YQ==\r\n".utf8)), Data("a".utf8))
        var gzip = try ValueCodec.gzip.encode(Data("value".utf8))
        gzip[gzip.count - 8] ^= 1
        XCTAssertThrowsError(try ValueCodec.gzip.decode(gzip))
        XCTAssertThrowsError(try ValueCodec.gzip.decode(Data(gzip.dropLast(3))))
        let valid = try ValueCodec.gzip.encode(Data("value".utf8))
        XCTAssertThrowsError(try ValueCodec.gzip.decode(valid + valid))
        var limits = DecodeLimits(); limits.maximumBytes = 100
        XCTAssertThrowsError(try ValueCodec.gzip.decode(ValueCodec.gzip.encode(Data(repeating: 65, count: 500)), limits: limits))
        limits = DecodeLimits(); limits.maximumExpansionRatio = 2
        XCTAssertThrowsError(try ValueCodec.gzip.decode(ValueCodec.gzip.encode(Data(repeating: 65, count: 500)), limits: limits))
    }
    func testJSONFormattingPreservesNumbersEscapesOrderAndDuplicateKeys() throws {
        let source = Data(#"{"z":9007199254740993123456789,"a":1.2300e+9999,"a":"\u4e2d\n\ud83d\udd11","empty":[],"bool":true}"#.utf8)
        let formatted = try JSONText.formatted(source)
        let text = String(decoding: formatted, as: UTF8.self)
        XCTAssertTrue(text.contains("9007199254740993123456789")); XCTAssertTrue(text.contains("1.2300e+9999"))
        XCTAssertTrue(text.contains(#"\u4e2d\n\ud83d\udd11"#))
        XCTAssertEqual(try JSONText.formatted(formatted, pretty: false), source)
        XCTAssertNoThrow(try JSONText.validate(Data("-0.00E-4".utf8)))
    }
    func testJSONInvalidInputsAndDepthAreRejectedWithoutChangingData() {
        for input in ["", "01", "1.", "1e", "+1", "true false", "[1,]", "{x:1}", #"{"a":"\uD800"}"#, #""\uDC00""#, "[1 2]"] {
            XCTAssertThrowsError(try JSONText.validate(Data(input.utf8)), input)
        }
        XCTAssertThrowsError(try JSONText.validate(Data([34, 0xff, 34])))
        XCTAssertThrowsError(try JSONText.validate(Data((String(repeating: "[", count: 130) + "0" + String(repeating: "]", count: 130)).utf8)))
    }
    func testValueChangeSummaryUsesOriginalEncodedBytes() {
        let change = ValueChangeSummary(original: Data("abc-OLD-xyz".utf8), replacement: Data("abc-NEWER-xyz".utf8))
        XCTAssertEqual(change.firstChangedByte, 4); XCTAssertEqual(change.removedBytes, 3); XCTAssertEqual(change.insertedBytes, 5)
        let empty = ValueChangeSummary(original: Data(), replacement: Data())
        XCTAssertEqual(empty.removedBytes, 0); XCTAssertEqual(empty.insertedBytes, 0)
    }
}
