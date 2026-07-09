import Foundation

/// The applet's persistent state: kv.json + files/, both under its data
/// dir. All ops are synchronous file IO (values are small); every path is
/// traversal-guarded.
struct AppletDataStore: Sendable {
    let dataDir: URL
    private let filesDir: URL
    private let kvFileURL: URL

    init(dataDir: URL) {
        self.dataDir = dataDir
        self.filesDir = dataDir.appendingPathComponent("files", isDirectory: true)
        self.kvFileURL = dataDir.appendingPathComponent("kv.json", isDirectory: false)
        try? FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
    }

    // MARK: - kv

    func kvGet(_ key: String) -> Any? {
        readKv()[key]
    }

    func kvSet(_ key: String, value: Any) throws {
        var kv = readKv()
        kv[key] = value
        guard JSONSerialization.isValidJSONObject(kv) else {
            throw AppletDataStoreError.invalidJSONValue(key)
        }
        try writeKv(kv)
    }

    func kvDelete(_ key: String) throws {
        var kv = readKv()
        kv.removeValue(forKey: key)
        try writeKv(kv)
    }

    func kvList() -> [String: Any] {
        readKv()
    }

    private func readKv() -> [String: Any] {
        guard let data = try? Data(contentsOf: kvFileURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any]
        else { return [:] }
        return dict
    }

    private func writeKv(_ kv: [String: Any]) throws {
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: kv,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: kvFileURL, options: .atomic)
    }

    // MARK: - fs

    /// files/<relative>, nil when the resolution escapes files/.
    func scopedFileURL(_ relative: String) -> URL? {
        let candidate = filesDir.appendingPathComponent(relative)
            .standardizedFileURL.resolvingSymlinksInPath()
        let resolvedRoot = filesDir.standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path == resolvedRoot.path
            || candidate.path.hasPrefix(resolvedRoot.path + "/")
        else { return nil }
        return candidate
    }

    func fsRead(_ relative: String) throws -> String {
        guard let url = scopedFileURL(relative) else {
            throw AppletDataStoreError.pathEscapesSandbox(relative)
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else {
            throw AppletDataStoreError.fileNotFound(relative)
        }
        return text
    }

    func fsWrite(_ relative: String, text: String) throws {
        guard let url = scopedFileURL(relative) else {
            throw AppletDataStoreError.pathEscapesSandbox(relative)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    func fsList(_ relative: String) throws -> [String] {
        guard let url = scopedFileURL(relative) else {
            throw AppletDataStoreError.pathEscapesSandbox(relative)
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: url.path)
        return entries.sorted()
    }

    func fsDelete(_ relative: String) throws {
        guard let url = scopedFileURL(relative) else {
            throw AppletDataStoreError.pathEscapesSandbox(relative)
        }
        try FileManager.default.removeItem(at: url)
    }
}

enum AppletDataStoreError: Error, LocalizedError {
    case invalidJSONValue(String)
    case pathEscapesSandbox(String)
    case fileNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSONValue(let key):
            return "value for \"\(key)\" is not JSON-serializable"
        case .pathEscapesSandbox(let path):
            return "\"\(path)\" escapes the applet's files/ sandbox"
        case .fileNotFound(let path):
            return "\"\(path)\" does not exist"
        }
    }
}
