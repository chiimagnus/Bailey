import Foundation
import SwiftTreeSitter
import Rearrange

public enum TreeSitterClientError: Error {
    case stateInvalid
    case staleContent
}

@MainActor
@preconcurrency
public final class TreeSitterClient {
    public typealias TextProvider = SwiftTreeSitter.Predicate.TextProvider

    struct ContentEdit {
        var rangeMutation: RangeMutation
        var inputEdit: InputEdit
        var limit: Int

        var size: Int {
            return max(abs(rangeMutation.delta), rangeMutation.range.length)
        }

        var affectedRange: NSRange {
            let range = rangeMutation.range

            // we want to expand our affected range just slightly, so that
            // changes to immediately-adjacent tokens are included in the range checks
            // for the cursor.
            let start = max(range.location - 1, 0)
            let end = min(max(range.max, range.max + rangeMutation.delta) + 1, limit)

            return NSRange(start..<end)
        }
    }

    private var oldEndPoint: Point?
    private let parser: Parser
    private var parseState: TreeSitterParseState
    private var outstandingEdits: [ContentEdit]
    private var version: Int
    private let queue: DispatchQueue
    private let semaphore: DispatchSemaphore
    private let synchronousLengthThreshold: Int

    // This was roughly determined to be the limit in characters
    // before it's likely that tree-sitter edit processing
    // and tree-diffing will start to become noticeably laggy
    private let synchronousContentLengthThreshold: Int = 1_000_000

    public let locationTransformer: Point.LocationTransformer?

    /// Invoked when parts of the text content have changed
    ///
    /// This function always returns values that represent
    /// the current state of the content, even if the
    /// system is working in the background.
    public var invalidationHandler: (IndexSet) -> Void

    public init(language: Language, transformer: Point.LocationTransformer? = nil, synchronousLengthThreshold: Int = 1024) throws {
        self.parser = Parser()
        self.parseState = TreeSitterParseState(tree: nil)
        self.outstandingEdits = []
        self.version = 0
        self.queue = DispatchQueue(label: "com.chimehq.Neon.TreeSitterClient")
        self.semaphore = DispatchSemaphore(value: 1)

        try parser.setLanguage(language)

        self.invalidationHandler = { _ in }
        self.locationTransformer = transformer
        self.synchronousLengthThreshold = synchronousLengthThreshold
    }

    private var hasQueuedWork: Bool {
        return outstandingEdits.count > 0
    }
}

extension TreeSitterClient {
    /// Prepare for a content change.
    ///
    /// This method must be called before any content changes have been applied that
    /// would affect how the `transformer`parameter will behave.
    ///
    /// - Parameter range: the range of content that will be affected by an edit
    public func willChangeContent(in range: NSRange) {
        oldEndPoint = locationTransformer?(range.max)
    }

    /// Process a change in the underlying text content.
    ///
    /// This method will re-parse the sections of the content
    /// needed by tree-sitter. It may do so **asynchronously**
    /// which means you **must** guarantee that `readHandler`
    /// provides a stable, thread-safe view of the
    /// content up until `completionHandler` is called.
    ///
    /// - Parameter range: the range that was affected by the edit
    /// - Parameter delta: the change in length of the content
    /// - Parameter limit: the current length of the content
    /// - Parameter readHandler: a function that returns the text data
    /// - Parameter completionHandler: invoked when the edit has been fully processed
    public func didChangeContent(in range: NSRange,
                                 delta: Int,
                                 limit: Int,
                                 readHandler: @escaping Parser.ReadBlock,
                                 completionHandler: @escaping () -> Void) {
        if locationTransformer != nil && oldEndPoint == nil {
            assertionFailure("oldEndPoint unavailable")
            return
        }
        let oldEndPoint = self.oldEndPoint ?? .zero
        self.oldEndPoint = nil

        guard let inputEdit = InputEdit(range: range, delta: delta, oldEndPoint: oldEndPoint, transformer: locationTransformer) else {
            assertionFailure("unable to build InputEdit")
            return
        }

        // RangeMutation has a "limit" concept, used for bounds checking. However,
        // they are treated as pre-application of the mutation. Here, the content
        // has already changed. That's why it's optional!
        //
        // So, why use RangeMutation at all? Because we want to make use of its
        // transformation capabilities for invalidations.
        let mutation = RangeMutation(range: range, delta: delta)
        let edit = ContentEdit(rangeMutation: mutation, inputEdit: inputEdit, limit: limit)

        processEdit(edit, readHandler: readHandler, completionHandler: completionHandler)
    }


}

