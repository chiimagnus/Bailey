import AppKit
import Foundation
import XCTest

@MainActor
final class GitGraphUITests: XCTestCase {
    func testHostedCommitMenuAndRemoteManagementUseRealGitConfiguration() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("hosted.txt", text: "remote context\n")
        try fixture.initializeGit()
        try fixture.git(["remote", "add", "origin", "https://github.com/owner/repo.git"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        let app = try launchGraph(fixture, language: "en")
        let commit = app.buttons["E2E fixture history"]
        XCTAssertTrue(commit.waitForExistence(timeout: 25))

        commit.rightClick()
        XCTAssertTrue(app.menuItems["Open on GitHub"].waitForExistence(timeout: 12),
                      "Git Graph must expose the known host instead of assuming GitHub")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        let more = app.descendants(matching: .any)
            .matching(identifier: "bailey.git.more-actions").firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 12))
        more.click()
        let manage = app.menuItems["Manage Remotes…"]
        XCTAssertTrue(manage.waitForExistence(timeout: 10))
        manage.click()
        XCTAssertTrue(app.staticTexts["origin"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "bailey.git.remote-name").firstMatch
            .waitForExistence(timeout: 15))
        let done = app.descendants(matching: .any)
            .matching(identifier: "bailey.git.remote-done").firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.click()

