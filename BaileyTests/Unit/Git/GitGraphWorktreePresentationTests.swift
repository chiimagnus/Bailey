import XCTest
@testable import Bailey

@MainActor
final class GitGraphWorktreePresentationTests: XCTestCase {
    func testWorktreeDisplayPathsStayUniqueWithSameCheckoutDirectoryNames() {
        let paths = [
            "/Users/test/A/shared",
            "/Users/test/B/shared",
            "/Users/test/C/one/shared",
            "/Users/test/D/one/shared",
            "/Users/test/独特工作树",
        ]
        let labels = paths.map { RecentCommitsView.worktreeDisplayPath($0, among: paths) }
        XCTAssertEqual(labels.count, Set(labels).count)
        XCTAssertEqual(labels[0], "A/shared")
        XCTAssertEqual(labels[1], "B/shared")
        XCTAssertEqual(labels[2], "C/one/shared")
        XCTAssertEqual(labels[3], "D/one/shared")
        XCTAssertEqual(labels[4], "独特工作树")
        XCTAssertEqual(RecentCommitsView.worktreeDisplayPath("/Users/test/B/shared",
                         among: ["/Users/test/B/shared"]), "shared")
    }

    func testWorktreeConflictStatusAlwaysUsesUInTreeAndList() {
        let conflicts: [(Character, Character)] = [
            ("U", "U"), ("A", "A"), ("D", "D"), ("A", "U"), ("U", "D")
        ]
        for (index, status) in conflicts.enumerated() {
            let entry = GitStatusModel.Entry(
                path: "conflict-\(index).txt", staged: status.0,
                unstaged: status.1, isConflict: true
            )
            XCTAssertEqual(RecentCommitsView.worktreeDisplayStatus(entry, staged: true), "U")
            XCTAssertEqual(RecentCommitsView.worktreeDisplayStatus(entry, staged: false), "U")
        }
        let modified = GitStatusModel.Entry(path: "modified", staged: "R", unstaged: "M")
        XCTAssertEqual(RecentCommitsView.worktreeDisplayStatus(modified, staged: true), "R")
        XCTAssertEqual(RecentCommitsView.worktreeDisplayStatus(modified, staged: false), "M")
    }

    func testUnassociatedWorktreeLabelChineseTranslationPreservesDirectoryName() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
        let bundle = try XCTUnwrap(Bundle(path: path))
        let pattern = bundle.localizedString(forKey: "%@ · No branch", value: nil, table: "Git")
        XCTAssertEqual(String(format: pattern, "a904/Bailey"), "a904/Bailey · 未关联分支")
    }
}
