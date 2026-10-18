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

    func testFinderDocumentRegistrationRemainsAnAlternateHandler() throws {
        let declarations = try XCTUnwrap(Bundle.main.object(
            forInfoDictionaryKey: "CFBundleDocumentTypes"
        ) as? [[String: Any]])
        XCTAssertEqual(declarations.count, 3, "Text, image, and folder each have a distinct role")
        var types = Set<String>()
        for entry in declarations {
            XCTAssertEqual(entry["LSHandlerRank"] as? String, "Alternate",
                           "Bailey must not change default applications")
            XCTAssertNotNil(entry["CFBundleTypeRole"] as? String)
            XCTAssertNil(entry["CFBundleTypeOSTypes"])
            XCTAssertNil(entry["CFBundleTypeExtensions"])
            let utis = try XCTUnwrap(entry["LSItemContentTypes"] as? [String])
            XCTAssertFalse(utis.isEmpty)
            types.formUnion(utis)
        }
        XCTAssertTrue(types.contains("public.text"))
        XCTAssertTrue(types.contains("public.image"))
        XCTAssertTrue(types.contains("public.folder"))
        XCTAssertFalse(types.contains("public.data"),
                       "A broad data handler is not an implicit binary editor")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String,
                       AppIdentity.bundleIdentifier)
        let services = try XCTUnwrap(Bundle.main.object(
            forInfoDictionaryKey: "NSServices"
        ) as? [[String: Any]])
        XCTAssertEqual(services.count, 1)
        XCTAssertEqual(services[0]["NSMessage"] as? String, "openInBailey")
    }

    @MainActor
    func testSystemDocumentBatchUsesAllAppleEventFileURLs() {
        let first = URL(fileURLWithPath: "/tmp/bailey one.swift")
        let second = URL(fileURLWithPath: "/tmp/中文 B.md")
        let third = URL(fileURLWithPath: "/tmp/dir", isDirectory: true)
        let fileList = NSAppleEventDescriptor.list()
        fileList.insert(NSAppleEventDescriptor(fileURL: first), at: 1)
        fileList.insert(NSAppleEventDescriptor(fileURL: second), at: 2)
        fileList.insert(NSAppleEventDescriptor(fileURL: third), at: 3)
        XCTAssertEqual(
            BaileyApplicationDelegate.documentURLs(from: fileList),
            [first, second, third],
            "One kAEOpenDocuments event must preserve every file and its original order"
        )
        XCTAssertEqual(
            BaileyApplicationDelegate.documentURLs(from: nil),
            []
        )
        XCTAssertEqual(
            BaileyApplicationDelegate.documentURLs(
                from: NSAppleEventDescriptor.list()
            ),
            []
        )
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
