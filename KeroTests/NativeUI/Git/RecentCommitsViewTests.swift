import AppKit
import Observation
import SwiftUI
import XCTest
@testable import kero

@MainActor
@Observable
private final class GraphSelection {
    var expanded: Set<String> = []
    var folders: Set<String> = []
}

@MainActor
final class RecentCommitsViewTests: XCTestCase {
    private func settle() {
        let until = Date().addingTimeInterval(0.12)
        while Date() < until {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func click(_ point: NSPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            )!
            window.sendEvent(event)
        }
        settle()
    }

    func testMergedHistoryOpensItsRealFileAfterExpansion() {
        let selection = GraphSelection()
        let files: [GitStatusModel.RecentCommit.FileChange] = [
            .init(status: "M", path: "Sources/file.swift", originalPath: nil)
        ]
        func row(_ id: String, parents: [String], name: String, current: Bool = false)
            -> GitStatusModel.RecentCommit {
            .init(hash: id, shortHash: id, subject: name, author: "Developer",
                  date: .distantPast, parentHashes: parents,
                  references: current
                    ? [.init(kind: .currentBranch, name: "main")]
                    : [], files: files)
        }
        let commits = [
            row("merge", parents: ["base", "side"], name: "Merge branch", current: true),
            row("side", parents: ["root"], name: "Side commit"),
            row("base", parents: ["root"], name: "Main commit"),
            row("root", parents: [], name: "Root commit"),
        ]
        let width: CGFloat = 440
        let height: CGFloat = 390
        var diffs: [String] = []
        let window = NSWindow(
            contentRect: NSRect(x: -1200, y: -1200, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RecentCommitsView(
            commits: commits,
            expandedCommitIDs: Binding(
                get: { selection.expanded },
                set: { selection.expanded = $0 }
            ),
            collapsedFolders: Binding(
                get: { selection.folders },
                set: { selection.folders = $0 }
            ),
            viewMode: .list, fontScale: 1,
            hasMoreCommits: false, isLoadingMore: false,
            loadMore: { false },
            openDiff: { commit, file in diffs.append(commit.hash + ":" + file.path) }
        ).frame(width: width, height: height, alignment: .topLeading)
            .background(Color(nsColor: Theme.sidebar)))
        window.orderFront(nil)
        settle()
        if let v = window.contentView, let b = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: b)
            try? b.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: "/tmp/kero-graph-qa-merge.png"))
        }
        click(NSPoint(x: 95, y: height - 18), in: window)
        XCTAssertTrue(selection.expanded.contains("merge"))
        click(NSPoint(x: 125, y: height - 64), in: window)
        XCTAssertEqual(diffs, ["merge:Sources/file.swift"])
        window.close()
    }

    func testCommitTitleExpandsFilesInWideAndNarrowPanels() {
        for (width, scale) in [(CGFloat(420), CGFloat(1)),
                               (CGFloat(260), CGFloat(1.6))] {
            let selection = GraphSelection()
            let commit = GitStatusModel.RecentCommit(
                hash: "0000000000000000000000000000000000000001",
                shortHash: "0000000", subject: "Add feature",
                author: "Developer", date: .now,
                parentHashes: [],
                references: [
                    .init(kind: .currentBranch, name: "main"),
                    .init(kind: .remoteBranch, name: "origin/main"),
                    .init(kind: .tag, name: "v1.2.3"),
                ],
                files: [.init(status: "A", path: "Sources/new.swift", originalPath: nil)]
            )
            let height: CGFloat = 180
            let window = NSWindow(
                contentRect: NSRect(x: -1200, y: -1200, width: width, height: height),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: RecentCommitsView(
                commits: [commit],
                expandedCommitIDs: Binding(
                    get: { selection.expanded },
                    set: { selection.expanded = $0 }
                ),
                collapsedFolders: Binding(
                    get: { selection.folders },
                    set: { selection.folders = $0 }
                ),
                viewMode: .list, fontScale: scale,
                hasMoreCommits: false, isLoadingMore: false,
                loadMore: { false }, openDiff: { _, _ in }
            )
            .frame(width: width, height: height, alignment: .topLeading)
                .background(Color(nsColor: Theme.sidebar)))
            window.orderFront(nil)
            settle()
            if let v = window.contentView, let b = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: b)
                try? b.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: "/tmp/kero-graph-qa-\(Int(width)).png"))
            }
            let gutter = max(41, 37 * scale)
            let titlePoint = NSPoint(x: gutter + 18, y: height - 14 * scale)
            click(titlePoint, in: window)
            XCTAssertTrue(selection.expanded.contains(commit.hash),
                          "Commit title must remain clickable at width \(width)")
            click(titlePoint, in: window)
            XCTAssertFalse(selection.expanded.contains(commit.hash))
            window.close()
        }
    }
}
