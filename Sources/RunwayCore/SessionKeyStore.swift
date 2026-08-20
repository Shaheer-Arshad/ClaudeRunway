import Foundation
import Security

/// Stores the claude.ai session key in the login keychain.
///
/// Kept in the keychain rather than UserDefaults or a plist because it is a
/// bearer credential for the user's whole Claude account — anything that can
/// read it can read their usage and more.
///
/// The org ID is *derived* from the key (see `WebUsageAPI.discoverOrganization`)
/// and cached in UserDefaults, since it isn't secret and re-fetching it on every
/// launch would be wasteful.
enum SessionKeyStore {
    static let service = "ClaudeRunway-session"
    /// The service name used before the app was renamed. Read once, migrated,
    /// then removed — an existing key must survive the rename rather than
    /// silently turning into "add a session key".
    private static let legacyService = "ClaudeUsageBar-session"
    private static let account = "claude.ai"
    private static let orgKey = "web.organizationID"

    // MARK: - Session key

    static func load() -> String? {
        if let key = read(from: service) { return key }

        // Nothing under the current name: carry a pre-rename key forward, then
        // drop the old item so this only happens once.
        guard let legacy = read(from: legacyService) else { return nil }
        if save(legacy) { delete(from: legacyService) }
        return legacy
    }

    private static func read(from service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = normalize(key)
        guard !trimmed.isEmpty else { return false }

        // Simplest correct approach: delete then add, so this works whether or
        // not an entry already exists.
        delete()

        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(trimmed.utf8),
            // A menu bar app only reads this while someone is logged in and
            // looking at the screen, so there is no reason to make the key
            // readable in the window between boot and unlock. (Advisory on the
            // legacy file-based keychain this app writes to; it becomes
            // enforced if the bundle ever gains a real signing identity and
            // moves to the data-protection keychain.)
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        delete(from: service)
        delete(from: legacyService)
    }

    private static func delete(from service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Accepts what a user realistically pastes: the bare key, `sessionKey=...`,
    /// or a whole cookie header containing it among other cookies.
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let range = s.range(of: "sessionKey=") {
            s = String(s[range.upperBound...])
        }
        // Stop at the next cookie separator, if the user pasted a full header.
        if let end = s.firstIndex(where: { $0 == ";" || $0 == " " || $0 == "\n" }) {
            s = String(s[..<end])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cheap sanity check so obviously-wrong pastes are rejected before a round trip.
    static func looksValid(_ key: String) -> Bool {
        let k = normalize(key)
        return k.hasPrefix("sk-ant-sid") && k.count > 40
    }

    // MARK: - Organization ID (derived, not secret)

    static var organizationID: String? {
        get { UserDefaults.standard.string(forKey: orgKey) }
        set { UserDefaults.standard.set(newValue, forKey: orgKey) }
    }
}
