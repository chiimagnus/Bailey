import XCTest
@testable import Bailey

@MainActor
final class GitGraphReferenceGroupTests: XCTestCase {
    func testKnownHostingRemotesFollowBothMergeParentsAndNeverInferFromLocalRefs() {
        typealias Commit = GitStatusModel.RecentCommit
        typealias Ref = GitStatusModel.GitRef
        func oid(_ character: Character) -> String { String(repeating: String(character), count: 40) }
        func commit(_ id: Character, parents: [Character]) -> Commit {
            Commit(
                hash: oid(id), shortHash: String(repeating: String(id), count: 7),
                subject: "commit", author: "Tester", date: .now,
                parentHashes: parents.map(oid), references: [], files: []
            )
        }
        let commits = [
            commit("a", parents: []),
            commit("b", parents: ["a"]),
            commit("c", parents: ["a"]),
            commit("d", parents: ["b", "c"]),
            commit("e", parents: ["d"])
        ]
        let refs: [String: Ref] = [
            "refs/remotes/origin/main": .init(oid: oid("d"), symbolic: nil, objectType: "commit"),
            "refs/remotes/upstream/main": .init(oid: oid("c"), symbolic: nil, objectType: "commit"),
            "refs/remotes/origin/team/topic": .init(oid: oid("b"), symbolic: nil, objectType: "commit"),
            "refs/remotes/origin/HEAD": .init(
                oid: oid("e"), symbolic: "refs/remotes/origin/main", objectType: "commit"
            ),
            "refs/remotes/deleted/main": .init(oid: oid("e"), symbolic: nil, objectType: "commit"),
            "refs/heads/main": .init(oid: oid("e"), symbolic: nil, objectType: "commit"),
            "refs/tags/local": .init(oid: oid("e"), symbolic: nil, objectType: "commit")
        ]
        let result = GitStatusModel.knownRemotesByCommit(
            commits, refsByName: refs, remotes: ["origin", "origin/team", "upstream"]
        )
        XCTAssertEqual(result[oid("a")], Set(["origin", "origin/team", "upstream"]))
        XCTAssertEqual(result[oid("b")], Set(["origin", "origin/team"]))
        XCTAssertEqual(result[oid("c")], Set(["origin", "upstream"]))
        XCTAssertEqual(result[oid("d")], Set(["origin"]))
        XCTAssertNil(result[oid("e")], "Local HEAD and an alias are not proof of a published commit")
        XCTAssertTrue(GitStatusModel.knownRemotesByCommit(
            commits, refsByName: refs, remotes: []
        ).isEmpty)
        XCTAssertNil(GitStatusModel.knownRemotesByCommit(
            Array(commits.dropFirst()), refsByName: refs, remotes: ["origin"]
        )[oid("a")], "Missing graph ancestry must not invent remote availability")
    }

    func testCompositeReferencesUseLongestConfiguredRemoteAndPreserveEveryTarget() throws {
        typealias Ref = GitStatusModel.RecentCommit.Reference
        let references: [Ref] = [
            .init(kind: .localBranch, name: "team/topic/nested"),
            .init(kind: .remoteBranch, name: "origin/team/topic/nested"),
            .init(kind: .remoteBranch, name: "old/main"),
            .init(kind: .currentBranch, name: "main"),
            .init(kind: .remoteBranch, name: "upstream/main"),
            .init(kind: .localBranch, name: "topic/nested"),
            .init(kind: .tag, name: "v1,β"),
            .init(kind: .remoteBranch, name: "origin/main"),
            .init(kind: .remoteAlias, name: "origin/HEAD"),
        ]
        let groups = GitGraphReferenceGroup.grouped(
            references, remotes: ["origin", "origin/team", "upstream"]
        )
        XCTAssertEqual(groups.first?.primary.name, "main")
        XCTAssertEqual(groups.first?.remotes.map(\.name), ["upstream/main", "origin/main"])
        let topic = try XCTUnwrap(groups.first { $0.primary.name == "topic/nested" })
        XCTAssertEqual(topic.remotes.map(\.name), ["origin/team/topic/nested"])
        XCTAssertTrue(groups.contains {
            $0.primary.name == "team/topic/nested" && $0.remotes.isEmpty
        })
        XCTAssertTrue(groups.contains {
            $0.primary.name == "old/main" && $0.remotes.isEmpty
        })
        XCTAssertTrue(groups.contains {
            $0.primary.kind == .remoteAlias && $0.remotes.isEmpty
        })
        XCTAssertTrue(groups.contains { $0.primary.kind == .tag })
        let flattened = groups.flatMap(\.references)
        XCTAssertEqual(flattened.count, references.count)
        XCTAssertEqual(Set(flattened), Set(references))
    }

