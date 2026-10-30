import Foundation
import XCTest
@testable import Bailey

final class GitHostedRemoteURLTests: XCTestCase {
    func testGitHubHTTPSAndSSHOpenTheSameCommit() throws {
        let hash = String(repeating: "a", count: 40)
        for raw in [
            "https://github.com/owner/repo.git",
            "git@github.com:owner/repo.git",
            "ssh://git@github.com:2222/owner/repo.git",
        ] {
            let link = try XCTUnwrap(GitHostedRemoteURL(remoteURL: raw))
            XCTAssertEqual(link.provider, .github)
            XCTAssertEqual(link.repositoryURL.absoluteString, "https://github.com/owner/repo")
            XCTAssertEqual(link.commitURL(hash)?.absoluteString,
                           "https://github.com/owner/repo/commit/\(hash)")
        }
    }

    func testGitLabSubgroupsAndPrivateHostMapping() throws {
        let hash = String(repeating: "b", count: 40)
        let link = try XCTUnwrap(GitHostedRemoteURL(
            remoteURL: "git@gitlab.com:team/group/repo.git"
        ))
        XCTAssertEqual(link.provider, .gitlab)
        XCTAssertEqual(link.commitURL(hash)?.absoluteString,
                       "https://gitlab.com/team/group/repo/-/commit/\(hash)")

        let overrides = try GitHostedRemoteURL.validateHostProviders(
            ["code.example.com=gitlab", "git.enterprise.test=github"]
        )
        let privateGitLab = try XCTUnwrap(GitHostedRemoteURL(
            remoteURL: "ssh://git@code.example.com:2222/team/repo.git",
            hostProviders: overrides
        ))
        XCTAssertEqual(privateGitLab.commitURL(hash)?.absoluteString,
                       "https://code.example.com/team/repo/-/commit/\(hash)")
        let enterprise = try XCTUnwrap(GitHostedRemoteURL(
            remoteURL: "https://git.enterprise.test/work/repo.git",
            hostProviders: overrides
        ))
        XCTAssertEqual(enterprise.commitURL(hash)?.absoluteString,
                       "https://git.enterprise.test/work/repo/commit/\(hash)")
    }

    func testBitbucketForgejoGiteaAndUnknownHost() throws {
        let hash = String(repeating: "c", count: 40)
        let cases: [(String, GitHostedRemoteURL.Provider, String)] = [
            ("https://bitbucket.org/team/repo.git", .bitbucket,
             "https://bitbucket.org/team/repo/commits/\(hash)"),
            ("git@codeberg.org:team/repo.git", .forgejo,
             "https://codeberg.org/team/repo/commit/\(hash)"),
            ("https://gitea.com/team/repo.git", .gitea,
             "https://gitea.com/team/repo/commit/\(hash)"),
            ("git@gitee.com:owner/repo.git", .gitee,
             "https://gitee.com/owner/repo/commit/\(hash)"),
            ("https://gitcode.com/team/repo.git", .gitcode,
             "https://gitcode.com/team/repo/commit/\(hash)"),
            ("https://codeup.aliyun.com/team/repo.git", .codeup,
             "https://codeup.aliyun.com/team/repo/commits/\(hash)"),
            ("https://hub.gitcode.com/team/repo.git", .gitcode,
             "https://hub.gitcode.com/team/repo/commit/\(hash)"),
            ("git@git.sr.ht:~team/repo.git", .sourcehut,
             "https://git.sr.ht/~team/repo/commit/\(hash)"),
            ("https://dev.azure.com/org/project/_git/repo.git", .azure,
             "https://dev.azure.com/org/project/_git/repo/commit/\(hash)"),
            ("git@ssh.dev.azure.com:v3/org/project/repo", .azure,
             "https://dev.azure.com/org/project/_git/repo/commit/\(hash)")
        ]
        for (raw, provider, expected) in cases {
            let link = try XCTUnwrap(GitHostedRemoteURL(remoteURL: raw))
            XCTAssertEqual(link.provider, provider)
            XCTAssertEqual(link.commitURL(hash)?.absoluteString, expected)
        }
        let unknown = try XCTUnwrap(GitHostedRemoteURL(
            remoteURL: "git@source.internal:division/repo.git"
        ))
        XCTAssertEqual(unknown.provider, .generic)
        XCTAssertNil(unknown.commitURL(hash))
        XCTAssertEqual(unknown.repositoryURL.absoluteString,
                       "https://source.internal/division/repo")
        XCTAssertEqual(GitHostedRemoteURL(remoteURL: "ssh://git@custom.host/repo.git")?
                       .repositoryURL.absoluteString, "https://custom.host/repo")
    }

    func testCredentialsAndUntrustedRemoteURLsNeverBecomeBrowserCredentials() throws {
        let link = try XCTUnwrap(GitHostedRemoteURL(
            remoteURL: "https://alice:secret@gitlab.com/team/repo.git?token=x#part"
        ))
        XCTAssertEqual(link.repositoryURL.absoluteString, "https://gitlab.com/team/repo")
        for invalid in [
            "", "../repo", "/tmp/repo", "file:///tmp/repo", "https://github.com",
            "https://github.com/org/../secret.git", "https://github.com/org/repo.git\ninvalid",
            "ftp://github.com/org/repo.git", "git@github.com:", "https://github.com/%2e%2e/repo"
        ] {
            XCTAssertNil(GitHostedRemoteURL(remoteURL: invalid), "Unsafe: \(invalid)")
        }
        XCTAssertNil(link.commitURL("abc"))
        XCTAssertNil(link.commitURL(String(repeating: "z", count: 40)))
        XCTAssertNil(GitHostedRemoteURL(remoteURL: "https://github.com/org/.git"))
        XCTAssertEqual(
            GitHostedRemoteURL(remoteURL: "https://github.com/org/repo.bundle")?
                .repositoryURL.absoluteString,
            "https://github.com/org/repo.bundle"
        )
    }

    func testHostOverrideValidationRejectsUnknownAndConflictingProviders() throws {
        let good = try GitHostedRemoteURL.validateHostProviders(["internal.example=gitlab"])
        XCTAssertEqual(good["internal.example"], .gitlab)
        for invalid in [
            ["internal.example=unsupported"], ["=gitlab"], ["internal.example=gitlab", "internal.example=github"],
            ["https://internal.example=gitlab"], ["host/path=github"]
        ] {
            XCTAssertThrowsError(try GitHostedRemoteURL.validateHostProviders(invalid))
        }
    }
}
