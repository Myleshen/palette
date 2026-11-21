import AppKit
import Combine
import Foundation
import PaletteCore
import PalettePlatform
import PaletteProviders
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
    private var actionsOwner: PaletteItem?
    private var allActions: [PaletteAction] = []
    private var queryBeforeActions = ""
    @Published public var actionIndex = 0
    /// The rail has keyboard focus after a click; arrows move providers then,
    /// while the search field keeps the actual typing focus.
    @Published public var railFocused = false
    @Published public private(set) var prompt: PromptState?
    @Published public var promptValue = ""
    @Published public private(set) var focusToken = 0
    /// Wider layout with a live preview pane; used by the clipboard hotkey.
    @Published public private(set) var previewEnabled = false
    @Published public private(set) var previewFocused = false
    @Published public private(set) var scratchpadActive = false
    @Published public private(set) var scratchpadNoteID: String?
    @Published public var scratchpadTitle = ""
    @Published public private(set) var terminalActive = false
    @Published public private(set) var terminalInitialCommand: String?
    @Published public var scratchpadText = ""
    @Published public var clipboardFilter: String?
    public var searchPosition: SearchPosition { configuration.searchPosition }
    /// Per-invocation multiplexer session name (e.g. `ssh-host`); nil uses the
    /// configured session.
    private var terminalSessionName: String?
    public var terminalSession: TerminalSessionConfig {
        var session = configuration.terminalSession
        if let terminalSessionName { session.name = terminalSessionName }
        return session
    }

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

    /// The pane only exists when there is a row and that row has preview
    /// content; setup and empty rows are not worth widening the panel for.
    public var previewVisible: Bool {
        previewEnabled && !items.isEmpty && selectedItem?.preview != nil
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
    private var windowConfig: WindowConfig { configuration.window }

    public var previewLayout: PreviewPlacement {
        configuration.window.resolvedPreviewLayout(
            screenWidth: Double(screenSize.width),
            previewPanelWidth: configuration.window.previewWidth(for: screenSize)
        )
    }

    private var timerObserver: NSObjectProtocol?

    private var screenSize: CGSize {
        (PanelController.screenUnderPointer() ?? panel?.panel.screen)?.visibleFrame.size
            ?? CGSize(width: 1440, height: 900)
    }

    public func openClipboard() {
        previewEnabled = true
        clipboardFilter = nil
        updatePreviewWidth()
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
        // A fresh open starts at the top: dropping the list also drops the
        // scroll offset and any row restored by stableID.
        items = []
        selectionIndex = 0
        scopeLabel = nil
        highlightTerms = []
        previewEnabled = false
        previewFocused = false
        railFocused = false
        terminalActive = false
        terminalSessionName = nil
        panel?.suppressAutoHide = false
        panel?.widthOverride = nil
    }

    public func requestFocus() {
        focusToken += 1
    }

    /// Refresh the visible list when the clipboard monitor records a new item.
    /// Re-run the current query, used after a forced vault refresh.
    public func refreshResults() {
        scheduleSearch(debounce: false)
    }

    public func clipboardDidChange() {
        guard !resetting, registry.parser.parse(query).providerID == "clip" else { return }
        scheduleSearch(debounce: false)
    }

    // MARK: - Searching

    private func queryDidChange() {
        guard !resetting, !scratchpadActive else { return }
        if actionsMode {
            applyActionFilter()
            return
        }

        // Bound searches can take a moment (Bitwarden, external processes).
        // Show the target provider immediately instead of stale global rows.
        let parsed = registry.parser.parse(query)
        // Preview is useful wherever a row has something worth showing:
        // clipboard, snippets, and path/project providers.
        let previewProvider = ["clip", "snip", "recent", "neo", "neof", "proj", "shots", "cheat", "atlas"]
            .contains(parsed.providerID ?? "")
        if previewProvider {
            if !previewEnabled {
                previewEnabled = true
                updatePreviewWidth()
            }
        } else if previewEnabled {
            previewEnabled = false
            previewFocused = false
            panel?.suppressAutoHide = false
            clipboardFilter = nil
            panel?.widthOverride = nil
        }
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
        let delay: UInt64 = debounce && pathQuery ? 120_000_000 : (debounce ? 12_000_000 : 0)
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
        // `!keyword query` goes straight to a search engine; providers never
        // see it, and the list is the bang row (or the matching engines).
        if raw.trimmingCharacters(in: .whitespaces).hasPrefix("!") {
            let previousID = selectedItem?.stableID
            let rows = BangResolver.items(for: raw, engines: configuration.webSearchEngines)
            items = rows
            highlightTerms = raw.dropFirst()
                .split(whereSeparator: \.isWhitespace)
                .dropFirst()
                .map(String.init)
            if let previousID, let index = rows.firstIndex(where: { $0.stableID == previousID }) {
                selectionIndex = index
            } else {
                selectionIndex = 0
            }
            actionIndex = 0
            isSearching = false
            updatePanelHeight()
            return
        }
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

        // The empty-query screen is the app list: only apps and pinned items,
        // never unpinned web apps, sessions, or search suggestions.
        let isEmptySearch = !result.parsed.isBound
            && result.parsed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var visible: [PaletteItem]
        if isEmptySearch {
            // Pinned snapshots keep their original provider id (so their
            // normal actions still work); the unpin action marks them.
            let pins = merged.filter { item in
                item.actions.contains { $0.id == "unpin-item" }
            }
            let pinnedIDs = Set(pins.map(\.stableID))
            var apps = merged.filter {
                $0.providerID == "apps" && !pinnedIDs.contains($0.stableID)
            }
            switch configuration.appSort {
            case .alphabetical:
                apps.sort {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
            case .frequent:
                let counts = (try? await store.useCounts(for: apps.map(\.stableID))) ?? [:]
                apps.sort {
                    let lhs = counts[$0.stableID] ?? 0
                    let rhs = counts[$1.stableID] ?? 0
                    if lhs != rhs { return lhs > rhs }
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
            }
            visible = pins + apps
        } else {
            visible = merged
        }

        // Provider discovery belongs to plain searches only: typing "atlas"
        // should offer the Atlas source instead of a similarly named app.
        if !result.parsed.isBound {
            let providerRows = providerMatches(query: result.parsed.text)
            if !providerRows.isEmpty {
                visible = (visible + providerRows).sorted {
                    if $0.score != $1.score { return $0.score > $1.score }
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
            }
        }

        items = visible
        highlightTerms = result.parsed.text
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
        if let previousID, let index = visible.firstIndex(where: { $0.stableID == previousID }) {
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
        let option = flags.contains(.option)
        let control = flags.contains(.control)
        let keyCode = event.keyCode
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if terminalActive {
            if command, keyCode == 13 {
                closeTerminalPanel()
                panel?.hide(activatePrevious: false)
                return true
            }
            return false
        }

        if scratchpadActive {
            if keyCode == 53 {
                closeScratchpad(save: true)
                return true
            }
            if command, keyCode == 36 || keyCode == 76 {
                copyScratchpad()
                return true
            }
            if command, characters == "s" {
                closeScratchpad(save: true)
                return true
            }
            return false
        }

        if option, characters == "p", previewEnabled {
            previewFocused.toggle()
            panel?.suppressAutoHide = previewFocused
            updatePanelHeight()
            return true
        }
        if previewFocused {
            if keyCode == 53 {
                previewFocused = false
                panel?.suppressAutoHide = false
                updatePanelHeight()
                return true
            }
            if control {
                switch characters {
                case "j": postPreviewScroll(dy: 40); return true
                case "k": postPreviewScroll(dy: -40); return true
                case "d": postPreviewScroll(dy: 300); return true
                case "u": postPreviewScroll(dy: -300); return true
                case "f": postPreviewScroll(dy: 600); return true
                case "b": postPreviewScroll(dy: -600); return true
                case "h": postPreviewScroll(dx: -60); return true
                case "l": postPreviewScroll(dx: 60); return true
                case "g":
                    postPreviewScroll(dy: flags.contains(.shift) ? .greatestFiniteMagnitude : -.greatestFiniteMagnitude)
                    return true
                default: break
                }
            }
        }

        if railFocused {
            switch keyCode {
            case 125:
                moveRail(by: 1)
                return true
            case 126:
                moveRail(by: -1)
                return true
            case 53:
                selectRail("everything")
                railFocused = false
                return true
            case 36, 76, 48:
                railFocused = false
                // Tab falls through to the normal provider cycle below.
                if keyCode != 48 { return true }
            default:
                break
            }
        }

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
                    if selectModeChip(at: number - 1) { return true }
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
            moveSelection(by: 1)
            return true
        case 126:
            moveSelection(by: -1)
            return true
        case 36, 76:
            if actionsMode { executeAction() } else { executePrimary() }
            return true
        case 48:
            cycleTab(by: flags.contains(.shift) ? -1 : 1)
            return true
        case 53:
            if actionsMode {
                closeActions()
            } else if !query.isEmpty {
                resetting = true
                query = ""
                resetting = false
                previewEnabled = false
                clipboardFilter = nil
                panel?.widthOverride = nil
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
        if previewEnabled { updatePanelHeight() }
    }

    // MARK: - Provider rail

    public struct RailEntry: Identifiable, Equatable {
        public var id: String
        public var title: String
        public var trigger: String?
        public var icon: String?
    }

    /// Everything first, then one row per provider in registry order. `askh`
    /// shares the Ask row; the rail has no grouped chips.
    public var railEntries: [RailEntry] {
        var entries: [RailEntry] = [
            RailEntry(id: "everything", title: "Everything", trigger: nil, icon: "symbol:square.grid.2x2"),
        ]
        for provider in registry.providers {
            let descriptor = provider.descriptor
            guard let trigger = descriptor.trigger, descriptor.id != "askh" else { continue }
            entries.append(RailEntry(
                id: descriptor.id,
                title: descriptor.name,
                trigger: trigger,
                icon: descriptor.icon
            ))
        }
        return entries
    }

    /// The rail row for the current scope; a plain query is Everything.
    public var activeRailID: String {
        let provider = registry.parser.parse(query).providerID
        if provider == nil || provider == "apps" { return "everything" }
        if provider == "askh" { return "ask" }
        return provider ?? "everything"
    }

    public func selectRail(_ id: String) {
        guard let entry = railEntries.first(where: { $0.id == id }) else { return }
        if let trigger = entry.trigger {
            query = registry.parser.prefix + trigger + " "
        } else {
            resetting = true
            query = ""
            resetting = false
            previewEnabled = false
            clipboardFilter = nil
            panel?.widthOverride = nil
            scheduleSearch(debounce: false)
        }
    }

    public func moveRail(by delta: Int) {
        let entries = railEntries
        guard !entries.isEmpty else { return }
        let current = entries.firstIndex(where: { $0.id == activeRailID }) ?? 0
        let next = ((current + delta) % entries.count + entries.count) % entries.count
        selectRail(entries[next].id)
    }

    public var activeTabID: String {
        activeRailID == "everything" ? "apps" : activeRailID
    }

    public var activeProviderID: String {
        registry.parser.parse(query).providerID ?? "apps"
    }

    public func cycleTab(by delta: Int) {
        guard !actionsMode else { return }
        let entries = railEntries
        guard entries.count > 1 else { return }
        let current = entries.firstIndex(where: { $0.id == activeRailID }) ?? 0
        let count = entries.count
        let next = ((current + delta) % count + count) % count
        selectRail(entries[next].id)
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

    /// ⌘1/⌘2 (and ⌘3/⌘4 for clipboard filters) pick a visible mode chip.
    private func selectModeChip(at index: Int) -> Bool {
        switch activeTabID {
        case "clip":
            let filters: [String?] = [nil, "text", "image", "files"]
            guard filters.indices.contains(index) else { return false }
            setClipboardFilter(filters[index])
            return true
        default:
            return false
        }
    }

    private func cycleScope() {
        let bound = registry.providers.filter {
            $0.descriptor.trigger != nil && !registry.globalProviderIDs.contains($0.descriptor.id)
        }
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
        railFocused = false
        selectionIndex = index
        if previewEnabled { updatePanelHeight() }
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

    /// The same list ⌘K shows, also used by a row's right-click menu.
    public func actions(for item: PaletteItem) -> [PaletteAction] {
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
        return actions
    }

    /// Runs an action for a row that is not the ⌘K owner (context menu).
    public func run(_ action: PaletteAction, on item: PaletteItem) {
        execute(item: item, action: action)
    }

    public func toggleActions() {
        if actionsMode {
            closeActions()
            return
        }
        guard let item = selectedItem else { return }
        actionsMode = true
        actionsOwner = item
        actionsOwnerID = item.stableID
        allActions = actions(for: item)
        queryBeforeActions = query
        query = ""
        applyActionFilter()
    }

    /// Typing while the action list is open narrows that list.
    private func applyActionFilter() {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        actionItems = needle.isEmpty
            ? allActions
            : allActions.filter { $0.title.lowercased().contains(needle) }
        actionIndex = 0
        updatePanelHeight()
    }

    private func closeActions() {
        actionsMode = false
        actionItems = []
        allActions = []
        actionsOwner = nil
        actionsOwnerID = nil
        actionIndex = 0
        let restored = queryBeforeActions
        queryBeforeActions = ""
        query = restored
        updatePanelHeight()
    }

    public func executeAction() {
        guard actionsMode, actionItems.indices.contains(actionIndex), let item = actionsOwner else { return }
        let action = actionItems[actionIndex]
        closeActions()
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
                if object?["mode"] == "app" {
                    launcher.openWebApp(url, browser: object?["browser"] ?? configuration.webAppBrowser)
                } else {
                    launcher.openURL(url, with: object?["browser"])
                }

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
                // Clipboard rows carry a DB id; /shots rows pass a file path.
                if let id = action.value.text,
                   let image = try await store.clipboardImage(id: id) ?? NSImage(contentsOfFile: id)?.pngData() {
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
                if action.id == "term-open" {
                    openTerminalPanel()
                } else if action.id == "cmd-run-panel" || action.id == "connect-panel" {
                    if let value = action.value.object,
                       let executable = value["executable"] {
                        let parts = [executable] + (value["args"] ?? "").split(separator: "\u{1F}").map(String.init)
                        let line = parts.map(Self.shellQuote).joined(separator: " ")
                        let cwd = value["cwd"].flatMap { $0.isEmpty ? nil : $0 }
                        openTerminalPanel(
                            command: cwd.map { "cd \(Self.shellQuote($0)) && \(line)" } ?? line,
                            sessionName: value["session"]
                        )
                    }
                } else if action.id == "scratch-open" {
                    openScratchpad(noteID: nil, seed: action.value.text == "new" ? "" : nil)
                } else if action.id == "scratch-edit" {
                    if let noteID = action.value.object?["id"] {
                        openScratchpad(noteID: noteID, seed: nil)
                    }
                } else if action.id == "scratch-delete" {
                    try await registry.activate(item: item, action: action)
                    scheduleSearch(debounce: false)
                } else if action.id == "scratch-entry" {
                    if let entryID = action.value.text,
                       let entry = try await store.clipboardEntry(id: entryID) {
                        openScratchpad(noteID: nil, seed: entry.text)
                    }
                } else if action.id == "snippet-scratch" {
                    if let raw = action.value.text {
                        let expanded = SnippetExpansion.expand(
                            raw,
                            clipboard: NSPasteboard.general.string(forType: .string) ?? ""
                        )
                        openScratchpad(noteID: nil, seed: expanded)
                    }
                } else if action.id == "term-here" {
                    if let path = action.value.object?["path"], !path.isEmpty {
                        openTerminalPanel(command: "cd \(Self.shellQuote(path))")
                    }
                } else if action.id == "clip-transform" {
                    if let entryID = action.value.text {
                        query = registry.parser.prefix + "clip transform:" + entryID
                    }
                } else if action.id == "ask-settings" {
                    onOpenConfig?()
                    panel?.hide()
                } else if action.id == "open-settings" {
                    onOpenConfig?()
                    panel?.hide()
                } else if action.id == "retry" {
                    // Re-run the current query, e.g. currency rates after a
                    // dropped connection; the panel stays where it is.
                    scheduleSearch(debounce: false)
                } else if action.id == "enter-provider" {
                    if let trigger = action.value.text {
                        query = registry.parser.prefix + trigger + " "
                    }
                } else if action.id == "pin-item" {
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
            setStatus(error.localizedDescription, duration: 8)
        }
    }

    /// One row per provider whose name or trigger matches the query. Bound
    /// searches never see these.
    private func providerMatches(query: String) -> [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return registry.providers.compactMap { provider in
            let descriptor = provider.descriptor
            guard let trigger = descriptor.trigger,
                  let score = Ranking.score(query: trimmed, candidate: "\(descriptor.name) \(trigger)")
            else { return nil }
            let icon = descriptor.icon.flatMap { raw -> IconSpec? in
                guard raw.hasPrefix("symbol:") else { return nil }
                return .symbol(String(raw.dropFirst("symbol:".count)))
            }
            return PaletteItem(
                id: "provider:\(descriptor.id)",
                title: descriptor.name,
                subtitle: "/\(trigger)",
                icon: icon ?? .symbol("square.grid.2x2"),
                badge: "PROVIDER",
                group: "Providers",
                score: score,
                actions: [PaletteAction(
                    id: "enter-provider",
                    title: "Open \(descriptor.name)",
                    kind: .custom,
                    value: .text(trigger)
                )],
                providerID: "providers",
                providerName: "Palette"
            )
        }
    }

    private func keepsPanelOpen(item: PaletteItem, action: PaletteAction) -> Bool {
        switch item.providerID {
        case "theme", "clip":
            return true
        case "awake":
            return true
        case "web":
            return ["add", "remove", "shortcut", "clear-shortcut"].contains(action.id)
        case "bw", "bwu", "bwt", "bwn", "bwo":
            return ["install", "login", "unlock", "retry"].contains(action.id)
        case "atlas":
            return ["review", "copy-path", "open-index"].contains(action.id)
        case "git":
            return ["status", "log", "stage", "commit", "pull", "push", "clear-output"].contains(action.id)
        case "proj":
            // Keep the list open so the new project shows up after it is registered.
            return ["clone-repo", "new-project"].contains(action.id)
        case "gha":
            return ["rerun", "cancel"].contains(action.id)
        case "ghn":
            return action.id == "mark-done"
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

    public func beginProgress(_ message: String) async {
        setStatus(message, duration: nil)
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

    /// Re-render the timer tab once a second so the countdown moves.
    public func observeTimerTicks() {
        guard timerObserver == nil else { return }
        timerObserver = NotificationCenter.default.addObserver(
            forName: TimerService.tickNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.activeTabID == "timer" else { return }
                self.scheduleSearch(debounce: true)
            }
        }
    }

    public func updatePanelHeight() {
        guard let panel else { return }
        let theme = themeManager.theme
        let chrome = tabChromeHeight
        if scratchpadActive {
            panel.setContentHeight(CGFloat(theme.search.height) + 500 + chrome)
            return
        }
        if terminalActive {
            panel.setContentHeight(660 + chrome)
            return
        }

        var content: CGFloat
        if prompt != nil {
            content = 136
        } else if actionsMode {
            content = 38 + listHeight
        } else {
            content = modeHeaderHeight + listHeight
        }
        if previewEnabled {
            // Clearing the width override matters as much as setting it: an
            // empty result hides the pane and must not leave the panel wide.
            updatePreviewWidth()
        }
        if previewVisible, previewLayout == .below {
            // The preview is its own card with one card gap under the list.
            content += previewPaneHeight + LauncherMetrics.cardGap
        }
        panel.setContentHeight(CGFloat(theme.search.height) + content + chrome)
    }

    /// Everything around the list: both outer insets, the card gaps and the
    /// footer. The rail is a sibling card, so it reserves no list height.
    private var tabChromeHeight: CGFloat {
        let footer = themeManager.theme.footer.show ? LauncherMetrics.footerHeight : 0
        let gaps = themeManager.theme.footer.show ? LauncherMetrics.cardGap * 2 : LauncherMetrics.cardGap
        return LauncherMetrics.outerInset * 2 + gaps + footer
    }

    /// The optional Ask/History or clipboard filter row inside the list card.
    private var modeHeaderHeight: CGFloat {
        activeTabID == "clip" || activeTabID == "ask" ? 40 : 0
    }

    /// The configured row count is the panel's fixed height: a short list
    /// does not shrink it and a long one does not grow it. Rows that wrap to
    /// two title lines get 16pt more, and the viewport is sized from those
    /// exact heights so no row is cut at the bottom.
    private var listHeight: CGFloat {
        let row = CGFloat(themeManager.theme.effectiveRowHeight)
        let spacing: CGFloat = 6
        let visible = Int(panel?.effectiveRows() ?? windowConfig.launcherRows)
        let rows = Array(items.prefix(visible))
        let heights = rows.map { row + (titleWraps($0) ? 16 : 0) }
        let used = heights.isEmpty ? row * CGFloat(visible) : heights.reduce(0, +)
        let count = max(1, heights.isEmpty ? CGFloat(visible) : CGFloat(heights.count))
        // Only the headers among the rows that fit take vertical space; a
        // later group must not inflate the viewport and reveal a partial row.
        let visibleGroups = Set(rows.compactMap(\.group)).count
        let groups = min(4, visibleGroups)
        // Header: 11pt line + 8pt top pad + the 6pt stack gap.
        let headerRoom = CGFloat(groups) * 25
        return used + (count - 1) * spacing + LauncherMetrics.innerPadding * 2 + headerRoom
    }

    /// Width left for a result title after the rail, card/row insets, icon,
    /// badge and spacer. Err narrow so a long title is predicted to wrap.
    private var titleColumnWidth: CGFloat {
        let panelWidth = panel?.widthOverride ?? CGFloat(windowConfig.launcherWidth(for: screenSize))
        let rail: CGFloat = (previewVisible || panelWidth < 700) ? 56 : 220
        return max(120, panelWidth - LauncherMetrics.outerInset * 2 - rail
            - LauncherMetrics.cardGap - LauncherMetrics.innerPadding * 4 - 20 - 10 - 8 - 80)
    }

    /// True when the title cannot fit on one line at the current width; the
    /// row then renders two lines and reserves the extra height.
    public func titleWraps(_ item: PaletteItem) -> Bool {
        let width = (item.title as NSString).size(
            withAttributes: [.font: themeManager.theme.nsFont(size: themeManager.theme.typography.size)]
        ).width
        return width > titleColumnWidth
    }

    /// Width of the beside-list preview pane. ⌥P grows it, and the panel
    /// grows by the same amount so the list keeps its width.
    public var previewPaneWidth: CGFloat {
        guard previewLayout == .beside, previewFocused else { return 300 }
        return max(300, min(640, screenSize.width - 420))
    }

    /// Height of the below-list preview pane. ⌥P takes the room the max
    /// panel height leaves after the list, so nothing is pushed out of view.
    public var previewPaneHeight: CGFloat {
        guard previewLayout == .below, previewFocused else { return 220 }
        let base = CGFloat(themeManager.theme.search.height) + tabChromeHeight + listHeight
        return max(220, min(520, CGFloat(themeManager.theme.window.maxHeight) - base))
    }

    /// One width rule for previews: `preview_width` beside, launcher width
    /// below, and a wider panel while focused. Clipboard's own width key must
    /// not fight this, or the panel jumps between opens and searches.
    private func updatePreviewWidth() {
        guard let panel else { return }
        guard previewVisible, previewLayout == .beside else {
            panel.widthOverride = nil
            return
        }
        guard previewFocused else {
            panel.widthOverride = CGFloat(windowConfig.previewWidth(for: screenSize))
            return
        }
        let normal = CGFloat(windowConfig.previewWidth(for: screenSize))
        panel.widthOverride = min(normal + previewPaneWidth - 300, screenSize.width - 24)
    }

    public func openTerminalPanel(command: String? = nil, sessionName: String? = nil) {
        terminalInitialCommand = command
        terminalSessionName = sessionName
        terminalActive = true
        scratchpadActive = false
        previewEnabled = false
        previewFocused = false
        actionsMode = false
        actionItems = []
        panel?.widthOverride = CGFloat(windowConfig.terminalWidth(for: screenSize))
        panel?.show()
        updatePanelHeight()
        requestFocus()
    }

    public func closeTerminalPanel() {
        guard terminalActive else { return }
        terminalActive = false
        terminalSessionName = nil
        panel?.widthOverride = nil
        NotificationCenter.default.post(name: .paletteTerminalStop, object: nil)
        resetting = true
        query = ""
        resetting = false
        scheduleSearch(debounce: false)
        updatePanelHeight()
    }

    public func openScratchpad(noteID: String? = nil, seed: String? = nil) {
        if terminalActive { closeTerminalPanel() }
        panel?.show()
        panel?.widthOverride = CGFloat(windowConfig.clipboardWidth(for: screenSize))
        scratchpadActive = true
        previewEnabled = false
        previewFocused = false
        scratchpadNoteID = noteID
        scratchpadTitle = ""
        scratchpadText = seed ?? ""
        previewFocused = false
        actionsMode = false
        actionItems = []

        if let noteID {
            Task { [weak self] in
                guard let self, let note = try? await self.store.scratchNote(id: noteID) else { return }
                self.scratchpadTitle = note.title
                self.scratchpadText = note.text
            }
        } else if seed == nil {
            Task { [weak self] in
                guard let self else { return }
                if let note = try? await self.store.scratchNotes(limit: 1).first {
                    self.scratchpadNoteID = note.id
                    self.scratchpadTitle = note.title
                    self.scratchpadText = note.text
                } else if let legacy = try? await self.store.metaValue("scratchpad.text"),
                          !legacy.isEmpty {
                    self.scratchpadText = legacy
                }
            }
        }
        updatePanelHeight()
        requestFocus()
    }

    public func closeScratchpad(save: Bool) {
        guard scratchpadActive else { return }
        if save {
            let title = scratchpadTitle
            let text = scratchpadText
            let noteID = scratchpadNoteID
            if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Task { [weak self] in
                    guard let self,
                          let note = try? await self.store.saveScratchNote(
                            id: noteID,
                            title: title,
                            text: text
                          ) else { return }
                    self.scratchpadNoteID = note.id
                }
            }
        }
        scratchpadActive = false
        panel?.widthOverride = nil
        panel?.suppressAutoHide = false
        resetting = true
        query = ""
        resetting = false
        scheduleSearch(debounce: false)
        updatePanelHeight()
        requestFocus()
    }

    public func copyScratchpad() {
        pasteboard.write(text: scratchpadText)
        setStatus("Scratchpad copied", duration: 2)
        panel?.suppressAutoHide = false
    }

    public func pasteIntoScratchpad() {
        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            if scratchpadText.isEmpty {
                scratchpadText = text
            } else {
                scratchpadText += "\n" + text
            }
        }
    }

    public func clearScratchpad() {
        scratchpadText = ""
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func postPreviewScroll(dy: CGFloat = 0, dx: CGFloat = 0) {
        NotificationCenter.default.post(
            name: .palettePreviewScroll,
            object: nil,
            userInfo: ["dx": dx, "dy": dy]
        )
    }

    public func refreshTheme() {
        updatePanelHeight()
    }
}
