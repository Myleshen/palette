import AppKit
import Foundation
import PaletteCore
import PalettePlatform

/// Quick machine stats: disk, memory, load, battery and uptime, each copyable.
public final class StatsProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "stats",
        name: "System Stats",
        trigger: "stats",
        isGlobal: false,
        priority: 40,
        icon: "symbol:gauge",
        keywords: ["stats", "disk", "memory", "ram", "load", "cpu", "battery", "uptime", "space", "system"]
    )

    private let bridge: HostBridge
    /// Five shell calls per search; a few seconds of reuse keeps typing cheap.
    private let rowsCache = ShortCache<[PaletteItem]>(ttl: 3)

    public init(bridge: HostBridge) {
        self.bridge = bridge
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var items = await rows()
        guard !query.isEmpty else { return items }
        // Groups carry the words people type (`cpu`, `ram`), not just titles.
        items = items.filter {
            Ranking.score(query: query, candidate: "\($0.title) \($0.subtitle ?? "") \($0.group ?? "")") != nil
        }
        return items
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        guard let value = action.value.text else { return }
        await bridge.copyToClipboard(value, concealed: false, clearAfterMs: nil)
    }

    private func rows() async -> [PaletteItem] {
        if let cached = await rowsCache.get("rows") { return cached }
        let items = await withTaskGroup(of: PaletteItem?.self) { group in
            group.addTask { await Self.diskRow() }
            group.addTask { await Self.memoryRow() }
            group.addTask { await Self.loadRow() }
            group.addTask { await Self.batteryRow() }
            group.addTask { await Self.uptimeRow() }
            var items: [PaletteItem] = []
            for await item in group {
                if let item { items.append(item) }
            }
            return items.sorted { $0.score > $1.score }
        }
        await rowsCache.set(items, key: "rows")
        return items
    }

    // MARK: - Rows

    private static func diskRow() async -> PaletteItem? {
        guard let out = await run(["/bin/df", "-h", "/"]) else { return nil }
        let lines = out.split(separator: "\n")
        guard lines.count >= 2 else { return nil }
        let fields = lines[1].split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 4 else { return nil }
        let size = String(fields[1])
        let used = String(fields[2])
        let free = String(fields[3])
        return PaletteItem(
            id: "stats-disk",
            title: "Disk · \(free) free",
            subtitle: "\(used) used of \(size) on /",
            icon: .symbol("internaldrive"),
            group: "Storage",
            score: 9_000,
            actions: [PaletteAction(id: "copy", title: "Copy free space", kind: .custom, value: .text("\(free) free of \(size) on /"))],
            providerID: "stats",
            providerName: "System Stats"
        )
    }

    private static func memoryRow() async -> PaletteItem? {
        guard let out = await run(["/usr/bin/vm_stat"]) else { return nil }
        func pages(_ label: String) -> Double {
            let line = out.split(separator: "\n").first { $0.hasPrefix(label) }
            let digits = line?.split(separator: ":").last?.filter(\.isNumber) ?? ""
            return Double(digits) ?? 0
        }
        let pageSize = 16_384.0
        let free = pages("Pages free") * pageSize
        let inactive = pages("Pages inactive") * pageSize
        let wired = pages("Pages wired down") * pageSize
        let compressed = pages("Pages occupied by compressor") * pageSize
        let available = free + inactive
        return PaletteItem(
            id: "stats-memory",
            title: "Memory · \(format(available)) available",
            subtitle: "\(format(wired)) wired · \(format(compressed)) compressed",
            icon: .symbol("memorychip"),
            group: "Memory",
            score: 8_900,
            actions: [PaletteAction(id: "copy", title: "Copy memory usage", kind: .custom, value: .text("\(format(available)) available, \(format(wired)) wired, \(format(compressed)) compressed"))],
            providerID: "stats",
            providerName: "System Stats"
        )
    }

    private static func loadRow() async -> PaletteItem? {
        guard let out = await run(["/usr/sbin/sysctl", "-n", "vm.loadavg"]) else { return nil }
        let values = out.trimmingCharacters(in: CharacterSet(charactersIn: "{} \n"))
            .split(separator: " ")
            .map(String.init)
        guard values.count >= 3 else { return nil }
        return PaletteItem(
            id: "stats-load",
            title: "Load average \(values[0])",
            subtitle: "1m \(values[0]) · 5m \(values[1]) · 15m \(values[2])",
            icon: .symbol("cpu"),
            group: "CPU",
            score: 8_800,
            actions: [PaletteAction(id: "copy", title: "Copy load average", kind: .custom, value: .text(values.joined(separator: " ")))],
            providerID: "stats",
            providerName: "System Stats"
        )
    }

    private static func batteryRow() async -> PaletteItem? {
        guard let out = await run(["/usr/bin/pmset", "-g", "batt"]) else { return nil }
        let line = out.split(separator: "\n").last.map(String.init) ?? ""
        let percent = line.split(separator: "%").first?.split(separator: "\t").last.map(String.init) ?? ""
        let state = line.contains("AC Power") ? "on power" : (line.contains("charging") ? "charging" : "on battery")
        guard !percent.isEmpty else { return nil }
        return PaletteItem(
            id: "stats-battery",
            title: "Battery · \(percent)%",
            subtitle: state,
            icon: .symbol("battery.100"),
            group: "Power",
            score: 8_700,
            actions: [PaletteAction(id: "copy", title: "Copy battery status", kind: .custom, value: .text("Battery \(percent)%, \(state)"))],
            providerID: "stats",
            providerName: "System Stats"
        )
    }

    private static func uptimeRow() async -> PaletteItem? {
        guard let out = await run(["/usr/bin/uptime"]) else { return nil }
        guard let range = out.range(of: "up ") else { return nil }
        let rest = out[range.upperBound...].split(separator: ",").prefix(2).joined(separator: ",")
        let label = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return PaletteItem(
            id: "stats-uptime",
            title: "Uptime · \(label)",
            subtitle: "Since the last boot",
            icon: .symbol("clock.arrow.circlepath"),
            group: "System",
            score: 8_600,
            actions: [PaletteAction(id: "copy", title: "Copy uptime", kind: .custom, value: .text(label))],
            providerID: "stats",
            providerName: "System Stats"
        )
    }

    // MARK: - Helpers

    private static func run(_ argv: [String]) async -> String? {
        guard let result = try? await ProcessRunner.run(argv, timeout: 5), result.status == 0 else { return nil }
        let text = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func format(_ bytes: Double) -> String {
        let gigabytes = bytes / 1_073_741_824
        if gigabytes >= 1 { return String(format: "%.1f GB", gigabytes) }
        return String(format: "%.0f MB", bytes / 1_048_576)
    }
}
