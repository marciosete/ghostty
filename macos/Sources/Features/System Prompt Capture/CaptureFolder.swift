import Foundation

/// Keeps a folder in step with a set of files, touching only what changed, so a file that
/// reads the same keeps its modification date and whatever watches it isn't disturbed.
enum CaptureFolder {
    /// Makes `directory` hold exactly `files`, by path relative to it: writes each file
    /// whose content differs from what is on disk, and removes files that are no longer
    /// among them, then any folder left empty. The folders in `keeping`, and hidden files
    /// such as Finder's `.DS_Store`, are left alone.
    static func sync(_ files: [String: Data], into directory: URL, keeping: Set<String> = []) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let kept = { (path: String) -> Bool in
            keeping.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        var folders: [String] = []
        for path in existingPaths(in: directory) where !kept(path) {
            let url = directory.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                folders.append(path)
            } else if files[path] == nil {
                try fileManager.removeItem(at: url)
            }
        }

        for (path, data) in files {
            let url = directory.appendingPathComponent(path)
            if let existing = try? Data(contentsOf: url), existing == data { continue }
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }

        // Deepest first, so a folder whose only content was an empty folder goes too.
        for path in folders.sorted(by: { $0.count > $1.count }) {
            let url = directory.appendingPathComponent(path)
            let contents = (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []
            if contents.allSatisfy({ $0.hasPrefix(".") }) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// Every file and folder under `directory` that isn't hidden, by path relative to it.
    private static func existingPaths(in directory: URL) -> [String] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(atPath: directory.path) else { return [] }
        return enumerator.compactMap { $0 as? String }.filter { path in
            !path.split(separator: "/").contains { $0.hasPrefix(".") }
        }
    }
}