    func testCompositeReferencesNeverJoinDifferentCommitRowsOrUnknownRemotes() {
        typealias Ref = GitStatusModel.RecentCommit.Reference
        let local = Ref(kind: .localBranch, name: "修复/feature,α")
        let remote = Ref(kind: .remoteBranch, name: "origin/修复/feature,α")
        let first = GitGraphReferenceGroup.grouped([local], remotes: ["origin"])
        let second = GitGraphReferenceGroup.grouped([remote], remotes: ["origin"])
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(first[0].remotes.isEmpty)
        XCTAssertEqual(second[0].primary, remote)
        let stale = GitGraphReferenceGroup.grouped([local, remote], remotes: [])
        XCTAssertEqual(stale.count, 2)
        XCTAssertTrue(stale.allSatisfy { $0.remotes.isEmpty })
        let matched = GitGraphReferenceGroup.grouped([local, remote], remotes: ["origin"])
        XCTAssertEqual(matched.count, 1)
        XCTAssertEqual(matched[0].remotes, [remote])
    }

    func testLocalBranchTakesPriorityOverRemoteDefaultAliasWithoutLosingReferences() {
        typealias Reference = GitStatusModel.RecentCommit.Reference
        let references: [Reference] = [
            .init(kind: .remoteAlias, name: "origin/HEAD"),
            .init(kind: .remoteBranch, name: "origin/main"),
            .init(kind: .localBranch, name: "main"),
            .init(kind: .tag, name: "v1"),
        ]
        let groups = GitGraphReferenceGroup.grouped(references, remotes: ["origin"])
        XCTAssertEqual(groups.first?.primary.name, "main")
        XCTAssertEqual(Set(groups.flatMap(\.references)), Set(references))
        let current = Reference(kind: .currentBranch, name: "topic")
        XCTAssertEqual(GitGraphReferenceGroup.grouped(references + [current], remotes: ["origin"])
            .first?.primary, current)
        let detached = Reference(kind: .detachedHead, name: "HEAD")
        XCTAssertEqual(GitGraphReferenceGroup.grouped(references + [detached], remotes: ["origin"])
            .first?.primary, detached)
        let feature = Reference(kind: .localBranch, name: "feature")
        let location = GitStatusModel.WorktreeLocation(path: "/fixture/feature", headOID: nil, branch: "feature")
        let checkedOut = GitGraphReferenceGroup.grouped(
            references + [feature], remotes: ["origin"], worktrees: [location]
        )
        XCTAssertEqual(checkedOut.first?.primary, feature)
        XCTAssertEqual(Set(checkedOut.flatMap(\.references)), Set(references + [feature]))
    }

    func testGraphNodeHelpOnlyStatesConfirmedHEADMembershipAndActualReferences() throws {
        let commit = GitStatusModel.RecentCommit(
            hash: String(repeating: "a", count: 40),
            shortHash: "aaaaaaa", subject: "Merge branch",
            author: "Tester", date: .now, parentHashes: ["parent", "side"],
            references: [
                .init(kind: .remoteBranch, name: "origin/main"),
                .init(kind: .tag, name: "v1.0"),
            ], files: []
        )
        let confirmed = RecentCommitsView.nodeHelp(commit, inHeadHistory: true)
        XCTAssertTrue(confirmed.contains(commit.hash))
        XCTAssertTrue(confirmed.contains(commit.subject))
        XCTAssertTrue(confirmed.contains("origin/main"))
        XCTAssertTrue(confirmed.contains("v1.0"))
        XCTAssertTrue(confirmed.contains(
            String(localized: "In HEAD History", table: "Git")
        ))
        let unknown = RecentCommitsView.nodeHelp(commit, inHeadHistory: false)
        XCTAssertFalse(unknown.contains(
            String(localized: "In HEAD History", table: "Git")
        ))
        let stash = GitStatusModel.Stash(
            selector: "stash@{1}", oid: String(repeating: "b", count: 40),
            message: "saved", baseHash: "parent", untrackedFilesHash: nil,
            author: "Tester", date: .now
        )
        let stashCommit = try XCTUnwrap(
            GitStatusModel.graphCommits([], stashes: [stash]).first
        )
        XCTAssertTrue(RecentCommitsView.nodeHelp(
            stashCommit, inHeadHistory: false
        ).contains(stash.selector))
    }
}
