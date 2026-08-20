import Foundation

/// Fallback transport: Claude Code's OAuth endpoint.
///
/// Automatic (no credential to maintain) but heavily rate limited — measured at
/// roughly one request per 6–7 minutes, and that quota is shared with Claude
/// Code's own calls. Used only when no valid session key is available.
enum UsageAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch(session: URLSession = UsageTransport.shared) async throws -> UsageSnapshot {
        let token = try Keychain.accessToken()

        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("ClaudeRunway/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw UsageError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw UsageError.undecodable }

        switch http.statusCode {
        case 200: return try UsageParser.parse(data, fetchedAt: Date())
        case 401, 403: throw UsageError.unauthorized
        case 429: throw UsageError.rateLimited(retryAfter: UsageParser.retryAfter(from: http))
        default: throw UsageError.http(http.statusCode)
        }
    }
}
