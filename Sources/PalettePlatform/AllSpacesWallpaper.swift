import Foundation

/// `NSWorkspace.setDesktopImageURL` only touches the Space that is active on
/// each display. macOS keeps the per-Space picture in a single store, so an
/// apply has to copy the chosen picture's entry to every Space as well.
public enum AllSpacesWallpaper {
    public static var storeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    /// Returns the number of Spaces rewritten, or nil when the store has no
    /// entry for this picture (nothing useful to copy).
    @discardableResult
    public static func spread(
        picture: URL,
        store: URL = storeURL,
        restart: () -> Void = restartAgent
    ) throws -> Int? {
        guard let data = try? Data(contentsOf: store),
              let rewritten = try rewrite(data, picturePath: picture.path) else { return nil }
        try rewritten.write(to: store, options: .atomic)
        restart()
        return count(in: rewritten)
    }

    /// Copies the Desktop entry that references `picturePath` to every Space
    /// and display. Pure, so tests run against a fixture store.
    public static func rewrite(_ data: Data, picturePath: String) throws -> Data? {
        guard var root = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else { return nil }
        let needle = Data("file://\(picturePath)".utf8)
        func isTarget(_ desktop: [String: Any]?) -> Bool {
            guard let choices = (desktop?["Content"] as? [String: Any])?["Choices"] as? [[String: Any]],
                  let configuration = choices.first?["Configuration"] as? Data else { return false }
            return configuration.range(of: needle) != nil
        }
        func desktop(in entry: [String: Any]) -> [String: Any]? {
            entry["Desktop"] as? [String: Any]
        }

        var source: [String: Any]?
        if let spaces = root["Spaces"] as? [String: Any] {
            for case let body as [String: Any] in spaces.values {
                let displays = body["Displays"] as? [String: Any] ?? [String: Any]()
                for case let entry as [String: Any] in displays.values {
                    if isTarget(desktop(in: entry)) { source = desktop(in: entry); break }
                }
                if source != nil { break }
            }
        }
        if source == nil, let displays = root["Displays"] as? [String: Any] {
            for case let entry as [String: Any] in displays.values where isTarget(desktop(in: entry)) {
                source = desktop(in: entry)
                break
            }
        }
        guard let source else { return nil }

        func apply(to entry: inout [String: Any]) {
            entry["Desktop"] = source
        }
        if var spaces = root["Spaces"] as? [String: Any] {
            for (space, body) in spaces {
                guard var body = body as? [String: Any] else { continue }
                var displays = body["Displays"] as? [String: Any] ?? [:]
                for (id, entry) in displays {
                    guard var entry = entry as? [String: Any] else { continue }
                    apply(to: &entry)
                    displays[id] = entry
                }
                body["Displays"] = displays
                spaces[space] = body
            }
            root["Spaces"] = spaces
        }
        if var displays = root["Displays"] as? [String: Any] {
            for (id, entry) in displays {
                guard var entry = entry as? [String: Any] else { continue }
                apply(to: &entry)
                displays[id] = entry
            }
            root["Displays"] = displays
        }
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    static func count(in data: Data) -> Int? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let spaces = root["Spaces"] as? [String: Any] else { return nil }
        return spaces.count
    }

    /// The agent caches the store at launch; restarting it makes the rewrite
    /// take effect without logging the user out.
    public static func restartAgent() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["WallpaperAgent"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
