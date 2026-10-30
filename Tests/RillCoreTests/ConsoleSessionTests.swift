import XCTest
@testable import RillCore

final class ConsoleSessionTests: XCTestCase {
    func testLostWriteReplyIsNeverRetriedAndNextCommandReconnects() async throws {
        let server = try ScriptedRedisServer { args in
            switch args.first.flatMap({ String(data: $0, encoding: .utf8) }) {
            case "PING": return Data("+PONG\r\n".utf8)
            case "INFO": return Data("-NOPERM INFO denied\r\n".utf8)
            case "SET": return nil
            default: return Data("-ERR unexpected\r\n".utf8)
            }
        }
        try await server.start(); defer { server.stop() }
        let session = ConsoleSession(), profile = ConnectionProfile(port: server.port)
        do { _ = try await session.execute(["SET", "key", "value"], profile: profile, password: ""); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("结果可能未知")) }
        XCTAssertEqual(server.commands().filter { $0.first == "SET" }.count, 1)
        XCTAssertEqual(server.connectionCount(), 1)
        let next = try await session.execute(["PING"], profile: profile, password: "")
        XCTAssertEqual(next.value.string, "PONG"); XCTAssertFalse(next.reusedConnection)
        XCTAssertEqual(server.connectionCount(), 2)
        await session.close()
    }
    func testCloseCancelsConnectionPreparationAndQueuedWrites() async throws {
        let pingStarted = expectation(description: "connect ping reached")
        let server = try ScriptedRedisServer { args in
            if args.first == Data("PING".utf8) { pingStarted.fulfill(); return Data() }
            return Data("+OK\r\n".utf8)
        }
        try await server.start(); defer { server.stop() }
        let session = ConsoleSession(), profile = ConnectionProfile(port: server.port)
        let first = Task { try await session.execute(["SET", "old", "one"], profile: profile, password: "") }
        await fulfillment(of: [pingStarted], timeout: 2)
        let second = Task { try await session.execute(["SET", "old", "two"], profile: profile, password: "") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await session.queuedCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        let count = await session.queuedCount; XCTAssertEqual(count, 1)
        await session.close()
        do { _ = try await first.value; XCTFail() } catch {}
        do { _ = try await second.value; XCTFail() } catch {}
        XCTAssertFalse(server.commands().contains { $0.first == "SET" })
    }
}
