import Foundation
import PaletteCore
import TOMLKit

/// Rewrites bundled theme files with the contrast repair the app applies at
/// load time, so the files, the picker swatches and the live theme agree.
///
///     swift run ThemeRepair Resources/Themes
///     swift run ThemeRepair --builtins
///
/// `--builtins` prints the repaired palette of every compiled-in theme so the
/// hard-coded sources can be updated to match.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func ratio(_ value: Double) -> String {
    String(format: "%.2f", value)
}

func values(for report: ThemeContrastReport) -> [String: String] {
    var result: [String: String] = [:]
    for change in report.changes {
        result[change.field.contains(".") ? change.field : "palette.\(change.field)"] = change.repaired
    }
    return result
}

func rewrite(_ text: String, values: [String: String]) -> String {
    guard !values.isEmpty else { return text }
    var section = ""
    var lines = text.components(separatedBy: "\n")
    for index in lines.indices {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
            section = String(trimmed.dropFirst().dropLast())
            continue
        }
        guard let equals = line.firstIndex(of: "=") else { continue }
        let key = line[..<equals].trimmingCharacters(in: .whitespaces)
        let fullKey = section.isEmpty ? key : "\(section).\(key)"
        guard let newValue = values[fullKey] else { continue }
        guard let open = line[equals...].firstIndex(of: "\""),
              let close = line[line.index(after: open)...].firstIndex(of: "\"") else { continue }
        lines[index] = String(line[..<open]) + "\"" + newValue + "\"" + String(line[line.index(after: close)...])
    }
    return lines.joined(separator: "\n")
}

func printPalette(_ palette: ThemePalette) {
    print("""
    [palette]
    bg = "\(palette.bg)"
    surface = "\(palette.surface)"
    elevated = "\(palette.elevated)"
    fg = "\(palette.fg)"
    fg_muted = "\(palette.fgMuted)"
    accent = "\(palette.accent)"
    accent_fg = "\(palette.accentFg)"
    selection_bg = "\(palette.selectionBg)"
    selection_fg = "\(palette.selectionFg)"
    match_fg = "\(palette.matchFg)"
    border = "\(palette.border)"
    separator = "\(palette.separator)"
    danger = "\(palette.danger)"
    warning = "\(palette.warning)"
    success = "\(palette.success)"
    info = "\(palette.info)"
    badge_bg = "\(palette.badgeBg)"
    badge_fg = "\(palette.badgeFg)"
    """)
}

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "--builtins" {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("palette-repair-\(UUID().uuidString)", isDirectory: true)
    for name in ThemeLoader.builtinNames {
        let theme = ThemeLoader.load(name: name, themesDirectory: directory).theme
        print("# \(name) — \(theme.name)")
        printPalette(theme.palette)
        if let fg = theme.states.selected.fg {
            print("states.selected.fg = \"\(fg)\"")
        }
        print("")
    }
    exit(0)
}

guard let directoryPath = arguments.first else {
    fail("usage: ThemeRepair <themes-directory> | --builtins")
}

let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension == "toml" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
guard !files.isEmpty else { fail("no .toml files in \(directoryPath)") }

var counts: [String: Int] = [:]
var worst = (ratio: Double.greatestFiniteMagnitude, label: "")
var maxHue = 0.0
var changedFiles = 0

for file in files {
    guard let text = try? String(contentsOf: file, encoding: .utf8),
          let table = try? TOMLTable(string: text) else {
        FileHandle.standardError.write(Data("skipped \(file.lastPathComponent): not valid TOML\n".utf8))
        continue
    }
    var diagnostics: [Diagnostic] = []
    let base: Theme = table.str("appearance")?.lowercased() == "light" ? .defaultLight : .defaultDark
    var theme = ThemeLoader.parse(
        table,
        name: file.deletingPathExtension().lastPathComponent,
        base: base,
        diagnostics: &diagnostics
    )
    let report = ThemeContrastRepair.repair(&theme)
    guard !report.changes.isEmpty else { continue }
    let rewritten = rewrite(text, values: values(for: report))
    guard rewritten != text else { continue }
    do {
        try rewritten.write(to: file, atomically: true, encoding: .utf8)
    } catch {
        fail("could not write \(file.path): \(error)")
    }
    changedFiles += 1
    for change in report.changes {
        counts[change.field, default: 0] += 1
        if change.before < worst.ratio {
            worst = (change.before, "\(file.lastPathComponent) \(change.field) \(change.original)")
        }
        maxHue = max(maxHue, change.hueShift)
    }
}

print("changed \(changedFiles) of \(files.count) files")
for field in counts.keys.sorted() {
    print("  \(field): \(counts[field] ?? 0)")
}
if changedFiles > 0 {
    print("worst original: \(worst.label) at \(ratio(worst.ratio)):1")
    print("max hue shift: \(ratio(maxHue))°")
}
