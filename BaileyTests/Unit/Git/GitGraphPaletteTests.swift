import AppKit
import XCTest
@testable import Bailey

@MainActor
final class GitGraphPaletteTests: XCTestCase {
    func testGraphPaletteKeepsTwelveLaneColors() {
        let expected: [(CGFloat, CGFloat, CGFloat)] = [
            (0, 133, 217), (217, 0, 143), (0, 217, 10), (217, 133, 0),
            (163, 0, 217), (255, 0, 0), (0, 217, 204), (225, 56, 232),
            (133, 217, 0), (220, 91, 35), (111, 36, 214), (255, 204, 0),
        ]
        XCTAssertEqual(GitGraphPalette.colors.count, expected.count)
        for (index, rgb) in expected.enumerated() {
            let actual = GitGraphPalette.colors[index]
            XCTAssertEqual(actual.redComponent, rgb.0 / 255, accuracy: 0.001)
            XCTAssertEqual(actual.greenComponent, rgb.1 / 255, accuracy: 0.001)
            XCTAssertEqual(actual.blueComponent, rgb.2 / 255, accuracy: 0.001)
        }
    }

    func testColoredBadgeIconsRemainReadableOverEveryGraphLaneColor() {
        func luminance(_ color: NSColor) -> CGFloat {
            let rgb = color.usingColorSpace(.sRGB)!
            func linear(_ channel: CGFloat) -> CGFloat {
                channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.redComponent)
                + 0.7152 * linear(rgb.greenComponent)
                + 0.0722 * linear(rgb.blueComponent)
        }
        XCTAssertEqual(GitGraphPalette.iconInks.count, GitGraphPalette.colors.count)
        for (index, fill) in GitGraphPalette.colors.enumerated() {
            let ink = GitGraphPalette.iconInks[index]
            let lighter = max(luminance(fill), luminance(ink))
            let darker = min(luminance(fill), luminance(ink))
            XCTAssertGreaterThanOrEqual((lighter + 0.05) / (darker + 0.05), 4.5,
                                        "Graph lane \(index) badge icon contrast")
        }
    }

    func testGraphBadgesUseCompactSharedMetrics() {
        XCTAssertEqual(RecentCommitsView.badgeHeight, 16)
        XCTAssertEqual(RecentCommitsView.badgeIconSize, 16)
        XCTAssertEqual(RecentCommitsView.badgeFontSize, 9)
        XCTAssertEqual(RecentCommitsView.badgeHorizontalPadding, 4)
    }
}
