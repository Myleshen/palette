import AppKit
import PaletteCore
import PalettePlatform
import SwiftUI

extension RGBA {
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

extension Theme {
    func color(_ hex: String, fallback: String = "#ffffff") -> Color {
        (RGBA(hex: hex) ?? RGBA(hex: fallback) ?? RGBA(red: 1, green: 1, blue: 1)).color
    }

    func nsColor(_ hex: String, fallback: String = "#ffffff") -> NSColor {
        (RGBA(hex: hex) ?? RGBA(hex: fallback) ?? RGBA(red: 1, green: 1, blue: 1)).nsColor
    }

    func font(size: Double, weight: Font.Weight = .regular) -> Font {
        let family = typography.family.trimmingCharacters(in: .whitespaces)
        if family.isEmpty || family == "SF Pro Text" || family == "System" {
            return .system(size: size, weight: weight)
        }
        return .custom(family, size: size).weight(weight)
    }

    func nsFont(size: Double, weight: NSFont.Weight = .regular) -> NSFont {
        let family = typography.family.trimmingCharacters(in: .whitespaces)
        guard !family.isEmpty, family != "SF Pro Text", family != "System",
              let base = NSFont(name: family, size: size) else {
            return NSFont.systemFont(ofSize: size, weight: weight)
        }
        let descriptor = base.fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.weight: weight],
        ])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    var matchWeight: Font.Weight {
        switch typography.matchWeight.lowercased() {
        case "regular": return .regular
        case "medium": return .medium
        case "bold": return .bold
        default: return .semibold
        }
    }

    var scrollAnimation: Animation? {
        if motion.style.lowercased() == "instant" { return nil }
        let duration = max(0, motion.durationMs) / 1_000
        return .easeOut(duration: duration)
    }
}

struct HighlightedText: View {
    var text: String
    var terms: [String]
    var theme: Theme
    var size: Double
    var base: String
    var match: String? = nil
    var weight: Font.Weight = .regular

    var body: some View {
        Text(attributed)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var attributed: AttributedString {
        let font = theme.nsFont(size: size, weight: weight.nsWeight)
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: theme.nsColor(base),
            ]
        )
        let matchColor = theme.nsColor(match ?? theme.palette.matchFg)
        let matchFont = theme.nsFont(size: size, weight: theme.matchWeight.nsWeight)
        for term in terms where !term.isEmpty {
            var searchRange = text.startIndex..<text.endIndex
            while let found = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
                let nsRange = NSRange(found, in: text)
                result.addAttribute(.foregroundColor, value: matchColor, range: nsRange)
                result.addAttribute(.font, value: matchFont, range: nsRange)
                searchRange = found.upperBound..<text.endIndex
            }
        }
        return AttributedString(result)
    }
}

private extension Font.Weight {
    var nsWeight: NSFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
}

struct ItemIconView: View {
    var item: PaletteItem
    var theme: Theme
    var size: CGFloat? = nil

    private var iconSize: CGFloat { size ?? CGFloat(theme.effectiveIconSize) }

    var body: some View {
        Group {
            if let image = IconProvider.shared.image(for: item.icon, size: iconSize) {
                if theme.list.iconStyle.lowercased() == "monochrome" {
                    Image(nsImage: monochrome(image))
                        .resizable()
                        .interpolation(.high)
                        .renderingMode(.template)
                        .foregroundColor(theme.color(theme.palette.fgMuted))
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                }
            } else {
                Image(systemName: "square.dashed")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(theme.color(theme.palette.fgMuted))
            }
        }
        .frame(width: iconSize, height: iconSize)
    }

    private func monochrome(_ image: NSImage) -> NSImage {
        guard let copy = image.copy() as? NSImage else { return image }
        copy.isTemplate = true
        return copy
    }
}

struct BadgeView: View {
    var text: String
    var theme: Theme
    var pill: Bool = false

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(theme.color(theme.palette.badgeFg))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(theme.color(theme.palette.badgeBg).opacity(0.8))
            .clipShape(pill ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: 4, style: .continuous)))
    }
}

