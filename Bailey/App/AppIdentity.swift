import Foundation

nonisolated enum AppIdentity {
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "chiimagnus.bailey"
    static let isDevelopment = bundleIdentifier == "chiimagnus.bailey.dev"
    static let displayName = isDevelopment ? "Bailey Dev" : "Bailey"

    static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(isDevelopment ? ".config/bailey-dev" : ".config/bailey",
                                    isDirectory: true)
    }

    static var historyDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(isDevelopment ? "bailey-dev" : "bailey",
                                       isDirectory: true)
    }
}
