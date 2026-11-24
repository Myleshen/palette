import Foundation
import PaletteCore

/// Stages the contents of a Palette backup in a temporary directory. The
/// caller zips that directory. Kept out of the app target so the export
/// contract can be tested: config, themes, providers, history, the database
/// without clipboard text, and the clipboard image files that sit beside it.
public enum BackupExporter {
    /// Copies the user state into `temp` and returns the top-level names that
    /// made it. Creates `temp` if needed.
    public static func stage(paths: PalettePaths, into temp: URL) throws -> [String] {
        let manager = FileManager.default
        try manager.createDirectory(at: temp, withIntermediateDirectories: true)
        var included: [String] = []

        func copy(_ source: URL, as name: String) {
            guard manager.fileExists(atPath: source.path) else { return }
            if (try? manager.copyItem(at: source, to: temp.appendingPathComponent(name))) != nil {
                included.append(name)
            }
        }

        copy(paths.configFile, as: "config.toml")
        copy(paths.themesDir, as: "themes")
        copy(paths.providersDir, as: "providers")
        copy(paths.databaseFile, as: "palette.sqlite")
        for suffix in ["-wal", "-shm"] {
            copy(URL(fileURLWithPath: paths.databaseFile.path + suffix), as: "palette.sqlite" + suffix)
        }
        copy(paths.configDir.appendingPathComponent("ask-key.bin"), as: "ask-key.bin")
        copy(paths.configDir.appendingPathComponent("ask-keys.bin"), as: "ask-keys.bin")
        copy(paths.bookmarksFile, as: "bookmarks.toml")
        copy(paths.configDir.appendingPathComponent("commands.toml"), as: "commands.toml")
        copy(paths.configDir.appendingPathComponent("snippets.toml"), as: "snippets.toml")
        // Image bytes live outside SQLite now, so the archive must carry them.
        copy(paths.clipboardImagesDir, as: "clipboard")

        // Pasted text is the sensitive part of the clipboard history. Fold the
        // WAL into the copy, drop text rows, then vacuum so no deleted page
        // survives in the zip. Image and file rows stay.
        let database = temp.appendingPathComponent("palette.sqlite")
        if manager.fileExists(atPath: database.path) {
            let sqlite = Process()
            sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            sqlite.arguments = [
                database.path,
                "PRAGMA journal_mode=DELETE; DELETE FROM clipboard WHERE kind = 'text'; VACUUM;",
            ]
            try sqlite.run()
            sqlite.waitUntilExit()
            guard sqlite.terminationStatus == 0 else {
                throw NSError(domain: "PaletteBackup", code: Int(sqlite.terminationStatus))
            }
            for suffix in ["-wal", "-shm"] {
                try? manager.removeItem(at: URL(fileURLWithPath: database.path + suffix))
            }
        }

        let readme = """
        Palette backup
        ==============
        Included in this archive:
        \(included.map { "- \($0)" }.joined(separator: "\n"))

        ask-key.bin and ask-keys.bin hold API keys stored by Palette; they
        are encrypted. Everything else is plain text or a normal SQLite
        database. Clipboard history is included without its text entries.
        clipboard/ holds the image and file-icon files the database points at.
        """
        try readme.write(to: temp.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        return included
    }
}
