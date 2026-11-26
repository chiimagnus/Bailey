import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Bailey

@MainActor
func requireDelimitedEdit(_ file: FileTab, _ change: DelimitedTableMutation.Change, using snapshot: FileTab.DelimitedSnapshot,
                          file path: StaticString = #filePath, line: UInt = #line) async throws {
    let task = try XCTUnwrap(file.submitDelimitedEdit(change, using: snapshot), file: path, line: line)
    let success = await task.value
    XCTAssertTrue(success, file.delimitedTable.editError ?? "", file: path, line: line)
}

@MainActor
final class DelimitedTableIndexTests: XCTestCase {
    func testColumnStructureKeepsOriginalTokensAndEveryRecordBoundary() async throws {
        let tokens = [
            ["Name", "\"Label\"", "Tail"],
            ["001", "\"line\r\npart\"", ""],
            ["", "\"q\"\"q\"", "末尾"],
            ["", "", ""],
        ]
        let endings = ["\r\n", "\r", "\n", ""]
        let source = zip(tokens, endings).map { $0.0.joined(separator: ",") + $0.1 }.joined()
        let index = try await DelimitedTableIndex.parse(source, preferred: .comma, selected: .comma)
        XCTAssertNil(index.issue)
        let orders: [[Int?]] = [
            [nil, 0, 1, 2], [0, nil, 1, 2], [0, 1, nil, 2], [0, 1, 2, nil],
            [1, 2], [0, 2], [0, 1], [1],
            [0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0],
        ]
        for order in orders {
            let expected = zip(tokens.indices, tokens).map { row, fields in
                var body = order.map { $0.map { fields[$0] } ?? "" }.joined(separator: ",")
                if body.isEmpty && (row == tokens.count - 1 || endings[row - 1] == "\r" && endings[row] == "\n") {
                    body = "\"\""
                }
                return body + endings[row]
            }.joined()
            let edits = try await DelimitedTableMutation.prepare(.columns(order), source: source, index: index, encoding: .utf8BOM)
            let actual = NSMutableString(string: source)
            for edit in edits {
                XCTAssertEqual(actual.substring(with: edit.range), edit.old)
                actual.replaceCharacters(in: edit.range, with: edit.new)
            }
            XCTAssertEqual(Data((actual as String).utf8), Data(expected.utf8), "\(order)")
        }

        for order: [Int?] in [[], [0, 0], [3], [-1]] {
            do {
                _ = try await DelimitedTableMutation.prepare(.columns(order), source: source, index: index, encoding: .utf8BOM)
                XCTFail("Invalid column order \(order)")
            } catch DelimitedTableMutation.Failure.invalidSelection {}
        }
        for (text, order, expected) in [
            ("one\r\ntwo", [nil, 0] as [Int?], ",one\r\n,two"),
            ("other,\rnext,\nother,", [1] as [Int?], "\r\"\"\n\"\""),
            ("head,", [1] as [Int?], "\"\""),
        ] {
            let index = try await DelimitedTableIndex.parse(text, preferred: .comma, selected: .comma)
            let edits = try await DelimitedTableMutation.prepare(.columns(order), source: text, index: index, encoding: .utf8)
            let actual = NSMutableString(string: text)
            for edit in edits { actual.replaceCharacters(in: edit.range, with: edit.new) }
            XCTAssertEqual(Data((actual as String).utf8), Data(expected.utf8))
        }
    }

