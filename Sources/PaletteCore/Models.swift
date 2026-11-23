import Foundation

/// A visual hint attached to a row. The host decides how to draw it.
public enum IconSpec: Equatable, Sendable, Codable {
    case symbol(String)
    case file(String)
    case url(String)
    case base64(String)
}

public enum ActionKind: String, Equatable, Sendable, CaseIterable, Codable {
    case openPath = "open_path"
    case openPathWith = "open_path_with"
    case openURL = "open_url"
    case reveal
    case copyText = "copy_text"
    case pasteText = "paste_text"
    case copyImage = "copy_image"
    case pasteImage = "paste_image"
    case copyFiles = "copy_files"
    case pasteFiles = "paste_files"
    case run
    case custom
}

public enum ActionValue: Equatable, Sendable, Codable {
    case none
    case text(String)
    case object([String: String])
    case list([String])

    public var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    public var object: [String: String]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var list: [String]? {
        if case .list(let value) = self { return value }
        return nil
    }
}

public struct PaletteAction: Identifiable, Equatable, Sendable, Codable {
    public var id: String
    public var title: String
    public var kind: ActionKind
    public var value: ActionValue
    public var concealed: Bool
    public var clearAfterMs: Int?
    public var shortcut: String?

    public init(
        id: String,
        title: String,
        kind: ActionKind,
        value: ActionValue = .none,
        concealed: Bool = false,
        clearAfterMs: Int? = nil,
        shortcut: String? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.value = value
        self.concealed = concealed
        self.clearAfterMs = clearAfterMs
        self.shortcut = shortcut
    }
}

/// Optional rich preview data for a row. Hosts may ignore it; Palette renders it
/// in the clipboard window and any other view that opts in.
public enum ItemPreview: Equatable, Sendable, Codable {
    case text(String)
    case image(base64: String, width: Int, height: Int)
    case files(paths: [String])
    /// A document on disk, rendered with QuickLook. `kind` is a hint for the
    /// host: pdf, html, markdown, text or image.
    case document(url: String, kind: String)
}

public struct PaletteItem: Identifiable, Equatable, Sendable, Codable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var icon: IconSpec?
    public var badge: String?
    public var group: String?
    public var accent: String?
    /// A provider-supplied score hint, added to the host's match score.
    public var score: Double
    public var actions: [PaletteAction]
    public var preview: ItemPreview?
    public var providerID: String
    public var providerName: String?

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        icon: IconSpec? = nil,
        badge: String? = nil,
        group: String? = nil,
        accent: String? = nil,
        score: Double = 0,
        actions: [PaletteAction] = [],
        preview: ItemPreview? = nil,
        providerID: String,
        providerName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.badge = badge
        self.group = group
        self.accent = accent
        self.score = score
        self.actions = actions
        self.preview = preview
        self.providerID = providerID
        self.providerName = providerName
    }

    /// The id used for frecency and selection preservation across refreshes.
    public var stableID: String { "\(providerID):\(id)" }

    public var primaryAction: PaletteAction? {
        actions.first
    }

    public var secondaryAction: PaletteAction? {
        actions.dropFirst().first
    }
}

public struct SearchRequest: Sendable {
    public var text: String
    public var terms: [String]
    public var limit: Int
    public var isBound: Bool

    public init(text: String, terms: [String]? = nil, limit: Int = 20, isBound: Bool = true) {
        self.text = text
        self.terms = terms ?? text.split(whereSeparator: \.isWhitespace).map(String.init)
        self.limit = limit
        self.isBound = isBound
    }
}

/// Providers that answer the same trigger family share one rail row and a
/// secondary strip, e.g. Bitwarden's `bw`/`bwu`/`bwt`/`bwn`/`bwo`.
public struct ProviderGroup: Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var order: Int

    public init(id: String, name: String, order: Int = 0) {
        self.id = id
        self.name = name
        self.order = order
    }
}

