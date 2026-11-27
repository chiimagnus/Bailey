import AppKit
import SwiftUI
import XCTest
@testable import Bailey

/// Isolated workspace owners and minimal native file components in separate windows. The current key window is
/// not a valid substitute for the manager that owns a file or its save target.
@MainActor
final class WindowOwnershipIntegrationTests: XCTestCase {
    @MainActor private lazy var workspaceApplication = WorkspaceApplication()

    func testClosedProjectCannotPresentLateFileErrorInItsFormerWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let removedRoot = root.appendingPathComponent("removed")
        let currentRoot = root.appendingPathComponent("current")
        try FileManager.default.createDirectory(at: removedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = workspaceApplication.makeWindow()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 520),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.close()
            manager.windowClosed()
        }
        manager.attach(to: window)
        manager.addLocalFolders([removedRoot, currentRoot])
        window.orderFront(nil)

        let removed = try XCTUnwrap(manager.projects.first { $0.customDirectory == removedRoot.path })
        let current = try XCTUnwrap(manager.projects.first { $0.customDirectory == currentRoot.path })
        let delayed = try XCTUnwrap(removed.fileTree.onError)
        manager.close(removed)
        XCTAssertFalse(manager.projects.contains { $0 === removed })
        XCTAssertNil(removed.fileTree.onError, "The retired project must lose its window presentation callback")

        delayed("Obsolete error", "A request finished after project removal")
        XCTAssertNil(window.attachedSheet, "An obsolete callback must not present a sheet")
        if let sheet = window.attachedSheet { window.endSheet(sheet) }

        await current.fileTree.sync(root: currentRoot.path, backend: LocalWorkspaceBackend.shared)
        await current.fileTree.beginNewFile(in: currentRoot.path)
        let rejected = await current.fileTree.commitDraft(name: "invalid/name")
        XCTAssertNil(rejected)
        XCTAssertNotNil(window.attachedSheet, "A real error in the live project must still present its sheet")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: currentRoot.path), [])
    }

    func testFilesCutClipboardDoesNotMoveUntilPasteAndUsesOriginTree() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let into = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.txt")
        let dest = into.appendingPathComponent("original.txt")
        try "exact bytes".write(to: source, atomically: true, encoding: .utf8)
        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        guard let project = manager.selectedProject else {
            return XCTFail("Expected a pinned Files project")
        }
        let target = project.panelContext.identity
        await project.fileTree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        XCTAssertFalse(manager.canPasteFileTree(in: project, target: target, pasteboard: pasteboard))

        manager.performFileTreeCommand(
            .copy([source.path], cut: true), in: project, target: target,
            pasteboard: pasteboard
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                      "Cut must not delete or move the source before paste")
        XCTAssertTrue(FileTreeClipboard.read(from: pasteboard)?.cut == true)
        XCTAssertTrue(manager.canPasteFileTree(in: project, target: target, pasteboard: pasteboard))
        let anotherWindow = workspaceApplication.makeWindow()
        defer { anotherWindow.windowClosed() }
        anotherWindow.addLocalFolders([root])
        let otherProject = try XCTUnwrap(anotherWindow.selectedProject)
        let otherTarget = otherProject.panelContext.identity
        XCTAssertTrue(
            anotherWindow.canPasteFileTree(in: otherProject, target: otherTarget, pasteboard: pasteboard),
            "A local file URL is copyable into another local project"
        )
        manager.performFileTreeCommand(
            .paste(into: into.path), in: project, target: target,
            pasteboard: pasteboard
        )
        try await wait { FileManager.default.fileExists(atPath: dest.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "exact bytes")
        try await wait { FileTreeClipboard.read(from: pasteboard) == nil }
        XCTAssertFalse(manager.canPasteFileTree(in: project, target: target, pasteboard: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), source.path,
                       "Completed cut must preserve plain-text paths but remove stale transfer metadata")
    }

    func testPastingCopiedFolderOntoItselfDuplicatesBesideSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = folder.appendingPathComponent("leaf.txt")
        let other = root.appendingPathComponent("other.txt")
        let bytes = Data("directory contents 中文\n".utf8)
        try bytes.write(to: original)
        try Data("other contents\n".utf8).write(to: other)

        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let target = project.panelContext.identity
        await project.fileTree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))

        manager.performFileTreeCommand(.copy([folder.path], cut: false),
                                       in: project, target: target, pasteboard: pasteboard)
        XCTAssertEqual(FileTreeClipboard.localURLs(from: pasteboard).map(\.path), [folder.path])
        manager.performFileTreeCommand(.paste(into: folder.path),
                                       in: project, target: target, pasteboard: pasteboard)
        let sibling = root.appendingPathComponent("folder copy/leaf.txt")
        try await wait { FileManager.default.fileExists(atPath: sibling.path) }
        XCTAssertEqual(try Data(contentsOf: sibling), bytes)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("folder copy").path
        ), "Copying a folder onto itself must not recursively place it inside itself")

        manager.performFileTreeCommand(.copy([other.path], cut: false),
                                       in: project, target: target, pasteboard: pasteboard)
        manager.performFileTreeCommand(.paste(into: folder.path),
                                       in: project, target: target, pasteboard: pasteboard)
        let inside = folder.appendingPathComponent("other.txt")
        try await wait { FileManager.default.fileExists(atPath: inside.path) }
        XCTAssertEqual(try Data(contentsOf: inside), Data("other contents\n".utf8))
        XCTAssertEqual(try Data(contentsOf: other), Data("other contents\n".utf8))
    }

    func testLocalClipboardCopiesAndMovesAcrossProjectsAndWindows() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstRoot = base.appendingPathComponent("Project A")
        let secondRoot = base.appendingPathComponent("Project B")
        let receiving = secondRoot.appendingPathComponent("receiving")
        for folder in [firstRoot, receiving] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: base) }
        let source = firstRoot.appendingPathComponent("跨项目 file.txt")
        let contents = Data("cross-project document 中文\n".utf8)
        try contents.write(to: source)

        let origin = workspaceApplication.makeWindow()
        let anotherEditor = workspaceApplication.makeWindow()
        let destination = workspaceApplication.makeWindow()
        defer {
            origin.windowClosed()
            anotherEditor.windowClosed()
            destination.windowClosed()
        }
        origin.addLocalFolders([firstRoot])
        anotherEditor.addLocalFolders([firstRoot])
        destination.addLocalFolders([secondRoot])
        let a = try XCTUnwrap(origin.selectedProject)
        let b = try XCTUnwrap(destination.selectedProject)
        let aTarget = a.panelContext.identity
        let bTarget = b.panelContext.identity
        await a.fileTree.sync(root: firstRoot.path, backend: LocalWorkspaceBackend.shared)
        await b.fileTree.sync(root: secondRoot.path, backend: LocalWorkspaceBackend.shared)
        anotherEditor.openFile(source.path)
        guard case .file(let opened)? = anotherEditor.selectedProject?.selectedTab?.content else {
            return XCTFail("Expected an open document in a second window")
        }
        try await opened.waitForText()

        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        origin.performFileTreeCommand(
            .copy([source.path], cut: false), in: a, target: aTarget, pasteboard: pasteboard
        )
        XCTAssertTrue(destination.canPasteFileTree(in: b, target: bTarget, pasteboard: pasteboard))
        destination.performFileTreeCommand(
            .paste(into: secondRoot.path), in: b, target: bTarget, pasteboard: pasteboard
        )
        let copied = secondRoot.appendingPathComponent(source.lastPathComponent)
        try await wait { FileManager.default.fileExists(atPath: copied.path) }
        XCTAssertEqual(try Data(contentsOf: copied), contents)
        XCTAssertEqual(try Data(contentsOf: source), contents)
        XCTAssertEqual(opened.path, source.path, "Copy never remaps an open source file")

        origin.performFileTreeCommand(
            .copy([source.path], cut: true), in: a, target: aTarget, pasteboard: pasteboard
        )
        destination.performFileTreeCommand(
            .paste(into: receiving.path), in: b, target: bTarget, pasteboard: pasteboard
        )
        let moved = receiving.appendingPathComponent(source.lastPathComponent)
        try await wait { FileManager.default.fileExists(atPath: moved.path) }
        try await wait { !FileManager.default.fileExists(atPath: source.path) }
        try await wait { opened.path == moved.path }
        try await wait { FileTreeClipboard.read(from: pasteboard) == nil }
        try await wait { !a.fileTree.items.contains(where: { $0.path == source.path }) }
        XCTAssertEqual(try Data(contentsOf: moved), contents)
        XCTAssertEqual(try Data(contentsOf: copied), contents)
        XCTAssertFalse(FileTreeClipboard.canReadFiles(from: pasteboard))
        XCTAssertEqual(origin.selectedProjectID, a.id)
        XCTAssertEqual(destination.selectedProjectID, b.id)
    }

    func testFinderStyleFileURLsPasteAsCopyButExplicitMoveRemovesOnlyOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = root.appendingPathComponent("Finder source")
        let projectRoot = root.appendingPathComponent("Project")
        let copiedInto = projectRoot.appendingPathComponent("copied")
        let movedInto = projectRoot.appendingPathComponent("moved")
        for folder in [outside, copiedInto, movedInto] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let file = outside.appendingPathComponent("报告 🧪.bin")
        let directory = outside.appendingPathComponent("empty dir")
        let symlink = outside.appendingPathComponent("dangling-link")
        let bytes = Data([127, 0, 10, 255])
        try bytes.write(to: file)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: symlink.path, withDestinationPath: "missing")

        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([projectRoot])
        let project = try XCTUnwrap(manager.selectedProject)
        let target = project.panelContext.identity
        await project.fileTree.sync(root: projectRoot.path, backend: LocalWorkspaceBackend.shared)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        XCTAssertTrue(FileTreeClipboard.writeLocalFiles([file.path, directory.path, symlink.path], to: pasteboard))
        XCTAssertNil(FileTreeClipboard.read(from: pasteboard), "Finder does not supply private tokens")
        XCTAssertTrue(manager.canPasteFileTree(in: project, target: target, pasteboard: pasteboard))
        manager.performFileTreeCommand(
            .paste(into: copiedInto.path), in: project, target: target, pasteboard: pasteboard
        )
        try await wait {
            [file, directory, symlink].allSatisfy {
                LocalFileIdentity.read(copiedInto.appendingPathComponent($0.lastPathComponent).path) != nil
            }
        }
        XCTAssertEqual(try Data(contentsOf: copiedInto.appendingPathComponent(file.lastPathComponent)), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNotNil(LocalFileIdentity.read(symlink.path))
        XCTAssertEqual(FileTreeClipboard.localURLs(from: pasteboard).count, 3)

        manager.performFileTreeCommand(
            .paste(into: movedInto.path, move: true), in: project, target: target,
            pasteboard: pasteboard
        )
        try await wait {
            [file, directory, symlink].allSatisfy {
                LocalFileIdentity.read(movedInto.appendingPathComponent($0.lastPathComponent).path) != nil
            }
        }
        try await wait { !FileTreeClipboard.canReadFiles(from: pasteboard) }
        for source in [file, directory, symlink] {
            XCTAssertNil(LocalFileIdentity.read(source.path))
        }
        XCTAssertEqual(try Data(contentsOf: movedInto.appendingPathComponent(file.lastPathComponent)), bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: movedInto.appendingPathComponent(symlink.lastPathComponent).path
        ), "missing")
    }

    func testForeignOrTamperedCutRecordCannotAuthorizeDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstRoot = root.appendingPathComponent("A")
        let secondRoot = root.appendingPathComponent("B")
        for folder in [firstRoot, secondRoot] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let file = firstRoot.appendingPathComponent("keep.txt")
        try Data("original source".utf8).write(to: file)
        let origin = workspaceApplication.makeWindow()
        let destination = workspaceApplication.makeWindow()
        defer { origin.windowClosed(); destination.windowClosed() }
        origin.addLocalFolders([firstRoot])
        destination.addLocalFolders([secondRoot])
        let sourceProject = try XCTUnwrap(origin.selectedProject)
        let targetProject = try XCTUnwrap(destination.selectedProject)
        let a = sourceProject.panelContext.identity
        let b = targetProject.panelContext.identity
        await sourceProject.fileTree.sync(root: firstRoot.path, backend: LocalWorkspaceBackend.shared)
        await targetProject.fileTree.sync(root: secondRoot.path, backend: LocalWorkspaceBackend.shared)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))

        origin.performFileTreeCommand(
            .copy([file.path], cut: true), in: sourceProject, target: a, pasteboard: pasteboard
        )
        let originalRecord = try XCTUnwrap(FileTreeClipboard.read(from: pasteboard))
        XCTAssertTrue(workspaceApplication.trustedFileClipboard(originalRecord, pasteboard: pasteboard))
        // A second pasteboard writer changes the version even if it copies the token byte-for-byte.
        XCTAssertTrue(FileTreeClipboard.write(originalRecord, local: true, to: pasteboard))
        XCTAssertFalse(workspaceApplication.trustedFileClipboard(originalRecord, pasteboard: pasteboard))
        destination.performFileTreeCommand(
            .paste(into: secondRoot.path), in: targetProject, target: b, pasteboard: pasteboard
        )
        let result = secondRoot.appendingPathComponent("keep.txt")
        try await wait { FileManager.default.fileExists(atPath: result.path) }
        XCTAssertEqual(try Data(contentsOf: result), Data("original source".utf8))
        XCTAssertEqual(try Data(contentsOf: file), Data("original source".utf8))
        XCTAssertTrue(FileTreeClipboard.canReadFiles(from: pasteboard))
        XCTAssertEqual(FileTreeClipboard.read(from: pasteboard), originalRecord)

        // A newly constructed application registry cannot authorize the prior cut.
        let restarted = WorkspaceApplication()
        let newWindow = restarted.makeWindow()
        defer { newWindow.windowClosed() }
        let thirdRoot = root.appendingPathComponent("C")
        try FileManager.default.createDirectory(at: thirdRoot, withIntermediateDirectories: true)
        newWindow.addLocalFolders([thirdRoot])
        let thirdProject = try XCTUnwrap(newWindow.selectedProject)
        let c = thirdProject.panelContext.identity
        await thirdProject.fileTree.sync(root: thirdRoot.path, backend: LocalWorkspaceBackend.shared)
        newWindow.performFileTreeCommand(
            .paste(into: thirdRoot.path), in: thirdProject, target: c, pasteboard: pasteboard
        )
        try await wait { FileManager.default.fileExists(atPath: thirdRoot.appendingPathComponent(file.lastPathComponent).path) }
        XCTAssertEqual(try Data(contentsOf: file), Data("original source".utf8))
    }

    func testCopyFromDirtyEditorLeavesDraftIntactAndCopiesSavedDiskBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let copiedInto = root.appendingPathComponent("copied")
        try FileManager.default.createDirectory(at: copiedInto, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("working.txt")
        try Data("saved".utf8).write(to: source)
        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        manager.openFile(source.path)
        let project = try XCTUnwrap(manager.selectedProject)
        let target = project.panelContext.identity
        await project.fileTree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        guard case .file(let file)? = project.selectedTab?.content else {
            return XCTFail("Open file required")
        }
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        file.text = "unsaved editor draft"
        file.refreshDirtyState()
        XCTAssertTrue(file.isDirty)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        manager.performFileTreeCommand(
            .copy([source.path], cut: false), in: project, target: target, pasteboard: pasteboard
        )
        manager.performFileTreeCommand(
            .paste(into: copiedInto.path), in: project, target: target, pasteboard: pasteboard
        )
        let copied = copiedInto.appendingPathComponent("working.txt")
        try await wait { FileManager.default.fileExists(atPath: copied.path) }
        XCTAssertEqual(try Data(contentsOf: copied), Data("saved".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("saved".utf8))
        XCTAssertEqual(file.text, "unsaved editor draft")
        XCTAssertTrue(file.isDirty, "Copy must never force-save or discard an editor draft")
    }

    func testCutMoveSavesDirtyEditorBeforeMovingTheRealFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destinationFolder = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(
            at: destinationFolder, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("draft.txt")
        try Data("original disk bytes".utf8).write(to: source)
        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        manager.openFile(source.path)
        let project = try XCTUnwrap(manager.selectedProject)
        let target = project.panelContext.identity
        await project.fileTree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        guard case .file(let file)? = project.selectedTab?.content else {
            return XCTFail("An open editor is required")
        }
        try await file.waitForText()
        file.text = "new saved content from Bailey"
        file.refreshDirtyState()
        XCTAssertTrue(file.isDirty)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        manager.performFileTreeCommand(
            .copy([source.path], cut: true), in: project, target: target, pasteboard: pasteboard
        )
        manager.performFileTreeCommand(
            .paste(into: destinationFolder.path), in: project, target: target,
            pasteboard: pasteboard
        )
        let moved = destinationFolder.appendingPathComponent(source.lastPathComponent)
        try await wait { LocalFileIdentity.read(moved.path) != nil }
        try await wait { LocalFileIdentity.read(source.path) == nil }
        try await wait { file.path == moved.path }
        XCTAssertEqual(try Data(contentsOf: moved), Data("new saved content from Bailey".utf8))
        XCTAssertFalse(file.isDirty)
        XCTAssertFalse(FileTreeClipboard.canReadFiles(from: pasteboard))
    }

    func testExternalPartialMoveKeepsOnlyLiveFinderFileURLsForRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = root.appendingPathComponent("Finder")
        let projectRoot = root.appendingPathComponent("Bailey")
        for folder in [outside, projectRoot] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let first = outside.appendingPathComponent("one.txt")
        let second = outside.appendingPathComponent("two.txt")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        let conflict = projectRoot.appendingPathComponent("two.txt")
        try Data("original target".utf8).write(to: conflict)

        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([projectRoot])
        let project = try XCTUnwrap(manager.selectedProject)
        let target = project.panelContext.identity
        await project.fileTree.sync(root: projectRoot.path, backend: LocalWorkspaceBackend.shared)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        XCTAssertTrue(FileTreeClipboard.writeLocalFiles([first.path, second.path], to: pasteboard))
        manager.performFileTreeCommand(
            .paste(into: projectRoot.path, move: true),
            in: project, target: target, pasteboard: pasteboard
        )
        try await wait { FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("one.txt").path) }
        try await wait { FileTreeClipboard.localURLs(from: pasteboard).map(\.path) == [second.path] }
        XCTAssertNil(LocalFileIdentity.read(first.path))
        XCTAssertNotNil(LocalFileIdentity.read(second.path))
        XCTAssertEqual(try Data(contentsOf: conflict), Data("original target".utf8))
        XCTAssertNil(FileTreeClipboard.read(from: pasteboard), "Finder partials stay public URLs")
        try FileManager.default.removeItem(at: conflict)
        manager.performFileTreeCommand(
            .paste(into: projectRoot.path, move: true),
            in: project, target: target, pasteboard: pasteboard
        )
        try await wait { LocalFileIdentity.read(second.path) == nil }
        try await wait { !FileTreeClipboard.canReadFiles(from: pasteboard) }
        XCTAssertEqual(try Data(contentsOf: projectRoot.appendingPathComponent("two.txt")),
                       Data("two".utf8))
    }

    func testMovingSymlinkDoesNotSaveItsUnrelatedDirtyTarget() async throws {
        for (viaClipboard, openedThroughLink) in [(true, false), (false, false), (true, true), (false, true)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let destination = root.appendingPathComponent("destination")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let actual = root.appendingPathComponent("target.txt")
            let link = root.appendingPathComponent("link.txt")
            try Data("saved bytes".utf8).write(to: actual)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target.txt")

            let manager = workspaceApplication.makeWindow()
            defer { manager.windowClosed() }
            manager.addLocalFolders([root])
            manager.openFile(openedThroughLink ? link.path : actual.path)
            let project = try XCTUnwrap(manager.selectedProject)
            let target = project.panelContext.identity
            await project.fileTree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
            guard case .file(let file)? = project.selectedTab?.content else {
                return XCTFail("An open editor of the symlink target is required")
            }
            try await file.waitForText()
            file.text = "unsaved draft"
            file.refreshDirtyState()
            XCTAssertTrue(file.isDirty)

            if viaClipboard {
                let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
                manager.performFileTreeCommand(
                    .copy([link.path], cut: true), in: project, target: target, pasteboard: pasteboard
                )
                manager.performFileTreeCommand(
                    .paste(into: destination.path), in: project, target: target,
                    pasteboard: pasteboard
                )
            } else {
                let batch = await manager.performFileOperation(
                    .move, paths: [link.path], into: destination.path,
                    in: project, target: target
                )
                XCTAssertTrue(batch.failures.isEmpty)
            }

            let moved = destination.appendingPathComponent("link.txt")
            try await wait { LocalFileIdentity.read(moved.path) != nil }
            XCTAssertNil(LocalFileIdentity.read(link.path))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: moved.path),
                           "target.txt")
            XCTAssertEqual(try Data(contentsOf: actual), Data("saved bytes".utf8),
                           "Moving a link entry must not commit the target editor's draft")
            XCTAssertEqual(file.path, openedThroughLink ? moved.path : actual.path)
            XCTAssertTrue(file.isDirty, "The editor's unsaved draft must survive the link move")
        }
    }

    func testPartialCutCannotReauthorizeAReplacedSourceForRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a.txt")
        let replaced = root.appendingPathComponent("b.txt")
        try Data("first".utf8).write(to: first)
        try Data("original second".utf8).write(to: replaced)

        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let target = project.panelContext.identity
        await project.fileTree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        manager.performFileTreeCommand(
            .copy([first.path, replaced.path], cut: true),
            in: project, target: target, pasteboard: pasteboard
        )
        manager.performFileTreeCommand(
            .paste(into: destination.path),
            in: project, target: target, pasteboard: pasteboard
        )
        try FileManager.default.removeItem(at: replaced)
        try Data("new second inode".utf8).write(to: replaced)

        try await wait { LocalFileIdentity.read(first.path) == nil }
        try await wait {
            FileTreeClipboard.localURLs(from: pasteboard).map(\.path) == [replaced.path]
        }
        XCTAssertEqual(try Data(contentsOf: replaced), Data("new second inode".utf8))
        XCTAssertNil(LocalFileIdentity.read(destination.appendingPathComponent("b.txt").path))
        XCTAssertNil(FileTreeClipboard.read(from: pasteboard),
                     "A partial cut must not create a fresh delete authorization for a replaced file")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("a.txt")),
                       Data("first".utf8))
    }

    func testCutMoveDirectoryAllowsProtectedDirtyDescendantSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sourceDirectory = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        for folder in [sourceDirectory, destination] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let child = sourceDirectory.appendingPathComponent("child.txt")
        try Data("original".utf8).write(to: child)
        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        manager.openFile(child.path)
        let project = try XCTUnwrap(manager.selectedProject)
        let target = project.panelContext.identity
        await project.fileTree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        guard case .file(let file)? = project.selectedTab?.content else {
            return XCTFail("A real open descendant editor is required")
        }
        try await file.waitForText()
        file.text = "saved by Bailey"
        file.refreshDirtyState()
        XCTAssertTrue(file.isDirty)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        manager.performFileTreeCommand(
            .copy([sourceDirectory.path], cut: true),
            in: project, target: target, pasteboard: pasteboard
        )
        manager.performFileTreeCommand(
            .paste(into: destination.path),
            in: project, target: target, pasteboard: pasteboard
        )
        let moved = destination.appendingPathComponent("source/child.txt")
        try await wait { LocalFileIdentity.read(moved.path) != nil }
        try await wait { LocalFileIdentity.read(sourceDirectory.path) == nil }
        XCTAssertEqual(try Data(contentsOf: moved), Data("saved by Bailey".utf8))
        XCTAssertEqual(file.path, moved.path)
        XCTAssertFalse(file.isDirty)
    }

    func testQueuedDirectoryCutRejectsReplacementBeforeProtectedEditorSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sourceDirectory = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        for folder in [sourceDirectory, destination] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let child = sourceDirectory.appendingPathComponent("child.txt")
        try Data("original".utf8).write(to: child)
        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        manager.openFile(child.path)
        let project = try XCTUnwrap(manager.selectedProject)
        let target = project.panelContext.identity
        await project.fileTree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        guard case .file(let file)? = project.selectedTab?.content else {
            return XCTFail("A real open descendant editor is required")
        }
        try await file.waitForText()
        file.text = "unsaved draft"
        file.refreshDirtyState()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        manager.performFileTreeCommand(
            .copy([sourceDirectory.path], cut: true),
            in: project, target: target, pasteboard: pasteboard
        )
        manager.performFileTreeCommand(
            .paste(into: destination.path),
            in: project, target: target, pasteboard: pasteboard
        )
        try FileManager.default.removeItem(at: sourceDirectory)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: child)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(try Data(contentsOf: child), Data("original".utf8),
                       "A stale move must not save the dirty draft over a substituted file")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("source").path
        ), "A directory created after the cut must not be moved")
        XCTAssertTrue(file.isDirty)
    }

    func testQueuedExplicitMoveRejectsAReplacedSourceEntity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("old bytes".utf8).write(to: source)

        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let target = project.panelContext.identity
        await project.fileTree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        XCTAssertTrue(FileTreeClipboard.writeLocalFiles([source.path], to: pasteboard))

        manager.performFileTreeCommand(
            .paste(into: destination.path, move: true),
            in: project, target: target, pasteboard: pasteboard
        )
        // The queued Task has not reached the backend: replace the original inode.
        try FileManager.default.removeItem(at: source)
        try Data("different entity".utf8).write(to: source)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(try Data(contentsOf: source), Data("different entity".utf8),
                       "The command must not delete a file created after the user requested the move")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("source.txt").path
        ))
    }

    func testClipboardChangeCancelsQueuedImplicitCutBeforeAnyDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.txt")
        try Data("keep this file".utf8).write(to: source)
        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let target = project.panelContext.identity
        await project.fileTree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        manager.performFileTreeCommand(
            .copy([source.path], cut: true), in: project, target: target, pasteboard: pasteboard
        )
        XCTAssertTrue(FileTreeClipboard.canReadFiles(from: pasteboard))
        manager.performFileTreeCommand(
            .paste(into: destination.path), in: project, target: target, pasteboard: pasteboard
        )
        // Change the pasteboard before the queued operation enters the backend.
        pasteboard.declareTypes([.string], owner: nil)
        XCTAssertTrue(pasteboard.setString("new clipboard content", forType: .string))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try Data(contentsOf: source), Data("keep this file".utf8))
        XCTAssertNil(LocalFileIdentity.read(destination.appendingPathComponent("original.txt").path))
        XCTAssertEqual(pasteboard.string(forType: .string), "new clipboard content")
    }

    func testClipboardFromAnotherAppIsNotOverwrittenAfterPendingMove() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let from = root.appendingPathComponent("source")
        let into = root.appendingPathComponent("destination")
        for folder in [from, into] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let file = from.appendingPathComponent("item.txt")
        try Data("safe bytes".utf8).write(to: file)
        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([into])
        let project = try XCTUnwrap(manager.selectedProject)
        let target = project.panelContext.identity
        await project.fileTree.sync(root: into.path, backend: LocalWorkspaceBackend.shared)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        XCTAssertTrue(FileTreeClipboard.writeLocalFiles([file.path], to: pasteboard))
        manager.performFileTreeCommand(
            .paste(into: into.path, move: true),
            in: project, target: target, pasteboard: pasteboard
        )
        pasteboard.declareTypes([.string], owner: nil)
        XCTAssertTrue(pasteboard.setString("new clipboard owner", forType: .string))
        try await wait { LocalFileIdentity.read(file.path) == nil }
        XCTAssertEqual(try Data(contentsOf: into.appendingPathComponent("item.txt")),
                       Data("safe bytes".utf8))
        XCTAssertEqual(pasteboard.string(forType: .string), "new clipboard owner")
        XCTAssertFalse(FileTreeClipboard.canReadFiles(from: pasteboard))
    }

    func testNativeFileDetectionUsesTypesOnlyAcrossMixedPasteboardItems() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("visible file 🧪.txt")
        try Data("content".utf8).write(to: source)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        let text = NSPasteboardItem()
        text.setString("file:///tmp/not-a-real-file-item", forType: .string)
        let file = NSPasteboardItem()
        file.setString(source.absoluteString, forType: .fileURL)
        XCTAssertTrue(pasteboard.writeObjects([text, file]))
        XCTAssertTrue(FileTreeClipboard.canReadFiles(from: pasteboard),
                      "File types may coexist with unrelated text items")
        XCTAssertEqual(FileTreeClipboard.localURLs(from: pasteboard).map(\.path), [source.path])
        XCTAssertNil(FileTreeClipboard.read(from: pasteboard))
    }

    func testPlainTextAndWebsiteURLsDoNotBecomeLocalFileClipboardSources() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.declareTypes([.string], owner: nil)
        XCTAssertTrue(pasteboard.setString("file:///tmp/untrusted.txt", forType: .string))
        XCTAssertFalse(FileTreeClipboard.canReadFiles(from: pasteboard))
        XCTAssertTrue(FileTreeClipboard.localURLs(from: pasteboard).isEmpty)

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("https://example.org/file.txt", forType: .URL)
        XCTAssertTrue(pasteboard.writeObjects([item]))
        XCTAssertFalse(FileTreeClipboard.canReadFiles(from: pasteboard))
        XCTAssertTrue(FileTreeClipboard.localURLs(from: pasteboard).isEmpty)

        pasteboard.clearContents()
        let remoteHostItem = NSPasteboardItem()
        remoteHostItem.setString("file://external.example.invalid/tmp/untrusted.txt", forType: .fileURL)
        XCTAssertTrue(pasteboard.writeObjects([remoteHostItem]))
        XCTAssertTrue(FileTreeClipboard.canReadFiles(from: pasteboard),
                      "The menu may inspect types without reading file contents")
        XCTAssertTrue(FileTreeClipboard.localURLs(from: pasteboard).isEmpty,
                      "Only localhost file URLs can become disk sources")

        pasteboard.clearContents()
        let malformedFile = NSPasteboardItem()
        malformedFile.setString("not a valid file URL", forType: .fileURL)
        XCTAssertTrue(pasteboard.writeObjects([malformedFile]))
        XCTAssertTrue(FileTreeClipboard.localURLs(from: pasteboard).isEmpty)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let target = project.panelContext.identity
        await project.fileTree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        XCTAssertTrue(manager.canPasteFileTree(in: project, target: target, pasteboard: pasteboard),
                      "The menu only checks a file type; the actual paste rejects malformed URLs")
        pasteboard.declareTypes([.string], owner: nil)
        XCTAssertTrue(pasteboard.setString("purely textual path", forType: .string))
        XCTAssertFalse(manager.canPasteFileTree(in: project, target: target, pasteboard: pasteboard))
    }

    func testFilesMultiSelectionCommandTargetsReachClipboardAndDiskWhenFocusMovesOutside() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let copied = root.appendingPathComponent("copied")
        let moved = root.appendingPathComponent("moved")
        for directory in [copied, moved] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("alpha.txt")
        let focused = root.appendingPathComponent("beta.txt")
        let last = root.appendingPathComponent("gamma.txt")
        let firstBytes = Data([0, 255, 10, 13, 42])
        let lastBytes = Data("中文内容\n".utf8)
        try firstBytes.write(to: first)
        try Data("focus only".utf8).write(to: focused)
        try lastBytes.write(to: last)

        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let target = project.panelContext.identity
        let tree = project.fileTree
        await tree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        let firstRow = try XCTUnwrap(tree.items.first { $0.path == first.path })
        let lastRow = try XCTUnwrap(tree.items.first { $0.path == last.path })
        let focusRow = try XCTUnwrap(tree.items.first { $0.path == focused.path })
        tree.select(firstRow)
        tree.select(lastRow, toggling: true)
        tree.focus(focusRow)
        XCTAssertEqual(tree.selectedPaths, [first.path, last.path])
        XCTAssertEqual(tree.selectedPath, focused.path)
        let paths = tree.selectedOperationPaths
        XCTAssertEqual(paths, [first.path, last.path])

        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        manager.performFileTreeCommand(.copy(paths, cut: false),
                                       in: project, target: target, pasteboard: pasteboard)
        XCTAssertEqual(FileTreeClipboard.read(from: pasteboard)?.paths, paths)
        manager.performFileTreeCommand(.paste(into: copied.path),
                                       in: project, target: target, pasteboard: pasteboard)
        try await wait {
            FileManager.default.fileExists(atPath: copied.appendingPathComponent("alpha.txt").path)
                && FileManager.default.fileExists(atPath: copied.appendingPathComponent("gamma.txt").path)
        }
        XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent("alpha.txt")), firstBytes)
        XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent("gamma.txt")), lastBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.appendingPathComponent("beta.txt").path))
        XCTAssertEqual(try Data(contentsOf: focused), Data("focus only".utf8))

        manager.performFileTreeCommand(.copy(paths, cut: true),
                                       in: project, target: target, pasteboard: pasteboard)
        manager.performFileTreeCommand(.paste(into: moved.path),
                                       in: project, target: target, pasteboard: pasteboard)
        try await wait {
            FileManager.default.fileExists(atPath: moved.appendingPathComponent("alpha.txt").path)
                && FileManager.default.fileExists(atPath: moved.appendingPathComponent("gamma.txt").path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: last.path))
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("alpha.txt")), firstBytes)
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("gamma.txt")), lastBytes)
        XCTAssertEqual(try Data(contentsOf: focused), Data("focus only".utf8))
        try await wait { FileTreeClipboard.read(from: pasteboard) == nil }
        XCTAssertEqual(pasteboard.string(forType: .string), paths.joined(separator: "\n"))
    }

    func testCutPartialSuccessRetainsOnlyUnmovedPathsForRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("into")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a.txt")
        let second = root.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: first)
        try Data("b".utf8).write(to: second)
        try Data("occupied".utf8).write(to: destination.appendingPathComponent("b.txt"))
        let owner = workspaceApplication.makeWindow()
        defer { owner.windowClosed() }
        owner.addLocalFolders([root])
        guard let project = owner.selectedProject
        else { return XCTFail("Expected local project") }
        let identity = project.panelContext.identity
        await project.fileTree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        owner.performFileTreeCommand(.copy([first.path, second.path], cut: true),
                                     in: project, target: identity, pasteboard: pasteboard)
        owner.performFileTreeCommand(.paste(into: destination.path),
                                     in: project, target: identity, pasteboard: pasteboard)
        try await wait {
            FileManager.default.fileExists(atPath: destination.appendingPathComponent("a.txt").path)
        }
        try await wait {
            FileTreeClipboard.read(from: pasteboard)?.paths == [second.path]
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(try Data(contentsOf: second), Data("b".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("b.txt")),
                       Data("occupied".utf8))
        XCTAssertEqual(FileTreeClipboard.localURLs(from: pasteboard).map(\.path), [second.path])
        XCTAssertTrue(workspaceApplication.trustedFileClipboard(
            try XCTUnwrap(FileTreeClipboard.read(from: pasteboard)), pasteboard: pasteboard
        ))
        try FileManager.default.removeItem(at: destination.appendingPathComponent("b.txt"))
        owner.performFileTreeCommand(
            .paste(into: destination.path), in: project, target: identity, pasteboard: pasteboard
        )
        try await wait { !FileManager.default.fileExists(atPath: second.path) }
        try await wait { FileTreeClipboard.read(from: pasteboard) == nil }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("b.txt")),
                       Data("b".utf8))
    }

    func testFileTreeClipboardRecordRoundTripsUnicodeWithoutGlobalPasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        let record = FileTreeClipboard.Record(
            token: UUID(), project: UUID(), identity: "ssh:remote",
            root: "/d/中文 工程", connectionRevision: 7,
            paths: ["/d/中文 工程/a\nb.swift", "/d/中文 工程/📄.txt"], cut: true
        )
        XCTAssertTrue(FileTreeClipboard.write(record, to: pasteboard))
        XCTAssertEqual(FileTreeClipboard.read(from: pasteboard), record)
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("not a file transfer", forType: .string)
        XCTAssertNil(FileTreeClipboard.read(from: pasteboard))
    }

    func testLocalFileClipboardWritesNativeFileItemsAndRemoteKeepsPrivateOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("中文 with spaces\n.txt")
        let directory = root.appendingPathComponent("empty folder")
        let link = root.appendingPathComponent("dangling")
        try Data([0, 1, 255]).write(to: file)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing")
        let paths = [file.path, directory.path, link.path]
        let record = FileTreeClipboard.Record(
            token: UUID(), project: UUID(), identity: "local", root: root.path,
            connectionRevision: nil, paths: paths, cut: false
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        XCTAssertTrue(FileTreeClipboard.write(record, local: true, to: pasteboard))
        XCTAssertEqual(pasteboard.pasteboardItems?.count, paths.count)
        XCTAssertEqual(FileTreeClipboard.read(from: pasteboard), record)
        XCTAssertEqual(pasteboard.string(forType: .string), paths.joined(separator: "\n"))
        XCTAssertTrue(FileTreeClipboard.canReadFiles(from: pasteboard))
        XCTAssertEqual(FileTreeClipboard.localURLs(from: pasteboard).map(\.path), paths)
        XCTAssertTrue(pasteboard.pasteboardItems?.allSatisfy {
            $0.types.contains(.fileURL)
        } == true)

        let remote = FileTreeClipboard.Record(
            token: UUID(), project: UUID(), identity: "ssh:remote", root: "/home",
            connectionRevision: 7, paths: ["/home/secrets.txt"], cut: true
        )
        XCTAssertTrue(FileTreeClipboard.write(remote, local: false, to: pasteboard))
        XCTAssertFalse(FileTreeClipboard.canReadFiles(from: pasteboard))
        XCTAssertEqual(FileTreeClipboard.localURLs(from: pasteboard), [])
        XCTAssertEqual(FileTreeClipboard.read(from: pasteboard), remote)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
    }

    func testClipboardCutTrustRequiresLiveProcessVersionSourceIdentityAndProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("before".utf8).write(to: source)
        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let target = project.panelContext.identity
        await project.fileTree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))

        manager.performFileTreeCommand(
            .copy([source.path], cut: true), in: project, target: target, pasteboard: pasteboard
        )
        let record = try XCTUnwrap(FileTreeClipboard.read(from: pasteboard))
        XCTAssertTrue(workspaceApplication.trustedFileClipboard(record, pasteboard: pasteboard))
        XCTAssertTrue(manager.canPasteFileTree(in: project, target: target, pasteboard: pasteboard))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        XCTAssertTrue(FileTreeClipboard.write(record, local: true, to: pasteboard))
        XCTAssertFalse(workspaceApplication.trustedFileClipboard(record, pasteboard: pasteboard),
                       "A copied private record and UUID do not authorize a move")
        XCTAssertTrue(FileTreeClipboard.canReadFiles(from: pasteboard))

        manager.performFileTreeCommand(
            .copy([source.path], cut: true), in: project, target: target, pasteboard: pasteboard
        )
        let current = try XCTUnwrap(FileTreeClipboard.read(from: pasteboard))
        try Data("modified after cut".utf8).write(to: source)
        XCTAssertFalse(workspaceApplication.trustedFileClipboard(current, pasteboard: pasteboard))
    }

    func testRenamingViaProjectRootSymlinkUpdatesCanonicalPathInAnotherWindow() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let actual = base.appendingPathComponent("actual")
        let alias = base.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        defer { try? FileManager.default.removeItem(at: base) }
        let actualOld = actual.appendingPathComponent("old.txt")
        let actualNew = actual.appendingPathComponent("renamed.txt")
        let logicalOld = alias.appendingPathComponent("old.txt")
        let logicalNew = alias.appendingPathComponent("renamed.txt")
        try Data("original".utf8).write(to: actualOld)
        let first = workspaceApplication.makeWindow()
        let second = workspaceApplication.makeWindow()
        defer { first.windowClosed(); second.windowClosed() }
        first.addLocalFolders([alias])
        second.addLocalFolders([actual])
        first.openFile(logicalOld.path)
        second.openFile(actualOld.path)
        guard let project = first.selectedProject,
              case .file(let firstFile)? = project.selectedTab?.content,
              case .file(let secondFile)? = second.selectedProject?.selectedTab?.content else {
            return XCTFail("Both windows must open the physical file from distinct paths")
        }
        let target = project.panelContext.identity
        try await firstFile.waitForText()
        try await secondFile.waitForText()
        firstFile.text = "changed"; firstFile.refreshDirtyState()
        await project.fileTree.sync(root: alias.path, backend: LocalWorkspaceBackend.shared)
        let row = try XCTUnwrap(project.fileTree.items.first { $0.path == logicalOld.path })
        let changed = await first.renameFile(row, to: "renamed.txt", in: project, target: target)
        XCTAssertEqual(changed, logicalNew.path)
        XCTAssertEqual(firstFile.path, logicalNew.path)
        XCTAssertEqual(secondFile.path, actualNew.path,
                       "The canonical path must not become a stale new file on the next save")
        XCTAssertFalse(FileManager.default.fileExists(atPath: actualOld.path))
        XCTAssertEqual(try Data(contentsOf: actualNew), Data("changed".utf8))
    }


    func testInternalFileDragCopiesAndMovesSelectedFilesOnlyWithinSourceWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        let owner = workspaceApplication.makeWindow()
        let other = workspaceApplication.makeWindow()
        defer { owner.windowClosed(); other.windowClosed() }
        owner.addLocalFolders([root])
        other.addLocalFolders([root])
        guard let project = owner.selectedProject,
              let otherProject = other.selectedProject else {
            return XCTFail("Both windows need a Files tree")
        }
        let identity = project.panelContext.identity
        let otherIdentity = otherProject.panelContext.identity
        await project.fileTree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        await otherProject.fileTree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        let firstRow = try XCTUnwrap(project.fileTree.items.first { $0.path == first.path })
        let secondRow = try XCTUnwrap(project.fileTree.items.first { $0.path == second.path })
        project.fileTree.select(firstRow)
        project.fileTree.select(secondRow, toggling: true)
        let record = try XCTUnwrap(owner.beginFileTreeDrag(for: firstRow, in: project, target: identity))
        let items = FileTreeNativeDragView.dragItems(record: record, local: true)
        XCTAssertEqual(items.count, 2, "Finder needs one real pasteboard item per selected file")
        XCTAssertEqual(items.compactMap { ($0.item as? NSURL)?.path },
                       [first.path, second.path])
        let remoteItems = FileTreeNativeDragView.dragItems(record: record, local: false)
        XCTAssertEqual(remoteItems.count, 1,
                       "SSH drags need one private marker, not a pasteboard item per selected file")
        let marker = try XCTUnwrap(remoteItems.first?.item as? NSPasteboardItem)
        XCTAssertNil(marker.string(forType: .fileURL))
        XCTAssertNotNil(marker.string(forType: NSPasteboard.PasteboardType(FileTreeDrag.type)))
        XCTAssertEqual(record.source.paths, [first.path, second.path],
                       "The in-process record retains all remote selection paths")
        XCTAssertFalse(other.receiveFileTreeDrop(
            record, into: destination.path, copy: false,
            in: otherProject, target: otherIdentity
        ), "The same local folder in another window must not accept the private drag")
        XCTAssertTrue(owner.receiveFileTreeDrop(
            record, into: destination.path, copy: true,
            in: project, target: identity
        ))
        try await wait {
            FileManager.default.fileExists(atPath: destination.appendingPathComponent("first.txt").path)
                && FileManager.default.fileExists(atPath: destination.appendingPathComponent("second.txt").path)
        }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("first.txt")),
                       Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("second.txt")),
                       Data("two".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertFalse(project.fileTree.hasActiveDrag)

        let afterCopy = try XCTUnwrap(project.fileTree.items.first { $0.path == first.path })
        let secondDestination = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: secondDestination, withIntermediateDirectories: true)
        let secondRecord = try XCTUnwrap(owner.beginFileTreeDrag(
            for: afterCopy, in: project, target: identity
        ))
        XCTAssertTrue(owner.receiveFileTreeDrop(
            secondRecord, into: secondDestination.path, copy: false,
            in: project, target: identity
        ))
        try await wait {
            FileManager.default.fileExists(atPath: secondDestination.appendingPathComponent("first.txt").path)
                && FileManager.default.fileExists(atPath: secondDestination.appendingPathComponent("second.txt").path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(try Data(contentsOf: secondDestination.appendingPathComponent("first.txt")),
                       Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: secondDestination.appendingPathComponent("second.txt")),
                       Data("two".utf8))
        XCTAssertFalse(project.fileTree.hasActiveDrag)
    }

    func testInternalDragRejectsSelectionChangesAndExternalFileURLProviders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        let owner = workspaceApplication.makeWindow()
        defer { owner.windowClosed() }
        owner.addLocalFolders([root])
        guard let project = owner.selectedProject else {
            return XCTFail("Missing Files project")
        }
        let identity = project.panelContext.identity
        await project.fileTree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        let firstRow = try XCTUnwrap(project.fileTree.items.first { $0.path == first.path })
        let secondRow = try XCTUnwrap(project.fileTree.items.first { $0.path == second.path })
        project.fileTree.select(firstRow)
        let previous = try XCTUnwrap(owner.beginFileTreeDrag(for: firstRow, in: project, target: identity))
        project.fileTree.select(secondRow)
        XCTAssertFalse(owner.receiveFileTreeDrop(
            previous, into: destination.path, copy: false,
            in: project, target: identity
        ), "Changed selection invalidates a previous drag")
        let forged = FileTreeDrag.Record(
            source: previous.source, window: previous.window, nonce: UUID()
        )
        XCTAssertFalse(owner.receiveFileTreeDrop(
            forged, into: destination.path, copy: false,
            in: project, target: identity
        ), "An unregistered or external drag cannot become an internal move")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("first.txt").path
        ))
    }

    func testMovingFolderAcrossSymlinkRootsUpdatesEveryWindowPath() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let physical = base.appendingPathComponent("physical")
        let firstAlias = base.appendingPathComponent("first-alias")
        let secondAlias = base.appendingPathComponent("second-alias")
        try FileManager.default.createDirectory(
            at: physical.appendingPathComponent("source"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: physical.appendingPathComponent("target"), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: firstAlias, withDestinationURL: physical)
        try FileManager.default.createSymbolicLink(at: secondAlias, withDestinationURL: physical)
        defer { try? FileManager.default.removeItem(at: base) }

        let oldName = "source/a.swift"
        let newName = "target/source/a.swift"
        try Data("before".utf8).write(to: physical.appendingPathComponent(oldName))
        let first = workspaceApplication.makeWindow()
        let second = workspaceApplication.makeWindow()
        let third = workspaceApplication.makeWindow()
        defer { first.windowClosed(); second.windowClosed(); third.windowClosed() }
        first.addLocalFolders([firstAlias])
        second.addLocalFolders([secondAlias])
        third.addLocalFolders([physical])
        first.openFile(firstAlias.appendingPathComponent(oldName).path)
        second.openFile(secondAlias.appendingPathComponent(oldName).path)
        third.openFile(physical.appendingPathComponent(oldName).path)
        guard let project = first.selectedProject,
              case .file(let a)? = project.selectedTab?.content,
              case .file(let b)? = second.selectedProject?.selectedTab?.content,
              case .file(let c)? = third.selectedProject?.selectedTab?.content else {
            return XCTFail("All three windows must open the same physical file")
        }
        let identity = project.panelContext.identity
        try await a.waitForText()
        try await b.waitForText()
        try await c.waitForText()
        a.text = "after"; a.refreshDirtyState()
        await project.fileTree.sync(root: firstAlias.path, backend: LocalWorkspaceBackend.shared)
        let result = await first.performFileOperation(
            .move, paths: [firstAlias.appendingPathComponent("source").path],
            into: firstAlias.appendingPathComponent("target").path,
            in: project, target: identity
        )
        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(result.succeeded.count, 1)
        XCTAssertEqual(a.path, firstAlias.appendingPathComponent(newName).path)
        XCTAssertEqual(b.path, physical.appendingPathComponent(newName).path)
        XCTAssertEqual(c.path, physical.appendingPathComponent(newName).path)
        XCTAssertEqual(try Data(contentsOf: physical.appendingPathComponent(newName)),
                       Data("after".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: physical.appendingPathComponent(oldName).path
        ))
    }

    func testDeletionThroughSymlinkInvalidatesOtherAliasAndCanonicalTabs() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let physical = base.appendingPathComponent("physical")
        let firstAlias = base.appendingPathComponent("first-alias")
        let secondAlias = base.appendingPathComponent("second-alias")
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: firstAlias, withDestinationURL: physical)
        try FileManager.default.createSymbolicLink(at: secondAlias, withDestinationURL: physical)
        defer { try? FileManager.default.removeItem(at: base) }

        let fileName = "deleted.txt"
        let physicalFile = physical.appendingPathComponent(fileName)
        try Data("original".utf8).write(to: physicalFile)
        let first = workspaceApplication.makeWindow()
        let second = workspaceApplication.makeWindow()
        let third = workspaceApplication.makeWindow()
        defer { first.windowClosed(); second.windowClosed(); third.windowClosed() }
        first.addLocalFolders([firstAlias])
        second.addLocalFolders([secondAlias])
        third.addLocalFolders([physical])
        first.openFile(firstAlias.appendingPathComponent(fileName).path)
        second.openFile(secondAlias.appendingPathComponent(fileName).path)
        third.openFile(physicalFile.path)
        guard case .file(let a)? = first.selectedProject?.selectedTab?.content,
              case .file(let b)? = second.selectedProject?.selectedTab?.content,
              case .file(let c)? = third.selectedProject?.selectedTab?.content else {
            return XCTFail("All three files must be open")
        }
        try await a.waitForText()
        try await b.waitForText()
        try await c.waitForText()
        b.text = "unsaved"; b.refreshDirtyState()
        try FileManager.default.removeItem(at: physicalFile)
        workspaceApplication.filesDeleted(
            paths: [firstAlias.appendingPathComponent(fileName).path], workspace: nil
        )
        XCTAssertFalse(first.selectedProject?.tabs.contains { $0.content.id == a.id } ?? true)
        XCTAssertFalse(third.selectedProject?.tabs.contains { $0.content.id == c.id } ?? true)
        XCTAssertTrue(second.selectedProject?.tabs.contains { $0.content.id == b.id } == true,
                      "A deleted file with unsaved changes must remain recoverable")
        XCTAssertTrue(b.isDirty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: physicalFile.path))
    }

    func testMovingFolderThroughManagerKeepsDirtyTabsAndSiblingWindowPaths() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("project")
        let folder = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let oldPath = folder.appendingPathComponent("a.swift")
        let newPath = destination.appendingPathComponent("source/a.swift")
        try "before".write(to: oldPath, atomically: true, encoding: .utf8)
        let first = workspaceApplication.makeWindow()
        let second = workspaceApplication.makeWindow()
        defer { first.windowClosed(); second.windowClosed() }
        first.addLocalFolders([root])
        second.addLocalFolders([root])
        first.openFile(oldPath.path)
        second.openFile(oldPath.path)
        guard let project = first.selectedProject,
              case .file(let file)? = first.selectedProject?.selectedTab?.content,
              case .file(let other)? = second.selectedProject?.selectedTab?.content else {
            return XCTFail("The two projects and their file targets must exist")
        }
        let identity = project.panelContext.identity
        try await file.waitForText()
        try await other.waitForText()
        file.text = "after"; file.refreshDirtyState()
        await project.fileTree.sync(
            root: root.path, backend: LocalWorkspaceBackend.shared
        )
        let result = await first.performFileOperation(
            .move, paths: [folder.path], into: destination.path,
            in: project, target: identity
        )
        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(result.succeeded.count, 1)
        XCTAssertEqual(file.path, newPath.path)
        XCTAssertEqual(other.path, newPath.path)
        XCTAssertEqual(try String(contentsOf: newPath, encoding: .utf8), "after")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPath.path))
        XCTAssertFalse(file.isDirty)
    }

    func testFileRenameAcrossTwoWindowsSavesFirstAndUpdatesOnlyMatchingMachine() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        let target = root.appendingPathComponent("moved.txt")
        try "old".write(to: source, atomically: true, encoding: .utf8)
        let first = workspaceApplication.makeWindow()
        let second = workspaceApplication.makeWindow()
        defer { first.windowClosed(); second.windowClosed() }
        first.addLocalFolders([root])
        second.addLocalFolders([root])
        first.openFile(source.path)
        second.openFile(source.path)
        guard case .file(let a)? = first.selectedProject?.selectedTab?.content,
              case .file(let b)? = second.selectedProject?.selectedTab?.content,
              let project = second.selectedProject else {
            return XCTFail("Both windows must own the file")
        }
        try await a.waitForText()
        try await b.waitForText()
        let remote = FileTab(
            path: source.path,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: "ssh:other"
        )
        project.append(PaneTab(content: .file(remote)))
        a.text = "new content"; a.refreshDirtyState()
        try await workspaceApplication.withProtectedFiles(paths: [source.path], workspace: nil) {
            try await LocalWorkspaceBackend.shared.rename(from: source.path, to: target.path)
            workspaceApplication.fileRenamed(from: source.path, to: target.path, workspace: nil)
        }
        XCTAssertEqual(a.path, target.path)
        XCTAssertEqual(b.path, target.path)
        XCTAssertEqual(remote.path, source.path, "A tab on another machine cannot follow a Mac rename")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new content")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(a.isDirty)
        XCTAssertTrue(first.selectedProject?.tabs.contains { $0.content.id == a.id } == true)
        XCTAssertTrue(second.selectedProject?.tabs.contains { $0.content.id == b.id } == true)
    }

    func testDeletionAfterFlushingClosesOnlyAffectedOpenTabs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("delete.txt")
        try "old".write(to: source, atomically: true, encoding: .utf8)
        let first = workspaceApplication.makeWindow()
        let second = workspaceApplication.makeWindow()
        defer { first.windowClosed(); second.windowClosed() }
        first.addLocalFolders([root])
        second.addLocalFolders([root])
        first.openFile(source.path)
        second.openFile(source.path)
        guard case .file(let a)? = first.selectedProject?.selectedTab?.content,
              case .file(let b)? = second.selectedProject?.selectedTab?.content else {
            return XCTFail("Both windows must own the original path")
        }
        try await a.waitForText()
        try await b.waitForText()
        a.text = "saved before delete"; a.refreshDirtyState()
        try await workspaceApplication.withProtectedFiles(paths: [source.path], workspace: nil) {
            XCTAssertFalse(a.isDirty)
            XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "saved before delete")
            try FileManager.default.removeItem(at: source)
            workspaceApplication.filesDeleted(paths: [source.path], workspace: nil)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(first.projects.flatMap(\.tabs).contains { $0.content.id == a.id })
        XCTAssertFalse(second.projects.flatMap(\.tabs).contains { $0.content.id == b.id })
    }

    func testTwoDirtyWindowsCannotOverwriteEachOtherDuringRename() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("conflict.txt")
        try "original".write(to: source, atomically: true, encoding: .utf8)
        let first = workspaceApplication.makeWindow()
        let second = workspaceApplication.makeWindow()
        defer { first.windowClosed(); second.windowClosed() }
        first.addLocalFolders([root])
        second.addLocalFolders([root])
        first.openFile(source.path)
        second.openFile(source.path)
        guard case .file(let a)? = first.selectedProject?.selectedTab?.content,
              case .file(let b)? = second.selectedProject?.selectedTab?.content else {
            return XCTFail("Both editors must exist")
        }
        try await a.waitForText()
        try await b.waitForText()
        a.text = "draft A"; a.refreshDirtyState()
        b.text = "draft B"; b.refreshDirtyState()
        do {
            try await workspaceApplication.withProtectedFiles(paths: [source.path], workspace: nil) {
                XCTFail("Concurrent unsaved buffers for the same physical file must block mutation")
            }
            XCTFail("Mutation should be refused when both buffers would be overwritten")
        } catch {}
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")
        XCTAssertEqual(a.text, "draft A")
        XCTAssertEqual(b.text, "draft B")
        XCTAssertTrue(a.isDirty && b.isDirty)
    }

    func testWindowFocusLossSavesAllDirtyBuffersNotOnlyTheMostRecentTab() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        var files: [FileTab] = []
        for name in ["甲.swift", "乙.swift"] {
            let url = root.appendingPathComponent(name)
            try "original".write(to: url, atomically: true, encoding: .utf8)
            manager.openFile(url.path)
            guard case .file(let file)? = project.selectedTab?.content else { return XCTFail("File required") }
            try await file.waitForText()
            files.append(file)
        }
        for file in files {
            file.text = "changed \(file.tabTitle) 😀"
            file.refreshDirtyState()
        }
        XCTAssertTrue(files.allSatisfy(\.isDirty))
        project.dock.selectForContextMenu(.git)
        manager.windowResignedKey()
        XCTAssertNil(project.dock.contextTarget)
        try await wait { files.allSatisfy { !$0.isDirty } }
        for file in files {
            XCTAssertEqual(try String(contentsOfFile: file.path, encoding: .utf8), file.text)
        }
    }

    private func editor(in view: NSView) -> FocusReportingTextView? {
        if let editor = view as? FocusReportingTextView { return editor }
        return view.subviews.lazy.compactMap { self.editor(in: $0) }.first
    }

    private func wait(
        _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Window did not finish rendering", file: file, line: line)
                throw WorkspaceError.timedOut
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testNativeGridInputParticipatesInWorkspaceSaveAndMoveProtection() async throws {
        for move in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source.csv")
            let target = root.appendingPathComponent("target.csv")
            let original = "Name,Value\r\nItem,old\n"
            let expected = "Name,Value\r\nItem,新值🧪\n"
            try Data(original.utf8).write(to: source)
            let manager = workspaceApplication.makeWindow()
            defer { manager.windowClosed() }
            manager.addLocalFolders([root])
            manager.openFile(source.path)
            guard case .file(let file)? = manager.selectedProject?.focusedContent else {
                return XCTFail("Expected focused CSV file")
            }
            try await file.waitForText()
            let controls = file.delimitedTable
            let grid = DelimitedGrid()
            controls.separator = .comma
            grid.file = file
            let window = NSWindow(contentRect: CGRect(x: -900, y: -900, width: 500, height: 260),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = grid
            window.orderBack(nil)
            defer { grid.detach(); window.close() }
            let loaded = try await file.delimitedSnapshot(using: .comma)
            let snapshot = try XCTUnwrap(loaded)
            let presentation = try await DelimitedTablePresentation.evaluate(
                source: snapshot.source, index: snapshot.index, configuration: controls.configuration)
            grid.install(snapshot, presentation: presentation)
            grid.layoutSubtreeIfNeeded()
            grid.table.onEdit(.init(row: 0, column: 1))
            let field = try XCTUnwrap(grid.table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTextField)
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.insertText("新值🧪", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            XCTAssertEqual(file.text, original)
            XCTAssertTrue(manager.canSaveSelectedFile, "Cmd-S must be enabled while the native field owns input")
            XCTAssertEqual(try Data(contentsOf: source), Data(original.utf8))
            if move {
                try await workspaceApplication.withProtectedFiles(paths: [source.path], workspace: nil) {
                    XCTAssertEqual(try Data(contentsOf: source), Data(expected.utf8))
                    try await LocalWorkspaceBackend.shared.rename(from: source.path, to: target.path)
                    workspaceApplication.fileRenamed(from: source.path, to: target.path, workspace: nil)
                }
                XCTAssertEqual(file.path, target.path)
                XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            } else {
                manager.saveSelectedFile()
            }
            let destination = move ? target : source
            try await wait { (try? Data(contentsOf: destination)) == Data(expected.utf8) && !file.isDirty && !file.hasPendingDelimitedEdit }
            XCTAssertFalse(manager.canSaveSelectedFile)
            XCTAssertTrue(file.documentUndoManager.canUndo)
            XCTAssertEqual(try Data(contentsOf: destination), Data(expected.utf8))
        }
    }

    func testTwoMountedWorkspaceManagersSaveTheirOwnNativeAXBuffers() async throws {
        let previousSnapshots = SessionStore.load()
        let previousHistories = TerminalHistoryStore.load()
        defer {
            SessionStore.save(previousSnapshots)
            TerminalHistoryStore.save(previousHistories)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let aFolder = root.appendingPathComponent("A")
        let bFolder = root.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: aFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let aURL = aFolder.appendingPathComponent("same-name.swift")
        let bURL = bFolder.appendingPathComponent("same-name.swift")
        let originalA = "let origin = \"A\"\n"
        let originalB = "let origin = \"B\"\n"
        let changedA = "let origin = \"甲 中文 😀\"\n"
        let changedB = "let origin = \"乙 emoji 👋\"\n"
        try originalA.write(to: aURL, atomically: true, encoding: .utf8)
        try originalB.write(to: bURL, atomically: true, encoding: .utf8)

        let first = self.workspaceApplication.makeWindow()
        let second = self.workspaceApplication.makeWindow()
        defer { first.windowClosed(); second.windowClosed() }
        first.addLocalFolders([aFolder])
        second.addLocalFolders([bFolder])
        first.openFile(aURL.path)
        second.openFile(bURL.path)
        guard case .file(let aFile)? = first.selectedProject?.focusedContent,
              case .file(let bFile)? = second.selectedProject?.focusedContent else {
            XCTFail("Both windows must own independent focused file tabs")
            return
        }
        aFile.autoSaveSuspendedForClose = true
        bFile.autoSaveSuspendedForClose = true
        let aWindow = NSWindow(contentRect: NSRect(x: -900, y: -900, width: 780, height: 490),
                               styleMask: [.titled], backing: .buffered, defer: false)
        let bWindow = NSWindow(contentRect: NSRect(x: -900, y: -900, width: 780, height: 490),
                               styleMask: [.titled], backing: .buffered, defer: false)
        aWindow.isReleasedWhenClosed = false
        bWindow.isReleasedWhenClosed = false
        defer { aWindow.close(); bWindow.close() }
        let aHost = NSHostingView(rootView: FileViewerView(file: aFile))
        let bHost = NSHostingView(rootView: FileViewerView(file: bFile))
        aWindow.contentView = aHost
        bWindow.contentView = bHost
        first.attach(to: aWindow)
        second.attach(to: bWindow)
        aWindow.orderFront(nil)
        bWindow.makeKeyAndOrderFront(nil)
        try await wait {
            aHost.layoutSubtreeIfNeeded()
            bHost.layoutSubtreeIfNeeded()
            return self.editor(in: aHost)?.text == originalA
                && self.editor(in: bHost)?.text == originalB
                && first.attachedWindow === aWindow
                && second.attachedWindow === bWindow
        }
        let aEditor = try XCTUnwrap(editor(in: aHost))
        let bEditor = try XCTUnwrap(editor(in: bHost))
        aEditor.setAccessibilityValue(changedA)
        bEditor.setAccessibilityValue(changedB)
        XCTAssertTrue(aFile.isDirty)
        XCTAssertTrue(bFile.isDirty)
        XCTAssertEqual(try String(contentsOf: aURL, encoding: .utf8), originalA)
        XCTAssertEqual(try String(contentsOf: bURL, encoding: .utf8), originalB)

        first.saveSelectedFile()
        try await wait {
            (try? String(contentsOf: aURL, encoding: .utf8)) == changedA && !aFile.isDirty
        }
        XCTAssertEqual(try String(contentsOf: bURL, encoding: .utf8), originalB,
                       "Saving workspace A must not write workspace B's focused buffer")
        XCTAssertTrue(bFile.isDirty)
        XCTAssertTrue(editor(in: aHost) === aEditor)
        XCTAssertTrue(editor(in: bHost) === bEditor)

        second.saveSelectedFile()
        try await wait {
            (try? String(contentsOf: bURL, encoding: .utf8)) == changedB && !bFile.isDirty
        }
        XCTAssertEqual(try String(contentsOf: aURL, encoding: .utf8), changedA)
        XCTAssertEqual(aEditor.text, changedA)
        XCTAssertEqual(bEditor.text, changedB)
    }

    func testClosingOneWorkspaceWindowKeepsOtherManagerEditorAndSnapshot() async throws {
        let previousSnapshots = SessionStore.load()
        let previousHistories = TerminalHistoryStore.load()
        defer {
            SessionStore.save(previousSnapshots)
            TerminalHistoryStore.save(previousHistories)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let aFolder = root.appendingPathComponent("A")
        let bFolder = root.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: aFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let aURL = aFolder.appendingPathComponent("a.txt")
        let bURL = bFolder.appendingPathComponent("b.txt")
        try "window A".write(to: aURL, atomically: true, encoding: .utf8)
        try "window B".write(to: bURL, atomically: true, encoding: .utf8)

        let first = self.workspaceApplication.makeWindow()
        let second = self.workspaceApplication.makeWindow()
        defer {
            first.windowClosed()
            second.windowClosed()
        }
        first.addLocalFolders([aFolder])
        second.addLocalFolders([bFolder])
        first.openFile(aURL.path)
        second.openFile(bURL.path)

        let firstWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 520),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let secondWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 520),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
        firstWindow.isReleasedWhenClosed = false
        secondWindow.isReleasedWhenClosed = false
        defer { firstWindow.close(); secondWindow.close() }
        guard case .file(let aFile)? = first.selectedProject?.focusedContent,
              case .file(let bFile)? = second.selectedProject?.focusedContent else {
            return XCTFail("Both owning file tabs must exist")
        }
        let firstHost = NSHostingView(rootView: FileViewerView(file: aFile))
        let secondHost = NSHostingView(rootView: FileViewerView(file: bFile))
        firstWindow.contentView = firstHost
        secondWindow.contentView = secondHost
        first.attach(to: firstWindow)
        second.attach(to: secondWindow)
        firstWindow.orderFront(nil)
        secondWindow.makeKeyAndOrderFront(nil)
        try await wait {
            firstHost.layoutSubtreeIfNeeded()
            secondHost.layoutSubtreeIfNeeded()
            return self.editor(in: firstHost)?.text == "window A"
                && self.editor(in: secondHost)?.text == "window B"
                && first.attachedWindow === firstWindow
                && second.attachedWindow === secondWindow
        }
        let bEditor = try XCTUnwrap(editor(in: secondHost))
        // Closing A has to remove only A from the window registry and snapshot;
        // it must not remove B or its native editor when B owns the key window.
        firstWindow.performClose(nil)
        XCTAssertFalse(firstWindow.isVisible, "A clean native window must close immediately")
        first.windowClosed()
        XCTAssertNil(first.attachedWindow)
        XCTAssertTrue(second.attachedWindow === secondWindow)
        XCTAssertTrue(editor(in: secondHost) === bEditor)
        XCTAssertEqual(bEditor.text, "window B")
        let savedProjects = SessionStore.load().flatMap(\.projects)
        XCTAssertTrue(savedProjects.contains { $0.customDirectory == bFolder.path })
        XCTAssertFalse(savedProjects.contains { $0.customDirectory == aFolder.path })
        XCTAssertEqual(try String(contentsOf: aURL, encoding: .utf8), "window A")
        XCTAssertEqual(try String(contentsOf: bURL, encoding: .utf8), "window B")
    }

    func testAlreadyRegisteredInitialSceneDoesNotRequestAnotherWindowBeforeNativeAttachment() throws {
        let application = WorkspaceApplication()
        let manager = application.makeWindow()
        defer { manager.windowClosed() }
        var extraWindows = 0
        application.openRestoredWindows { extraWindows += 1 }
        XCTAssertEqual(application.windowCount, 1)
        XCTAssertEqual(extraWindows, 0,
                       "A scene already registered before native attachment must not launch a duplicate window")
    }

    func testInitialWindowOpensOnlyAfterAppActivationAndRetainsPendingFolders() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let application = WorkspaceApplication()
        var extraWindows = 0
        application.openDirectories([folder.path])
        application.registerWindowOpener { extraWindows += 1 }
        XCTAssertEqual(extraWindows, 0,
                       "Commands may register the opener before AppKit finishes activating")
        application.registerWindowOpener { extraWindows += 1 }
        XCTAssertEqual(extraWindows, 0,
                       "The early Commands reevaluation must not open a premature scene")
        application.applicationBecameActive()
        XCTAssertEqual(extraWindows, 1, "Activation opens the isolated first scene exactly once")
        application.applicationBecameActive()
        application.registerWindowOpener { extraWindows += 1 }
        XCTAssertEqual(extraWindows, 1, "Repeated activation and menu rebuilding must not duplicate it")
        let manager = application.makeWindow()
        defer { manager.windowClosed() }
        XCTAssertEqual(manager.selectedProject?.name, folder.lastPathComponent)
        XCTAssertEqual(application.windowCount, 1)
    }

    func testActivationBeforeCommandsRegistrationStillOpensOnlyOneScene() throws {
        let application = WorkspaceApplication()
        application.applicationBecameActive()
        var requests = 0
        application.registerWindowOpener { requests += 1 }
        XCTAssertEqual(requests, 1,
                       "Late Commands registration must open the initial scene after activation")
        application.applicationBecameActive()
        application.registerWindowOpener { requests += 1 }
        XCTAssertEqual(requests, 1)
        let manager = application.makeWindow()
        defer { manager.windowClosed() }
        XCTAssertEqual(application.windowCount, 1)
    }

    func testExternalFolderAfterClosingLastWindowRequestsOneReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let next = root.appendingPathComponent("next")
        let extra = root.appendingPathComponent("extra")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let application = WorkspaceApplication()
        var requests = 0
        application.registerWindowOpener { requests += 1 }
        XCTAssertEqual(requests, 0)
        application.applicationBecameActive()
        XCTAssertEqual(requests, 1, "AppKit activation opens the isolated first window")
        let first = application.makeWindow()
        let firstWindow = NSWindow(contentRect: NSRect(x: -900, y: -900, width: 300, height: 200),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        firstWindow.isReleasedWhenClosed = false
        firstWindow.identifier = NSUserInterfaceItemIdentifier("fixture-first")
        defer { firstWindow.close() }
        first.attach(to: firstWindow)
        XCTAssertTrue(first.attachedWindow === firstWindow)
        first.windowClosed()
        XCTAssertEqual(application.windowCount, 0)

        // Another application owner can have a native main window. It must
        // never consume this application's replacement-window request.
        let foreignWindow = NSWindow(contentRect: NSRect(x: -900, y: -900, width: 300, height: 200),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        foreignWindow.isReleasedWhenClosed = false
        foreignWindow.identifier = NSUserInterfaceItemIdentifier("main-foreign-owner")
        defer { foreignWindow.close() }
        XCTAssertTrue(NSApp.windows.contains { $0 === foreignWindow })

        application.openDirectories([next.path])
        application.openDirectories([extra.path])
        XCTAssertEqual(requests, 2,
                       "An unrelated native main window cannot consume the one replacement request")
        let second = application.makeWindow()
        defer { second.windowClosed() }
        let secondWindow = NSWindow(contentRect: NSRect(x: -900, y: -900, width: 300, height: 200),
                                    styleMask: [.titled], backing: .buffered, defer: false)
        secondWindow.isReleasedWhenClosed = false
        secondWindow.identifier = NSUserInterfaceItemIdentifier("fixture-second")
        defer { secondWindow.close() }
        second.attach(to: secondWindow)
        XCTAssertEqual(application.windowCount, 1)
        XCTAssertTrue(second.projects.contains { $0.name == next.lastPathComponent })
        XCTAssertTrue(second.projects.contains { $0.name == extra.lastPathComponent })
    }

    func testSpeculativeSceneConstructionDoesNotRegisterOrConsumeRestoredWindows() throws {
        XCTAssertTrue(BaileyInstanceMode.isIsolated)
        let saved = SessionStore.load()
        let histories = TerminalHistoryStore.load()
        defer {
            SessionStore.save(saved)
            TerminalHistoryStore.save(histories)
        }

        func snapshot(named name: String) -> SessionSnapshot {
            let project = SessionSnapshot.ProjectSnapshot(
                customDirectory: "/fixture/" + name,
                sshHost: nil,
                pinnedFile: nil,
                tabs: [],
                selectedTabIndex: nil,
                groups: []
            )
            return SessionSnapshot(projects: [project], selectedProjectIndex: 0,
                                   layout: .group(DockGroup(items: [.files])))
        }
        SessionStore.save([snapshot(named: "one"), snapshot(named: "two")])
        let application = WorkspaceApplication(loadSavedState: true)
        let discarded = WorkspaceWindowModel(application: application)
        let redundant = WorkspaceWindowModel(application: application)
        XCTAssertEqual(application.windowCount, 0)
        XCTAssertTrue(discarded.projects.isEmpty)
        XCTAssertTrue(redundant.projects.isEmpty)

        let first = application.makeWindow()
        let second = application.makeWindow()
        defer {
            first.windowClosed()
            second.windowClosed()
        }
        XCTAssertEqual(application.windowCount, 2)
        XCTAssertEqual(first.selectedProject?.name, "one")
        XCTAssertEqual(second.selectedProject?.name, "two")
        application.register(first)
        application.register(second)
        XCTAssertEqual(application.windowCount, 2,
                       "Repeated SwiftUI appear or native attachment cannot claim another snapshot")
        XCTAssertEqual(first.selectedProject?.name, "one")
        XCTAssertEqual(second.selectedProject?.name, "two")
        XCTAssertTrue(SessionStore.load().count == 2)
        withExtendedLifetime([discarded, redundant]) {}
    }

    func testLocalWorktreeUseProtectsMacFileInsideAnSSHProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let checkout = root.appendingPathComponent("checkout", isDirectory: true)
        let sibling = root.appendingPathComponent("checkout-other", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = checkout.appendingPathComponent("unsaved.swift")
        try "original".write(to: file, atomically: true, encoding: .utf8)

        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        let remote = Project(customDirectory: "/remote/unrelated", sshHost: "invalid-worktree-protection-fixture", layout: manager.dockLayout)
        manager.projects.append(remote)
        manager.selectedProjectID = remote.id
        XCTAssertTrue(manager.openExternalLocalItems([file]).isEmpty)
        let tab = try XCTUnwrap(remote.selectedTab)
        guard case .file(let localFile) = tab.content else {
            return XCTFail("Mac file should open in an SSH project's editor tab")
        }
        XCTAssertNil(localFile.workspaceIdentity)
        XCTAssertEqual(remote.panelContext.scope, "ssh:invalid-worktree-protection-fixture")

        XCTAssertTrue(self.workspaceApplication.isWorktreeInUse(path: checkout.path, scope: "local"),
                      "A local editor inside an SSH project must block worktree removal")
        XCTAssertFalse(self.workspaceApplication.isWorktreeInUse(path: sibling.path, scope: "local"))
        XCTAssertFalse(self.workspaceApplication.isWorktreeInUse(path: checkout.path,
                                                                scope: "ssh:invalid-worktree-protection-fixture"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
    }

    func testTwoApplicationOwnersNeverShareWorkspaceRegistryOrWorktreeProtection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let aFolder = root.appendingPathComponent("first", isDirectory: true)
        let bFolder = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: aFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let otherApplication = WorkspaceApplication()
        let first = self.workspaceApplication.makeWindow()
        let second = otherApplication.makeWindow()
        defer {
            first.windowClosed()
            second.windowClosed()
        }
        first.addLocalFolders([aFolder])
        second.addLocalFolders([bFolder])
        XCTAssertEqual(self.workspaceApplication.windowCount, 1)
        XCTAssertEqual(otherApplication.windowCount, 1)
        XCTAssertTrue(self.workspaceApplication.isWorktreeInUse(path: aFolder.path, scope: "local"))
        XCTAssertFalse(self.workspaceApplication.isWorktreeInUse(path: bFolder.path, scope: "local"))
        XCTAssertTrue(otherApplication.isWorktreeInUse(path: bFolder.path, scope: "local"))
        XCTAssertFalse(otherApplication.isWorktreeInUse(path: aFolder.path, scope: "local"))
        XCTAssertFalse(otherApplication.containsWindow(first))
        XCTAssertFalse(self.workspaceApplication.containsWindow(second))
    }
}
