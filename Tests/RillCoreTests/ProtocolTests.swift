import XCTest
@testable import RillCore

final class ProtocolTests: XCTestCase {
    func testBinaryRoundTripAndByteLengths() throws {
        let arguments = [Data("SET".utf8), Data("中文🔑".utf8), Data([0, 255, 13, 10, 42])]
        let encoded = RESPCodec.encode(arguments)
        let decoded = try XCTUnwrap(RESPCodec.decode(encoded))
        XCTAssertEqual(decoded.value.elements, arguments.map { .bulk($0) })
        XCTAssertEqual(decoded.consumed, encoded.count)
    }
    func testEverySplitRequiresCompleteFrame() throws {
        let encoded = Data("*3\r\n$3\r\nfoo\r\n*2\r\n:42\r\n$-1\r\n-ERR failure\r\n".utf8)
        for length in 0..<encoded.count { XCTAssertNil(try RESPCodec.decode(Data(encoded.prefix(length))), "split \(length)") }
        XCTAssertEqual(try RESPCodec.decode(encoded)?.value, .array([.bulk(Data("foo".utf8)), .array([.integer(42), .bulk(nil)]), .error("ERR failure")]))
    }
    func testPipelineKeepsUnconsumedBytes() throws {
        let data = Data("+OK\r\n:9\r\n".utf8)
        let first = try XCTUnwrap(RESPCodec.decode(data))
        XCTAssertEqual(first.value, .simple("OK"))
        XCTAssertEqual(try RESPCodec.decode(Data(data.dropFirst(first.consumed)))?.value, .integer(9))
    }
    func testInvalidAndOversizedFrames() {
        for input in [":no\r\n", "$-2\r\n", "$33554433\r\n", "$1\r\naXX", "?a\r\n", "*100001\r\n"] {
            XCTAssertThrowsError(try RESPCodec.decode(Data(input.utf8)), input)
        }
        let deep = String(repeating: "*1\r\n", count: 65) + "+OK\r\n"
        XCTAssertThrowsError(try RESPCodec.decode(Data(deep.utf8)))
    }
    func testNullEmptyAndServerError() throws {
        XCTAssertEqual(try RESPCodec.decode(Data("$0\r\n\r\n".utf8))?.value, .bulk(Data()))
        XCTAssertEqual(try RESPCodec.decode(Data("*-1\r\n".utf8))?.value, .array(nil))
        XCTAssertEqual(try RESPCodec.decode(Data("*0\r\n".utf8))?.value, .array([]))
        XCTAssertThrowsError(try RESPValue.error("WRONGTYPE").checked())
    }
    func testCommandQuotingAndEmptyArguments() throws {
        XCTAssertEqual(try CommandLine.parse(#"SET 'hello world' "你好\nRedis""#), ["SET", "hello world", "你好\nRedis"])
        XCTAssertEqual(try CommandLine.parse(#"SET key """#), ["SET", "key", ""])
        XCTAssertEqual(try CommandLine.parse(#"GET a\ b"#), ["GET", "a b"])
        XCTAssertThrowsError(try CommandLine.parse("SET a 'unfinished"))
        XCTAssertThrowsError(try CommandLine.parse("GET a\\"))
    }
    func testReadOnlyPolicyUsesAllowlistAndBlocksSessionChanges() throws {
        for command in ["GET a", "HGET a b", "SCAN 0", "SLOWLOG GET 20", "MEMORY USAGE a", "XINFO STREAM a"] {
            XCTAssertNoThrow(try CommandPolicy.validate(CommandLine.parse(command), readOnly: true))
        }
        for command in ["SET a b", "EVAL 'return 1' 0", "FUTURE.READ a", "SLOWLOG RESET", "MEMORY PURGE"] {
            XCTAssertThrowsError(try CommandPolicy.validate(CommandLine.parse(command), readOnly: true))
        }
        for command in ["SELECT 1", "AUTH secret", "FLUSHALL", "CONFIG GET *", "MULTI", "MONITOR", "KEYS *", "XREAD BLOCK 0 STREAMS x $", "CLIENT TRACKING ON", "EVAL 'return 1' 0", "FCALL myfunction 0", "SLOWLOG RESET", "MEMORY PURGE"] {
            XCTAssertThrowsError(try CommandPolicy.validate(CommandLine.parse(command), readOnly: false))
        }
    }
    func testProfileValidationAndNoCredentialSerialization() throws {
        XCTAssertNoThrow(try ConnectionProfile().validate())
        var profile = ConnectionProfile(); profile.host = "redis://localhost"
        XCTAssertThrowsError(try profile.validate())
        profile.host = "localhost"; profile.port = 65536
        XCTAssertThrowsError(try profile.validate())
        let encoded = try JSONEncoder().encode(profile)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("password"))
    }
    func testInfoAndStreamValidation() throws {
        XCTAssertEqual(RedisDatabase.parseInfo("# Stats\r\nhits:100\r\nendpoint:host:6379\r\n"), ["hits": "100", "endpoint": "host:6379"])
        XCTAssertEqual(try RedisDatabase.streamFields(Data(#"{"event":"created","id":"7"}"#.utf8)).count, 4)
        XCTAssertThrowsError(try RedisDatabase.streamFields(Data(#"{"id":7}"#.utf8)))
        XCTAssertThrowsError(try RedisDatabase.streamFields(Data("{}".utf8)))
    }
}
