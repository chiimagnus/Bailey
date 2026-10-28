import AppKit
import SwiftUI
import XCTest
@testable import Bailey

/// Isolated workspace owners and minimal native file components in separate windows. The current key window is
/// not a valid substitute for the manager that owns a file or its save target.
@MainActor
final class WindowOwnershipIntegrationTests: XCTestCase {
    @MainActor private lazy var workspaceApplication = WorkspaceApplication()

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
        guard let project = manager.selectedProject,
              let target = project.panelContext?.identity else {
            return XCTFail("Expected a pinned Files project")
        }
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
        let otherTarget = try XCTUnwrap(otherProject.panelContext?.identity)
        XCTAssertFalse(
            anotherWindow.canPasteFileTree(in: otherProject, target: otherTarget, pasteboard: pasteboard),
            "A system Paste menu must not offer files from another project"
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
        let target = try XCTUnwrap(project.panelContext?.identity)
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
        guard let project = owner.selectedProject, let identity = project.panelContext?.identity
        else { return XCTFail("Expected local project") }
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
              case .file(let secondFile)? = second.selectedProject?.selectedTab?.content,
              let target = project.panelContext?.identity else {
            return XCTFail("Both windows must open the physical file from distinct paths")
        }
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
              let identity = project.panelContext?.identity,
              let otherProject = other.selectedProject,
              let otherIdentity = otherProject.panelContext?.identity else {
            return XCTFail("Both windows need a Files tree")
        }
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
        guard let project = owner.selectedProject,
              let identity = project.panelContext?.identity else {
            return XCTFail("Missing Files project")
        }
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
              case .file(let c)? = third.selectedProject?.selectedTab?.content,
              let identity = project.panelContext?.identity else {
            return XCTFail("All three windows must open the same physical file")
        }
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
              case .file(let other)? = second.selectedProject?.selectedTab?.content,
              let identity = project.panelContext?.identity else {
            return XCTFail("The two projects and their file targets must exist")
        }
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
        manager.autoSaveEditedTabs()
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
                dock: .group(.init(id: UUID(), items: [.files], selected: .files))
            )
            return SessionSnapshot(projects: [project], selectedProjectIndex: 0)
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
        let remote = Project(fallbackName: "SSH", workspaceConfiguration: .standard)
        remote.sshHost = "invalid-worktree-protection-fixture"
        remote.customDirectory = "/remote/unrelated"
        manager.projects.append(remote)
        manager.selectedProjectID = remote.id
        XCTAssertTrue(manager.openExternalLocalItems([file]).isEmpty)
        let tab = try XCTUnwrap(remote.selectedTab)
        guard case .file(let localFile) = tab.content else {
            return XCTFail("Mac file should open in an SSH project's editor tab")
        }
        XCTAssertNil(localFile.workspaceIdentity)
        XCTAssertEqual(remote.panelContext?.scope, "ssh:invalid-worktree-protection-fixture")

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
