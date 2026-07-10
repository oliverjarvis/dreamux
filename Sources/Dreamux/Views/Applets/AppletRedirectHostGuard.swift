import Foundation

/// Keeps a connection's credential from following an unsafe redirect.
///
/// Used ONLY for a `{connection}`-authenticated `http.fetch`: the initial
/// request already cleared `ConnectionAuthenticator.authorize`'s https-only /
/// exact-host allowlist, but `URLSession` follows 3xx redirects automatically
/// — so a redirect off the allowlisted host (or an https→http downgrade to the
/// SAME host, which URLSession won't strip a custom/`.query` credential from)
/// would carry the just-attached credential along with it, defeating the
/// "the token only goes to the right host, only over https" guarantee.
///
/// This `URLSessionTaskDelegate` re-checks every redirect target against the
/// SAME pure `ConnectionAuthenticator.isAllowedTarget` (T2) predicate — https
/// AND exact-host — that gates the initial send, and cancels any redirect that
/// fails it. Cancelling makes `URLSession` return the 3xx response itself as
/// the result, so the applet still sees the redirect — the credential simply
/// never follows it.
///
/// `@unchecked Sendable`: its only state is an immutable `[String]` and the
/// delegate callback arrives on the session's (background) delegate queue.
final class AppletRedirectHostGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let hosts: [String]

    init(hosts: [String]) {
        self.hosts = hosts
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, ConnectionAuthenticator.isAllowedTarget(url, hosts: hosts) else {
            // Off-allowlist, non-https (an https→http downgrade would leak the
            // credential over cleartext), or malformed target: refuse the
            // redirect so the credential stays put. URLSession then surfaces
            // the 3xx response as the fetch result.
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
