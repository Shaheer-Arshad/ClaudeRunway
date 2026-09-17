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

    /// Read from the keychain once, then served from memory: the web transport
    /// polls every minute and each read could otherwise be a password prompt.
    static func load() -> String? {
        lock.lock(); defer { lock.unlock() }
        if loaded { return cachedKey }

        var key = read(from: service)
        if key == nil, let legacy = read(from: legacyService) {
            // Carry a pre-rename key forward, then drop the old item.
            key = legacy
            if writeLocked(legacy) { SecurityCLI.delete(service: legacyService, account: account) }
        } else if let found = key, !UserDefaults.standard.bool(forKey: migratedKey) {
            // Items saved by versions before 1.1.4 were created by the app itself,
            // so every update re-prompted. Re-create it through `security` once so
            // later versions read it silently.
            _ = writeLocked(found)
        }
        if key != nil { UserDefaults.standard.set(true, forKey: migratedKey) }
        cachedKey = key
        loaded = true
        return key
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = normalize(key)
        guard !trimmed.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        let ok = writeLocked(trimmed)
        if ok { UserDefaults.standard.set(true, forKey: migratedKey) }
        return ok
    }

    static func delete() {
        lock.lock(); defer { lock.unlock() }
        SecurityCLI.delete(service: service, account: account)
        SecurityCLI.delete(service: legacyService, account: account)
        cachedKey = nil
        loaded = true
    }

    /// True if a session key item exists. Reads attributes only, so it never
    /// prompts — used to decide whether to explain a prompt before it appears.
    static func itemExists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private static func read(from service: String) -> String? {
        guard case let (data?, _) = SecurityCLI.read(service: service, account: account),
              let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    private static func writeLocked(_ key: String) -> Bool {
        let ok = SecurityCLI.write(service: service, account: account, value: key)
        if ok { cachedKey = key; loaded = true }
        return ok
    }

    private static let migratedKey = "sessionKeyStoredViaSecurityTool"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded = false
    nonisolated(unsafe) private static var cachedKey: String?

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
