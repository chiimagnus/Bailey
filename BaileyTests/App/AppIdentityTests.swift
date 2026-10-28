import AppKit
import Foundation
import SwiftUI
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
            XCTAssertEqual(entry["LSHandlerRank"] as? String,
                           AppIdentity.isDevelopment ? "None" : "Alternate",
                           "The test app must not become a Finder file handler")
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

    func testApplicationIdentityMatchesBuildVariant() {
        let suffix = AppIdentity.isDevelopment ? ".dev" : ""
        XCTAssertEqual(AppIdentity.bundleIdentifier, "chiimagnus.bailey" + suffix)
        XCTAssertEqual(AppIdentity.displayName, AppIdentity.isDevelopment ? "Bailey Dev" : "Bailey")
        XCTAssertEqual(Bundle.main.bundleIdentifier, AppIdentity.bundleIdentifier)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                       AppIdentity.displayName)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
                       AppIdentity.displayName)
        XCTAssertTrue(BaileyInstanceMode.isIsolated)
    }

    @MainActor
    func testEditDeleteUsesNativeMenuShortcut() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let editMenu = try XCTUnwrap(menu.items.compactMap(\.submenu).first(where: { submenu in
            submenu.items.contains { $0.action == #selector(TreeKeyboardView.copy(_:)) }
                && submenu.items.contains { $0.action == #selector(TreeKeyboardView.paste(_:)) }
        }))
        let matches = editMenu.items.filter {
            $0.action == #selector(TreeKeyboardView.delete(_:))
        }
        XCTAssertEqual(matches.count, 1)
        let delete = try XCTUnwrap(matches.first)
        XCTAssertEqual(delete.keyEquivalent, String(UnicodeScalar(NSBackspaceCharacter)!))
        XCTAssertTrue(delete.keyEquivalentModifierMask.isEmpty)
    }

    @MainActor
    func testContextMenuShortcutHintsAreDisplayOnly() throws {
        let menu = NSHostingMenu(rootView: VStack {
            Button(action: {}) { Text(verbatim: "Copy\t⌘C") }
            Button(action: {}) { Text(verbatim: "Paste\t⌘V") }
            Button(action: {}) { Text(verbatim: "Close Panel\t⌘W") }
                .accessibilityLabel("Close Panel")
            Button(action: {}) { Text(verbatim: "Close\t⌘W") }
                .accessibilityLabel("Close")
            Button("Other action", action: {})
        })
        menu.update()

        let copy = try XCTUnwrap(menu.items.first)
        let paste = try XCTUnwrap(menu.items.dropFirst().first)
        XCTAssertEqual(copy.attributedTitle?.string, "Copy\t⌘C",
                       "The menu observer must format shortcuts before the popup opens")
        XCTAssertEqual(paste.attributedTitle?.string, "Paste\t⌘V")
        let closePanel = try XCTUnwrap(menu.items.dropFirst(2).first)
        let closeTab = try XCTUnwrap(menu.items.dropFirst(3).first)
        for (item, name) in [(closePanel, "Close Panel"), (closeTab, "Close")] {
            XCTAssertEqual(item.attributedTitle?.string, name + "\t⌘W")
            XCTAssertEqual(item.accessibilityLabel(), name)
            XCTAssertTrue(item.keyEquivalent.isEmpty,
                          "A context-menu shortcut hint must not register a second shortcut")
        }
        XCTAssertEqual(copy.accessibilityLabel(), "Copy")
        XCTAssertEqual(paste.accessibilityLabel(), "Paste")
        let style = try XCTUnwrap(copy.attributedTitle?
            .attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.tabStops.first?.alignment, .right)
        XCTAssertTrue(copy.keyEquivalent.isEmpty)
        XCTAssertTrue(paste.keyEquivalent.isEmpty)
        XCTAssertGreaterThanOrEqual(menu.minimumWidth, 275)
        XCTAssertNil(menu.items.last?.attributedTitle)
    }

    @MainActor
    func testTreeContextClickTracksOnlyItsMenuAndClearsOnEnd() throws {
        let view = ContextMenuClickView(frame: CGRect(x: 0, y: 0, width: 120, height: 24))
        var contextClicks = 0
        var closed = 0
        view.onContextClick = { contextClicks += 1 }
        view.onMenuClosed = { closed += 1 }
        view.isExpectedMenu = { $0.title == "Files" }

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1
        ))
        _ = view.menu(for: event)
        XCTAssertEqual(contextClicks, 1)
        let other = NSMenu(title: "Unrelated")
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: other)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: other)
        XCTAssertEqual(closed, 0, "An unrelated tracking menu must not consume the Files context")
        let menu = NSMenu(title: "Files")
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        XCTAssertEqual(closed, 0, "Unrelated menus cannot dismiss the Files context target")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        XCTAssertEqual(closed, 1)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        XCTAssertEqual(closed, 1, "A menu can only close the same context once")
        view.stopObservingMenu()
    }

    func testStableStorageLocations() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(
            AppIdentity.configDirectory,
            home.appendingPathComponent(AppIdentity.isDevelopment
                ? ".config/bailey-dev" : ".config/bailey", isDirectory: true)
        )
        XCTAssertEqual(AppIdentity.historyDirectory.lastPathComponent,
                       AppIdentity.isDevelopment ? "bailey-dev" : "bailey")
        if AppIdentity.isDevelopment {
            XCTAssertNotEqual(AppIdentity.configDirectory,
                              home.appendingPathComponent(".config/bailey"))
            XCTAssertNotEqual(AppIdentity.historyDirectory.lastPathComponent, "bailey")
        }
    }
}