public struct ProviderDescriptor: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var trigger: String?
    public var isGlobal: Bool
    public var priority: Int
    public var icon: String?
    public var keywords: [String]
    public var group: ProviderGroup?
    /// Short label for the group strip; falls back to `name`.
    public var shortName: String?

    public init(
        id: String,
        name: String,
        trigger: String? = nil,
        isGlobal: Bool = false,
        priority: Int = 0,
        icon: String? = nil,
        keywords: [String] = [],
        group: ProviderGroup? = nil,
        shortName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.isGlobal = isGlobal
        self.priority = priority
        self.icon = icon
        self.keywords = keywords
        self.group = group
        self.shortName = shortName
    }
}

public struct ProviderRailChild: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var trigger: String
    public var icon: String?

    public init(id: String, title: String, trigger: String, icon: String? = nil) {
        self.id = id
        self.title = title
        self.trigger = trigger
        self.icon = icon
    }
}

public struct ProviderRailEntry: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var icon: String?
    public var trigger: String?
    /// Set when the entry opens one provider without a prefix, such as Apps.
    public var scopeProviderID: String?
    public var children: [ProviderRailChild]

    public var isGroup: Bool { !children.isEmpty }

    public init(
        id: String,
        title: String,
        icon: String? = nil,
        trigger: String? = nil,
        scopeProviderID: String? = nil,
        children: [ProviderRailChild] = []
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.trigger = trigger
        self.scopeProviderID = scopeProviderID
        self.children = children
    }
}

/// Everything and Apps, then one row per group, then every ungrouped provider.
public enum ProviderRail {
    public static let everythingID = "everything"
    public static let appsID = "apps"

    public static func groupEntryID(_ groupID: String) -> String { "group:\(groupID)" }

    public static func entries(for descriptors: [ProviderDescriptor]) -> [ProviderRailEntry] {
        var entries: [ProviderRailEntry] = [
            ProviderRailEntry(id: everythingID, title: "Everything", icon: "symbol:square.grid.2x2"),
            ProviderRailEntry(
                id: appsID,
                title: "Apps",
                icon: descriptors.first(where: { $0.id == appsID })?.icon ?? "symbol:app",
                scopeProviderID: appsID
            ),
        ]

        var groupsByID: [String: ProviderGroup] = [:]
        var groupOrder: [String] = []
        var childrenByGroup: [String: [ProviderRailChild]] = [:]
        var ungrouped: [ProviderRailEntry] = []

        for descriptor in descriptors where descriptor.id != appsID {
            guard let trigger = descriptor.trigger else { continue }
            if let group = descriptor.group {
                if groupsByID[group.id] == nil {
                    groupsByID[group.id] = group
                    groupOrder.append(group.id)
                }
                childrenByGroup[group.id, default: []].append(ProviderRailChild(
                    id: descriptor.id,
                    title: descriptor.shortName ?? descriptor.name,
                    trigger: trigger,
                    icon: descriptor.icon
                ))
            } else {
                ungrouped.append(ProviderRailEntry(
                    id: descriptor.id,
                    title: descriptor.shortName ?? descriptor.name,
                    icon: descriptor.icon,
                    trigger: trigger
                ))
            }
        }

        // A group takes the place of its first member; `order` decides which
        // group comes first when several are present.
        let orderedGroups = groupOrder.enumerated().sorted { lhs, rhs in
            let left = groupsByID[lhs.element]?.order ?? 0
            let right = groupsByID[rhs.element]?.order ?? 0
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }
        for (_, groupID) in orderedGroups {
            guard let group = groupsByID[groupID],
                  let members = childrenByGroup[groupID],
                  let first = members.first else { continue }
            entries.append(ProviderRailEntry(
                id: groupEntryID(groupID),
                title: group.name,
                icon: first.icon,
                children: members
            ))
        }
        entries.append(contentsOf: ungrouped)
        return entries
    }

