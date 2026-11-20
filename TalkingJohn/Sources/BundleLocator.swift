import Foundation

/// Поиск ресурсов в бандле.
///
/// XcodeGen подключает папки ассетов как folder reference, а Xcode может положить
/// их как в корень бандла, так и во вложенный каталог — точное место зависит от
/// версии и типа ссылки. Поэтому ищем по всему дереву, а результат кэшируем:
/// обход выполняется один раз, дальше это обычный словарь.
enum BundleLocator {

    private static var cache: [String: URL] = [:]
    private static var missing: Set<String> = []
    private static var indexed = false
    private static let lock = NSLock()

    /// Индекс всех каталогов бандла по относительному пути.
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
            // Первое вхождение выигрывает: корень бандла обходится раньше вложенных копий.
            if directories[relative] == nil {
                directories[relative] = url
            }
        }
    }

    /// Возвращает каталог по относительному пути, например "Animations/talk".
    static func directory(_ relativePath: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }

        let key = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let hit = cache[key] { return hit }
        if missing.contains(key) { return nil }

        // Быстрый путь: ресурс лежит ровно там, где ожидается.
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
        // Папка могла оказаться вложенной глубже: ищем по суффиксу пути.
        if let match = directories.first(where: { $0.key.hasSuffix("/" + key) })?.value {
            cache[key] = match
            return match
        }
        missing.insert(key)
        return nil
    }

    /// Файл внутри каталога ресурсов, например ("Sounds", "laugh", "wav").
    static func file(directory: String, name: String, extension ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: directory) {
            return url
        }
        guard let dir = self.directory(directory) else { return nil }
        let candidate = dir.appendingPathComponent(name).appendingPathExtension(ext)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}