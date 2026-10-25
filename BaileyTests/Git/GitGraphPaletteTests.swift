import AppKit
import SwiftUI
import XCTest
@testable import Bailey

@MainActor
final class GitGraphPaletteTests: XCTestCase {
    private func luminance(_ color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.sRGB)!
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent)
            + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }

    private func contrast(_ first: NSColor, _ second: NSColor) -> CGFloat {
        let a = luminance(first)
        let b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    func testGraphPaletteFollowsGhosttyANSIColors() {
        for (dark, name) in [(true, "Catppuccin Macchiato"), (true, "Dracula"),
                             (false, "Ayu Light")] {
            let theme = Theme.definition(named: name)!
            let palette = GitGraphPalette(theme: theme)
            XCTAssertEqual(palette.colors.count, 12)
            let actual = palette.colors[0].usingColorSpace(.sRGB)!
            let expected = theme.paletteNSColor(4)!.usingColorSpace(.sRGB)!
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.005, name)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.005, name)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.005, name)
            XCTAssertEqual(dark, theme.isDark)
        }
        let first = GitGraphPalette(theme: Theme.definition(named: "Dracula")!)
        let second = GitGraphPalette(theme: Theme.definition(named: "Catppuccin Macchiato")!)
        XCTAssertNotEqual(first.colors[0], second.colors[0])
    }

    func testGraphTracksAndBadgeIconsContrastAcrossEveryTheme() {
        let themes = Theme.commonDarkThemes + Theme.commonLightThemes
        XCTAssertEqual(themes.count, 60)
        for theme in themes {
            let palette = GitGraphPalette(theme: theme)
            XCTAssertEqual(palette.colors.count, 12, theme.name)
            XCTAssertEqual(palette.iconInks.count, 12, theme.name)
            let unique = Set(palette.colors.map { color in
                let rgb = color.usingColorSpace(.sRGB)!
                return String(format: "%02x%02x%02x",
                    Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
                    Int(rgb.blueComponent * 255))
            })
            XCTAssertEqual(unique.count, 12, "\(theme.name) must distinguish all twelve lanes")
            let backdrop = theme.sidebarNSColor
            for (index, fill) in palette.colors.enumerated() {
                XCTAssertGreaterThanOrEqual(contrast(fill, backdrop), 2.49,
                    "\(theme.name) lane \(index) must be visible on sidebar")
                XCTAssertGreaterThanOrEqual(contrast(fill, palette.iconInks[index]), 4.49,
                    "\(theme.name) lane \(index) badge icon")
            }
            _ = palette.color(CommitGraphLayout.unconnectedWorktreeColor)
        }
    }

    func testSharedGitFileStatusesUseGhosttyANSIColors() {
        let statuses: [(TreeDisplayModel.Status, Int)] = [
            (.modified, 3), (.added, 2), (.untracked, 2),
            (.deleted, 1), (.renamed, 4), (.copied, 4), (.conflict, 5),
        ]
        for theme in Theme.commonDarkThemes + Theme.commonLightThemes {
            for (status, slot) in statuses {
                let actual = NSColor(status.color(theme: theme)).usingColorSpace(.sRGB)!
                let expected = theme.paletteNSColor(slot)!.usingColorSpace(.sRGB)!
                XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.005, theme.name)
                XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.005, theme.name)
                XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.005, theme.name)
            }
        }
    }

    func testCanvasRailsRepaintWhenThemeChangesWithoutRemount() throws {
        let oldLight = Theme.terminal(dark: false).name
        let oldDark = Theme.terminal(dark: true).name
        defer { Theme.reloadSelection(light: oldLight, dark: oldDark) }

        for (dark, first, second) in [
            (true, "Catppuccin Macchiato", "Dracula"),
            (false, "Rose Pine Dawn", "Ayu Light"),
        ] {
            Theme.reloadSelection(light: dark ? "Default Light" : first,
                                  dark: dark ? first : "Default Dark")
            let rail = CommitGraphLayout.Rail(lane: 0, color: 0)
            let host = NSHostingView(rootView: CommitGraphRails(
                bottomRails: [rail], fontScale: 1, laneSpacing: 9
            ).frame(width: 40, height: 80))
            let window = NSWindow(
                contentRect: NSRect(x: -900, y: -900, width: 40, height: 80),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }

            func capture() throws -> NSBitmapImageRep {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                return bitmap
            }
            let before = try capture()
            Theme.reloadSelection(light: dark ? "Default Light" : second,
                                  dark: dark ? second : "Default Dark")
            var changed = 0
            let repainted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let after = try? capture() else { return false }
                let scale = CGFloat(after.pixelsWide) / host.bounds.width
                changed = 0
                for y in Int(5 * scale)..<Int(75 * scale) {
                    for x in Int(2 * scale)..<Int(17 * scale) {
                        guard let a = before.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                              let b = after.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                        else { continue }
                        if max(abs(a.redComponent - b.redComponent),
                               abs(a.greenComponent - b.greenComponent),
                               abs(a.blueComponent - b.blueComponent)) > 0.08 { changed += 1 }
                    }
                }
                return changed > 15
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [repainted], timeout: 3), .completed,
                "\(first) → \(second) graph rail pixels unchanged: \(changed)")
        }
    }

    func testGraphBadgesUseCompactSharedMetrics() {
        XCTAssertEqual(RecentCommitsView.badgeHeight, 16)
        XCTAssertEqual(RecentCommitsView.badgeIconSize, 16)
        XCTAssertEqual(RecentCommitsView.badgeFontSize, 9)
        XCTAssertEqual(RecentCommitsView.badgeHorizontalPadding, 4)
    }
}
