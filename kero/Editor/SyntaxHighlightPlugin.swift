//
//  SyntaxHighlightPlugin.swift
//  kero
//
//  kero's own STTextView highlighting plugin. It reuses STTextView-Plugin-Neon's
//  tree-sitter grammars and query files (via TreeSitterResource) and Neon's
//  incremental Highlighter, but owns the glue so it can do one thing the stock
//  plugin can't: **merge a language's inherited base query**. tree-sitter
//  highlight queries use nvim-treesitter's `; inherits:` convention — e.g.
//  TypeScript inherits ecma/JavaScript, C++ inherits C — and SwiftTreeSitter
//  doesn't resolve that, so the stock plugin (which loads a single query file)
//  leaves comments, strings and base keywords unhighlighted. See
//  SyntaxHighlighting.highlightsData(for:).
//
//  Languages are named by kero's own `SyntaxLanguage`, not the plugin's
//  `TreeSitterLanguage`, because one grammar (TSX) is vendored rather than
//  bundled.
//
//  Adapted from STTextView-Plugin-Neon's Coordinator / STTextViewSystemInterface.
//

import AppKit
import Neon
import Rearrange
import STTextKitPlus
import STTextView
import SwiftTreeSitter
import TreeSitterClient

/// STTextView plugin that drives Neon's tree-sitter highlighter.
struct SyntaxHighlightPlugin: STPlugin {
    let theme: [String: NSColor]
    let language: SyntaxLanguage
    /// The combined highlights query (`inherited base + language-specific`),
    /// already concatenated by `SyntaxHighlighting.highlightsData(for:)`.
    let highlightsData: Data
    /// The injections query for a language that embeds others (markdown code
    /// fences, HTML `<script>`, …), or `nil`. Drives the injection-aware token
    /// provider; see `SyntaxHighlighting.injectionsData(for:)`.
    let injectionsData: Data?

    /// These handlers are stored on `STPluginEvents`, which the text view
    /// itself retains (`STTextView.plugins`) for as long as it lives — and the
    /// view has no way to drop a plugin, so anything they capture strongly
    /// lives exactly as long as the view does. Capturing `context` whole would
    /// therefore close a cycle: it holds `textView` strongly, so every editor
    /// would stay alive for the life of the process. Capture the coordinator
    /// (which is meant to share the view's lifetime) and a *weak* view instead.
    func setUp(context: any Context) {
        let coordinator = context.coordinator

        context.events.onWillChangeText { [weak textView = context.textView] affectedRange, _ in
            guard let textView else { return }
            let range = NSRange(affectedRange, in: textView.textContentManager)
            coordinator.willChangeContent(in: range)
        }

        context.events.onDidChangeText { [weak textView = context.textView] affectedRange, replacementString in
            guard let textView, let replacementString else { return }
            let range = NSRange(affectedRange, in: textView.textContentManager)
            coordinator.didChangeContent(
                textView.textContentManager,
                in: range,
                replacementString: replacementString
            )
        }

        context.events.onDidLayoutViewport { viewportRange in
            coordinator.updateViewportRange(viewportRange)
        }
    }

    func makeCoordinator(context: CoordinatorContext) -> SyntaxHighlightCoordinator {
        SyntaxHighlightCoordinator(
            textView: context.textView,
            theme: theme,
            language: language,
            highlightsData: highlightsData,
            injectionsData: injectionsData
        )
    }
}

@MainActor
final class HighlightQueryCache {
    static let shared = HighlightQueryCache()

    enum Kind: Hashable { case highlights, injections }

    private struct Key: Hashable {
        let language: SyntaxLanguage
        let kind: Kind
    }

    private enum Entry {
        case pending(Task<SwiftTreeSitter.Query?, Never>)
        case complete(SwiftTreeSitter.Query?)
    }

    private var entries: [Key: Entry] = [:]

    func cached(_ language: SyntaxLanguage, kind: Kind = .highlights) -> SwiftTreeSitter.Query? {
        guard case .complete(let query) = entries[Key(language: language, kind: kind)] else { return nil }
        return query
    }

    func isComplete(_ language: SyntaxLanguage, kind: Kind = .highlights) -> Bool {
        if case .complete = entries[Key(language: language, kind: kind)] { return true }
        return false
    }

    func query(
        for language: SyntaxLanguage, kind: Kind = .highlights, data: Data
    ) async -> SwiftTreeSitter.Query? {
        let key = Key(language: language, kind: kind)
        let task: Task<SwiftTreeSitter.Query?, Never>
        switch entries[key] {
        case .complete(let query): return query
        case .pending(let pending): task = pending
        case nil:
            guard let grammarIndex = language.grammarIndex else { return nil }
            task = Task.detached(priority: .userInitiated) {
                SyntaxLanguage.compileQuery(grammarIndex: grammarIndex, data: data)
            }
            entries[key] = .pending(task)
        }
        let query = await task.value
        entries[key] = .complete(query)
        return query
    }
}

