import Foundation

/// Builds browser links from Git transport addresses without contacting the remote.
nonisolated struct GitHostedRemoteURL: Equatable, Sendable {
    enum Provider: String, CaseIterable, Sendable {
        case github, gitlab, bitbucket, gitea, forgejo, gitee, gitcode, codeup, azure, sourcehut, gogs, generic

        var title: String {
            switch self {
            case .github: "GitHub"
            case .gitlab: "GitLab"
            case .bitbucket: "Bitbucket"
            case .gitea: "Gitea"
            case .forgejo: "Forgejo"
            case .gitee: "Gitee"
            case .gitcode: "GitCode"
            case .codeup: "Codeup"
            case .azure: "Azure DevOps"
            case .sourcehut: "SourceHut"
            case .gogs: "Gogs"
            case .generic: "Repository"
            }
        }
    }

    let repositoryURL: URL
    let provider: Provider

    init?(remoteURL: String, hostProviders: [String: Provider] = [:]) {
        let input = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !remoteURL.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else { return nil }

        let host: String
        let path: String
        let webScheme: String
        let port: Int?
        if let url = URLComponents(string: input), let scheme = url.scheme {
            let lower = scheme.lowercased()
            guard ["http", "https", "ssh", "git"].contains(lower),
                  let remoteHost = url.host, !remoteHost.isEmpty else { return nil }
            host = remoteHost.lowercased()
            path = url.path
            webScheme = lower == "http" ? "http" : "https"
            port = lower == "http" || lower == "https" ? url.port : nil
        } else {
            let fields = input.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[1].isEmpty,
                  !fields[0].contains("/"), !fields[0].contains("\\"),
                  let name = fields[0].split(separator: "@").last, !name.isEmpty else { return nil }
            host = String(name).lowercased()
            path = "/" + fields[1]
            webScheme = "https"
            port = nil
        }

        let detected = hostProviders[host] ?? Self.detectProvider(host)
        var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var browserHost = host
        if detected == .azure, host == "ssh.dev.azure.com", parts.count == 4,
           parts.first == "v3" {
            browserHost = "dev.azure.com"
            parts = [parts[1], parts[2], "_git", parts[3]]
        }
        guard parts.count >= (detected == .generic ? 1 : 2),
              !parts.contains(where: { $0 == "." || $0 == ".." || $0.contains("\\") }),
              !host.contains(" "), !host.isEmpty else { return nil }
        var normalized = parts
        guard let last = normalized.last, !last.lowercased().hasSuffix(".bundle") else { return nil }
        if last.lowercased().hasSuffix(".git") {
            normalized[normalized.count - 1] = String(last.dropLast(4))
        }
        guard !normalized.last!.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = webScheme
        components.host = browserHost
        components.port = port
        components.path = "/" + normalized.joined(separator: "/")
        guard let webURL = components.url else { return nil }
        repositoryURL = webURL
        provider = detected
    }

    func commitURL(_ oid: String) -> URL? {
        guard (oid.count == 40 || oid.count == 64),
              oid.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
              }) else { return nil }
        switch provider {
        case .github, .gitea, .forgejo, .gitee, .gitcode, .azure, .sourcehut, .gogs:
            return repositoryURL.appendingPathComponent("commit").appendingPathComponent(oid)
        case .gitlab:
            return repositoryURL.appendingPathComponent("-")
                .appendingPathComponent("commit").appendingPathComponent(oid)
        case .bitbucket, .codeup:
            return repositoryURL.appendingPathComponent("commits").appendingPathComponent(oid)
        case .generic:
            return nil
        }
    }

    /// Custom hosts cover GitLab, GitHub Enterprise and self-hosted forges.
    static func validateHostProviders(_ entries: [String]) throws -> [String: Provider] {
        var overrides: [String: Provider] = [:]
        for entry in entries {
            let fields = entry.split(separator: "=", omittingEmptySubsequences: false)
            guard fields.count == 2 else { throw HostRuleError.invalid(entry) }
            let host = fields[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let name = fields[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let provider = Provider(rawValue: name), provider != .generic,
                  !host.isEmpty, !host.contains("/"), !host.contains(":"),
                  !host.contains("@"), !host.contains(" "),
                  URLComponents(string: "https://" + host)?.host == host,
                  overrides[host] == nil else { throw HostRuleError.invalid(entry) }
            overrides[host] = provider
        }
        return overrides
    }

    enum HostRuleError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self {
            case .invalid(let value):
                String(localized: "Invalid Git hosting rule", table: "Settings") + ": "
                    + value + ". "
                    + String(localized: "Use host=provider, for example git.company.com=gitlab.", table: "Settings")
            }
        }
    }

    private static func detectProvider(_ host: String) -> Provider {
        if host == "github.com" || host.hasSuffix(".github.com") { return .github }
        if host == "gitlab.com" || host == "jihulab.com" || host.hasPrefix("gitlab.") { return .gitlab }
        if host == "bitbucket.org" || host.hasPrefix("bitbucket.") { return .bitbucket }
        if host == "codeberg.org" || host.hasPrefix("forgejo.") { return .forgejo }
        if host == "gitee.com" { return .gitee }
        if host == "gitcode.com" || host == "atomgit.com"
            || host == "hub.gitcode.com" || host == "hub.atomgit.com" { return .gitcode }
        if host == "codeup.aliyun.com" { return .codeup }
        if host == "dev.azure.com" || host == "ssh.dev.azure.com"
            || host.hasSuffix(".visualstudio.com") { return .azure }
        if host == "git.sr.ht" { return .sourcehut }
        if host.hasPrefix("gogs.") { return .gogs }
        if host == "gitea.com" || host.hasPrefix("gitea.") { return .gitea }
        return .generic
    }
}
