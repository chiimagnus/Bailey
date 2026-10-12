import Foundation

nonisolated enum AppIdentity {
    static let bundleIdentifier = "chiimagnus.kero"
    static let displayName = "Kero"

    static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/kero", isDirectory: true)
    }

    static var historyDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("kero", isDirectory: true)
    }
}
