import Foundation
import Security

/// Reads the OAuth access token that Claude Code stores in the login keychain.
///
/// We deliberately only ever *read*. Claude Code owns the token lifecycle; if we
/// refreshed it ourselves we could rotate it out from under a running session.
enum Keychain {
    /// Service name Claude Code registers under. Built the same way the CLI builds
    /// it ("Claude Code" + "-credentials") so it stays greppable against the binary.
    static let service = "Claude Code-credentials"

    enum Error: Swift.Error, LocalizedError {
        case notFound
        case unreadable(OSStatus)
        case malformed(String)
        case expired

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "No Claude Code credentials found in the keychain. Sign in with `claude` first."
            case .unreadable(let status):
                let msg = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
                return "Could not read the keychain: \(msg)"
            case .malformed(let detail):
                return "Claude Code credentials were not in the expected format: \(detail)"
            case .expired:
                return "Claude Code's saved credentials have expired. Run `claude` to sign in again."
            }
        }
    }

    /// Raw JSON blob stored under the service.
    ///
    /// The service name is the only attribute we can pin — the account is the
    /// local username, which we shouldn't assume — so a `matchLimitOne` query
    /// would hand back whichever item the keychain happened to order first if
    /// more than one existed. Instead: enumerate the accounts, then read them
    /// by name and pick the one that actually parses.
    ///
    /// Two passes rather than one because the legacy file-based keychain this
    /// item lives in rejects `kSecMatchLimitAll` combined with
    /// `kSecReturnData` outright (`errSecParam`); only attributes can be
    /// listed in bulk.
    static func rawCredentials() throws -> Data {
        let accounts = try accountNames()

        var firstFound: Data?
        var lastStatus: OSStatus = errSecItemNotFound
        for account in accounts {
            let (data, status) = itemData(account: account)
            guard let data else { lastStatus = status; continue }
            if firstFound == nil { firstFound = data }
            if (try? credential(in: data)) != nil { return data }
        }

        // A blob we could read but not parse still beats a generic failure:
        // the caller gets a specific `.malformed` describing what was there.
        if let firstFound { return firstFound }
        if accounts.isEmpty || lastStatus == errSecItemNotFound { throw Error.notFound }
        throw Error.unreadable(lastStatus)
    }

    /// Every account stored under the service. Attributes only — no secret
    /// material is copied out here, so this doesn't prompt.
    private static func accountNames() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            let attributes = (item as? [[String: Any]]) ?? []
            // Sorted so that a keychain holding several items resolves the same
            // way on every launch rather than however it happened to enumerate.
            return attributes.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
        case errSecItemNotFound:
            throw Error.notFound
        default:
            throw Error.unreadable(status)
        }
    }

    private static func itemData(account: String) -> (Data?, OSStatus) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return (nil, status) }
        return (data, status)
    }

    /// The bearer token to send to the usage endpoint.
    ///
    /// Expiry is checked here rather than being discovered as a 401: the OAuth
    /// endpoint's rate limit is shared with Claude Code itself, so spending a
    /// request to learn something the stored blob already says is a waste of
    /// the user's quota.
    static func accessToken(now: Date = Date()) throws -> String {
        let data = try rawCredentials()
        let (token, expiresAt) = try credential(in: data)
        if let expiresAt, expiresAt <= now { throw Error.expired }
        return token
    }

    /// The token alone, for probing whether a blob is the one we want.
    private static func token(in data: Data) throws -> String {
        try credential(in: data).token
    }

    static func credential(in data: Data) throws -> (token: String, expiresAt: Date?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.malformed("stored value was not JSON")
        }

        // Observed shape is { "claudeAiOauth": { "accessToken": ... } }, but tolerate
        // the token sitting at the top level in case the layout shifts.
        let oauth = root["claudeAiOauth"] as? [String: Any] ?? root

        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw Error.malformed("no accessToken field (keys: \(root.keys.sorted().joined(separator: ", ")))")
        }
        return (token, expiry(in: oauth))
    }

    /// Claude Code writes `expiresAt` as epoch milliseconds. Anything we can't
    /// make sense of is treated as "no expiry known" — the request still goes
    /// out and a 401 remains the backstop.
    private static func expiry(in oauth: [String: Any]) -> Date? {
        guard let raw = oauth["expiresAt"] as? Double, raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw / 1000)
    }
}
