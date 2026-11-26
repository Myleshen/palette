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
    public var validation: PromptValidation = .none
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
    /// The global deadline hint is shown once per session, not on every keystroke.
    private var reportedSlowProviders = false
    @Published public private(set) var actionsMode = false
    @Published public private(set) var actionItems: [PaletteAction] = []
    private var actionsOwnerID: String?
    private var actionsOwner: PaletteItem?
    private var allActions: [PaletteAction] = []
    private var queryBeforeActions = ""
    /// Bumped on every scratchpad open/close so an in-flight load cannot write
    /// over newer text.
    private var scratchpadGeneration = 0
    /// The close-path save; the next open waits for it so it cannot read the
    /// snapshot from before the save.
    private var scratchpadSaveTask: Task<Void, Never>?
    @Published public var actionIndex = 0
    /// Which zone Tab, the arrows, Enter and Esc act on. The search field keeps
    /// the real keyboard focus in every zone so typing never stops working.
    @Published public var focusZone: LauncherZone = .search
    /// Derived views for the script dump and the older click handlers.
    public var railFocused: Bool {
        get { focusZone == .rail }
        set { focusZone = newValue ? .rail : (focusZone == .rail ? .search : focusZone) }
    }
    /// The secondary strip has keyboard focus; arrows switch group children.
    public var stripFocused: Bool {
        get { focusZone == .strip }
        set { focusZone = newValue ? .strip : (focusZone == .strip ? .search : focusZone) }
    }
    /// A provider opened without a trigger (the Apps rail row); plain text
    /// keeps filtering that provider until another scope is chosen.
    @Published public private(set) var scopeProviderID: String?
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
    /// Exit status of the pane's child; nil while it is running. Drives the end
    /// card so a finished session never looks like a hung one.
    @Published public private(set) var terminalExitCode: Int32?
    /// Bumped by Restart; the pane starts a fresh process when it changes.
    @Published public private(set) var terminalRestartToken = 0
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
    /// Opens Settings already scrolled to a search anchor, for trouble rows.
    public var onOpenSettingsAnchor: ((String) -> Void)?
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
    private var previewTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var pathsIndexObserver: NSObjectProtocol?
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
        // A finished background walk re-runs the current query, so the
        // "Indexing files…" row is replaced without retyping.
        pathsIndexObserver = NotificationCenter.default.addObserver(
            forName: PathsProvider.indexUpdatedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let id = note.object as? String else { return }
            Task { @MainActor in self?.pathsIndexDidUpdate(id) }
        }
    }

    private func pathsIndexDidUpdate(_ providerID: String) {
        guard panel?.isVisible == true else { return }
        let bound = registry.parser.parse(query).providerID == providerID
        guard bound || scopeProviderID == providerID else { return }
        scheduleSearch(debounce: false)
    }

    /// The text field's contents: `query` minus the `"/trigger "` token when
    /// the user is already typing inside a provider.
    public var visibleQuery: String {
        QueryDisplay(parser: registry.parser).visible(for: query)
    }

    /// Applies an edit made in the text field to the internal query.
    public func editVisibleQuery(_ visible: String) {
        let next = QueryDisplay(parser: registry.parser)
            .query(forVisible: visible, previous: query)
        guard next != query else { return }
        query = next
    }

    public var selectedItem: PaletteItem? {
        guard items.indices.contains(selectionIndex) else { return nil }
        return items[selectionIndex]
    }

    /// What the footer says Return will do; nil when Return does nothing.
    public var returnHint: String? {
        switch selectedItem?.returnRoute {
        case .settings: return "Fix in Settings"
        case .action(let action): return action.title
        case nil: return nil
        }
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
        focusZone = .search
        hasShown = true
        scheduleSearch()
    }

    /// The dedicated clipboard hotkey opens straight into `/clip`, with the
    /// wide preview layout and no typing required.
    private var windowConfig: WindowConfig { configuration.window }

    public var previewLayout: PreviewPlacement {
        configuration.window.resolvedPreviewLayout(
            frameWidth: Double(configuration.window.launcherSize(for: screenSize).width)
        )
    }

    /// Top strip, left rail, or no provider switcher at all.
    public var providerBar: ProviderBarPlacement { configuration.window.providerBar }

    /// The strip only occupies height in top mode and only while it has chips.
    public var showsProviderBar: Bool {
        providerBar == .top && !railEntries.isEmpty
    }

    private var timerObserver: NSObjectProtocol?

    private var screenSize: CGSize {
        (PanelController.screenUnderPointer() ?? panel?.panel.screen)?.visibleFrame.size
            ?? CGSize(width: 1440, height: 900)
    }

    public func openClipboard() {
        previewEnabled = true
        clipboardFilter = nil
        actionsMode = false
        actionItems = []
        query = "\(configuration.providerPrefix)clip "
        panelDidShow()
    }

    public func panelDidHide() {
        // The panel auto-hides when another app takes focus; that must keep a
        // half-written draft, not throw it away.
        if scratchpadActive {
            saveScratchpad()
        }
        searchTask?.cancel()
        previewTask?.cancel()
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
        focusZone = .search
        scopeProviderID = nil
        terminalActive = false
        terminalSessionName = nil
        panel?.suppressAutoHide = false
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
        if parsed.providerID != nil { scopeProviderID = nil }
        // Preview is useful wherever a row has something worth showing:
        // clipboard, snippets, and path/project providers.
        let previewProvider = ["clip", "snip", "recent", "neo", "neof", "proj", "shots", "cheat", "atlas"]
            .contains(parsed.providerID ?? "")
        if previewProvider {
            if !previewEnabled {
                previewEnabled = true
            }
        } else if previewEnabled {
            previewEnabled = false
            previewFocused = false
            panel?.suppressAutoHide = false
            clipboardFilter = nil
        }
        if parsed.isBound {
            // Keep the previous rows visible while the next query runs: clearing
            // on each keystroke made the list (and its preview) blink empty.
            if !parsed.keepsPreviousRows(previousProviderID: items.first?.providerID) {
                items = []
                selectionIndex = 0
                actionIndex = 0
            }
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
        } else {
            scopeLabel = nil
        }
        scheduleSearch()
    }

    private func scheduleSearch(debounce: Bool = true) {
        searchTask?.cancel()
        let raw = query
        let scope = scopeProviderID
        let pathQuery = scope != nil || registry.parser.parse(raw).isBound
        let delay: UInt64 = debounce && pathQuery ? 120_000_000 : (debounce ? 12_000_000 : 0)
        searchTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.performSearch(raw: raw, scope: scope)
        }
    }

    private func performSearch(raw: String, scope: String?) async {
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
            return
        }
        let result: RegistrySearchResult
        if let scope {
            result = await registry.search(providerID: scope, text: raw)
        } else {
            result = await registry.search(raw: raw)
        }
        guard !Task.isCancelled else { return }

        let previousID = selectedItem?.stableID
        var boosts = (try? await store.frecencyBoosts(for: result.items.map(\.stableID))) ?? [:]
        // Learned ordering is a tie-breaker for a short plain query only; a
        // bound /trigger search or a scoped provider never learns or boosts.
        if scope == nil, !result.parsed.isBound, configuration.learningEnabled,
           let prefix = QueryMemory.learnablePrefix(result.parsed.text),
           let learned = try? await store.learnedBoosts(
                prefixHash: QueryMemory.digest(prefix),
                itemKeys: result.items.map(\.stableID)
           ) {
            for (stableID, boost) in learned { boosts[stableID, default: 0] += boost }
        }
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
        // never unpinned web apps, sessions, or search suggestions. The Apps
        // rail row is the same list on purpose.
        let appOnly = result.parsed.providerID == "apps"
        let isEmptySearch = (!result.parsed.isBound || appOnly)
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
            if !items.indices.contains(selectionIndex) {
                // An external refresh can empty the list while ⌘K is open.
                actionsMode = false
                actionItems = []
                allActions = []
                actionsOwner = nil
                actionsOwnerID = nil
                queryBeforeActions = ""
                actionIndex = 0
            } else if let owner = actionsOwnerID, items[selectionIndex].stableID != owner {
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
        if !result.timedOutProviders.isEmpty, !reportedSlowProviders {
            reportedSlowProviders = true
            setStatus("Some sources are still loading — use a /trigger for the slow one", duration: 5)
        }
        fillPreview()
    }

    /// A preview that costs a process call (git status, a file digest) is
    /// fetched for the selected row only, after its list is already on screen.
    private func fillPreview() {
        previewTask?.cancel()
        guard previewEnabled, items.indices.contains(selectionIndex) else { return }
        let item = items[selectionIndex]
        guard let provider = registry.providers.first(where: { $0.descriptor.id == item.providerID })
            as? AsyncPreviewProviding else { return }
        let index = selectionIndex
        let stableID = item.stableID
        previewTask = Task { [weak self] in
            let preview = await provider.preview(for: item)
            guard let preview, let self, !Task.isCancelled,
                  self.items.indices.contains(index),
                  self.items[index].stableID == stableID else { return }
            self.items[index].preview = preview
        }
    }

    /// The bound provider has nothing to show because a tool is missing.
    public var missingToolHint: String? {
        let parsed = registry.parser.parse(query)
        guard parsed.isBound,
              let id = parsed.providerID,
              let provider = registry.providers.first(where: { $0.descriptor.id == id }),
              let missing = ProviderRequirements.missing(
                ProviderToolRequirements.requirements(for: provider)
              ).first else { return nil }
        return "\(provider.descriptor.name) needs \(missing.tool) — \(missing.install)"
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
            // Esc belongs to the running program; once the child is gone it
            // closes the pane like the end card's Close button.
            if keyCode == 53, terminalExitCode != nil {
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
            return true
        }
        if previewFocused {
            if keyCode == 53 {
                previewFocused = false
                panel?.suppressAutoHide = false
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

        // A prompt is modal: it owns Enter and Esc ahead of any focus zone.
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

        let shift = flags.contains(.shift)
        // Plain keys belong to the zone; ⌘ combos (⌘⏎, ⌘K, ⌘1…9, ⌘Tab) stay
        // with the command block below.
        if !command {
            switch focusZone {
            case .strip:
                switch keyCode {
                case 123, 126:
                    moveGroupChild(by: -1)
                    return true
                case 124, 125:
                    moveGroupChild(by: 1)
                    return true
                case 36, 76:
                    // Enter confirms the child and hands the list the keyboard.
                    focusZone = .list
                    fillPreview()
                    return true
                case 48:
                    focusTab(forward: !shift)
                    return true
                case 53:
                    focusZone = .search
                    return true
                default:
                    break
                }
            case .rail:
                switch keyCode {
                case 125:
                    moveRail(by: 1)
                    return true
                case 126:
                    moveRail(by: -1)
                    return true
                case 36, 76:
                    focusZone = .list
                    fillPreview()
                    return true
                case 48:
                    focusTab(forward: !shift)
                    return true
                case 53:
                    focusZone = .search
                    return true
                default:
                    break
                }
            case .list:
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
                    focusTab(forward: !shift)
                    return true
                case 53:
                    if actionsMode {
                        closeActions()
                    } else {
                        focusZone = .search
                    }
                    return true
                default:
                    break
                }
            case .search:
                break
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
            focusTab(forward: !shift)
            return true
        case 53:
            if actionsMode {
                closeActions()
            } else if !query.isEmpty || scopeProviderID != nil {
                resetToPlainQuery()
                scopeProviderID = nil
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
        fillPreview()
    }

    /// Tab never changes the provider: it walks the focus zones and wraps.
    public func focusTab(forward: Bool) {
        guard !actionsMode else { return }
        focusZone = LauncherFocus.tab(
            from: focusZone,
            forward: forward,
            hasStrip: activeGroupEntry != nil
        )
        if focusZone == .list { fillPreview() }
    }

    // MARK: - Provider rail

    /// Everything, Apps, one row per group, then ungrouped providers.
    public var railEntries: [ProviderRailEntry] {
        ProviderRail.entries(for: registry.providers.map(\.descriptor))
    }

    /// The rail row for the current scope; a plain query is Everything.
    public var activeRailID: String {
        if let scopeProviderID { return scopeProviderID }
        guard let providerID = registry.parser.parse(query).providerID else {
            return ProviderRail.everythingID
        }
        return ProviderRail.railID(for: providerID, in: railEntries)
    }

    /// The group whose secondary strip belongs above the list, if any.
    public var activeGroupEntry: ProviderRailEntry? {
        let id = activeRailID
        return railEntries.first { $0.id == id && $0.isGroup }
    }

    public func selectRail(_ id: String) {
        guard let entry = railEntries.first(where: { $0.id == id }) else { return }
        stripFocused = false
        if entry.isGroup {
            scopeProviderID = nil
            guard let first = entry.children.first else { return }
            resetToPlainQuery()
            query = registry.parser.prefix + first.trigger + " "
            scheduleSearch(debounce: false)
            return
        }
        if let scope = entry.scopeProviderID {
            resetToPlainQuery()
            scopeProviderID = scope
            scheduleSearch(debounce: false)
            return
        }
        scopeProviderID = nil
        if let trigger = entry.trigger {
            query = registry.parser.prefix + trigger + " "
        } else {
            resetToPlainQuery()
            scheduleSearch(debounce: false)
        }
    }

    /// Switch inside the group strip, keeping whatever text follows the trigger.
    public func selectGroupChild(_ child: ProviderRailChild) {
        let text = registry.parser.parse(query).text
        scopeProviderID = nil
        query = registry.parser.prefix + child.trigger + (text.isEmpty ? " " : " " + text)
    }

    public func moveGroupChild(by delta: Int) {
        guard let group = activeGroupEntry, !group.children.isEmpty else { return }
        let current = group.children.firstIndex { $0.id == activeProviderID } ?? 0
        let count = group.children.count
        let next = ((current + delta) % count + count) % count
        selectGroupChild(group.children[next])
    }

    private func resetToPlainQuery() {
        resetting = true
        query = ""
        resetting = false
        previewEnabled = false
        previewFocused = false
        clipboardFilter = nil
    }

    public func moveRail(by delta: Int) {
        let entries = railEntries
        guard !entries.isEmpty else { return }
        let current = entries.firstIndex(where: { $0.id == activeRailID }) ?? 0
        let next = ((current + delta) % entries.count + entries.count) % entries.count
        selectRail(entries[next].id)
    }

    public var activeTabID: String {
        activeRailID == ProviderRail.everythingID ? "apps" : activeProviderID
    }

    public var activeProviderID: String {
        if let scopeProviderID { return scopeProviderID }
        return registry.parser.parse(query).providerID ?? "apps"
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
        focusZone = .list
        selectionIndex = index
        fillPreview()
    }

    public func activate(_ index: Int) {
        select(index)
        executePrimary()
    }

    public func executePrimary() {
        guard let item = selectedItem else { return }
        switch item.returnRoute {
        case .settings(let anchor):
            if let onOpenSettingsAnchor {
                onOpenSettingsAnchor(anchor)
            } else {
                onOpenConfig?()
            }
            panel?.hide()
        case .action(let action):
            execute(item: item, action: action, learnQuery: learnableQuery)
        case nil:
            setStatus(item.noActionHint, duration: 3)
        }
    }

    public func executeSecondary() {
        guard let item = selectedItem, let action = item.secondaryAction else {
            setStatus("No secondary action", duration: 2)
            return
        }
        execute(item: item, action: action, learnQuery: learnableQuery)
    }

    /// The plain query text this activation may be learned under, if any.
    private var learnableQuery: String? {
        let parsed = registry.parser.parse(query)
        guard !actionsMode, scopeProviderID == nil, !parsed.isBound else { return nil }
        return QueryMemory.learnablePrefix(parsed.text)
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
        focusZone = .list
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
            : allActions.filter { Ranking.score(query: needle, candidate: $0.title) != nil }
        actionIndex = 0
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
    }

    public func executeAction() {
        guard actionsMode, actionItems.indices.contains(actionIndex), let item = actionsOwner else { return }
        let action = actionItems[actionIndex]
        closeActions()
        execute(item: item, action: action)
    }

    private func execute(item: PaletteItem, action: PaletteAction, learnQuery: String? = nil) {
        let isTransient = ["install", "login", "unlock", "add", "remove", "shortcut", "clear-shortcut", "pin-item", "unpin-item"].contains(action.id)
        // Digest before the task runs: the query may change while it waits.
        let prefixHash = learnQuery.map(QueryMemory.digest)
        Task { [weak self] in
            guard let self else { return }
            // Act first: the frecency write must not sit between Enter and the
            // window opening or the clipboard being written.
            await self.perform(item: item, action: action)
            if !isTransient {
                try? await self.store.recordUse(stableID: item.stableID, provider: item.providerID)
                if let prefixHash, self.configuration.learningEnabled {
                    try? await self.store.recordLearnedChoice(
                        prefixHash: prefixHash,
                        itemKey: item.stableID
                    )
                }
            }
        }
    }

    private func perform(item: PaletteItem, action: PaletteAction) async {
        do {
            switch action.kind {
            case .openPath:
                if let path = action.value.text {
                    let expanded = PathExpansion.expand(path)
                    if case let .missing(message) = OpenPathPlan.plan(
                        path: path,
                        exists: FileManager.default.fileExists(atPath: expanded),
                        create: false
                    ) {
                        setStatus(message, duration: 5)
                        return
                    }
                    launcher.openPath(path)
                    panel?.hide(activatePrevious: false)
                }

            case .openPathWith:
                guard let value = action.value.object, let path = value["path"] else {
                    setStatus("Action is missing a path", duration: 3)
                    return
                }
                let app = value["app"] ?? configuration.editorOpenWith
                let plan = OpenPathPlan.plan(
                    path: path,
                    exists: FileManager.default.fileExists(
                        atPath: PathExpansion.expand(path)
                    ),
                    create: value["create"] == "true"
                )
                switch plan {
                case .missing(let message):
                    setStatus(message, duration: 5)
                    return
                case .createAndOpen:
                    ensureFileExists(at: path)
                case .open:
                    break
                }
                let attempt: OpenAttempt
                do {
                    try launcher.openPath(path, with: app)
                    attempt = .succeeded
                } catch {
                    attempt = .failed(error.localizedDescription)
                }
                if attempt.hidesPanel {
                    panel?.hide(activatePrevious: false)
                } else if case let .failed(message) = attempt {
                    setStatus(message, duration: 8)
                }

            case .openURL:
                let object = action.value.object
                let url = object?["url"] ?? action.value.text
                guard let url else { return }
                let outcome: URLOpenOutcome
                if object?["mode"] == "app" {
                    outcome = await launcher.openWebApp(
                        url,
                        browser: object?["browser"] ?? configuration.webAppBrowser
                    )
                } else {
                    outcome = await launcher.openURL(url, with: object?["browser"])
                }
                // Hide only after something opened. A fallback keeps the panel up
                // long enough to say which browser took the link instead.
                if outcome.hidesPanel {
                    panel?.hide(activatePrevious: false)
                } else if let message = outcome.status {
                    setStatus(message, duration: 8)
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
                    let previous = panel?.previousApplication
                    let clearAfterMs = action.clearAfterMs ?? (action.concealed ? configuration.clipboard.clearAfterMs : nil)
                    performPaste(into: previous) { route in
                        pasteboard.paste(
                            text: text,
                            concealed: action.concealed,
                            clearAfterMs: clearAfterMs,
                            into: previous,
                            route: route
                        )
                    }
                }

            case .copyImage:
                if let id = action.value.text, let image = try await store.clipboardImage(id: id) {
                    pasteboard.write(image: image, concealed: action.concealed, clearAfterMs: action.clearAfterMs)
                    panel?.hide()
                } else {
                    setStatus("That image is no longer stored", duration: 4)
                }

            case .pasteImage:
                // Clipboard rows carry a DB id; /shots rows pass a file path.
                if let id = action.value.text,
                   let image = try await store.clipboardImage(id: id) ?? NSImage(contentsOfFile: id)?.pngData() {
                    let previous = panel?.previousApplication
                    let clearAfterMs = action.clearAfterMs ?? (action.concealed ? configuration.clipboard.clearAfterMs : nil)
                    performPaste(into: previous, image: true) { route in
                        pasteboard.paste(
                            image: image,
                            concealed: action.concealed,
                            clearAfterMs: clearAfterMs,
                            into: previous,
                            route: route
                        )
                    }
                } else {
                    setStatus("That image is no longer stored", duration: 4)
                }

            case .copyFiles:
                if let paths = action.value.list, !paths.isEmpty {
                    pasteboard.write(files: paths, concealed: action.concealed, clearAfterMs: action.clearAfterMs)
                    panel?.hide()
                }

            case .pasteFiles:
                if let paths = action.value.list, !paths.isEmpty {
                    let previous = panel?.previousApplication
                    let clearAfterMs = action.clearAfterMs ?? (action.concealed ? configuration.clipboard.clearAfterMs : nil)
                    performPaste(into: previous) { route in
                        pasteboard.paste(
                            files: paths,
                            clearAfterMs: clearAfterMs,
                            into: previous,
                            route: route
                        )
                    }
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
                    // Re-run the current query, e.g. after a dropped
                    // connection; the panel stays where it is.
                    scheduleSearch(debounce: false)
                } else if action.id == "enter-provider" {
                    if let trigger = action.value.text {
                        query = registry.parser.prefix + trigger + " "
                    }
                } else if action.id == "pin-item" {
                    try await store.pinItem(item)
                    setStatus("Pinned \(item.title)", duration: 2)
                    scheduleSearch(debounce: false)
                } else if action.id == "ocr-pin-copy" || action.id == "ocr-pin-open" {
                    await runPinnedImageOCR(item: item, openLink: action.id == "ocr-pin-open")
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

    /// OCR for a pinned image. Pinned items keep the provider they came from,
    /// so the host reads the best available pixels instead of dispatching to a
    /// provider that may no longer have the row.
    private func runPinnedImageOCR(item: PaletteItem, openLink: Bool) async {
        guard let data = await pinnedImageData(for: item) else {
            setStatus("No text found", duration: 3)
            return
        }
        guard let recognition = try? await ImageTextRecognition.recognize(pngData: data) else {
            setStatus("Text recognition failed", duration: 3)
            return
        }
        if openLink {
            guard let raw = recognition.firstLink,
                  ImageTextRecognition.isOpenable(raw),
                  let url = URL(string: raw) else {
                setStatus("No link found", duration: 3)
                return
            }
            panel?.hide(activatePrevious: false)
            NSWorkspace.shared.open(url)
        } else {
            let text = recognition.text
            guard !text.isEmpty else {
                setStatus("No text found", duration: 3)
                return
            }
            pasteboard.write(text: text)
            setStatus("Text copied (\(text.count) chars)", duration: 3)
        }
    }

    private func pinnedImageData(for item: PaletteItem) async -> Data? {
        if item.providerID == "shots", item.id.hasPrefix("shot:") {
            let path = String(item.id.dropFirst("shot:".count))
            return try? Data(contentsOf: URL(fileURLWithPath: path))
        }
        if item.providerID == "clip", let data = try? await store.clipboardImage(id: item.id) {
            return data
        }
        if case let .image(base64, _, _) = item.preview {
            return Data(base64Encoded: base64)
        }
        return nil
    }

    private func keepsPanelOpen(item: PaletteItem, action: PaletteAction) -> Bool {
        switch item.providerID {
        case "theme", "clip", "ocr", "timer", "color":
            return true
        case "shots":
            // Copy and OCR report their outcome in the status line; capture
            // rows still hide.
            return action.id == "copy" || action.id.hasPrefix("ocr-")
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
            // Keep the list open so the new project or worktree shows up
            // immediately and its status/error stays readable.
            return ["clone-repo", "new-project", "new-worktree"].contains(action.id)
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
        await prompt(kind: kind, title: title, placeholder: placeholder, validation: .none)
    }

    public func prompt(
        kind: PromptKind,
        title: String,
        placeholder: String?,
        validation: PromptValidation
    ) async -> String? {
        if promptContinuation != nil {
            promptContinuation?.resume(returning: nil)
            promptContinuation = nil
        }
        return await withCheckedContinuation { continuation in
            promptContinuation = continuation
            promptValue = ""
            prompt = PromptState(kind: kind, title: title, placeholder: placeholder, validation: validation)
            panel?.suppressAutoHide = true
            focusToken += 1
        }
    }

    /// Inline reason the prompt cannot be accepted, read as the field changes.
    public var promptValidationMessage: String? {
        guard let prompt else { return nil }
        switch prompt.validation {
        case .none: return nil
        case .branchName: return BranchName.error(for: promptValue)
        }
    }

    public var canSubmitPrompt: Bool {
        guard let prompt else { return false }
        return prompt.kind == .confirm || promptValidationMessage == nil
    }

    public func submitPrompt() {
        guard let prompt, canSubmitPrompt else { return }
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
        focusZone = .search
        panel?.suppressAutoHide = false
        panel?.activatePreviousOnHide = true
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

    /// Setup rows opt in with `create: true`; create the empty file so the
    /// editor opens instead of the panel closing on a missing path.
    private func ensureFileExists(at path: String) {
        PathExpansion.ensureFileExists(at: path)
    }

    public func copyToClipboard(_ text: String, concealed: Bool, clearAfterMs: Int?) async {
        pasteboard.write(
            text: text,
            concealed: concealed,
            clearAfterMs: clearAfterMs ?? (concealed ? configuration.clipboard.clearAfterMs : nil)
        )
        setStatus(concealed ? "Copied securely (clears automatically)" : "Copied to clipboard", duration: 2)
        // Anything Palette copies on the user's behalf belongs in our own
        // history too (OCR, preview buttons, copy actions). Concealed copies
        // are deliberately never stored.
        if !concealed, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try? await store.insertClipboard(text: text, maxEntries: configuration.clipboard.maxText)
        }
    }

    // MARK: - Presentation support

    /// Picks the paste route, hides the panel only when the paste is
    /// automatic, and reports what the user must do otherwise. The panel stays
    /// up for a copy-only outcome so the status line is visible.
    private func performPaste(
        into app: NSRunningApplication?,
        image: Bool = false,
        deliver: (PasteTarget.Route?) -> PasteOutcome
    ) {
        let route = pasteboard.isAccessibilityTrusted
            ? PasteTarget.route(
                bundleID: app?.bundleIdentifier,
                menuAvailable: pasteboard.canPasteViaMenu(into: app),
                image: image
            )
            : nil
        let outcome = deliver(route)
        if let message = outcome.fallbackStatus {
            // Nothing reached the target: keep the panel up so the user can
            // see what to do with the copy.
            setStatus(message, duration: 5)
        } else {
            panel?.hide(activatePrevious: false)
        }
    }

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

    /// Width left for a result title after the rail, card/row insets, icon,
    /// badge and spacer. Err narrow so a long title is predicted to wrap.
    private var titleColumnWidth: CGFloat {
        let panelWidth = CGFloat(windowConfig.launcherSize(for: screenSize).width)
        let rail: CGFloat = providerBar == .left ? LauncherMetrics.railWidth : 0
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

    /// Width of the beside-list preview pane. ⌥P grows the pane, which takes
    /// the extra width out of the list area; the window itself never changes.
    public var previewPaneWidth: CGFloat {
        guard previewLayout == .beside, previewFocused else { return 300 }
        return max(300, min(640, windowConfig.launcherSize(for: screenSize).width - 420))
    }

    /// Height of the below-list preview pane. ⌥P grows it inside the fixed
    /// frame, shrinking the list card instead of the window.
    public var previewPaneHeight: CGFloat {
        guard previewLayout == .below, previewFocused else { return 220 }
        let frame = windowConfig.launcherSize(for: screenSize)
        return min(520, max(220, frame.height - 420))
    }

    public func openTerminalPanel(command: String? = nil, sessionName: String? = nil) {
        scratchpadGeneration += 1
        terminalInitialCommand = command
        terminalSessionName = sessionName
        terminalExitCode = nil
        terminalActive = true
        scratchpadActive = false
        previewEnabled = false
        previewFocused = false
        actionsMode = false
        actionItems = []
        panel?.show()
        requestFocus()
    }

    public func closeTerminalPanel() {
        guard terminalActive else { return }
        terminalActive = false
        terminalExitCode = nil
        terminalSessionName = nil
        NotificationCenter.default.post(name: .paletteTerminalStop, object: nil)
        focusZone = .search
        resetting = true
        query = ""
        resetting = false
        scheduleSearch(debounce: false)
    }

    /// Called by the terminal pane when its child exits. The pane stays open so
    /// the last output can still be read.
    public func noteTerminalExited(_ code: Int32?) {
        guard terminalActive else { return }
        terminalExitCode = code
    }

    /// Runs the pane's initial command again after the child exited.
    public func restartTerminal() {
        guard terminalActive, terminalExitCode != nil else { return }
        terminalExitCode = nil
        terminalRestartToken += 1
    }

    /// True while the list (not the editor) is the visible scratchpad surface.
    public var scratchpadListActive: Bool {
        !scratchpadActive
            && registry.parser.parse(query).providerID == HotkeyTargets.scratchpadListTrigger
    }

    /// The ⌘⌥S target: the scratchpad provider's list, New Scratch Note first.
    public func openScratchpadList() {
        if terminalActive { closeTerminalPanel() }
        if scratchpadActive { closeScratchpad(save: true) }
        scopeProviderID = nil
        resetToPlainQuery()
        resetting = true
        query = HotkeyTargets.scratchpadListQuery(prefix: registry.parser.prefix)
        resetting = false
        focusZone = .search
        panel?.show()
        requestFocus()
        scheduleSearch(debounce: false)
    }

    public func openScratchpad(noteID: String? = nil, seed: String? = nil) {        if terminalActive { closeTerminalPanel() }
        scratchpadGeneration += 1
        let generation = scratchpadGeneration
        panel?.show()
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
                guard let self else { return }
                await self.scratchpadSaveTask?.value
                guard let note = try? await self.store.scratchNote(id: noteID) else { return }
                guard self.scratchpadGeneration == generation, self.scratchpadNoteID == noteID else { return }
                self.scratchpadTitle = note.title
                self.scratchpadText = note.text
            }
        } else if seed == nil {
            Task { [weak self] in
                guard let self else { return }
                await self.scratchpadSaveTask?.value
                if let note = try? await self.store.scratchNotes(limit: 1).first {
                    guard self.scratchpadGeneration == generation else { return }
                    self.scratchpadNoteID = note.id
                    self.scratchpadTitle = note.title
                    self.scratchpadText = note.text
                } else if let legacy = try? await self.store.metaValue("scratchpad.text"),
                          !legacy.isEmpty {
                    guard self.scratchpadGeneration == generation else { return }
                    self.scratchpadText = legacy
                }
            }
        }
        requestFocus()
    }

    public func closeScratchpad(save: Bool) {
        guard scratchpadActive else { return }
        scratchpadGeneration += 1
        let generation = scratchpadGeneration
        if save {
            let title = scratchpadTitle
            let text = scratchpadText
            let noteID = scratchpadNoteID
            if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                scratchpadSaveTask = Task { [weak self] in
                    guard let self,
                          let note = try? await self.store.saveScratchNote(
                            id: noteID,
                            title: title,
                            text: text
                          ) else { return }
                    guard self.scratchpadGeneration == generation else { return }
                    self.scratchpadNoteID = note.id
                }
            }
        }
        scratchpadActive = false
        focusZone = .search
        panel?.suppressAutoHide = false
        resetting = true
        query = ""
        resetting = false
        scheduleSearch(debounce: false)
        requestFocus()
    }

    /// Saves the open draft under the note it was opened from, so reopening
    /// restores it instead of creating a duplicate note.
    private func saveScratchpad() {
        let title = scratchpadTitle
        let text = scratchpadText
        let noteID = scratchpadNoteID
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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

    /// `applicationWillTerminate` cannot await, so block briefly on a detached
    /// save (the store actor is not main-actor bound) before the process exits.
    public func saveScratchpadOnTerminate() {
        let title = scratchpadTitle
        let text = scratchpadText
        let noteID = scratchpadNoteID
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let store = self.store
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            _ = try? await store.saveScratchNote(id: noteID, title: title, text: text)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
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
}
