import Foundation
import PaletteCore
import PalettePlatform
import PaletteProviders

public enum ManifestProviderFactory {
    public static func make(
        manifest: ProviderManifest,
        configuration: PaletteConfig,
        launcher: LauncherService,
        host: HostBridge,
        diagnostics: inout [Diagnostic]
    ) -> (any PaletteProvider)? {
        if manifest.engine == "paths", let paths = manifest.paths {
            let scope = configuration.scopes[paths.scope] ?? {
                if paths.scope == "home" { return Scope.home }
                diagnostics.append(Diagnostic(
                    .warning,
                    "Provider '\(manifest.id)' uses unknown scope '\(paths.scope)'; using projects.",
                    source: "providers"
                ))
                return Scope.projects
            }()
            let config = PathsProviderConfiguration(
                id: manifest.id,
                name: manifest.name,
                trigger: manifest.trigger,
                global: manifest.global,
                icon: manifest.icon,
                keywords: manifest.keywords,
                priority: manifest.priority,
                kind: paths.kind,
                scopeName: paths.scope,
                openWith: paths.openWith == "editor" ? configuration.editorOpenWith : paths.openWith,
                secondary: paths.secondary,
                maxResults: paths.maxResults,
                terminalApp: configuration.terminalApp,
                freeform: paths.freeform
            )
            return PathsProvider(configuration: config, scope: scope, launcher: launcher)
        }

        if !manifest.command.isEmpty {
            return ExternalProvider(manifest: manifest, host: host)
        }

        diagnostics.append(Diagnostic(.warning, "Provider '\(manifest.id)' has no runnable engine.", source: "providers"))
        return nil
    }
}
