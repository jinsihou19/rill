import XCTest
import RillCore
import RillTestSupport
@testable import RillApp

@MainActor
final class BrowserStateTests: XCTestCase {
    private func withModel(_ check: (AppModel, ScriptedRedisServer) async throws -> Void) async throws {
        let server = try ScriptedRedisServer { arguments in
            switch arguments.first.flatMap({ String(data: $0, encoding: .utf8) }) {
            case "PING": return Data("+PONG\r\n".utf8)
            case "INFO": return Data("-NOPERM INFO denied\r\n".utf8)
            case "SCAN":
                let present = arguments.contains(Data("*".utf8))
                return Data((present ? "*2\r\n$1\r\n0\r\n*1\r\n$4\r\nslow\r\n" : "*2\r\n$1\r\n0\r\n*0\r\n").utf8)
            case "DBSIZE": return Data(":1\r\n".utf8)
            case "TYPE": return Data("+string\r\n".utf8)
            case "PTTL": return Data(":-1\r\n".utf8)
            case "MEMORY": return Data(":64\r\n".utf8)
            case "STRLEN": return Data(":5\r\n".utf8)
            case "GETRANGE": return Data("$5\r\nvalue\r\n".utf8)
            case "UNLINK": return nil
            default: return Data("-ERR unexpected fixture command\r\n".utf8)
            }
        }
        try await server.start()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rill-app-tests-" + UUID().uuidString)
        let suite = "rill-app-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(store: ProfileStore(directory: directory), browserPreferences: BrowserPreferencesStore(defaults: defaults))
        defer {
            model.disconnect(); server.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        model.connect(ConnectionProfile(name: "Isolated audit fixture", port: server.port))
        try await waitUntil { model.connected && !model.isLoadingKeys }
        XCTAssertEqual(model.keys.count, 1)
        try await check(model, server)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard condition() else { throw RedisError.message("Timed out waiting for the app state") }
    }

    func testNewSearchReleasesLoadingStateOfDiscardedDetail() async throws {
        try await withModel { model, _ in
            model.selectKey(model.keys.first?.id)
            XCTAssertTrue(model.isLoadingDetail)
            model.isStoppingMembers = true
            model.updateSearch("absent")
            model.loadKeys(reset: true, preserveSelection: false)
            try await waitUntil { !model.isLoadingKeys }
            XCTAssertTrue(model.keys.isEmpty)
            XCTAssertNil(model.detail)
            XCTAssertFalse(model.isLoadingDetail)
            XCTAssertFalse(model.isStoppingMembers)
            XCTAssertFalse(model.busy)
        }
    }

    func testLostMutationReplyReportsUnknownOutcomeAndDoesNotRetry() async throws {
        try await withModel { model, server in
            model.mutate("删除键") { try await $0.deleteKey(Data("slow".utf8)) }
            try await waitUntil { !model.isWriting && model.error != nil }
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertTrue(model.error?.contains("写入结果可能未知") == true)
            XCTAssertTrue(model.error?.contains("未自动重试") == true)
            XCTAssertEqual(server.commands().filter { $0.first == "UNLINK" }.count, 1)
        }
    }

    func testLocalAndServerRejectionsKeepTheirSpecificErrors() async throws {
        try await withModel { model, _ in
            for issue in [RedisError.message("TTL 必须是正整数"), .server("WRONGTYPE changed")] {
                model.mutate("保存值") { _ in throw issue }
                try await waitUntil { !model.isWriting }
                XCTAssertEqual(model.error, issue.localizedDescription)
                XCTAssertFalse(model.error?.contains("结果可能未知") == true)
            }
        }
    }

    func testUpdatePostponesForDraftAndRequiresExplicitResume() async throws {
        try await withModel { model, _ in
            model.selectKey(model.keys.first?.id)
            try await waitUntil { model.detail != nil && !model.isPreparingValue }
            model.draft = "unsaved replacement"
            XCTAssertTrue(model.dirty)
            let updater = AppUpdater(); updater.start(model: model)
            var installations = 0
            XCTAssertTrue(updater.postponeInstallationIfNeeded { installations += 1 })
            XCTAssertTrue(updater.waitingToInstall)
            updater.resumeInstallation()
            XCTAssertEqual(installations, 0)
            XCTAssertEqual(model.draft, "unsaved replacement")
            model.restoreValueDraft()
            XCTAssertEqual(installations, 0)
            updater.resumeInstallation()
            XCTAssertEqual(installations, 1)
            XCTAssertFalse(updater.waitingToInstall)
            updater.resumeInstallation()
            XCTAssertEqual(installations, 1)
        }
    }

    func testUpdatePostponesDuringWritesConsoleExportsAndOpenEditors() async throws {
        try await withModel { model, _ in
            let updater = AppUpdater(); updater.start(model: model)
            var installations = 0
            for operation in ["write", "console", "export", "editor", "confirmation"] {
                model.isWriting = operation == "write"
                model.isConsoleRunning = operation == "console"
                model.isExportingKey = operation == "export"
                model.sheet = operation == "editor" ? EditorSheet(kind: .newKey) : nil
                model.confirmation = operation == "confirmation" ? ConfirmationRequest(title: "Fixture", message: "Fixture", action: {}) : nil
                XCTAssertTrue(updater.postponeInstallationIfNeeded { installations += 1 }, operation)
                updater.resumeInstallation()
                XCTAssertEqual(installations, 0)
            }
            model.isWriting = false; model.isConsoleRunning = false; model.isExportingKey = false
            model.sheet = nil; model.confirmation = nil
            updater.resumeInstallation()
            XCTAssertEqual(installations, 1)
            XCTAssertFalse(updater.postponeInstallationIfNeeded { XCTFail("A safe immediate restart belongs to Sparkle") })
        }
    }
}