@MainActor
final class SyntaxHighlightCoordinator {
    private(set) var highlighter: Neon.Highlighter?
    let tsClient: TreeSitterClient
    private let coordinates: TextCoordinateIndex
    private var pendingInjectionQueries: Set<SyntaxLanguage> = []
    private var injectedFragments: [SwiftTreeSitter.NamedRange: Task<[SwiftTreeSitter.NamedRange], Never>] = [:]
    // Both text edits and newly available embedded queries change which tokens
    // a pending request may validly deliver.
    private var highlightRevision: UInt = 0
    private var prevViewportRange: NSTextRange?

    init(
        textView: STTextView,
        theme: [String: NSColor],
        language: SyntaxLanguage,
        highlightsData: Data,
        injectionsData: Data?
    ) {
        let string = textView.textContentManager.attributedString(in: nil)?.string ?? ""
        let coordinates = TextCoordinateIndex(string)
        self.coordinates = coordinates
        tsClient = try! TreeSitterClient(
            language: Language(language: language.parser),
            transformer: { coordinates.point(at: $0) },
            synchronousLengthThreshold: 0
        )

        tsClient.invalidationHandler = { [weak self, hasInjections = injectionsData != nil] indexSet in
            self?.highlighter?.invalidate(hasInjections ? .all : .set(indexSet))
        }

        let textInterface = SyntaxHighlightTextInterface(textView: textView) { neonToken in
            // Metadata captures aren't colors — skip them so they don't repaint
            // a real capture on the same range. Swift captures comments as
            // `@comment @spell`; letting `spell` through (it resolves to the
            // plain fallback, applied after `comment`) turned comments black.
            guard !Self.ignoredCaptures.contains(neonToken.name) else {
                return nil
            }
            return Self.themeColor(for: neonToken.name, theme: theme)
        }

        // Start with no token provider (a no-op); it's installed below once the
        // query is ready — off the main thread on first use, so opening a file
        // never blocks on the ~190 ms Swift query compile.
        highlighter = Neon.Highlighter(textInterface: textInterface)

        // Parse the whole document once up front.
        tsClient.willChangeContent(in: .zero)
        tsClient.didChangeContent(
            in: .zero,
            delta: textView.textContentManager.length,
            limit: textView.textContentManager.length,
            readHandler: Parser.readFunction(for: string),
            completionHandler: {}
        )

        installTokenProvider(language: language, highlightsData: highlightsData,
                             injectionsData: injectionsData, textContentManager: textView.textContentManager)
    }

    /// tree-sitter capture names that carry no color — spell-check hints,
    /// concealment, and the explicit "no highlight" marker. Grammars attach
    /// these alongside real captures (e.g. Swift's `@comment @spell`), so they
    /// must be dropped rather than resolved to a color.
    nonisolated static let ignoredCaptures: Set<String> = ["spell", "nospell", "conceal", "none"]

    /// The theme color for a tree-sitter capture name, trying the most specific
    /// name first and shortening on each dot (`variable.parameter` → `variable`),
    /// then the theme's `plain` default. The merged queries carry finer-grained
    /// capture names than the theme enumerates, so exact-match alone would leave
    /// many tokens uncolored.
    nonisolated static func themeColor(for name: String, theme: [String: NSColor]) -> NSColor? {
        var key = name
        while true {
            if let color = theme[key] {
                return color
            }
            if let alias = captureAliases[key], let color = theme[alias] {
                return color
            }
            guard let dot = key.lastIndex(of: ".") else { break }
            key = String(key[..<dot])
        }
        return theme["plain"]
    }

    /// Capture names the theme's palette has no entry for, redirected onto ones
    /// it does. The palette is a fixed list that predates markup grammars, so
    /// `@tag` and `@attribute` — which carry most of the color in a JSX or HTML
    /// file — would otherwise walk straight to the `plain` fallback and leave
    /// every element name and prop the same black as the text around it.
    nonisolated private static let captureAliases: [String: String] = [
        // Capitalized JSX components already reach `@constructor` through the
        // JavaScript query's `^[A-Z]` rule, so lowercase intrinsics match them
        // and `<main>` looks like `<Sidebar>`.
        "tag": "constructor",
        // The theme ships a `property` color but leaves it out of the palette;
        // `method` is the same value and does make the list.
        "attribute": "method",
    ]