    /// The rail row that owns a provider: its group when it belongs to one.
    public static func railID(for providerID: String, in entries: [ProviderRailEntry]) -> String {
        entries.first { entry in
            entry.id == providerID || entry.children.contains { $0.id == providerID }
        }?.id ?? providerID
    }
}

public protocol PaletteProvider: AnyObject, Sendable {
    var descriptor: ProviderDescriptor { get }
    func search(_ request: SearchRequest) async throws -> [PaletteItem]
    func activate(_ item: PaletteItem, action: PaletteAction) async throws
}

public extension PaletteProvider {
    func activate(_ item: PaletteItem, action: PaletteAction) async throws {}
}

public enum ProviderError: LocalizedError, Equatable {
    case toolMissing(String)
    case failed(String)
    case timedOut
    case cancelled
    case unauthorized

    public var errorDescription: String? {
        switch self {
        case .toolMissing(let tool): return "\(tool) is not installed"
        case .failed(let message): return message
        case .timedOut: return "Provider timed out"
        case .cancelled: return "Provider cancelled"
        case .unauthorized: return "Permission required"
        }
    }
}

public enum DiagnosticLevel: String, Sendable, Equatable {
    case info, warning, error
}

public struct Diagnostic: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var level: DiagnosticLevel
    public var message: String
    public var source: String?

    public init(_ level: DiagnosticLevel, _ message: String, source: String? = nil) {
        self.level = level
        self.message = message
        self.source = source
    }
}

public enum PathKind: String, Sendable, Equatable {
    case files, directories, any
}

public enum PromptKind: String, Sendable, Equatable {
    case text
    case secureText = "secure_text"
    case confirm
}

/// Per-field rules the prompt applies while the user types, so a provider does
/// not have to accept bad input and reject it afterwards.
public enum PromptValidation: Sendable, Equatable {
    case none
    case branchName
}

/// Services the host exposes to providers that need UI or clipboard access.
public protocol HostBridge: AnyObject, Sendable {
    func prompt(kind: PromptKind, title: String, placeholder: String?) async -> String?
    func prompt(
        kind: PromptKind,
        title: String,
        placeholder: String?,
        validation: PromptValidation
    ) async -> String?
    func notify(_ message: String) async
    func copyToClipboard(_ text: String, concealed: Bool, clearAfterMs: Int?) async
    /// Like `notify`, but stays on screen until the next status replaces it.
    /// Used for work that can run longer than a toast.
    func beginProgress(_ message: String) async
}

public extension HostBridge {
    /// Hosts without inline validation accept the value unvalidated; providers
    /// still re-check it before acting.
    func prompt(
        kind: PromptKind,
        title: String,
        placeholder: String?,
        validation: PromptValidation
    ) async -> String? {
        await prompt(kind: kind, title: title, placeholder: placeholder)
    }

    /// Hosts that cannot keep a status fall back to a normal toast.
    func beginProgress(_ message: String) async {
        await notify(message)
    }
}

public struct WebApp: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var url: String
    public var createdAt: Date
    public var shortcut: String?

    public init(id: String, name: String, url: String, createdAt: Date, shortcut: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.createdAt = createdAt
        self.shortcut = shortcut
    }
}

public enum ClipboardKind: String, Equatable, Sendable {
    case text
    case image
    case files
}

public struct ClipboardEntry: Identifiable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var createdAt: Date
    public var pinned: Bool
    public var kind: ClipboardKind
    public var imageWidth: Int
    public var imageHeight: Int
    public var thumbnailPNG: Data?

    public init(
        id: String,
        text: String,
        createdAt: Date,
        pinned: Bool = false,
        kind: ClipboardKind = .text,
        imageWidth: Int = 0,
        imageHeight: Int = 0,
        thumbnailPNG: Data? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.pinned = pinned
        self.kind = kind
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.thumbnailPNG = thumbnailPNG
    }

    /// File entries keep their paths newline-separated in `text`.
    public var paths: [String] {
        kind == .files ? text.split(separator: "\n").map(String.init) : []
    }
}
