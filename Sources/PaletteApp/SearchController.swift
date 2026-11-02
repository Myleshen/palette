import AppKit
import Combine
import Foundation
import PaletteCore
import PalettePlatform
import PaletteRuntime

public struct PromptState: Identifiable, Equatable {
    public var id = UUID()
    public var kind: PromptKind
    public var title: String
    public var placeholder: String?
}

@MainActor
public final class SearchController: ObservableObject, HostBridge {
    @Published public var query = "" {
        didSet { queryDidChange() }
    }
    @Published public private(set) var items: [PaletteItem] = []
    @Published public var selectionIndex = 0
    @Published public private(set) var scopeLabel: String?
    @Published public private(set) var highlightTerms: [String] = []
    @Published public private(set) var isSearching = false
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var actionsMode = false
    @Published public private(set) var actionItems: [PaletteAction] = []
    private var actionsOwnerID: String?
    @Published public var actionIndex = 0
    @Published public private(set) var prompt: PromptState?
    @Published public var promptValue = ""
    @Published public private(set) var focusToken = 0
    /// Wider layout with a live preview pane; used by the clipboard hotkey.
    @Published public private(set) var previewEnabled = false
    @Published public var clipboardFilter: String?
    public var searchPosition: SearchPosition { configuration.searchPosition }

    public var panel: PanelController?
    public var onReload: (() -> Void)?
    public var onOpenConfig: (() -> Void)?
    public var onOpenProviders: (() -> Void)?
    public var onQuit: (() -> Void)?

    private(set) var registry: ProviderRegistry
    private(set) var configuration: PaletteConfig
    private let paths: PalettePaths
    private let store: PaletteStore
    private let launcher: LauncherService
    private let pasteboard: PasteboardService
    private let themeManager: ThemeManager
    private let clipboardMonitor: ClipboardMonitor?

    private var searchTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var promptContinuation: CheckedContinuation<String?, Never>?
    private var resetting = false
    private var hasShown = false

    public init(
        registry: ProviderRegistry,
        configuration: PaletteConfig,
        paths: PalettePaths,
        store: PaletteStore,
        launcher: LauncherService,
        pasteboard: PasteboardService,
        themeManager: ThemeManager,
        clipboardMonitor: ClipboardMonitor?
    ) {
        self.registry = registry
        self.configuration = configuration
        self.paths = paths
        self.store = store
        self.launcher = launcher
        self.pasteboard = pasteboard
        self.themeManager = themeManager
        self.clipboardMonitor = clipboardMonitor
    }

    public var selectedItem: PaletteItem? {
        guard items.indices.contains(selectionIndex) else { return nil }
        return items[selectionIndex]
    }

    public var isGridMode: Bool {
        configuration.appGrid
            && prompt == nil
            && !actionsMode
            && scopeLabel == nil
            && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !items.isEmpty
    }

    public var gridColumns: Int {
        configuration.appGridColumns
    }

    public func replace(registry: ProviderRegistry, configuration: PaletteConfig) {
        self.registry = registry
        self.configuration = configuration
        scheduleSearch()
    }

    // MARK: - Panel lifecycle

    public func panelDidShow() {
        focusToken += 1
        hasShown = true
        scheduleSearch()
    }

    /// The dedicated clipboard hotkey opens straight into `/clip`, with the
    /// wide preview layout and no typing required.
    public func openClipboard() {
        previewEnabled = true
        clipboardFilter = nil
        panel?.widthOverride = 880
        actionsMode = false
        actionItems = []
        query = "\(configuration.providerPrefix)clip "
        panelDidShow()
    }

    public func panelDidHide() {
        searchTask?.cancel()
        isSearching = false
        cancelPrompt()
        actionsMode = false
        actionItems = []
        if !query.isEmpty {
            resetting = true
            query = ""
            resetting = false
        }
        scopeLabel = nil
        highlightTerms = []
        previewEnabled = false
        panel?.widthOverride = nil
    }

    public func requestFocus() {
        focusToken += 1
    }

    /// Refresh the visible list when the clipboard monitor records a new item.
    public func clipboardDidChange() {
        guard !resetting, registry.parser.parse(query).providerID == "clip" else { return }
        scheduleSearch(debounce: false)
    }

    // MARK: - Searching

