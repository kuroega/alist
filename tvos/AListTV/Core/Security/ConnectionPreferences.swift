import Foundation
import Network

struct StoredConnection: Equatable, Sendable {
    let baseURL: URL
    let username: String
    let clientID: String
}

struct ConnectionPreferences {
    private enum Key {
        static let baseURL = "com.alist.tv.base-url"
        static let username = "com.alist.tv.username"
        static let clientID = "com.alist.tv.client-id"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func stableClientID() -> String {
        if let existing = defaults.string(forKey: Key.clientID), UUID(uuidString: existing) != nil {
            return existing
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: Key.clientID)
        return generated
    }

    func saveConnection(baseURL: URL, username: String, clientID: String) {
        defaults.set(baseURL.absoluteString, forKey: Key.baseURL)
        defaults.set(username, forKey: Key.username)
        defaults.set(clientID, forKey: Key.clientID)
    }

    func loadConnection() -> StoredConnection? {
        guard let value = defaults.string(forKey: Key.baseURL),
              let baseURL = URL(string: value),
              let username = defaults.string(forKey: Key.username),
              let clientID = defaults.string(forKey: Key.clientID),
              UUID(uuidString: clientID) != nil else {
            return nil
        }
        return StoredConnection(baseURL: baseURL, username: username, clientID: clientID)
    }
}

enum ServerURLValidator {
    static func validate(_ input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              components.scheme != nil else {
            throw AListAPIError.invalidServerURL
        }
        guard isAllowedConnection(scheme: components.scheme, host: components.host) else {
            throw AListAPIError.insecureURL
        }
        guard let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw AListAPIError.invalidServerURL
        }

        var path = components.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path == "/" ? "" : path
        guard let normalized = components.url, normalized.host != nil else {
            throw AListAPIError.invalidServerURL
        }
        return normalized
    }

    static func isAllowedConnection(scheme: String?, host: String?) -> Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        if scheme == "https" {
            return true
        }
#if DEBUG
        return scheme == "http" && host.map(isPrivateHost) == true
#else
        return false
#endif
    }

#if DEBUG
    private static func isPrivateHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        if normalized == "localhost" || normalized.hasSuffix(".local") {
            return true
        }

        if let address = IPv4Address(normalized) {
            let octets = address.rawValue
            return octets[0] == 10
                || octets[0] == 127
                || (octets[0] == 169 && octets[1] == 254)
                || (octets[0] == 172 && (16 ... 31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168)
        }

        guard let address = IPv6Address(normalized) else { return false }
        let octets = address.rawValue
        let isLoopback = octets.dropLast().allSatisfy { $0 == 0 } && octets.last == 1
        let isUniqueLocal = octets[0] & 0xfe == 0xfc
        let isLinkLocal = octets[0] == 0xfe && octets[1] & 0xc0 == 0x80
        return isLoopback || isUniqueLocal || isLinkLocal
    }
#endif
}
