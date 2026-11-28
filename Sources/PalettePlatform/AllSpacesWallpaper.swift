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

    /// Points every Space's picture entry at `picturePath`. Entries that are
    /// not file-backed (aerials, dynamic) are left alone. Pure, so tests run
    /// against a fixture store.
    public static func rewrite(_ data: Data, picturePath: String) throws -> Data? {
        guard var root = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else { return nil }

        func retarget(_ entry: inout [String: Any]) -> Bool {
            guard var desktop = entry["Desktop"] as? [String: Any],
                  var content = desktop["Content"] as? [String: Any],
                  var choices = content["Choices"] as? [[String: Any]],
                  var first = choices.first,
                  let blob = first["Configuration"] as? Data,
                  var configuration = try? PropertyListSerialization.propertyList(
                      from: blob, options: [], format: nil
                  ) as? [String: Any],
                  var url = configuration["url"] as? [String: Any],
                  let relative = url["relative"] as? String,
                  relative.hasPrefix("file://") else { return false }
            url["relative"] = "file://\(picturePath)"
            configuration["url"] = url
            first["Configuration"] = try? PropertyListSerialization.data(
                fromPropertyList: configuration, format: .binary, options: 0
            )
            choices[0] = first
            content["Choices"] = choices
            desktop["Content"] = content
            entry["Desktop"] = desktop
            return true
        }

        var changed = 0
        if var spaces = root["Spaces"] as? [String: Any] {
            for (space, body) in spaces {
                guard var body = body as? [String: Any] else { continue }
                var displays = body["Displays"] as? [String: Any] ?? [String: Any]()
                for (id, raw) in displays {
                    guard var entry = raw as? [String: Any] else { continue }
                    if retarget(&entry) {
                        displays[id] = entry
                        changed += 1
                    }
                }
                body["Displays"] = displays
                spaces[space] = body
            }
            root["Spaces"] = spaces
        }
        if var displays = root["Displays"] as? [String: Any] {
            for (id, raw) in displays {
                guard var entry = raw as? [String: Any] else { continue }
                if retarget(&entry) { displays[id] = entry }
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