extension TreeSitterClient {
    func processEdit(_ edit: ContentEdit, readHandler: @escaping Parser.ReadBlock, completionHandler: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))

        let largeEdit = edit.size > synchronousLengthThreshold
        let largeDocument = edit.limit > synchronousContentLengthThreshold
        let runAsync = hasQueuedWork || largeEdit || largeDocument

		self.version += 1

        if runAsync == false {
            processEditSync(edit, readHandler: readHandler, completionHandler: completionHandler)
            return
        }

        processEditAsync(edit, readHandler: readHandler, completionHandler: completionHandler)
    }

    private func applyEdit(_ edit: ContentEdit, readHandler: @escaping Parser.ReadBlock) -> (TreeSitterParseState, TreeSitterParseState) {
        self.semaphore.wait()
        let state = self.parseState

        state.applyEdit(edit.inputEdit)
        self.parseState = TreeSitterParseState(tree: self.parser.parse(tree: state.tree, readBlock: readHandler))

        let oldState = state.copy()
        let newState = parseState.copy()

        self.semaphore.signal()

        return (oldState, newState)
    }

    private func processEditSync(_ edit: ContentEdit, readHandler: @escaping Parser.ReadBlock, completionHandler: () -> Void) {
        let (oldState, newState) = applyEdit(edit, readHandler: readHandler)

        let set = self.computeInvalidatedSet(from: oldState, to: newState, with: edit)

        completionHandler()

        dispatchInvalidatedSet(set)
    }

    private func processEditAsync(_ edit: ContentEdit, readHandler: @escaping Parser.ReadBlock, completionHandler: @escaping () -> Void) {
        outstandingEdits.append(edit)

        queue.async {
            let (oldState, newState) = self.applyEdit(edit, readHandler: readHandler)
			let set = self.computeInvalidatedSet(from: oldState, to: newState, with: edit)

			OperationQueue.main.addOperation {
				let completedEdit = self.outstandingEdits.removeFirst()

				assert(completedEdit.inputEdit == edit.inputEdit)

				self.dispatchInvalidatedSet(set)

				completionHandler()
			}
        }
    }

    func computeInvalidatedSet(from oldState: TreeSitterParseState, to newState: TreeSitterParseState, with edit: ContentEdit) -> IndexSet {
        let changedRanges = oldState.changedByteRanges(for: newState).map({ $0.range })

        // we have to ensure that any invalidated ranges don't fall outside of limit
        let clampedRanges = changedRanges.compactMap({ $0.clamped(to: edit.limit) })

        var set = IndexSet(integersIn: edit.affectedRange)

        set.insert(ranges: clampedRanges)

        return set
    }
}

extension TreeSitterClient {
    private func transformRangeSet(_ set: IndexSet) -> IndexSet {
        let rangeMutations = outstandingEdits.map({ $0.rangeMutation })

        var transformedSet = set

        // this ensures that the set we have computed lines up with
        // the current state of the world
        for rangeMutation in rangeMutations {
            transformedSet = rangeMutation.transform(set: transformedSet)
        }

        return transformedSet
    }

    private func dispatchInvalidatedSet(_ set: IndexSet) {
		dispatchPrecondition(condition: .onQueue(.main))

        let transformedSet = transformRangeSet(set)

        if transformedSet.isEmpty {
            return
        }

        self.invalidationHandler(transformedSet)
    }
}

extension TreeSitterClient {
    private func executeQuery(
        _ query: Query,
        in range: NSRange,
        textProvider: TextProvider?,
        resolve: @escaping (ResolvingQueryMatchSequence<[QueryMatch]>) -> [NamedRange],
        completionHandler: @escaping (Result<[NamedRange], TreeSitterClientError>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let startedVersion = version
        queue.async {
            self.semaphore.wait()
            let state = self.parseState.copy()
            self.semaphore.signal()

            DispatchQueue.global().async {
                let result: Result<[QueryMatch], TreeSitterClientError>
                if let tree = state.tree, let node = tree.rootNode {
                    let cursor = query.execute(node: node, in: tree)
                    cursor.setRange(range)
                    result = .success(Array(cursor))
                } else {
                    result = .failure(.stateInvalid)
                }
                OperationQueue.main.addOperation {
                    guard startedVersion == self.version else {
                        completionHandler(.failure(.staleContent))
                        return
                    }
                    let context = Predicate.Context(textProvider: textProvider ?? { _, _ in nil })
                    let resolved = result.map { resolve($0.resolve(with: context)) }
                    guard startedVersion == self.version else {
                        completionHandler(.failure(.staleContent))
                        return
                    }
                    completionHandler(resolved)
                }
            }
        }
    }

    public func executeHighlightsQuery(
        _ query: Query, in range: NSRange, textProvider: TextProvider? = nil,
        completionHandler: @escaping (Result<[NamedRange], TreeSitterClientError>) -> Void
    ) {
        executeQuery(query, in: range, textProvider: textProvider,
                     resolve: { $0.highlights() }, completionHandler: completionHandler)
    }

    public func executeInjectionsQuery(
        _ query: Query, in range: NSRange, textProvider: TextProvider? = nil,
        completionHandler: @escaping (Result<[NamedRange], TreeSitterClientError>) -> Void
    ) {
        executeQuery(query, in: range, textProvider: textProvider,
                     resolve: { $0.injections() }, completionHandler: completionHandler)
    }

    /// Fetches the current stable version of Tree
    ///
    /// This function always fetches the tree that represents the current state of the content, even if the
    /// system is working in the background.
    public func currentTree(completionHandler: @escaping (Result<Tree, TreeSitterClientError>) -> Void) {
		dispatchPrecondition(condition: .onQueue(.main))

        let startedVersion = version
        queue.async {
            self.semaphore.wait()
            let tree = self.parseState.tree?.copy()
            self.semaphore.signal()

            OperationQueue.main.addOperation {
                guard startedVersion == self.version else {
                    completionHandler(.failure(.staleContent))
                    return
                }
                if let tree {
                    completionHandler(.success(tree))
                } else {
                    completionHandler(.failure(.stateInvalid))
                }
            }
        }
    }

    /// Fetches the current stable version of Tree
    ///
    /// This function always fetches the tree that represents the current state of the content, even if the
    /// system is working in the background.
	@MainActor
    public func currentTree() async throws -> Tree {
        try await withCheckedThrowingContinuation { continuation in
            currentTree() { result in
				continuation.resume(with: result)
            }
        }
    }
}
