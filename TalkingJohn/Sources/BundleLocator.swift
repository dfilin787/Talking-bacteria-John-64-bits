import Foundation

enum BundleLocator {

    private static var cache: [String: URL] = [:]
    private static var missing: Set<String> = []
    private static var indexed = false
    private static let lock = NSLock()

    private static var directories: [String: URL] = [:]

    private static func buildIndex() {
        guard !indexed else { return }
        indexed = true
        let root = Bundle.main.bundleURL
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let rootPath = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }
            var relative = url.standardizedFileURL.path
            if relative.hasPrefix(rootPath) {
                relative = String(relative.dropFirst(rootPath.count))
            }
            relative = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if relative.isEmpty { continue }

            if directories[relative] == nil {
                directories[relative] = url
            }
        }
    }

    static func directory(_ relativePath: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }

        let key = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let hit = cache[key] { return hit }
        if missing.contains(key) { return nil }

        let parts = key.split(separator: "/").map(String.init)
        if let last = parts.last, parts.count > 1 {
            let subdirectory = parts.dropLast().joined(separator: "/")
            if let url = Bundle.main.url(forResource: last, withExtension: nil, subdirectory: subdirectory) {
                cache[key] = url
                return url
            }
        }

        buildIndex()
        if let url = directories[key] {
            cache[key] = url
            return url
        }

        if let match = directories.first(where: { $0.key.hasSuffix("/" + key) })?.value {
            cache[key] = match
            return match
        }
        missing.insert(key)
        return nil
    }

    static func file(directory: String, name: String, extension ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: directory) {
            return url
        }
        guard let dir = self.directory(directory) else { return nil }
        let candidate = dir.appendingPathComponent(name).appendingPathExtension(ext)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}