struct ResultRow: View {
    var item: PaletteItem
    var selected: Bool
    var terms: [String]
    var showProvider: Bool
    var theme: Theme
    var pill: Bool = false

    private var selectedBase: String {
        pill ? theme.palette.fg : (theme.states.selected.fg ?? theme.palette.selectionFg)
    }

    private var selectedMatch: String {
        pill ? theme.palette.accent : selectedBase
    }

    private var subtitleColor: String {
        if selected {
            return pill ? theme.palette.fgMuted : selectedBase
        }
        return theme.palette.fgMuted
    }

    var body: some View {
        HStack(spacing: 10) {
            if theme.list.showIcons {
                ItemIconView(item: item, theme: theme)
            }
            VStack(alignment: .leading, spacing: 2) {
                HighlightedText(
                    text: item.title,
                    terms: terms,
                    theme: theme,
                    size: theme.typography.size,
                    base: selected ? selectedBase : theme.palette.fg,
                    match: selected ? selectedMatch : nil,
                    weight: .regular
                )
                if theme.list.showSubtitles, let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: theme.typography.subtitleSize))
                        .foregroundColor(theme.color(subtitleColor).opacity(selected && !pill ? 0.7 : 1))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let badge = item.badge {
                BadgeView(text: badge, theme: theme, pill: pill)
            }
            if showProvider, let name = item.providerName, !name.isEmpty, item.providerID != "apps" {
                Text(name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.color(selected && !pill ? selectedBase : theme.palette.fgMuted)
                        .opacity(selected && !pill ? 0.75 : 0.8))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: CGFloat(theme.effectiveRowHeight))
        .background(selectionBackground)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var selectionBackground: some View {
        let style = theme.list.selection.lowercased()
        let color = theme.color(theme.states.selected.bg ?? theme.palette.selectionBg)
        if selected {
            switch style {
            case "bar":
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(theme.color(theme.palette.accent))
                        .frame(width: 3)
                        .padding(.vertical, 6)
                    Spacer()
                }
                .padding(.leading, 2)
            case "outline":
                if pill {
                    Capsule().strokeBorder(theme.color(theme.palette.accent).opacity(0.7), lineWidth: 1)
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.color(theme.palette.accent).opacity(0.7), lineWidth: 1)
                }
            case "none":
                Color.clear
            default:
                if pill {
                    Capsule()
                        .fill(theme.color(theme.palette.accent).opacity(0.18))
                        .overlay(
                            Capsule().strokeBorder(theme.color(theme.palette.accent).opacity(0.55), lineWidth: 1)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(color.opacity(0.95))
                }
            }
        } else {
            Color.clear
        }
    }
}

struct ActionRow: View {
    var action: PaletteAction
    var selected: Bool
    var theme: Theme
    var pill: Bool = false

