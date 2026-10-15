import Foundation
import XCTest
@testable import kero

@MainActor
final class GitTagActionTests: XCTestCase {
    private var directory: URL!
    private var remotesDirectory: URL!
    private var model: GitStatusModel!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kero-tag-" + UUID().uuidString)
        remotesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kero-tag-remotes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remotesDirectory, withIntermediateDirectories: true)
        model = GitStatusModel()
        _ = try git(["init", "-q", "-b", "main"])
        _ = try git(["config", "user.name", "Tag Tester"])
        _ = try git(["config", "user.email", "tag@example.invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        _ = try git(["config", "core.hooksPath", "/dev/null"])
        _ = try git(["commit", "--allow-empty", "-qm", "first"])
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.removeItem(at: remotesDirectory)
    }

    @discardableResult
    private func git(_ args: [String]) throws -> String {
        let result = GitCommandExecution.run(args, in: directory.path, timeout: 15)
        guard result.status == 0 else {
            XCTFail(result.stderr + result.stdout)
            throw WorkspaceError.notFound
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func remote(_ name: String) throws -> URL {
        let location = remotesDirectory.appendingPathComponent(name)
        let initialized = GitCommandExecution.run(
            ["init", "--bare", "-q", location.path], in: directory.path
        )
        XCTAssertEqual(initialized.status, 0, initialized.stderr)
        _ = try git(["remote", "add", name, location.path])
        return location
    }

    private func settle() async throws {
        let deadline = Date().addingTimeInterval(15)
        while !model.hasResolvedStatus || model.isBusy || model.isRefreshing {
            guard Date() < deadline else { throw WorkspaceError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func refresh() async throws {
        model.sync(root: directory.path)
        try await settle()
    }

    func testAnnotatedAndLightweightTagsExposeActualObjectKindsAndDetails() async throws {
        let first = try git(["rev-parse", "HEAD"])
        _ = try git(["commit", "--allow-empty", "-qm", "second"])
        let second = try git(["rev-parse", "HEAD"])
        try await refresh()
        model.createTag(named: "v1.0", at: first, type: .annotated, message: "release notes\nsecond line",
                        replacing: nil, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["cat-file", "-t", "refs/tags/v1.0"]), "tag")
        XCTAssertEqual(try git(["rev-parse", "refs/tags/v1.0^{commit}"]), first)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), second)
        XCTAssertTrue(model.isAnnotatedTag(named: "v1.0"))
        let fetchedDetails = await model.tagDetails(named: "v1.0", target: model.actionTarget())
        let details = try XCTUnwrap(fetchedDetails)
        XCTAssertEqual(details.commitOID, first)
        XCTAssertEqual(details.objectOID, try git(["rev-parse", "refs/tags/v1.0"]))
        XCTAssertTrue(details.message.contains("release notes\nsecond line"))
        XCTAssertTrue(details.tagger.contains("Tag Tester"))
        XCTAssertEqual(details.verification, .unsigned)

        model.createTag(named: "v1,patch", at: second, type: .lightweight, message: "ignored",
                        replacing: nil, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["cat-file", "-t", "refs/tags/v1,patch"]), "commit")
        XCTAssertFalse(model.isAnnotatedTag(named: "v1,patch"))
        let lightweightDetails = await model.tagDetails(named: "v1,patch", target: model.actionTarget())
        XCTAssertNil(lightweightDetails)
    }

    func testSignedTagWithoutTrustedSignerIsNeverReportedAsVerified() async throws {
        let key = remotesDirectory.appendingPathComponent("test-signing-key")
        let generation = Process()
        generation.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        generation.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", key.path]
        generation.standardOutput = FileHandle.nullDevice
        generation.standardError = FileHandle.nullDevice
        try generation.run()
        generation.waitUntilExit()
        XCTAssertEqual(generation.terminationStatus, 0)
        _ = try git(["config", "gpg.format", "ssh"])
        _ = try git(["config", "user.signingkey", key.path])
        _ = try git(["tag", "-s", "-m", "signed release notes", "signed-v1"])
        try await refresh()
        XCTAssertTrue(model.isAnnotatedTag(named: "signed-v1"))
        let loaded = await model.tagDetails(named: "signed-v1", target: model.actionTarget())
        let details = try XCTUnwrap(loaded)
        XCTAssertEqual(details.verification, .unverified,
            "An existing SSH signature without a trusted verifier cannot be reported as valid")
        XCTAssertTrue(details.message.contains("signed release notes"))
    }

    func testTagCollisionNeverReplacesWithoutExplicitChoiceAndKeepsOtherTags() async throws {
        let first = try git(["rev-parse", "HEAD"])
        _ = try git(["tag", "coexisting", first])
        try await refresh()
        model.createTag(named: "v1", at: first, type: .annotated, message: "",
                        replacing: nil, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        let oldTag = try git(["rev-parse", "refs/tags/v1"])
        _ = try git(["commit", "--allow-empty", "-qm", "new"])
        let second = try git(["rev-parse", "HEAD"])
        try await refresh()
        model.createTag(named: "v1", at: second, type: .lightweight, message: "",
                        replacing: nil, target: model.actionTarget())
        try await settle()
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "refs/tags/v1"]), oldTag)

        model.createTag(named: "v1", at: second, type: .lightweight, message: "",
                        replacing: oldTag, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "refs/tags/v1"]), second)
        XCTAssertEqual(try git(["rev-parse", "refs/tags/coexisting"]), first)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), second)
    }

    func testTagDeleteRemoteFirstAndPreservesLocalWhenRemoteRejects() async throws {
        let remotePath = try remote("origin")
        let head = try git(["rev-parse", "HEAD"])
        _ = try git(["tag", "v1", head])
        _ = try git(["push", "origin", "refs/tags/v1:refs/tags/v1"])
        try await refresh()
        // `receive.denyDeletes` protects branch deletes, not tag deletes.
        // Explicitly override the host's global core.hooksPath for this bare fixture.
        let hooks = remotesDirectory.appendingPathComponent("tag-protection-hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let preReceive = hooks.appendingPathComponent("pre-receive")
        try """
            #!/bin/sh
            while read old new ref; do
                case "$ref:$new" in
                    refs/tags/*:0000000000000000000000000000000000000000)
                        echo 'Tag deletion rejected by fixture' >&2
                        exit 1
                        ;;
                esac
            done
            exit 0
            """.write(to: preReceive, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: preReceive.path)
        let forbid = GitCommandExecution.run(
            ["--git-dir", remotePath.path, "config", "core.hooksPath", hooks.path],
            in: directory.path
        )
        XCTAssertEqual(forbid.status, 0, forbid.stderr)
        model.deleteTag("v1", fromRemote: "origin", target: model.actionTarget())
        try await settle()
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "refs/tags/v1"]), head)
        XCTAssertEqual(GitCommandExecution.run(
            ["--git-dir", remotePath.path, "show-ref", "--verify", "refs/tags/v1"],
            in: directory.path
        ).status, 0)
        let allow = GitCommandExecution.run(
            ["--git-dir", remotePath.path, "config", "--unset", "core.hooksPath"],
            in: directory.path
        )
        XCTAssertEqual(allow.status, 0)
        model.deleteTag("v1", fromRemote: "origin", target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertNotEqual(GitCommandExecution.run(["show-ref", "--verify", "refs/tags/v1"],
            in: directory.path).status, 0)
        XCTAssertNotEqual(GitCommandExecution.run(
            ["--git-dir", remotePath.path, "show-ref", "--verify", "refs/tags/v1"],
            in: directory.path
        ).status, 0)
    }

    func testCreateThenPushUsesActualNewTagOIDWithoutWaitingForStatusSnapshot() async throws {
        let remotePath = try remote("origin")
        let head = try git(["rev-parse", "HEAD"])
        try await refresh()
        let target = model.actionTarget()
        let pushed = expectation(description: "push the newly created annotated tag")
        model.createTag(named: "immediate", at: head, type: .annotated, message: "notes",
                        replacing: nil, target: target) { success in
            XCTAssertTrue(success)
            Task { @MainActor in
                let selected = await self.model.tagOID(
                    named: "immediate", pointingAt: head, target: target)
                XCTAssertNotNil(selected)
                if let selected {
                    self.model.pushTag("immediate", to: ["origin"], target: target,
                                       selectedOID: selected)
                }
                pushed.fulfill()
            }
        }
        await fulfillment(of: [pushed], timeout: 15)
        try await settle()
        XCTAssertNil(model.lastError, model.lastError ?? "")
        let onRemote = GitCommandExecution.run(
            ["--git-dir", remotePath.path, "rev-parse", "refs/tags/immediate"],
            in: directory.path
        )
        XCTAssertEqual(onRemote.status, 0, onRemote.stderr)
        XCTAssertEqual(onRemote.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                       try git(["rev-parse", "refs/tags/immediate"]))
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), head)
    }

    func testAnnotatedTagArchiveUsesSelectedCommitInsteadOfCurrentHead() async throws {
        try "archive historical bytes".write(
            to: directory.appendingPathComponent("historical.txt"), atomically: true, encoding: .utf8)
        _ = try git(["add", "historical.txt"])
        _ = try git(["commit", "-qm", "archive history"])
        let first = try git(["rev-parse", "HEAD"])
        _ = try git(["tag", "-a", "-m", "archive notes", "archive-v1", first])
        let tagOID = try git(["rev-parse", "refs/tags/archive-v1"])
        try "only newer commit".write(
            to: directory.appendingPathComponent("newer.txt"), atomically: true, encoding: .utf8)
        _ = try git(["add", "newer.txt"])
        _ = try git(["commit", "-qm", "next"])
        try await refresh()
        let archive = remotesDirectory.appendingPathComponent("tag-selected.zip")
        await model.createArchive(reference: "refs/tags/archive-v1",
            objectOID: tagOID, destination: archive, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        let result = GitCommandExecution.run(["ls-tree", "-r", "--name-only", first], in: directory.path)
        XCTAssertEqual(result.status, 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z", "-1", archive.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let names = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(names.contains("historical.txt"))
        XCTAssertFalse(names.contains("newer.txt"))
        XCTAssertEqual(try git(["rev-parse", "refs/tags/archive-v1^{commit}"]), first)
        XCTAssertNotEqual(try git(["rev-parse", "HEAD"]), first)
    }

    func testPushTagStopsAfterFirstRemoteRefusalAndWarnsForUnknownReachability() async throws {
        let first = try git(["rev-parse", "HEAD"])
        let rejecting = try remote("rejecting")
        let secondRemote = try remote("unattempted")
        _ = try git(["tag", "-a", "-m", "old", "v1", first])
        _ = try git(["push", "rejecting", "refs/tags/v1:refs/tags/v1"])
        _ = try git(["tag", "-d", "v1"])
        _ = try git(["commit", "--allow-empty", "-qm", "new"])
        let second = try git(["rev-parse", "HEAD"])
        try await refresh()
        model.createTag(named: "v1", at: second, type: .annotated, message: "new",
                        replacing: nil, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        let unknown = await model.tagRemotesWithoutCommit(second, selected: ["rejecting", "unattempted"],
                                                           target: model.actionTarget())
        XCTAssertEqual(Set(unknown ?? []), Set(["rejecting", "unattempted"]))

        model.pushTag("v1", to: ["rejecting", "unattempted"], target: model.actionTarget())
        try await settle()
        XCTAssertNotNil(model.lastError)
        XCTAssertTrue(model.operation?.output.contains("unattempted") == true)
        XCTAssertNotEqual(GitCommandExecution.run(["--git-dir", secondRemote.path, "show-ref",
                                                   "--verify", "refs/tags/v1"], in: directory.path).status, 0)
        XCTAssertEqual(GitCommandExecution.run(["--git-dir", rejecting.path, "show-ref",
                                                "--verify", "refs/tags/v1"], in: directory.path).status, 0)

        model.pushTag("v1", to: ["unattempted"], target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        let pushedOID = GitCommandExecution.run(
            ["--git-dir", secondRemote.path, "rev-parse", "refs/tags/v1"], in: directory.path
        )
        XCTAssertEqual(pushedOID.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                       try git(["rev-parse", "refs/tags/v1"]))
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), second)
    }
}
