import Foundation
import PaletteCore
import PalettePlatform

public final class AppProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "apps",
        name: "Applications",
        trigger: nil,
        isGlobal: true,
        priority: 100,
        icon: "symbol:app"
    )

    private let index: AppIndex
    private let launcher: LauncherService
    private let bridge: HostBridge?

    public init(index: AppIndex, launcher: LauncherService, bridge: HostBridge? = nil) {
        self.index = index
        self.launcher = launcher
        self.bridge = bridge
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let apps = await index.applications()
        let ranked: [(AppRecord, Double)]
        if request.text.trimmingCharacters(in: .whitespaces).isEmpty {
            ranked = apps.map { ($0, 0) }
        } else {
            ranked = apps.compactMap { app in
                // Score fields separately: joining them lets a subsequence match
                // letters from unrelated fields (e.g. "Safari" -> "System Information").
                let fields = [app.name, app.bundleID ?? ""] + app.keywords
                let score = fields.compactMap { Ranking.score(query: request.text, candidate: $0) }.max()
                guard let score else { return nil }
                return (app, score)
            }.sorted { lhs, rhs in
                if abs(lhs.1 - rhs.1) > 0.001 { return lhs.1 > rhs.1 }
                return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
            }
        }

        return ranked.prefix(max(1, request.limit)).map { app, score in
            var actions: [PaletteAction] = [
                PaletteAction(id: "open", title: "Open", kind: .openPath, value: .text(app.path)),
                PaletteAction(id: "reveal", title: "Show in Finder", kind: .reveal, value: .text(app.path)),
            ]
            if let bundleID = app.bundleID {
                actions.append(PaletteAction(id: "copy-bundle-id", title: "Copy Bundle ID", kind: .copyText, value: .text(bundleID)))
                actions.append(PaletteAction(id: "quit-app", title: "Quit App", kind: .custom, value: .text(app.path)))
            }
            actions.append(PaletteAction(id: "copy-path", title: "Copy Path", kind: .copyText, value: .text(app.path)))
            if app.path.hasPrefix("/Applications/") || app.path.hasPrefix(NSHomeDirectory() + "/Applications/") {
                actions.append(PaletteAction(id: "uninstall-app", title: "Move App to Trash…", kind: .custom, value: .text(app.path)))
            }
            return PaletteItem(
                id: app.path,
                title: app.name,
                subtitle: app.bundleID,
                icon: .file(app.path),
                score: score,
                actions: actions,
                providerID: descriptor.id,
                providerName: descriptor.name
            )
        }
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        guard case .text(let path) = action.value else { return }
        switch action.id {
        case "quit-app":
            await MainActor.run { launcher.quitApp(path: path) }
        case "uninstall-app":
            guard let bridge else { return }
            guard await bridge.prompt(
                kind: .confirm,
                title: "Move \(item.title) to the Trash?",
                placeholder: nil
            ) != nil else { return }
            do {
                try await MainActor.run { try launcher.uninstallApp(path: path) }
                await bridge.notify("Moved \(item.title) to the Trash")
            } catch {
                await bridge.notify("Could not uninstall \(item.title): \(error.localizedDescription)")
            }
        default:
            await MainActor.run { launcher.activateApp(path: path) }
        }
    }
}