        XCTAssertEqual(try fixture.git(["remote", "get-url", "origin"]),
                       Data("https://github.com/owner/repo.git\n".utf8))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
    }

    func testGraphExplicitSelectionIsIndependentOfKeyboardCursorAndContext() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let oldFile = try fixture.file("nested/old.txt", text: "history stays unchanged\n")
        try fixture.initializeGit()
        _ = try fixture.file("new.txt", text: "new revision\n")
        try fixture.git(["add", "--", "new.txt"])
        try fixture.git(["commit", "-qm", "new selected commit"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        let app = try launchGraph(fixture, language: "en")
        let window = app.windows.firstMatch
        let current = app.buttons["new selected commit"]
        let earlier = app.buttons["E2E fixture history"]
        XCTAssertTrue(current.waitForExistence(timeout: 25))
        XCTAssertTrue(earlier.waitForExistence(timeout: 25))
        XCTAssertFalse(current.isSelected)
        XCTAssertFalse(earlier.isSelected)
        func rowColor() throws -> NSColor {
            let screenshot = window.screenshot().image
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data:
                XCTUnwrap(screenshot.tiffRepresentation)))
            let x = bitmap.pixelsWide - Int(16 * CGFloat(bitmap.pixelsWide) / window.frame.width)
            let y = Int((current.frame.midY - window.frame.minY)
                        * CGFloat(bitmap.pixelsHigh) / window.frame.height)
            return try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        }
        let beforeColor = try rowColor()
        let before = XCTAttachment(screenshot: window.screenshot())
        before.name = "Git Graph before explicit selection"
        before.lifetime = .keepAlways
        add(before)
        current.click()
        XCTAssertTrue(current.isSelected, "Clicking a commit must create real Selection")
        XCTAssertFalse(earlier.isSelected)
        let activeColor = try rowColor()
        XCTAssertGreaterThan(
            activeColor.blueComponent - activeColor.redComponent,
            beforeColor.blueComponent - beforeColor.redComponent + 0.05,
            "The actual Git Graph row must gain the blue selection fill, not just AX Selected"
        )
        let after = XCTAttachment(screenshot: window.screenshot())
        after.name = "Git Graph selected commit has active accent fill"
        after.lifetime = .keepAlways
        add(after)

        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        XCTAssertTrue(current.isSelected, "Arrow navigation moves Focus, not Selection")
        XCTAssertFalse(earlier.isSelected)
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
        XCTAssertTrue(current.isSelected, "Right arrow disclosure must not select the focused commit")
        XCTAssertFalse(earlier.isSelected)
        app.typeKey(XCUIKeyboardKey.leftArrow, modifierFlags: [])
        XCTAssertTrue(current.isSelected, "Left arrow collapse must preserve Selection")
        XCTAssertFalse(earlier.isSelected)
        earlier.rightClick()
        XCTAssertTrue(app.menuItems["Create Branch at Commit…"].waitForExistence(timeout: 10))
        XCTAssertFalse(earlier.isSelected, "Context Target must not become Selection")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(current.isSelected, "Dismissing a menu must preserve Selection")

        earlier.click()
        XCTAssertTrue(earlier.isSelected)
        XCTAssertFalse(current.isSelected)
        let folder = window.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder")
            .matching(NSPredicate(format: "label CONTAINS %@", "nested")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 12))
        folder.click()
        XCTAssertTrue(folder.isSelected, "Git Graph folders must also use Selection fill")
        XCTAssertFalse(earlier.isSelected)
        folder.click()
        let historical = historicalFile("nested/old.txt", in: app)
        XCTAssertTrue(historical.waitForExistence(timeout: 12))
        historical.click()
        XCTAssertTrue(historical.isSelected, "Historical files must use the shared Selection")
        XCTAssertFalse(folder.isSelected)
        app.typeKey(XCUIKeyboardKey.upArrow, modifierFlags: [])
        XCTAssertTrue(historical.isSelected, "Keyboard Focus must not move the file Selection")
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(folder.isSelected, "Space on a focused folder explicitly selects it")
        XCTAssertFalse(historical.exists, "Space must still collapse the actual focused folder")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertTrue(try fixture.git(["status", "--porcelain=v1"]).isEmpty)
        XCTAssertEqual(try Data(contentsOf: oldFile), Data("history stays unchanged\n".utf8))
    }

    func testSwitchingProjectsInsideSameRepositoryKeepsGraphDisclosureScoped() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let nestedFile = try fixture.file("nested/shared.txt", text: "first\n")
        try fixture.initializeGit()
        let original = try fixture.git(["rev-parse", "HEAD"])
        try "second\n".write(to: nestedFile, atomically: true, encoding: .utf8)
        try fixture.git(["add", "--", "nested/shared.txt"])
        try fixture.git(["commit", "-qm", "second shared revision"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        XCTAssertNotEqual(original, head)
        let app = try launchGraph(fixture, language: "en")
        let first = app.buttons["E2E fixture history"]
        let second = app.buttons["second shared revision"]
        XCTAssertTrue(first.waitForExistence(timeout: 25))
        XCTAssertTrue(second.waitForExistence(timeout: 25))
        first.click()
        XCTAssertTrue(first.isSelected, "The original Project must own its Graph Selection")
        let historical = historicalFile("nested/shared.txt", in: app)
        XCTAssertTrue(historical.waitForExistence(timeout: 12))

        app.typeKey("a", modifierFlags: [.command, .shift])
        try WorkspaceUITestSupport.choose(nestedFile.deletingLastPathComponent(), in: app)
        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(first.waitForExistence(timeout: 25))
        XCTAssertTrue(second.waitForExistence(timeout: 25))
        XCTAssertFalse(historical.exists,
                       "A new Project must not reuse the other Project's expanded commit")
        XCTAssertFalse(first.isSelected,
                       "A new Project in the same Git repository must not inherit old Selection")
        first.click()
        XCTAssertTrue(historical.waitForExistence(timeout: 12),
                      "The new Project must open its own commit details on first click")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try Data(contentsOf: nestedFile), Data("second\n".utf8))
        XCTAssertTrue(try fixture.git(["status", "--porcelain=v1"]).isEmpty)
    }

    func testExpandedCommitSurvivesTemporaryGitPanelHiding() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("retained/history.txt", text: "immutable history bytes\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        let app = try launchGraph(fixture, language: "en")
        let commit = app.buttons["E2E fixture history"]
        let history = historicalFile("retained/history.txt", in: app)
        XCTAssertTrue(commit.waitForExistence(timeout: 20))
        XCTAssertFalse(history.exists)
        commit.click()
        XCTAssertTrue(history.waitForExistence(timeout: 12))

        app.typeKey("e", modifierFlags: [.command, .shift])
        let files = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 15))
        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(history.waitForExistence(timeout: 12),
                      "Hiding Git must not discard a still-valid expanded commit")
        commit.click()
        XCTAssertTrue(history.waitForNonExistence(timeout: 12),
                      "The restored disclosure must collapse on its next click, not re-expand")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertTrue(try fixture.git(["status", "--porcelain=v1"]).isEmpty)
    }

    func testCommandClickSecondCommitKeepsBothHistoricalDetailsIndependent() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("first-history.txt", text: "first\n")
        try fixture.initializeGit()
        _ = try fixture.file("second-history.txt", text: "second\n")
        try fixture.git(["add", "--", "second-history.txt"])
        try fixture.git(["commit", "-qm", "second history record"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        let app = try launchGraph(fixture, language: "en")
        let first = app.buttons["E2E fixture history"]
        let second = app.buttons["second history record"]
        XCTAssertTrue(first.waitForExistence(timeout: 25))
        XCTAssertTrue(second.waitForExistence(timeout: 25))
        first.click()
        XCTAssertTrue(historicalFile("first-history.txt", in: app).waitForExistence(timeout: 12))
        XCUIElement.perform(withKeyModifiers: .command) { second.click() }
        XCTAssertTrue(historicalFile("second-history.txt", in: app).waitForExistence(timeout: 12))
        XCTAssertTrue(historicalFile("first-history.txt", in: app).exists)
        XCTAssertEqual(app.windows.firstMatch.descendants(matching: .any)
            .matching(identifier: "bailey.git.history.file").count, 2,
            "A modified click must only expand its own commit's normal historical files")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertTrue(try fixture.git(["status", "--porcelain=v1"]).isEmpty)
    }

    func testGraphArrowNavigationKeepsRealCommitVisible() throws {
        try verifyGraphArrowNavigation(pendingChanges: false)
    }

    func testGraphArrowNavigationWithGitChangesKeepsRealCommitVisible() throws {
        try verifyGraphArrowNavigation(pendingChanges: true)
    }

    private func verifyGraphArrowNavigation(pendingChanges: Bool) throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let tracked = try fixture.file("navigation-00.txt", text: "initial revision\n")
        try fixture.initializeGit()
        for revision in 1...30 {
            let name = String(format: "navigation-%02d", revision)
            _ = try fixture.file(name + ".txt", text: "revision \(revision)\n")
            try fixture.git(["add", "--", name + ".txt"])
            try fixture.git(["commit", "-qm", name])
        }
        if pendingChanges {
            try "modified revision\n".write(to: tracked, atomically: true, encoding: .utf8)
            _ = try fixture.file("untracked-navigation.txt", text: "not committed\n")
        }
        let initialHead = try fixture.git(["rev-parse", "HEAD"])
        let initialStatus = try fixture.git(["status", "--porcelain=v1"])
        let app = try launchGraph(fixture, language: "en")
        let newest = app.buttons["navigation-30"]
        XCTAssertTrue(newest.waitForExistence(timeout: 25))
        newest.click()
        newest.click()

        for _ in 0..<12 {
            app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        }
        let destination = app.buttons["navigation-18"]
        XCTAssertTrue(destination.waitForExistence(timeout: 12),
                      "Keyboard navigation must realize an offscreen commit")
        XCTAssertTrue(destination.isHittable,
                      "A focused Git Graph commit must stay inside the scroll viewport")
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(historicalFile("navigation-18.txt", in: app).waitForExistence(timeout: 12),
                      "Space must expand the actual navigated commit")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), initialHead)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), initialStatus)
        XCTAssertEqual(try Data(contentsOf: tracked),
                       Data(pendingChanges ? "modified revision\n".utf8 : "initial revision\n".utf8))
    }

    func testGraphKeyboardNavigationKeepsFortyHistoricalFilesVisible() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let files = try (0..<40).map { index in
            try fixture.file(String(format: "graph-key-%02d.txt", index), text: "history \(index)\n")
        }
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        let app = try launchGraph(fixture)
        let commit = app.buttons["E2E fixture history"]
        XCTAssertTrue(commit.waitForExistence(timeout: 25))
        commit.click()
        XCTAssertTrue(historicalFile("graph-key-00.txt", in: app).waitForExistence(timeout: 15))

        for (index, file) in files.enumerated() {
            app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
            let row = historicalFile(file.lastPathComponent, in: app)
            let visible = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in row.isHittable }, object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed,
                           "Graph keyboard row \(index) must remain in the actual scroll viewport")
            XCTAssertFalse(row.isSelected,
                           "Graph keyboard cursor must not manufacture file Selection")
        }
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertTrue(try fixture.git(["status", "--porcelain=v1"]).isEmpty)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.last)), Data("history 39\n".utf8))
    }

    func testGraphCommandArrowsNavigateRealParentAndChildWithoutMutatingGit() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("parent-node.txt", text: "parent data\n")
        try fixture.initializeGit()
        _ = try fixture.file("child-node.txt", text: "child data\n")
        try fixture.git(["add", "--", "child-node.txt"])
        try fixture.git(["commit", "-qm", "child graph node"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        let app = try launchGraph(fixture, language: "en")
        let parent = app.buttons["E2E fixture history"]
        let child = app.buttons["child graph node"]
        XCTAssertTrue(parent.waitForExistence(timeout: 25))
        XCTAssertTrue(child.waitForExistence(timeout: 25))
        child.click()
        XCTAssertTrue(child.isSelected)
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: .command)
        XCTAssertTrue(child.isSelected, "Cmd-arrow navigation must preserve explicit Selection")
        XCTAssertFalse(parent.isSelected)
        XCTAssertTrue(historicalFile("parent-node.txt", in: app).waitForExistence(timeout: 15),
                      "Cmd-Down must activate and expand the actual parent commit")
        app.typeKey(XCUIKeyboardKey.upArrow, modifierFlags: .command)
        XCTAssertTrue(historicalFile("child-node.txt", in: app).waitForExistence(timeout: 15),
                      "Cmd-Up must activate the current commit's loaded child")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertTrue(try fixture.git(["status", "--porcelain=v1"]).isEmpty)
    }

    func testRightClickDifferentCommitMovesGraphKeyboardCursorWithoutOpeningHistory() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("first-commit.txt", text: "first\n")
        try fixture.initializeGit()
        _ = try fixture.file("second-commit.txt", text: "second\n")
        try fixture.git(["add", "--", "second-commit.txt"])
        try fixture.git(["commit", "-m", "second context commit"])

        let app = try launchGraph(fixture, language: "en")
        let firstCommit = app.buttons["E2E fixture history"]
        let secondCommit = app.buttons["second context commit"]
        XCTAssertTrue(firstCommit.waitForExistence(timeout: 25))
        XCTAssertTrue(secondCommit.waitForExistence(timeout: 25))
        secondCommit.click()
        secondCommit.click()

        firstCommit.rightClick()
        XCTAssertTrue(app.menuItems["Create Branch at Commit…"].waitForExistence(timeout: 10))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        let earlierFile = historicalFile("first-commit.txt", in: app)
        XCTAssertFalse(earlierFile.exists, "Context click must not expand a commit")
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(earlierFile.waitForExistence(timeout: 12),
                      "Space must act on the right-clicked commit, not the prior keyboard row")
        XCTAssertTrue(try fixture.git(["status", "--porcelain=v1"]).isEmpty)
    }

    func testGraphBadgeTitleNodeAndMetadataToggleTheSameRealCommit() throws {
        try verifyGraphInteractions(language: "en")
    }

    func testChineseGraphNodeAndReferenceMenusRetainTheirExactCopyTargets() throws {
        try verifyGraphInteractions(language: "zh-Hans")
    }

    private func verifyGraphInteractions(language: String) throws {
        let clipboard = try WorkspaceUITestSupport.clipboardItems()
        addTeardownBlock { @MainActor in
            NSPasteboard.general.clearContents()
            if !clipboard.isEmpty { XCTAssertTrue(NSPasteboard.general.writeObjects(clipboard)) }
        }
        let fixture = try WorkspaceUITestFixture(in: self)
        let tracked = try fixture.file("nested/history.txt", text: "committed history\n")
        try fixture.initializeGit()
        try fixture.git(["branch", "topic/history"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        let fullHash = String(decoding: head, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let app = try launchGraph(fixture, language: language)
        let commit = app.buttons.matching(NSPredicate(
            format: "label == %@", "E2E fixture history")).firstMatch
        let badge = app.buttons.matching(NSPredicate(
            format: "label IN %@", ["main, Worktree", "main, 工作树"])).firstMatch
        let file = historicalFile("nested/history.txt", in: app)
        XCTAssertTrue(commit.waitForExistence(timeout: 25))
        XCTAssertTrue(badge.waitForExistence(timeout: 12))
        XCTAssertFalse(file.exists)

        badge.click()
        XCTAssertTrue(file.waitForExistence(timeout: 12),
                      "Clicking the visible Branch badge must expand its real commit")
        commit.click()
        XCTAssertTrue(file.waitForNonExistence(timeout: 12),
                      "Clicking the title must collapse the same commit")

        let node = app.descendants(matching: .any).matching(NSPredicate(
            format: "value == %@", fullHash)).firstMatch
        XCTAssertTrue(node.waitForExistence(timeout: 12),
                      "The graph node must expose the actual commit OID")
        node.click()
        XCTAssertTrue(file.waitForExistence(timeout: 12))
        node.click()
        XCTAssertTrue(file.waitForNonExistence(timeout: 12),
                      "Node hit testing must toggle exactly once per click")
        node.hover()
        node.rightClick()
        let create = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Create Branch at Commit…", "在此创建分支…"])).firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 8))
        XCTAssertFalse(app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Delete Remote Branch…", "删除远端分支…"])).firstMatch.exists)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertFalse(file.exists, "Opening the node menu must not expand the commit")

        // Locate the metadata inside the real 38-point row rather than extending
        // a title Button's normalized coordinate beyond its own bounds.
        let window = app.windows.firstMatch
        let metadataPoint = window.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: min(commit.frame.minX + 15, window.frame.maxX - 24)
                         - window.frame.minX,
                     dy: badge.frame.maxY + 7 - window.frame.minY))
        metadataPoint.click()
        guard file.waitForExistence(timeout: 12) else {
            XCTFail("The blank metadata area did not toggle its Git Graph commit")
            return
        }
        badge.rightClick()
        let rename = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Rename Branch…", "重命名分支…"])).firstMatch
        let copy = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Copy Branch Name", "复制分支名称"])).firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 8))
        XCTAssertTrue(copy.waitForExistence(timeout: 8))
        copy.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "main")
        XCTAssertTrue(file.exists, "Copying the Branch must not toggle its commit")
        badge.click()
        XCTAssertTrue(file.waitForNonExistence(timeout: 12))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "main",
                       "Expanding or collapsing a Branch must not copy its name")
        let overflow = app.menuButtons.matching(NSPredicate(
            format: "title CONTAINS %@", "topic/history")).firstMatch
        XCTAssertTrue(overflow.waitForExistence(timeout: 8))
        overflow.click()
        let topic = app.menuItems.matching(NSPredicate(format: "title == %@", "topic/history"))
            .firstMatch
        XCTAssertTrue(topic.waitForExistence(timeout: 8))
        topic.hover()
        let copyTopic = topic.descendants(matching: .menuItem).matching(NSPredicate(
            format: "title IN %@", ["Copy Branch Name", "复制分支名称"])).firstMatch
        XCTAssertTrue(copyTopic.waitForExistence(timeout: 8))
        copyTopic.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "topic/history")
        XCTAssertFalse(file.exists, "Copying another Branch must not toggle the shared commit")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
        XCTAssertEqual(try Data(contentsOf: tracked), Data("committed history\n".utf8))
    }

    func testOverflowReferencesExposeTagAndBranchWithoutLosingGitRefs() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("overflows.txt", text: "refs remain distinct\n")
        try fixture.initializeGit()
        try fixture.git(["branch", "topic/extra"])
        try fixture.git(["tag", "v1.2.3"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        let app = try launchGraph(fixture)
        // SwiftUI's native MenuButton exposes its hidden references as AX title,
        // not label. Query the real control rather than an inferred +N Text child.
        let hidden = app.menuButtons.matching(NSPredicate(
            format: "title CONTAINS %@ AND title CONTAINS %@",
            "topic/extra", "v1.2.3")).firstMatch
        guard hidden.waitForExistence(timeout: 12) else {
            XCTFail("The +N MenuButton must retain all real hidden reference names")
            return
        }
        hidden.click()
        let branch = app.menuItems.matching(NSPredicate(format: "title == %@", "topic/extra"))
            .firstMatch
        let tag = app.menuItems.matching(NSPredicate(format: "title == %@", "v1.2.3"))
            .firstMatch
        XCTAssertTrue(branch.waitForExistence(timeout: 8))
        XCTAssertTrue(tag.waitForExistence(timeout: 8))
        tag.click()
        let copyTag = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Copy Tag Name", "复制标签名称"])).firstMatch
        XCTAssertTrue(copyTag.waitForExistence(timeout: 8),
                      "The real second-level menu must contain the selected Tag actions")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/heads/topic/extra"]), head)
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/tags/v1.2.3"]), head)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
    }

    func testGraphTreeKeyboardMovesFromChangesFocusToBothHistoricalFiles() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let alpha = try fixture.file("nested/alpha.txt", text: "alpha history\n")
        let beta = try fixture.file("nested/beta.txt", text: "beta history\n")
        let changed = try fixture.file("working.txt", text: "original\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        try "edited\n".write(to: changed, atomically: true, encoding: .utf8)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]),
                       Data(" M working.txt\n".utf8))
        let app = try launchGraph(fixture)
        let window = app.windows.firstMatch
        let changeRow = WorkspaceUITestSupport.fileRow(changed, in: window,
                                                       relativeTo: fixture.root)
        XCTAssertTrue(changeRow.waitForExistence(timeout: 25))
        changeRow.click()
        let graphCommit = app.buttons.matching(NSPredicate(
            format: "label == %@", "E2E fixture history")).firstMatch
        let badge = app.buttons.matching(NSPredicate(
            format: "label IN %@", ["main, Worktree", "main, 工作树"])).firstMatch
        XCTAssertTrue(graphCommit.waitForExistence(timeout: 20))
        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        badge.click()
        let first = historicalFile("nested/alpha.txt", in: app)
        let second = historicalFile("nested/beta.txt", in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        XCTAssertTrue(second.waitForExistence(timeout: 15))

        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
        app.typeKey(" ", modifierFlags: [])
        let firstTab = window.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", alpha.lastPathComponent)).firstMatch
        XCTAssertTrue(firstTab.waitForExistence(timeout: 15),
                      "Down, Right and Space must browse the first real historical file")
        XCTAssertTrue(graphCommit.isHittable,
                      "The Git Graph must retain its focus owner while previewing a historical Diff")
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let secondTab = window.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", beta.lastPathComponent)).firstMatch
        XCTAssertTrue(secondTab.waitForExistence(timeout: 15),
                      "Down and Return must browse the next historical file")
        app.typeKey(XCUIKeyboardKey.leftArrow, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.leftArrow, modifierFlags: [])
        XCTAssertTrue(first.waitForNonExistence(timeout: 12),
                      "Left from a historical file must select and collapse the parent folder")
        XCTAssertTrue(graphCommit.isHittable,
                      "Collapsing a nested folder must not close the real commit")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertTrue(try fixture.git(["diff", "--cached", "--name-only"]).isEmpty)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]),
                       Data(" M working.txt\n".utf8))
        XCTAssertEqual(try Data(contentsOf: alpha), Data("alpha history\n".utf8))
        XCTAssertEqual(try Data(contentsOf: beta), Data("beta history\n".utf8))
        XCTAssertEqual(try Data(contentsOf: changed), Data("edited\n".utf8))
    }

    func testDetachedHeadAndRealStashKeepSeparateNativeGraphActions() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let tracked = try fixture.file("stash-check.txt", text: "base contents\n")
        try fixture.initializeGit()
        try fixture.git(["config", "user.name", "BaileyUITest"])
        try fixture.git(["config", "user.email", "tests@example.invalid"])
        try fixture.git(["tag", "v-stash-history"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        try "unsaved changes\n".write(to: tracked, atomically: true, encoding: .utf8)
        try fixture.git(["stash", "push", "-m", "graph-actual-stash"])
        let stashOID = try fixture.git(["rev-parse", "stash@{0}"])
        try fixture.git(["checkout", "-q", "--detach", "HEAD"])
        XCTAssertThrowsError(try fixture.git(["symbolic-ref", "-q", "HEAD"]))
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/tags/v-stash-history"]), head)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())

        let app = try launchGraph(fixture)
        let badge = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", "stash@{0}")).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 25),
                      "The real stash must appear as its own Git Graph node")
        badge.rightClick()
        let pop = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Pop Stash…", "弹出储藏…"])).firstMatch
        let copyOID = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Copy Stash Hash", "复制储藏哈希"])).firstMatch
        let unsafe = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Checkout Commit…", "检出提交…"])).firstMatch
        XCTAssertTrue(pop.waitForExistence(timeout: 8))
        XCTAssertTrue(copyOID.waitForExistence(timeout: 8))
        XCTAssertFalse(unsafe.exists,
                       "The Stash graph node must not offer ordinary destructive commit actions")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        badge.click()
        let files = historicalFile("stash-check.txt", in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 15),
                      "Expanding the actual stash must load its historical Git file")
        badge.click()
        XCTAssertTrue(files.waitForNonExistence(timeout: 12))
        let commit = app.buttons.matching(NSPredicate(
            format: "label == %@", "E2E fixture history")).firstMatch
        XCTAssertTrue(commit.waitForExistence(timeout: 12),
                      "The detached HEAD commit remains visible and independent of stash")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["rev-parse", "stash@{0}"]), stashOID)
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/tags/v-stash-history"]), head)
        XCTAssertThrowsError(try fixture.git(["symbolic-ref", "-q", "HEAD"]))
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
        XCTAssertEqual(try Data(contentsOf: tracked), Data("base contents\n".utf8))
    }

    func testDirtyLinkedWorktreeUsesItsOwnGraphNodeAndSafeNativeMenu() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("linked-diff.txt", text: "committed in main\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        let branch = "topic/" + String(repeating: "极长的分支名称-long-", count: 6)
        let linked = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bailey-UITest-Linked-" + UUID().uuidString)
        addTeardownBlock {
            _ = try? fixture.git(["worktree", "remove", "--force", linked.path])
            try? FileManager.default.removeItem(at: linked)
        }
        try fixture.git(["worktree", "add", "-q", "-b", branch, linked.path, "HEAD"])
        let linkedFile = linked.appendingPathComponent("linked-diff.txt")
        try "changed in linked worktree\n".write(to: linkedFile,
                                                      atomically: true, encoding: .utf8)
        XCTAssertEqual(try fixture.git(["worktree", "list", "--porcelain"])
            .contains(Data(linked.path.utf8)), true)
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/heads/" + branch]), head)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data(),
                       "Changes in another worktree must not dirty the current repository")

        let app = try launchGraph(fixture)
        let node = app.buttons.matching(NSPredicate(
            format: "value == %@", linked.path)).firstMatch
        guard node.waitForExistence(timeout: 25) else {
            XCTFail("The other dirty worktree must have its own native graph node")
            return
        }
        let window = app.windows.firstMatch
        let divider = window.descendants(matching: .any)
            .matching(identifier: "bailey.dock.divider")
            .allElementsBoundByIndex.filter { $0.frame.height > $0.frame.width }
            .max { $0.frame.minX < $1.frame.minX }
        guard let divider else { XCTFail("Missing real Dock divider"); return }
        let origin = window.coordinate(withNormalizedOffset: .zero)
        divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(
                dx: window.frame.width - 150, dy: window.frame.height / 2)))
        XCTAssertTrue(node.isHittable, "A dirty worktree with a very long Branch must remain accessible in a 150pt panel")
        node.rightClick()
        let copyPath = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Copy Worktree Path", "复制工作树路径"])).firstMatch
        let unsafe = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Checkout Commit…", "检出提交…"])).firstMatch
        XCTAssertTrue(copyPath.waitForExistence(timeout: 8),
                      "The dirty node must have its own worktree path action")
        XCTAssertFalse(unsafe.exists,
                       "A dirty worktree state must not become a synthetic commit action")
        XCTAssertFalse(app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Rename Branch…", "重命名分支…",
                                   "Copy Branch Name", "复制分支名称"])).firstMatch.exists,
                       "A dirty worktree node must not repeat the checkout's Branch badge actions")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        node.click()
        let file = app.windows.firstMatch.descendants(matching: .any)
            .matching(identifier: "bailey.tree.file")
            .matching(NSPredicate(format: "label ENDSWITH %@", ", linked-diff.txt"))
            .firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 12),
                      "The other worktree state must list its actual changed path")
        node.click()
        XCTAssertTrue(file.waitForNonExistence(timeout: 12))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/heads/" + branch]), head)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
        XCTAssertEqual(try Data(contentsOf: linkedFile),
                       Data("changed in linked worktree\n".utf8))
    }

    func testRealGraphHistoryLoadsNextPageOnlyAfterScrollingToBottom() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("root.txt", text: "root revision\n")
        try fixture.initializeGit()
        try fixture.git(["config", "user.name", "BaileyUITest"])
        try fixture.git(["config", "user.email", "tests@example.invalid"])
        for index in 0..<34 {
            try fixture.git(["commit", "--allow-empty", "-qm", "graph-page-\(index)"])
        }
        let head = try fixture.git(["rev-parse", "HEAD"])
        XCTAssertEqual(try fixture.git(["rev-list", "--count", "HEAD"]), Data("35\n".utf8))
        let app = try launchGraph(fixture)
        let latest = app.buttons.matching(NSPredicate(
            format: "label == %@", "graph-page-33")).firstMatch
        let oldest = app.buttons.matching(NSPredicate(
            format: "label == %@", "E2E fixture history")).firstMatch
        XCTAssertTrue(latest.waitForExistence(timeout: 25))
        XCTAssertFalse(oldest.exists,
                       "Only the first 30 real commits should initially be loaded")

        // Pixel-based macOS XCTest scroll is routed through the actual graph row.
        latest.scroll(byDeltaX: 0, deltaY: -950)
        XCTAssertTrue(oldest.waitForExistence(timeout: 25),
                      "Reaching the real last row must load the next page of Git history")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
        XCTAssertEqual(try fixture.git(["rev-list", "--count", "HEAD"]), Data("35\n".utf8))
    }

    func testDenseRealGraphKeepsHistoryAndNodeVisibleAcrossMoreThanTwelveLanes() throws {
        try verifyDenseGraph(theme: "light", fontSize: 14, widths: [420, 260, 150, 320])
    }

    func testDarkDenseGraphAtMinimumPanelFontKeepsTitleAndRailsInsideThePanel() throws {
        try verifyDenseGraph(theme: "dark", fontSize: 9)
    }

    func testDarkDenseGraphAtMaximumPanelFontKeepsTitleAndRailsInsideThePanel() throws {
        try verifyDenseGraph(theme: "dark", fontSize: 18)
    }

    private func verifyDenseGraph(
        theme: String, fontSize: Int, widths: [CGFloat] = [420, 150]
    ) throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("base.txt", text: "shared base\n")
        try fixture.initializeGit()
        let base = try fixture.git(["rev-parse", "HEAD"])
        let tree = String(decoding: try fixture.git(["rev-parse", "HEAD^{tree}"]),
                          as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = String(decoding: base, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for index in 0..<24 {
            let subject = "graph-lane-\(index)"
            let oid = String(decoding: try fixture.git([
                "-c", "user.name=BaileyUITest", "-c", "user.email=tests@example.invalid",
                "commit-tree", tree, "-p", baseName, "-m", subject
            ]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            try fixture.git(["update-ref", "refs/heads/branch-lane-\(index)", oid])
        }
        XCTAssertEqual(try fixture.git(["for-each-ref", "--format=%(refname)",
                                        "refs/heads"]).split(separator: 0x0A).count, 25)
        let home = try WorkspaceUITestFixture(in: self)
        _ = try home.file(".config/bailey-dev/config.toml",
                          text: "theme = \"\(theme)\"\npanel.font-size = \(fontSize)\n")
        let app = try launchGraph(fixture, configurationHome: home.root)
        let commit = app.buttons.matching(NSPredicate(
            format: "label MATCHES %@", "graph-lane-[0-9]+"))
            .firstMatch
        XCTAssertTrue(commit.waitForExistence(timeout: 25),
                      "A real 24-lane Graph must expose a visible commit title")
        XCTAssertTrue(commit.isHittable,
                      "Dense lanes must not push the first visible commit out of the sidebar")
        let window = app.windows.firstMatch
        XCTAssertLessThan(commit.frame.minX, window.frame.maxX - 12,
                          "The history title must stay within the real Git Graph viewport")
        let node = app.buttons.matching(NSPredicate(
            format: "label ENDSWITH %@", ": " + commit.label)).firstMatch
        XCTAssertTrue(node.waitForExistence(timeout: 12),
                      "The dense real graph must still expose its colored node")
        XCTAssertEqual(node.frame.width / 14, CGFloat(fontSize) / 14, accuracy: 0.04)
        for width in widths {
            let divider = try XCTUnwrap(window.descendants(matching: .any)
                .matching(identifier: "bailey.dock.divider").allElementsBoundByIndex
                .filter { $0.frame.height > $0.frame.width }
                .max { $0.frame.minX < $1.frame.minX })
            let origin = window.coordinate(withNormalizedOffset: .zero)
            divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .click(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(
                    dx: window.frame.width - width, dy: window.frame.height / 2)))
            XCTAssertTrue(commit.isHittable)
            XCTAssertGreaterThan(commit.frame.width, 0)
            XCTAssertGreaterThanOrEqual(commit.frame.minX, window.frame.maxX - width)
            XCTAssertLessThanOrEqual(commit.frame.maxX, window.frame.maxX + 1,
                "At requested \(width)pt: title=\(commit.frame), node=\(node.frame), window=\(window.frame), divider=\(divider.frame)")
            let originalNodeX = node.frame.minX
            commit.scroll(byDeltaX: -180, deltaY: 0)
            XCTAssertEqual(node.frame.minX, originalNodeX, accuracy: 1,
                           "Scrolling the commit title must never move the graph gutter")
        }
        // A dense graph may reuse path colors, but must preserve the actual Git refs.
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), base)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
        XCTAssertEqual(try fixture.git(["for-each-ref", "--format=%(refname)",
                                        "refs/heads"]).split(separator: 0x0A).count, 25)
        _ = node
    }

    func testHistoricalTagBadgeTogglesItsCommitAndKeepsOnlyTagActions() throws {
        let clipboard = try WorkspaceUITestSupport.clipboardItems()
        addTeardownBlock { @MainActor in
            NSPasteboard.general.clearContents()
            if !clipboard.isEmpty { XCTAssertTrue(NSPasteboard.general.writeObjects(clipboard)) }
        }
        let fixture = try WorkspaceUITestFixture(in: self)
        let tracked = try fixture.file("tagged-history.txt", text: "old tagged revision\n")
        try fixture.initializeGit()
        let original = try fixture.git(["rev-parse", "HEAD"])
        try fixture.git(["tag", "v1.0.0-graph"])
        try fixture.git(["config", "user.name", "BaileyUITest"])
        try fixture.git(["config", "user.email", "tests@example.invalid"])
        try "new working revision\n".write(to: tracked, atomically: true, encoding: .utf8)
        try fixture.git(["add", "--", "tagged-history.txt"])
        try fixture.git(["commit", "-qm", "Current main after tagged history"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        XCTAssertNotEqual(head, original)

        let app = try launchGraph(fixture)
        let tag = app.buttons.matching(NSPredicate(
            format: "label == %@", "v1.0.0-graph")).firstMatch
        let commit = app.buttons.matching(NSPredicate(
            format: "label == %@", "E2E fixture history")).firstMatch
        let historical = historicalFile("tagged-history.txt", in: app)
        XCTAssertTrue(tag.waitForExistence(timeout: 25))
        XCTAssertTrue(commit.waitForExistence(timeout: 12))
        XCTAssertFalse(historical.exists)
        tag.click()
        XCTAssertTrue(historical.waitForExistence(timeout: 12),
                      "The real Tag badge must expand the tagged old commit")
        commit.click()
        XCTAssertTrue(historical.waitForNonExistence(timeout: 12),
                      "The Tag and commit title must own the same expansion state")
        tag.rightClick()
        let copy = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Copy Tag Name", "复制标签名称"])).firstMatch
        let delete = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Delete Tag…", "删除标签…"])).firstMatch
        let unsafe = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Checkout Commit…", "检出提交…"])).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 8))
        XCTAssertTrue(delete.waitForExistence(timeout: 8))
        XCTAssertFalse(unsafe.exists, "Tag badge context menu must not expose commit actions")
        copy.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "v1.0.0-graph")
        XCTAssertFalse(historical.exists, "Copying the Tag must not toggle its commit")
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/tags/v1.0.0-graph"]), original)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
        XCTAssertEqual(try Data(contentsOf: tracked), Data("new working revision\n".utf8))
    }

    func testCleanSharedHEADWorktreesKeepDistinctThreeLevelNativeMenus() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("shared-history.txt", text: "shared history\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        let common = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bailey-UITest-Graph-Multi-" + UUID().uuidString)
        let first = common.appendingPathComponent("a904/Bailey")
        let second = common.appendingPathComponent("b905/Bailey")
        addTeardownBlock {
            _ = try? fixture.git(["worktree", "remove", "--force", first.path])
            _ = try? fixture.git(["worktree", "remove", "--force", second.path])
            try? FileManager.default.removeItem(at: common)
        }
        for linked in [first, second] {
            try FileManager.default.createDirectory(at: linked.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try fixture.git(["worktree", "add", "-q", "--detach", linked.path, "HEAD"])
        }
        let worktrees = try fixture.git(["worktree", "list", "--porcelain"])
        XCTAssertTrue(worktrees.contains(Data(first.path.utf8)))
        XCTAssertTrue(worktrees.contains(Data(second.path.utf8)))
        let app = try launchGraph(fixture)
        let badge = app.buttons.matching(NSPredicate(
            format: "label IN %@", ["main, Worktree", "main, 工作树"])).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 25))
        let history = historicalFile("shared-history.txt", in: app)
        badge.click()
        XCTAssertTrue(history.waitForExistence(timeout: 12),
                      "The shared HEAD branch badge must expand the real commit, not open a worktree")
        badge.click()
        XCTAssertTrue(history.waitForNonExistence(timeout: 12))

        badge.rightClick()
        let worktree = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Worktree", "工作树"])).firstMatch
        XCTAssertTrue(worktree.waitForExistence(timeout: 10))
        worktree.click()
        let firstPath = app.menuItems.matching(NSPredicate(
            format: "title == %@", "a904/Bailey")).firstMatch
        let secondPath = app.menuItems.matching(NSPredicate(
            format: "title == %@", "b905/Bailey")).firstMatch
        XCTAssertTrue(firstPath.waitForExistence(timeout: 8))
        XCTAssertTrue(secondPath.waitForExistence(timeout: 8),
                      "Same-name detached worktrees must retain unique navigable paths")
        firstPath.click()
        let opened = firstPath.descendants(matching: .menuItem).matching(NSPredicate(
            format: "title IN %@",
            ["Open Worktree", "在 Bailey 中打开工作树", "打开工作树"])).firstMatch
        let remover = firstPath.descendants(matching: .menuItem).matching(NSPredicate(
            format: "title IN %@", ["Remove Worktree…", "移除工作树…"])).firstMatch
        XCTAssertTrue(opened.waitForExistence(timeout: 8),
                      "The selected nested worktree must have its own Open action")
        XCTAssertTrue(remover.waitForExistence(timeout: 8),
                      "The selected nested worktree must have its own Remove action")
        XCTAssertTrue(remover.isEnabled,
                      "A clean detached linked worktree must remain removable")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
        XCTAssertEqual(try fixture.git(["worktree", "list", "--porcelain"]), worktrees)
    }

    func testShortHashCopiesActualOIDWithoutExpandingGitCommit() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("copy-hash.txt", text: "read-only history\n")
        try fixture.initializeGit()
        let head = String(decoding: try fixture.git(["rev-parse", "HEAD"]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = try WorkspaceUITestSupport.clipboardItems()
        addTeardownBlock { @MainActor in
            NSPasteboard.general.clearContents()
            if !previous.isEmpty { XCTAssertTrue(NSPasteboard.general.writeObjects(previous)) }
        }
        NSPasteboard.general.clearContents()
        let app = try launchGraph(fixture)
        let commit = app.buttons.matching(NSPredicate(
            format: "label == %@", "E2E fixture history")).firstMatch
        let hashButton = app.buttons.matching(NSPredicate(
            format: "label IN %@", ["Copy Commit Hash", "复制提交哈希", "复制提交散列"])).firstMatch
        let file = historicalFile("copy-hash.txt", in: app)
        XCTAssertTrue(commit.waitForExistence(timeout: 25))
        XCTAssertFalse(file.exists)
        let expansionBeforeCopy = commit.value as? String
        guard hashButton.waitForExistence(timeout: 12) else {
            XCTFail("The short hash must be an independently accessible Copy button")
            return
        }
        hashButton.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), head,
                       "Clicking the short hash must copy the immutable full OID")
        XCTAssertFalse(file.exists,
                       "Copying the short OID must not expand the selected commit")
        XCTAssertEqual(commit.value as? String, expansionBeforeCopy,
                       "Copy must not change the commit expansion state")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), Data((head + "\n").utf8))
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
    }

    func testSymbolicRemoteAliasCannotOfferDestructiveBranchActions() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("alias.txt", text: "real remote ref\n")
        try fixture.initializeGit()
        try fixture.git(["remote", "add", "upstream", fixture.root.path])
        try fixture.git(["update-ref", "refs/remotes/upstream/main", "HEAD"])
        try fixture.git(["symbolic-ref", "refs/remotes/upstream/HEAD",
                         "refs/remotes/upstream/main"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        XCTAssertEqual(try fixture.git(["symbolic-ref", "refs/remotes/upstream/HEAD"]),
                       Data("refs/remotes/upstream/main\n".utf8))
        let prior = try WorkspaceUITestSupport.clipboardItems()
        addTeardownBlock { @MainActor in
            NSPasteboard.general.clearContents()
            if !prior.isEmpty { XCTAssertTrue(NSPasteboard.general.writeObjects(prior)) }
        }
        let app = try launchGraph(fixture)
        let overflow = app.menuButtons.matching(NSPredicate(
            format: "title CONTAINS %@ AND title CONTAINS %@",
            "upstream/HEAD", "upstream/main")).firstMatch
        guard overflow.waitForExistence(timeout: 25) else {
            XCTFail("Actual symbolic alias and branch must both remain in the +N overflow")
            return
        }
        overflow.click()
        let alias = app.menuItems.matching(NSPredicate(
            format: "title == %@", "upstream/HEAD")).firstMatch
        XCTAssertTrue(alias.waitForExistence(timeout: 8))
        alias.click()
        let copy = alias.descendants(matching: .menuItem).matching(NSPredicate(
            format: "title IN %@", ["Copy Remote Branch Name", "复制远端分支名称"])).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 8),
                      "The selected symbolic alias must expose a Copy-only native menu")
        let unsafe = alias.descendants(matching: .menuItem).matching(NSPredicate(
            format: "title IN %@", ["Delete Remote Branch…", "删除远端分支…",
                                   "Checkout Remote Branch…", "检出远端分支…"])).firstMatch
        XCTAssertFalse(unsafe.exists,
                       "Remote HEAD is symbolic, not a deletable or checkout target")
        copy.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "upstream/HEAD")

        overflow.click()
        let actual = app.menuItems.matching(NSPredicate(
            format: "title == %@", "upstream/main")).firstMatch
        XCTAssertTrue(actual.waitForExistence(timeout: 8))
        actual.click()
        let delete = actual.descendants(matching: .menuItem).matching(NSPredicate(
            format: "title IN %@", ["Delete Remote Branch…", "删除远端分支…"])).firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 8),
                      "The ordinary real remote branch must retain its applicable actions")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/remotes/upstream/main"]), head)
        XCTAssertEqual(try fixture.git(["symbolic-ref", "refs/remotes/upstream/HEAD"]),
                       Data("refs/remotes/upstream/main\n".utf8))
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
    }

    func testRealMergeShowsBothParentHistoriesAndTheirOwnFileDiffs() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("base.txt", text: "common base\n")
        try fixture.initializeGit()
        let base = try fixture.git(["rev-parse", "HEAD"])
        try fixture.git(["config", "user.name", "BaileyUITest"])
        try fixture.git(["config", "user.email", "tests@example.invalid"])
        try fixture.git(["branch", "topic/merge"])
        try fixture.git(["switch", "-q", "topic/merge"])
        _ = try fixture.file("feature/path.txt", text: "feature path\n")
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-qm", "Feature parent revision"])
        let feature = try fixture.git(["rev-parse", "HEAD"])
        try fixture.git(["switch", "-q", "main"])
        _ = try fixture.file("main/path.txt", text: "main path\n")
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-qm", "Main parent revision"])
        let mainParent = try fixture.git(["rev-parse", "HEAD"])
        try fixture.git(["merge", "--no-ff", "-m", "Two-parent UI merge", "topic/merge"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        XCTAssertEqual(try fixture.git(["rev-list", "--parents", "-n", "1", "HEAD"])
            .split(separator: 0x20).count, 3,
                       "The real Git fixture must have exactly two non-first parents")
        XCTAssertNotEqual(feature, mainParent)
        XCTAssertNotEqual(base, feature)
        XCTAssertNotEqual(base, mainParent)

        let app = try launchGraph(fixture)
        let merge = app.buttons.matching(NSPredicate(
            format: "label == %@", "Two-parent UI merge")).firstMatch
        let featureRow = app.buttons.matching(NSPredicate(
            format: "label == %@", "Feature parent revision")).firstMatch
        let mainRow = app.buttons.matching(NSPredicate(
            format: "label == %@", "Main parent revision")).firstMatch
        XCTAssertTrue(merge.waitForExistence(timeout: 25))
        XCTAssertTrue(featureRow.waitForExistence(timeout: 12))
        XCTAssertTrue(mainRow.waitForExistence(timeout: 12))
        XCTAssertTrue(merge.isHittable)
        XCTAssertTrue(featureRow.isHittable)
        XCTAssertTrue(mainRow.isHittable)
        featureRow.click()
        let featureFile = historicalFile("feature/path.txt", in: app)
        XCTAssertTrue(featureFile.waitForExistence(timeout: 12),
                      "The merged second-parent line must have its own real historical file")
        featureFile.click()
        XCTAssertTrue(app.windows.firstMatch.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", "path.txt")).firstMatch.waitForExistence(timeout: 12))
        mainRow.click()
        let mainFile = historicalFile("main/path.txt", in: app)
        XCTAssertTrue(mainFile.waitForExistence(timeout: 12),
                      "The main first-parent line must preserve its separate real file")
        mainRow.click()
        XCTAssertTrue(mainFile.waitForNonExistence(timeout: 12))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/heads/topic/merge"]), feature)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
        XCTAssertEqual(try fixture.git(["show", "HEAD:feature/path.txt"]),
                       Data("feature path\n".utf8))
        XCTAssertEqual(try fixture.git(["show", "HEAD:main/path.txt"]),
                       Data("main path\n".utf8))
    }

    func testTwoRealBranchLanesPaintMatchingReferenceBadgesAndGraphNodes() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("common.txt", text: "base\n")
        try fixture.initializeGit()
        try fixture.git(["config", "user.name", "BaileyUITest"])
        try fixture.git(["config", "user.email", "tests@example.invalid"])
        try fixture.git(["branch", "topic/colors"])
        try fixture.git(["switch", "-q", "topic/colors"])
        _ = try fixture.file("feature.txt", text: "feature\n")
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-qm", "Feature color lane"])
        let featureOID = String(decoding: try fixture.git(["rev-parse", "HEAD"]),
                                as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.git(["switch", "-q", "main"])
        _ = try fixture.file("main.txt", text: "main\n")
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-qm", "Main color lane"])
        let mainOID = String(decoding: try fixture.git(["rev-parse", "HEAD"]),
                             as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let app = try launchGraph(fixture)
        func paintedColors(_ element: XCUIElement, leftFraction: CGFloat) throws -> [NSColor] {
            XCTAssertTrue(element.waitForExistence(timeout: 25))
            let data = try XCTUnwrap(element.screenshot().image.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            let maxX = max(1, Int(CGFloat(bitmap.pixelsWide) * leftFraction))
            var result: [NSColor] = []
            for x in 0..<maxX {
                for y in 0..<bitmap.pixelsHigh {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                        continue
                    }
                    let channels = [color.redComponent, color.greenComponent,
                                    color.blueComponent]
                    if channels.max()! - channels.min()! > 0.28 {
                        result.append(color)
                    }
                }
            }
            return result
        }
        func nearestDifference(_ a: [NSColor], _ b: [NSColor]) -> CGFloat {
            var best = CGFloat.infinity
            for first in a {
                for second in b {
                    let delta = abs(first.redComponent - second.redComponent)
                        + abs(first.greenComponent - second.greenComponent)
                        + abs(first.blueComponent - second.blueComponent)
                    best = min(best, delta)
                }
            }
            return best
        }
        // Compare the predominant painted node color, not the closest pair of
        // anti-aliased edge pixels (which can look almost identical across lanes).
        func dominantColor(_ pixels: [NSColor]) throws -> NSColor {
            var frequencies: [UInt32: Int] = [:]
            for pixel in pixels {
                let red = UInt32((pixel.redComponent * 255).rounded())
                let green = UInt32((pixel.greenComponent * 255).rounded())
                let blue = UInt32((pixel.blueComponent * 255).rounded())
                frequencies[(red << 16) | (green << 8) | blue, default: 0] += 1
            }
            let key = try XCTUnwrap(frequencies.max(by: { $0.value < $1.value })?.key)
            return NSColor(srgbRed: CGFloat((key >> 16) & 255) / 255,
                           green: CGFloat((key >> 8) & 255) / 255,
                           blue: CGFloat(key & 255) / 255, alpha: 1)
        }
        var nodeColors: [NSColor] = []
        for (branch, oid) in [("main", mainOID), ("topic/colors", featureOID)] {
            let badge = app.buttons.matching(NSPredicate(
                format: "label == %@ OR label BEGINSWITH %@",
                branch, branch + ", ")).firstMatch
            let node = app.buttons.matching(NSPredicate(
                format: "value == %@", oid)).firstMatch
            let badgePixels = try paintedColors(badge, leftFraction: 0.25)
            let nodePixels = try paintedColors(node, leftFraction: 1)
            XCTAssertFalse(badgePixels.isEmpty, "\(branch) must paint its colored icon background")
            XCTAssertFalse(nodePixels.isEmpty, "\(branch) must paint its actual colored graph node")
            let delta = nearestDifference(badgePixels, nodePixels)
            print("Git Graph color \(branch): badge=\(badgePixels.count), node=\(nodePixels.count), RGB delta=\(delta)")
            XCTAssertLessThan(delta, 0.32,
                              "\(branch) badge and DAG node must paint the same lane hue")
            nodeColors.append(try dominantColor(nodePixels))
        }
        XCTAssertEqual(nodeColors.count, 2)
        let first = nodeColors[0].usingColorSpace(.sRGB)!
        let second = nodeColors[1].usingColorSpace(.sRGB)!
        let separation = max(abs(first.redComponent - second.redComponent),
                             abs(first.greenComponent - second.greenComponent),
                             abs(first.blueComponent - second.blueComponent))
        XCTAssertGreaterThan(separation, 0.10,
                             "Divergent main and feature lanes must retain distinct painted colors")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), Data((mainOID + "\n").utf8))
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
    }

    func testLongChineseGraphTitleScrollsButShortTitleAndGraphRailsStayFixed() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("scroll.txt", text: "base\n")
        try fixture.initializeGit()
        try fixture.git(["config", "user.name", "BaileyUITest"])
        try fixture.git(["config", "user.email", "tests@example.invalid"])
        try fixture.git(["commit", "--allow-empty", "-qm", "Fix"])
        // Each segment must be unique: scrolling past repeated glyphs can yield identical pixels.
        let subject = (0..<48).map { "历史图谱第\($0)段超长中文提交消息–" }.joined()
        try fixture.git(["commit", "--allow-empty", "-qm", subject])
        let head = String(decoding: try fixture.git(["rev-parse", "HEAD"]),
                          as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let app = try launchGraph(fixture)
        let long = app.buttons.matching(NSPredicate(
            format: "label == %@", subject)).firstMatch
        let short = app.buttons.matching(NSPredicate(
            format: "label == %@", "Fix")).firstMatch
        let node = app.buttons.matching(NSPredicate(
            format: "value == %@", head)).firstMatch
        XCTAssertTrue(long.waitForExistence(timeout: 25))
        XCTAssertTrue(short.waitForExistence(timeout: 12))
        XCTAssertTrue(node.waitForExistence(timeout: 12))
        XCTAssertTrue(long.isHittable)
        let nodeX = node.frame.minX
        let longX = long.frame.minX
        func bitmapPixels(_ element: XCUIElement) throws -> Data {
            let tiff = try XCTUnwrap(element.screenshot().image.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
            let bytes = try XCTUnwrap(bitmap.bitmapData)
            return Data(bytes: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        long.scroll(byDeltaX: 0, deltaY: 0)
        let beforeLong = try bitmapPixels(long)
        long.scroll(byDeltaX: -460, deltaY: 0)
        let afterLong = try bitmapPixels(long)
        XCTAssertNotEqual(beforeLong, afterLong,
                          "Long Chinese commit subjects must actually scroll horizontally")
        XCTAssertEqual(long.frame.minX, longX, accuracy: 1)
        XCTAssertEqual(node.frame.minX, nodeX, accuracy: 1,
                       "Title scrolling must not move the DAG node or graph gutter")
        // Stabilize both the row hover state and graph keyboard focus first.
        // Comparing TIFF bytes before moving the pointer between rows tests hover,
        // not the horizontal bounce of the short native text viewport.
        short.click()
        short.click()
        let beforeShort = try bitmapPixels(short)
        short.scroll(byDeltaX: -460, deltaY: 0)
        let afterShort = try bitmapPixels(short)
        XCTAssertEqual(beforeShort, afterShort,
                       "A short subject must keep identical pixels after horizontal wheel input")
        XCTAssertEqual(node.frame.minX, nodeX, accuracy: 1)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), Data((head + "\n").utf8))
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
    }

    func testDeepChineseHistoricalFolderScrollsInsideRowWithoutMovingGraph() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        // Each APFS component and the full sandbox path must remain legal.
        let directory = String(repeating: "非常长的中文目录名称", count: 4)
        let path = (0..<6).map { "\(directory)-\($0)" }.joined(separator: "/")
            + "/final.swift"
        let file = try fixture.file(path, text: "let source = 42\n")
        try fixture.initializeGit()
        let head = String(decoding: try fixture.git(["rev-parse", "HEAD"]),
                          as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let app = try launchGraph(fixture)
        let commit = app.buttons.matching(NSPredicate(
            format: "label == %@", "E2E fixture history")).firstMatch
        let node = app.buttons.matching(NSPredicate(format: "value == %@", head)).firstMatch
        XCTAssertTrue(commit.waitForExistence(timeout: 25))
        XCTAssertTrue(node.waitForExistence(timeout: 10))
        commit.click()
        let folder = app.windows.firstMatch.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder").firstMatch
        guard folder.waitForExistence(timeout: 15) else {
            XCTFail("Deep actual Git paths must be represented as native folder rows")
            return
        }
        XCTAssertTrue(folder.isHittable)
        let gutterX = node.frame.minX
        let folderX = folder.frame.minX
        func pixels() throws -> Data {
            let tiff = try XCTUnwrap(folder.screenshot().image.tiffRepresentation)
            let image = try XCTUnwrap(NSBitmapImageRep(data: tiff))
            let base = try XCTUnwrap(image.bitmapData)
            return Data(bytes: base, count: image.bytesPerRow * image.pixelsHigh)
        }
        // The initial zero-delta input establishes the same hover state for
        // the two raster captures; a moving pointer is not horizontal scrolling.
        folder.scroll(byDeltaX: 0, deltaY: 0)
        let before = try pixels()
        folder.scroll(byDeltaX: -480, deltaY: 0)
        let after = try pixels()
        XCTAssertNotEqual(before, after,
                          "The very long native folder name must move inside its own text viewport")
        XCTAssertEqual(folder.frame.minX, folderX, accuracy: 1)
        XCTAssertEqual(node.frame.minX, gutterX, accuracy: 1,
                       "Folder text scrolling must not move the graph rails")
        let historical = historicalFile(path, in: app)
        XCTAssertTrue(historical.waitForExistence(timeout: 15),
                      "Deep history must keep its exact relative Git path")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), Data((head + "\n").utf8))
        XCTAssertEqual(try Data(contentsOf: file), Data("let source = 42\n".utf8))
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
    }

    func testUnbornEmptyRepositoryDoesNotInventCommitOrWorktreeGraphNodes() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        try fixture.git(["init", "-q", "-b", "main"])
        XCTAssertEqual(try fixture.git(["rev-list", "--all", "--count"]), Data("0\n".utf8))
        XCTAssertEqual(try fixture.git(["symbolic-ref", "--short", "HEAD"]),
                       Data("main\n".utf8))
        let app = try launchGraph(fixture)
        let gitPanel = WorkspaceUITestSupport.element("bailey.dock.git", in: app)
        XCTAssertTrue(gitPanel.waitForExistence(timeout: 20))
        XCTAssertTrue(app.windows.firstMatch.exists)
        let graph = app.buttons.matching(NSPredicate(
            format: "label == %@", "E2E fixture history")).firstMatch
        XCTAssertFalse(graph.exists,
                       "An unborn repo must not show fabricated commit history")
        let node = app.buttons.matching(NSPredicate(
            format: "value MATCHES %@", "[0-9a-f]{40}")).firstMatch
        XCTAssertFalse(node.exists, "An unborn repo must not draw a phantom Git OID")
        XCTAssertEqual(try fixture.git(["rev-list", "--all", "--count"]), Data("0\n".utf8))
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
    }

    func testHistoricalDiffRowRetainsSelectionFillAfterMovingFocusToEditor() throws {
        try verifyHistoricalSelection(theme: "light")
    }

    func testDarkHistoricalDiffRowRetainsSelectionFillAfterMovingFocusToEditor() throws {
        try verifyHistoricalSelection(theme: "dark")
    }

    private func verifyHistoricalSelection(theme: String) throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("selected-history.txt", text: "historical blob\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        let home = try WorkspaceUITestFixture(in: self)
        _ = try home.file(".config/bailey-dev/config.toml", text: "theme = \"\(theme)\"\n")
        let app = try launchGraph(fixture, configurationHome: home.root)
        let commit = app.buttons.matching(NSPredicate(
            format: "label == %@", "E2E fixture history")).firstMatch
        XCTAssertTrue(commit.waitForExistence(timeout: 25))
        commit.click()
        let row = historicalFile("selected-history.txt", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        func bitmap() throws -> NSBitmapImageRep {
            let tiff = try XCTUnwrap(row.screenshot().image.tiffRepresentation)
            return try XCTUnwrap(NSBitmapImageRep(data: tiff))
        }
        let plain = try bitmap()
        row.click()
        let layout = app.windows.firstMatch.radioGroups["bailey.diff.layout"]
        XCTAssertTrue(layout.waitForExistence(timeout: 15),
                      "The historical click must open a real native Git Diff")
        layout.radioButtons.firstMatch.click()  // Move focus away from the Git Graph.
        let selected = try bitmap()
        XCTAssertEqual(plain.pixelsWide, selected.pixelsWide)
        XCTAssertEqual(plain.pixelsHigh, selected.pixelsHigh)
        var largestChange: CGFloat = 0
        for fx in [0.83, 0.90, 0.97] {
            for fy in [0.25, 0.50, 0.75] {
                let x = Int(Double(plain.pixelsWide - 1) * fx)
                let y = Int(Double(plain.pixelsHigh - 1) * fy)
                guard let before = plain.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let after = selected.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                let delta = abs(before.redComponent - after.redComponent)
                    + abs(before.greenComponent - after.greenComponent)
                    + abs(before.blueComponent - after.blueComponent)
                largestChange = max(largestChange, delta)
            }
        }
        print("Git historical selected fill RGB delta: \(largestChange)")
        XCTAssertGreaterThan(largestChange, 0.045,
                             "The actual selected historical file must have a grey row fill")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
    }

    func testMainWorktreeThirdLevelMenuDisablesRemovalInNativeApp() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("main-owned.txt", text: "main-owned commit\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        let linked = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bailey-UITest-RootMenu-" + UUID().uuidString)
        addTeardownBlock {
            _ = try? fixture.git(["worktree", "remove", "--force", linked.path])
            try? FileManager.default.removeItem(at: linked)
        }
        try fixture.git(["worktree", "add", "-q", "--detach", linked.path, "HEAD"])
        let before = try fixture.git(["worktree", "list", "--porcelain"])
        let app = try launchGraph(fixture)
        let badge = app.buttons.matching(NSPredicate(
            format: "label IN %@", ["main, Worktree", "main, 工作树"])).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 25))
        badge.rightClick()
        let group = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Worktree", "工作树"])).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 8))
        group.click()
        // The app also keeps the same project name in its *hidden* project
        // menu. Match the visible second-level Worktree entry, not a global
        // menu-bar item with the same title and zero-sized frame.
        let mainPath = app.menuItems.matching(NSPredicate(
            format: "title == %@", fixture.root.lastPathComponent))
            .allElementsBoundByIndex.first { $0.frame.width > 0 }
        guard let mainPath else {
            XCTFail("The selected main Worktree must be visible in the second-level menu")
            return
        }
        mainPath.click()
        let available = mainPath.descendants(matching: .menuItem).matching(NSPredicate(
            format: "title IN %@", ["Open Worktree", "在 Bailey 中打开工作树"])).firstMatch
        let remove = mainPath.descendants(matching: .menuItem).matching(NSPredicate(
            format: "title IN %@", ["Remove Worktree…", "移除工作树…"])).firstMatch
        XCTAssertTrue(available.waitForExistence(timeout: 8))
        XCTAssertGreaterThan(available.frame.width, 0,
                             "The main checkout's own third-tier menu must really be open")
        XCTAssertTrue(remove.waitForExistence(timeout: 8))
        XCTAssertGreaterThan(remove.frame.width, 0)
        XCTAssertFalse(remove.isEnabled, "The current main worktree cannot be removed")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertEqual(try fixture.git(["worktree", "list", "--porcelain"]), before)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
    }

    func testOtherWorktreeStagedAndWorkingFilesPreserveDistinctDiffBaselines() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("other-stage.txt", text: "committed\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        let linked = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bailey-UITest-Staged-" + UUID().uuidString)
        addTeardownBlock {
            _ = try? fixture.git(["worktree", "remove", "--force", linked.path])
            try? FileManager.default.removeItem(at: linked)
        }
        try fixture.git(["worktree", "add", "-q", "-b", "topic/staged",
                         linked.path, "HEAD"])
        let file = linked.appendingPathComponent("other-stage.txt")
        try "index version\n".write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["-C", linked.path, "add", "--", "other-stage.txt"])
        try "working version\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try fixture.git(["-C", linked.path, "status", "--porcelain=v1"]),
                       Data("MM other-stage.txt\n".utf8))
        XCTAssertEqual(try fixture.git(["-C", linked.path, "show", ":other-stage.txt"]),
                       Data("index version\n".utf8))
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())

        let app = try launchGraph(fixture)
        let window = app.windows.firstMatch
        let node = app.buttons.matching(NSPredicate(format: "value == %@", linked.path)).firstMatch
        XCTAssertTrue(node.waitForExistence(timeout: 25))
        node.click()
        let rows = window.descendants(matching: .any)
            .matching(identifier: "bailey.tree.file")
            .matching(NSPredicate(format: "label ENDSWITH %@", ", other-stage.txt"))
        XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 15),
                      "One real file must have separate Staged and Changes rows in the worktree")
        func contents() -> Set<String> {
            Set(window.textViews.allElementsBoundByIndex.compactMap { $0.value as? String })
        }
        func requireDiff(_ original: String, _ modified: String) {
            let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let visible = contents()
                return visible.contains(original) && visible.contains(modified)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 15), .completed,
                           "The actual Diff must use the selected worktree stage and baseline")
        }
        rows.element(boundBy: 0).click()
        XCTAssertTrue(rows.element(boundBy: 0).isSelected,
                      "The staged Worktree file must use Git Graph Selection styling")
        let layout = window.radioGroups["bailey.diff.layout"]
        XCTAssertTrue(layout.waitForExistence(timeout: 15))
        layout.radioButtons.element(boundBy: 1).click()
        requireDiff("committed\n", "index version\n")

        rows.element(boundBy: 1).click()
        XCTAssertTrue(rows.element(boundBy: 1).isSelected)
        XCTAssertFalse(rows.element(boundBy: 0).isSelected,
                       "Changing Worktree file must not leave a second selected row")
        let mode = window.radioGroups["bailey.diff.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 15))
        mode.radioButtons.element(boundBy: 0).click()
        layout.radioButtons.element(boundBy: 1).click()
        requireDiff("index version\n", "working version\n")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["-C", linked.path, "rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["-C", linked.path, "status", "--porcelain=v1"]),
                       Data("MM other-stage.txt\n".utf8))
        XCTAssertEqual(try fixture.git(["-C", linked.path, "show", ":other-stage.txt"]),
                       Data("index version\n".utf8))
        XCTAssertEqual(try Data(contentsOf: file), Data("working version\n".utf8))
    }

    private func launchGraph(
        _ fixture: WorkspaceUITestFixture, configurationHome: URL? = nil, language: String? = nil
    ) throws -> XCUIApplication {
        let root = fixture.root.standardizedFileURL.path
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
        precondition(root.hasPrefix(temporary + "/Bailey-UITest-"),
                     "Git Graph tests may only access an isolated fixture")
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: language, configurationHome: configurationHome, project: fixture.root)
        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(WorkspaceUITestSupport.element("bailey.dock.git", in: app)
            .waitForExistence(timeout: 20))
        return app
    }

    private func historicalFile(_ path: String, in app: XCUIApplication) -> XCUIElement {
        app.windows.firstMatch.descendants(matching: .any)
            .matching(identifier: "bailey.git.history.file")
            .matching(NSPredicate(format: "label ENDSWITH %@", ", " + path)).firstMatch
    }
}
