import Foundation
import XCTest
@testable import Bailey

@MainActor
final class MarkdownFootnotesTests: XCTestCase {
    func testFootnotesFollowFirstReferenceAndOmitUnusedDefinitions() async throws {
        let document = try await MarkdownDocument.parse("""
            First[^second], then[^first], and second again[^second].

            [^first]: Definition one.
            [^second]: Definition two.
            [^unused]: Should not appear.
            """)
        let notes = document.blocks.compactMap { block -> (String, String)? in
            guard let anchor = block.anchor, anchor.hasPrefix("bailey-note:"),
                  case .markdown(let text) = block.content else { return nil }
            return (anchor, String(text.characters))
        }
        XCTAssertEqual(notes.map(\.0), ["bailey-note:second", "bailey-note:first"])
        XCTAssertEqual(notes.map(\.1), ["[1] Definition two.", "[2] Definition one."])
        guard case .markdown(let body) = document.blocks.first?.content else {
            return XCTFail("Missing Markdown paragraph")
        }
        let references = body.runs.compactMap { run -> (String, String)? in
            guard let fragment = run.link?.fragment, fragment.hasPrefix("bailey-note:") else { return nil }
            return (fragment, String(body[run.range].characters))
        }
        XCTAssertEqual(references.map(\.0), ["bailey-note:second", "bailey-note:first", "bailey-note:second"])
        XCTAssertEqual(references.map(\.1), ["[1]", "[2]", "[1]"])
        XCTAssertFalse(document.blocks.contains { block in
            guard case .markdown(let text) = block.content else { return false }
            return String(text.characters).contains("Should not appear")
        })
    }

    func testMultilineFootnoteDoesNotLeakDefinitionIntoBody() async throws {
        let document = try await MarkdownDocument.parse("""
            Content[^a].

            [^a]: First line.
                Continued line.

            Closing paragraph.
            """)
        XCTAssertEqual(document.blocks.compactMap(\.anchor), ["bailey-note:a"])
        let text = document.blocks.compactMap { block -> String? in
            guard case .markdown(let value) = block.content else { return nil }
            return String(value.characters)
        }.joined(separator: "\n")
        XCTAssertEqual(text.components(separatedBy: "Continued line.").count, 2)
        XCTAssertTrue(text.contains("Closing paragraph."))
    }

    func testFootnoteReferencesInsideLiteralCodeDoNotCreateNotes() async throws {
        let document = try await MarkdownDocument.parse("""
            `[^inline]` and a real note[^valid].

            ```text
            [^block]
            ```

            [^inline]: Literal inline code.
            [^block]: Literal block code.
            [^valid]: Referenced note.
            """)
        XCTAssertEqual(document.blocks.compactMap(\.anchor), ["bailey-note:valid"])
    }
}