    func testColumnOperationsRoundTripEverySupportedEncodingAndDelimiter() async throws {
        let orders: [[Int?]] = [
            [nil, 0, 1, 2], [0, nil, 1, 2], [0, 1, nil, 2], [0, 1, 2, nil],
            [1, 2], [0, 2], [0, 1], [0], [1], [2],
            [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0],
        ]
        for separator in DelimitedTableIndex.Separator.allCases {
            let delimiter = String(UnicodeScalar(separator.rawValue)!)
            for encoding in TextFileEncoding.choices {
                let tail = try XCTUnwrap(["😀", "中文", "é", "tail"].first { encoding.encoded($0) != nil })
                let tokens = [
                    ["", "", ""],
                    ["001", "\"x\(delimiter)y\r\nz\"", ""],
                    ["", "\"q\"\"q\"", tail],
                    ["", "", ""],
                ]
                let endings = ["\r\n", "\r", "\n", ""]
                let source = zip(tokens, endings).map { $0.0.joined(separator: delimiter) + $0.1 }.joined()
                let original = try XCTUnwrap(encoding.encoded(source))
                let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
                try original.write(to: path)
                defer { try? FileManager.default.removeItem(at: path) }
                let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
                defer { file.retireContent() }
                file.autoSaveSuspendedForClose = true
                file.reopen(using: encoding)
                try await file.waitForText()
                XCTAssertEqual(file.fileEncoding, encoding)
                XCTAssertEqual(TextFileEncoding.hasIdenticalCodeUnits(file.text, source), true)

                for order in orders {
                    let context = "\(encoding.name) / \(separator) / \(order)"
                    let expected = tokens.enumerated().map { row, fields in
                        var body = order.map { $0.map { fields[$0] } ?? "" }.joined(separator: delimiter)
                        if body.isEmpty && (row == tokens.count - 1 || row > 0 && endings[row - 1] == "\r" && endings[row] == "\n") {
                            body = "\"\""
                        }
                        return body + endings[row]
                    }.joined()
                    let bytes = try XCTUnwrap(encoding.encoded(expected))
                    let loaded = try await file.delimitedSnapshot(using: separator)
                    try await requireDelimitedEdit(file, .columns(order), using: XCTUnwrap(loaded))
                    XCTAssertTrue(TextFileEncoding.hasIdenticalCodeUnits(file.text, expected), context)
                    let parsed = try await file.delimitedSnapshot(using: separator)
                    XCTAssertNil(parsed?.index.issue, context)
                    XCTAssertEqual(parsed?.index.records.count, tokens.count, context)
                    XCTAssertEqual(parsed?.index.columnCount, order.count, context)
                    await file.save()
                    XCTAssertEqual(try Data(contentsOf: path), bytes, context)
                    XCTAssertFalse(file.isDirty, context)
                    file.documentUndoManager.undo()
                    XCTAssertTrue(TextFileEncoding.hasIdenticalCodeUnits(file.text, source), context)
                    XCTAssertTrue(file.isDirty, context)
                    XCTAssertFalse(file.documentUndoManager.canUndo, context)
                    await file.save()
                    XCTAssertEqual(try Data(contentsOf: path), original, context)
                    XCTAssertFalse(file.isDirty, context)
                    XCTAssertNil(file.saveError, context)
                }
            }
        }
    }

    func testColumnStructureRejectsHiddenColumnsAndPreservesTheFieldBudget() async throws {
        let limit = DelimitedTableIndex.maximumColumns
        for count in [limit - 1, limit, limit + 1] {
            let source = String(repeating: ",", count: count - 1)
            let index = try await DelimitedTableIndex.parse(source, preferred: .comma, selected: .comma)
            var order = (0..<count).map(Optional.some)
            order.append(nil)
            do {
                let edits = try await DelimitedTableMutation.prepare(.columns(order), source: source, index: index, encoding: .utf8)
                XCTAssertEqual(count, limit - 1)
                XCTAssertEqual(edits.count, 1)
                XCTAssertEqual(edits.first?.new, ",")
            } catch DelimitedTableMutation.Failure.invalidSelection {
                XCTAssertGreaterThanOrEqual(count, limit)
            }
        }
        let source = String(repeating: String(repeating: ",", count: 99) + "\n", count: 9_901)
        let index = try await DelimitedTableIndex.parse(source, preferred: .comma, selected: .comma)
        XCTAssertEqual(index.records.count * index.columnCount, 990_100)
        XCTAssertNil(index.issue)
        do {
            _ = try await DelimitedTableMutation.prepare(.columns((0..<100).map(Optional.some) + [nil]),
                                                          source: source, index: index, encoding: .utf8)
            XCTFail("1,000,001 fields must be refused before touching the document")
        } catch DelimitedTableMutation.Failure.invalidSelection {}
    }

