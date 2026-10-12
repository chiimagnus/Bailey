import Foundation
import XCTest
@testable import kero

final class AppIdentityTests: XCTestCase {
    func testStorageAndBundleIdentity() throws {
        let stable = AppIdentity(bundleIdentifier: "chiimagnus.kero")
        let development = AppIdentity(bundleIdentifier: "chiimagnus.kero.dev")
        XCTAssertEqual(stable.displayName, "Kero")
        XCTAssertEqual(development.displayName, "Kero Dev")
        XCTAssertNotEqual(stable.configDirectory, development.configDirectory)
        XCTAssertNotEqual(stable.historyDirectory, development.historyDirectory)
        XCTAssertEqual(stable.isolatedDefaultsSuite, "chiimagnus.kero.isolated-ui-test")
        XCTAssertEqual(development.isolatedDefaultsSuite, "chiimagnus.kero.dev.isolated-ui-test")
        XCTAssertTrue(KeroInstanceMode.isRunningTests && KeroInstanceMode.isIsolated)
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, development.bundleIdentifier)
        XCTAssertEqual(info["CFBundleName"] as? String, development.displayName)
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, development.displayName)
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "kero")
        XCTAssertEqual(info["LSMinimumSystemVersion"] as? String, "15.6")
    }
}
