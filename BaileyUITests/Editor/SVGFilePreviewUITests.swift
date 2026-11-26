import AppKit
import XCTest

@MainActor
final class SVGFilePreviewUITests: XCTestCase {
    func testDefaultVectorPaintsAndSharesSourceAndCompanionActions() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = """
            <svg xmlns="http://www.w3.org/2000/svg" width="360" height="220" viewBox="-180 -110 360 220">
              <defs>
                <pattern id="paper" width="2" height="2" patternUnits="userSpaceOnUse"><rect width="2" height="2" fill="#f11a14"/></pattern>
                <foreignObject width="1" height="1"/>
                <symbol id="sheet" viewBox="0 0 36 22"><rect width="36" height="22"/></symbol>
              </defs>
              <use href="#sheet" x="-180" y="-110" width="360" height="220" fill="url(#paper)"/>
            </svg>
            """
        let file = try fixture.file("图形.SVG", text: source)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let preview = WorkspaceUITestSupport.element("bailey.svg.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 12))
        func redCenter() -> Bool {
            guard let bitmap = NSBitmapImageRep(data: window.screenshot().pngRepresentation) else { return false }
            let origin = window.frame.origin
            let column = Int((preview.frame.midX - origin.x) * CGFloat(bitmap.pixelsWide) / window.frame.width)
            let row = Int((preview.frame.midY - origin.y) * CGFloat(bitmap.pixelsHigh) / window.frame.height)
            guard (0..<bitmap.pixelsWide).contains(column), (0..<bitmap.pixelsHigh).contains(row),
                  let color = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { return false }
            return color.redComponent > 0.6 && color.redComponent > 2 * max(color.greenComponent, color.blueComponent)
        }
        let painted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in redCenter() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [painted], timeout: 8), .completed)
        let omitted = app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@ OR label CONTAINS %@", "omits: foreignObject", "omits: foreignObject"
        )).firstMatch
        XCTAssertTrue(omitted.exists)

        let tab = WorkspaceUITestSupport.fileTab(file, in: window)
        tab.rightClick()
        let split = WorkspaceUITestSupport.menuItem("Show Side by Side", in: app)
        XCTAssertTrue(split.waitForExistence(timeout: 5))
        split.click()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        preview.click()
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(preview.waitForNonExistence(timeout: 10))
        XCTAssertTrue((window.textViews.firstMatch.value as? String)?.contains("<pattern id=\"paper\"") == true)
        XCTAssertEqual(try Data(contentsOf: file), Data(source.utf8))
    }

    func testLargeSVGFitShowsAllFourCornersAfterSourceRemount() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = """
            <svg xmlns="http://www.w3.org/2000/svg" width="1400" height="620">
              <rect width="700" height="310" fill="#ff0000"/>
              <rect x="700" width="700" height="310" fill="#00ff00"/>
              <rect y="310" width="700" height="310" fill="#0000ff"/>
              <rect x="700" y="310" width="700" height="310" fill="#ffff00"/>
            </svg>
            """
        let file = try fixture.file("Large.svg", text: source)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let preview = WorkspaceUITestSupport.element("bailey.svg.preview", in: app)

        func showsWholeImage() -> Bool {
            guard preview.exists,
                  let bitmap = NSBitmapImageRep(data: window.screenshot().pngRepresentation) else { return false }
            let frame = window.frame
            let sx = CGFloat(bitmap.pixelsWide) / frame.width
            let sy = CGFloat(bitmap.pixelsHigh) / frame.height
            let visible = preview.frame
            let width = min(visible.width * sx, visible.height * sy * 1400 / 620)
            let height = width * 620 / 1400
            let center = CGPoint(x: (visible.midX - frame.minX) * sx,
                                 y: (visible.midY - frame.minY) * sy)
            let samples: [(CGFloat, CGFloat, (NSColor) -> Bool)] = [
                (-0.25, -0.25, { $0.redComponent - max($0.greenComponent, $0.blueComponent) > 0.5 }),
                (0.25, -0.25, { $0.greenComponent - max($0.redComponent, $0.blueComponent) > 0.35 }),
                (-0.25, 0.25, { $0.blueComponent - max($0.redComponent, $0.greenComponent) > 0.5 }),
                (0.25, 0.25, { min($0.redComponent, $0.greenComponent) - $0.blueComponent > 0.5 }),
            ]
            return samples.allSatisfy { dx, dy, matches in
                let x = Int(center.x + dx * width), y = Int(center.y + dy * height)
                guard (0..<bitmap.pixelsWide).contains(x), (0..<bitmap.pixelsHigh).contains(y),
                      let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                return matches(color)
            }
        }

        for remounted in [false, true] {
            if remounted {
                preview.click()
                app.typeKey("v", modifierFlags: [.command, .shift])
                XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 10))
                window.textViews.firstMatch.click()
                app.typeKey("v", modifierFlags: [.command, .shift])
            }
            XCTAssertTrue(preview.waitForExistence(timeout: 12))
            let painted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                showsWholeImage()
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [painted], timeout: 10), .completed,
                           "Fit must display the complete document, including the right and bottom halves")
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = remounted ? "large-fit-remounted" : "large-fit"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(try Data(contentsOf: file), Data(source.utf8))
    }

    func testNativeZoomResolvesFineVectorDetailInTheActualWindow() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let stripes = (0..<40).map { column in
            "<rect x=\"\(10 + Double(column) * 0.5)\" width=\"0.25\" height=\"40\" fill=\"black\"/>"
        }.joined()
        let source = """
            <svg xmlns="http://www.w3.org/2000/svg" width="80" height="40">
              <rect width="80" height="40" fill="white"/>\(stripes)
            </svg>
            """
        let file = try fixture.file("Fine detail.svg", text: source)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let preview = WorkspaceUITestSupport.element("bailey.svg.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 12))
        XCTAssertEqual(preview.label, "SVG preview, Fit")
        XCTAssertEqual(preview.value as? String, "Fit")
        preview.rightClick()
        let actual = WorkspaceUITestSupport.menuItem("100%", in: app)
        XCTAssertTrue(actual.waitForExistence(timeout: 5))
        actual.click()
        XCTAssertEqual(preview.value as? String, "100%")
        XCTAssertEqual(preview.label, "SVG preview, 100%")
        for _ in 0..<9 {
            preview.rightClick()
            let zoom = WorkspaceUITestSupport.menuItem("Zoom in", in: app)
            XCTAssertTrue(zoom.waitForExistence(timeout: 5))
            zoom.click()
        }
        let painted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let bitmap = NSBitmapImageRep(data: window.screenshot().pngRepresentation) else { return false }
            let frame = window.frame
            let centerX = (preview.frame.midX - frame.minX) * CGFloat(bitmap.pixelsWide) / frame.width
            let y = Int((preview.frame.midY - frame.minY) * CGFloat(bitmap.pixelsHigh) / frame.height)
            let scale = CGFloat(pow(1.25 as Double, 9 as Double))
            let left = Int(centerX + (12 - 40) * scale)
            let right = Int(centerX + (28 - 40) * scale)
            guard (0..<bitmap.pixelsHigh).contains(y), left >= 0, right <= bitmap.pixelsWide else { return false }
            let channels = (left..<right).compactMap {
                bitmap.colorAt(x: $0, y: y)?.usingColorSpace(.sRGB)?.redComponent
            }
            let transitions = zip(channels, channels.dropFirst()).filter { abs($0 - $1) > 0.5 }.count
            return channels.count == right - left && transitions > 30
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [painted], timeout: 10), .completed,
                       "The actual window must resolve quarter-unit vector bands above 400%, not enlarge a cached fit bitmap")
        XCTAssertEqual(preview.value as? String, pow(1.25, 9).formatted(.percent.precision(.fractionLength(0))))
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "fine-vector-above-400-percent"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(try Data(contentsOf: file), Data(source.utf8))
    }

    func testInvalidSVGOffersItsUnchangedSource() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let invalid = "<svg><g>"
        let oversized = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"3000\" height=\"3000\"/>"
        let fixtures = [
            (try fixture.file("invalid.svg", text: invalid), invalid, "Could not display this SVG."),
            (try fixture.file("oversized.svg", text: oversized), oversized,
             "SVG is too large to preview. You can still edit the source."),
        ]
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        for (file, source, reason) in fixtures {
            let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            row.doubleClick()
            let message = app.staticTexts.matching(NSPredicate(
                format: "value BEGINSWITH %@ OR label BEGINSWITH %@", reason, reason
            )).firstMatch
            XCTAssertTrue(message.waitForExistence(timeout: 10))
            let showSource = WorkspaceUITestSupport.element("bailey.svg.showSource", in: app)
            XCTAssertTrue(showSource.waitForExistence(timeout: 5))
            showSource.click()
            let editor = app.windows.firstMatch.textViews.firstMatch
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            XCTAssertTrue((editor.value as? String)?.contains(source) == true)
            XCTAssertEqual(try Data(contentsOf: file), Data(source.utf8))
        }
    }

    func testLiveSVGPreservesLastValidPixelsAndNativeUndoAcrossInvalidEdits() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let original = ##"<svg xmlns="http://www.w3.org/2000/svg" width="360" height="220"><rect width="360" height="220" fill="#ff0000"/></svg>"##
        let invalid = String(original.dropLast("</svg>".count))
        let updated = original.replacingOccurrences(of: "#ff0000", with: "#00ff00")
        let file = try fixture.file("Live.svg", text: original)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let preview = WorkspaceUITestSupport.element("bailey.svg.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 12))
        let tab = WorkspaceUITestSupport.fileTab(file, in: window)
        tab.rightClick()
        let split = WorkspaceUITestSupport.menuItem("Show Side by Side", in: app)
        XCTAssertTrue(split.waitForExistence(timeout: 5))
        split.click()
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let stale = window.staticTexts["SVG preview not updated."]
        let error = window.staticTexts.matching(NSPredicate(
            format: "value BEGINSWITH %@ OR label BEGINSWITH %@",
            "Could not display this SVG.", "Could not display this SVG."
        )).firstMatch
        func checkPixels(green: Bool) {
            let painted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard preview.exists,
                      let bitmap = NSBitmapImageRep(data: window.screenshot().pngRepresentation) else { return false }
                let frame = window.frame, point = preview.frame
                let x = Int((point.midX - frame.minX) * CGFloat(bitmap.pixelsWide) / frame.width)
                let y = Int((point.midY - frame.minY) * CGFloat(bitmap.pixelsHigh) / frame.height)
                guard (0..<bitmap.pixelsWide).contains(x), (0..<bitmap.pixelsHigh).contains(y),
                      let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                // A window screenshot contains display-profile transformed colors.
                // Require a bright, strongly dominant channel, not the source RGB ratio.
                return green ? color.greenComponent > 0.6 && color.greenComponent - max(color.redComponent, color.blueComponent) > 0.35
                    : color.redComponent > 0.6 && color.redComponent - max(color.greenComponent, color.blueComponent) > 0.35
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [painted], timeout: 10), .completed)
        }
        func replaceSource(_ value: String) {
            editor.typeKey("a", modifierFlags: .command)
            NSPasteboard.general.clearContents()
            XCTAssertTrue(NSPasteboard.general.setString(value, forType: .string))
            editor.typeKey("v", modifierFlags: .command)
            XCTAssertEqual(editor.value as? String, value)
        }
        func checkInvalid(retainedGreen: Bool) {
            XCTAssertTrue(error.waitForExistence(timeout: 10))
            XCTAssertTrue(stale.exists)
            checkPixels(green: retainedGreen)
        }
        func checkValid(green: Bool) {
            XCTAssertTrue(stale.waitForNonExistence(timeout: 10))
            XCTAssertFalse(error.exists)
            checkPixels(green: green)
        }

        editor.click()
        checkValid(green: false)
        replaceSource(invalid)
        checkInvalid(retainedGreen: false)
        replaceSource(updated)
        checkValid(green: true)
        editor.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, invalid)
        checkInvalid(retainedGreen: true)
        editor.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, original)
        checkValid(green: false)
        editor.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertEqual(editor.value as? String, invalid)
        checkInvalid(retainedGreen: false)
        editor.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertEqual(editor.value as? String, updated)
        checkValid(green: true)
        XCTAssertEqual(try Data(contentsOf: file), Data(original.utf8))
        editor.typeKey("s", modifierFlags: .command)
        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: file)) == Data(updated.utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: 10), .completed)

        preview.rightClick()
        let copy = WorkspaceUITestSupport.menuItem("Copy PNG…", in: app)
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.click()
        let sheet = window.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 8))
        let clipboard = NSPasteboard.general
        let version = clipboard.changeCount
        sheet.buttons["Copy"].click()
        let copied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            clipboard.changeCount != version && clipboard.data(forType: .png) != nil
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: 10), .completed)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(clipboard.data(forType: .png))))
        XCTAssertEqual(bitmap.pixelsWide, 360)
        XCTAssertEqual(bitmap.pixelsHigh, 220)
        let color = try XCTUnwrap(bitmap.colorAt(x: 180, y: 110)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.greenComponent - max(color.redComponent, color.blueComponent), 0.6)

        preview.rightClick()
        let export = WorkspaceUITestSupport.menuItem("Export PNG…", in: app)
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.click()
        let destination = fixture.root.appendingPathComponent("Live.png")
        try WorkspaceUITestSupport.saveFile(destination, in: app, window: window)
        let exported = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: destination.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [exported], timeout: 10), .completed)
        let exportedBitmap = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: destination)))
        XCTAssertEqual(exportedBitmap.pixelsWide, 360)
        XCTAssertEqual(exportedBitmap.pixelsHigh, 220)
        let exportedColor = try XCTUnwrap(exportedBitmap.colorAt(x: 180, y: 110)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(exportedColor.greenComponent - max(exportedColor.redComponent, exportedColor.blueComponent), 0.6)
        XCTAssertEqual(try Data(contentsOf: file), Data(updated.utf8))
    }

    func testPNGOutputMenusOfferExplicitOptionsAndCancelWithoutChangingFiles() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = #"<svg xmlns="http://www.w3.org/2000/svg" width="80" height="40"><rect width="80" height="40" fill="red"/></svg>"#
        let file = try fixture.file("Diagram.svg", text: source)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let preview = WorkspaceUITestSupport.element("bailey.svg.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 12))
        let clipboardChangeCount = NSPasteboard.general.changeCount
        for title in ["Copy PNG…", "Export PNG…"] {
            preview.rightClick()
            let action = WorkspaceUITestSupport.menuItem(title, in: app)
            XCTAssertTrue(action.waitForExistence(timeout: 5))
            action.click()
            let sheet = window.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 8))
            let cancel = sheet.buttons["Cancel"]
            XCTAssertTrue(cancel.waitForExistence(timeout: 5))
            XCTAssertTrue(sheet.staticTexts["Pixel width"].exists, sheet.debugDescription)
            XCTAssertTrue(sheet.staticTexts["Pixel height"].exists, sheet.debugDescription)
            XCTAssertTrue(sheet.staticTexts["Color space"].exists, sheet.debugDescription)
            XCTAssertTrue(sheet.staticTexts["Background"].exists, sheet.debugDescription)
            cancel.click()
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 8))
            XCTAssertTrue(preview.exists)
            XCTAssertEqual(try Data(contentsOf: file), Data(source.utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appending(path: "Diagram.png").path))
            XCTAssertEqual(NSPasteboard.general.changeCount, clipboardChangeCount)
        }
    }

    func testCompressedSVGShowsAnActionableMessageAndDoesNotEnterPreview() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let bytes = try XCTUnwrap(Data(base64Encoded:
            "H4sIAAAAAAAAAxXMQQ6DMAwF0atY/wDYhF0VZ8FNqpImkdJSgYU5fmE9TxP3o9D56d9dUc1+D2Z3H3wa1q1wEBG+BOho2ef1VAgJBaFRkOKWX0beFquKIKCaW6mmuCK9W+8Ky88OTvGepD+3uwqDbAAAAA=="
        ))
        let compressed = fixture.root.appending(path: "Diagram.SVGZ")
        try bytes.write(to: compressed)
        let xml = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 10"><rect width="20" height="10" fill="teal"/></svg>"#
        let original = try fixture.file("Diagram.svg", text: xml)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(compressed, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let message = window.staticTexts["Compressed SVG is not supported. Open an uncompressed SVG file."]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        let preview = WorkspaceUITestSupport.element("bailey.svg.preview", in: app)
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(message.exists)
        XCTAssertFalse(preview.exists)
        XCTAssertFalse(window.textViews.firstMatch.exists)
        WorkspaceUITestSupport.fileRow(original, in: window).doubleClick()
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertEqual(try Data(contentsOf: compressed), bytes)
        XCTAssertEqual(try Data(contentsOf: original), Data(xml.utf8))
    }

    func testSVGPreviewByteBudgetKeepsTheOverLimitDocumentAvailableAsSource() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let prefix = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"180\" height=\"120\">\n<!--"
        let suffix = "--><rect width=\"180\" height=\"120\" fill=\"red\"/></svg>"
        let byteLimit = 1 << 20
        let remaining = byteLimit - prefix.utf8.count - suffix.utf8.count
        let line = String(repeating: " ", count: 1023) + "\n"
        let exact = prefix + String(repeating: line, count: remaining / 1024)
            + String(repeating: " ", count: remaining % 1024) + suffix
        let overflow = exact + "\n"
        XCTAssertEqual(exact.utf8.count, byteLimit)
        XCTAssertEqual(overflow.utf8.count, byteLimit + 1)
        let accepted = try fixture.file("Exact.svg", text: exact)
        let tooLarge = try fixture.file("Overflow.svg", text: overflow)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true)
        let window = app.windows.firstMatch
        func open(_ url: URL) {
            let row = WorkspaceUITestSupport.fileRow(url, in: window)
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            row.doubleClick()
        }

        open(accepted)
        let preview = WorkspaceUITestSupport.element("bailey.svg.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        let painted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let bitmap = NSBitmapImageRep(data: preview.screenshot().pngRepresentation),
                  let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB)
            else { return false }
            return color.redComponent - color.greenComponent > 0.45
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [painted], timeout: 8), .completed)

        open(tooLarge)
        let reason = "SVG is too large to preview. You can still edit the source."
        let message = app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", reason, reason)).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertFalse(preview.exists)
        WorkspaceUITestSupport.element("bailey.svg.showSource", in: app).click()
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, overflow)
        XCTAssertEqual(try Data(contentsOf: accepted), Data(exact.utf8))
        XCTAssertEqual(try Data(contentsOf: tooLarge), Data(overflow.utf8))
    }
}