    func testDelimitedFileUsesTheExistingPreviewCompanionAndSourceRoute() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("table.TSV")
        let bytes = Data("item\tvalue\r\n青🧪\t42\r\n".utf8)
        try bytes.write(to: path)
        let project = Project(fallbackName: "Table preview", workspaceConfiguration: .standard)
        project.openLocalFile(path.path)
        let tab = try XCTUnwrap(project.tabs.first)
        guard case .file(let file) = tab.content else { return XCTFail("Expected file tab") }
        try await file.waitForText()
        let storage = file.nativeTextStorage
        XCTAssertEqual(project.filePreviewMode(for: tab), .preview)
        project.setFilePreviewMode(.sideBySide, for: tab)
        XCTAssertEqual(project.filePreviewMode(for: tab), .sideBySide)
        XCTAssertNotNil(project.dock.group(containing: .filePreview(tab.id)))
        project.setFilePreviewMode(.source, for: tab)
        XCTAssertNil(project.dock.group(containing: .filePreview(tab.id)))
        XCTAssertTrue(file.nativeTextStorage === storage)
        XCTAssertEqual(project.tabs.count, 1)
        XCTAssertEqual(try Data(contentsOf: path), bytes)
    }

    func testRestoredTableDropsItsCompanionWhenRenamedAcrossFormats() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("values.csv")
        let destination = directory.appendingPathComponent("values.txt")
        let bytes = Data("Name,Value\na,2\n".utf8)
        try bytes.write(to: path)
        let project = Project(fallbackName: "Restored table", workspaceConfiguration: .standard)
        let tab = project.restoreTab(from: .init(content: .file(path: path.path, editorState: nil)))
        guard case .file(let file) = tab.content else { return XCTFail("Expected restored file") }
        guard case .loading = file.content else { return XCTFail("Restore must keep file IO lazy") }
        try await file.waitForText()
        XCTAssertEqual(project.filePreviewMode(for: tab), .preview)
        project.setFilePreviewMode(.sideBySide, for: tab)
        XCTAssertNotNil(project.dock.group(containing: .filePreview(tab.id)))
        let original = file.nativeTextStorage
        try FileManager.default.moveItem(at: path, to: destination)
        project.updateFilePaths(from: path.path, to: destination.path, workspace: nil)
        XCTAssertEqual(file.path, destination.path)
        XCTAssertEqual(project.filePreviewMode(for: tab), .source)
        XCTAssertFalse(file.canPreviewFile)
        XCTAssertNil(project.dock.group(containing: .filePreview(tab.id)))
        XCTAssertTrue(file.nativeTextStorage === original)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testPhysicalAndLogicalRecordsPreserveUTF16FieldRangesAndTerminators() async throws {
        let text = "\"e\u{301}😀\",,\"a\"\"b\"\r\n\"x\r\ny\rz\nw\",last,\r\r\nend,,!"
        let utf16 = text as NSString
        let index = try await DelimitedTableIndex.parse(text, preferred: .comma)
        let expected = [
            ["\"e\u{301}😀\"", "", "\"a\"\"b\""],
            ["\"x\r\ny\rz\nw\"", "last", ""],
            [""],
            ["end", "", "!"],
        ]
        XCTAssertEqual(index.records.map(\.physicalLine), [1, 2, 6, 7])
        XCTAssertEqual(index.records.map(\.lineEndingLength), [2, 1, 2, 0])
        XCTAssertEqual(index.issue, .init(problem: .unevenColumns(expected: 3, actual: 1), line: 6, column: 1))
        var recordStart = 0
        for (record, row) in zip(index.records, expected) {
            XCTAssertEqual(record.source.location, recordStart)
            var fieldStart = recordStart
            for (field, literal) in zip(index.fields(in: record), row) {
                XCTAssertEqual(field.source, NSRange(location: fieldStart, length: literal.utf16.count))
                XCTAssertEqual(utf16.substring(with: field.source), literal)
                fieldStart += literal.utf16.count + 1
            }
            XCTAssertEqual(index.fields(in: record).count, row.count)
            recordStart = NSMaxRange(record.source)
        }
        XCTAssertEqual(recordStart, utf16.length)
        XCTAssertEqual(index.fields(in: index.records[0]).map { $0.value(in: utf16) }, ["e\u{301}😀", "", "a\"b"])
        XCTAssertEqual(index.fields(in: index.records[1]).first?.value(in: utf16), "x\r\ny\rz\nw")
    }

    func testDelimiterDetectionDoesNotCountQuotedDelimitersAndExposesAmbiguity() async throws {
        for (text, expected) in [
            ("\"x\t;y\",z\r\n\"a\t;b\",c", DelimitedTableIndex.Separator.comma),
            ("\"x\t,y\";z\n\"a\t,b\";c", .semicolon),
            ("\"x;,y\"\tz\n\"a;,b\"\tc", .tab),
        ] {
            let index = try await DelimitedTableIndex.parse(text, preferred: .comma)
            XCTAssertEqual(index.separator, expected)
            XCTAssertFalse(index.needsSeparatorChoice)
            XCTAssertEqual(index.records.count, 2)
            XCTAssertNil(index.issue)
        }
        let source = "a,b;c\n=1,+2;@4"
        let automatic = try await DelimitedTableIndex.parse(source, preferred: .tab)
        XCTAssertTrue(automatic.needsSeparatorChoice)
        let selected = try await DelimitedTableIndex.parse(source, preferred: .tab, selected: .semicolon)
        XCTAssertFalse(selected.needsSeparatorChoice)
        XCTAssertEqual(selected.fields(in: selected.records[1]).map { $0.value(in: source as NSString) },
                       ["=1,+2", "@4"])
        let longFirstField = "\"" + String(repeating: "a", count: 16_384) + "\";second"
        let bounded = try await DelimitedTableIndex.parse(longFirstField, preferred: .comma)
        XCTAssertTrue(bounded.needsSeparatorChoice, "Do not guess outside the sample")
        let corrected = try await DelimitedTableIndex.parse(longFirstField, preferred: .comma, selected: .semicolon)
        XCTAssertEqual(corrected.fields(in: corrected.records[0]).count, 2)
        XCTAssertNil(corrected.issue)
    }

    func testIncidentalDelimitersDoNotMakeRectangularTablesReadOnly() async throws {
        let fixtures: [(String, String, DelimitedTableIndex.Separator, String)] = [
            ("csv", "Name,Note\nalpha,hello; world\nbeta,plain", .comma, "hello; world"),
            ("csv", "Name,Note\nalpha,hello\tworld\nbeta,plain", .comma, "hello\tworld"),
            ("csv", "Name;Value\nalpha;12,5\nbeta;7", .semicolon, "12,5"),
            ("tsv", "Name\tNote\nalpha\thello, world\nbeta\tplain; text", .tab, "hello, world"),
            ("csv", "Name,Note\nalpha,\"quoted; note\"\nbeta,plain", .comma, "quoted; note"),
            ("csv", "Name,Note\nalpha,hello; world\nbeta,\"" + String(repeating: "x", count: 17_000) + "\"", .comma, "hello; world")
        ]
        for (ext, original, separator, firstValue) in fixtures {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            try Data(original.utf8).write(to: path)
            defer { try? FileManager.default.removeItem(at: path) }
            let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            defer { file.retireContent() }
            try await file.waitForText()
            let loaded = try await file.delimitedSnapshot()
            let snapshot = try XCTUnwrap(loaded)
            XCTAssertEqual(snapshot.index.separator, separator, original.prefix(80).description)
            XCTAssertFalse(snapshot.index.needsSeparatorChoice, original.prefix(80).description)
            XCTAssertNil(snapshot.index.issue)
            XCTAssertEqual(snapshot.index.field(record: 1, column: 1)?.value(in: original as NSString), firstValue)
            XCTAssertTrue(file.canEditDelimited(snapshot))
            guard file.canEditDelimited(snapshot) else { continue }
            try await requireDelimitedEdit(file, .cells([.init(row: 1, column: 0): "edited"]), using: snapshot)
            let expected = original.replacingOccurrences(of: "alpha", with: "edited")
            XCTAssertEqual(file.text, expected)
            await file.save()
            XCTAssertEqual(try Data(contentsOf: path), Data(expected.utf8))
        }
    }

    func testEmptyTrailingQuotedAndInvalidFieldsHaveDistinctRangesAndIssues() async throws {
        for (text, values) in [
            ("", []),
            (",", [["", ""]]),
            ("\n", [[""]]),
            ("\"\"\r", [[""]]),
            ("\"\"\"\"", [["\""]]),
            ("\"a\"\"\u{301}\"", [["a\"\u{301}"]]),
            ("a\u{2028}b,\u{2029}\n", [["a\u{2028}b", "\u{2029}"]]),
        ] {
            let index = try await DelimitedTableIndex.parse(text, preferred: .comma)
            XCTAssertNil(index.issue)
            XCTAssertEqual(index.records.map { record in
                index.fields(in: record).map { $0.value(in: text as NSString) }
            }, values)
        }
        for (text, issue) in [
            ("abc,\"x\r\ny", DelimitedTableIndex.Issue(problem: .unclosedQuote, line: 2, column: 2)),
            ("a,b\nx\"y,z", .init(problem: .unexpectedQuote, line: 2, column: 2)),
            ("\"a\"b,x", .init(problem: .textAfterQuote, line: 1, column: 4)),
            ("a,b\r\nx,\0", .init(problem: .nul, line: 2, column: 3)),
        ] {
            let index = try await DelimitedTableIndex.parse(text, preferred: .comma, selected: .comma)
            XCTAssertEqual(index.issue, issue)
            XCTAssertEqual(index.records.count, text.hasPrefix("a,b") ? 1 : 0)
        }
    }

    func testCapacityBoundsAndCancellation() async throws {
        let text = String(repeating: "模型,😀,\r\n", count: 100_000)
        let index = try await DelimitedTableIndex.parse(text, preferred: .comma)
        XCTAssertNil(index.issue)
        XCTAssertEqual(index.records.count, 100_000)
        let last = try XCTUnwrap(index.records.last)
        XCTAssertEqual(index.fields(in: last).map { $0.value(in: text as NSString) }, ["模型", "😀", ""])
        XCTAssertEqual(NSMaxRange(last.source), text.utf16.count)
        let wide = try await DelimitedTableIndex.parse(String(repeating: "field,", count: 2_500), preferred: .comma)
        XCTAssertEqual(wide.fields(in: try XCTUnwrap(wide.records.first)).count, 2_501)
        let tooManyFields = try await DelimitedTableIndex.parse(
            String(repeating: ",", count: 1_000_000), preferred: .comma
        )
        XCTAssertEqual(tooManyFields.issue?.problem, .fieldLimit)
        let length = 32 << 20
        let atLimit = String(repeating: "x", count: length)
        let accepted = try await DelimitedTableIndex.parse(atLimit, preferred: .comma, selected: .comma)
        let record = try XCTUnwrap(accepted.records.first)
        XCTAssertEqual(accepted.fields(in: record).first?.source, NSRange(location: 0, length: length))
        let exceeded = try await DelimitedTableIndex.parse(atLimit + "x", preferred: .comma, selected: .comma)
        XCTAssertEqual(exceeded.issue, .init(problem: .sourceLimit, line: 1, column: length + 1))
        let canceled = Task { try await DelimitedTableIndex.parse(atLimit, preferred: .comma) }
        canceled.cancel()
        do {
            _ = try await canceled.value
            XCTFail("A canceled scan must not return an index")
        } catch is CancellationError {}
    }

    func testFileSnapshotTracksNativeEditsAndRetainsOriginalEncodedBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (encoding, value) in [
            (TextFileEncoding.utf8, "模型😀"),
            (.utf8BOM, "e\u{301}😀"),
            (.utf16LEBOM, "模型😀"),
            (.utf16BEBOM, "模型😀"),
            (.gbk, "模型"),
            (.gb18030, "模型"),
            (.shiftJIS, "日本語"),
            (.latin1, "é"),
        ] {
            let path = directory.appendingPathComponent(UUID().uuidString + ".TSV")
            let original = "name\tvalue\r\n\(value)\t1"
            let bytes = try XCTUnwrap(encoding.encoded(original))
            try bytes.write(to: path)
            let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            file.reopen(using: encoding)
            try await file.waitForText()
            let loaded = try await file.delimitedSnapshot()
            let first = try XCTUnwrap(loaded)
            XCTAssertTrue(file.canEditDelimited(first), encoding.name)
            XCTAssertEqual(first.index.separator, .tab)
            let record = first.index.records[1]
            let field = try XCTUnwrap(first.index.fields(in: record).first)
            XCTAssertEqual((file.nativeTextStorage.string as NSString).substring(with: field.source), value)
            file.nativeTextStorage.replaceCharacters(in: field.source, with: "changed")
            XCTAssertNotEqual(file.textPreviewRequestID, first.requestID)
            let edited = try await file.delimitedSnapshot()
            let next = try XCTUnwrap(edited)
            XCTAssertTrue(file.canEditDelimited(next))
            XCTAssertEqual(next.index.fields(in: next.index.records[1]).first?.source.length, 7)
            XCTAssertEqual(try Data(contentsOf: path), bytes, "Indexing and editing in memory must not publish bytes")
        }
    }

    func testGridMutationsShareTheMountedSourceUndoAndPreserveBytes() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        let original = "Name,Group,Value\r\nItem 10,g,\"old\"\r\nItem 2,g,old\nOther,h,\"literal\""
        let expected = "Name,Group,Value\r\nItem 10,g,\"new\"\"value\"\r\nItem 2,g,\"青🧪,\nline\"\nOther,h,\"literal\""
        let encoding = TextFileEncoding.utf8BOM
        let bytes = try XCTUnwrap(encoding.encoded(original))
        try bytes.write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        file.reopen(using: encoding)
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        defer { file.retireContent() }
        let storage = file.nativeTextStorage
        let undo = file.documentUndoManager
        let loaded = try await file.delimitedSnapshot(using: .comma)
        let snapshot = try XCTUnwrap(loaded)
        XCTAssertNil(file.editorView, "Grid editing must not construct a hidden editor")
        let displayed = try await DelimitedTablePresentation.evaluate(
            source: snapshot.source, index: snapshot.index,
            configuration: .init(filters: [1: "g"], sort: [.init(column: 0, ascending: true)])
        )
        XCTAssertEqual(displayed.rows, [2, 1])
        try await requireDelimitedEdit(file, .cells([
            .init(row: displayed.rows[0], column: 2): "青🧪,\nline",
            .init(row: displayed.rows[1], column: 2): "new\"value",
        ]), using: snapshot)
        XCTAssertEqual(file.text, expected)
        XCTAssertTrue(file.isDirty)
        XCTAssertTrue(file.nativeTextStorage === storage)
        XCTAssertNil(file.editorView)
        XCTAssertEqual(try Data(contentsOf: path), bytes)
        undo.undo()
        XCTAssertEqual(file.text, original)
        XCTAssertFalse(file.isDirty)
        undo.redo()
        XCTAssertEqual(file.text, expected)
        XCTAssertTrue(file.isDirty)

        file.setFilePreview(false)
        let host = NSHostingView(rootView: FileViewerView(file: file))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap((file.editorView as? NSScrollView)?.documentView as? NativeCodeTextView)
        XCTAssertTrue(editor.undoManager === undo)
        editor.insertText("Title", replacementRange: NSRange(location: 0, length: 4))
        editor.breakUndoCoalescing()
        let sourceEdited = "Title" + String(expected.dropFirst(4))
        XCTAssertEqual(file.text, sourceEdited)
        let fresh = try await file.delimitedSnapshot(using: .comma)
        try await requireDelimitedEdit(file, .deleteRows([1, 2]), using: try XCTUnwrap(fresh))
        XCTAssertEqual(file.text, "Title,Group,Value\r\nOther,h,\"literal\"")
        undo.undo()
        XCTAssertEqual(file.text, sourceEdited, "Contiguous deletions undo in physical record order")
        undo.undo()
        XCTAssertEqual(file.text, expected)
        undo.undo()
        XCTAssertEqual(file.text, original)
        XCTAssertFalse(file.isDirty)
        undo.redo()
        XCTAssertEqual(file.text, expected)
        undo.redo()
        XCTAssertEqual(file.text, sourceEdited)
        undo.redo()
        XCTAssertEqual(file.text, "Title,Group,Value\r\nOther,h,\"literal\"")
        undo.undo()
        undo.undo()
        XCTAssertEqual(file.text, expected)
        await file.save()
        XCTAssertEqual(try Data(contentsOf: path), encoding.encoded(expected))
        XCTAssertFalse(file.isDirty)
        XCTAssertNil(file.submitDelimitedEdit(.cells([.init(row: 1, column: 2): "stale"]), using: snapshot))
        XCTAssertEqual(file.text, expected)
    }

    func testHundredLargeGridEditsAndUndoPreserveOriginalCodeUnits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("large.csv")
        let wide = String(repeating: "宽😀a", count: 1024)
        let prefix = "Name,Value\r\n" + (0..<99_999).map {
            "row-\($0),value-\($0)" + ($0.isMultiple(of: 2) ? "\r\n" : "\n")
        }.joined()
        let original = prefix + "\(wide),last-000\r\n"
        let bytes = try XCTUnwrap(TextFileEncoding.utf8BOM.encoded(original))
        try bytes.write(to: path)
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        file.reopen(using: .utf8BOM)
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        defer { file.retireContent() }
        let storage = file.nativeTextStorage
        let undo = file.documentUndoManager
        let clock = ContinuousClock()
        let started = clock.now
        var snapshotTimes: [Duration] = []
        var editTimes: [Duration] = []
        var undoTimes: [Duration] = []
        var redoTimes: [Duration] = []
        for iteration in 1...100 {
            // Repeated mode switching must not reconstruct the document.
            file.setFilePreview(false)
            file.setFilePreview(true)
            let snapshotStart = clock.now
            let result = try await file.delimitedSnapshot(using: .comma)
            snapshotTimes.append(snapshotStart.duration(to: clock.now))
            let snapshot = try XCTUnwrap(result)
            XCTAssertEqual(snapshot.index.records.count, 100_001)
            let value = String(format: "last-%03d", iteration)
            let editStart = clock.now
            try await requireDelimitedEdit(file, .cells([.init(row: 100_000, column: 1): value]), using: snapshot)
            editTimes.append(editStart.duration(to: clock.now))
            XCTAssertTrue(file.isDirty)
            XCTAssertTrue(file.nativeTextStorage === storage)
            XCTAssertNil(file.editorView, "Grid editing must not mount a hidden source editor")
        }
        let final = prefix + "\(wide),last-100\r\n"
        XCTAssertTrue(TextFileEncoding.hasIdenticalCodeUnits(file.text, final))
        XCTAssertEqual(try Data(contentsOf: path), bytes)
        for _ in 0..<100 {
            XCTAssertTrue(undo.canUndo)
            let start = clock.now
            undo.undo()
            undoTimes.append(start.duration(to: clock.now))
        }
        XCTAssertTrue(TextFileEncoding.hasIdenticalCodeUnits(file.text, original))
        XCTAssertFalse(file.isDirty)
        for _ in 0..<100 {
            XCTAssertTrue(undo.canRedo)
            let start = clock.now
            undo.redo()
            redoTimes.append(start.duration(to: clock.now))
        }
        XCTAssertTrue(TextFileEncoding.hasIdenticalCodeUnits(file.text, final))
        XCTAssertTrue(file.isDirty)
        XCTAssertEqual(try Data(contentsOf: path), bytes)
        await file.save()
        XCTAssertEqual(try Data(contentsOf: path), TextFileEncoding.utf8BOM.encoded(final))
        XCTAssertFalse(file.isDirty)
        let reopen = try await file.delimitedSnapshot(using: .comma)
        XCTAssertEqual(reopen?.index.records.count, 100_001)
        func p95(_ times: [Duration]) -> Duration { times.sorted()[94] }
        print("CSV_EDIT_SESSION edits=100 records=100001 elapsed=\(started.duration(to: clock.now)) snapshot_p95=\(p95(snapshotTimes)) edit_p95=\(p95(editTimes)) undo_main_p95=\(p95(undoTimes)) redo_main_p95=\(p95(redoTimes))")
    }

    func testGridRejectsUnrepresentableEditsAndUndoRestoresInsertedRows() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        let original = "Name,Value\r\nCafé,1"
        let bytes = try XCTUnwrap(TextFileEncoding.latin1.encoded(original))
        try bytes.write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        file.reopen(using: .latin1)
        try await file.waitForText()
        defer { file.retireContent() }
        let loaded = try await file.delimitedSnapshot(using: .comma)
        let snapshot = try XCTUnwrap(loaded)
        do {
            _ = try await DelimitedTableMutation.prepare(.cells([.init(row: 1, column: 0): "😀",
                                                                 .init(row: 1, column: 1): "new"]),
                                                         source: snapshot.source, index: snapshot.index, encoding: .latin1)
            XCTFail("The entire transaction must be refused if its encoding cannot round-trip")
        } catch DelimitedTableMutation.Failure.cannotEncode {}
        XCTAssertEqual(file.text, original)
        XCTAssertFalse(file.isDirty)
        XCTAssertFalse(file.documentUndoManager.canUndo)
        try await requireDelimitedEdit(file, .insertRows(before: 2, count: 2), using: snapshot)
        XCTAssertEqual(file.text, original + "\r\n,\r\n,")
        file.documentUndoManager.undo()
        XCTAssertEqual(file.text, original)
        XCTAssertFalse(file.isDirty)
        file.documentUndoManager.redo()
        XCTAssertEqual(file.text, original + "\r\n,\r\n,")
        await file.save()
        XCTAssertEqual(try Data(contentsOf: path), TextFileEncoding.latin1.encoded(file.text))
    }

    func testGridSavesOriginalEncodingAndRejectsAnotherWindowsSameSizeDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (encoding, value) in [
            (TextFileEncoding.utf8BOM, "e\u{301}😀"),
            (.utf16LEBOM, "模型😀"), (.utf16BEBOM, "模型😀"),
            (.gbk, "模型"), (.gb18030, "模型"), (.shiftJIS, "日本語"), (.latin1, "é"),
        ] {
            let path = directory.appendingPathComponent(UUID().uuidString + ".csv")
            let original = "Name,Group,Value\r\n\(value),g,000\nOther,h,\"literal\""
            let firstDraft = "Name,Group,Value\r\n\(value),g,111\nOther,h,\"literal\""
            let secondDraft = "Name,Group,Value\r\n\(value),g,222\nOther,h,\"literal\""
            let bytes = try XCTUnwrap(encoding.encoded(original))
            let firstBytes = try XCTUnwrap(encoding.encoded(firstDraft))
            let secondBytes = try XCTUnwrap(encoding.encoded(secondDraft))
            XCTAssertEqual(bytes.count, firstBytes.count)
            XCTAssertEqual(bytes.count, secondBytes.count)
            try bytes.write(to: path)
            let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
            try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: path.path)
            let first = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            let second = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            defer { first.retireContent(); second.retireContent() }
            first.autoSaveSuspendedForClose = true
            second.autoSaveSuspendedForClose = true
            for (file, replacement) in [(first, "111"), (second, "222")] {
                file.reopen(using: encoding)
                try await file.waitForText()
                let result = try await file.delimitedSnapshot(using: .comma)
                let snapshot = try XCTUnwrap(result)
                XCTAssertTrue(file.canEditDelimited(snapshot), encoding.name)
                try await requireDelimitedEdit(file, .cells([.init(row: 1, column: 2): replacement]), using: snapshot)
                XCTAssertTrue(file.isDirty)
                XCTAssertEqual(try Data(contentsOf: path), bytes)
            }
            await first.save()
            XCTAssertEqual(try Data(contentsOf: path), firstBytes, encoding.name)
            XCTAssertFalse(first.isDirty)
            try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: path.path)
            await second.save()
            XCTAssertEqual(try Data(contentsOf: path), firstBytes, "A stale grid must not overwrite another window")
            XCTAssertEqual(second.text, secondDraft)
            XCTAssertTrue(second.isDirty)
            XCTAssertNotNil(second.saveError)
            second.documentUndoManager.undo()
            XCTAssertEqual(second.text, original)
            XCTAssertFalse(second.isDirty)
            second.documentUndoManager.redo()
            XCTAssertEqual(second.text, secondDraft)
            // The original version returning on disk allows the existing save
            // path to recover the entire rejected draft without re-encoding it.
            try bytes.write(to: path, options: .atomic)
            await second.save()
            XCTAssertEqual(try Data(contentsOf: path), secondBytes, encoding.name)
            XCTAssertFalse(second.isDirty)
            XCTAssertNil(second.saveError)
        }
    }

    func testMalformedGridRefusesMutationUntilSourceIsRepaired() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        let original = "Name,Value\r\nItem,\"unclosed"
        try Data(original.utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        defer { file.retireContent() }
        try await file.waitForText()
        let initial = try await file.delimitedSnapshot(using: .comma)
        let malformed = try XCTUnwrap(initial)
        XCTAssertNotNil(malformed.index.issue)
        XCTAssertFalse(file.canEditDelimited(malformed))
        XCTAssertNil(file.submitDelimitedEdit(.cells([.init(row: 1, column: 1): "overwrite"]), using: malformed))
        XCTAssertEqual(file.text, original)
        XCTAssertFalse(file.isDirty)
        file.nativeTextStorage.replaceCharacters(in: NSRange(location: file.nativeTextStorage.length, length: 0), with: "\"")
        let repaired = try await file.delimitedSnapshot(using: .comma)
        let snapshot = try XCTUnwrap(repaired)
        XCTAssertNil(snapshot.index.issue)
        XCTAssertTrue(file.canEditDelimited(snapshot))
        try await requireDelimitedEdit(file, .cells([.init(row: 1, column: 1): "repaired"]), using: snapshot)
        XCTAssertEqual(file.text, "Name,Value\r\nItem,\"repaired\"")
        XCTAssertEqual(try Data(contentsOf: path), Data(original.utf8))
        await file.save()
        XCTAssertEqual(try Data(contentsOf: path), Data(file.text.utf8))
    }

    func testInFlightSnapshotCannotPublishAcrossRename() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("open.csv")
        let renamed = directory.appendingPathComponent("open.txt")
        let bytes = Data(String(repeating: "part,😀\r\n", count: 100_000).utf8)
        try bytes.write(to: source)
        let file = FileTab(path: source.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let scan = Task {
            signal.yield(())
            signal.finish()
            return try await file.delimitedSnapshot()
        }
        for await _ in started { break }
        try FileManager.default.moveItem(at: source, to: renamed)
        file.updatePath(renamed.path)
        let stale = try await scan.value
        XCTAssertNil(stale)
        let wrongFormat = try await file.delimitedSnapshot()
        XCTAssertNil(wrongFormat)
        XCTAssertEqual(try Data(contentsOf: renamed), bytes)
    }

    func testInFlightSnapshotCannotPublishAfterProjectClosesFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("close.csv")
        let bytes = Data(String(repeating: "part,😀\r\n", count: 100_000).utf8)
        try bytes.write(to: source)
        let project = Project(fallbackName: "CSV close", workspaceConfiguration: .standard)
        project.openLocalFile(source.path)
        guard let selected = project.tabs.first, case .file(let file) = selected.content else {
            return XCTFail("Opening a file must create the real project tab")
        }
        try await file.waitForText()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let scan = Task {
            signal.yield(())
            signal.finish()
            return try await file.delimitedSnapshot()
        }
        for await _ in started { break }
        project.closeContent(selected.content)
        XCTAssertTrue(project.tabs.isEmpty)
        let stale = try await scan.value
        XCTAssertNil(stale?.requestID)
        let closed = try await file.delimitedSnapshot()
        XCTAssertNil(closed?.requestID)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
}
