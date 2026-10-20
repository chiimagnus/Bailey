// swift-tools-version: 5.10
import PackageDescription

// Grammar/query files from STTextView-Plugin-Neon@5a30db4.
// No STTextView runtime dependency.
let languages = ["Bash", "C", "CPP", "CSharp", "CSS", "Go", "HTML", "Java", "JavaScript", "JSON", "Markdown", "PHP", "Python", "Ruby", "Rust", "Swift", "SQL", "TOML", "TypeScript", "YAML"]
let queries: [String: [String]] = [
    "Bash": ["highlights.scm"],
    "C": ["highlights.scm"],
    "CPP": ["highlights.scm"],
    "CSharp": ["highlights.scm"],
    "CSS": ["highlights.scm"],
    "Go": ["highlights.scm"],
    "HTML": ["highlights.scm", "injections.scm"],
    "Java": ["highlights.scm"],
    "JavaScript": ["highlights-jsx.scm", "highlights.scm"],
    "JSON": ["highlights.scm"],
    "Markdown": ["highlights.scm", "injections.scm"],
    "PHP": ["highlights.scm", "injections.scm"],
    "Python": ["highlights.scm"],
    "Ruby": ["highlights.scm"],
    "Rust": ["highlights.scm", "injections.scm"],
    "Swift": ["highlights.scm"],
    "SQL": ["highlights.scm"],
    "TOML": ["highlights.scm"],
    "TypeScript": ["highlights.scm"],
    "YAML": ["highlights.scm"],
]

let grammarTargets: [Target] = languages.flatMap { language -> [Target] in
    let parser = "TreeSitter" + language
    return [
        .target(name: parser,
                exclude: language == "YAML" ? ["src/schema.generated.cc"] : [],
                cSettings: [.headerSearchPath("src")]),
        .target(name: parser + "Queries",
                resources: queries[language, default: []].map { Resource.copy($0) }),
    ]
}

let grammarDependencies: [Target.Dependency] = languages.flatMap { language -> [Target.Dependency] in
    [.target(name: "TreeSitter" + language), .target(name: "TreeSitter" + language + "Queries")]
}
let resourceTarget: Target = .target(
    name: "TreeSitterResource",
    dependencies: [.product(name: "SwiftTreeSitter", package: "SwiftTreeSitter")]
        + grammarDependencies
)

let package = Package(
    name: "BaileyGrammars",
    platforms: [.macOS("15.6")],
    products: [.library(name: "TreeSitterResource", targets: ["TreeSitterResource"])],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.25.0"),
    ],
    targets: [resourceTarget] + grammarTargets
)
