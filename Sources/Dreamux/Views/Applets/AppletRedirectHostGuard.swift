import Foundation

/// Keeps a connection's credential from following a cross-host redirect.
///
/// Used ONLY for a `{connection}`-authenticated `http.fetch`: the initial
/// request already cleared `ConnectionAuthenticator.authorize`'s https-only /
/// exact-host allowlist, but `URLSession` follows 3xx redirects automatically
/// — so a redirect from an allowlisted host to an off-list one would carry the
/// just-attached credential along with it, defeating the whole "the token
/// can't be sent to the wrong host" guarantee.
///
/// This `URLSessionTaskDelegate` re-checks every redirect target against the
/// SAME pure `ConnectionAuthenticator.hostAllowed` (T2) the initial send used,
/// and cancels any redirect that leaves the allowlist. Cancelling makes
/// `URLSession` return the 3xx response itself as the result, so the applet
/// still sees the redirect — the credential simply never follows it.
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
        guard let url = request.url, ConnectionAuthenticator.hostAllowed(url, hosts: hosts) else {
            // Off-allowlist (or malformed) target: refuse the redirect so the
            // credential stays put. URLSession then surfaces the 3xx response
            // as the fetch result.
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
