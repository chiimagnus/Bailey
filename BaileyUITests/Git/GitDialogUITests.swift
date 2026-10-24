import Foundation
import XCTest

@MainActor
final class GitDialogUITests: XCTestCase {
    func testHistoricalBranchSheetCancelsThenCreatesAtChosenCommitWithoutCheckout() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("branch.txt", text: "root\n")
        try fixture.initializeGit()
        let original = try fixture.git(["rev-parse", "HEAD"])
        try "second\n".write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["-c", "user.name=BaileyUITest", "-c",
                         "user.email=tests@example.invalid", "commit", "-qam", "second revision"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        XCTAssertNotEqual(original, head)
        let app = try launchGit(fixture)

        func present() -> XCUIElement {
            openCommitMenu("E2E fixture history", in: app)
            let option = app.menuItems.matching(NSPredicate(format: "title IN %@",
                ["Create Branch at Commit…", "在此创建分支…"])).firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 10))
            option.click()
            let sheet = app.windows.firstMatch.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 15))
            return sheet
        }
        let first = present()
        let name = first.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        let checkout = first.checkBoxes.matching(NSPredicate(
            format: "title IN %@", ["Check out", "创建后检出"])).firstMatch
        XCTAssertTrue(checkout.waitForExistence(timeout: 8))
        XCTAssertEqual(String(describing: checkout.value ?? ""), "0",
                       "Creating a branch at an old commit must not checkout by default")
        let create = first.buttons.matching(NSPredicate(
            format: "title IN %@", ["Create Branch", "创建分支"])).firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 8))
        XCTAssertFalse(create.isEnabled, "An empty native branch name must disable confirmation")
        let cancel = first.buttons.matching(NSPredicate(
            format: "title IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8))
        cancel.click()
        XCTAssertTrue(first.waitForNonExistence(timeout: 10))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(String(decoding: try fixture.git(["branch", "--show-current"]), as: UTF8.self),
                       "main\n")
        XCTAssertThrowsError(try fixture.git(["rev-parse", "--verify", "refs/heads/ui-old-point"]))

        let second = present()
        let input = second.textFields.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        input.click()
        input.typeText("ui-old-point")
        let confirm = second.buttons.matching(NSPredicate(
            format: "title IN %@", ["Create Branch", "创建分支"])).firstMatch
        XCTAssertTrue(confirm.isEnabled)
        confirm.click()
        let created = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["rev-parse", "refs/heads/ui-old-point"])) == original
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [created], timeout: 25), .completed,
                       "The selected historical commit must be the new ref's target")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["branch", "--show-current"]), Data("main\n".utf8))
        XCTAssertEqual(try Data(contentsOf: file), Data("second\n".utf8))
        XCTAssertEqual(try fixture.git(["show", ":branch.txt"]), Data("second\n".utf8))
    }

    func testStashNativeApplyDropAndBranchUseSelectedOlderEntry() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("stash-branch.txt", text: "base\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        for message in ["first", "second"] {
            try (message + "\n").write(to: file, atomically: true, encoding: .utf8)
            try fixture.git(["add", "--", "stash-branch.txt"])
            try fixture.git(["stash", "push", "-m", message])
        }
        let older = try fixture.git(["rev-parse", "stash@{1}"])
        let newest = try fixture.git(["rev-parse", "stash@{0}"])
        let app = try launchGit(fixture)
        func present(_ names: [String]) -> XCUIElement {
            let badge = app.buttons.matching(NSPredicate(
                format: "label CONTAINS %@", "stash@{1}")).firstMatch
            XCTAssertTrue(badge.waitForExistence(timeout: 25))
            badge.rightClick()
            let item = app.menuItems.matching(NSPredicate(format: "title IN %@", names)).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 8))
            item.click()
            let sheet = app.windows.firstMatch.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 15))
            return sheet
        }
        func cancel(_ sheet: XCUIElement) {
            let button = sheet.buttons.matching(NSPredicate(
                format: "title IN %@", ["Cancel", "取消"])).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 8))
            button.click()
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
        }

        let apply = present(["Apply Stash…", "应用储藏…"])
        let index = apply.checkBoxes.matching(NSPredicate(
            format: "title IN %@", ["Reinstate Index", "恢复暂存状态"])).firstMatch
        XCTAssertTrue(index.waitForExistence(timeout: 8))
        XCTAssertEqual(String(describing: index.value ?? ""), "0")
        cancel(apply)
        let drop = present(["Drop Stash…", "删除储藏…"])
        XCTAssertTrue(drop.buttons.matching(NSPredicate(
            format: "title IN %@", ["Yes, Drop", "是，删除"])).firstMatch.waitForExistence(timeout: 8))
        cancel(drop)
        let branch = present(["Create Branch from Stash…", "从储藏创建分支…"])
        let stashOID = String(decoding: older, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for detail in ["stash@{1}", stashOID] {
            XCTAssertTrue(branch.staticTexts.matching(NSPredicate(
                format: "value CONTAINS %@", detail)).firstMatch.waitForExistence(timeout: 8),
                "The confirmation must identify the selected stash and its immutable OID")
        }
        let input = branch.textFields.firstMatch
        let submit = branch.buttons.matching(NSPredicate(
            format: "title IN %@", ["Create Branch", "创建分支"])).firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        XCTAssertTrue(submit.waitForExistence(timeout: 8))
        XCTAssertFalse(submit.isEnabled)
        input.click()
        input.typeText("  ")
        XCTAssertFalse(submit.isEnabled)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(branch.waitForNonExistence(timeout: 10),
                      "Escape must dismiss the destructive native form")
        XCTAssertEqual(try fixture.git(["rev-parse", "stash@{0}"]), newest)
        XCTAssertEqual(try fixture.git(["rev-parse", "stash@{1}"]), older)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try Data(contentsOf: file), Data("base\n".utf8))

        let confirmed = present(["Create Branch from Stash…", "从储藏创建分支…"])
        let name = confirmed.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.click()
        name.typeText("ui-stash-older")
        let create = confirmed.buttons.matching(NSPredicate(
            format: "title IN %@", ["Create Branch", "创建分支"])).firstMatch
        XCTAssertTrue(create.isEnabled)
        create.click()
        let branched = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["branch", "--show-current"])) == Data("ui-stash-older\n".utf8)
                && (try? Data(contentsOf: file)) == Data("first\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [branched], timeout: 25), .completed)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["rev-parse", "stash@{0}"]), newest)
        XCTAssertThrowsError(try fixture.git(["rev-parse", "stash@{1}"]))
        XCTAssertEqual(try fixture.git(["show", ":stash-branch.txt"]), Data("first\n".utf8))
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]),
                       Data("M  stash-branch.txt\n".utf8))
    }

    func testOlderStashNativePopCancelAndReinstateIndexUseCapturedOID() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("stash.txt", text: "base\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        for message in ["first", "second"] {
            try (message + "\n").write(to: file, atomically: true, encoding: .utf8)
            try fixture.git(["add", "--", "stash.txt"])
            try fixture.git(["stash", "push", "-m", message])
        }
        let older = try fixture.git(["rev-parse", "stash@{1}"])
        let newest = try fixture.git(["rev-parse", "stash@{0}"])
        XCTAssertNotEqual(older, newest)
        XCTAssertEqual(try fixture.git(["show", ":stash.txt"]), Data("base\n".utf8))
        let app = try launchGit(fixture)

        func presentOlderPop() -> XCUIElement {
            let badge = app.buttons.matching(NSPredicate(
                format: "label CONTAINS %@", "stash@{1}")).firstMatch
            XCTAssertTrue(badge.waitForExistence(timeout: 25),
                          "Git Graph must expose the second, not just the newest, stash")
            badge.rightClick()
            let pop = app.menuItems.matching(NSPredicate(
                format: "title IN %@", ["Pop Stash…", "弹出储藏…"])).firstMatch
            XCTAssertTrue(pop.waitForExistence(timeout: 10))
            pop.click()
            let sheet = app.windows.firstMatch.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 15))
            return sheet
        }
        let cancelled = presentOlderPop()
        let reinstate = cancelled.checkBoxes.matching(NSPredicate(
            format: "title IN %@", ["Reinstate Index", "恢复暂存状态"])).firstMatch
        XCTAssertTrue(reinstate.waitForExistence(timeout: 8))
        XCTAssertEqual(String(describing: reinstate.value ?? ""), "0",
                       "The native Stash pop must not unexpectedly restore staged bits")
        let cancel = cancelled.buttons.matching(NSPredicate(
            format: "title IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8))
        cancel.click()
        XCTAssertTrue(cancelled.waitForNonExistence(timeout: 10))
        XCTAssertEqual(try fixture.git(["rev-parse", "stash@{0}"]), newest)
        XCTAssertEqual(try fixture.git(["rev-parse", "stash@{1}"]), older)
        XCTAssertEqual(try Data(contentsOf: file), Data("base\n".utf8))
        XCTAssertEqual(try fixture.git(["show", ":stash.txt"]), Data("base\n".utf8))

        let chosen = presentOlderPop()
        let restore = chosen.checkBoxes.matching(NSPredicate(
            format: "title IN %@", ["Reinstate Index", "恢复暂存状态"])).firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 8))
        restore.click()
        XCTAssertEqual(String(describing: restore.value ?? ""), "1")
        let confirm = chosen.buttons.matching(NSPredicate(
            format: "title IN %@", ["Yes, Pop Stash", "是，弹出储藏"])).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 8))
        confirm.click()
        let popped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["show", ":stash.txt"])) == Data("first\n".utf8)
                && (try? Data(contentsOf: file)) == Data("first\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [popped], timeout: 25), .completed)
        XCTAssertEqual(try fixture.git(["rev-parse", "stash@{0}"]), newest)
        XCTAssertThrowsError(try fixture.git(["rev-parse", "stash@{1}"]))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]),
                       Data("M  stash.txt\n".utf8))
    }

    func testCurrentBranchNativeSheetDefaultsToCheckoutAndPreservesGitBytes() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("branch.txt", text: "committed\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        let app = try launchGit(fixture)
        let selector = app.menuButtons.matching(identifier: "arrow.triangle.branch").firstMatch
        XCTAssertTrue(selector.waitForExistence(timeout: 20))
        selector.click()
        let create = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Create New Branch…", "创建新分支…"])).firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 8))
        create.click()
        let sheet = app.windows.firstMatch.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 15))
        let checkout = sheet.checkBoxes.matching(NSPredicate(
            format: "title IN %@", ["Check out", "创建后检出"])).firstMatch
        XCTAssertTrue(checkout.waitForExistence(timeout: 8))
        XCTAssertEqual(String(describing: checkout.value ?? ""), "1",
                       "Creating from HEAD must default to checking out the new branch")
        let confirm = sheet.buttons.matching(NSPredicate(
            format: "title IN %@", ["Create Branch", "创建分支"])).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 8))
        XCTAssertFalse(confirm.isEnabled)
        let name = sheet.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.click()
        name.typeText("feature-current-e2e")
        XCTAssertTrue(confirm.isEnabled)
        confirm.click()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["branch", "--show-current"])) == Data("feature-current-e2e\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 25), .completed)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/heads/feature-current-e2e"]), head)
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/heads/main"]), head)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
        XCTAssertEqual(try Data(contentsOf: file), Data("committed\n".utf8))
    }

    func testBranchRenameFromNativeRefMenuPreservesGitBytes() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("rename.txt", text: "original\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        let app = try launchGit(fixture)
        let badge = app.buttons.matching(NSPredicate(
            format: "label IN %@", ["main, Worktree", "main, 工作树"])).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 25),
                      "Git Graph must show a context menu for the checked-out branch")
        badge.rightClick()
        let rename = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Rename Branch…", "重命名分支…"])).firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 8))
        rename.click()
        let sheet = app.windows.firstMatch.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 15))
        let name = sheet.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        XCTAssertEqual(name.value as? String, "main")
        name.click()
        app.typeKey("a", modifierFlags: .command)
        name.typeText("feature-gui-rename")
        let submitRename = sheet.buttons.matching(NSPredicate(
            format: "title IN %@", ["Rename Branch", "重命名分支"])).firstMatch
        XCTAssertTrue(submitRename.waitForExistence(timeout: 8))
        XCTAssertTrue(submitRename.isEnabled)
        submitRename.click()
        let renamed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["branch", "--show-current"])) == Data("feature-gui-rename\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [renamed], timeout: 25), .completed)
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/heads/feature-gui-rename"]), head)
        XCTAssertThrowsError(try fixture.git(["rev-parse", "--verify", "refs/heads/main"]))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
        XCTAssertEqual(try Data(contentsOf: file), Data("original\n".utf8))
        XCTAssertEqual(try fixture.git(["remote"]), Data())
    }

    func testLateBranchAndTagCollisionPreserveRetryInputsWithoutOverwritingRefs() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("late-collision.txt", text: "initial\n")
        try fixture.initializeGit()
        let original = try fixture.git(["rev-parse", "HEAD"])
        try "later\n".write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["-c", "user.name=BaileyUITest", "-c",
                         "user.email=tests@example.invalid", "commit", "-qam", "later HEAD"])
        let current = try fixture.git(["rev-parse", "HEAD"])
        let app = try launchGit(fixture)
        for isTag in [false, true] {
            let name = isTag ? "ui-late-tag" : "ui-late-branch"
            let ref = (isTag ? "refs/tags/" : "refs/heads/") + name
            openCommitMenu("E2E fixture history", in: app)
            let createMenu = isTag
                ? ["Create Tag at Commit…", "在此创建标签…"]
                : ["Create Branch at Commit…", "在此创建分支…"]
            let menu = app.menuItems.matching(NSPredicate(
                format: "title IN %@", createMenu)).firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 8))
            menu.click()
            let createdSheet = app.windows.firstMatch.sheets.firstMatch
            XCTAssertTrue(createdSheet.waitForExistence(timeout: 15))
            let input = createdSheet.textFields.firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 8))
            input.click()
            input.typeText(name)
            if isTag {
                let annotation = createdSheet.textViews.firstMatch
                XCTAssertTrue(annotation.waitForExistence(timeout: 8))
                annotation.click()
                annotation.typeText("late collision annotation")
            } else {
                let checkout = createdSheet.checkBoxes.matching(NSPredicate(
                    format: "title IN %@", ["Check out", "创建后检出"])).firstMatch
                XCTAssertTrue(checkout.waitForExistence(timeout: 8))
                XCTAssertEqual(String(describing: checkout.value ?? ""), "0")
            }
            XCTAssertThrowsError(try fixture.git(["rev-parse", "--verify", ref]))
            try fixture.git(["update-ref", ref, String(decoding: current, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)])
            let create = createdSheet.buttons.matching(NSPredicate(format: "title IN %@",
                isTag ? ["Add Tag", "添加标签"] : ["Create Branch", "创建分支"])).firstMatch
            XCTAssertTrue(create.waitForExistence(timeout: 8))
            create.click()
            let collision = app.windows.firstMatch.sheets.firstMatch
            let choose = collision.buttons.matching(NSPredicate(format: "title IN %@",
                ["Choose Another Name", "选择其他名称"])).firstMatch
            XCTAssertTrue(choose.waitForExistence(timeout: 20),
                          "An external ref created after Sheet presentation must offer a retry")
            choose.click()
            let retry = app.windows.firstMatch.sheets.firstMatch
            let retryName = retry.textFields.firstMatch
            XCTAssertTrue(retryName.waitForExistence(timeout: 12))
            XCTAssertEqual(retryName.value as? String, name)
            if isTag {
                let message = retry.textViews.firstMatch
                XCTAssertTrue(message.waitForExistence(timeout: 8))
                XCTAssertEqual(message.value as? String, "late collision annotation")
            } else {
                let checkout = retry.checkBoxes.matching(NSPredicate(
                    format: "title IN %@", ["Check out", "创建后检出"])).firstMatch
                XCTAssertTrue(checkout.waitForExistence(timeout: 8))
                XCTAssertEqual(String(describing: checkout.value ?? ""), "0")
            }
            let cancel = retry.buttons.matching(NSPredicate(
                format: "title IN %@", ["Cancel", "取消"])).firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 8))
            cancel.click()
            XCTAssertTrue(retry.waitForNonExistence(timeout: 10))
            XCTAssertEqual(try fixture.git(["rev-parse", ref]), current)
            XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), current)
            XCTAssertEqual(try fixture.git(["rev-parse", "refs/heads/main"]), current)
            XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
            XCTAssertEqual(try Data(contentsOf: file), Data("later\n".utf8))
            XCTAssertNotEqual(original, current)
        }
    }

    func testHistoricalTagReplacementRejectsMovedRefAndRetainsAnnotation() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("tag-replace.txt", text: "selected\n")
        try fixture.initializeGit()
        try fixture.git(["config", "user.name", "BaileyUITest"])
        try fixture.git(["config", "user.email", "tests@example.invalid"])
        let selected = try fixture.git(["rev-parse", "HEAD"])
        try "existing\n".write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["commit", "-qam", "tag previously created"])
        let existing = try fixture.git(["rev-parse", "HEAD"])
        let ref = "refs/tags/ui-replace-tag"
        try fixture.git(["tag", "-a", "-m", "old annotation", "ui-replace-tag",
                         String(decoding: existing, as: UTF8.self)
                             .trimmingCharacters(in: .whitespacesAndNewlines)])
        let oldOID = try fixture.git(["rev-parse", ref])
        try "moved\n".write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["commit", "-qam", "new HEAD"])
        let moved = try fixture.git(["rev-parse", "HEAD"])
        let app = try launchGit(fixture, language: "en")

        func presentCreate() -> XCUIElement {
            openCommitMenu("E2E fixture history", in: app)
            let item = app.menuItems.matching(NSPredicate(format: "title IN %@",
                ["Create Tag at Commit…", "在此创建标签…"])).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 8))
            item.click()
            let sheet = app.windows.firstMatch.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 15))
            let name = sheet.textFields.firstMatch
            let note = sheet.textViews.firstMatch
            XCTAssertTrue(name.waitForExistence(timeout: 8))
            XCTAssertTrue(note.waitForExistence(timeout: 8))
            name.click()
            name.typeText("ui-replace-tag")
            note.click()
            note.typeText("E2E annotation retained")
            let create = sheet.buttons.matching(NSPredicate(format: "title IN %@",
                ["Add Tag", "添加标签"])).firstMatch
            XCTAssertTrue(create.waitForExistence(timeout: 8))
            create.click()
            let replacement = app.windows.firstMatch.sheets.firstMatch
            let button = replacement.buttons.matching(NSPredicate(format: "title IN %@",
                ["Replace Existing Tag", "替换已有标签"])).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 15))
            return replacement
        }

        let first = presentCreate()
        let choose = first.buttons.matching(NSPredicate(format: "title IN %@",
            ["Choose Another Name", "选择其他名称"])).firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 8))
        choose.click()
        let retry = app.windows.firstMatch.sheets.firstMatch
        let name = retry.textFields.firstMatch
        let annotation = retry.textViews.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 12))
        XCTAssertTrue(annotation.waitForExistence(timeout: 8))
        XCTAssertEqual(name.value as? String, "ui-replace-tag")
        XCTAssertEqual(annotation.value as? String, "E2E annotation retained")
        let type = retry.popUpButtons.firstMatch
        XCTAssertTrue(type.waitForExistence(timeout: 8))
        XCTAssertTrue(["Annotated", "带注释标签"].contains(type.value as? String ?? ""))
        let cancel = retry.buttons.matching(NSPredicate(format: "title IN %@",
            ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8))
        cancel.click()
        XCTAssertTrue(retry.waitForNonExistence(timeout: 10))
        XCTAssertEqual(try fixture.git(["rev-parse", ref]), oldOID)

        let stale = presentCreate()
        try fixture.git(["update-ref", ref, String(decoding: moved, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)])
        XCTAssertEqual(try fixture.git(["rev-parse", ref]), moved)
        stale.buttons.matching(NSPredicate(format: "title IN %@",
            ["Replace Existing Tag", "替换已有标签"])).firstMatch.click()
        XCTAssertTrue(stale.waitForNonExistence(timeout: 10))
        let unexpectedMutation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["rev-parse", ref])) != moved
        }, object: nil)
        unexpectedMutation.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unexpectedMutation], timeout: 2), .completed,
                       "Stale tag confirmation must never overwrite externally changed OID")
        XCTAssertEqual(try fixture.git(["rev-parse", ref]), moved)

        let fresh = presentCreate()
        let replace = fresh.buttons.matching(NSPredicate(format: "title IN %@",
            ["Replace Existing Tag", "替换已有标签"])).firstMatch
        XCTAssertTrue(replace.waitForExistence(timeout: 8))
        replace.click()
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["rev-parse", ref + "^{commit}"])) == selected
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 25), .completed)
        XCTAssertEqual(try fixture.git(["cat-file", "-t", ref]), Data("tag\n".utf8))
        XCTAssertTrue(String(decoding: try fixture.git(["cat-file", "-p", ref]),
                             as: UTF8.self).contains("E2E annotation retained"))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), moved)
        XCTAssertEqual(try Data(contentsOf: file), Data("moved\n".utf8))
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
    }

    func testHistoricalBranchReplacementRejectsMovedRefAndPreservesRetryName() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("replacement.txt", text: "selected\n")
        try fixture.initializeGit()
        let selected = try fixture.git(["rev-parse", "HEAD"])
        try "existing\n".write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["-c", "user.name=BaileyUITest", "-c",
                         "user.email=tests@example.invalid", "commit", "-qam", "existing revision"])
        let existing = try fixture.git(["rev-parse", "HEAD"])
        try "moved\n".write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["-c", "user.name=BaileyUITest", "-c",
                         "user.email=tests@example.invalid", "commit", "-qam", "externally moved"])
        let moved = try fixture.git(["rev-parse", "HEAD"])
        let ref = "refs/heads/ui-replace-branch"
        try fixture.git(["update-ref", ref, String(decoding: existing, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)])
        let app = try launchGit(fixture)
        func presentCreate() -> XCUIElement {
            openCommitMenu("E2E fixture history", in: app)
            let item = app.menuItems.matching(NSPredicate(format: "title IN %@",
                ["Create Branch at Commit…", "在此创建分支…"])).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 8))
            item.click()
            let sheet = app.windows.firstMatch.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 15))
            let input = sheet.textFields.firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 8))
            input.click()
            input.typeText("ui-replace-branch")
            let checkout = sheet.checkBoxes.matching(NSPredicate(format: "title IN %@",
                ["Check out", "创建后检出"])).firstMatch
            XCTAssertTrue(checkout.waitForExistence(timeout: 8))
            XCTAssertEqual(String(describing: checkout.value ?? ""), "0")
            let create = sheet.buttons.matching(NSPredicate(format: "title IN %@",
                ["Create Branch", "创建分支"])).firstMatch
            XCTAssertTrue(create.waitForExistence(timeout: 8))
            create.click()
            let replacement = app.windows.firstMatch.sheets.firstMatch
            let replace = replacement.buttons.matching(NSPredicate(format: "title IN %@",
                ["Replace Existing Branch", "替换已有分支"])).firstMatch
            XCTAssertTrue(replace.waitForExistence(timeout: 15))
            return replacement
        }
        let first = presentCreate()
        let choose = first.buttons.matching(NSPredicate(format: "title IN %@",
            ["Choose Another Name", "选择其他名称"])).firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 8))
        choose.click()
        let retry = app.windows.firstMatch.sheets.firstMatch
        let input = retry.textFields.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 12))
        XCTAssertEqual(input.value as? String, "ui-replace-branch")
        let checkout = retry.checkBoxes.matching(NSPredicate(
            format: "title IN %@", ["Check out", "创建后检出"])).firstMatch
        XCTAssertEqual(String(describing: checkout.value ?? ""), "0")
        let cancel = retry.buttons.matching(NSPredicate(
            format: "title IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8))
        cancel.click()
        XCTAssertTrue(retry.waitForNonExistence(timeout: 10))
        XCTAssertEqual(try fixture.git(["rev-parse", ref]), existing)

        let stale = presentCreate()
        try fixture.git(["update-ref", ref, String(decoding: moved, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)])
        XCTAssertEqual(try fixture.git(["rev-parse", ref]), moved)
        let replaceStale = stale.buttons.matching(NSPredicate(format: "title IN %@",
            ["Replace Existing Branch", "替换已有分支"])).firstMatch
        replaceStale.click()
        XCTAssertTrue(stale.waitForNonExistence(timeout: 10))
        let unexpectedMutation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["rev-parse", ref])) != moved
        }, object: nil)
        unexpectedMutation.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unexpectedMutation], timeout: 2), .completed,
                       "A delayed stale Git mutation must not overwrite the externally moved ref")
        XCTAssertEqual(try fixture.git(["rev-parse", ref]), moved,
                       "A stale confirmation must not replace an externally moved ref")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), moved)

        let fresh = presentCreate()
        let replaceFresh = fresh.buttons.matching(NSPredicate(format: "title IN %@",
            ["Replace Existing Branch", "替换已有分支"])).firstMatch
        XCTAssertTrue(replaceFresh.waitForExistence(timeout: 8))
        replaceFresh.click()
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["rev-parse", ref])) == selected
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 25), .completed)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), moved)
        XCTAssertEqual(try fixture.git(["branch", "--show-current"]), Data("main\n".utf8))
        XCTAssertEqual(try Data(contentsOf: file), Data("moved\n".utf8))
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
    }

    func testDropCommitNativeConfirmationCancelsThenRewritesOnlySelectedHistory() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("root.txt", text: "root\n")
        try fixture.initializeGit()
        let base = try fixture.git(["rev-parse", "HEAD"])
        try fixture.git(["config", "user.name", "BaileyUITest"])
        try fixture.git(["config", "user.email", "tests@example.invalid"])
        let middle = try fixture.file("to-drop.txt", text: "remove this\n")
        try fixture.git(["add", "to-drop.txt"])
        try fixture.git(["commit", "-qm", "middle to drop"])
        let selected = try fixture.git(["rev-parse", "HEAD"])
        let last = try fixture.file("keep.txt", text: "keep this\n")
        try fixture.git(["add", "keep.txt"])
        try fixture.git(["commit", "-qm", "head to keep"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        let app = try launchGit(fixture)
        func present() -> XCUIElement {
            openCommitMenu("middle to drop", in: app)
            let item = app.menuItems.matching(NSPredicate(format: "title IN %@",
                ["Drop Commit…", "删除提交…"])).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 8))
            item.click()
            let sheet = app.windows.firstMatch.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 15))
            let drop = sheet.buttons.matching(NSPredicate(format: "title IN %@",
                ["Yes, Drop", "是，删除"])).firstMatch
            XCTAssertTrue(drop.waitForExistence(timeout: 8))
            XCTAssertTrue(drop.isEnabled)
            return sheet
        }
        let initial = present()
        let cancel = initial.buttons.matching(NSPredicate(format: "title IN %@",
            ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8))
        cancel.click()
        XCTAssertTrue(initial.waitForNonExistence(timeout: 10))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD^"]), selected)
        XCTAssertEqual(try Data(contentsOf: middle), Data("remove this\n".utf8))
        let confirmed = present()
        let drop = confirmed.buttons.matching(NSPredicate(format: "title IN %@",
            ["Yes, Drop", "是，删除"])).firstMatch
        drop.click()
        let rewritten = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["rev-parse", "HEAD^"])) == base
                && (try? fixture.git(["log", "-1", "--format=%s"])) == Data("head to keep\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rewritten], timeout: 25), .completed)
        XCTAssertNotEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertFalse(FileManager.default.fileExists(atPath: middle.path))
        XCTAssertEqual(try Data(contentsOf: last), Data("keep this\n".utf8))
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
    }

    func testInteractiveRebaseFromGitGraphOpensRealPTYAndAcceptsEditorInput() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("base.txt", text: "base\n")
        try fixture.initializeGit()
        try fixture.git(["config", "user.name", "BaileyUITest"])
        try fixture.git(["config", "user.email", "tests@example.invalid"])
        try fixture.git(["switch", "-c", "side"])
        _ = try fixture.file("side.txt", text: "side\n")
        try fixture.git(["add", "side.txt"])
        try fixture.git(["commit", "-qm", "side for interactive rebase"])
        let side = try fixture.git(["rev-parse", "HEAD"])
        try fixture.git(["switch", "main"])
        _ = try fixture.file("main.txt", text: "main\n")
        try fixture.git(["add", "main.txt"])
        try fixture.git(["commit", "-qm", "main before interactive rebase"])
        let oldHead = try fixture.git(["rev-parse", "HEAD"])
        // Git runs the editor in Bailey Dev, which cannot exec files inside the UI runner container.
        let marker = fixture.root.appendingPathComponent(".git/e2e-editor-ready")
        let script = "printf '%s\\n' \"$PWD\" > '" + marker.path
            + "'\n[ -t 0 ] || exit 71\nprintf 'PTY\\n' >> '" + marker.path
            + "'\nprintf 'BAILEY_SEQUENCE_EDITOR_READY\\n'\nread -r response\n"
        let editor = "/bin/sh -c '" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try fixture.git(["config", "sequence.editor", editor])
        let app = try launchGit(fixture)
        openCommitMenu("side for interactive rebase", in: app)
        let option = app.menuItems.matching(NSPredicate(format: "title IN %@",
            ["Rebase Current Branch onto Commit…", "将当前分支变基到提交…"])).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 8))
        option.click()
        let sheet = app.windows.firstMatch.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 15))
        let interactive = sheet.checkBoxes.matching(NSPredicate(format: "title IN %@",
            ["Launch Interactive Rebase in New Terminal", "在新终端启动交互式变基"])).firstMatch
        XCTAssertTrue(interactive.waitForExistence(timeout: 8))
        XCTAssertEqual(String(describing: interactive.value ?? ""), "0")
        interactive.click()
        XCTAssertEqual(String(describing: interactive.value ?? ""), "1")
        let confirm = sheet.buttons.matching(NSPredicate(format: "title IN %@",
            ["Yes, Rebase", "是，变基"])).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 8))
        confirm.click()
        let launched = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: marker, encoding: .utf8)) == fixture.root.path + "\nPTY\n"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [launched], timeout: 30), .completed,
                       "The real GUI must start Git's sequence editor on an actual PTY")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), oldHead,
                       "History must stay unchanged until the terminal editor accepts input")
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["rev-parse", "HEAD^"])) == side
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 30), .completed)
        XCTAssertNotEqual(try fixture.git(["rev-parse", "HEAD"]), oldHead)
        XCTAssertEqual(try fixture.git(["show", "HEAD:main.txt"]), Data("main\n".utf8))
        XCTAssertEqual(try fixture.git(["show", "HEAD:side.txt"]), Data("side\n".utf8))
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
    }

    func testCommitSheetBelongsToItsWindowWhenAnotherWorkspaceTakesFocus() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("window-commit.txt", text: "earlier\n")
        try fixture.initializeGit()
        let old = try fixture.git(["rev-parse", "HEAD"])
        try "later\n".write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["-c", "user.name=BaileyUITest", "-c", "user.email=tests@example.invalid",
                         "commit", "-qam", "new window revision"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        let app = try launchGit(fixture)
        let originalID = try XCTUnwrap(app.windows.allElementsBoundByIndex.first {
            $0.buttons.matching(NSPredicate(format: "label == %@", "E2E fixture history"))
                .firstMatch.exists
        }).identifier
        XCTAssertFalse(originalID.isEmpty, "Window identity must stay stable across App focus changes")
        let original = app.windows.matching(identifier: originalID).firstMatch
        let other = app.windows.matching(NSPredicate(format: "identifier != %@", originalID)).firstMatch
        if !other.exists { app.typeKey("n", modifierFlags: [.command, .shift]) }
        XCTAssertTrue(original.waitForExistence(timeout: 15))
        XCTAssertTrue(other.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(app.windows.count, 2)
        XCTAssertFalse(other.sheets.firstMatch.exists)

        func present() -> XCUIElement {
            let gitDock = original.buttons.matching(identifier: "bailey.dock.git").firstMatch
            XCTAssertTrue(gitDock.waitForExistence(timeout: 8))
            gitDock.click()
            openCommitMenu("E2E fixture history", in: app)
            let option = app.menuItems.matching(NSPredicate(format: "title IN %@",
                ["Checkout Commit…", "检出提交…"])).firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 8))
            option.click()
            let sheet = original.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 15),
                          "The native checkout sheet must attach to the initiating project window")
            XCTAssertFalse(other.sheets.firstMatch.exists)
            return sheet
        }
        let first = present()
        XCTAssertFalse(other.sheets.firstMatch.exists,
                       "A checkout dialog must not appear in the other workspace window")
        let cancel = first.buttons.matching(NSPredicate(format: "title IN %@",
            ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8))
        cancel.click()
        XCTAssertTrue(first.waitForNonExistence(timeout: 10))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try Data(contentsOf: file), Data("later\n".utf8))

        let second = present()
        XCTAssertTrue(second.exists)
        XCTAssertFalse(other.sheets.firstMatch.exists)
        let confirm = second.buttons.matching(NSPredicate(format: "title IN %@",
            ["Yes, Checkout", "是，检出"])).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 8))
        confirm.click()
        let checkout = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["rev-parse", "HEAD"])) == old
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [checkout], timeout: 25), .completed)
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/heads/main"]), head)
        XCTAssertEqual(try fixture.git(["branch", "--show-current"]), Data())
        XCTAssertEqual(try Data(contentsOf: file), Data("earlier\n".utf8))
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
        XCTAssertTrue(other.buttons["bailey.emptyState.addFolder"].exists,
                      "The second workspace must remain empty and unaffected")
    }

    func testHistoricalCommitNativeSheetsUseSafeDefaultsAndCheckoutRealHistory() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("base.txt", text: "base\n")
        try fixture.initializeGit()
        try fixture.git(["config", "user.name", "BaileyUITest"])
        try fixture.git(["config", "user.email", "tests@example.invalid"])
        try fixture.git(["switch", "-c", "side"])
        _ = try fixture.file("side.txt", text: "side\n")
        try fixture.git(["add", "side.txt"])
        try fixture.git(["commit", "-qm", "side contribution"])
        try fixture.git(["switch", "main"])
        _ = try fixture.file("main.txt", text: "main\n")
        try fixture.git(["add", "main.txt"])
        try fixture.git(["commit", "-qm", "main contribution"])
        try fixture.git(["merge", "--no-ff", "side", "-m", "merge target"])
        let merge = try fixture.git(["rev-parse", "HEAD"])
        _ = try fixture.file("after.txt", text: "after\n")
        try fixture.git(["add", "after.txt"])
        try fixture.git(["commit", "-qm", "after merge"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        let app = try launchGit(fixture)

        func present(_ names: [String]) -> XCUIElement {
            openCommitMenu("merge target", in: app)
            let item = app.menuItems.matching(NSPredicate(format: "title IN %@", names)).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 8))
            item.click()
            let sheet = app.windows.firstMatch.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 15))
            return sheet
        }
        func check(_ sheet: XCUIElement, _ names: [String], _ value: String) {
            let checkbox = sheet.checkBoxes.matching(NSPredicate(format: "title IN %@", names)).firstMatch
            XCTAssertTrue(checkbox.waitForExistence(timeout: 8))
            XCTAssertEqual(String(describing: checkbox.value ?? ""), value)
        }
        func cancel(_ sheet: XCUIElement) {
            let button = sheet.buttons.matching(NSPredicate(
                format: "title IN %@", ["Cancel", "取消"])).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 8))
            button.click()
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
        }

        let checkout = present(["Checkout Commit…", "检出提交…"])
        check(checkout, ["Always Accept", "总是接受"], "0")
        cancel(checkout)

        let cherry = present(["Cherry Pick Commit…", "拣选提交…"])
        check(cherry, ["Record Origin", "记录来源"], "0")
        check(cherry, ["No Commit", "不创建提交"], "0")
        let mainline = cherry.popUpButtons.firstMatch
        XCTAssertTrue(mainline.waitForExistence(timeout: 8))
        XCTAssertTrue((mainline.value as? String)?.hasPrefix("1: ") == true)
        mainline.click()
        let secondParent = app.menuItems.matching(NSPredicate(
            format: "title BEGINSWITH %@", "2: ")).firstMatch
        XCTAssertTrue(secondParent.waitForExistence(timeout: 8))
        let firstParent = app.menuItems.matching(NSPredicate(
            format: "title BEGINSWITH %@", "1: ")).firstMatch
        XCTAssertTrue(firstParent.waitForExistence(timeout: 8))
        firstParent.click()
        cancel(cherry)

        let revert = present(["Revert Commit…", "撤销提交…"])
        let revertMainline = revert.popUpButtons.firstMatch
        XCTAssertTrue(revertMainline.waitForExistence(timeout: 8))
        XCTAssertTrue((revertMainline.value as? String)?.hasPrefix("1: ") == true)
        cancel(revert)

        let merging = present(["Merge Commit into Current Branch…", "将提交合并到当前分支…"])
        check(merging, ["Create Commit Even If Fast-forward Is Possible", "即使可快进也创建提交"], "1")
        check(merging, ["Squash Commits", "压缩提交"], "0")
        check(merging, ["No Commit", "不创建提交"], "0")
        cancel(merging)

        let rebase = present(["Rebase Current Branch onto Commit…", "将当前分支变基到提交…"])
        check(rebase, ["Launch Interactive Rebase in New Terminal", "在新终端启动交互式变基"], "0")
        check(rebase, ["Ignore Date", "忽略日期"], "1")
        cancel(rebase)

        let reset = present(["Reset Current Branch to Commit…", "将当前分支重置到提交…"])
        let mode = reset.popUpButtons.firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 8))
        XCTAssertTrue((mode.value as? String)?.contains("Mixed") == true,
                      "Reset must preserve the working tree by default")
        mode.click()
        for option in ["Soft", "Mixed", "Hard"] {
            XCTAssertTrue(app.menuItems.matching(NSPredicate(
                format: "title BEGINSWITH %@", option)).firstMatch.waitForExistence(timeout: 8))
        }
        app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "Mixed")).firstMatch.click()
        cancel(reset)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["branch", "--show-current"]), Data("main\n".utf8))
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("after.txt")),
                       Data("after\n".utf8))

        let confirmCheckout = present(["Checkout Commit…", "检出提交…"])
        let yes = confirmCheckout.buttons.matching(NSPredicate(
            format: "title IN %@", ["Yes, Checkout", "是，检出"])).firstMatch
        XCTAssertTrue(yes.waitForExistence(timeout: 8))
        yes.click()
        let detached = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["rev-parse", "HEAD"])) == merge
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [detached], timeout: 25), .completed)
        XCTAssertEqual(try fixture.git(["branch", "--show-current"]), Data())
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/heads/main"]), head)
        XCTAssertThrowsError(try fixture.git(["ls-files", "--error-unmatch", "after.txt"]))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("after.txt").path))
        XCTAssertEqual(try fixture.git(["show", "HEAD:side.txt"]), Data("side\n".utf8))
        XCTAssertEqual(try fixture.git(["show", "HEAD:main.txt"]), Data("main\n".utf8))
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
    }

    func testRemoteCheckoutNativeSheetValidatesNameAndCreatesTrackingBranch() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let remote = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("checkout.txt", text: "base\n")
        try fixture.initializeGit()
        let base = try fixture.git(["rev-parse", "HEAD"])
        try fixture.git(["init", "--bare", "-q", remote.root.path])
        try fixture.git(["remote", "add", "origin", remote.root.path])
        try fixture.git(["switch", "-c", "server-only"])
        try "server\n".write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["-c", "user.name=BaileyUITest", "-c", "user.email=tests@example.invalid",
                         "commit", "-qam", "server tracking revision"])
        let server = try fixture.git(["rev-parse", "HEAD"])
        try fixture.git(["push", "origin", "HEAD:refs/heads/topic"])
        try fixture.git(["switch", "main"])
        try fixture.git(["branch", "-D", "server-only"])
        try fixture.git(["fetch", "origin"])
        let app = try launchGit(fixture)
        func presentCheckout() -> XCUIElement {
            let badge = app.buttons.matching(NSPredicate(
                format: "label == %@", "origin/topic")).firstMatch
            XCTAssertTrue(badge.waitForExistence(timeout: 25))
            badge.rightClick()
            let checkout = app.menuItems.matching(NSPredicate(
                format: "title IN %@", ["Checkout Remote Branch…", "检出远端分支…"])).firstMatch
            XCTAssertTrue(checkout.waitForExistence(timeout: 8))
            checkout.click()
            let sheet = app.windows.firstMatch.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 15))
            return sheet
        }
        let initial = presentCheckout()
        let name = initial.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        XCTAssertEqual(name.value as? String, "topic")
        let create = initial.buttons.matching(NSPredicate(
            format: "title IN %@", ["Checkout Branch", "检出分支"])).firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 8))
        name.click()
        app.typeKey("a", modifierFlags: .command)
        name.typeText("   ")
        XCTAssertFalse(create.isEnabled, "Whitespace must not authorize a branch checkout")
        let cancel = initial.buttons.matching(NSPredicate(
            format: "title IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8))
        cancel.click()
        XCTAssertTrue(initial.waitForNonExistence(timeout: 10))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), base)
        XCTAssertThrowsError(try fixture.git(["rev-parse", "--verify", "refs/heads/topic"]))
        let confirmed = presentCheckout()
        let input = confirmed.textFields.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        input.click()
        app.typeKey("a", modifierFlags: .command)
        input.typeText("ui-tracking")
        let yes = confirmed.buttons.matching(NSPredicate(
            format: "title IN %@", ["Checkout Branch", "检出分支"])).firstMatch
        XCTAssertTrue(yes.isEnabled)
        yes.click()
        let tracked = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["branch", "--show-current"])) == Data("ui-tracking\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [tracked], timeout: 25), .completed)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), server)
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/heads/main"]), base)
        XCTAssertEqual(try fixture.git(["config", "--get", "branch.ui-tracking.remote"]), Data("origin\n".utf8))
        XCTAssertEqual(try fixture.git(["config", "--get", "branch.ui-tracking.merge"]), Data("refs/heads/topic\n".utf8))
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
        XCTAssertEqual(try Data(contentsOf: file), Data("server\n".utf8))
    }

    func testRemoteFetchAndPullNativeDefaultsPreserveOrAdvanceOnlyExpectedRefs() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let remote = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("remote.txt", text: "base\n")
        try fixture.initializeGit()
        let base = try fixture.git(["rev-parse", "HEAD"])
        try fixture.git(["branch", "side"])
        try fixture.git(["init", "--bare", "-q", remote.root.path])
        try fixture.git(["remote", "add", "origin", remote.root.path])
        try fixture.git(["switch", "-c", "server-work"])
        try "remote\n".write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["-c", "user.name=BaileyUITest", "-c", "user.email=tests@example.invalid",
                         "commit", "-qam", "remote revision"])
        let server = try fixture.git(["rev-parse", "HEAD"])
        try fixture.git(["push", "origin", "HEAD:refs/heads/side"])
        try fixture.git(["switch", "main"])
        try fixture.git(["branch", "-D", "server-work"])
        try fixture.git(["fetch", "origin"])
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/heads/side"]), base)
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/remotes/origin/side"]), server)
        let app = try launchGit(fixture)
        func openRemoteAction(_ names: [String]) -> XCUIElement {
            let badge = app.buttons.matching(NSPredicate(
                format: "label == %@", "origin/side")).firstMatch
            if badge.exists {
                badge.rightClick()
            } else {
                // Once local and remote tips agree, the remote lives in +N.
                let overflow = app.menuButtons.matching(NSPredicate(
                    format: "title == %@", "origin/side")).firstMatch
                XCTAssertTrue(overflow.waitForExistence(timeout: 10))
                overflow.click()
                let remoteReference = app.menuItems.matching(NSPredicate(
                    format: "title == %@", "origin/side")).firstMatch
                XCTAssertTrue(remoteReference.waitForExistence(timeout: 8))
                remoteReference.click()
            }
            let item = app.menuItems.matching(NSPredicate(format: "title IN %@", names)).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 8))
            item.click()
            let sheet = app.windows.firstMatch.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 15))
            return sheet
        }
        let fetch = ["Fetch into Local Branch…", "获取到本地分支…"]
        let pull = ["Pull into Current Branch…", "拉取到当前分支…"]
        let initial = openRemoteAction(fetch)
        let force = initial.checkBoxes.matching(NSPredicate(
            format: "title IN %@", ["Force Fetch", "强制获取"])).firstMatch
        XCTAssertTrue(force.waitForExistence(timeout: 8))
        XCTAssertEqual(String(describing: force.value ?? ""), "0")
        let cancel = initial.buttons.matching(NSPredicate(
            format: "title IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8))
        cancel.click()
        XCTAssertTrue(initial.waitForNonExistence(timeout: 10))
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/heads/side"]), base)
        let confirmedFetch = openRemoteAction(fetch)
        let yesFetch = confirmedFetch.buttons.matching(NSPredicate(
            format: "title IN %@", ["Yes, Fetch", "是，获取"])).firstMatch
        XCTAssertTrue(yesFetch.waitForExistence(timeout: 8))
        yesFetch.click()
        let fetched = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["rev-parse", "refs/heads/side"])) == server
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [fetched], timeout: 25), .completed)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), base)
        XCTAssertEqual(try Data(contentsOf: file), Data("base\n".utf8))

        let initialPull = openRemoteAction(pull)
        let noFastForward = initialPull.checkBoxes.matching(NSPredicate(format: "title IN %@",
            ["Create New Commit Even If Fast-Forward", "即使可快进也创建新提交"])).firstMatch
        let squash = initialPull.checkBoxes.matching(NSPredicate(
            format: "title IN %@", ["Squash", "压缩合并"])).firstMatch
        XCTAssertTrue(noFastForward.waitForExistence(timeout: 8))
        XCTAssertTrue(squash.waitForExistence(timeout: 8))
        XCTAssertEqual(String(describing: noFastForward.value ?? ""), "0")
        XCTAssertEqual(String(describing: squash.value ?? ""), "0")
        let cancelPull = initialPull.buttons.matching(NSPredicate(
            format: "title IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancelPull.waitForExistence(timeout: 8))
        cancelPull.click()
        XCTAssertTrue(initialPull.waitForNonExistence(timeout: 10))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), base)
        let confirmedPull = openRemoteAction(pull)
        let yesPull = confirmedPull.buttons.matching(NSPredicate(
            format: "title IN %@", ["Yes, Pull", "是，拉取"])).firstMatch
        XCTAssertTrue(yesPull.waitForExistence(timeout: 8))
        yesPull.click()
        let pulled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["rev-parse", "HEAD"])) == server
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pulled], timeout: 25), .completed)
        XCTAssertEqual(try fixture.git(["branch", "--show-current"]), Data("main\n".utf8))
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/heads/side"]), server)
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/remotes/origin/side"]), server)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
        XCTAssertEqual(try Data(contentsOf: file), Data("remote\n".utf8))
    }

    func testBranchDeleteDefaultsPreserveRemoteAndCancelIsNoOp() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let remote = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("branch-delete.txt", text: "base\n")
        try fixture.initializeGit()
        try fixture.git(["init", "--bare", "-q", remote.root.path])
        try fixture.git(["remote", "add", "origin", remote.root.path])
        try fixture.git(["switch", "-c", "feature-delete"])
        try "feature\n".write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["-c", "user.name=BaileyUITest", "-c", "user.email=tests@example.invalid",
                         "commit", "-qam", "feature revision"])
        let branchOID = try fixture.git(["rev-parse", "HEAD"])
        try fixture.git(["push", "-u", "origin", "feature-delete"])
        let remoteOID = try fixture.git(["ls-remote", "origin", "refs/heads/feature-delete"])
        XCTAssertFalse(remoteOID.isEmpty)
        try fixture.git(["switch", "main"])
        try fixture.git(["merge", "--ff-only", "feature-delete"])
        try "after\n".write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["-c", "user.name=BaileyUITest", "-c", "user.email=tests@example.invalid",
                         "commit", "-qam", "new main HEAD"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        XCTAssertNotEqual(head, branchOID)
        let app = try launchGit(fixture)
        func presentDelete() -> XCUIElement {
            let badge = app.buttons.matching(NSPredicate(
                format: "label == %@", "feature-delete")).firstMatch
            XCTAssertTrue(badge.waitForExistence(timeout: 25))
            badge.rightClick()
            let option = app.menuItems.matching(NSPredicate(
                format: "title IN %@", ["Delete Branch…", "删除分支…"])).firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 8))
            option.click()
            let sheet = app.windows.firstMatch.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 15))
            return sheet
        }
        let first = presentDelete()
        let force = first.checkBoxes.matching(NSPredicate(
            format: "title IN %@", ["Force Delete", "强制删除"])).firstMatch
        let remoteDelete = first.checkBoxes.matching(NSPredicate(
            format: "title IN %@", ["Delete on Remote(s)", "同时删除远端分支"])).firstMatch
        XCTAssertTrue(force.waitForExistence(timeout: 8))
        XCTAssertTrue(remoteDelete.waitForExistence(timeout: 8))
        XCTAssertEqual(String(describing: force.value ?? ""), "0")
        XCTAssertEqual(String(describing: remoteDelete.value ?? ""), "0")
        let cancel = first.buttons.matching(NSPredicate(
            format: "title IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8))
        cancel.click()
        XCTAssertTrue(first.waitForNonExistence(timeout: 10))
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/heads/feature-delete"]), branchOID)
        XCTAssertEqual(try fixture.git(["ls-remote", "origin", "refs/heads/feature-delete"]), remoteOID)
        let second = presentDelete()
        let delete = second.buttons.matching(NSPredicate(
            format: "title IN %@", ["Yes, Delete", "确认删除"])).firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 8))
        delete.click()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["show-ref", "--verify", "refs/heads/feature-delete"])) == nil
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 25), .completed)
        XCTAssertEqual(try fixture.git(["ls-remote", "origin", "refs/heads/feature-delete"]), remoteOID)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["branch", "--show-current"]), Data("main\n".utf8))
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
        XCTAssertEqual(try Data(contentsOf: file), Data("after\n".utf8))
    }

    func testBranchPushNativeSheetChoosesOnlySelectedBareRemote() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let origin = try WorkspaceUITestFixture(in: self)
        let backup = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("push.txt", text: "tracked\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        for (name, remote) in [("origin", origin), ("backup", backup)] {
            try fixture.git(["init", "--bare", "-q", remote.root.path])
            try fixture.git(["remote", "add", name, remote.root.path])
        }
        try fixture.git(["config", "remote.pushDefault", "backup"])
        let app = try launchGit(fixture)
        let badge = app.buttons.matching(NSPredicate(
            format: "label IN %@", ["main, Worktree", "main, 工作树"])).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 25))
        badge.rightClick()
        let push = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Push Branch…", "推送分支…"])).firstMatch
        XCTAssertTrue(push.waitForExistence(timeout: 8))
        push.click()
        let sheet = app.windows.firstMatch.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 15))
        let upstream = sheet.checkBoxes.matching(NSPredicate(
            format: "title IN %@", ["Set Upstream", "设置上游分支"])).firstMatch
        let originButton = sheet.checkBoxes.matching(NSPredicate(format: "title == %@", "origin")).firstMatch
        let backupButton = sheet.checkBoxes.matching(NSPredicate(format: "title == %@", "backup")).firstMatch
        let confirm = sheet.buttons.matching(NSPredicate(
            format: "title IN %@", ["Yes, Push", "确认推送"])).firstMatch
        XCTAssertTrue(upstream.waitForExistence(timeout: 8))
        XCTAssertTrue(originButton.waitForExistence(timeout: 8))
        XCTAssertTrue(backupButton.waitForExistence(timeout: 8))
        XCTAssertTrue(confirm.waitForExistence(timeout: 8))
        XCTAssertEqual(String(describing: upstream.value ?? ""), "1")
        XCTAssertEqual(String(describing: originButton.value ?? ""), "0")
        XCTAssertEqual(String(describing: backupButton.value ?? ""), "1")
        backupButton.click()
        XCTAssertFalse(confirm.isEnabled, "No selected remote must prevent any Push")
        originButton.click()
        XCTAssertTrue(confirm.isEnabled)
        originButton.click()
        XCTAssertFalse(confirm.isEnabled)
        backupButton.click()
        XCTAssertTrue(confirm.isEnabled)
        confirm.click()
        let pushed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["ls-remote", "backup", "refs/heads/main"]))
                == Data("\(String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))\trefs/heads/main\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pushed], timeout: 25), .completed)
        XCTAssertEqual(try fixture.git(["ls-remote", "origin", "refs/heads/main"]), Data())
        XCTAssertEqual(try fixture.git(["config", "--get", "branch.main.remote"]), Data("backup\n".utf8))
        XCTAssertEqual(try fixture.git(["config", "--get", "branch.main.merge"]), Data("refs/heads/main\n".utf8))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
        XCTAssertEqual(try Data(contentsOf: file), Data("tracked\n".utf8))
    }

    func testTagPushUsesTagDefaultRemoteNotBranchPushRemote() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let origin = try WorkspaceUITestFixture(in: self)
        let backup = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("tag-push.txt", text: "tagged\n")
        try fixture.initializeGit()
        let tagCommit = try fixture.git(["rev-parse", "HEAD"])
        try fixture.git(["tag", "ui-push"])
        try "newer\n".write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["-c", "user.name=BaileyUITest", "-c", "user.email=tests@example.invalid",
                         "commit", "-qam", "new head after tag"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        for (name, remote) in [("origin", origin), ("backup", backup)] {
            try fixture.git(["init", "--bare", "-q", remote.root.path])
            try fixture.git(["remote", "add", name, remote.root.path])
            try fixture.git(["push", name, "main"])
            try fixture.git(["fetch", name])
        }
        try fixture.git(["config", "remote.pushDefault", "backup"])
        try fixture.git(["config", "branch.main.pushRemote", "origin"])
        let app = try launchGit(fixture)
        let badge = app.buttons.matching(NSPredicate(format: "label == %@", "ui-push")).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 25))
        badge.rightClick()
        let push = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Push Tag…", "推送标签…"])).firstMatch
        XCTAssertTrue(push.waitForExistence(timeout: 8))
        push.click()
        let sheet = app.windows.firstMatch.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 15))
        let originButton = sheet.checkBoxes.matching(NSPredicate(format: "title == %@", "origin")).firstMatch
        let backupButton = sheet.checkBoxes.matching(NSPredicate(format: "title == %@", "backup")).firstMatch
        let confirm = sheet.buttons.matching(NSPredicate(
            format: "title IN %@", ["Yes, Push", "确认推送"])).firstMatch
        XCTAssertTrue(originButton.waitForExistence(timeout: 8))
        XCTAssertTrue(backupButton.waitForExistence(timeout: 8))
        XCTAssertTrue(confirm.waitForExistence(timeout: 8))
        XCTAssertEqual(String(describing: originButton.value ?? ""), "0",
                       "Tag remote selection must ignore branch.main.pushRemote")
        XCTAssertEqual(String(describing: backupButton.value ?? ""), "1")
        backupButton.click()
        XCTAssertFalse(confirm.isEnabled)
        originButton.click()
        XCTAssertTrue(confirm.isEnabled)
        originButton.click()
        XCTAssertFalse(confirm.isEnabled)
        backupButton.click()
        confirm.click()
        let expected = Data((String(decoding: tagCommit, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\trefs/tags/ui-push\n").utf8)
        let pushed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["ls-remote", "backup", "refs/tags/ui-push"])) == expected
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pushed], timeout: 25), .completed)
        XCTAssertEqual(try fixture.git(["ls-remote", "origin", "refs/tags/ui-push"]), Data())
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
        XCTAssertEqual(try Data(contentsOf: file), Data("newer\n".utf8))
    }

    func testTagDeleteNativeSheetDefaultsLocalOnlyAndPreservesBareRemote() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let remote = try WorkspaceUITestFixture(in: self)
        let backup = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("tagged.txt", text: "old tagged revision\n")
        try fixture.initializeGit()
        let taggedCommit = try fixture.git(["rev-parse", "HEAD"])
        try fixture.git(["tag", "ui-delete"])
        try fixture.git(["init", "--bare", "-q", remote.root.path])
        try fixture.git(["remote", "add", "origin", remote.root.path])
        try fixture.git(["push", "origin", "refs/tags/ui-delete"])
        try fixture.git(["init", "--bare", "-q", backup.root.path])
        try fixture.git(["remote", "add", "backup", backup.root.path])
        try fixture.git(["push", "backup", "refs/tags/ui-delete"])
        let remoteTag = try fixture.git(["ls-remote", "origin", "refs/tags/ui-delete"])
        XCTAssertFalse(remoteTag.isEmpty)
        XCTAssertEqual(try fixture.git(["ls-remote", "backup", "refs/tags/ui-delete"]), remoteTag)
        try "working head\n".write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["-c", "user.name=BaileyUITest", "-c",
                         "user.email=tests@example.invalid", "commit", "-qam", "later head"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        XCTAssertNotEqual(head, taggedCommit)
        let app = try launchGit(fixture, language: "en")

        func presentDelete() -> XCUIElement {
            let badge = app.buttons.matching(NSPredicate(
                format: "label == %@", "ui-delete")).firstMatch
            XCTAssertTrue(badge.waitForExistence(timeout: 25),
                          "The tag on an older commit must be visible in the real Git Graph")
            badge.rightClick()
            let item = app.menuItems.matching(NSPredicate(
                format: "title IN %@", ["Delete Tag…", "删除标签…"])).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 8))
            item.click()
            let sheet = app.windows.firstMatch.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 15))
            return sheet
        }

        let first = presentDelete()
        let remotes = first.popUpButtons.firstMatch
        XCTAssertTrue(remotes.waitForExistence(timeout: 8))
        let localOnly = ["Don't Delete on Any Remote", "不删除远端标签"]
        XCTAssertTrue(localOnly.contains(remotes.value as? String ?? ""),
                      "Deleting a local tag must not remotely delete anything by default")
        remotes.click()
        let other = app.menuItems.matching(NSPredicate(format: "title == %@", "backup")).firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 8))
        other.click()
        XCTAssertEqual(remotes.value as? String, "backup")
        remotes.click()
        let localOnlyOption = app.menuItems.matching(NSPredicate(
            format: "title IN %@", localOnly)).firstMatch
        XCTAssertTrue(localOnlyOption.waitForExistence(timeout: 8))
        localOnlyOption.click()
        XCTAssertTrue(localOnly.contains(remotes.value as? String ?? ""))
        let cancel = first.buttons.matching(NSPredicate(format: "title IN %@",
            ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8))
        cancel.click()
        XCTAssertTrue(first.waitForNonExistence(timeout: 10))
        XCTAssertFalse(try fixture.git(["tag", "-l", "ui-delete"]).isEmpty)
        XCTAssertEqual(try fixture.git(["ls-remote", "origin", "refs/tags/ui-delete"]), remoteTag)
        XCTAssertEqual(try fixture.git(["ls-remote", "backup", "refs/tags/ui-delete"]), remoteTag)

        let second = presentDelete()
        let choice = second.popUpButtons.firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 8))
        XCTAssertTrue(localOnly.contains(choice.value as? String ?? ""))
        let delete = second.buttons.matching(NSPredicate(format: "title IN %@",
            ["Yes, Delete", "确认删除"])).firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 8))
        delete.click()
        let localGone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["tag", "-l", "ui-delete"])) == Data()
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [localGone], timeout: 25), .completed)
        XCTAssertEqual(try fixture.git(["ls-remote", "origin", "refs/tags/ui-delete"]), remoteTag,
                       "The native default must preserve the actual bare remote tag")
        XCTAssertEqual(try fixture.git(["ls-remote", "backup", "refs/tags/ui-delete"]), remoteTag)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data())
        XCTAssertEqual(try Data(contentsOf: file), Data("working head\n".utf8))
    }

    func testHistoricalTagSheetPreservesAnnotationAndCreatesAtChosenCommit() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("tag.txt", text: "old\n")
        try fixture.initializeGit()
        let old = try fixture.git(["rev-parse", "HEAD"])
        try fixture.git(["config", "user.name", "Tag UITest"])
        try fixture.git(["config", "user.email", "tags@example.invalid"])
        try "new\n".write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["commit", "-qam", "post-tag revision"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        XCTAssertNotEqual(old, head)
        let app = try launchGit(fixture)

        func present() -> XCUIElement {
            openCommitMenu("E2E fixture history", in: app)
            let option = app.menuItems.matching(NSPredicate(
                format: "title IN %@", ["Create Tag at Commit…", "在此创建标签…"])).firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 10))
            option.click()
            let sheet = app.windows.firstMatch.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 15))
            return sheet
        }
        let initial = present()
        let name = initial.textFields.firstMatch
        let note = initial.textViews.firstMatch
        let type = initial.popUpButtons.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        XCTAssertTrue(note.waitForExistence(timeout: 8))
        XCTAssertTrue(type.waitForExistence(timeout: 8))
        let add = initial.buttons.matching(NSPredicate(
            format: "title IN %@", ["Add Tag", "添加标签"])).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 8))
        XCTAssertFalse(add.isEnabled)
        name.click()
        name.typeText("ui-annotated-old")
        note.click()
        note.typeText("E2E annotation retained")
        type.click()
        let lightweight = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Lightweight", "轻量标签"])).firstMatch
        XCTAssertTrue(lightweight.waitForExistence(timeout: 8))
        lightweight.click()
        XCTAssertEqual(note.value as? String, "E2E annotation retained",
                       "Switching to lightweight must not erase the unsaved annotation")
        type.click()
        let annotated = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Annotated", "带注释标签"])).firstMatch
        XCTAssertTrue(annotated.waitForExistence(timeout: 8))
        annotated.click()
        XCTAssertEqual(note.value as? String, "E2E annotation retained")
        let cancel = initial.buttons.matching(NSPredicate(
            format: "title IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8))
        cancel.click()
        XCTAssertTrue(initial.waitForNonExistence(timeout: 10))
        XCTAssertThrowsError(try fixture.git(["rev-parse", "--verify", "refs/tags/ui-annotated-old"]))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)

        let confirmed = present()
        let tagName = confirmed.textFields.firstMatch
        let annotation = confirmed.textViews.firstMatch
        XCTAssertTrue(tagName.waitForExistence(timeout: 8))
        XCTAssertTrue(annotation.waitForExistence(timeout: 8))
        tagName.click()
        tagName.typeText("ui-annotated-old")
        annotation.click()
        annotation.typeText("E2E selected old revision")
        let create = confirmed.buttons.matching(NSPredicate(
            format: "title IN %@", ["Add Tag", "添加标签"])).firstMatch
        XCTAssertTrue(create.isEnabled)
        create.click()
        let tagged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["rev-parse", "refs/tags/ui-annotated-old^{commit}"])) == old
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [tagged], timeout: 25), .completed)
        XCTAssertEqual(try fixture.git(["cat-file", "-t", "refs/tags/ui-annotated-old"]),
                       Data("tag\n".utf8))
        XCTAssertTrue(String(decoding: try fixture.git(["cat-file", "-p", "refs/tags/ui-annotated-old"]),
                             as: UTF8.self).contains("E2E selected old revision"))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try Data(contentsOf: file), Data("new\n".utf8))
    }

    private func launchGit(_ fixture: WorkspaceUITestFixture, language: String? = nil) throws -> XCUIApplication {
        let root = fixture.root.standardizedFileURL.path
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
        precondition(root.hasPrefix(temporary + "/Bailey-UITest-"),
                     "Dialog UI tests must never execute Git against a real workspace")
        let app = try WorkspaceUITestSupport.launch(in: self, language: language)
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(WorkspaceUITestSupport.element("bailey.dock.git", in: app)
            .waitForExistence(timeout: 20))
        return app
    }

    private func openCommitMenu(_ subject: String, in app: XCUIApplication) {
        let node = app.buttons.matching(NSPredicate(
            format: "label ENDSWITH %@", ": " + subject)).firstMatch
        XCTAssertTrue(node.waitForExistence(timeout: 25))
        XCTAssertTrue(node.isHittable)
        node.rightClick()
    }
}
