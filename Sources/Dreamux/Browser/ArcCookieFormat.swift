import Foundation

/// Pure conversions for Arc/Chromium's on-disk cookie encoding. No I/O.
enum ArcCookieFormat {
    /// Seconds between 1601-01-01 (Windows FILETIME epoch) and 1970-01-01.
    private static let epochDelta = 11_644_473_600.0

    /// Chromium stores timestamps as microseconds since 1601-01-01 UTC.
    /// Returns nil for 0 (a session cookie).
    static func date(fromChromiumMicros micros: Int64) -> Date? {
        guard micros > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(micros) / 1_000_000.0 - epochDelta)
    }

    /// Chromium `samesite`: -1 unspecified, 0 none, 1 lax, 2 strict. None and
    /// unspecified carry no explicit `HTTPCookie` policy, so map to nil.
    static func sameSite(fromChromiumInt raw: Int) -> SameSitePolicy? {
        switch raw {
        case 1: return .lax
        case 2: return .strict
        default: return nil
        }
    }
}
