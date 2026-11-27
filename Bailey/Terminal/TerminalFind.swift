import AppKit
import GhosttyTerminal
import Foundation
import Observation

/// Find-in-terminal state for one session.
///
/// The backend owns the search itself — it scans the screen and scrollback on
/// its own thread, highlights every match in its renderer, and moves the
/// selection as you navigate — so this holds only what the find bar draws and
/// forwards the user's intent as surface find actions. Match counts arrive
/// back asynchronously through Ghostty.
@MainActor
@Observable
final class TerminalFind {
    private(set) var isPresented = false

    /// The needle. Every edit restarts the backend's search, so the bar
    /// searches as you type.
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            runSearch()
        }
    }

    /// Matches found so far, or nil while a count for the current needle has
    /// not been reported yet.
    private(set) var total: Int?
    /// Zero-based index of the highlighted match, nil when none is.
    private(set) var selected: Int?

    /// Bumped whenever the bar should take (or retake) keyboard focus, so ⌘F
    /// on an already-open bar focuses the query again. A counter rather than
    /// a flag: repeated requests must each land.
    private(set) var focusRequest = 0

    @ObservationIgnored private let surface: BaileyTerminalView

    /// Bumped per search so a deferred reveal belonging to an older needle can
    /// tell it has been superseded. A backend reports each restart as a burst
    /// of counts, several per keystroke.
    @ObservationIgnored private var searchGeneration = 0
    /// Whether the current needle has already jumped to a match.
    @ObservationIgnored private var hasRevealedMatch = false

    init(surface: BaileyTerminalView) {
        self.surface = surface
    }

    /// Seed from the focused terminal selection, otherwise retain the query.
    func present() {
        let wasPresented = isPresented
        // The selection action synchronously reports start_search. Let that
        // callback open a closed bar and execute its resolved query.
        if (!wasPresented || surface.window?.firstResponder === surface),
           surface.searchSelection() {
            if wasPresented { focusRequest += 1 }
            return
        }
        isPresented = true
        focusRequest += 1
        if !wasPresented { runSearch() }
    }

    /// Closes the bar, clears the backend's highlights, and hands typing back
    /// to the terminal.
    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        clearCounts()
        surface.endSearch()
    }

    /// Returns first responder to the terminal. Called once the find bar has
    /// actually left the view tree, because claiming it any earlier loses the
    /// race with SwiftUI tearing down the find field: AppKit resigns that
    /// field editor afterwards and the window is left without a first
    /// responder, so the terminal silently stops receiving keystrokes.
    func restoreTerminalFocus() {
        DispatchQueue.main.async { [weak self, surface] in
            guard let self, !self.isPresented, self.canFocusSource,
                  let window = surface.window,
                  window.firstResponder !== surface
            else { return }
            window.makeFirstResponder(surface)
        }
    }

    var canFocusSource: Bool {
        guard NSApp.isActive, surface.window?.isKeyWindow == true,
              let container = surface.superview as? TerminalContainerView else { return false }
        return container.focusOnAppear && container.canFocus()
    }

    func navigate(forward: Bool) {
        guard isPresented, !query.isEmpty else { return }
        surface.navigateSearch(forward: forward)
    }

    // MARK: - Reports from the backend

    func started(needle: String) {
        let wasPresented = isPresented
        // Only claim keyboard focus when this actually opens the bar. A
        // backend may report a start for a search already under way, and
        // re-selecting the field mid-edit would eat what the user is typing.
        if !isPresented {
            isPresented = true
            focusRequest += 1
        }
        // start_search reports the requested needle, but does not execute
        // the search. Updating the query must send it back to Ghostty.
        if !needle.isEmpty, needle != query { query = needle }
        else if !wasPresented { runSearch() }
    }

    /// The backend ended the search on its own. Mirror it without sending
    /// an end straight back at it.
    func ended() {
        isPresented = false
        clearCounts()
    }

    func update(total: Int?) {
        self.total = total
        revealFirstMatchIfNeeded()
    }

    func update(selected: Int?) {
        self.selected = selected
    }

    /// A backend tallies matches but selects none until asked, so the first
    /// non-empty result for a needle jumps to one — typing in the find bar is
    /// meant to reveal the hit, not merely count it. Deferred so it never
    /// re-enters the backend from inside its own action callback, and dropped
    /// when the needle has moved on by the time it runs.
    private func revealFirstMatchIfNeeded() {
        guard !hasRevealedMatch, let total, total > 0 else { return }
        hasRevealedMatch = true
        let generation = searchGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, isPresented, searchGeneration == generation else { return }
            surface.navigateSearch(forward: true)
        }
    }

    // MARK: - Search

    /// Restarts the backend's search for the current needle. Counts are
    /// dropped first so the bar never shows a tally belonging to the previous
    /// term.
    private func runSearch() {
        guard isPresented else { return }
        searchGeneration += 1
        hasRevealedMatch = false
        clearCounts()
        surface.search(query)
    }

    private func clearCounts() {
        total = nil
        selected = nil
    }
}
