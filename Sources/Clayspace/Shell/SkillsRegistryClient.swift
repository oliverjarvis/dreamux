import Foundation

enum SkillsRegistryError: LocalizedError {
    case queryTooShort
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .queryTooShort:
            return "Search needs at least 2 characters."
        case .badStatus(let code):
            return "skills.sh search failed (HTTP \(code))."
        }
    }
}

/// Minimal client for the public skills.sh search endpoint — the same
/// one `skills find` uses. The full v1 registry API requires Vercel
/// OIDC auth, so search is the only endpoint we consume.
/// `CLAYSPACE_SKILLS_API_BASE` points this at a local stub during
/// tests/e2e, mirroring the `CLAYSPACE_*_BIN` overrides.
struct SkillsRegistryClient: Sendable {
    let baseURL: URL
    let session: URLSession

    init(baseURL: URL? = nil, session: URLSession = .shared) {
        if let baseURL {
            self.baseURL = baseURL
        } else if let override = ProcessInfo.processInfo.environment["CLAYSPACE_SKILLS_API_BASE"],
                  !override.isEmpty, let url = URL(string: override) {
            self.baseURL = url
        } else {
            self.baseURL = URL(string: "https://skills.sh")!
        }
        self.session = session
    }

    /// Search the registry. The endpoint rejects queries under 2 chars,
    /// so we pre-empt with a typed error the UI can treat as "idle".
    func search(query: String, limit: Int = 30) async throws -> [RegistrySkill] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { throw SkillsRegistryError.queryTooShort }

        var components = URLComponents(
            url: baseURL.appending(path: "api/search"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        let (data, response) = try await session.data(from: components.url!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw SkillsRegistryError.badStatus(status) }
        return try JSONDecoder().decode(SkillSearchResponse.self, from: data).skills
    }
}
