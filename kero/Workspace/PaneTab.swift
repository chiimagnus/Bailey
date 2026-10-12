import Combine
import Foundation

enum PaneContent: nonisolated Identifiable {
    case session(TerminalSession)
    case file(FileTab)
    case browser(BrowserTab)
    case diff(DiffTab)

    nonisolated var id: UUID {
        switch self {
        case .session(let session): session.id
        case .file(let file): file.id
        case .browser(let browser): browser.id
        case .diff(let diff): diff.id
        }
    }

    var isDiff: Bool {
        if case .diff = self { return true }
        return false
    }

    var isFile: Bool {
        if case .file = self { return true }
        return false
    }

    @MainActor var title: String {
        switch self {
        case .session(let session): session.title
        case .file(let file): file.tabTitle
        case .browser(let browser): browser.title
        case .diff(let diff): diff.tabTitle
        }
    }

    @MainActor var systemImage: String {
        switch self {
        case .session: "terminal"
        case .file: "doc.text"
        case .browser: "globe"
        case .diff: "plus.forwardslash.minus"
        }
    }

    @MainActor var fileIconPath: String? {
        switch self {
        case .file(let file): file.path
        case .diff(let diff): diff.path
        case .session, .browser: nil
        }
    }

    @MainActor var isDirty: Bool {
        switch self {
        case .file(let file): file.isDirty
        case .diff(let diff): diff.isDirty
        case .session, .browser: false
        }
    }

    @MainActor var saveError: String? {
        switch self {
        case .file(let file): file.saveError
        case .diff(let diff): diff.saveError
        case .session, .browser: nil
        }
    }

    @MainActor func save() async {
        switch self {
        case .file(let file): await file.save()
        case .diff(let diff): await diff.save()
        case .session, .browser: break
        }
    }
}

@MainActor
final class PaneTab: nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id = UUID()
    let content: PaneContent
    @Published var customName: String? {
        didSet { if customName != oldValue { onSnapshotChange?() } }
    }
    weak var contextSession: TerminalSession? {
        didSet { if contextSession?.id != oldValue?.id { onSnapshotChange?() } }
    }
    var onSnapshotChange: (() -> Void)?
    private var dirtyObservation: AnyCancellable?

    init(content: PaneContent) {
        self.content = content
        let publisher: AnyPublisher<Bool, Never>
        switch content {
        case .file(let file): publisher = file.$isDirty.eraseToAnyPublisher()
        case .diff(let diff): publisher = diff.$isDirty.eraseToAnyPublisher()
        case .session, .browser: return
        }
        dirtyObservation = publisher.removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var displayTitle: String {
        if let customName, !customName.isEmpty { return customName }
        return content.title
    }
}