    private func queryDidChange() {
        guard !resetting else { return }
        if actionsMode {
            actionsMode = false
            actionItems = []
        }

        // Bound searches can take a moment (Bitwarden, external processes).
        // Show the target provider immediately instead of stale global rows.
        let parsed = registry.parser.parse(query)
        if parsed.isBound {
            items = []
            selectionIndex = 0
            actionIndex = 0
            highlightTerms = parsed.text
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .filter { !$0.isEmpty }
            if let providerID = parsed.providerID,
               let provider = registry.providers.first(where: { $0.descriptor.id == providerID }) {
                scopeLabel = provider.descriptor.name
            } else {
                scopeLabel = nil
            }
            updatePanelHeight()
        } else {
            scopeLabel = nil
        }
        scheduleSearch()
    }

    private func scheduleSearch(debounce: Bool = true) {
        searchTask?.cancel()
        let raw = query
        let pathQuery = registry.parser.parse(raw).isBound
        let delay: UInt64 = debounce && pathQuery ? 30_000_000 : (debounce ? 12_000_000 : 0)
        searchTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.performSearch(raw: raw)
        }
    }

    private func performSearch(raw: String) async {
        isSearching = true
        let result = await registry.search(raw: raw)
        guard !Task.isCancelled else { return }

        let previousID = selectedItem?.stableID
        let boosts = (try? await store.frecencyBoosts(for: result.items.map(\.stableID))) ?? [:]
        guard !Task.isCancelled else { return }
        let merged: [PaletteItem]
        if result.parsed.isBound {
            merged = result.items.map { item in
                var copy = item
                copy.score += boosts[item.stableID] ?? 0
                return copy
            }
        } else {
            merged = Ranking.merge(result.items, boosts: boosts)
        }

        // The empty-query screen is the app grid, so background providers
        // (Zellij sessions, pins aside) do not push apps out of view.
        let visible = (configuration.appGrid && !result.parsed.isBound
            && result.parsed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ? merged.filter { $0.providerID == "apps" || $0.providerID == "pins" }
            : merged

        items = visible
        highlightTerms = result.parsed.text
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
        if let previousID, let index = merged.firstIndex(where: { $0.stableID == previousID }) {
            selectionIndex = index
        } else {
            selectionIndex = 0
        }
        if actionsMode {
            if let owner = actionsOwnerID, items[selectionIndex].stableID != owner {
                actionsMode = false
                actionItems = []
                actionIndex = 0
            }
        } else {
            actionIndex = 0
        }
        isSearching = false

        if let providerID = result.parsed.providerID,
           let provider = registry.providers.first(where: { $0.descriptor.id == providerID }) {
            scopeLabel = provider.descriptor.name
        } else {
            scopeLabel = nil
        }

        if let diagnostic = result.diagnostics.first(where: { $0.level != .info }) {
            setStatus(diagnostic.message, duration: 6)
        }
        updatePanelHeight()
    }

    // MARK: - Keyboard

    public func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let keyCode = event.keyCode
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if prompt != nil {
            switch keyCode {
            case 53:
                cancelPrompt()
                return true
            case 36, 76:
                submitPrompt()
                return true
            default:
                return false
            }
        }

        if command {
            switch keyCode {
            case 36, 76:
                executeSecondary()
                return true
            case 40:
                toggleActions()
                return true
            case 15:
                onReload?()
                setStatus("Reloaded configuration", duration: 2)
                return true
            case 43:
                onOpenConfig?()
                panel?.hide()
                return true
            case 13:
                panel?.hide()
                return true
            case 123:
                panel?.hide()
                return true
            case 48:
                cycleScope()
                return true
            default:
                if let number = Int(characters), (1...9).contains(number) {
                    let index = number - 1
                    if items.indices.contains(index) {
                        selectionIndex = index
                        executePrimary()
                    }
                    return true
                }
            }
            return false
        }

        switch keyCode {
        case 125:
            moveSelection(by: isGridMode ? configuration.appGridColumns : 1)
            return true
        case 126:
            moveSelection(by: isGridMode ? -configuration.appGridColumns : -1)
            return true
        case 123, 124:
            if isGridMode, !actionsMode {
                moveSelection(by: keyCode == 123 ? -1 : 1)
                return true
            }
            return false
        case 36, 76:
            if actionsMode { executeAction() } else { executePrimary() }
            return true
        case 48:
            cycleTab(by: flags.contains(.shift) ? -1 : 1)
            return true
        case 53:
            if actionsMode {
                actionsMode = false
                actionItems = []
                updatePanelHeight()
            } else if !query.isEmpty {
                resetting = true
                query = ""
                resetting = false
                scheduleSearch(debounce: false)
            } else {
                panel?.hide()
            }
            return true
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        if actionsMode {
            guard !actionItems.isEmpty else { return }
            actionIndex = (actionIndex + delta + actionItems.count) % actionItems.count
            return
        }
        guard !items.isEmpty else { return }
        selectionIndex = (selectionIndex + delta + items.count) % items.count
    }

    private func completeTrigger() {
        cycleTab(by: 1)
    }

    // MARK: - Provider tabs

    public struct ProviderTab: Identifiable, Equatable {
        public var id: String
        public var title: String
        public var trigger: String?
        public var icon: String?
    }

    public var providerTabs: [ProviderTab] {
        var tabs: [ProviderTab] = [
            ProviderTab(id: "apps", title: "Apps", trigger: nil, icon: "square.grid.2x2"),
        ]
        for provider in registry.providers {
            guard let trigger = provider.descriptor.trigger else { continue }
            tabs.append(ProviderTab(
                id: provider.descriptor.id,
                title: provider.descriptor.name,
                trigger: trigger,
                icon: provider.descriptor.icon
            ))
        }
        return tabs
    }

    public var activeTabID: String {
        registry.parser.parse(query).providerID ?? "apps"
    }

    public func selectTab(_ id: String) {
        if id == "apps" {
            query = ""
            return
        }
        guard let provider = registry.providers.first(where: { $0.descriptor.id == id }),
              let trigger = provider.descriptor.trigger else { return }
        query = registry.parser.prefix + trigger + " "
    }

    public func cycleTab(by delta: Int) {
        guard !actionsMode else { return }
        let tabs = providerTabs
        guard tabs.count > 1 else { return }
        let current = tabs.firstIndex(where: { $0.id == activeTabID }) ?? 0
        let count = tabs.count
        let next = ((current + delta) % count + count) % count
        selectTab(tabs[next].id)
    }

    public var effectiveClipboardFilter: String? {
        let text = registry.parser.parse(query).text.lowercased()
        if text.hasPrefix("image") { return "image" }
        if text.hasPrefix("file") { return "files" }
        if text.hasPrefix("text") { return "text" }
        return nil
    }

    public func setClipboardFilter(_ kind: String?) {
        clipboardFilter = kind
        query = "/clip" + (kind.map { " " + $0 } ?? " ")
    }

    private func cycleScope() {
        let bound = registry.providers.filter { $0.descriptor.trigger != nil && !$0.descriptor.isGlobal }
        guard !bound.isEmpty else { return }
        let parser = registry.parser
        let current = parser.parse(query).providerID
        let index = bound.firstIndex(where: { $0.descriptor.id == current }) ?? -1
        let next = bound[(index + 1) % bound.count]
        guard let trigger = next.descriptor.trigger else { return }
        let text = parser.parse(query).text
        query = parser.prefix + trigger + (text.isEmpty ? " " : " " + text)
    }

    // MARK: - Activation

    public func select(_ index: Int) {
        guard actionsMode == false, items.indices.contains(index) else { return }
        selectionIndex = index
    }

    public func activate(_ index: Int) {
        select(index)
        executePrimary()
    }

    public func executePrimary() {
        guard let item = selectedItem, let action = item.primaryAction else { return }
        execute(item: item, action: action)
    }

    public func executeSecondary() {
        guard let item = selectedItem, let action = item.secondaryAction else {
            setStatus("No secondary action", duration: 2)
            return
        }
        execute(item: item, action: action)
    }

    public func toggleActions() {
        if actionsMode {
            actionsMode = false
            actionItems = []
            updatePanelHeight()
            return
        }
        guard let item = selectedItem else { return }
        var actions = item.actions
        let pinID = item.providerID == "pins" ? "unpin-item" : "pin-item"
        if !actions.contains(where: { $0.id == "pin-item" || $0.id == "unpin-item" }) {
            actions.append(PaletteAction(
                id: pinID,
                title: pinID == "pin-item" ? "Pin to Palette" : "Unpin from Palette",
                kind: .custom,
                value: .text(item.stableID)
            ))
        }
        actionsMode = true
        actionItems = actions
        actionsOwnerID = item.stableID
        actionIndex = 0
        updatePanelHeight()
    }

    public func executeAction() {
        guard actionsMode, actionItems.indices.contains(actionIndex), let item = selectedItem,
              actionsOwnerID == item.stableID else { return }
        let action = actionItems[actionIndex]
        actionsMode = false
        actionItems = []
        execute(item: item, action: action)
    }

    private func execute(item: PaletteItem, action: PaletteAction) {
        let isTransient = ["install", "login", "unlock", "add", "remove", "shortcut", "clear-shortcut", "pin-item", "unpin-item"].contains(action.id)
        Task { [weak self] in
            guard let self else { return }
            // Act first: the frecency write must not sit between Enter and the
            // window opening or the clipboard being written.
            await self.perform(item: item, action: action)
            if !isTransient {
                try? await self.store.recordUse(stableID: item.stableID, provider: item.providerID)
            }
        }
    }

    private func perform(item: PaletteItem, action: PaletteAction) async {
        do {
            switch action.kind {
            case .openPath:
                if let path = action.value.text {
                    // Hide first so Enter feels instant; launching the app can
                    // take longer than the animation.
                    panel?.hide(activatePrevious: false)
                    launcher.openPath(path)
                }

            case .openPathWith:
                guard let value = action.value.object, let path = value["path"] else {
                    setStatus("Action is missing a path", duration: 3)
                    return
                }
                let app = value["app"] ?? configuration.editorOpenWith
                panel?.hide(activatePrevious: false)
                try launcher.openPath(path, with: app)

            case .openURL:
                let object = action.value.object
                let url = object?["url"] ?? action.value.text
                guard let url else { return }
                panel?.hide(activatePrevious: false)
                launcher.openURL(url, with: object?["browser"])

            case .reveal:
                if let path = action.value.text {
                    panel?.hide(activatePrevious: false)
                    launcher.reveal(path)
                }

            case .copyText:
                if let text = action.value.text {
                    pasteboard.write(text: text, concealed: action.concealed, clearAfterMs: action.clearAfterMs ?? (action.concealed ? configuration.clipboard.clearAfterMs : nil))
                    panel?.hide()
                }

            case .pasteText:
                if let text = action.value.text {
                    if !pasteboard.isAccessibilityTrusted {
                        pasteboard.write(
                            text: text,
                            concealed: action.concealed,
                            clearAfterMs: action.clearAfterMs ?? (action.concealed ? configuration.clipboard.clearAfterMs : nil)
                        )
                        pasteboard.requestAccessibility()
                        setStatus("Copied — enable Accessibility to paste automatically.", duration: 5)
                        return
                    }
                    let previous = panel?.previousApplication
                    panel?.hide(activatePrevious: false)
                    _ = pasteboard.paste(
                        text: text,
                        concealed: action.concealed,
                        into: previous
                    )
                }

            case .copyImage:
                if let id = action.value.text, let image = try await store.clipboardImage(id: id) {
                    pasteboard.write(image: image, concealed: action.concealed, clearAfterMs: action.clearAfterMs)
                    panel?.hide()
                }

            case .pasteImage:
                if let id = action.value.text, let image = try await store.clipboardImage(id: id) {
                    if !pasteboard.isAccessibilityTrusted {
                        pasteboard.write(image: image, concealed: action.concealed, clearAfterMs: action.clearAfterMs)
                        pasteboard.requestAccessibility()
                        setStatus("Copied — enable Accessibility to paste automatically.", duration: 5)
                        return
                    }
                    let previous = panel?.previousApplication
                    panel?.hide(activatePrevious: false)
                    _ = pasteboard.paste(image: image, concealed: action.concealed, into: previous)
                }

            case .copyFiles:
                if let paths = action.value.list, !paths.isEmpty {
                    pasteboard.write(files: paths, concealed: action.concealed, clearAfterMs: action.clearAfterMs)
                    panel?.hide()
                }

            case .pasteFiles:
                if let paths = action.value.list, !paths.isEmpty {
                    if !pasteboard.isAccessibilityTrusted {
                        pasteboard.write(files: paths, concealed: action.concealed, clearAfterMs: action.clearAfterMs)
                        pasteboard.requestAccessibility()
                        setStatus("Copied — enable Accessibility to paste automatically.", duration: 5)
                        return
                    }
                    let previous = panel?.previousApplication
                    panel?.hide(activatePrevious: false)
                    _ = pasteboard.paste(files: paths, into: previous)
                }

            case .run:
                if let argv = action.value.list, !argv.isEmpty {
                    try launcher.run(argv)
                    panel?.hide(activatePrevious: false)
                }

            case .custom:
                if action.id == "pin-item" {
                    try await store.pinItem(item)
                    setStatus("Pinned \(item.title)", duration: 2)
                    scheduleSearch(debounce: false)
                } else if action.id == "unpin-item" {
                    try await store.unpinItem(id: item.stableID)
                    setStatus("Unpinned \(item.title)", duration: 2)
                    scheduleSearch(debounce: false)
                } else {
                    try await registry.activate(item: item, action: action)
                    if keepsPanelOpen(item: item, action: action) {
                        scheduleSearch(debounce: false)
                    } else if action.id.contains("copy") {
                        panel?.hide()
                    } else {
                        panel?.hide(activatePrevious: false)
                    }
                }
            }
        } catch {
            setStatus(error.localizedDescription, duration: 5)
        }
    }

    private func keepsPanelOpen(item: PaletteItem, action: PaletteAction) -> Bool {
        switch item.providerID {
        case "theme", "clip":
            return true
        case "web":
            return ["add", "remove", "shortcut", "clear-shortcut"].contains(action.id)
        case "bw", "bwu", "bwt", "bwn", "bwo":
            return ["install", "login", "unlock"].contains(action.id)
        default:
            return false
        }
    }

    // MARK: - Host bridge

    public func prompt(kind: PromptKind, title: String, placeholder: String?) async -> String? {
        if promptContinuation != nil {
            promptContinuation?.resume(returning: nil)
            promptContinuation = nil
        }
        return await withCheckedContinuation { continuation in
            promptContinuation = continuation
            promptValue = ""
            prompt = PromptState(kind: kind, title: title, placeholder: placeholder)
            panel?.suppressAutoHide = true
            focusToken += 1
            updatePanelHeight()
        }
    }

    public func submitPrompt() {
        guard let prompt else { return }
        let value = prompt.kind == .confirm ? "true" : promptValue
        finishPrompt(value)
    }

    public func cancelPrompt() {
        guard prompt != nil else { return }
        finishPrompt(nil)
    }

    private func finishPrompt(_ value: String?) {
        let continuation = promptContinuation
        promptContinuation = nil
        prompt = nil
        promptValue = ""
        panel?.suppressAutoHide = false
        panel?.activatePreviousOnHide = true
        updatePanelHeight()
        continuation?.resume(returning: value)
        requestFocus()
    }

    public func notify(_ message: String) async {
        setStatus(message, duration: 4)
        await MainActor.run {
            if let panel, !panel.isVisible {
                NSApp.requestUserAttention(.informationalRequest)
            }
        }
    }

    public func copyToClipboard(_ text: String, concealed: Bool, clearAfterMs: Int?) async {
        pasteboard.write(
            text: text,
            concealed: concealed,
            clearAfterMs: clearAfterMs ?? (concealed ? configuration.clipboard.clearAfterMs : nil)
        )
        setStatus(concealed ? "Copied securely (clears automatically)" : "Copied to clipboard", duration: 2)
    }

    // MARK: - Presentation support

    public func setStatus(_ message: String, duration: TimeInterval? = nil) {
        statusTask?.cancel()
        statusMessage = message
        guard let duration else { return }
        statusTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if self?.statusMessage == message { self?.statusMessage = nil }
            }
        }
    }

    public func updatePanelHeight() {
        guard let panel else { return }
        let theme = themeManager.theme
        let row = CGFloat(theme.effectiveRowHeight)
        let spacing = CGFloat(theme.list.spacing)
        func rows(_ count: Int) -> CGFloat {
            let visible = CGFloat(min(max(count, 1), 8))
            return visible * row + max(0, visible - 1) * spacing + 8
        }
        var content: CGFloat
        if prompt != nil {
            content = 136
        } else if actionsMode {
            content = 38 + rows(actionItems.count)
        } else if items.isEmpty {
            content = 58
        } else if isGridMode {
            let columns = configuration.appGridColumns
            let visible = min(items.count, columns * 4)
            let gridRows = Int(ceil(Double(visible) / Double(columns)))
            content = CGFloat(gridRows) * 86 + CGFloat(max(0, gridRows - 1)) * 8 + 12
        } else {
            content = rows(items.count)
        }
        let footer = theme.footer.show ? CGFloat(28) : 0
        // Provider tab strip, plus the clipboard filter chips when previewing.
        let tabs = CGFloat(33 + (activeTabID == "clip" ? 27 : 0))
        if previewEnabled {
            // The preview pane sets the height; a few rows are always visible.
            content = max(content, 360)
            panel.widthOverride = 880
        }
        panel.setContentHeight(CGFloat(theme.search.height) + content + tabs + footer)
    }

    public func refreshTheme() {
        updatePanelHeight()
    }
}
