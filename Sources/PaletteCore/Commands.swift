import Foundation

/// One `[[shortcut]]` row: a catalogue command and the key that runs it.
/// An empty `keys` is the explicit "unbound" state Settings writes when the
/// user clears a command, so the choice survives a round trip.
public struct ShortcutBinding: Sendable, Equatable {
    public var command: String
    public var keys: String

    public init(command: String, keys: String = "") {
        self.command = command
        self.keys = keys
    }
}

/// A command that can be given a global shortcut. Provider entries are built
/// from the live registry so a new provider is bindable without a code change.
public struct CatalogCommand: Identifiable, Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case provider(trigger: String)
        case app(AppCommand)
    }

    public enum AppCommand: String, Sendable, Equatable, CaseIterable {
        case settings
        case reload
        case quit
        case toggleLauncher = "toggle-launcher"
    }

    public var id: String
    public var title: String
    public var group: String
    public var action: Action

    public init(id: String, title: String, group: String, action: Action) {
        self.id = id
        self.title = title
        self.group = group
        self.action = action
    }
}

public enum CommandCatalog {
    public struct ProviderEntry: Sendable, Equatable {
        public var id: String
        public var trigger: String?

        public init(id: String, trigger: String?) {
            self.id = id
            self.trigger = trigger
        }
    }

    public static let providerGroup = "Providers"
    public static let appGroup = "App"

    /// App commands are fixed; capture keys belong to the nine built-ins, so
    /// they are deliberately not duplicated here.
    public static let appCommands: [CatalogCommand] = [
        CatalogCommand(
            id: "app.settings",
            title: "Open Settings",
            group: appGroup,
            action: .app(.settings)
        ),
        CatalogCommand(
            id: "app.reload",
            title: "Reload Configuration",
            group: appGroup,
            action: .app(.reload)
        ),
        CatalogCommand(
            id: "app.toggle-launcher",
            title: "Toggle Launcher",
            group: appGroup,
            action: .app(.toggleLauncher)
        ),
        CatalogCommand(
            id: "app.quit",
            title: "Quit Palette",
            group: appGroup,
            action: .app(.quit)
        ),
    ]

    /// Providers first, in registry order, then the fixed app commands.
    /// Providers without a trigger cannot be addressed, so they are skipped.
    public static func commands(providers: [ProviderEntry], prefix: String = "/") -> [CatalogCommand] {
        var result: [CatalogCommand] = []
        for provider in providers {
            guard let trigger = provider.trigger?
                .trimmingCharacters(in: .whitespaces), !trigger.isEmpty else { continue }
            result.append(CatalogCommand(
                id: "provider.\(provider.id)",
                title: "Open \(prefix)\(trigger)",
                group: providerGroup,
                action: .provider(trigger: trigger)
            ))
        }
        return result + appCommands
    }
}
