import AppKit
import PaletteCore
import SwiftUI

/// Settings → Appearance theme browser. The catalogue loads off the main
/// thread and rows parse their theme only when SwiftUI asks for them, so the
/// first frame is a search field and an empty list, not 923 TOML files.
struct ThemeBrowserView: View {
    @ObservedObject var themeManager: ThemeManager
    @Binding var selection: ThemeSelection
    let themesDirectory: URL

    @State private var browser: ThemeBrowserSession?
    @State private var previewTheme: Theme?
    @State private var status: String?
    @FocusState private var listFocused: Bool

    private var theme: Theme { themeManager.theme }

    private var muted: Color { theme.color(theme.palette.fgMuted) }

    private var query: Binding<String> {
        Binding(
            get: { browser?.query ?? "" },
            set: { value in
                guard var session = browser else { return }
                session.query = value
                browser = session
            }
        )
    }

    private var selectedName: String? { browser?.selected }

    private var visibleThemes: [ThemeInfo] { browser?.visibleThemes ?? [] }

    /// The theme currently on screen, which is the slot Revert goes back to.
    private var currentSlotName: String {
        switch selection.mode {
        case .dark: return selection.dark
        case .light: return selection.light
        case .auto: return theme.appearance == "light" ? selection.light : selection.dark
        }
    }

    private var currentDisplayName: String { theme.name }

