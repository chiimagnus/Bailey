import AppKit
import XCTest
@testable import kero

@MainActor
final class AppMenuIsolationTests: XCTestCase {
    func testTestHostHasNoQuitKeyboardEquivalent() throws {
        XCTAssertTrue(KeroInstanceMode.isIsolated)
        let root = try XCTUnwrap(NSApp.mainMenu)
        func items(in menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { item in
                [item] + (item.submenu.map { items(in: $0) } ?? [])
            }
        }
        let commands = items(in: root)
        XCTAssertFalse(commands.isEmpty, "The actual test host must have an app menu")
        let quitShortcuts = commands.filter {
            $0.keyEquivalent.lowercased() == "q"
                && $0.keyEquivalentModifierMask.contains(.command)
        }
        XCTAssertTrue(quitShortcuts.isEmpty,
            "The isolated XCTest host must not accept the foreground desktop's Command-Q; quitting that host ends the test run before finishing")
    }
}
