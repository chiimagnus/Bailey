import Foundation
import Security

/// One user-approved Bark endpoint. Only the push key is retained in the
/// destination URL; notification text is never appended to the URL.
nonisolated struct BarkDestination: Hashable, Identifiable, Sendable {
    let url: URL
    let pushURL: URL
    let key: String

    var id: String { url.absoluteString }
    var displayName: String { "\(url.host ?? "Bark") · ••••\(key.suffix(4))" }

    init?(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = text.contains("://") ? text : "https://api.day.app/\(text)"
        guard var components = URLComponents(string: source),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath.split(separator: "/").count == 1,
              let part = components.percentEncodedPath.split(separator: "/").first
        else { return nil }

        let key = String(part)
        guard !key.isEmpty, key.utf8.count <= 128,
              key.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0)
                      || (97...122).contains($0) || $0 == 45 || $0 == 95
              })
        else { return nil }

        components.scheme = "https"
        components.host = host.lowercased()
        components.percentEncodedPath = "/\(key)"
        guard let url = components.url else { return nil }
        components.percentEncodedPath = "/push"
        guard let pushURL = components.url else { return nil }
        self.url = url
        self.pushURL = pushURL
        self.key = key
    }
}

/// Sends each configured device independently: the public Bark server does not
/// guarantee support for the separate multi-device batch-push API.
nonisolated enum BarkPushService {
    enum Failure: Error {
        case invalidDestination
        case keychain(OSStatus)
        case corruptStorage
        case invalidResponse
    }

    struct DeliveryResult: Equatable, Sendable {
        let total: Int
        let accepted: Int
        var failed: Int { total - accepted }
    }

    private static let service = AppIdentity.bundleIdentifier + ".bark"
    private static let account = "destinations"

    private static var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func destinations() throws -> [BarkDestination] {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        guard let data = item as? Data,
              let addresses = try? JSONDecoder().decode([String].self, from: data)
        else { throw Failure.corruptStorage }

        return try addresses.map { address in
            guard let destination = BarkDestination(address) else { throw Failure.corruptStorage }
            return destination
        }
    }

    /// Returns nil when the same URL is already configured.
    static func add(_ input: String) throws -> [BarkDestination]? {
        guard let destination = BarkDestination(input) else { throw Failure.invalidDestination }
        var current = try destinations()
        guard !current.contains(destination) else { return nil }
        current.append(destination)
        try store(current)
        return current
    }

    static func remove(_ destination: BarkDestination) throws -> [BarkDestination] {
        let current = try destinations()
        let retained = current.filter { $0 != destination }
        if retained.count != current.count { try store(retained) }
        return retained
    }

    private static func store(_ destinations: [BarkDestination]) throws {
        if destinations.isEmpty {
            let status = SecItemDelete(keychainQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw Failure.keychain(status)
            }
            return
        }

        let data = try JSONEncoder().encode(destinations.map(\.id))
        let changes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(keychainQuery as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = keychainQuery
            attributes[kSecValueData as String] = data
            attributes[kSecAttrLabel as String] = "Bailey Bark destinations"
            let added = SecItemAdd(attributes as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure.keychain(added) }
        } else if status != errSecSuccess {
            throw Failure.keychain(status)
        }
    }

    static func makeRequest(
        title: String, message: String, destination: BarkDestination
    ) throws -> URLRequest {
        var request = URLRequest(url: destination.pushURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_key": destination.key,
            "title": String(title.unicodeScalars.prefix(120)),
            "body": String(message.unicodeScalars.prefix(1_000)),
            "group": "Bailey",
        ])
        return request
    }

    static func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? Int, code == 200
        else { throw Failure.invalidResponse }
    }

    static func deliver(
        to destinations: [BarkDestination], title: String, message: String,
        using session: URLSession = .shared
    ) async -> DeliveryResult {
        let accepted = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for destination in destinations {
                group.addTask {
                    do {
                        let request = try makeRequest(
                            title: title, message: message, destination: destination
                        )
                        let (data, response) = try await session.data(for: request)
                        try validateResponse(response, data: data)
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var successes = 0
            for await succeeded in group where succeeded {
                successes += 1
            }
            return successes
        }
        return DeliveryResult(total: destinations.count, accepted: accepted)
    }

    static func sendConfigured(title: String, message: String) async throws -> DeliveryResult {
        await deliver(to: try destinations(), title: title, message: message)
    }
}
