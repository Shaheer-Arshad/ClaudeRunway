import Foundation

// One-shot harness: fetch /api/oauth/usage and print the response shape.
// Redacts anything token-shaped so the output is safe to paste around.

let sem = DispatchSemaphore(value: 0)

func redact(_ s: String) -> String {
    var out = s
    for pattern in ["sk-ant-[A-Za-z0-9_-]+", "sk-[A-Za-z0-9_-]{20,}"] {
        out = out.replacingOccurrences(of: pattern, with: "<redacted>", options: .regularExpression)
    }
    return out
}

do {
    let token = try Keychain.accessToken()
    FileHandle.standardError.write("keychain: read token (\(token.count) chars)\n".data(using: .utf8)!)

    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.httpMethod = "GET"
    req.timeoutInterval = 10
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("ClaudeRunway/0.1", forHTTPHeaderField: "User-Agent")

    URLSession.shared.dataTask(with: req) { data, resp, err in
        defer { sem.signal() }
        if let err { print("ERROR: \(err.localizedDescription)"); return }
        let http = resp as? HTTPURLResponse
        print("HTTP \(http?.statusCode ?? -1)")
        // Rate-limit headers decide our whole polling strategy, so surface them.
        for (k, v) in (http?.allHeaderFields ?? [:]) {
            let key = "\(k)".lowercased()
            if key.contains("ratelimit") || key.contains("retry-after") || key == "date" {
                print("  \(k): \(v)")
            }
        }
        guard let data else { print("no body"); return }

        // Pretty-print so the bucket structure is readable at a glance.
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: pretty, encoding: .utf8) {
            print(redact(s))
        } else {
            print(redact(String(data: data, encoding: .utf8) ?? "<binary>"))
        }
    }.resume()

    sem.wait()
} catch {
    FileHandle.standardError.write("FAILED: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
