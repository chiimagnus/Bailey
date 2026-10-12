import Foundation

nonisolated struct AppIdentity {
    static let current = AppIdentity(bundleIdentifier: Bundle.main.bundleIdentifier ?? "chiimagnus.kero")

    let bundleIdentifier: String

    var dataDirectoryName: String {
        bundleIdentifier == "chiimagnus.kero.dev" ? "kero-dev" : "kero"
    }

    var displayName: String {
        bundleIdentifier == "chiimagnus.kero.dev" ? "Kero Dev" : "Kero"
    }

    var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(dataDirectoryName, isDirectory: true)
    }

    var historyDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(dataDirectoryName, isDirectory: true)
    }

    var isolatedDefaultsSuite: String {
        bundleIdentifier + ".isolated-ui-test"
    }
}
