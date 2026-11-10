import AppKit
import Foundation
import Observation
import SwiftUI
import Synchronization
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
        XCTAssertEqual(Bundle.main.bundleURL.lastPathComponent, AppIdentity.displayName + ".app",
                       "App bundle filename must match its macOS-visible identity")
        XCTAssertTrue(BaileyInstanceMode.isIsolated)
    }

    @MainActor
    func testWindowChromePreservesNativeWindowArrangement() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.isMovable = true
        let chrome = WindowChromeAccessor.Coordinator(
            onAttach: { _ in }, hasUnsavedEdits: { false }, saveBeforeClose: { true }
        )
        chrome.attach(window)
        XCTAssertTrue(window.isMovable,
                      "Window menu arrangement requires a movable native window")

        for event in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification,
                      NSWindow.didResignMainNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.post(name: event, object: window)
            XCTAssertTrue(window.isMovable,
                          "Window chrome must not disable macOS window management on \(event.rawValue)")
        }
    }

    @MainActor
    func testWindowCommandsStayInNativeWindowMenu() throws {
        let menu = try XCTUnwrap(NSApp.windowsMenu)
        let newWindow = menu.items.filter {
            $0.title == String(localized: "New Window", table: "Interface")
        }
        XCTAssertEqual(newWindow.count, 1)
        XCTAssertEqual(newWindow.first?.keyEquivalent, "n")
        XCTAssertEqual(newWindow.first?.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(menu.items.filter {
            $0.title == String(localized: "Enter Full Screen", table: "Interface")
                || $0.title == String(localized: "Exit Full Screen", table: "Interface")
        }.count, 1)
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
    func testPanelItemsDoNotReconfigureUnrelatedEditShortcut() throws {
        let main = try XCTUnwrap(NSApp.mainMenu)
        let panel = try XCTUnwrap(main.items.first {
            $0.title == String(localized: "Panel", table: "Interface")
        }?.submenu)
        let edit = try XCTUnwrap(main.items.compactMap(\.submenu).first { menu in
            menu.items.contains { $0.action == #selector(TreeKeyboardView.copy(_:)) }
                && menu.items.contains { $0.action == #selector(TreeKeyboardView.paste(_:)) }
        })
        let delete = try XCTUnwrap(edit.items.first {
            $0.action == #selector(TreeKeyboardView.delete(_:))
        })
        let originalKey = delete.keyEquivalent
        let originalMask = delete.keyEquivalentModifierMask
        defer {
            delete.keyEquivalent = originalKey
            delete.keyEquivalentModifierMask = originalMask
        }
        delete.keyEquivalentModifierMask = .command
        XCTAssertEqual(delete.keyEquivalentModifierMask, .command)

        let unrelated = NSMenuItem(title: "Panel Probe", action: nil, keyEquivalent: "")
        panel.addItem(unrelated)
        defer { panel.removeItem(unrelated) }
        XCTAssertEqual(delete.keyEquivalentModifierMask, .command,
                       "Adding a Panel row must not reconfigure the unrelated Edit menu")

        let editChange = NSMenuItem(title: "Edit Probe", action: #selector(TreeKeyboardView.copy(_:)),
                                    keyEquivalent: "")
        edit.addItem(editChange)
        defer { edit.removeItem(editChange) }
        XCTAssertEqual(delete.keyEquivalent, originalKey,
                       "Edit changes must still restore the native Delete shortcut")
        XCTAssertTrue(delete.keyEquivalentModifierMask.isEmpty)
    }

    @MainActor
    func testSystemMenuTrackingPinsPresentationUntilEndNotification() throws {
        let appDelegate = try XCTUnwrap(NSApp.servicesProvider as? BaileyApplicationDelegate)
        let mainMenu = try XCTUnwrap(NSApp.mainMenu)
        let presentation = appDelegate.menuPresentation
        XCTAssertNil(presentation.tracked)

        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: mainMenu)
        XCTAssertNotNil(presentation.tracked)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        XCTAssertNotNil(presentation.tracked,
                        "Unrelated popup tracking must not release the system menu snapshot")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: mainMenu)
        XCTAssertNil(presentation.tracked)
    }

    @MainActor
    func testNativeMenuPresentationInvalidatesOnlyAfterTrackingEnds() {
        let presentation = MainMenuPresentation()
        let changes = Mutex<Int>(0)
        withObservationTracking {
            _ = presentation.panelEntries(for: nil)
            _ = presentation.projectEntries(for: [])
        } onChange: {
            changes.withLock { $0 += 1 }
        }

        presentation.beginTracking(project: nil, projects: [])
        XCTAssertNotNil(presentation.tracked)
        XCTAssertEqual(changes.withLock { $0 }, 0,
                       "Opening a system menu must not invalidate SwiftUI Commands")

        presentation.endTracking()
        XCTAssertNil(presentation.tracked)
        XCTAssertEqual(changes.withLock { $0 }, 1,
                       "Refresh menu entries only after AppKit stops tracking")
    }

    @MainActor
    func testSystemPanelMenuDoesNotReceiveContextShortcutFormatting() throws {
        let panel = try XCTUnwrap(NSApp.mainMenu?.items.first {
            $0.title == String(localized: "Panel", table: "Interface")
        }?.submenu)
        let item = NSMenuItem(title: "Example\t⌃1", action: nil, keyEquivalent: "")
        panel.addItem(item)
        defer { panel.removeItem(item) }
        XCTAssertNil(item.attributedTitle,
                     "The app's context-menu formatter must never rewrite a system Panel entry")
    }

    @MainActor
    func testSwiftUIMenuShortcutBadgesAreDisplayOnly() throws {
        let menu = NSHostingMenu(rootView: VStack {
            Button("Cut", action: {}).badge("⌘X")
            Button("Copy", action: {}).badge("⌘C")
            Button("Paste", action: {}).badge("⌘V").disabled(true)
            Button("Move to Trash", role: .destructive, action: {}).badge("⌫")
            Button("Close", action: {}).badge("⌘W")
            Button("Close Tabs to the Right", action: {})
        })
        menu.update()
        let expectations = [
            ("Cut", "⌘X"), ("Copy", "⌘C"), ("Paste", "⌘V"),
            ("Move to Trash", "⌫"), ("Close", "⌘W")
        ]
        for (index, expected) in expectations.enumerated() {
            let item = menu.items[index]
            XCTAssertEqual(item.title, expected.0)
            XCTAssertEqual(item.badge?.stringValue, expected.1)
            XCTAssertTrue(item.keyEquivalent.isEmpty,
                          "The system main menu must remain the only keyboard shortcut owner")
            XCTAssertNil(item.attributedTitle)
            XCTAssertTrue(item.accessibilityLabel()?.contains(expected.0) == true)
        }
        XCTAssertFalse(menu.items[2].isEnabled)
        XCTAssertEqual(menu.items.last?.title, "Close Tabs to the Right")
        XCTAssertNil(menu.items.last?.badge)
        XCTAssertLessThan(menu.size.width, 290, "Native badges should not reserve a fixed column")
    }

    @MainActor
    func testLegacyTabFormattedMenuTitlesAreNotRewritten() throws {
        let menu = NSHostingMenu(rootView: Button(action: {}) {
            Text(verbatim: "Legacy\t⌘C")
        })
        menu.update()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        defer {
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        }
        XCTAssertNil(menu.items.first?.attributedTitle,
                     "Context shortcut display must no longer mutate native menu titles")
    }

    @MainActor
    func testNativeMenuBadgeOmittedWhenShortcutIsUnavailable() throws {
        let menu = NSHostingMenu(rootView: VStack {
            Button("Commit Staged", action: {}).badge(nil as String?)
            Button("Commit Staged", action: {}).badge("⌘↩")
            Button("新建文件夹…", action: {}).badge("⌥⌘N")
        })
        menu.update()
        XCTAssertNil(menu.items[0].badge)
        XCTAssertEqual(menu.items[1].badge?.stringValue, "⌘↩")
        XCTAssertEqual(menu.items[2].badge?.stringValue, "⌥⌘N")
        XCTAssertEqual(menu.items[2].title, "新建文件夹…")
        XCTAssertTrue(menu.items.allSatisfy(\.keyEquivalent.isEmpty))
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
