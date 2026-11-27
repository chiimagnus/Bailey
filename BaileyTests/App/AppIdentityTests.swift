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
        XCTAssertEqual(declarations.count, 4, "Text, image, media, and folder each have a distinct role")
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
            if utis.contains("public.audio") || utis.contains("public.movie") {
                XCTAssertEqual(entry["CFBundleTypeRole"] as? String, "Viewer")
            }
            types.formUnion(utis)
        }
        XCTAssertTrue(types.contains("public.text"))
        XCTAssertTrue(types.contains("public.image"))
        XCTAssertTrue(types.contains("public.audio"))
        XCTAssertTrue(types.contains("public.movie"))
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
    func testMenuEntryConstructionDoesNotObserveDynamicTitles() {
        let terminal = TerminalSession(launchCommand: "exec /bin/sh -i")
        defer { terminal.terminate() }
        let tab = PaneTab(content: .session(terminal))
        let project = Project(fallbackName: "Original", workspaceConfiguration: .standard)
        project.append(tab)
        let changes = Mutex<Int>(0)

        withObservationTracking {
            XCTAssertEqual(PanelMenuEntry.entries(for: project).map(\.id), [.tab(tab.id)])
            XCTAssertEqual(ProjectMenuEntry.entries(for: [project]).map(\.id), [project.id])
        } onChange: {
            changes.withLock { $0 += 1 }
        }

        terminal.terminalDidChangeTitle("Updated Terminal Title")
        XCTAssertEqual(PanelMenuEntry.entries(for: project).first?.title, "Updated Terminal Title")
        project.customDirectory = "/tmp/updated-project"
        XCTAssertEqual(ProjectMenuEntry.entries(for: [project]).first?.title, "updated-project")
        XCTAssertEqual(changes.withLock { $0 }, 0,
                       "Dynamic names must not invalidate the entire SwiftUI Commands hierarchy")
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
        let all = try XCTUnwrap(NSApp.mainMenu).items.compactMap(\.submenu).flatMap(\.items)
        for (title, key) in [("Zoom In", "+"), ("Zoom Out", "-"), ("Reset Zoom", "0")] {
            let name = String(localized: String.LocalizationValue(title), table: "Interface")
            let item = try XCTUnwrap(menu.items.first { $0.title == name })
            XCTAssertEqual(item.keyEquivalent, key)
            XCTAssertEqual(item.keyEquivalentModifierMask, .command)
            XCTAssertEqual(all.filter { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == .command }.count, 1)
        }
        XCTAssertEqual(menu.items.filter {
            $0.title == String(localized: "Enter Full Screen", table: "Interface")
                || $0.title == String(localized: "Exit Full Screen", table: "Interface")
        }.count, 1)
    }

    @MainActor
    func testNativeWindowMenuPresentsEveryProjectAndKeepsWindowActions() throws {
        let delegate = try XCTUnwrap(NSApp.servicesProvider as? BaileyApplicationDelegate)
        let application = delegate.workspace
        let menu = try XCTUnwrap(NSApp.windowsMenu)
        let savedSnapshots = SessionStore.load()
        let savedHistories = TerminalHistoryStore.load()
        let first = application.makeWindow()
        let second = application.makeWindow()
        func project(_ name: String) -> Project {
            Project(fallbackName: name, workspaceConfiguration: .standard)
        }
        let alpha = project("Alpha 🌷")
        let duplicate = project("Alpha 🌷")
        let bravo = project("Bravo 中文")
        first.projects = [alpha, duplicate, bravo]
        first.selectedProjectID = duplicate.id
        let charlie = project("Charlie")
        second.projects = [charlie]
        second.selectedProjectID = charlie.id
        func window(_ owner: WorkspaceWindowModel, title: String) -> NSWindow {
            let window = NSWindow(contentRect: .init(x: -800, y: -800, width: 360, height: 240),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = title
            owner.attach(to: window)
            window.orderBack(nil)
            NSApp.addWindowsItem(window, title: title, filename: false)
            return window
        }
        let a = window(first, title: "Window menu test A")
        let b = window(second, title: "Window menu test B")
        defer {
            NSApp.removeWindowsItem(a)
            NSApp.removeWindowsItem(b)
            a.close(); b.close()
            first.windowClosed(); second.windowClosed()
            SessionStore.save(savedSnapshots)
            TerminalHistoryStore.save(savedHistories)
        }
        let font = try XCTUnwrap(NSFont(name: "AppleColorEmoji", size: 15))
        let glyph = try XCTUnwrap(first.windowMenuEmoji)
        let scalar = try XCTUnwrap(glyph.unicodeScalars.first)
        XCTAssertEqual(glyph.unicodeScalars.count, 1)
        XCTAssertTrue(scalar.properties.isEmojiPresentation)
        XCTAssertTrue(font.coveredCharacterSet.contains(scalar))
        XCTAssertEqual(first.windowMenuEmoji, glyph)
        let rowA = try XCTUnwrap(menu.items.first { ($0.target as? NSWindow) === a })
        let rowB = try XCTUnwrap(menu.items.first { ($0.target as? NSWindow) === b })
        let actionA = rowA.action
        let actionB = rowB.action
        let originalImageA = rowA.image
        let originalImageB = rowB.image
        let count = menu.items.count
        func inspect(_ current: WorkspaceWindowModel, row: NSMenuItem, colorRange: NSRange,
                     inactiveOffset: Int? = nil) throws {
            let title = try XCTUnwrap(row.attributedTitle)
            let expected = current.projects.map(\.name).joined(separator: " · ")
            XCTAssertEqual(title.string, expected)
            var actualRange = NSRange()
            let accent = title.attribute(.foregroundColor, at: colorRange.location, effectiveRange: &actualRange) as? NSColor
            XCTAssertEqual(accent, .controlAccentColor)
            XCTAssertEqual(actualRange, colorRange)
            if let inactiveOffset {
                XCTAssertNotEqual(title.attribute(.foregroundColor, at: inactiveOffset, effectiveRange: nil) as? NSColor,
                                  .controlAccentColor)
            }
        }
        // Host tests do not own desktop focus. Exercise the same native menu
        // decoration with an explicit current-window identity; the UI test
        // verifies that AppKit supplies it when the actual menu is opened.
        func track(current: NSWindow?, _ body: () throws -> Void) rethrows {
            let restore = delegate.decorateWindowMenu(menu.items, currentWindow: current)
            defer { restore() }
            try body()
        }
        try track(current: a) {
            try inspect(first, row: rowA, colorRange: NSRange(location: ("Alpha 🌷 · " as NSString).length,
                                                             length: ("Alpha 🌷" as NSString).length), inactiveOffset: 0)
            try inspect(second, row: rowB, colorRange: NSRange(location: 0, length: 7))
            XCTAssertEqual(rowA.action, actionA)
            XCTAssertEqual(rowB.action, actionB)
            XCTAssertTrue(rowA.target === a)
            XCTAssertTrue(rowB.target === b)
            XCTAssertEqual(menu.items.count, count)
            XCTAssertNotNil(rowA.image)
            XCTAssertFalse(rowA.image?.isTemplate ?? true)
            XCTAssertEqual(rowA.onStateImage.size, NSSize(width: 1, height: 1))
            XCTAssertTrue(rowB.image === originalImageB)
        }
        XCTAssertTrue(rowA.image === originalImageA)
        XCTAssertTrue(rowB.image === originalImageB)
        XCTAssertEqual(rowA.title, "Window menu test A")
        XCTAssertEqual(rowB.title, "Window menu test B")
        first.selectedProjectID = bravo.id
        first.moveProject(bravo.id, to: alpha.id)
        try track(current: b) {
            try inspect(first, row: rowA, colorRange: NSRange(location: 0, length: ("Bravo 中文" as NSString).length),
                        inactiveOffset: ("Bravo 中文 · " as NSString).length)
            try inspect(second, row: rowB, colorRange: NSRange(location: 0, length: 7))
            XCTAssertTrue(rowA.image === originalImageA)
            XCTAssertNotNil(rowB.image)
            XCTAssertFalse(rowB.image?.isTemplate ?? true)
        }
        try track(current: nil) {
            XCTAssertTrue(rowA.image === originalImageA)
            XCTAssertTrue(rowB.image === originalImageB)
        }
        second.close(charlie)
        try track(current: b) {
            XCTAssertEqual(rowB.attributedTitle?.string, AppIdentity.displayName)
            XCTAssertFalse(rowB.image?.isTemplate ?? true)
        }
    }

    @MainActor
    func testFilePathShortcutsRemainUniqueWithinMainMenu() throws {
        let main = try XCTUnwrap(NSApp.mainMenu)
        let file = try XCTUnwrap(main.items.first {
            $0.title == String(localized: "File", table: "Interface")
        }?.submenu)
        let commands: [(String, String, NSEvent.ModifierFlags)] = [
            (String(localized: "Copy Path", table: "Sidebar"), "c", [.command, .option]),
            (String(localized: "Copy Relative Path", table: "Sidebar"),
             "c", [.command, .option, .shift]),
            (String(localized: "Reveal in Finder", table: "Sidebar"), "r", [.command, .option]),
        ]
        let all = main.items.compactMap(\.submenu).flatMap(\.items)
        for (title, key, flags) in commands {
            let item = try XCTUnwrap(file.items.first { $0.title == title })
            XCTAssertEqual(item.keyEquivalent, key)
            XCTAssertEqual(item.keyEquivalentModifierMask, flags)
            XCTAssertEqual(all.filter {
                $0.keyEquivalent == key && $0.keyEquivalentModifierMask == flags
            }.count, 1, "Only the File menu may register \(title)")
        }
    }

    @MainActor
    func testExcludedFilesCommandBelongsToFileMenuWithoutShortcut() throws {
        let main = try XCTUnwrap(NSApp.mainMenu)
        let file = try XCTUnwrap(main.items.first {
            $0.title == String(localized: "File", table: "Interface")
        }?.submenu)
        let panel = try XCTUnwrap(main.items.first {
            $0.title == String(localized: "Panel", table: "Interface")
        }?.submenu)
        let title = String(localized: "Show Excluded Files", table: "Sidebar")
        let show = try XCTUnwrap(file.items.first { $0.title == title })
        XCTAssertTrue(show.keyEquivalent.isEmpty,
                      "Excluded-file visibility must not have a keyboard shortcut")
        XCTAssertFalse(panel.items.contains { $0.title == title },
                       "Excluded-file visibility belongs in File, not Panel")
    }

    @MainActor
    func testPanelCloseShortcutIsNativeInBothMenus() throws {
        let main = try XCTUnwrap(NSApp.mainMenu)
        let panel = try XCTUnwrap(main.items.first {
            $0.title == String(localized: "Panel", table: "Interface")
        }?.submenu)
        let close = try XCTUnwrap(panel.items.first {
            $0.title == String(localized: "Close Panel", table: "Interface")
        })
        XCTAssertEqual(close.keyEquivalent, "w")
        XCTAssertEqual(close.keyEquivalentModifierMask, .command)

        let context = NSHostingMenu(rootView:
            Button("Close Panel", action: {}).keyboardShortcut("w", modifiers: .command)
        )
        context.update()
        let item = try XCTUnwrap(context.items.first)
        XCTAssertEqual(item.keyEquivalent, "w")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)
        XCTAssertNil(item.badge, "A native shortcut must not use a display-only badge")
    }

    @MainActor
    func testStageAllChangesShortcutRemainsInFileMenu() throws {
        let main = try XCTUnwrap(NSApp.mainMenu)
        let file = try XCTUnwrap(main.items.first {
            $0.title == String(localized: "File", table: "Interface")
        }?.submenu)
        let stageAll = try XCTUnwrap(file.items.first {
            $0.title == String(localized: "Stage All Changes", table: "Sidebar")
        })
        XCTAssertEqual(stageAll.keyEquivalent, "y")
        XCTAssertEqual(stageAll.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(main.items.compactMap(\.submenu).flatMap(\.items).filter {
            $0.keyEquivalent == "y"
                && $0.keyEquivalentModifierMask == [.command, .shift]
        }.count, 1)
        XCTAssertFalse(file.items.contains {
            $0.title == String(localized: "Stage Changes", table: "Sidebar")
        }, "Only Stage All Changes belongs to the main menu")
    }

    @MainActor
    func testMarkdownPreviewAndSaveBelongToFileWithUniqueNativeShortcuts() throws {
        let main = try XCTUnwrap(NSApp.mainMenu)
        let edit = try XCTUnwrap(main.items.compactMap(\.submenu).first { submenu in
            submenu.items.contains { $0.action == #selector(TreeKeyboardView.copy(_:)) }
                && submenu.items.contains { $0.action == #selector(TreeKeyboardView.paste(_:)) }
        })
        let file = try XCTUnwrap(main.items.first {
            $0.title == String(localized: "File", table: "Interface")
        }?.submenu)
        let save = try XCTUnwrap(file.items.first {
            $0.title == String(localized: "Save", table: "Interface")
        })
        XCTAssertEqual(save.keyEquivalent, "s")
        XCTAssertEqual(save.keyEquivalentModifierMask, .command)
        XCTAssertFalse(edit.items.contains { $0.title == save.title })

        let preview = try XCTUnwrap(file.items.first {
            $0.title == String(localized: "Show Preview", table: "Editor")
        })
        XCTAssertEqual(preview.keyEquivalent, "v")
        XCTAssertEqual(preview.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertFalse(preview.isEnabled)
        let openIndex = try XCTUnwrap(file.items.firstIndex {
            $0.title == String(localized: "Open File…", table: "Interface")
        })
        let previewIndex = try XCTUnwrap(file.items.firstIndex { $0 === preview })
        let saveIndex = try XCTUnwrap(file.items.firstIndex { $0 === save })
        XCTAssertLessThan(openIndex, previewIndex)
        XCTAssertLessThan(previewIndex, saveIndex)
        let allItems = main.items.compactMap(\.submenu).flatMap(\.items)
        for (key, modifiers) in [("s", NSEvent.ModifierFlags.command),
                                 ("v", [.command, .shift])] {
            XCTAssertEqual(allItems.filter {
                $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers
            }.count, 1, "The File menu must own one native shortcut")
        }

        let toggle = try XCTUnwrap(file.items.first {
            $0.title == String(localized: "Diff Layout", table: "Git")
        })
        XCTAssertEqual(toggle.keyEquivalent, "u")
        XCTAssertEqual(toggle.keyEquivalentModifierMask, [.command, .option])
        XCTAssertFalse(toggle.isEnabled, "Without a focused Diff the command must be disabled")
        let all = main.items.compactMap(\.submenu).flatMap(\.items)
        XCTAssertEqual(all.filter {
            $0.keyEquivalent == "u" && $0.keyEquivalentModifierMask == [.command, .option]
        }.count, 1, "Only File registers the layout toggle")
        XCTAssertFalse(all.contains {
            ["1", "2"].contains($0.keyEquivalent)
                && $0.keyEquivalentModifierMask == [.command, .option]
        }, "Remove both obsolete layout shortcuts")
        XCTAssertFalse(edit.items.contains {
            [String(localized: "Unified", table: "Git"),
             String(localized: "Split", table: "Git")].contains($0.title)
        }, "Edit must no longer contain Diff layout commands")
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
        let panel = try XCTUnwrap(mainMenu.items.first {
            $0.title == String(localized: "Panel", table: "Interface")
        }?.submenu)
        XCTAssertTrue(panel.supermenu === mainMenu)
        XCTAssertEqual(panel.title, String(localized: "Panel", table: "Interface"))
        let presentation = appDelegate.menuPresentation
        let changes = Mutex<Int>(0)
        withObservationTracking {
            _ = presentation.panelEntries(for: nil)
            _ = presentation.projectEntries(for: [])
        } onChange: {
            changes.withLock { $0 += 1 }
        }

        XCTAssertNil(presentation.tracked)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: panel)
        XCTAssertNil(presentation.tracked, "A submenu does not own native menu-bar tracking")
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: mainMenu)
        XCTAssertNotNil(presentation.tracked)
        XCTAssertEqual(changes.withLock { $0 }, 0,
                       "Opening a menu must not invalidate native Window commands")

        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        XCTAssertNotNil(presentation.tracked,
                        "Unrelated popup tracking must not release the system menu snapshot")
        XCTAssertEqual(changes.withLock { $0 }, 0)

        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: panel)
        XCTAssertNotNil(presentation.tracked)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: mainMenu)
        XCTAssertNil(presentation.tracked)
        XCTAssertEqual(changes.withLock { $0 }, 1,
                       "Refresh the snapshot only after AppKit ends menu tracking")
    }

    @MainActor
    func testSwiftUIContextMenuShortcutsRegisterNativeKeyEquivalents() throws {
        let menu = NSHostingMenu(rootView: VStack {
            Button("Cut", action: {}).keyboardShortcut("x", modifiers: .command)
            Button("Copy", action: {}).keyboardShortcut("c", modifiers: .command)
            Button("Paste", action: {}).keyboardShortcut("v", modifiers: .command).disabled(true)
            Button("Move to Trash", role: .destructive, action: {})
                .keyboardShortcut(.delete, modifiers: [])
            Button("Close", action: {}).keyboardShortcut("w", modifiers: .command)
                .modifierKeyAlternate(.option) {
                    Button("Close Others", action: {})
                }
            Button("Stage All Changes", action: {})
                .keyboardShortcut("y", modifiers: [.command, .shift])
            Button("Close All", action: {})
        })
        menu.update()
        let expected: [(String, String, NSEvent.ModifierFlags)] = [
            ("Cut", "x", .command), ("Copy", "c", .command),
            ("Paste", "v", .command), ("Close", "w", .command),
            ("Stage All Changes", "y", [.command, .shift]),
        ]
        for (title, key, flags) in expected {
            let item = try XCTUnwrap(menu.items.first { $0.title == title })
            XCTAssertEqual(item.keyEquivalent, key)
            XCTAssertEqual(item.keyEquivalentModifierMask, flags)
            XCTAssertNil(item.badge)
            XCTAssertTrue(item.accessibilityLabel()?.contains(title) == true)
        }
        let delete = try XCTUnwrap(menu.items.first { $0.title == "Move to Trash" })
        XCTAssertFalse(delete.keyEquivalent.isEmpty)
        XCTAssertTrue(delete.keyEquivalentModifierMask.isEmpty)
        XCTAssertFalse(try XCTUnwrap(menu.items.first { $0.title == "Paste" }).isEnabled)
        let closeIndex = try XCTUnwrap(menu.items.firstIndex { $0.title == "Close" })
        let alternate = try XCTUnwrap(menu.items.first { $0.title == "Close Others" })
        XCTAssertTrue(alternate.isAlternate)
        XCTAssertTrue(alternate.keyEquivalentModifierMask.contains(.option))
        XCTAssertTrue(menu.items[closeIndex + 1] === alternate)
        XCTAssertEqual(menu.items.last?.title, "Close All")
        XCTAssertTrue(try XCTUnwrap(menu.items.last).keyEquivalent.isEmpty)
    }

    @MainActor
    func testNativeContextShortcutCanBeConditionalAndLocalized() throws {
        let menu = NSHostingMenu(rootView: VStack {
            Button("Commit Staged", action: {}).keyboardShortcut(nil as KeyboardShortcut?)
            Button("Commit Staged", action: {}).keyboardShortcut(.return, modifiers: .command)
            Button("新建文件夹…", action: {})
                .keyboardShortcut("n", modifiers: [.command, .option])
        })
        menu.update()
        XCTAssertTrue(menu.items[0].keyEquivalent.isEmpty)
        XCTAssertFalse(menu.items[1].keyEquivalent.isEmpty)
        XCTAssertEqual(menu.items[1].keyEquivalentModifierMask, .command)
        XCTAssertEqual(menu.items[2].keyEquivalent, "n")
        XCTAssertEqual(menu.items[2].keyEquivalentModifierMask, [.command, .option])
        XCTAssertEqual(menu.items[2].title, "新建文件夹…")
        XCTAssertTrue(menu.items.allSatisfy { $0.badge == nil })
    }

    @MainActor
    func testPathShortcutKeyEquivalentsIdentifyTheirContextMenu() throws {
        let menu = NSHostingMenu(rootView: VStack {
            Button("Other locale", action: {}).keyboardShortcut(PathMenuShortcut.copyAbsolute)
            Button("Close", action: {}).keyboardShortcut("w", modifiers: .command)
        })
        menu.update()
        XCTAssertTrue(PathMenuShortcut.hasPathActions(menu))
        XCTAssertEqual(menu.items[0].keyEquivalent, "c")
        XCTAssertEqual(menu.items[0].keyEquivalentModifierMask, [.command, .option])

        for shortcut in [PathMenuShortcut.copyRelative, PathMenuShortcut.reveal] {
            let other = NSHostingMenu(rootView:
                Button("Other locale", action: {}).keyboardShortcut(shortcut)
            )
            other.update()
            XCTAssertTrue(PathMenuShortcut.hasPathActions(other))
        }
        let plain = NSHostingMenu(rootView:
            Button("Close", action: {}).keyboardShortcut("w", modifiers: .command)
        )
        plain.update()
        XCTAssertFalse(PathMenuShortcut.hasPathActions(plain))
        let mainFile = try XCTUnwrap(NSApp.mainMenu?.items.first {
            $0.title == String(localized: "File", table: "Interface")
        }?.submenu)
        XCTAssertFalse(PathMenuShortcut.hasPathActions(mainFile),
                       "A system File submenu must not be mistaken for a context popup")
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
