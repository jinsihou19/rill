import XCTest
@testable import RillCore

final class CommandPolicyTests: XCTestCase {
    func testEveryDocumentedBlockedCommandProducesAPolicyErrorInBothModes() throws {
        let commands = """
        AUTH SELECT HELLO QUIT RESET CLIENT MULTI EXEC DISCARD WATCH UNWATCH
        SUBSCRIBE PSUBSCRIBE SSUBSCRIBE UNSUBSCRIBE PUNSUBSCRIBE SUNSUBSCRIBE MONITOR
        BLPOP BRPOP BRPOPLPUSH BLMOVE BLMPOP BZPOPMIN BZPOPMAX BZMPOP XREAD XREADGROUP
        FLUSHDB FLUSHALL SHUTDOWN DEBUG CONFIG ACL MODULE REPLICAOF SLAVEOF
        MIGRATE RESTORE SAVE BGSAVE BGREWRITEAOF REPLCONF SYNC PSYNC FAILOVER
        CLUSTER SENTINEL SCRIPT FUNCTION SWAPDB KEYS EVAL EVALSHA EVAL_RO EVALSHA_RO FCALL FCALL_RO
        """.split(whereSeparator: \.isWhitespace).map(String.init)
        for command in commands {
            for readOnly in [true, false] {
                XCTAssertThrowsError(try CommandPolicy.validate([command.lowercased()], readOnly: readOnly)) { error in
                    XCTAssertEqual(error as? RedisError, .commandPolicy("工作台不执行 \(command)。请使用应用的连接/数据库控件，或在专用运维终端执行此类命令。"))
                }
            }
        }
    }

    func testDiagnosticAndReadOnlyRestrictionsProducePolicyErrors() throws {
        for command in ["MEMORY PURGE", "MEMORY HELP", "MEMORY", "SLOWLOG RESET", "SLOWLOG"] {
            for readOnly in [true, false] {
                XCTAssertThrowsError(try CommandPolicy.validate(CommandLine.parse(command), readOnly: readOnly)) { error in
                    guard case .commandPolicy = error as? RedisError else { return XCTFail("Missing policy error: \(command)") }
                }
            }
        }
        for command in ["SET key value", "JSON.GET key", "FUTURE.READ key"] {
            let args = try CommandLine.parse(command)
            XCTAssertThrowsError(try CommandPolicy.validate(args, readOnly: true)) { error in
                XCTAssertEqual(error as? RedisError, .commandPolicy("当前连接为只读，不能执行写入或无法确认安全的命令。"))
            }
            XCTAssertNoThrow(try CommandPolicy.validate(args, readOnly: false))
        }
        for command in ["GET key", "MEMORY USAGE key", "MEMORY STATS", "MEMORY DOCTOR", "MEMORY MALLOC-STATS", "SLOWLOG GET 20", "SLOWLOG LEN", "SLOWLOG HELP"] {
            XCTAssertNoThrow(try CommandPolicy.validate(CommandLine.parse(command), readOnly: true))
        }
        XCTAssertThrowsError(try CommandPolicy.validate([], readOnly: false)) { error in
            XCTAssertEqual(error as? RedisError, .message("请输入 Redis 命令。"))
        }
    }
}
