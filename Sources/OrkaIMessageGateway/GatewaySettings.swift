import Foundation
import Security

/// Non-secret settings, kept in UserDefaults.
struct GatewaySettings: Codable, Equatable {
    var accountID = ""
    var allowedSenders = ""
    var ingressURL = ""
    var listenPort = 8787
    var startAutomatically = true

    private static let key = "gatewaySettings"

    static func load(from defaults: UserDefaults = .standard) -> GatewaySettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(GatewaySettings.self, from: data)
        else { return GatewaySettings() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

/// The two Orka bearer tokens, kept in the login keychain.
enum TokenStore {
    static let inboundAccount = "orka-inbound-token"
    static let outboundAccount = "orka-outbound-token"
    private static let service = "ai.orka.gateway-imessage"

    static func read(_ account: String) -> String {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery(account)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    /// Returns 32 random bytes as hex.
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    struct KeychainError: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }
}