    private func installTokenProvider(
        language: SyntaxLanguage, highlightsData: Data, injectionsData: Data?, textContentManager: NSTextContentManager
    ) {
        Task { @MainActor [weak self, weak textContentManager] in
            guard let query = await HighlightQueryCache.shared.query(for: language, data: highlightsData) else { return }
            let injectionsQuery: SwiftTreeSitter.Query?
            if let injectionsData {
                injectionsQuery = await HighlightQueryCache.shared.query(
                    for: language, kind: .injections, data: injectionsData
                )
            } else {
                injectionsQuery = nil
            }
            guard let self, let textContentManager else { return }
            if let injectionsQuery {
                self.setInjectionTokenProvider(
                    highlightsQuery: query, injectionsQuery: injectionsQuery, textContentManager: textContentManager
                )
            } else {
                self.setTokenProvider(query: query, textContentManager: textContentManager)
            }
        }
    }

    private func setTokenProvider(query: SwiftTreeSitter.Query, textContentManager: NSTextContentManager) {
        let provider = tsClient.tokenProvider(with: query) { range, _ in
            guard !range.isEmpty else { return nil }
            return textContentManager.attributedString(in: NSTextRange(range, provider: textContentManager))?.string
        }
        highlighter?.tokenProvider = { [weak self] range, completion in
            guard let self else { return }
            let revision = self.highlightRevision
            provider(range) { [weak self] result in
                guard self?.highlightRevision == revision else { return }
                completion(result)
            }
        }
        // Re-run highlighting now that the provider exists (the no-op provider
        // produced nothing during the initial parse).
        highlighter?.invalidate()
    }

    /// A token provider that highlights the root language *and* any embedded
    /// languages. For each request it runs the root highlights query for the
    /// base tokens, then the injections query to find embedded regions, and
    /// sub-highlights each region with its own grammar. Injected tokens are
    /// appended after the base ones so they win on the shared range: markdown
    /// tags fenced content `@none` (dropped), and the embedded bash/js/… tokens
    /// paint over it — e.g. a shell comment finally gets the comment color.
    private func setInjectionTokenProvider(
        highlightsQuery: SwiftTreeSitter.Query,
        injectionsQuery: SwiftTreeSitter.Query,
        textContentManager: NSTextContentManager
    ) {
        let textProvider: SwiftTreeSitter.Predicate.TextProvider = { range, _ in
            guard !range.isEmpty else { return nil }
            return textContentManager.attributedString(in: NSTextRange(range, provider: textContentManager))?.string
        }

        highlighter?.tokenProvider = { [weak self] range, completion in
            guard let self else { return }
            let revision = self.highlightRevision

            self.tsClient.executeHighlightsQuery(highlightsQuery, in: range, textProvider: textProvider) { [weak self] baseResult in
                guard let self, self.highlightRevision == revision else { return }
                switch baseResult {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let baseRanges):
                    self.tsClient.executeInjectionsQuery(injectionsQuery, in: range, textProvider: textProvider) { [weak self] injectionResult in
                        guard let self, self.highlightRevision == revision else { return }
                        Task { @MainActor [weak self] in
                            guard let self, self.highlightRevision == revision else { return }
                            var tokens = baseRanges.compactMap { capture -> Neon.Token? in
                                let clipped = NSIntersectionRange(capture.range, range)
                                return clipped.length > 0 ? Neon.Token(name: capture.name, range: clipped) : nil
                            }
                            if case .success(let injections) = injectionResult {
                                for injection in injections {
                                    let captures = await self.injectedCaptures(
                                        for: injection, revision: revision, textProvider: textProvider
                                    )
                                    guard self.highlightRevision == revision else { return }
                                    for capture in captures {
                                        let shifted = NSRange(location: capture.range.location + injection.range.location,
                                                              length: capture.range.length)
                                        let clipped = NSIntersectionRange(shifted, range)
                                        if clipped.length > 0 {
                                            tokens.append(Neon.Token(name: capture.name, range: clipped))
                                        }
                                    }
                                }
                            }
                            guard self.highlightRevision == revision else { return }
                            completion(.success(TokenApplication(tokens: tokens)))
                        }
                    }
                }
            }
        }
        highlighter?.invalidate()
    }

    private func injectedCaptures(
        for injection: SwiftTreeSitter.NamedRange,
        revision: UInt,
        textProvider: SwiftTreeSitter.Predicate.TextProvider
    ) async -> [SwiftTreeSitter.NamedRange] {
        let injectionRange = injection.range
        guard highlightRevision == revision, injectionRange.length > 0,
              let language = SyntaxHighlighting.language(forInjectionName: injection.name),
              let query = injectedHighlightsQuery(for: language)
        else { return [] }
        if let task = injectedFragments[injection] { return await task.value }
        guard let grammarIndex = language.grammarIndex,
              let fragment = textProvider(injectionRange, Point.zero..<Point.zero),
              !fragment.isEmpty, highlightRevision == revision
        else { return [] }
        let task = Task.detached(priority: .userInitiated) { () -> [SwiftTreeSitter.NamedRange] in
            guard !Task.isCancelled, let grammar = SyntaxLanguage.parser(grammarIndex: grammarIndex) else { return [] }
            let parser = Parser()
            do { try parser.setLanguage(grammar) } catch { return [] }
            guard let tree = parser.parse(fragment), let root = tree.rootNode, !Task.isCancelled else { return [] }
            let context = SwiftTreeSitter.Predicate.Context(string: fragment)
            return query.execute(node: root, in: tree).resolve(with: context).highlights().filter {
                $0.range.length > 0 && !Self.ignoredCaptures.contains($0.name)
            }
        }
        injectedFragments[injection] = task
        return await task.value
    }

    private func injectedHighlightsQuery(for language: SyntaxLanguage) -> SwiftTreeSitter.Query? {
        let cache = HighlightQueryCache.shared
        if let query = cache.cached(language) {
            return query
        }
        guard !cache.isComplete(language), pendingInjectionQueries.insert(language).inserted else { return nil }
        let data = SyntaxHighlighting.highlightsData(for: language)
        Task { @MainActor [weak self] in
            let query = await cache.query(for: language, data: data)
            guard let self else { return }
            self.pendingInjectionQueries.remove(language)
            if query != nil { self.injectedQueryBecameAvailable() }
        }
        return nil
    }

    func injectedQueryBecameAvailable() {
        highlightRevision &+= 1
        highlighter?.invalidate()
    }

    func updateViewportRange(_ range: NSTextRange?) {
        if range != prevViewportRange {
            highlighter?.visibleContentDidChange()
        }
        prevViewportRange = range
    }

    func willChangeContent(in range: NSRange) {
        highlightRevision &+= 1
        for task in injectedFragments.values { task.cancel() }
        injectedFragments.removeAll()
        tsClient.willChangeContent(in: range)
    }

    func didChangeContent(_ textContentManager: NSTextContentManager, in range: NSRange, replacementString: String) {
        guard let string = textContentManager.attributedString(in: nil)?.string else { return }
        coordinates.replace(in: range, with: replacementString)
        let delta = replacementString.utf16.count - range.length
        highlighter?.didChangeContent(in: range, delta: delta)
        tsClient.didChangeContent(
            in: range,
            delta: delta,
            limit: string.utf16.count,
            readHandler: Parser.readFunction(for: string),
            completionHandler: {}
        )
    }
}