    private var actionIcon: String {
        if action.concealed { return "lock.fill" }
        let id = action.id.lowercased()
        if id.contains("pin") { return "pin" }
        if id.contains("delete") { return "trash" }
        if id.contains("unlock") { return "lock.open" }
        if id.contains("login") { return "person.crop.circle" }
        if id.contains("install") { return "arrow.down.circle" }
        if id.contains("reload") { return "arrow.clockwise" }
        if id.contains("open") { return "arrow.up.forward.square" }
        switch action.kind {
        case .copyText: return "doc.on.doc"
        case .pasteText: return "doc.on.clipboard"
        case .copyImage: return "photo.on.rectangle"
        case .pasteImage: return "photo"
        case .copyFiles: return "doc.on.doc.fill"
        case .pasteFiles: return "folder.badge.plus"
        case .openURL: return "globe"
        case .run: return "terminal"
        case .openPath, .openPathWith: return "arrow.up.forward.app"
        case .reveal: return "folder"
        case .custom: return "sparkles"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: actionIcon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: CGFloat(theme.effectiveIconSize))
                .foregroundColor(theme.color(selected
                    ? (pill ? theme.palette.accent : theme.palette.selectionFg)
                    : theme.palette.fgMuted))
            Text(action.title)
                .font(.system(size: theme.typography.size))
                .foregroundColor(theme.color(selected
                    ? (pill ? theme.palette.fg : (theme.states.selected.fg ?? theme.palette.selectionFg))
                    : theme.palette.fg))
                .lineLimit(1)
            Spacer()
            if let shortcut = action.shortcut {
                Text(shortcut)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(theme.color(theme.palette.fgMuted))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: CGFloat(theme.effectiveRowHeight))
        .background(selectionBackground)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var selectionBackground: some View {
        let style = theme.list.selection.lowercased()
        let color = theme.color(theme.states.selected.bg ?? theme.palette.selectionBg)
        if selected {
            switch style {
            case "bar":
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(theme.color(theme.palette.accent))
                        .frame(width: 3)
                        .padding(.vertical, 6)
                    Spacer()
                }
                .padding(.leading, 2)
            case "outline":
                if pill {
                    Capsule().strokeBorder(theme.color(theme.palette.accent).opacity(0.7), lineWidth: 1)
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.color(theme.palette.accent).opacity(0.7), lineWidth: 1)
                }
            case "none":
                Color.clear
            default:
                if pill {
                    Capsule()
                        .fill(theme.color(theme.palette.accent).opacity(0.18))
                        .overlay(
                            Capsule().strokeBorder(theme.color(theme.palette.accent).opacity(0.55), lineWidth: 1)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(color.opacity(0.95))
                }
            }
        } else {
            Color.clear
        }
    }
}

struct LauncherRootView: View {
    @ObservedObject var controller: SearchController
    @EnvironmentObject var themeManager: ThemeManager
    @FocusState private var searchFocused: Bool
    @FocusState private var promptFocused: Bool

    private var theme: Theme { themeManager.theme }
    private var isPill: Bool { controller.searchStyle == .pill }

    var body: some View {
        Group {
            if isPill {
                pillLayout
            } else {
                classicLayout
            }
        }
        .environment(\.colorScheme, theme.appearance == "light" ? .light : .dark)
        .onAppear {
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: controller.focusToken) { _, _ in
            DispatchQueue.main.async {
                if controller.prompt != nil { promptFocused = true } else { searchFocused = true }
            }
        }
        .onChange(of: controller.prompt?.id) { _, _ in
            DispatchQueue.main.async { promptFocused = controller.prompt != nil }
        }
    }

    /// Classic is one continuous panel.
    private var classicLayout: some View {
        VStack(spacing: 0) {
            searchBar
            Rectangle()
                .fill(theme.color(theme.palette.separator))
                .frame(height: 1)
            tabBar
            content
            if theme.footer.show {
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.color(theme.palette.bg).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: CGFloat(theme.window.cornerRadius), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CGFloat(theme.window.cornerRadius), style: .continuous)
                .strokeBorder(theme.color(theme.palette.border).opacity(0.55), lineWidth: CGFloat(theme.window.borderWidth))
        )
    }

