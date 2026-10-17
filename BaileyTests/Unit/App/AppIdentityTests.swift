import Foundation
import XCTest
@testable import Bailey

final class AppIdentityTests: XCTestCase {
    func testNeonLicenseIsIncludedInApplicationResources() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "LICENSE-neon", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("BSD 3-Clause License"))
        XCTAssertTrue(text.contains("Copyright (c) 2022, Chime"))
    }

    func testSingleApplicationIdentity() {
        XCTAssertEqual(AppIdentity.bundleIdentifier, "chiimagnus.bailey")
        XCTAssertEqual(AppIdentity.displayName, "Bailey")
        XCTAssertEqual(Bundle.main.bundleIdentifier, AppIdentity.bundleIdentifier)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "Bailey")
        XCTAssertTrue(BaileyInstanceMode.isIsolated)
    }

    func testStableStorageLocations() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(
            AppIdentity.configDirectory,
            home.appendingPathComponent(".config/bailey", isDirectory: true)
        )
        XCTAssertEqual(AppIdentity.historyDirectory.lastPathComponent, "bailey")
    }
}
