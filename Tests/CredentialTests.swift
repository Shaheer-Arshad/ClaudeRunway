import Foundation

/// The two credentials this app touches are bearer tokens for a whole Claude
/// account, so the rules that keep them from leaking are worth pinning down in
/// tests rather than leaving to a code comment.
func runCredentialTests() {

    // MARK: - Token parsing

    func blob(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    T.test("an expired stored token is refused without spending a request") {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let data = blob(["claudeAiOauth": [
            "accessToken": "sk-ant-oat-example",
            "expiresAt": (now.timeIntervalSince1970 - 60) * 1000,
        ]])

        let credential = try! Keychain.credential(in: data)
        T.equal(credential.token, "sk-ant-oat-example", "the token still parses")
        T.expect(credential.expiresAt! < now, "and it is recognised as past its expiry")
    }

    T.test("a token with no expiry field is still usable") {
        let credential = try! Keychain.credential(in: blob(["claudeAiOauth": ["accessToken": "sk-ant-oat-x"]]))
        T.expect(credential.expiresAt == nil, "unknown expiry is not the same as expired")
    }

    // MARK: - Organization ID

    T.test("only a real UUID is accepted as an organization ID") {
        T.expect(WebUsageAPI.isUUID("2f1f7d1e-6b2c-4f0a-9a1e-6c3f5c2d8b90"),
                 "a well-formed uuid from the API is fine")
        T.expect(!WebUsageAPI.isUUID("../../admin"),
                 "a path fragment must never reach the URL the session key is sent with")
        T.expect(!WebUsageAPI.isUUID(""), "an empty value is not an organization")
    }

    // MARK: - Transport hardening

    T.test("the credentialed session keeps nothing on disk and accepts no cookies") {
        let config = UsageTransport.shared.configuration
        T.expect(config.urlCache == nil, "responses carrying account data must not be cached to disk")
        T.expect(config.httpCookieStorage == nil, "no process-wide cookie jar")
        T.expect(!config.httpShouldSetCookies, "cookies are set by hand, per request, and never stored")
        T.equal(config.requestCachePolicy, .reloadIgnoringLocalCacheData, "always ask the server")
    }

    T.test("session key normalization strips a pasted cookie header") {
        T.equal(SessionKeyStore.normalize("sessionKey=sk-ant-sid-abc; other=1"), "sk-ant-sid-abc",
                "a whole cookie header yields just the key")
        T.expect(!SessionKeyStore.looksValid("hunter2"), "an obvious non-key is rejected before a round trip")
    }
}
