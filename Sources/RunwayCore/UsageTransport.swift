import Foundation

/// The `URLSession` both transports use, and the redirect policy that protects
/// the credentials they carry.
///
/// `URLSession.shared` is the wrong tool for credentialed requests: it keeps a
/// persistent on-disk `URLCache` (so responses land unencrypted on disk) and a
/// process-wide cookie store that would attach cookies alongside our own header.
/// An ephemeral configuration with caching and cookies switched off carries
/// nothing between launches.
public enum UsageTransport {
    /// Redirect guard. `URLSession` strips a manually set `Authorization`
    /// header across origins, but it copies every *other* header — including a
    /// hand-built `Cookie` — onto the redirected request. Neither endpoint has
    /// any business redirecting, so refuse rather than forward a bearer
    /// credential to a host we didn't choose.
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let guardDelegate = RedirectGuard()

    public static let shared: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCredentialStorage = nil
        return URLSession(configuration: config, delegate: guardDelegate, delegateQueue: nil)
    }()
}
