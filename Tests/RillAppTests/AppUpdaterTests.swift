import AppKit
import XCTest
import Sparkle
@testable import RillApp

@MainActor
final class AppUpdaterTests: XCTestCase {
    private func controller() -> SPUStandardUpdaterController {
        _ = NSApplication.shared
        return SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func testNoUpdateAbortRetainsSuccessfulLatestVersionStatus() async {
        let controller = controller()
        let subject = AppUpdater()
        subject.updaterDidNotFindUpdate(controller.updater)
        subject.updater(controller.updater, didAbortWithError: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue)))
        XCTAssertEqual(subject.status, "当前已是最新版本。")
        XCTAssertNil(subject.availableVersion)
    }

    func testActualFailuresAndSameCodeFromAnotherDomainRemainFailures() async {
        let controller = controller()
        let subject = AppUpdater()
        for error in [NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
                      NSError(domain: "rill.tests.other", code: Int(SUError.noUpdateError.rawValue))] {
            subject.updater(controller.updater, didAbortWithError: error)
            XCTAssertTrue(subject.status.hasPrefix("检查更新失败，请稍后重试。"))
            XCTAssertTrue(subject.status.contains(error.localizedDescription))
        }
    }

    func testUserCancellingInstallationIsNotReportedAsCheckFailure() async {
        let controller = controller()
        let subject = AppUpdater()
        subject.updater(controller.updater, didAbortWithError: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue)))
        XCTAssertEqual(subject.status, "已取消安装，可稍后再试。")
    }
}