    private func isCurrent(_ info: ThemeInfo) -> Bool {
        info.name == currentSlotName || info.displayName == theme.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(alignment: .top, spacing: 12) {
                listPane
                    .frame(width: 280)
                Divider()
                previewPane
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 430)
        }
        .task { await loadCatalog() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Current · \(currentDisplayName)")
                .font(theme.font(size: 11))
                .foregroundStyle(muted)
                .lineLimit(1)
            Spacer()
            if let catalog = browser?.catalog {
                Text("\(visibleThemes.count) of \(catalog.count) themes")
                    .font(.system(size: 10))
                    .foregroundStyle(muted.opacity(0.8))
                    .monospacedDigit()
            }
        }
    }

    private var listPane: some View {
        VStack(spacing: 6) {
            searchField
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                        ForEach(browser?.sections ?? []) { section in
                            Section {
                                ForEach(section.themes) { info in
                                    row(info, section: section.section)
                                        .id(info.name)
                                }
                            } header: {
                                sectionHeader(section)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .background(theme.color(theme.palette.surface))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(theme.color(theme.palette.border).opacity(0.7), lineWidth: 1)
                )
                .focusable()
                .focusEffectDisabled()
                .focused($listFocused)
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(keys: [.return]) { press in
                    if press.modifiers.contains(.command) {
                        applySelected()
                    } else {
                        previewSelected()
                    }
                    return .handled
                }
                .onChange(of: selectedName) { _, name in
                    guard let name else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(name, anchor: .center)
                    }
                }
            }
            .overlay {
                if browser == nil {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(muted)
            TextField("Search themes", text: query)
                .textFieldStyle(.plain)
                .font(theme.font(size: 12))
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(keys: [.return]) { press in
                    if press.modifiers.contains(.command) {
                        applySelected()
                    } else {
                        previewSelected()
                    }
                    return .handled
                }
            if !(browser?.query.isEmpty ?? true) {
                Button {
                    if var session = browser {
                        session.query = ""
                        browser = session
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear theme search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(theme.color(theme.palette.elevated).opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(theme.color(theme.palette.border).opacity(0.7), lineWidth: 1)
        )
    }

    private func sectionHeader(_ section: ThemeBrowserSection) -> some View {
        HStack(spacing: 6) {
            Text(section.title)
                .font(.system(size: 10, weight: .semibold))
            Spacer()
            Text("\(section.count)")
                .font(.system(size: 10))
                .monospacedDigit()
        }
        .foregroundStyle(muted)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.color(theme.palette.surface).opacity(0.96))
    }

    private func row(_ info: ThemeInfo, section: ThemeSection) -> some View {
        let selected = selectedName == info.name
        let isCurrent = isCurrent(info)
        let rowTheme = ThemeLoader.load(name: info.name, themesDirectory: themesDirectory).theme
        let accent = rowTheme.color(rowTheme.palette.accent)
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(info.displayName)
                    .font(theme.font(size: 11, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Text(info.appearance.capitalized)
                    .font(.system(size: 9))
                    .foregroundStyle(muted.opacity(0.85))
            }
            Spacer(minLength: 4)
            swatches(rowTheme)
            if isCurrent {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(selected ? accent.opacity(0.22) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(selected ? accent : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            listFocused = true
            preview(info.name)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(info, section: section))
        .accessibilityValue(isCurrent ? "Current theme" : info.appearance)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func swatches(_ theme: Theme) -> some View {
        HStack(spacing: 2) {
            ForEach(Array([theme.palette.bg, theme.palette.fg, theme.palette.accent,
                           theme.palette.danger, theme.palette.warning,
                           theme.palette.success, theme.palette.info].enumerated()), id: \.offset) { _, hex in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(theme.color(hex))
                    .frame(width: 8, height: 8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
                    )
            }
        }
        .accessibilityHidden(true)
    }

    private var previewPane: some View {
        let preview = previewTheme ?? theme
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(preview.name)
                    .font(theme.font(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(preview.appearance.capitalized)
                    .font(.system(size: 10))
                    .foregroundStyle(muted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(theme.color(theme.palette.elevated).opacity(0.7))
                    .clipShape(Capsule())
                Spacer()
                if selectedName == currentSlotName || preview.name == theme.name {
                    Text("Current")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(preview.color(preview.palette.accent))
                }
            }
            sample(preview)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(previewDescription(preview))
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button("Use Theme") { applySelected() }
                    .buttonStyle(.borderedProminent)
                    .tint(preview.color(preview.palette.accent))
                    .disabled(selectedName == nil)
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Revert") { revert() }
                    .disabled(selectedName == nil)
                if let status {
                    Label(status, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(theme.color(theme.palette.success))
                        .transition(.opacity)
                }
                Spacer()
            }
            Text("Preview only. Use Theme applies it app-wide; Revert puts the preview back on the current theme.")
                .font(.caption2)
                .foregroundStyle(muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sample(_ preview: Theme) -> some View {
        let sampleAccent = preview.color(preview.palette.accent)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                Text(preview.search.placeholder)
                    .font(preview.font(size: min(preview.typography.size, 15)))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("⌘K")
                    .font(preview.monoFont(size: 9))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(preview.color(preview.palette.bg).opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            .foregroundStyle(preview.color(preview.palette.fgMuted))
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(preview.color(preview.palette.elevated))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            resultRow(preview, title: "Safari", subtitle: "Application", icon: "safari", selected: true)
            resultRow(preview, title: "Theme Browser", subtitle: "Settings", icon: "paintpalette", selected: false)

            HStack(spacing: 5) {
                chip("apps", theme: preview, filled: true)
                chip("theme", theme: preview, filled: false)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("PREVIEW")
                    .font(preview.monoFont(size: 9, weight: .semibold))
                    .foregroundStyle(sampleAccent)
                Text("Palette — quick, local, yours")
                    .font(preview.font(size: min(preview.typography.size, 14)))
                    .foregroundStyle(preview.color(preview.palette.fg))
                    .lineLimit(1)
                Text("mono: glitch in the matrix")
                    .font(preview.monoFont(size: min(preview.typography.monoSize, 12)))
                    .foregroundStyle(preview.color(preview.palette.fgMuted))
                    .lineLimit(1)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(preview.color(preview.palette.surface))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(preview.color(preview.palette.border).opacity(0.6), lineWidth: 1)
            )
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(preview.color(preview.palette.bg))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(preview.color(preview.palette.border), lineWidth: 1)
        )
    }

    private func resultRow(
        _ preview: Theme,
        title: String,
        subtitle: String,
        icon: String,
        selected: Bool
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .frame(width: 16)
                .foregroundStyle(selected
                    ? preview.color(preview.palette.accent)
                    : preview.color(preview.palette.fgMuted))
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(preview.font(size: min(preview.typography.size, 13), weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Text(subtitle)
                    .font(preview.font(size: min(preview.typography.subtitleSize, 10)))
                    .foregroundStyle(preview.color(preview.palette.fgMuted))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if selected {
                Text("↩")
                    .font(preview.monoFont(size: 9))
                    .foregroundStyle(preview.color(preview.palette.selectionFg).opacity(0.75))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .foregroundStyle(selected
            ? preview.color(preview.palette.selectionFg)
            : preview.color(preview.palette.fg))
        .background(selected
            ? preview.color(preview.palette.selectionBg)
            : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func chip(_ title: String, theme preview: Theme, filled: Bool) -> some View {
        Text(title)
            .font(preview.monoFont(size: 9, weight: .medium))
            .foregroundStyle(filled
                ? preview.color(preview.palette.accentFg)
                : preview.color(preview.palette.fgMuted))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(filled
                ? preview.color(preview.palette.accent)
                : preview.color(preview.palette.elevated))
            .clipShape(Capsule())
    }

    private func previewDescription(_ preview: Theme) -> String {
        "Preview of \(preview.name), a \(preview.appearance) theme. "
            + "Background \(preview.palette.bg), foreground \(preview.palette.fg), "
            + "accent \(preview.palette.accent). Sample search field, two results with one selected, "
            + "provider chips and a preview card."
    }

    private func accessibilityLabel(_ info: ThemeInfo, section: ThemeSection) -> String {
        // Bundled ports already carry their source in the display name.
        info.section == .builtIn
            ? "\(section.title) · \(info.shortDisplayName)"
            : info.displayName
    }

    private func loadCatalog() async {
        guard browser == nil else { return }
        let directory = themesDirectory
        let catalog = await Task.detached(priority: .userInitiated) {
            ThemeBrowserCatalog(themes: ThemeLoader.catalog(themesDirectory: directory))
        }.value
        guard browser == nil else { return }
        var session = ThemeBrowserSession(
            catalog: catalog,
            selected: catalog.info(matching: theme.name)?.name ?? currentSlotName
        )
        if session.selectedInfo == nil {
            session = ThemeBrowserSession(catalog: catalog, selected: catalog.allThemes.first?.name)
        }
        browser = session
        if let name = session.selected {
            previewTheme = ThemeLoader.load(name: name, themesDirectory: themesDirectory).theme
        }
        listFocused = true
    }

    private func previewSelected() {
        guard let name = selectedName else { return }
        preview(name)
    }

    private func preview(_ name: String) {
        guard var session = browser else { return }
        session.select(name)
        browser = session
        previewTheme = ThemeLoader.load(name: name, themesDirectory: themesDirectory).theme
        status = nil
    }

    private func move(_ delta: Int) {
        guard var session = browser else { return }
        session.moveSelection(by: delta)
        browser = session
        if let name = session.selected {
            previewTheme = ThemeLoader.load(name: name, themesDirectory: themesDirectory).theme
        }
        status = nil
    }

    private func applySelected() {
        guard var session = browser, let name = session.selected else { return }
        let updated = session.applying(to: selection, activeAppearance: theme.appearance)
        selection = updated
        themeManager.selection = updated
        themeManager.select(name)
        session.markApplied()
        browser = session
        previewTheme = ThemeLoader.load(name: name, themesDirectory: themesDirectory).theme
        status = "Theme applied"
    }

    private func revert() {
        guard var session = browser else { return }
        session.revert(to: theme.name)
        if session.selectedInfo == nil {
            session.revert(to: currentSlotName)
        }
        browser = session
        let name = session.selected ?? currentSlotName
        previewTheme = ThemeLoader.load(name: name, themesDirectory: themesDirectory).theme
        status = nil
    }
}
