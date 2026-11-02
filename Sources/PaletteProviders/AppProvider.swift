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

    public init(index: AppIndex, launcher: LauncherService) {
        self.index = index
        self.launcher = launcher
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
            }
            actions.append(PaletteAction(id: "copy-path", title: "Copy Path", kind: .copyText, value: .text(app.path)))
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
        if case .text(let path) = action.value {
            await MainActor.run { launcher.activateApp(path: path) }
        }
    }
}
