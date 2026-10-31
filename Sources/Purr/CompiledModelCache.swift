import Foundation

// Core ML compiles each model for this Mac on its first load and keeps the
// result in Purr's Caches folder, apart from the model's own files, so
// deleting a model leaves its compiled copy behind. Core ML has no API to
// remove it, and the layout is undocumented: a folder per macOS build, each
// holding a folder per compiled model.
enum CompiledModelCache {
    private static var directory: URL? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("com.apple.e5rt.e5bundlecache", isDirectory: true)
    }

    static func removeAll() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    // A compiled GPU graph records the path of the model it came from, so the
    // folders naming `modelFolder` can go. The rest record no path and stay
    // until macOS clears the cache.
    static func removeCopies(of modelFolder: URL) {
        guard let directory else { return }
        let fm = FileManager.default
        let marker = Data((modelFolder.path + "/").utf8)
        for build in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            for entry in (try? fm.contentsOfDirectory(at: build, includingPropertiesForKeys: nil)) ?? []
            where names(marker, in: entry) {
                try? fm.removeItem(at: entry)
            }
        }
    }

    private static func names(_ marker: Data, in entry: URL) -> Bool {
        guard let files = FileManager.default.enumerator(at: entry, includingPropertiesForKeys: nil) else {
            return false
        }
        return files.contains { file in
            guard let file = file as? URL, file.pathExtension == "mpsgraph",
                let data = try? Data(contentsOf: file, options: .alwaysMapped)
            else { return false }
            return data.range(of: marker) != nil
        }
    }
}
