import XCTest
@testable import RillCore

final class RESPStreamDecoderTests: XCTestCase {
    func testEveryFragmentBoundaryAndPipelineMatchesReferenceDecoder() throws {
        let frames = [Data("+OK\r\n:-9223372036854775808\r\n$-1\r\n*-1\r\n*0\r\n".utf8),
                      RESPCodec.encode([Data(), Data([0, 255, 13, 10]), Data("中文".utf8)]),
                      Data("*3\r\n*2\r\n:1\r\n$0\r\n\r\n*0\r\n-ERR no\r\n".utf8)]
        let source = frames.reduce(Data(), +)
        var remaining = source, expected: [RESPValue] = []
        while let result = try RESPCodec.decode(remaining) { expected.append(result.value); remaining.removeFirst(result.consumed) }
        for chunk in 1...source.count {
            var decoder = RESPStreamDecoder(), values: [RESPValue] = []
            for offset in stride(from: 0, to: source.count, by: chunk) {
                try decoder.append(source.subdata(in: offset..<min(offset + chunk, source.count)))
                while let value = try decoder.next() { values.append(value) }
            }
            XCTAssertEqual(values, expected, "chunk=\(chunk)"); XCTAssertNil(try decoder.next())
        }
    }
    func testDeterministicRandomFragmentationAndCompaction() throws {
        var seed: UInt64 = 7
        func random(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int(seed >> 32) % n }
        var decoder = RESPStreamDecoder(), expected: [RESPValue] = [], actual: [RESPValue] = []
        var source = Data()
        for _ in 0..<500 {
            let arguments = (0..<random(8)).map { _ in Data((0..<random(200)).map { _ in UInt8(random(256)) }) }
            let frame = RESPCodec.encode(arguments); source.append(frame); expected.append(.array(arguments.map { .bulk($0) }))
        }
        var offset = 0
        while offset < source.count {
            let end = min(offset + 1 + random(1000), source.count)
            try decoder.append(source.subdata(in: offset..<end)); offset = end
            while let value = try decoder.next() { actual.append(value) }
        }
        XCTAssertEqual(actual, expected)
    }
    func testMalformedAndOversizedFramesAreRejected() throws {
        let invalid = [":oops\r\n", "$-2\r\n", "$999999999999999999999999\r\n", "$2\r\naa!!", "*100001\r\n", "%0\r\n", String(repeating: "*1\r\n", count: 64) + ":0\r\n", "$33554432\r\n"]
        for text in invalid {
            var decoder = RESPStreamDecoder(); try decoder.append(Data(text.utf8))
            XCTAssertThrowsError(try decoder.next(), text)
        }
        var decoder = RESPStreamDecoder()
        XCTAssertThrowsError(try decoder.append(Data(repeating: 65, count: RESPCodec.maximumBytes + 1)))
    }
    func testHexGoldenOutputAndHighlightRanges() {
        let bytes = Data([0, 1, 15, 16, 32, 65, 126, 127, 255])
        XCTAssertEqual(DataPresentation.hex(bytes), "00000000  " + "00 01 0F 10 20 41 7E 7F FF".padding(toLength: 48, withPad: " ", startingAt: 0) + "  .... A~..")
        XCTAssertEqual(DataPresentation.hex(Data()), "")
        let source = #"{"中文":12,"str":"a:true","bool":false}"#
        let spans = JSONHighlight.spans(source)
        XCTAssertEqual(spans.filter { $0.kind == .key }.count, 3)
        XCTAssertEqual(spans.filter { $0.kind == .literal }.count, 1)
        for span in spans { XCTAssertLessThanOrEqual(NSMaxRange(span.range), source.utf16.count) }
        XCTAssertTrue(JSONHighlight.spans(String(repeating: "a", count: 200_000)).isEmpty)
    }
}
