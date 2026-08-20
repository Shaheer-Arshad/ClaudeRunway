import Foundation

/// Primary transport: the endpoint claude.ai's own UI uses.
///
/// Verified against the live service: five requests two seconds apart all
/// returned 200, versus the OAuth endpoint which 429s at five-minute spacing.
/// That headroom is what makes 60-second updates possible.
///
/// It sits behind Cloudflare, but native `URLSession` passes the challenge —
/// its TLS fingerprint resembles Safari's. (`curl` is blocked; that difference
/// is the whole reason this route works.)
enum WebUsageAPI {
    static let host = "https://claude.ai"

    static func fetch(session: URLSession = UsageTransport.shared) async throws -> UsageSnapshot {
        guard let key = SessionKeyStore.load() else { throw UsageError.noSessionKey }

        let org: String
        if let cached = SessionKeyStore.organizationID, isUUID(cached) {
            org = cached
        } else {
            org = try await discoverOrganization(key: key, session: session)
            SessionKeyStore.organizationID = org
        }

        let data = try await get("\(host)/api/organizations/\(org)/usage", key: key, session: session)
        return try UsageParser.parse(data, fetchedAt: Date())
    }

    /// The user pastes only a session key; the org ID is derived from it so they
    /// never have to go hunting for a second value.
    static func discoverOrganization(key: String, session: URLSession = UsageTransport.shared) async throws -> String {
        let data = try await get("\(host)/api/organizations", key: key, session: session)

        guard let orgs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw UsageError.undecodable
        }
        // Prefer an org that actually has a Claude subscription attached; fall
        // back to the first one for accounts where capabilities aren't listed.
        let chosen = orgs.first { org in
            (org["capabilities"] as? [String])?.contains { $0.hasPrefix("claude_") } ?? false
        } ?? orgs.first

        // Validated before it is cached or interpolated into a path. It arrives
        // from the network and is cached in UserDefaults, which is a plain
        // user-writable plist — neither is a source we should paste into a URL
        // unchecked.
        guard let uuid = chosen?["uuid"] as? String, isUUID(uuid) else {
            throw UsageError.undecodable
        }
        return uuid
    }

    static func isUUID(_ s: String) -> Bool { UUID(uuidString: s) != nil }

    // MARK: - Transport

    private static func get(_ urlString: String, key: String,
                            session: URLSession) async throws -> Data {
        guard let url = URL(string: urlString) else { throw UsageError.undecodable }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("*/*", forHTTPHeaderField: "accept")
        req.setValue("\(host)/", forHTTPHeaderField: "referer")
        req.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")
        req.setValue("sessionKey=\(key)", forHTTPHeaderField: "cookie")

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw UsageError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw UsageError.undecodable }

        switch http.statusCode {
        case 200:
            // A Cloudflare interstitial returns 200 with HTML, so a status check
            // alone isn't enough to know we got real data.
            if isChallenge(data) { throw UsageError.sessionExpired }
            return data
        case 401, 403:
            throw UsageError.sessionExpired
        case 429:
            throw UsageError.rateLimited(retryAfter: UsageParser.retryAfter(from: http))
        default:
            throw UsageError.http(http.statusCode)
        }
    }

    private static func isChallenge(_ data: Data) -> Bool {
        guard let head = String(data: data.prefix(200), encoding: .utf8) else { return false }
        return head.contains("<!DOCTYPE") || head.contains("Just a moment")
    }
}
