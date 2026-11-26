import AppKit
import SwiftUI

/// Both the file editor and the Git worktree use this native review sheet.
struct WorkspaceSaveErrorBanner: View {
    let message: String
    let canCompare: Bool
    let compare: () async throws -> WorkspaceSaveConflict
    let overwrite: (WorkspaceSaveConflict) async throws -> Void
    @State private var showingComparison = false

    var body: some View {
        WorkspaceErrorBanner(message: message, compare: canCompare ? { showingComparison = true } : nil)
            .sheet(isPresented: $showingComparison) {
                WorkspaceSaveConflictSheet(compare: compare, overwrite: overwrite)
            }
    }
}

private struct WorkspaceSaveConflictSheet: View {
    let compare: () async throws -> WorkspaceSaveConflict
    let overwrite: (WorkspaceSaveConflict) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var comparison: WorkspaceSaveConflict?
    @State private var error: String?
    @State private var revision = 0
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading) {
            Text(String(localized: "Resolve Save Conflict", table: "Workspace"))
                .font(.headline)
            Text(String(localized: "Review the disk version and your draft. Overwrite checks the reviewed bytes again before saving.", table: "Workspace"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let comparison {
                Text(comparison.context.path)
                    .font(.caption)
                    .textSelection(.enabled)
                    .lineLimit(2)
                HStack {
                    Label(String(localized: "Disk (removed)", table: "Workspace"), systemImage: "minus.circle")
                    Text(verbatim: "\(comparison.diskEncoding) · \(comparison.diskVersion.byteCount.formatted()) B")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Label(String(localized: "Draft (added)", table: "Workspace"), systemImage: "plus.circle")
                    Text(verbatim: "\(comparison.draftEncoding) · \(comparison.draftVersion.byteCount.formatted()) B")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                HStack {
                    Text(verbatim: "SHA-256: \(comparison.diskVersion.sha256.prefix(16))…")
                        .help(comparison.diskVersion.sha256)
                    Spacer()
                    Text(verbatim: "SHA-256: \(comparison.draftVersion.sha256.prefix(16))…")
                        .help(comparison.draftVersion.sha256)
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                WorkspaceSaveConflictReview(comparison: comparison)
                    .id(revision)
                    .frame(minHeight: 180, maxHeight: .infinity)
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
            if let error {
                WorkspaceErrorBanner(message: error)
            }
            HStack {
                if error != nil {
                    Button(String(localized: "Compare Again", table: "Workspace")) {
                        comparison = nil
                        error = nil
                        revision &+= 1
                    }
                }
                Spacer()
                Button(String(localized: "Cancel", table: "Workspace")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button(String(localized: "Overwrite", table: "Workspace"), role: .destructive) {
                    guard let comparison, !saving else { return }
                    saving = true
                    Task {
                        defer { saving = false }
                        do {
                            try await overwrite(comparison)
                            dismiss()
                        } catch {
                            self.error = String(localized: "The file or draft changed, or the save failed. Compare again before overwriting.", table: "Workspace")
                        }
                    }
                }
                .disabled(comparison == nil || saving || error != nil)
                .accessibilityIdentifier("bailey.saveConflict.overwrite")
            }
        }
        .padding()
        .frame(minWidth: 480, idealWidth: 720, minHeight: 360, idealHeight: 540)
        .interactiveDismissDisabled(saving)
        .task(id: revision) {
            do {
                let loaded = try await compare()
                try Task.checkCancellation()
                comparison = loaded
            } catch is CancellationError {
                return
            } catch WorkspaceError.tooLarge {
                self.error = String(localized: "The comparison is too large to display safely. Your draft is unchanged.", table: "Workspace")
            } catch {
                self.error = String(localized: "Unable to compare the current disk version. Your draft is unchanged.", table: "Workspace")
                    + " " + error.localizedDescription
            }
        }
    }
}

/// The existing TextKit Diff pane owns drawing, gutters and native scrolling.
private struct WorkspaceSaveConflictReview: NSViewRepresentable {
    let comparison: WorkspaceSaveConflict
    @Environment(\.colorScheme) private var colorScheme
    private let themeChanges = Theme.changes
    private let settings = AppSettings.shared

    func makeNSView(context: Context) -> DiffCodePaneView {
        let pane = DiffCodePaneView(mode: .review, gutterLayout: .single)
        pane.textView.setAccessibilityIdentifier("bailey.saveConflict.review")
        return pane
    }

    func updateNSView(_ pane: DiffCodePaneView, context: Context) {
        let _ = themeChanges.revision
        let font = TerminalFont.editor()
        let style = DiffTypography.paragraphStyle(for: font)
        let color = Theme.terminal(dark: colorScheme == .dark).foregroundNSColor
        pane.applyTypography(font: font, paragraphStyle: style, textColor: color,
                             longLineDisplayWidth: settings.longLineDisplayWidth)
        let initial = pane.renderedDisplayID == nil
        let storage = pane.textView.textStorage
        if !initial, let storage, storage.length > 0,
           storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == font,
           storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle == style,
           storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == color {
            return
        }
        pane.renderedDisplayID = comparison.context.failure.id
        pane.setReviewDocument(NSAttributedString(string: comparison.review.text,
            attributes: [.font: font, .paragraphStyle: style, .foregroundColor: color]),
            decorations: .review(comparison.review))
        if initial, let row = comparison.review.rows.firstIndex(where: { $0.kind == .added || $0.kind == .removed }) {
            pane.scrollToRow(max(0, row - 3))
        }
    }

    static func dismantleNSView(_ pane: DiffCodePaneView, coordinator: ()) {
        pane.retireNativeDocument()
    }
}
