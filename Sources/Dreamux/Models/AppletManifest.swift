import Foundation
import CryptoKit

/// v1 bridge capabilities. Unknown manifest strings are tolerated on load
/// (a future Dreamux may define them) and surfaced via `unknownCapabilities`.
enum AppletCapability: String, CaseIterable, Sendable {
    case kv, fs, http, shell, notify
}

struct AppletManifest: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var slug: String
    /// SF Symbol name for the sidebar row / host header.
    var icon: String
    var description: String
    var requiresCapabilities: [String]
    var origin: Origin?
    /// Connection slots this applet declares it needs (bound to a `Connection`
    /// at run time). Non-optional, so old manifests without the key decode to
    /// `[]` via the custom `init(from:)` below rather than failing to decode.
    var requiresConnections: [ConnectionSlot]

    struct Origin: Codable, Equatable, Sendable {
        var id: UUID        // library applet id this was adopted from
        var hash: String    // AppletContentHash of the library folder at adopt time
        var adoptedAt: Date
    }

    init(id: UUID, name: String, slug: String, icon: String, description: String,
         requiresCapabilities: [String], origin: Origin?, requiresConnections: [ConnectionSlot] = []) {
        self.id = id
        self.name = name
        self.slug = slug
        self.icon = icon
        self.description = description
        self.requiresCapabilities = requiresCapabilities
        self.origin = origin
        self.requiresConnections = requiresConnections
    }

    /// Custom decode: every field decodes normally except `requiresConnections`,
    /// which is a non-optional array that would fail synthesized decoding on
    /// manifests written before this field existed. Read it as present-or-empty
    /// so old manifests on disk keep loading. `encode(to:)` stays synthesized —
    /// it still emits `requiresConnections` (defaulting to `[]`) for every
    /// manifest this app writes going forward.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        slug = try container.decode(String.self, forKey: .slug)
        icon = try container.decode(String.self, forKey: .icon)
        description = try container.decode(String.self, forKey: .description)
        requiresCapabilities = try container.decode([String].self, forKey: .requiresCapabilities)
        origin = try container.decodeIfPresent(Origin.self, forKey: .origin)
        requiresConnections = try container.decodeIfPresent([ConnectionSlot].self, forKey: .requiresConnections) ?? []
    }

    var grantedCapabilities: Set<AppletCapability> {
        Set(requiresCapabilities.compactMap(AppletCapability.init(rawValue:)))
    }
    var unknownCapabilities: [String] {
        requiresCapabilities.filter { AppletCapability(rawValue: $0) == nil }
    }

    private static let manifestFileName = "manifest.json"

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Decode `<folder>/manifest.json`; nil when missing/invalid (callers
    /// render a warning state, never crash). ISO-8601 dates.
    ///
    /// A decoded manifest whose slug isn't path-safe (`AppletSlug.isSafe`) is
    /// treated as invalid too: the slug is user-editable JSON and every data
    /// dir is built by appending it to a root (`.dreamux/appdata/<slug>`,
    /// `AppStudioData/<slug>`), so a hand-edited `"../evil"` would escape the
    /// data root. Rejecting it at this chokepoint makes a tampered folder an
    /// `invalidFolder` everywhere, consistently.
    static func load(from folderURL: URL) -> AppletManifest? {
        let fileURL = folderURL.appendingPathComponent(manifestFileName)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let decoded = try? makeDecoder().decode(AppletManifest.self, from: data),
              AppletSlug.isSafe(decoded.slug)
        else { return nil }
        return decoded
    }

    /// Write `manifest.json` (pretty, sorted keys, ISO-8601, atomic).
    func write(to folderURL: URL) throws {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let data = try AppletManifest.makeEncoder().encode(self)
        let fileURL = folderURL.appendingPathComponent(AppletManifest.manifestFileName)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// One applet on disk: manifest + where it lives. Identity is the manifest id.
struct Applet: Identifiable, Equatable, Sendable {
    let manifest: AppletManifest
    let folderURL: URL
    var id: UUID { manifest.id }
    var slug: String { manifest.slug }
    var isAdopted: Bool { manifest.origin != nil }
}

enum AppletContentHash {
    /// SHA-256 over the folder's regular files: sorted relative path +
    /// "\0" + contents, `.DS_Store` excluded. Deterministic across
    /// enumeration order. Empty/missing folder hashes the empty input.
    static func hash(of folderURL: URL) -> String {
        var hasher = SHA256()
        for relativePath in sortedRegularFileRelativePaths(in: folderURL) {
            let fileURL = folderURL.appendingPathComponent(relativePath)
            let contents = (try? Data(contentsOf: fileURL)) ?? Data()
            hasher.update(data: Data(relativePath.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: contents)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func sortedRegularFileRelativePaths(in folderURL: URL) -> [String] {
        let fileManager = FileManager.default
        // Default options (no .skipsHiddenFiles) so .DS_Store is visited and
        // explicitly filtered below, per the brief.
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }

        var relativePaths: [String] = []
        let basePath = folderURL.standardizedFileURL.path
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true else { continue }
            if fileURL.lastPathComponent == ".DS_Store" { continue }
            var path = fileURL.standardizedFileURL.path
            if path.hasPrefix(basePath) {
                path = String(path.dropFirst(basePath.count))
                if path.hasPrefix("/") { path.removeFirst() }
            }
            relativePaths.append(path)
        }
        return relativePaths.sorted()
    }
}

enum AppletSlug {
    /// "Expo Status!" → "expo-status" (lowercased, non-alphanumerics → "-",
    /// runs collapsed, trimmed; empty input → "applet").
    static func slugify(_ name: String) -> String {
        let lowered = name.lowercased()
        var result = ""
        result.reserveCapacity(lowered.count)
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "applet" : trimmed
    }

    /// Whether a slug is safe to append as a single path component: exactly
    /// `slugify`'s own output shape (non-empty, lowercase alphanumerics and
    /// single interior dashes). `slugify` is idempotent on that shape, so
    /// every slug the app ever generates passes; anything hand-edited into
    /// a manifest with "/", "\\", ".", ".." or other separators — or any
    /// string that could traverse out of a data root — does not.
    static func isSafe(_ slug: String) -> Bool {
        !slug.isEmpty && slug == slugify(slug)
    }

    /// First of base, base-2, base-3… not in `existing`.
    static func unique(_ base: String, existing: Set<String>) -> String {
        guard existing.contains(base) else { return base }
        var counter = 2
        while existing.contains("\(base)-\(counter)") {
            counter += 1
        }
        return "\(base)-\(counter)"
    }
}