/// Bridges Neon's colors onto an STTextView using temporary rendering attributes.
private final class SyntaxHighlightTextInterface: TextSystemInterface {
    typealias ColorProvider = (Neon.Token) -> NSColor?

    /// Weak: the text view owns this interface transitively (view → plugins →
    /// events → coordinator → highlighter → here), so a strong reference back
    /// would keep every editor — and its whole document — alive forever.
    private weak var textView: STTextView?
    private let colorProvider: ColorProvider

    init(textView: STTextView, colorProvider: @escaping ColorProvider) {
        self.textView = textView
        self.colorProvider = colorProvider
    }

    func clearStyle(in range: NSRange) {
        guard let textView,
              let textRange = NSTextRange(range, in: textView.textContentManager)
        else { return }
        textView.textLayoutManager.removeRenderingAttribute(.foregroundColor, for: textRange)
    }

    func applyStyle(to token: Neon.Token) {
        // Zero-length tokens (markdown emits them) would crash TextKit when
        // used as a rendering-attribute range; STTextLayoutManager also guards
        // this, but skipping here avoids the wasted work.
        guard let textView,
              token.range.length > 0,
              let color = colorProvider(token),
              let textRange = NSTextRange(token.range, in: textView.textContentManager)
        else {
            return
        }

        textView.textLayoutManager.addRenderingAttribute(.foregroundColor, value: color, for: textRange)
    }

    var length: Int {
        textView?.textContentManager.length ?? 0
    }

    var visibleRange: NSRange {
        guard let textView,
              let viewportRange = textView.textLayoutManager.textViewportLayoutController.viewportRange
        else {
            return .zero
        }
        return NSRange(viewportRange, provider: textView.textContentManager)
    }
}
