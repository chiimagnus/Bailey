import AppKit
import XCTest

@MainActor
final class WorkspaceDockUITests: XCTestCase {
    func testDockCommandAndShiftTabSelectionHasNativeAccessibilityState() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let files = try (0..<3).map {
            try fixture.file("tab-\($0).txt", text: "original \($0)\n")
        }
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root
        )
        let bundle = try XCTUnwrap(NSRunningApplication.runningApplications(
            withBundleIdentifier: "chiimagnus.bailey.dev").compactMap(\.bundleURL).first)
        let opened = expectation(description: "Open three tabs in a single real Dock")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(files, withApplicationAt: bundle, configuration: configuration) {
            _, error in
            XCTAssertNil(error)
            opened.fulfill()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 20), .completed)
        let window = app.windows.firstMatch
        let tabs = files.map { WorkspaceUITestSupport.fileTab($0, in: window) }
        for tab in tabs { XCTAssertTrue(tab.waitForExistence(timeout: 15)) }

        tabs[0].click()
        XCTAssertTrue(tabs[0].isSelected)
        XCUIElement.perform(withKeyModifiers: .command) { tabs[2].click() }
        XCTAssertTrue(tabs[0].isSelected,
                      "Command-click must keep the previously selected tab in the same group")
        XCTAssertFalse(tabs[1].isSelected)
        XCTAssertTrue(tabs[2].isSelected)

        XCUIElement.perform(withKeyModifiers: .shift) { tabs[1].click() }
        XCTAssertTrue(tabs[0].isSelected)
        XCTAssertTrue(tabs[1].isSelected)
        XCTAssertTrue(tabs[2].isSelected)
        tabs[1].click()
        XCTAssertFalse(tabs[0].isSelected, "Ordinary release must collapse the selected set")
        XCTAssertTrue(tabs[1].isSelected)
        XCTAssertFalse(tabs[2].isSelected)
        for (index, file) in files.enumerated() {
            XCTAssertEqual(try Data(contentsOf: file), Data("original \(index)\n".utf8))
        }
    }

    func testDockCommandSelectedTabsCloseTogetherWithoutClosingUnselectedFiles() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let files = try (0..<3).map {
            try fixture.file("close-\($0).swift", text: "let value = \($0)\n")
        }
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root
        )
        let bundle = try XCTUnwrap(NSRunningApplication.runningApplications(
            withBundleIdentifier: "chiimagnus.bailey.dev").compactMap(\.bundleURL).first)
        let opened = expectation(description: "Open three isolated file tabs")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(files, withApplicationAt: bundle, configuration: config) {
            _, error in
            XCTAssertNil(error)
            opened.fulfill()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 20), .completed)
        let window = app.windows.firstMatch
        let tabs = files.map { WorkspaceUITestSupport.fileTab($0, in: window) }
        for tab in tabs { XCTAssertTrue(tab.waitForExistence(timeout: 15)) }

        tabs[0].click()
        XCUIElement.perform(withKeyModifiers: .command) { tabs[2].click() }
        XCTAssertTrue(tabs[0].isSelected && tabs[2].isSelected)
        XCTAssertFalse(tabs[1].isSelected)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(tabs[0].waitForNonExistence(timeout: 15))
        XCTAssertTrue(tabs[2].waitForNonExistence(timeout: 15))
        XCTAssertTrue(tabs[1].exists,
                      "Closing a multi-selection must leave unselected tabs open")
        XCTAssertTrue(WorkspaceUITestSupport.element("bailey.dock.files", in: app).exists,
                      "Closing work tabs must not remove the Files tool")
        for (index, file) in files.enumerated() {
            XCTAssertEqual(try Data(contentsOf: file), Data("let value = \(index)\n".utf8))
        }
    }

    func testSelectedTabContextMenuCommandWClosesSelectionOnlyOnce() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let files = try (0..<3).map {
            try fixture.file("s-\($0).swift", text: "let selected = \($0)\n")
        }
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root
        )
        let bundle = try XCTUnwrap(NSRunningApplication.runningApplications(
            withBundleIdentifier: "chiimagnus.bailey.dev").compactMap(\.bundleURL).first)
        let opened = expectation(description: "Open selected Dock close fixtures")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(files, withApplicationAt: bundle, configuration: config) { _, error in
            XCTAssertNil(error)
            opened.fulfill()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 20), .completed)
        let window = app.windows.firstMatch
        let tabs = files.map { WorkspaceUITestSupport.fileTab($0, in: window) }
        for tab in tabs { XCTAssertTrue(tab.waitForExistence(timeout: 15)) }

        tabs[0].click()
        XCUIElement.perform(withKeyModifiers: .command) { tabs[2].click() }
        XCTAssertTrue(tabs[0].isSelected && tabs[2].isSelected)
        XCTAssertFalse(tabs[1].isSelected)
        tabs[2].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        XCTAssertTrue(app.menus.allElementsBoundByIndex.contains {
            $0.menuItems["Close Selected Panels"].exists
        }, "A selected multi-tab right-click must reveal the actual batch action")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(tabs[0].waitForNonExistence(timeout: 15))
        XCTAssertTrue(tabs[2].waitForNonExistence(timeout: 15))
        XCTAssertTrue(tabs[1].exists, "Context-menu Command-W must not close an unselected tab")
        XCTAssertEqual(window.buttons.matching(identifier: "bailey.tab.file").count, 1,
                       "The native menu and system shortcut must not both execute a close")
        for (index, file) in files.enumerated() {
            XCTAssertEqual(try Data(contentsOf: file), Data("let selected = \(index)\n".utf8))
        }
    }

    func testRightClickOutsideTabSelectionClosesOnlyItsOwnTarget() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let files = try (0..<3).map {
            try fixture.file("u-\($0).swift", text: "let untouched = \($0)\n")
        }
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root
        )
        let bundle = try XCTUnwrap(NSRunningApplication.runningApplications(
            withBundleIdentifier: "chiimagnus.bailey.dev").compactMap(\.bundleURL).first)
        let opened = expectation(description: "Open context selection fixtures")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(files, withApplicationAt: bundle, configuration: config) { _, error in
            XCTAssertNil(error)
            opened.fulfill()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 20), .completed)
        let window = app.windows.firstMatch
        let tabs = files.map { WorkspaceUITestSupport.fileTab($0, in: window) }
        for tab in tabs { XCTAssertTrue(tab.waitForExistence(timeout: 15)) }

        tabs[0].click()
        XCUIElement.perform(withKeyModifiers: .command) { tabs[2].click() }
        XCTAssertTrue(tabs[0].isSelected && tabs[2].isSelected)
        tabs[1].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        let menu = try XCTUnwrap(app.menus.allElementsBoundByIndex.first {
            $0.menuItems["Close"].exists && $0.menuItems["Close Others"].exists
        }, "An unselected tab must have a single-item Close action")
        XCTAssertFalse(menu.menuItems["Close Selected Panels"].exists)
        XCTAssertTrue(tabs[0].isSelected && tabs[2].isSelected,
                      "Right-clicking outside the selection cannot select or activate its target")
        menu.menuItems["Close"].click()
        XCTAssertTrue(tabs[1].waitForNonExistence(timeout: 15))
        XCTAssertTrue(tabs[0].exists && tabs[2].exists)
        XCTAssertEqual(window.buttons.matching(identifier: "bailey.tab.file").count, 2)
        for (index, file) in files.enumerated() {
            XCTAssertEqual(try Data(contentsOf: file), Data("let untouched = \(index)\n".utf8))
        }
    }

    func testDockMultiSelectionDragMovesBothTabsToAnotherGroupWithoutCloning() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let files = try (0..<3).map {
            try fixture.file("d-\($0).swift", text: "let item = \($0)\n")
        }
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root
        )
        let bundle = try XCTUnwrap(NSRunningApplication.runningApplications(
            withBundleIdentifier: "chiimagnus.bailey.dev").compactMap(\.bundleURL).first)
        let opened = expectation(description: "Create three original native editors")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(files, withApplicationAt: bundle, configuration: config) {
            _, error in
            XCTAssertNil(error)
            opened.fulfill()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 20), .completed)
        let window = app.windows.firstMatch
        let tabs = files.map { WorkspaceUITestSupport.fileTab($0, in: window) }
        let filesTool = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        for tab in tabs { XCTAssertTrue(tab.waitForExistence(timeout: 15)) }
        XCTAssertTrue(filesTool.waitForExistence(timeout: 15))

        tabs[0].click()
        XCUIElement.perform(withKeyModifiers: .command) { tabs[2].click() }
        XCTAssertTrue(tabs[0].isSelected && tabs[2].isSelected)
        XCTAssertFalse(tabs[1].isSelected)
        let originalSourceX = tabs[0].frame.midX
        let originalTargetX = filesTool.frame.midX
        XCTAssertGreaterThan(abs(originalTargetX - originalSourceX), 80,
                             "This fixture must actually span two independent Dock groups")
        tabs[0].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.3, thenDragTo:
                filesTool.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            )
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            tabs[0].exists && tabs[2].exists
                && abs(tabs[0].frame.midX - originalTargetX)
                    < abs(originalSourceX - originalTargetX)
                && abs(tabs[2].frame.midX - originalTargetX)
                    < abs(originalSourceX - originalTargetX)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 12), .completed,
                       "One actual drag must move the whole selection into the destination group")
        XCTAssertTrue(tabs[1].exists, "Unselected native editor must remain in the origin group")
        XCTAssertEqual(window.buttons.matching(identifier: "bailey.tab.file").count, 3,
                       "Moving must not clone or drop any file tab")
        for (index, file) in files.enumerated() {
            XCTAssertEqual(try Data(contentsOf: file), Data("let item = \(index)\n".utf8))
        }
    }

    func testNestedDockSplitRepaintsEveryPaneAcrossPaletteChanges() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("nested-top.swift", text: "let top = 1\n")
        let second = try fixture.file("nested-bottom.swift", text: "let bottom = 2\n")
        _ = try fixture.file(".config/bailey-dev/config.toml", text: """
            theme = "light"
            theme-light = "Ayu Light"
            theme-dark = "Adwaita Dark"
            """)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", configurationHome: fixture.root, project: fixture.root
        )
        let bundle = try XCTUnwrap(NSRunningApplication.runningApplications(
            withBundleIdentifier: "chiimagnus.bailey.dev"
        ).compactMap(\.bundleURL).first)
        let opened = expectation(description: "Open two real editors in one Dock group")
        NSWorkspace.shared.open([first, second], withApplicationAt: bundle,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            XCTAssertNil(error)
            opened.fulfill()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 20), .completed)
        let main = app.windows.matching(identifier: "main-AppWindow-1").firstMatch
        let upper = WorkspaceUITestSupport.fileTab(first, in: main)
        let lower = WorkspaceUITestSupport.fileTab(second, in: main)
        XCTAssertTrue(upper.waitForExistence(timeout: 15))
        XCTAssertTrue(lower.waitForExistence(timeout: 15))
        let initialDividers = main.otherElements.matching(identifier: "bailey.dock.divider").count
        XCTAssertEqual(initialDividers, 2, "Fixture starts in the three-column layout")

        lower.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.3, thenDragTo:
                main.coordinate(withNormalizedOffset: CGVector(dx: 0.46, dy: 0.91))
            )
        let nested = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            main.otherElements.matching(identifier: "bailey.dock.divider").count == 3
                && upper.exists && lower.exists && abs(upper.frame.midY - lower.frame.midY) > 110
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [nested], timeout: 15), .completed,
                       "An actual tab drag must create a fourth group and a vertical nested split")

        func capture(_ name: String) throws -> (projects: NSColor, top: NSColor, bottom: NSColor, files: NSColor) {
            let screenshot = main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(
                data: try XCTUnwrap(screenshot.image.tiffRepresentation)
            ))
            let scale = CGFloat(bitmap.pixelsWide) / main.frame.width
            func color(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
                let pixel = try XCTUnwrap(bitmap.colorAt(
                    x: Int(x * scale), y: Int(y * scale)
                ))
                return try XCTUnwrap(pixel.usingColorSpace(.deviceRGB))
            }
            return try (
                color(50, 250), color(350, 150), color(350, 430), color(780, 250)
            )
        }
        func difference(_ a: NSColor, _ b: NSColor) -> CGFloat {
            max(abs(a.redComponent - b.redComponent),
                abs(a.greenComponent - b.greenComponent),
                abs(a.blueComponent - b.blueComponent))
        }
        let originalFrames = (upper.frame, lower.frame)
        let light = try capture("Nested Dock with four groups, Ayu Light")
        XCTAssertLessThan(difference(light.projects, light.top), 0.035)
        XCTAssertLessThan(difference(light.bottom, light.top), 0.035)
        XCTAssertLessThan(difference(light.files, light.top), 0.035)

        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(
            identifier: "com_apple_SwiftUI_Settings_window"
        ).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 12))
        let darkTab = settings.descendants(matching: .tab)["Dark"].firstMatch
        XCTAssertTrue(darkTab.waitForExistence(timeout: 12))
        darkTab.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 12))
        let dark = try capture("Nested Dock after dark appearance")
        XCTAssertGreaterThan(difference(light.top, dark.top), 0.5)
        XCTAssertLessThan(difference(dark.projects, dark.top), 0.035)
        XCTAssertLessThan(difference(dark.bottom, dark.top), 0.035)
        XCTAssertLessThan(difference(dark.files, dark.top), 0.035)

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settings.waitForExistence(timeout: 12))
        let picker = settings.popUpButtons.element(boundBy: 1)
        XCTAssertTrue(picker.waitForExistence(timeout: 12))
        picker.click()
        let ayuDark = picker.menuItems["Ayu"]
        XCTAssertTrue(ayuDark.waitForExistence(timeout: 12))
        ayuDark.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 12))
        let alternate = try capture("Nested Dock after dark-only palette change")
        XCTAssertGreaterThan(difference(dark.top, alternate.top), 0.03)
        XCTAssertLessThan(difference(alternate.projects, alternate.top), 0.035)
        XCTAssertLessThan(difference(alternate.bottom, alternate.top), 0.035)
        XCTAssertLessThan(difference(alternate.files, alternate.top), 0.035)

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settings.waitForExistence(timeout: 12))
        let lightTab = settings.descendants(matching: .tab)["Light"].firstMatch
        XCTAssertTrue(lightTab.waitForExistence(timeout: 12))
        lightTab.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 12))
        let restored = try capture("Nested Dock restored Ayu Light without redocking")
        XCTAssertLessThan(difference(restored.top, light.top), 0.025)
        XCTAssertLessThan(difference(restored.bottom, light.bottom), 0.025)
        XCTAssertLessThan(difference(restored.projects, light.projects), 0.025)
        XCTAssertEqual(main.otherElements.matching(identifier: "bailey.dock.divider").count, 3)
        XCTAssertEqual(upper.frame.midY, originalFrames.0.midY, accuracy: 3)
        XCTAssertEqual(lower.frame.midY, originalFrames.1.midY, accuracy: 3)
        XCTAssertEqual(try Data(contentsOf: first), Data("let top = 1\n".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("let bottom = 2\n".utf8))
    }

    func testDockFileTabSwitchRevealsOneSelectedExplorerRow() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("one.swift", text: "let one = 1\n")
        let second = try fixture.file("two.swift", text: "let two = 2\n")
        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
        let window = app.windows.firstMatch
        let firstRow = WorkspaceUITestSupport.fileRow(first, in: window)
        let secondRow = WorkspaceUITestSupport.fileRow(second, in: window)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 15))
        XCTAssertTrue(secondRow.waitForExistence(timeout: 15))

        firstRow.click()
        secondRow.click()
        let firstTab = WorkspaceUITestSupport.fileTab(first, in: window)
        let secondTab = WorkspaceUITestSupport.fileTab(second, in: window)
        XCTAssertTrue(firstTab.waitForExistence(timeout: 10))
        XCTAssertTrue(secondTab.waitForExistence(timeout: 10))

        for (tab, selected, other) in [
            (firstTab, firstRow, secondRow),
            (secondTab, secondRow, firstRow),
            (firstTab, firstRow, secondRow)
        ] {
            tab.click()
            let expected = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "selected == true"), object: selected
            )
            XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 8), .completed)
            XCTAssertFalse(other.isSelected, "The previous Explorer row must not remain selected")
        }
        XCTAssertEqual(try Data(contentsOf: first), Data("let one = 1\n".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("let two = 2\n".utf8))
    }

    func testThirtyRealDockSwitchesKeepExplorerSelectionAndMeasureEndToEndResponse() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("switch-a.swift", text: "original A\n")
        let second = try fixture.file("switch-b.swift", text: "original B\n")
        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
        let window = app.windows.firstMatch
        let firstRow = WorkspaceUITestSupport.fileRow(first, in: window)
        let secondRow = WorkspaceUITestSupport.fileRow(second, in: window)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 15))
        XCTAssertTrue(secondRow.waitForExistence(timeout: 15))
        firstRow.click()
        secondRow.click()
        let tabs = [WorkspaceUITestSupport.fileTab(first, in: window),
                    WorkspaceUITestSupport.fileTab(second, in: window)]
        for tab in tabs { XCTAssertTrue(tab.waitForExistence(timeout: 15)) }
        let rows = [firstRow, secondRow]
        var seconds: [Double] = []
        for index in 0..<30 {
            let target = index % 2
            let start = ProcessInfo.processInfo.systemUptime
            tabs[target].click()
            XCTAssertTrue(rows[target].isSelected,
                          "The real Explorer selection must follow the latest Dock tab")
            XCTAssertFalse(rows[1 - target].isSelected,
                           "The previous file must not retain a second selection")
            seconds.append(ProcessInfo.processInfo.systemUptime - start)
        }
        let sorted = seconds.sorted()
        print(String(format: "P5_DOCK_UI_SWITCH n=30 median=%.3fs p95=%.3fs max=%.3fs",
                     (sorted[14] + sorted[15]) / 2, sorted[28], sorted[29]))
        XCTAssertEqual(try Data(contentsOf: first), Data("original A\n".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("original B\n".utf8))
    }

    func testCrossGroupDragReleaseCannotSelectDestinationButRealClickCan() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("unchanged.swift", text: "original bytes\n")
        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
        let window = app.windows.firstMatch
        let projects = WorkspaceUITestSupport.element("bailey.dock.projects", in: app)
        let files = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        XCTAssertTrue(projects.waitForExistence(timeout: 15))
        XCTAssertTrue(files.waitForExistence(timeout: 15))
        projects.click()

        let origin = window.coordinate(withNormalizedOffset: .zero)
        let source = origin.withOffset(CGVector(
            dx: window.frame.width * 0.06, dy: window.frame.height * 0.72))
        let destination = origin.withOffset(CGVector(
            dx: window.frame.width * 0.92, dy: window.frame.height * 0.72))
        source.click(forDuration: 0.12, thenDragTo: destination)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(projects.waitForNonExistence(timeout: 12),
                      "The first Cmd-W after a cross-group drag must close its original Projects panel")
        XCTAssertTrue(files.exists, "Drag release must not activate or close the Files target")

        files.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(files.waitForNonExistence(timeout: 12),
                      "A genuine Files click must route Cmd-W to the destination group")
        XCTAssertTrue(window.exists, "Closing two tool panes must not destroy the project window")
        XCTAssertEqual(try Data(contentsOf: file), Data("original bytes\n".utf8))
    }

    func testOpenToolContextMenuCommandWClosesOnlyRightClickedPanel() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("do-not-close-git.txt", text: "keep original\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)

        let window = app.windows.firstMatch
        let files = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        let git = WorkspaceUITestSupport.element("bailey.dock.git", in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 15))
        XCTAssertTrue(git.waitForExistence(timeout: 15))
        let strip = window.scrollViews.containing(
            .button, identifier: "bailey.dock.git"
        ).firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        XCTAssertLessThan(strip.frame.width, 130,
                          "The narrow Dock tab strip must not overflow its group's viewport")
        strip.swipeLeft()
        XCTAssertTrue(strip.frame.contains(CGPoint(x: git.frame.midX, y: git.frame.midY)),
                      "The active Git target must be inside the visible tab-strip viewport")
        git.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(git.isSelected, "Real Git tab click must select and activate Git")
        strip.swipeRight()
        XCTAssertTrue(files.isHittable, "The Files tab must be reachable by horizontal scrolling")
        XCTAssertTrue(strip.frame.contains(CGPoint(x: files.frame.midX, y: files.frame.midY)),
                      "The right-clicked Files tab must be inside the actual tab-strip viewport")
        files.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        XCTAssertTrue(app.menus.allElementsBoundByIndex.contains {
            $0.menuItems["Close Panel"].exists
        }, "The native right-click menu must still be open")
        app.typeKey("w", modifierFlags: .command)

        XCTAssertTrue(files.waitForNonExistence(timeout: 12),
                      "Cmd-W in the context menu must close Files only")
        XCTAssertTrue(git.exists && window.exists,
                      "The active Git group must remain after closing the inactive Files panel")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(git.waitForNonExistence(timeout: 12),
                      "After the menu closes, Cmd-W must return to the active Dock group")
        XCTAssertTrue(window.exists)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep original\n")
    }

    func testCancelledFileTabMenuDoesNotCloseItsFormerTarget() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("keep-left.txt", text: "left original\n")
        let second = try fixture.file("close-right.txt", text: "right original\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let bundle = try XCTUnwrap(NSRunningApplication.runningApplications(
            withBundleIdentifier: "chiimagnus.bailey.dev").compactMap(\.bundleURL).first)
        let opened = expectation(description: "Open both isolated file tabs")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([first, second], withApplicationAt: bundle,
                                configuration: configuration) { _, error in
            XCTAssertNil(error)
            opened.fulfill()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 15), .completed)

        let window = app.windows.firstMatch
        let a = WorkspaceUITestSupport.fileTab(first, in: window)
        let b = WorkspaceUITestSupport.fileTab(second, in: window)
        XCTAssertTrue(a.waitForExistence(timeout: 15))
        XCTAssertTrue(b.waitForExistence(timeout: 15))
        b.click()
        a.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        XCTAssertTrue(app.menus.allElementsBoundByIndex.contains {
            $0.menuItems["Close"].exists && $0.menuItems["Close Others"].exists
        })
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(a.exists && b.exists)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(b.waitForNonExistence(timeout: 12),
                      "Escape must clear the transient menu target before the next Cmd-W")
        XCTAssertTrue(a.exists && window.exists)
        XCTAssertEqual(try Data(contentsOf: first), Data("left original\n".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("right original\n".utf8))
    }

    func testOpenFileTabContextMenuCommandWClosesOnlyRightClickedTab() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("left.txt", text: "first\n")
        let second = try fixture.file("right.txt", text: "second\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let bundle = try XCTUnwrap(NSRunningApplication.runningApplications(
            withBundleIdentifier: "chiimagnus.bailey.dev").compactMap(\.bundleURL).first)
        XCTAssertTrue(bundle.path.contains("DerivedData-Dev/Build/Products/Debug/"))
        let opened = expectation(description: "Open two fixture files")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([first, second], withApplicationAt: bundle,
                                configuration: configuration) { _, error in
            XCTAssertNil(error)
            opened.fulfill()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 15), .completed)

        let window = app.windows.firstMatch
        let a = WorkspaceUITestSupport.fileTab(first, in: window)
        let b = WorkspaceUITestSupport.fileTab(second, in: window)
        XCTAssertTrue(a.waitForExistence(timeout: 15))
        XCTAssertTrue(b.waitForExistence(timeout: 15))
        b.click()
        a.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        XCTAssertTrue(app.menus.allElementsBoundByIndex.contains {
            $0.menuItems["Close"].exists && $0.menuItems["Close Others"].exists
        }, "The native tab menu must be open before Cmd-W")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(a.waitForNonExistence(timeout: 12))
        XCTAssertTrue(b.exists && window.exists,
                      "Only the right-clicked inactive file tab may close")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first\n")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second\n")
    }

    func testCommandPaletteClosePanelUsesTheActiveTool() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("persist.txt", text: "not edited\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let files = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        let git = WorkspaceUITestSupport.element("bailey.dock.git", in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 15))
        XCTAssertTrue(git.waitForExistence(timeout: 15))
        files.click()
        app.typeKey("p", modifierFlags: .command)
        let search = app.textFields["bailey.commandPalette.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.typeText("Close Panel")
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(files.waitForNonExistence(timeout: 12))
        XCTAssertTrue(git.exists)
        XCTAssertTrue(app.windows.firstMatch.exists)
        XCTAssertEqual(try Data(contentsOf: file), Data("not edited\n".utf8))
    }

    func testRightClickInactiveFileTabClosesOnlyThatTab() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("first-tab.txt", text: "first\n")
        let second = try fixture.file("second-tab.txt", text: "second\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let window = app.windows.firstMatch
        let firstRow = WorkspaceUITestSupport.fileRow(first, in: window)
        let secondRow = WorkspaceUITestSupport.fileRow(second, in: window)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 15))
        firstRow.doubleClick()
        XCTAssertTrue(secondRow.waitForExistence(timeout: 15))
        secondRow.doubleClick()
        let firstTab = WorkspaceUITestSupport.fileTab(first, in: window)
        let secondTab = WorkspaceUITestSupport.fileTab(second, in: window)
        XCTAssertTrue(firstTab.waitForExistence(timeout: 12))
        XCTAssertTrue(secondTab.waitForExistence(timeout: 12))

        firstTab.hover()
        let before = try contextOutlinePixels(of: firstTab)
        firstTab.rightClick()
        XCTAssertTrue(app.menuItems["Close"].waitForExistence(timeout: 8))
        XCTAssertNotEqual(try contextOutlinePixels(of: firstTab), before,
                          "The inactive tab must show a context outline while its menu is open")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        firstTab.hover()
        XCTAssertEqual(try contextOutlinePixels(of: firstTab), before,
                       "Dismissal must remove the temporary context outline")
        firstTab.rightClick()
        let contextMenu = try XCTUnwrap(app.menus.allElementsBoundByIndex.first {
            $0.menuItems["Close Others"].exists && $0.menuItems["Close"].exists
        }, "Only the tab context menu can close this inactive tab")
        contextMenu.menuItems["Close"].click()
        XCTAssertTrue(firstTab.waitForNonExistence(timeout: 12))
        XCTAssertTrue(secondTab.exists, "Right-clicking an inactive tab must not replace the active one")
        XCTAssertEqual(try Data(contentsOf: first), Data("first\n".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second\n".utf8))
    }

    func testProjectKeyboardCursorAndContextSurviveBackgroundDeletion() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let firstFile = try fixture.file("alpha-workspace/unchanged.txt", text: "alpha bytes\n")
        let secondFile = try fixture.file("bravo-workspace/unchanged.txt", text: "bravo bytes\n")
        let thirdFile = try fixture.file("charlie-workspace/unchanged.txt", text: "charlie bytes\n")
        let folders = [firstFile, secondFile, thirdFile].map { $0.deletingLastPathComponent() }

        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: folders[0]
        )
        let window = app.windows.firstMatch
        func row(_ index: Int) -> XCUIElement {
            window.descendants(matching: .any)
                .matching(identifier: "bailey.project.row")
                .matching(NSPredicate(format: "label CONTAINS %@", folders[index].lastPathComponent))
                .firstMatch
        }
        for index in 1..<folders.count {
            app.typeKey("a", modifierFlags: [.command, .shift])
            try WorkspaceUITestSupport.choose(folders[index], in: app, window: window)
            XCTAssertTrue(row(index).waitForExistence(timeout: 15))
        }
        XCTAssertEqual(window.descendants(matching: .any)
            .matching(identifier: "bailey.project.row").count, 3)

        let projects = WorkspaceUITestSupport.element("bailey.dock.projects", in: app)
        let projectContextMenu = app.menus.matching(identifier: "bailey.project.row").firstMatch
        XCTAssertTrue(projects.waitForExistence(timeout: 15))
        projects.click()
        row(0).click()
        XCTAssertTrue(row(0).isSelected)
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        XCTAssertTrue(row(0).isSelected, "Arrow keys must not activate the cursor project")
        XCTAssertFalse(row(1).isSelected)
        row(2).rightClick()
        XCTAssertTrue(projectContextMenu.menuItems["Close Project"].waitForExistence(timeout: 10))
        XCTAssertTrue(row(0).isSelected, "Right-clicking a third project cannot activate it")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(row(1).isSelected, "Return must commit the keyboard cursor, not the menu target")

        row(0).click()
        XCTAssertTrue(row(0).isSelected)
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        row(1).rightClick()
        XCTAssertTrue(projectContextMenu.menuItems["Close Project"].waitForExistence(timeout: 10))
        projectContextMenu.menuItems["Close Project"].click()
        XCTAssertTrue(row(1).waitForNonExistence(timeout: 12))
        XCTAssertTrue(row(0).isSelected, "Closing a background cursor project cannot activate another")
        XCTAssertTrue(row(2).exists)
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(row(0).isSelected, "Return cannot select the deleted project UUID")
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(row(2).isSelected,
                      "After removal, the arrow cursor must follow the remaining project order")

        app.typeKey(XCUIKeyboardKey.upArrow, modifierFlags: [])
        XCTAssertTrue(row(2).isSelected, "Arrow alone cannot activate another project")
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(row(0).isSelected, "Space must activate the keyboard cursor project")
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(row(2).isSelected)

        row(0).click(forDuration: 0.12, thenDragTo: row(2))
        let ordered = window.descendants(matching: .any)
            .matching(identifier: "bailey.project.row").allElementsBoundByIndex
        XCTAssertEqual(ordered.count, 2)
        XCTAssertTrue(ordered[0].label.contains(folders[2].lastPathComponent),
                      "Dragging A onto C must reorder the projects, not change their identities")
        XCTAssertTrue(ordered[1].label.contains(folders[0].lastPathComponent))
        XCTAssertTrue(row(2).isSelected, "Reordering a background row cannot switch projects")

        row(0).rightClick()
        XCTAssertTrue(projectContextMenu.menuItems["Close Project"].waitForExistence(timeout: 10))
        projectContextMenu.menuItems["Close Project"].click()
        XCTAssertTrue(row(0).waitForNonExistence(timeout: 12))
        XCTAssertTrue(row(2).isSelected, "Closing the last background project cannot switch context")
        row(2).rightClick()
        XCTAssertTrue(projectContextMenu.menuItems["Close Project"].waitForExistence(timeout: 10))
        projectContextMenu.menuItems["Close Project"].click()
        XCTAssertTrue(window.buttons["bailey.emptyState.addFolder"].waitForExistence(timeout: 12))
        XCTAssertEqual(window.descendants(matching: .any)
            .matching(identifier: "bailey.project.row").count, 0)
        XCTAssertEqual(try Data(contentsOf: firstFile), Data("alpha bytes\n".utf8))
        XCTAssertEqual(try Data(contentsOf: secondFile), Data("bravo bytes\n".utf8))
        XCTAssertEqual(try Data(contentsOf: thirdFile), Data("charlie bytes\n".utf8))
    }

    func testProjectContextMenuExposesOnlyCloseAndUsesFolderName() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("folder-first.txt", text: "project contents\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let projects = WorkspaceUITestSupport.element("bailey.dock.projects", in: app)
        XCTAssertTrue(projects.waitForExistence(timeout: 15))
        projects.click()

        let row = app.descendants(matching: .any)
            .matching(identifier: "bailey.project.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertTrue(row.label.contains(fixture.root.lastPathComponent),
                      "The project name must be derived from its directory")
        row.hover()
        let before = try contextOutlinePixels(of: row)
        row.rightClick()
        XCTAssertTrue(app.menuItems["Close Project"].waitForExistence(timeout: 10))
        for removed in ["Rename…", "Use Automatic Title", "Set Project Directory…",
                        "Use Automatic Directory"] {
            XCTAssertFalse(app.menuItems[removed].exists,
                           "Project menu must not expose removed action \(removed)")
        }
        XCTAssertNotEqual(try contextOutlinePixels(of: row), before,
                          "The project context outline must be visible only during menu tracking")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        row.hover()
        XCTAssertEqual(try contextOutlinePixels(of: row), before,
                       "Dismissal must remove the project context outline")
    }

    private func contextOutlinePixels(of element: XCUIElement) throws -> Data {
        let tiff = try XCTUnwrap(element.screenshot().image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let height = bitmap.pixelsHigh
        let width = bitmap.pixelsWide
        var rgb: [UInt8] = []
        for y in (height / 3)..<(2 * height / 3) {
            for x in [1, 2, 3, max(0, width - 4), max(0, width - 3), max(0, width - 2)] {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                else { continue }
                rgb += [color.redComponent, color.greenComponent, color.blueComponent].map {
                    UInt8(max(0, min(255, Int($0 * 255))))
                }
            }
        }
        return Data(rgb)
    }

    func testClosingExplicitlyActivatedProjectsKeepsFilesWithoutDragging() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("unchanged.swift", text: "original bytes\n")
        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
        let projects = WorkspaceUITestSupport.element("bailey.dock.projects", in: app)
        let files = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        XCTAssertTrue(projects.waitForExistence(timeout: 15))
        XCTAssertTrue(files.waitForExistence(timeout: 15))
        XCTAssertTrue(projects.isHittable,
                      "The default narrow Projects group must expose a clickable header tab")
        projects.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.exists,
                      "Closing an active tool must not close the main app window")
        XCTAssertTrue(projects.waitForNonExistence(timeout: 12))
        XCTAssertTrue(files.exists, "Closing Projects alone must preserve the Files panel")
        XCTAssertTrue(app.windows.firstMatch.exists)
    }

    func testDockFocusHandoffNeverSendsKeysToHiddenEditor() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("project/a-first.swift", text: "first file\n")
        let file = try fixture.file("project/b-focused.swift", text: "do not change this file\n")
        let projectRoot = fixture.root.appendingPathComponent("project", isDirectory: true)
        let app = try WorkspaceUITestSupport.launch(in: self, project: projectRoot)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.doubleClick()
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertEqual(editor.value as? String, "do not change this file\n")
        editor.click()

        let blankFilesArea = window.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: window.frame.width * 0.92, dy: window.frame.height * 0.80))
        blankFilesArea.click()
        app.typeKey("z", modifierFlags: [])
        XCTAssertEqual(editor.value as? String, "do not change this file\n",
                       "After clicking an empty tool pane, typing must not reach the old editor")

        WorkspaceUITestSupport.element("bailey.dock.git", in: app).click()
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        app.typeKey(XCUIKeyboardKey.upArrow, modifierFlags: [])
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(first, in: window)
            .waitForExistence(timeout: 15),
            "Returning from Git to Files must restore the visible tree's keyboard navigation")
        XCTAssertEqual(try Data(contentsOf: file), Data("do not change this file\n".utf8))
        XCTAssertEqual(try Data(contentsOf: first), Data("first file\n".utf8))
    }
}
