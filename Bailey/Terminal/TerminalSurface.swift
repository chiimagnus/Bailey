import AppKit

/// Everything Ghostty needs to start one pane's shell. Bailey resolves the
/// shell command, working directory, and environment once, up front.
struct TerminalLaunch {
    let commandLine: String
    let workingDirectory: String
    let environment: [String: String]
    var initialInput: String? = nil
}

/// A Command-clickable terminal value after the owning session has resolved
/// it against the pane's live local working directory.
enum TerminalLinkTarget {
    case url(URL)
    case file(URL)
}

/// Where the viewport sits within a surface's total content. Kept as raw row
/// counts rather than a fraction so the overlay scrollbar can both draw itself
/// and map a drag back onto a row.
struct TerminalScrollPosition: Equatable, Sendable {
    /// Rows of content, viewport plus scrollback.
    let totalRows: UInt64
    /// Rows visible in the viewport.
    let viewportRows: UInt64
    /// The content row currently at the top of the viewport.
    let topRow: UInt64

    /// False when everything fits, so there is nothing to scroll.
    var isScrollable: Bool {
        totalRows > viewportRows && viewportRows > 0
    }

    /// Visible fraction of the content, 0…1 — the scrollbar knob's length.
    var proportion: Double {
        totalRows > 0 ? Double(viewportRows) / Double(totalRows) : 1
    }

    /// The knob's travel, 0 at the top of the scrollback and 1 at the live
    /// prompt. Pinned to the bottom when there is nothing to scroll.
    var position: Double {
        guard isScrollable else { return 1 }
        return Double(topRow) / Double(totalRows - viewportRows)
    }

    /// The top row a scrollbar drag to `fraction` of its travel lands on.
    func row(atDragFraction fraction: Double) -> UInt64 {
        let available = totalRows > viewportRows ? totalRows - viewportRows : 0
        return UInt64((Double(available) * fraction).rounded())
    }
}

/// A backend asking Bailey to confirm clipboard access before it proceeds.
/// Exactly one of ``approve()`` and ``deny()`` must be called.
@MainActor
final class TerminalClipboardRequest {
    enum Kind: Sendable {
        /// Paste protection flagged the pending paste as unsafe.
        case unsafePaste
        /// A terminal program asked to read the clipboard (OSC 52). Never
        /// resolve this one without asking: any program whose output reaches
        /// the terminal, including a remote SSH host, would otherwise be able
        /// to exfiltrate the macOS clipboard through the PTY.
        case programRead
    }

    let kind: Kind
    /// The text under decision: what would be pasted for ``Kind/unsafePaste``,
    /// or what the program would receive for ``Kind/programRead``.
    let contents: String

    private let resolve: @MainActor (Bool) -> Void

    init(kind: Kind, contents: String, resolve: @escaping @MainActor (Bool) -> Void) {
        self.kind = kind
        self.contents = contents
        self.resolve = resolve
    }

    func approve() { resolve(true) }
    func deny() { resolve(false) }
}
