import AppKit
import Carbon

/// Provides Bailey's Finder service. The advertised menu item lives in
/// Info.plist; AppKit forwards matching service requests to this object.
@MainActor
final class BaileyApplicationDelegate: NSObject, NSApplicationDelegate {
    let workspace = WorkspaceApplication(loadSavedState: true)
    private var preparingToQuit = false

    /// Let AppKit finish quitting only after all edited files were written.
    /// A failed SSH or local save cancels termination and retains the editor.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard workspace.hasUnsavedEditors else { return .terminateNow }
        guard !preparingToQuit else { return .terminateLater }
        preparingToQuit = true
        Task { @MainActor in
            let saved = await workspace.saveBeforeTermination()
            preparingToQuit = false
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        workspace.willTerminate()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocuments(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
        // AppSettings is first initialized from SwiftUI's App.init(), where
        // NSApp may not exist yet. Reapply the saved override once AppKit is
        // ready, before SwiftUI creates the first window.
        AppSettings.shared.applyAppearance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NotificationCenter.default.addObserver(
            self, selector: #selector(mainMenuItemAdded(_:)),
            name: NSMenu.didAddItemNotification, object: nil
        )
        removeUnusedViewMenu()
        configureDeleteShortcut()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        removeUnusedViewMenu()
        configureDeleteShortcut()
    }

    @objc private func mainMenuItemAdded(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        if menu.items.last?.title.contains("\t") == true {
            Self.formatShortcutHints(in: menu)
        }
        if menu === NSApp.mainMenu { removeUnusedViewMenu() }
        if menu === NSApp.mainMenu
            || NSApp.mainMenu?.items.contains(where: { $0.submenu === menu }) == true {
            configureDeleteShortcut()
        }
    }

    /// A context menu may display a shortcut, but only the main menu owns its key equivalent.
    static func formatShortcutHints(in menu: NSMenu) {
        let hinted = menu.items.filter { $0.keyEquivalent.isEmpty && $0.title.contains("\t") }
        guard !hinted.isEmpty else { return }

        let font = NSFont.menuFont(ofSize: 0)
        let widest = menu.items.map {
            let label = $0.title.components(separatedBy: "\t").first ?? $0.title
            return (label as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        let tabStop = max(250, widest + 90)
        menu.minimumWidth = max(menu.minimumWidth, tabStop + 25)

        for item in hinted {
            let style = NSMutableParagraphStyle()
            style.tabStops = [NSTextTab(textAlignment: .right, location: tabStop)]
            let label = NSMutableAttributedString(
                string: item.title, attributes: [.font: font, .paragraphStyle: style]
            )
            let tab = (item.title as NSString).range(of: "\t")
            if tab.location != NSNotFound {
                let suffix = NSRange(location: tab.location + 1,
                                     length: (item.title as NSString).length - tab.location - 1)
                label.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: suffix)
            }
            item.attributedTitle = label
            if let tabIndex = item.title.firstIndex(of: "\t") {
                item.setAccessibilityLabel(String(item.title[..<tabIndex]))
            }
        }
    }

    private func configureDeleteShortcut() {
        guard let edit = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { menu in
            menu.items.contains { $0.action == #selector(TreeKeyboardView.copy(_:)) }
                && menu.items.contains { $0.action == #selector(TreeKeyboardView.paste(_:)) }
        }), let delete = edit.items.first(where: {
            $0.action == #selector(TreeKeyboardView.delete(_:))
        }) else { return }
        delete.keyEquivalent = String(UnicodeScalar(NSBackspaceCharacter)!)
        delete.keyEquivalentModifierMask = []
    }

    private func removeUnusedViewMenu() {
        guard let menu = NSApp.mainMenu,
              let panelIndex = menu.items.firstIndex(where: {
                  $0.title == String(localized: "Panel", table: "Interface")
              }), panelIndex > 0,
              let viewItem = menu.item(at: panelIndex - 1),
              let viewMenu = viewItem.submenu,
              viewMenu.items.allSatisfy({
                  $0.isSeparatorItem || $0.action == #selector(NSWindow.toggleFullScreen(_:))
                      || $0.title == String(localized: "Enter Full Screen", table: "Interface")
                      || $0.title == String(localized: "Exit Full Screen", table: "Interface")
              }) else { return }
        // SwiftUI inserts its unused View menu immediately before Bailey's Panel menu.
        menu.removeItem(viewItem)
    }

    /// Receive the entire Finder Apple Event before SwiftUI WindowGroup can
    /// turn one document-open event into an additional workspace window.
    @objc private func handleOpenDocuments(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        let urls = Self.documentURLs(
            from: event.paramDescriptor(forKeyword: keyDirectObject)
        )
        workspace.openExternalFiles(urls)
    }

    static func documentURLs(from fileList: NSAppleEventDescriptor?) -> [URL] {
        guard let fileList, fileList.numberOfItems > 0 else { return [] }
        return (1...fileList.numberOfItems).compactMap {
            fileList.atIndex($0)?.fileURLValue
        }
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
        workspace.openDirectories(directories)
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
