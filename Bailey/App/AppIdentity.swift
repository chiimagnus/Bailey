import Foundation

nonisolated enum AppIdentity {
    static let bundleIdentifier = "chiimagnus.bailey"
    static let displayName = "Bailey"

    static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/bailey", isDirectory: true)
    }

    static var historyDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("bailey", isDirectory: true)
    }
}