    /// Pill separates the search capsule from the content card, like the
    /// floating Siri search surface. The window itself stays transparent.
    private var pillLayout: some View {
        VStack(spacing: 10) {
            searchBar
            pillContentCard
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var pillContentCard: some View {
        VStack(spacing: 0) {
            tabBar
            content
            if theme.footer.show {
                footer
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(theme.color(theme.palette.bg).opacity(0.96))
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(theme.color(theme.palette.border).opacity(0.5), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    private var tabBar: some View {
        VStack(spacing: 0) {
            if controller.activeTabID == "clip" {
                HStack(spacing: 6) {
                    filterChip("All", value: nil)
                    filterChip("Text", value: "text")
                    filterChip("Images", value: "image")
                    filterChip("Files", value: "files")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, isPill ? 14 : 12)
                .padding(.top, isPill ? 8 : 6)
            }
            if isPill {
                FlowLayout(spacing: 3) {
                    ForEach(controller.providerTabs) { tab in
                        tabChip(tab)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(controller.providerTabs) { tab in
                            tabChip(tab)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
            Rectangle()
                .fill(theme.color(theme.palette.separator).opacity(isPill ? 0.35 : 0.6))
                .frame(height: 1)
        }
    }

    private func tabChip(_ tab: SearchController.ProviderTab) -> some View {
        let selected = controller.activeTabID == tab.id
        let title = isPill ? shortTabTitle(tab.title) : tab.title
        return Button {
            controller.selectTab(tab.id)
        } label: {
            HStack(spacing: 4) {
                if let icon = tabIcon(tab.icon) {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: isPill ? 10.5 : 10.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(theme.color(selected
                ? theme.palette.accent
                : theme.palette.fgMuted))
            .padding(.horizontal, isPill ? 8 : 10)
            .padding(.vertical, isPill ? 5 : 4)
            .background(
                Capsule().fill(
                    selected
                        ? theme.color(theme.palette.accent).opacity(isPill ? 0.2 : 0.16)
                        : Color.clear
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    theme.color(theme.palette.accent).opacity(selected && isPill ? 0.45 : 0),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
    }

    private func shortTabTitle(_ title: String) -> String {
        if title.hasPrefix("Bitwarden ") {
            let suffix = String(title.dropFirst("Bitwarden ".count))
            return suffix == "Usernames" ? "BW Users" : "BW " + suffix
        }
        if title == "Clipboard History" { return "Clipboard" }
        if title == "Neovide Folders" { return "Folders" }
        if title == "Zellij Sessions" { return "Zellij" }
        return title
    }

    private func filterChip(_ title: String, value: String?) -> some View {
        let selected = controller.effectiveClipboardFilter == value
        return Button {
            controller.setClipboardFilter(value)
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.color(selected ? theme.palette.accentFg : theme.palette.fgMuted))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(selected
                        ? theme.color(theme.palette.accent)
                        : theme.color(theme.palette.elevated))
                )
        }
        .buttonStyle(.plain)
    }

    private func tabIcon(_ raw: String?) -> String? {
        guard let raw, raw.hasPrefix("symbol:") else { return nil }
        return String(raw.dropFirst(7))
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            if theme.search.showIcon {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(theme.color(theme.palette.accent))
            }
            ZStack(alignment: .leading) {
                if controller.query.isEmpty {
                    Text(theme.search.placeholder)
                        .font(theme.font(size: theme.typography.size + 3))
                        .foregroundColor(theme.color(theme.palette.fgMuted).opacity(0.55))
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
                TextField("", text: $controller.query)
                    .textFieldStyle(.plain)
                    .font(theme.font(size: theme.typography.size + 3))
                    .foregroundColor(theme.color(theme.palette.fg))
                    .focused($searchFocused)
                    .disabled(controller.prompt != nil)
                    .accessibilityLabel(theme.search.placeholder)
                    .onSubmit {
                        if controller.actionsMode { controller.executeAction() } else { controller.executePrimary() }
                    }
            }
            if controller.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
            if let scope = controller.scopeLabel {
                Text(scope)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.color(theme.palette.accent))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(theme.color(theme.palette.accent).opacity(0.14))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, isPill ? 24 : 16)
        .frame(height: isPill ? CGFloat(theme.search.height) - 12 : CGFloat(theme.search.height))
        .background(
            Capsule()
                .fill(theme.color(theme.palette.surface).opacity(isPill ? 0.96 : 0))
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    theme.color(theme.palette.accent).opacity(isPill ? 0.30 : 0),
                    lineWidth: 1
                )
        )
        .shadow(
            color: .black.opacity(isPill ? 0.12 : 0),
            radius: isPill ? 6 : 0,
            y: isPill ? 2 : 0
        )
    }

    @ViewBuilder
    private var content: some View {
        if let prompt = controller.prompt {
            PromptView(prompt: prompt, controller: controller, theme: theme, focused: $promptFocused, pill: isPill)
        } else if controller.actionsMode {
            actionsView
        } else if controller.previewEnabled {
            HStack(spacing: 0) {
                resultsView
                Rectangle()
                    .fill(theme.color(theme.palette.separator))
                    .frame(width: 1)
                ClipboardPreviewPane(item: controller.selectedItem, theme: theme)
                    .frame(width: 320)
            }
        } else {
            resultsView
        }
    }

    private var resultsView: some View {
        Group {
            if controller.items.isEmpty {
                emptyState
            } else if controller.isGridMode {
                gridView
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: isPill ? 6 : CGFloat(theme.list.spacing)) {
                            ForEach(Array(controller.items.enumerated()), id: \.element.stableID) { index, item in
                                if controller.previewEnabled,
                                   let group = item.group,
                                   index == 0 || controller.items[index - 1].group != group {
                                    Text(group.uppercased())
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(theme.color(theme.palette.fgMuted))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.leading, 10)
                                        .padding(.top, 8)
                                }
                                ResultRow(
                                    item: item,
                                    selected: index == controller.selectionIndex,
                                    terms: controller.highlightTerms,
                                    showProvider: controller.scopeLabel == nil,
                                    theme: theme,
                                    pill: isPill
                                )
                                .id(item.stableID)
                                .onTapGesture { controller.activate(index) }
                            }
                        }
                        .padding(.horizontal, isPill ? 14 : 6)
                        .padding(.vertical, isPill ? 6 : 4)
                    }
                    .scrollIndicators(theme.list.showScrollbar ? .visible : .hidden)
                    .onChange(of: controller.selectionIndex) { _, _ in
                        guard controller.items.indices.contains(controller.selectionIndex) else { return }
                        let stableID = controller.items[controller.selectionIndex].stableID
                        withAnimation(theme.scrollAnimation) {
                            proxy.scrollTo(stableID, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if isPill, !controller.isGridMode, !controller.items.isEmpty {
                LinearGradient(
                    colors: [
                        theme.color(theme.palette.bg).opacity(0),
                        theme.color(theme.palette.bg).opacity(0.96),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 26)
                .allowsHitTesting(false)
            }
        }
    }

    private var gridView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 8),
                        count: controller.gridColumns
                    ),
                    spacing: 8
                ) {
                    ForEach(Array(controller.items.enumerated()), id: \.element.stableID) { index, item in
                        VStack(spacing: 4) {
                            ItemIconView(item: item, theme: theme, size: 40)
                            Text(item.title)
                                .font(theme.font(size: 11))
                                .foregroundColor(theme.color(
                                    index == controller.selectionIndex
                                        ? (theme.states.selected.fg ?? theme.palette.selectionFg)
                                        : theme.palette.fg
                                ))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 78)
                        .padding(.horizontal, 2)
                        .background(
                            Group {
                                if isPill {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(index == controller.selectionIndex
                                            ? theme.color(theme.states.selected.bg ?? theme.palette.selectionBg)
                                            : Color.clear)
                                } else {
                                    RoundedRectangle(cornerRadius: 9)
                                        .fill(index == controller.selectionIndex
                                              ? theme.color(theme.states.selected.bg ?? theme.palette.selectionBg)
                                              : Color.clear)
                                }
                            }
                        )
                        .contentShape(Rectangle())
                        .id(item.stableID)
                        .onTapGesture { controller.activate(index) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .scrollIndicators(theme.list.showScrollbar ? .visible : .hidden)
            .onChange(of: controller.selectionIndex) { _, _ in
                guard controller.items.indices.contains(controller.selectionIndex) else { return }
                let stableID = controller.items[controller.selectionIndex].stableID
                withAnimation(theme.scrollAnimation) {
                    proxy.scrollTo(stableID, anchor: .center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var actionsView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "command")
                Text("Actions")
                    .font(.system(size: 10, weight: .semibold))
                if let item = controller.selectedItem {
                    Text("· \(item.title)")
                        .font(.system(size: 10))
                        .foregroundColor(theme.color(theme.palette.fgMuted))
                        .lineLimit(1)
                }
                Spacer()
            }
            .foregroundColor(theme.color(theme.palette.fgMuted))
            .padding(.horizontal, isPill ? 20 : 16)
            .frame(height: 34)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: CGFloat(theme.list.spacing)) {
                        ForEach(Array(controller.actionItems.enumerated()), id: \.element.id) { index, action in
                            ActionRow(
                                action: action,
                                selected: index == controller.actionIndex,
                                theme: theme,
                                pill: isPill
                            )
                            .id(action.id)
                            .onTapGesture {
                                controller.actionIndex = index
                                controller.executeAction()
                            }
                        }
                    }
                    .padding(.horizontal, isPill ? 14 : 6)
                    .padding(.bottom, isPill ? 6 : 4)
                }
                .scrollIndicators(theme.list.showScrollbar ? .visible : .hidden)
                .onChange(of: controller.actionIndex) { _, _ in
                    guard controller.actionItems.indices.contains(controller.actionIndex) else { return }
                    proxy.scrollTo(controller.actionItems[controller.actionIndex].id, anchor: .center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: controller.isSearching ? "hourglass" : "sparkle.magnifyingglass")
                .font(.system(size: 18, weight: .light))
                .foregroundColor(theme.color(theme.palette.fgMuted).opacity(0.8))
            Text(emptyMessage)
                .font(.system(size: 12))
                .foregroundColor(theme.color(theme.palette.fgMuted))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyMessage: String {
        if controller.isSearching { return "Searching…" }
        if controller.query.isEmpty { return "Start typing to search" }
        return "No results"
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let status = controller.statusMessage {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                Text(status)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if controller.actionsMode {
                hint("↑↓", "Select")
                hint("⏎", "Run")
                hint("esc", "Back")
            } else {
                hint("↑↓", "Navigate")
                hint("⏎", "Open")
                hint("⌘⏎", "Secondary")
                hint("⌘K", "Actions")
                hint("⌘R", "Reload")
                hint("esc", "Close")
            }
            Spacer(minLength: 4)
            Text(theme.name)
                .foregroundColor(theme.color(theme.palette.fgMuted).opacity(0.55))
                .lineLimit(1)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(theme.color(theme.footer.hintColor))
        .padding(.horizontal, isPill ? 20 : 16)
        .frame(height: 28)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(theme.color(theme.palette.elevated).opacity(0.7))
                .clipShape(isPill
                    ? AnyShape(Capsule())
                    : AnyShape(RoundedRectangle(cornerRadius: 3, style: .continuous)))
            Text(label)
        }
        .foregroundColor(theme.color(theme.footer.hintColor))
    }
}

struct PromptView: View {
    var prompt: PromptState
    var controller: SearchController
    var theme: Theme
    var focused: FocusState<Bool>.Binding
    var pill: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.color(theme.palette.fg))
            if prompt.kind == .confirm {
                Text("This action cannot be undone.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color(theme.palette.fgMuted))
            } else if prompt.kind == .secureText {
                SecureField(prompt.placeholder ?? "Password", text: Binding(
                    get: { controller.promptValue },
                    set: { controller.promptValue = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(8)
                .background(theme.color(theme.palette.surface))
                .clipShape(pill ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous)))
                .focused(focused)
                .onSubmit { controller.submitPrompt() }
            } else {
                TextField(prompt.placeholder ?? "Input", text: Binding(
                    get: { controller.promptValue },
                    set: { controller.promptValue = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(8)
                .background(theme.color(theme.palette.surface))
                .clipShape(pill ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous)))
                .focused(focused)
                .onSubmit { controller.submitPrompt() }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { controller.cancelPrompt() }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(theme.color(theme.palette.elevated))
                    .clipShape(pill ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous)))
                Button(prompt.kind == .confirm ? "Confirm" : "Continue") { controller.submitPrompt() }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.color(theme.palette.accentFg))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(theme.color(theme.palette.accent))
                    .clipShape(pill ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous)))
            }
            .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Right-hand preview used by the dedicated clipboard window. Text is shown
/// verbatim, images at their stored size, and Finder selections get icons,
/// `stat` metadata plus a `bat` render for plain-text files.
struct ClipboardPreviewPane: View {
    var item: PaletteItem?
    var theme: Theme

    @State private var files: [FileDetail] = []
    @State private var textPreview: String?

    private struct FileDetail: Sendable {
        var name: String
        var path: String
        var size: Int64
        var isDirectory: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item {
                Text(item.title)
                    .font(theme.font(size: 13, weight: .semibold))
                    .foregroundColor(theme.color(theme.palette.fg))
                    .lineLimit(2)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(theme.color(theme.palette.fgMuted))
                        .lineLimit(2)
                }
                Rectangle()
                    .fill(theme.color(theme.palette.separator))
                    .frame(height: 1)
                preview(for: item)
            } else {
                Text("Nothing selected")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color(theme.palette.fgMuted))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: item?.stableID) { await load() }
    }

    @ViewBuilder
    private func preview(for item: PaletteItem) -> some View {
        switch item.preview {
        case .text(let value):
            ScrollView {
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.color(theme.palette.fg))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .image(let base64, let width, let height):
            VStack(alignment: .leading, spacing: 6) {
                if let data = Data(base64Encoded: base64), let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 250)
                }
                Text("\(width) × \(height) px")
                    .font(.system(size: 10))
                    .foregroundColor(theme.color(theme.palette.fgMuted))
            }
        case .files(let paths):
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(files, id: \.path) { file in
                        HStack(alignment: .top, spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                                .resizable()
                                .frame(width: 26, height: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(theme.color(theme.palette.fg))
                                    .lineLimit(1)
                                Text("\(file.isDirectory ? "folder" : Self.byteCount(file.size)) · \(file.path)")
                                    .font(.system(size: 9))
                                    .foregroundColor(theme.color(theme.palette.fgMuted))
                                    .lineLimit(2)
                            }
                        }
                    }
                    if let textPreview {
                        Rectangle()
                            .fill(theme.color(theme.palette.separator))
                            .frame(height: 1)
                        Text(textPreview)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(theme.color(theme.palette.fg))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if paths.isEmpty {
                        Text("No paths")
                            .font(.system(size: 11))
                            .foregroundColor(theme.color(theme.palette.fgMuted))
                    }
                }
            }
        case nil:
            Text("No preview available")
                .font(.system(size: 11))
                .foregroundColor(theme.color(theme.palette.fgMuted))
        }
    }

    private func load() async {
        files = []
        textPreview = nil
        guard let item, case .files(let paths) = item.preview else { return }

        let result = await Task.detached(priority: .userInitiated) { () -> ([FileDetail], String?) in
            let manager = FileManager.default
            var details: [FileDetail] = []
            for path in paths.prefix(8) {
                let attributes = try? manager.attributesOfItem(atPath: path)
                details.append(FileDetail(
                    name: (path as NSString).lastPathComponent,
                    path: path,
                    size: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
                    isDirectory: (attributes?[.type] as? FileAttributeType) == .typeDirectory
                ))
            }
            var rendered: String?
            if paths.count == 1, let path = paths.first, details.first?.isDirectory == false {
                rendered = Self.batPreview(path)
            }
            return (details, rendered)
        }.value

        files = result.0
        textPreview = result.1
    }

    /// `bat` is the system-friendly text renderer; plain read is the fallback.
    nonisolated private static func batPreview(_ path: String) -> String? {
        guard let bat = ToolLocator.shared.path(for: "bat") else {
            return (try? String(contentsOfFile: path, encoding: .utf8)).map { String($0.prefix(4_000)) }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bat)
        process.arguments = [
            "--color=never", "--style=plain", "--paging=never", "--wrap=character",
            "--terminal-width=48", "--line-range=1:80", path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (output?.isEmpty ?? true) ? nil : output
    }

    private static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Wraps provider chips onto as many rows as they need. The old horizontal
/// scroller hid half the providers behind a clipped edge; tab bars are for
/// discovery, so every provider should be visible.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = max(1, proposal.width ?? 600)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > bounds.width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
