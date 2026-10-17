import AppKit

/// Provides Bailey's Finder service. The advertised menu item lives in
/// Info.plist; AppKit forwards matching service requests to this object.
@MainActor
final class BaileyApplicationDelegate: NSObject, NSApplicationDelegate {
    private var preparingToQuit = false

    /// Let AppKit finish quitting only after all edited files were written.
    /// A failed SSH or local save cancels termination and retains the editor.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard TerminalManager.hasUnsavedEditors else { return .terminateNow }
        guard !preparingToQuit else { return .terminateLater }
        preparingToQuit = true
        Task { @MainActor in
            let saved = await TerminalManager.saveBeforeTermination()
            preparingToQuit = false
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // AppSettings is first initialized from SwiftUI's App.init(), where
        // NSApp may not exist yet. Reapply the saved override once AppKit is
        // ready, before SwiftUI creates the first window.
        AppSettings.shared.applyAppearance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
    }

    /// Opens every directory Finder placed on the service pasteboard as a
    /// project in the active Bailey window.
    @objc func openInBailey(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let directories = Self.directories(from: pasteboard)
        guard !directories.isEmpty else {
            error.pointee = String(localized: "Select one or more folders to open in Bailey.", table: "Settings") as NSString
            return
        }

        NSApp.activate()
        TerminalManager.openDirectories(directories)
    }

    private static func directories(from pasteboard: NSPasteboard) -> [String] {
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        var candidates = pasteboard.propertyList(forType: filenamesType) as? [String] ?? []

        if candidates.isEmpty,
           let urls = pasteboard.readObjects(
               forClasses: [NSURL.self],
               options: [.urlReadingFileURLsOnly: true]
           ) as? [URL] {
            candidates = urls.map(\.path)
        }

        if candidates.isEmpty, let text = pasteboard.string(forType: .string) {
            candidates = text.split(whereSeparator: \.isNewline).map(String.init)
        }

        let fileManager = FileManager.default
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            let path: String
            if let url = URL(string: candidate), url.isFileURL {
                path = url.path
            } else {
                path = (candidate as NSString).expandingTildeInPath
            }

            let standardized = URL(
                fileURLWithPath: path,
                isDirectory: true
            ).standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: standardized,
                isDirectory: &isDirectory
            ), isDirectory.boolValue, seen.insert(standardized).inserted else {
                return nil
            }
            return standardized
        }
    }
}
