import Foundation
import Security

/// Persisted connection settings. Server/user live in UserDefaults, secrets in the Keychain.
struct ConnectionSettings: Equatable {
    var serverURL: String
    var apiKey: String
    var username: String
    var password: String

    private enum Key {
        static let serverURL = "serverURL"
        static let username = "username"
        static let passwordAccount = "redmine-password"
        static let apiKeyAccount = "redmine-api-key"
    }

    static func load() -> ConnectionSettings {
        let defaults = UserDefaults.standard
        return ConnectionSettings(
            serverURL: defaults.string(forKey: Key.serverURL) ?? "",
            apiKey: Keychain.read(account: Key.apiKeyAccount) ?? "",
            username: defaults.string(forKey: Key.username) ?? "",
            password: Keychain.read(account: Key.passwordAccount) ?? ""
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(serverURL, forKey: Key.serverURL)
        defaults.set(username, forKey: Key.username)
        Keychain.write(password, account: Key.passwordAccount)
        Keychain.write(apiKey, account: Key.apiKeyAccount)
    }

    /// Normalised base URL; adds `https://` when no scheme was entered.
    var baseURL: URL? {
        var raw = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if !raw.contains("://") { raw = "https://" + raw }
        guard let url = URL(string: raw), url.host() != nil else { return nil }
        return url
    }

    /// Valid when a server plus an API key and/or username + password are set.
    var clientConfiguration: RedmineClient.Configuration? {
        guard let baseURL else { return nil }
        let configuration = RedmineClient.Configuration(
            baseURL: baseURL,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password
        )
        guard configuration.hasAPIKey || configuration.hasCredentials else { return nil }
        return configuration
    }
}

/// Minimal generic-password Keychain wrapper.
enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "RedmineMenuBar"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
