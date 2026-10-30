import AppKit
import Foundation
import XCTest

@MainActor
final class GitGraphGeometryUITests: XCTestCase {
    func testRealDividerResizePreservesCompactBranchMenuAndWholeCommitHitArea() throws {
        try verifyDivider(widths: [420, 260, 150, 320, 150])
    }

    func testDarkGraphAtMinimumPanelFontRetainsMenusAndFullRowHitArea() throws {
        try verifyDivider(theme: "dark", fontSize: 9)
    }

    func testMaximumPanelFontWithTwelveSharedWorktreesRetainsMenusAndFullRowHitArea() throws {
        try verifyDivider(theme: "light", fontSize: 18, additionalWorktrees: 11)
    }

    func testLightLongPrimaryBranchAtMinimumPanelFontRetainsItsMenuAndCommitTitle() throws {
        try verifyDivider(theme: "light", fontSize: 9, longBranch: true)
    }

    func testDarkLongPrimaryBranchAtMaximumPanelFontRetainsItsMenuAndCommitTitle() throws {
        try verifyDivider(theme: "dark", fontSize: 18, longBranch: true, language: "zh-Hans")
    }

    private func verifyDivider(
        theme: String? = nil, fontSize: CGFloat = 14, additionalWorktrees: Int = 0,
        longBranch: Bool = false, language: String? = nil,
        widths: [CGFloat] = [420, 150]
    ) throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("hit-area.txt", text: "unchanged history\n")
        try fixture.initializeGit()
        let branchName = longBranch ? "feature/很长的分支名称-" + String(repeating: "long-", count: 12) : "main"
        if longBranch { try fixture.git(["branch", "-m", branchName]) }
        try fixture.git(["branch", "topic/overflow"])
        try fixture.git(["tag", "v-resize"])
        for _ in 0..<additionalWorktrees {
            let linked = FileManager.default.temporaryDirectory
                .appendingPathComponent("Bailey-UITest-Compact-" + UUID().uuidString)
            addTeardownBlock {
                _ = try? fixture.git(["worktree", "remove", "--force", linked.path])
                try? FileManager.default.removeItem(at: linked)
            }
            try fixture.git(["worktree", "add", "-q", "--detach", linked.path, "HEAD"])
        }
        XCTAssertEqual(String(decoding: try fixture.git(["worktree", "list", "--porcelain"]),
                              as: UTF8.self).components(separatedBy: "worktree ").count - 1,
                       additionalWorktrees + 1)
        let head = try fixture.git(["rev-parse", "HEAD"])
        let oid = String(decoding: head, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var home: URL?
        if let theme {
            let configuration = try WorkspaceUITestFixture(in: self)
            _ = try configuration.file(".config/bailey-dev/config.toml",
                text: "theme = \"\(theme)\"\npanel.font-size = \(Int(fontSize))\n")
            home = configuration.root
        }
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: language, configurationHome: home, project: fixture.root)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let window = app.windows.firstMatch
        let node = app.buttons.matching(NSPredicate(format: "value == %@", oid)).firstMatch
        let title = app.buttons.matching(NSPredicate(
            format: "label == %@", "E2E fixture history")).firstMatch
        let branch = app.buttons.matching(NSPredicate(
            format: "label IN %@", [branchName + ", Worktree", branchName + ", 工作树"])).firstMatch
        let file = window.descendants(matching: .any)
            .matching(identifier: "bailey.git.history.file")
            .matching(NSPredicate(format: "label ENDSWITH %@", ", hit-area.txt")).firstMatch
        XCTAssertTrue(node.waitForExistence(timeout: 25))
        XCTAssertTrue(title.waitForExistence(timeout: 12))
        XCTAssertTrue(branch.waitForExistence(timeout: 12))
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let scale = node.frame.width / 14
        let branchLabelWidth = (branchName as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 9 * scale, weight: .semibold)
        ]).width
        let countWidth = additionalWorktrees > 0 ? (String(additionalWorktrees + 1) as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 9 * scale, weight: .medium)
        ]).width : 0
        let maximumCompactBranchWidth = branchLabelWidth + countWidth + (16 + 8 + 12 + 4) * scale + 2
        XCTAssertEqual(scale, fontSize / 14, accuracy: 0.04,
                       "The App must actually load the isolated panel font setting")
        if let theme {
            let screenshot = try XCTUnwrap(window.screenshot().image.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: screenshot))
            let background = try XCTUnwrap(bitmap.colorAt(
                x: bitmap.pixelsWide * 2 / 5, y: bitmap.pixelsHigh * 3 / 4
            )?.usingColorSpace(.sRGB))
            let brightness = (background.redComponent + background.greenComponent
                              + background.blueComponent) / 3
            if theme == "light" {
                XCTAssertGreaterThan(brightness, 0.65)
            } else {
                XCTAssertLessThan(brightness, 0.45)
            }
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = "Git Graph \(theme) \(Int(fontSize))pt"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for requestedWidth in widths {
            let dividers = window.descendants(matching: .any)
                .matching(identifier: "bailey.dock.divider")
            guard let divider = dividers.allElementsBoundByIndex
                .filter({ $0.frame.height > $0.frame.width })
                .max(by: { $0.frame.minX < $1.frame.minX }) else {
                XCTFail("The real Dock divider must expose its resize hit target: \(window.debugDescription)")
                return
            }
            let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = origin.withOffset(CGVector(
                dx: window.frame.width - requestedWidth, dy: window.frame.height / 2))
            start.click(forDuration: 0.1, thenDragTo: end)
            let resized = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                abs(window.frame.maxX - node.frame.minX + scale + 6 - requestedWidth) < 5
            }, object: nil)
            guard XCTWaiter.wait(for: [resized], timeout: 8) == .completed else {
                XCTFail("The Dock divider did not reach \(requestedWidth)pt; divider=\(divider.frame), node=\(node.frame), window=\(window.frame)")
                return
            }
            XCTAssertLessThanOrEqual(branch.frame.width, maximumCompactBranchWidth,
                              "A short branch badge must not stretch when its panel widens")
            guard title.isHittable else {
                XCTFail("The commit title is outside its \(requestedWidth)pt panel at \(fontSize)pt; title=\(title.frame), branch=\(branch.frame), node=\(node.frame)\n\(window.debugDescription)")
                return
            }
            branch.rightClick()
            let rename = app.menuItems.matching(NSPredicate(
                format: "title IN %@", ["Rename Branch…", "重命名分支…"])).firstMatch
            let copy = app.menuItems.matching(NSPredicate(
                format: "title IN %@", ["Copy Branch Name", "复制分支名称"])).firstMatch
            XCTAssertTrue(rename.waitForExistence(timeout: 8))
            XCTAssertTrue(copy.waitForExistence(timeout: 8))
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            let rowLeft = node.frame.minX - scale
            let height = max(36, ceil(38 * scale))
            let rowTop = node.frame.midY - height / 2
            let width = window.frame.maxX - rowLeft
            for point in [
                CGPoint(x: 10 * scale, y: height / 2), CGPoint(x: 28 * scale, y: height / 2),
                CGPoint(x: min(142 * scale, width - 18), y: height * 0.79),
                CGPoint(x: width - 8, y: height * 0.34),
                CGPoint(x: 18 * scale, y: 1), CGPoint(x: 18 * scale, y: height - 1)
            ] {
                let wasExpanded = file.exists
                origin.withOffset(CGVector(
                    dx: rowLeft + point.x - window.frame.minX,
                    dy: rowTop + point.y - window.frame.minY)).click()
                let toggled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    file.exists != wasExpanded
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [toggled], timeout: 8), .completed,
                               "The commit row must toggle once at \(point), width \(requestedWidth)")
            }
        }
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
        XCTAssertEqual(try fixture.git(["show", "HEAD:hit-area.txt"]),
                       Data("unchanged history\n".utf8))
    }

    func testLightGraphPaintsTagStashDetachedAndUnreferencedWorktreeIconsLikeTheirNodes() throws {
        try verifySpecialGraphColors(theme: "light")
    }

    func testDarkGraphPaintsTagStashDetachedAndUnreferencedWorktreeIconsLikeTheirNodes() throws {
        try verifySpecialGraphColors(theme: "dark")
    }

    private func verifySpecialGraphColors(theme: String) throws {
        let clipboard = try WorkspaceUITestSupport.clipboardItems()
        addTeardownBlock { @MainActor in
            NSPasteboard.general.clearContents()
            if !clipboard.isEmpty { XCTAssertTrue(NSPasteboard.general.writeObjects(clipboard)) }
        }
        let fixture = try WorkspaceUITestFixture(in: self)
        let tracked = try fixture.file("tagged.txt", text: "tagged contents\n")
        try fixture.initializeGit()
        let taggedOID = String(decoding: try fixture.git(["rev-parse", "HEAD"]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.git(["tag", "v-glyphs"])
        _ = try fixture.file("head.txt", text: "current HEAD\n")
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-qm", "Detached head history"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        let headOID = String(decoding: head, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.git(["remote", "add", "origin", fixture.root.path])
        try fixture.git(["update-ref", "refs/remotes/origin/main", "HEAD"])
        try fixture.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        let linked = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bailey-UITest-Glyphs-" + UUID().uuidString)
        addTeardownBlock {
            _ = try? fixture.git(["worktree", "remove", "--force", linked.path])
            try? FileManager.default.removeItem(at: linked)
        }
        try fixture.git(["worktree", "add", "-q", "--detach", linked.path, "HEAD"])
        try "unreferenced checkout\n".write(to: linked.appendingPathComponent("standalone.txt"),
                                           atomically: true, encoding: .utf8)
        try fixture.git(["-C", linked.path, "add", "."])
        try fixture.git(["-C", linked.path, "commit", "-qm", "Unreferenced colored worktree"])
        let linkedOID = String(decoding: try fixture.git(["-C", linked.path, "rev-parse", "HEAD"]),
                               as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(try fixture.git(["for-each-ref", "--contains", linkedOID]).isEmpty)
        try "stashed changes\n".write(to: tracked, atomically: true, encoding: .utf8)
        try fixture.git(["stash", "push", "-m", "colored stash"])
        let stash = try fixture.git(["rev-parse", "stash@{0}"])
        let stashOID = String(decoding: stash, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.git(["checkout", "-q", "--detach", "HEAD"])
        XCTAssertThrowsError(try fixture.git(["symbolic-ref", "-q", "HEAD"]))
        let home = try WorkspaceUITestFixture(in: self)
        _ = try home.file(".config/bailey-dev/config.toml", text: "theme = \"\(theme)\"\n")
        let app = try WorkspaceUITestSupport.launch(in: self, configurationHome: home.root, project: fixture.root)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let current = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", fixture.root.lastPathComponent + " · ")).firstMatch
        let standalone = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", linked.lastPathComponent + " · ")).firstMatch
        let tag = app.buttons.matching(NSPredicate(format: "label == %@", "v-glyphs")).firstMatch
        let stashBadge = app.buttons.matching(NSPredicate(format: "label == %@", "stash@{0}")).firstMatch
        for (badge, oid, path) in [
            (tag, taggedOID, "tagged.txt"), (stashBadge, stashOID, "tagged.txt"),
            (current, headOID, "head.txt"), (standalone, linkedOID, "standalone.txt")
        ] {
            XCTAssertTrue(badge.waitForExistence(timeout: 25))
            let node = app.buttons.matching(NSPredicate(format: "value == %@", oid)).firstMatch
            XCTAssertTrue(node.waitForExistence(timeout: 15))
            let badgeColors = try coloredPixels(in: badge, leftFraction: 0.25)
            let nodeColors = try coloredPixels(in: node, leftFraction: 1)
            XCTAssertFalse(badgeColors.isEmpty)
            XCTAssertFalse(nodeColors.isEmpty)
            var nearestHue = CGFloat.infinity
            for first in badgeColors {
                for second in nodeColors {
                    let delta = abs(first.hueComponent - second.hueComponent)
                    nearestHue = min(nearestHue, min(delta, 1 - delta))
                }
            }
            XCTAssertLessThan(nearestHue, 0.08,
                              "\(badge.label) icon must match its actual DAG node in \(theme)")
            let file = app.windows.firstMatch.descendants(matching: .any)
                .matching(identifier: "bailey.git.history.file")
                .matching(NSPredicate(format: "label ENDSWITH %@", ", " + path)).firstMatch
            XCTAssertFalse(file.exists)
            node.click()
            XCTAssertTrue(file.waitForExistence(timeout: 15))
            badge.click()
            XCTAssertTrue(file.waitForNonExistence(timeout: 12))
        }
        current.rightClick()
        let copy = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Copy Commit Hash", "复制提交哈希"])).firstMatch
        let checkout = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Checkout Commit…", "检出提交…"])).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 8))
        XCTAssertFalse(checkout.exists)
        copy.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), headOID,
                       "Detached HEAD must copy its real commit hash without changing the selected checkout")
        current.rightClick()
        let worktree = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Worktree", "工作树"])).firstMatch
        XCTAssertTrue(worktree.waitForExistence(timeout: 8))
        worktree.click()
        let removal = worktree.descendants(matching: .menuItem).matching(NSPredicate(
            format: "title IN %@", ["Remove Worktree…", "移除工作树…"])).firstMatch
        XCTAssertTrue(removal.waitForExistence(timeout: 8))
        XCTAssertFalse(removal.isEnabled, "The detached main checkout must not become removable")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["rev-parse", "stash@{0}"]), stash)
        XCTAssertEqual(try fixture.git(["symbolic-ref", "refs/remotes/origin/HEAD"]),
                       Data("refs/remotes/origin/main\n".utf8))
        XCTAssertTrue(try fixture.git(["status", "--porcelain=v1"]).isEmpty)
        XCTAssertEqual(try Data(contentsOf: tracked), Data("tagged contents\n".utf8))
    }

    private func coloredPixels(in element: XCUIElement, leftFraction: CGFloat) throws -> [NSColor] {
        let data = try XCTUnwrap(element.screenshot().image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        var colors: [NSColor] = []
        for x in 0..<max(1, Int(CGFloat(bitmap.pixelsWide) * leftFraction)) {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                if channels.max()! - channels.min()! > 0.12 { colors.append(color) }
            }
        }
        return colors
    }

    func testDirtyWorktreeDiamondsAlignWithTheirOwnHeadsWithoutSelectingTheirHeaders() throws {
        try verifyUnselectedHeaders(theme: "light", mode: "tree")
    }

    func testDarkTreeHistoryAndWorktreeHeadersExpandWithoutPersistentSelectionFill() throws {
        try verifyUnselectedHeaders(theme: "dark", mode: "tree")
    }

    func testLightListHistoryAndWorktreeHeadersExpandWithoutPersistentSelectionFill() throws {
        try verifyUnselectedHeaders(theme: "light", mode: "list")
    }

    func testDarkListHistoryAndWorktreeHeadersExpandWithoutPersistentSelectionFill() throws {
        try verifyUnselectedHeaders(theme: "dark", mode: "list")
    }

    private func verifyUnselectedHeaders(theme: String, mode: String) throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let mainFile = try fixture.file("main.txt", text: "base main\n")
        _ = try fixture.file("feature.txt", text: "base feature\n")
        try fixture.initializeGit()
        let linked = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bailey-UITest-Diamonds-" + UUID().uuidString)
        addTeardownBlock {
            _ = try? fixture.git(["worktree", "remove", "--force", linked.path])
            try? FileManager.default.removeItem(at: linked)
        }
        try fixture.git(["worktree", "add", "-q", "-b", "topic/diamond", linked.path, "HEAD"])
        let featureFile = linked.appendingPathComponent("feature.txt")
        try "feature revision\n".write(to: featureFile, atomically: true, encoding: .utf8)
        try fixture.git(["-C", linked.path, "add", "."])
        try fixture.git(["-C", linked.path, "commit", "-qm", "Feature diamond HEAD"])
        try "main revision\n".write(to: mainFile, atomically: true, encoding: .utf8)
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-qm", "Main diamond HEAD"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        let feature = try fixture.git(["-C", linked.path, "rev-parse", "HEAD"])
        XCTAssertNotEqual(head, feature)
        try "dirty main\n".write(to: mainFile, atomically: true, encoding: .utf8)
        try "dirty feature\n".write(to: featureFile, atomically: true, encoding: .utf8)
        let home = try WorkspaceUITestFixture(in: self)
        _ = try home.file(".config/bailey-dev/config.toml",
                          text: "theme = \"\(theme)\"\ngit.view-mode = \"\(mode)\"\n")
        let app = try WorkspaceUITestSupport.launch(in: self, configurationHome: home.root, project: fixture.root)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let window = app.windows.firstMatch
        func headerColors(_ node: XCUIElement) throws -> [NSColor] {
            let screenshot = try XCTUnwrap(window.screenshot().image.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: screenshot))
            let factor = CGFloat(bitmap.pixelsWide) / window.frame.width
            var colors: [NSColor] = []
            for inset: CGFloat in [12, 16, 20] {
                for offset: CGFloat in [-4, 0, 4] {
                    let x = Int((window.frame.width - inset) * factor)
                    let y = Int((node.frame.midY + offset - window.frame.minY) * factor)
                    colors.append(try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)))
                }
            }
            return colors
        }
        for (checkout, oid, path) in [(fixture.root, head, "main.txt"), (linked, feature, "feature.txt")] {
            let node = app.buttons.matching(NSPredicate(format: "value == %@", checkout.path)).firstMatch
            let hash = String(decoding: oid, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let parent = app.buttons.matching(NSPredicate(format: "value == %@", hash)).firstMatch
            XCTAssertTrue(node.waitForExistence(timeout: 25))
            XCTAssertTrue(parent.waitForExistence(timeout: 15))
            XCTAssertEqual(node.frame.midX, parent.frame.midX, accuracy: 1)
            let files = window.descendants(matching: .any).matching(identifier: "bailey.tree.file")
                .matching(NSPredicate(format: "label ENDSWITH %@", ", " + path))
            let count = files.count
            node.hover()
            let collapsed = try headerColors(node)
            node.click()
            let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                files.count == count + 1
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 12), .completed)
            let selected = try headerColors(node)
            for (before, after) in zip(collapsed, selected) {
                let delta = abs(before.redComponent - after.redComponent)
                    + abs(before.greenComponent - after.greenComponent)
                    + abs(before.blueComponent - after.blueComponent)
                XCTAssertLessThan(delta, 0.035,
                                  "Expanding a Worktree must not paint a persistent selection fill")
            }
            node.click()
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in files.count == count },
                                                  object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 12), .completed)
            let historical = window.descendants(matching: .any)
                .matching(identifier: "bailey.git.history.file")
                .matching(NSPredicate(format: "label ENDSWITH %@", ", " + path)).firstMatch
            parent.hover()
            parent.click()
            XCTAssertTrue(historical.waitForExistence(timeout: 12))
            let expandedHistory = try headerColors(parent)
            parent.click()
            XCTAssertTrue(historical.waitForNonExistence(timeout: 12))
            let collapsedHistory = try headerColors(parent)
            let changedPixels = zip(collapsedHistory, expandedHistory).filter { before, after in
                abs(before.redComponent - after.redComponent)
                    + abs(before.greenComponent - after.greenComponent)
                    + abs(before.blueComponent - after.blueComponent) >= 0.035
            }
            XCTAssertLessThan(changedPixels.count, 3,
                              "History disclosure must not add a persistent row fill; one anti-aliased edge pixel may vary")
        }
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["-C", linked.path, "rev-parse", "HEAD"]), feature)
        XCTAssertEqual(try Data(contentsOf: mainFile), Data("dirty main\n".utf8))
        XCTAssertEqual(try Data(contentsOf: featureFile), Data("dirty feature\n".utf8))
        XCTAssertTrue(try fixture.git(["diff", "--cached", "--name-only"]).isEmpty)
        XCTAssertTrue(try fixture.git(["-C", linked.path, "diff", "--cached", "--name-only"]).isEmpty)
    }

    func testOverflowBranchWorktreeActionRebindsAfterExternalRefresh() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let tracked = try fixture.file("menu.txt", text: "stable menu target\n")
        try fixture.initializeGit()
        try fixture.git(["tag", "v-before-refresh"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        let common = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bailey-UITest-Menu-" + UUID().uuidString)
        let first = common.appendingPathComponent("a904/Bailey")
        let second = common.appendingPathComponent("b905/Bailey")
        addTeardownBlock {
            for checkout in [first, second] {
                _ = try? fixture.git(["worktree", "remove", "--force", checkout.path])
            }
            try? FileManager.default.removeItem(at: common)
        }
        for checkout in [first, second] {
            try FileManager.default.createDirectory(at: checkout.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        }
        try fixture.git(["worktree", "add", "-q", "-b", "topic/menu", first.path, "HEAD"])
        try fixture.git(["worktree", "add", "-q", "--force", second.path, "topic/menu"])
        let locations = try fixture.git(["worktree", "list", "--porcelain"])
        XCTAssertEqual(String(decoding: locations, as: UTF8.self)
            .components(separatedBy: "branch refs/heads/topic/menu").count - 1, 2)
        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let window = app.windows.firstMatch
        func openSelectedWorktreeAction() -> XCUIElement {
            let overflow = app.menuButtons.matching(NSPredicate(
                format: "title CONTAINS %@ AND title CONTAINS %@", "topic/menu", "v-before-refresh"))
                .firstMatch
            XCTAssertTrue(overflow.waitForExistence(timeout: 25))
            overflow.click()
            let branch = app.menuItems.matching(NSPredicate(format: "title == %@", "topic/menu"))
                .firstMatch
            XCTAssertTrue(branch.waitForExistence(timeout: 8))
            branch.hover()
            let worktrees = branch.descendants(matching: .menuItem).matching(NSPredicate(
                format: "title IN %@", ["Worktree", "工作树"])).firstMatch
            XCTAssertTrue(worktrees.waitForExistence(timeout: 8))
            worktrees.hover()
            let selected = worktrees.descendants(matching: .menuItem)
                .matching(NSPredicate(format: "title == %@", "a904/Bailey")).firstMatch
            XCTAssertTrue(selected.waitForExistence(timeout: 8))
            selected.hover()
            let open = selected.descendants(matching: .menuItem).matching(NSPredicate(
                format: "title IN %@", ["Open Worktree", "在 Bailey 中打开工作树"])).firstMatch
            XCTAssertTrue(open.waitForExistence(timeout: 8))
            XCTAssertGreaterThan(open.frame.width, 0)
            return open
        }
        let open = openSelectedWorktreeAction()
        XCTAssertTrue(open.isHittable, "The original Worktree action must be a real native menu target")
        let began = Date()
        try "stable menu target\n".write(to: tracked, atomically: true, encoding: .utf8)
        try fixture.git(["tag", "v-external-refresh"])
        let updated = app.menuButtons.matching(NSPredicate(
            format: "title CONTAINS %@", "v-external-refresh")).firstMatch
        let observed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            updated.exists && Date().timeIntervalSince(began) >= 10
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [observed], timeout: 20), .completed,
                       "External file and Ref events must really refresh the graph during the dwell")
        XCTAssertEqual(try fixture.git(["worktree", "list", "--porcelain"]), locations,
                       "A menu invalidated by refresh must not run its stale Worktree action")
        // A native nested NSMenu may close when SwiftUI updates its backing ref list.
        // Never use the stale AX element: resolve the same checkout from the new menu.
        let actionable: XCUIElement
        if open.isHittable {
            actionable = open
        } else {
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            actionable = openSelectedWorktreeAction()
        }
        XCTAssertTrue(actionable.isHittable,
                      "The selected checkout must have a physically hittable current menu action")
        actionable.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let files = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 15))
        files.click()
        let chosen = first.appendingPathComponent("menu.txt")
        let row = WorkspaceUITestSupport.fileRow(chosen, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(chosen, in: window).waitForExistence(timeout: 15))
        XCTAssertEqual(window.textViews.firstMatch.value as? String, "stable menu target\n")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/tags/v-external-refresh"]), head)
        XCTAssertEqual(try fixture.git(["worktree", "list", "--porcelain"]), locations)
        for checkout in [fixture.root, first, second] {
            XCTAssertTrue(try fixture.git(["-C", checkout.path, "status", "--porcelain=v1"]).isEmpty)
        }
    }

    func testAllThirtyThreeRemoteReferencesRemainInTheNativeOverflowMenu() throws {
        let clipboard = try WorkspaceUITestSupport.clipboardItems()
        addTeardownBlock { @MainActor in
            NSPasteboard.general.clearContents()
            if !clipboard.isEmpty { XCTAssertTrue(NSPasteboard.general.writeObjects(clipboard)) }
        }
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("many-refs.txt", text: "same immutable object\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        for index in 0..<33 {
            let remote = "remote-\(index)"
            try fixture.git(["remote", "add", remote, fixture.root.path])
            try fixture.git(["update-ref", "refs/remotes/" + remote + "/main", "HEAD"])
        }
        let references = try fixture.git(["for-each-ref", "--format=%(refname)"])
        XCTAssertEqual(references.split(separator: 0x0A).count, 34)
        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let overflow = app.menuButtons.matching(NSPredicate(
            format: "title CONTAINS %@ AND title CONTAINS %@", "remote-0/main", "remote-32/main"))
            .firstMatch
        XCTAssertTrue(overflow.waitForExistence(timeout: 25))
        let window = app.windows.firstMatch
        let divider = try XCTUnwrap(window.descendants(matching: .any)
            .matching(identifier: "bailey.dock.divider").allElementsBoundByIndex
            .filter { $0.frame.height > $0.frame.width }
            .max { $0.frame.minX < $1.frame.minX })
        let origin = window.coordinate(withNormalizedOffset: .zero)
        divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(
                dx: window.frame.width - 150, dy: window.frame.height / 2)))
        XCTAssertTrue(overflow.isHittable,
                      "All 33 remote references must remain reachable in a real 150pt Git panel")
        overflow.click()
        for index in 0..<33 {
            let reference = app.menuItems.matching(NSPredicate(
                format: "title == %@", "remote-\(index)/main")).firstMatch
            XCTAssertTrue(reference.waitForExistence(timeout: 8),
                          "Every configured remote must keep its own native menu target")
        }
        let last = app.menuItems.matching(NSPredicate(
            format: "title == %@", "remote-32/main")).firstMatch
        last.hover()
        let copy = last.descendants(matching: .menuItem).matching(NSPredicate(
            format: "title IN %@", ["Copy Remote Branch Name", "复制远端分支名称"])).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 8))
        copy.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "remote-32/main")
        XCTAssertEqual(try fixture.git(["for-each-ref", "--format=%(refname)"]), references)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertTrue(try fixture.git(["status", "--porcelain=v1"]).isEmpty)
    }

    func testUnreferencedSharedWorktreeMenuOpensTheSelectedCheckoutAndActualFile() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("main-only.txt", text: "main checkout\n")
        try fixture.initializeGit()
        let base = try fixture.git(["rev-parse", "HEAD"])
        let common = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bailey-UITest-Unreferenced-" + UUID().uuidString)
        let first = common.appendingPathComponent("a904/Bailey")
        let second = common.appendingPathComponent("b905/Bailey")
        addTeardownBlock {
            for linked in [first, second] {
                _ = try? fixture.git(["worktree", "remove", "--force", linked.path])
            }
            try? FileManager.default.removeItem(at: common)
        }
        for linked in [first, second] {
            try FileManager.default.createDirectory(at: linked.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        }
        try fixture.git(["worktree", "add", "-q", "--detach", first.path, "HEAD"])
        let file = first.appendingPathComponent("detached-only.txt")
        try "selected detached checkout\n".write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["-C", first.path, "add", "."])
        try fixture.git(["-C", first.path, "-c", "user.name=BaileyUITest", "-c",
                         "user.email=tests@example.invalid", "commit", "-qm", "Unreferenced checkout"])
        let tip = String(decoding: try fixture.git(["-C", first.path, "rev-parse", "HEAD"]),
                         as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.git(["worktree", "add", "-q", "--detach", second.path, tip])
        XCTAssertTrue(try fixture.git(["for-each-ref", "--contains", tip]).isEmpty)
        let before = try fixture.git(["worktree", "list", "--porcelain"])
        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let window = app.windows.firstMatch
        let badge = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@", "a904/Bailey", "b905/Bailey"))
            .firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 25))
        badge.rightClick()
        let selectedPath = app.menuItems.matching(NSPredicate(format: "title == %@", "a904/Bailey"))
            .firstMatch
        XCTAssertTrue(selectedPath.waitForExistence(timeout: 8))
        selectedPath.click()
        let open = selectedPath.descendants(matching: .menuItem).matching(NSPredicate(
            format: "title IN %@", ["Open Worktree", "在 Bailey 中打开工作树"])).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 8))
        XCTAssertGreaterThan(open.frame.width, 0)
        open.click()
        let files = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 15))
        files.click()
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "Open Worktree must select the requested checkout, not its same-name sibling")
        row.doubleClick()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(file, in: window).waitForExistence(timeout: 15))
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertEqual(editor.value as? String, "selected detached checkout\n")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), base)
        XCTAssertEqual(try fixture.git(["worktree", "list", "--porcelain"]), before)
        for checkout in [fixture.root, first, second] {
            XCTAssertTrue(try fixture.git(["-C", checkout.path, "status", "--porcelain=v1"]).isEmpty)
        }
    }
}
