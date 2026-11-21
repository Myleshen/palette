import AppKit
import class SwiftTerm.LocalProcessTerminalView
import PaletteCore
import PalettePlatform
import QuickLookUI
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

    var nsAppearance: NSAppearance? {
        NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
    }

    func font(size: Double, weight: Font.Weight = .regular) -> Font {        let family = typography.family.trimmingCharacters(in: .whitespaces)
        if family.isEmpty || family == "SF Pro Text" || family == "System" {
            return .system(size: size, weight: weight)
        }
        return .custom(family, size: size).weight(weight)
    }

    func monoFont(size: Double? = nil, weight: Font.Weight = .regular) -> Font {
        let family = typography.mono.trimmingCharacters(in: .whitespaces)
        let pointSize = size ?? typography.monoSize
        if family.isEmpty || family == "System" || family == "SF Mono"
            || NSFont(name: family, size: pointSize) == nil {
            return .system(size: pointSize, weight: weight, design: .monospaced)
        }
        return .custom(family, size: pointSize).weight(weight)
    }

    func nsFont(size: Double, weight: NSFont.Weight = .regular) -> NSFont {        let family = typography.family.trimmingCharacters(in: .whitespaces)
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

/// The two public accessibility prefs that change how glass may be painted.
/// Glass intensity itself is left to AppKit's own slider; no private prefs
/// (`NSGlassTintAmount` and friends) are read.
struct GlassPolicy: Equatable {
    var reduceTransparency = false
    var increaseContrast = false

    /// Public AppKit prefs, for views SwiftUI does not re-render for us.
    static var current: GlassPolicy {
        let workspace = NSWorkspace.shared
        return GlassPolicy(
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast
        )
    }
}

struct GlassBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    final class Coordinator {
        var observer: NSObjectProtocol?
    }

    private static let glassID = NSUserInterfaceItemIdentifier("palette.glass")
    private static let materialID = NSUserInterfaceItemIdentifier("palette.material")
    private static let opaqueID = NSUserInterfaceItemIdentifier("palette.opaque")

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 0
            glass.identifier = Self.glassID
            host.addSubview(glass)
        } else {
            let view = Self.materialView(material: material)
            view.identifier = Self.materialID
            host.addSubview(view)
        }
        let opaque = Self.materialView(material: .contentBackground)
        opaque.identifier = Self.opaqueID
        host.addSubview(opaque)
        for view in host.subviews {
            view.frame = host.bounds
            view.autoresizingMask = [.width, .height]
        }
        // SwiftUI only re-renders on the environment change; observe the AppKit
        // notifications too so the fallback swaps even outside a render pass.
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak host] _ in
            guard let host else { return }
            Self.apply(.current, to: host)
        }
        Self.apply(.current, to: host)
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        if #available(macOS 26.0, *),
           let glass = host.subviews.first(where: { $0.identifier == Self.glassID }) as? NSGlassEffectView {
            glass.style = .regular
        }
        Self.apply(.current, to: host)
    }

    static func dismantleNSView(_ host: NSView, coordinator: Coordinator) {
        if let observer = coordinator.observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private static func apply(_ policy: GlassPolicy, to host: NSView) {
        for view in host.subviews {
            switch view.identifier {
            case glassID, materialID:
                view.isHidden = policy.reduceTransparency
            case opaqueID:
                view.isHidden = !policy.reduceTransparency
            default:
                break
            }
        }
    }

    private static func materialView(material: NSVisualEffectView.Material) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }
}

/// Liquid Glass on macOS 26+, ultra-thin material before it. Reduce Transparency
/// replaces the glass with an opaque window background; Increase Contrast keeps
/// the glass and adds a hairline stroke.
struct GlassSurface<S: Shape>: View {
    var shape: S
    var tint: Color? = nil

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var policy: GlassPolicy {
        GlassPolicy(reduceTransparency: reduceTransparency, increaseContrast: contrast == .increased)
    }

    var body: some View {
        ZStack {
            if policy.reduceTransparency {
                if #available(macOS 26.0, *) {
                    Color.clear.glassEffect(.identity, in: shape)
                }
                shape.fill(Color(nsColor: .windowBackgroundColor))
            } else if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                shape.fill(.ultraThinMaterial)
            }
            if let tint {
                shape.fill(tint)
            }
        }
        .overlay {
            if policy.increaseContrast {
                shape.stroke(.primary.opacity(0.25), lineWidth: 1)
            }
        }
    }
}

/// One spacing scale for the whole launcher. Every card edge, gutter and text
/// column is derived from these, so the search pill, list card, preview card
/// and footer line up instead of each carrying its own inset.
enum LauncherMetrics {
    /// Window edge to every card.
    static let outerInset: CGFloat = 12
    /// Between the search pill and the content row, and between cards.
    static let cardGap: CGFloat = 10
    /// Radius shared by the list and preview cards.
    static let cardRadius: CGFloat = 16
    /// Content inset inside every card.
    static let innerPadding: CGFloat = 12
    /// Selection highlight radius.
    static let rowRadius: CGFloat = 10
    static let footerHeight: CGFloat = 44
}

/// The glass + theme fill + hairline used by every launcher card. Cards share
/// one radius, so the shape is not a parameter.
private struct CardSurface: ViewModifier {
    var theme: Theme
    var background: String?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: LauncherMetrics.cardRadius, style: .continuous)
    }

    /// Every card paints its own palette colour; glass only ever sits on top.
    var fill: Color {
        theme.color(background ?? theme.palette.bg)
            .opacity(theme.window.glass ? theme.window.glassOpacity : 1)
    }

    func body(content: Content) -> some View {
        content
            .background(GlassSurface(shape: shape))
            .background(shape.fill(fill))
            .clipShape(shape)
            .overlay(shape.strokeBorder(theme.color(theme.palette.border).opacity(0.45), lineWidth: 1))
    }
}

extension View {
    func cardSurface(theme: Theme, background: String? = nil) -> some View {
        modifier(CardSurface(theme: theme, background: background))
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

/// A mode or filter chip. Selection is a solid accent fill with a foreground
/// chosen for contrast, not accent text on a tint; 28pt tall for the pointer.
private struct ChipButton: View {
    var title: String
    var selected: Bool
    var theme: Theme
    var action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.font(size: 11, weight: .semibold))
                .lineLimit(1)
                .foregroundColor(selected
                    ? theme.color(theme.palette.accentFg)
                    : theme.color(hovered ? theme.palette.fg : theme.palette.fgMuted))
                .padding(.horizontal, 10)
                .frame(minHeight: 28)
                .background(
                    Capsule().fill(
                        selected
                            ? theme.color(theme.palette.accent)
                            : theme.color(theme.palette.elevated).opacity(hovered ? 1 : 0.55)
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct ResultRow: View {
    var item: PaletteItem
    var selected: Bool
    var terms: [String]
    var showProvider: Bool
    var theme: Theme
    var pill: Bool = false

    /// Armed hover: a parked or jittery pointer must not light a row, so the
    /// highlight waits until the pointer has moved more than a few points
    /// since it entered. Selection always outranks it.
    @State private var hoverOrigin: CGPoint?
    @State private var hoverArmed = false

    private var hovered: Bool { hoverArmed && !selected }

    private var selectedBase: String {
        theme.states.selected.fg ?? theme.palette.selectionFg
    }

    /// On a selected row every text colour comes from the selection pair;
    /// accent-on-accent made matched terms disappear.
    private var selectedMatch: String { selectedBase }

    private var subtitleColor: String {
        selected ? selectedBase : theme.palette.fgMuted
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
                        .foregroundColor(theme.color(subtitleColor))
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
                    .foregroundColor(theme.color(selected ? selectedBase : theme.palette.fgMuted))
                    .opacity(selected ? 1 : 0.8)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, LauncherMetrics.innerPadding)
        .frame(height: CGFloat(theme.effectiveRowHeight))
        .background(selectionBackground)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .global) { phase in
            switch phase {
            case .active(let location):
                if let origin = hoverOrigin {
                    if !hoverArmed, hypot(location.x - origin.x, location.y - origin.y) > 3 {
                        hoverArmed = true
                    }
                } else {
                    // First event in this row: arm it without highlighting.
                    hoverOrigin = location
                    hoverArmed = false
                }
            case .ended:
                hoverOrigin = nil
                hoverArmed = false
            }
        }
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
                RoundedRectangle(cornerRadius: LauncherMetrics.rowRadius, style: .continuous)
                    .strokeBorder(theme.color(theme.palette.accent).opacity(0.7), lineWidth: 1)
            case "none":
                Color.clear
            default:
                RoundedRectangle(cornerRadius: LauncherMetrics.rowRadius, style: .continuous)
                    .fill(color.opacity(0.95))
            }
        } else if hovered {
            // Deliberately weaker than selection, and absent when the user
            // turned selection backgrounds off.
            switch style {
            case "none":
                Color.clear
            default:
                RoundedRectangle(cornerRadius: LauncherMetrics.rowRadius, style: .continuous)
                    .fill(color.opacity(0.45))
            }
        } else {
            Color.clear
        }
    }
}

/// Read-only key reference shown at the end of the ⌘K action list.
private struct ShortcutHint: Identifiable {
    var keys: String
    var label: String
    var id: String { keys }
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
        if id.contains("term") { return "terminal" }
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
        .padding(.horizontal, LauncherMetrics.innerPadding)
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
                RoundedRectangle(cornerRadius: LauncherMetrics.rowRadius, style: .continuous)
                    .strokeBorder(theme.color(theme.palette.accent).opacity(0.7), lineWidth: 1)
            case "none":
                Color.clear
            default:
                RoundedRectangle(cornerRadius: LauncherMetrics.rowRadius, style: .continuous)
                    .fill(color.opacity(0.95))
            }
        } else {
            Color.clear
        }
    }
}

struct LauncherRootView: View {
    @ObservedObject var controller: SearchController
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    @FocusState private var promptFocused: Bool
    @State private var railScrollTarget: String?
    private var theme: Theme { themeManager.theme }
    private var isPill: Bool { true }

    var body: some View {
        GeometryReader { proxy in
            pillLayout(railCollapsed: controller.previewVisible || proxy.size.width < 700)
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

    /// One grid: search pill, the provider rail plus cards, then the footer.
    private func pillLayout(railCollapsed: Bool) -> some View {
        VStack(spacing: LauncherMetrics.cardGap) {
            searchBar
            HStack(alignment: .top, spacing: LauncherMetrics.cardGap) {
                rail(collapsed: railCollapsed)
                contentArea
            }
            if theme.footer.show {
                footer
            }
        }
        .padding(LauncherMetrics.outerInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Vertical provider rail: Everything first, one row per provider, full
    /// height between the search pill and the footer. Icons only when the
    /// preview is open or the panel is narrow.
    private func rail(collapsed: Bool) -> some View {
        GeometryReader { proxy in
            // Whole rows only: the scroll viewport is trimmed to a row
            // boundary so the last provider cannot be cut by the card edge.
            let pinned = LauncherMetrics.innerPadding + 32
            let inset: CGFloat = 20
            let stride: CGFloat = 34
            let rows = max(1, Int((proxy.size.height - pinned - inset) / stride))
            VStack(spacing: 0) {
                // Everything is pinned: the default scope must always be
                // one click away, even while the provider list scrolls.
                if let everything = controller.railEntries.first {
                    railRow(everything, collapsed: collapsed)
                        .padding(.horizontal, LauncherMetrics.innerPadding)
                        .padding(.top, LauncherMetrics.innerPadding)
                        .onTapGesture {
                            controller.selectRail(everything.id)
                            controller.railFocused = true
                        }
                }
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(controller.railEntries.dropFirst())) { entry in
                            railRow(entry, collapsed: collapsed)
                                .id(entry.id)
                                .onTapGesture {
                                    controller.selectRail(entry.id)
                                    controller.railFocused = true
                                }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, LauncherMetrics.innerPadding)
                    .padding(.horizontal, LauncherMetrics.innerPadding)
                    .scrollTargetLayout()
                }
                .frame(height: CGFloat(rows) * stride + 18)
                .scrollIndicators(theme.list.showScrollbar ? .visible : .hidden)
                .scrollPosition(id: $railScrollTarget, anchor: .center)
                .onChange(of: controller.activeRailID, initial: true) { _, id in
                    railScrollTarget = id == "everything" ? nil : id
                }
                Spacer(minLength: 0)
            }
        }
        .frame(width: collapsed ? 56 : 200)
        .frame(maxHeight: .infinity)
        .cardSurface(theme: theme)
    }

    /// Two initials keep "Editor" and "Editor Folders" apart when a provider
    /// ships no icon.
    private func railInitials(_ title: String) -> String {
        let words = title.split(whereSeparator: \.isWhitespace).prefix(2)
        return words.compactMap { $0.first }.map { String($0).uppercased() }.joined()
    }

    private func railRow(_ entry: SearchController.RailEntry, collapsed: Bool) -> some View {
        let selected = controller.activeRailID == entry.id
        let symbol = entry.icon.flatMap { raw -> String? in
            raw.hasPrefix("symbol:") ? String(raw.dropFirst("symbol:".count)) : nil
        }
        return HStack(spacing: collapsed ? 0 : 8) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: collapsed ? 24 : 16)
            } else {
                // A repeated grid glyph is worse than a letter: every row
                // stays distinguishable in the icon-only rail.
                Text(railInitials(entry.title))
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: collapsed ? 22 : 16, height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(theme.color(theme.palette.elevated))
                    )
            }
            if !collapsed {
                Text(entry.title)
                    .font(theme.font(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        // Accent, not a slightly lighter grey: the active provider has to be
        // obvious at a glance.
        .foregroundColor(theme.color(selected ? theme.palette.accentFg : theme.palette.fgMuted))
        .padding(.horizontal, collapsed ? 0 : 10)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: collapsed ? .center : .leading)
        .background(
            RoundedRectangle(cornerRadius: LauncherMetrics.rowRadius, style: .continuous)
                .fill(selected ? theme.color(theme.palette.accent) : Color.clear)
        )
        .contentShape(Rectangle())
        .help(entry.title)
        .accessibilityLabel(entry.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// The list card, plus the preview as its own card on the same grid.
    @ViewBuilder
    private var contentArea: some View {
        if controller.previewVisible, controller.previewLayout == .beside {
            HStack(spacing: LauncherMetrics.cardGap) {
                listCard
                previewCard
                    .frame(width: controller.previewPaneWidth)
            }
        } else if controller.previewVisible {
            VStack(spacing: LauncherMetrics.cardGap) {
                listCard
                previewCard
                    .frame(height: controller.previewPaneHeight)
            }
        } else {
            listCard
        }
    }

    private var listCard: some View {
        VStack(spacing: 0) {
            modeHeader
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .cardSurface(theme: theme)
    }

    private var previewCard: some View {
        ClipboardPreviewPane(
            item: controller.selectedItem,
            theme: theme,
            focused: controller.previewFocused
        )
    }

    /// Filters belong to the list, not the rail: one fixed-height row above
    /// the results when the clipboard or Ask scope is active.
    @ViewBuilder
    private var modeHeader: some View {
        if controller.activeTabID == "clip" {
            modeRow {
                filterChip("All", value: nil)
                filterChip("Text", value: "text")
                filterChip("Images", value: "image")
                filterChip("Files", value: "files")
            }
        }
    }

    private func modeRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 4) {
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LauncherMetrics.innerPadding)
        .frame(height: 40)
    }

    private func filterChip(_ title: String, value: String?) -> some View {
        ChipButton(title: title, selected: controller.effectiveClipboardFilter == value, theme: theme) {
            controller.setClipboardFilter(value)
        }
    }

    private func modeChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        ChipButton(title: title, selected: selected, theme: theme, action: action)
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
                    .disabled(controller.prompt != nil || controller.scratchpadActive || controller.terminalActive)
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
        .padding(.horizontal, LauncherMetrics.innerPadding)
        .frame(height: CGFloat(theme.search.height))
        .background(
            GlassSurface(shape: Capsule())
                .overlay(
                    Capsule()
                        .fill(theme.color(theme.palette.bg).opacity(isPill && theme.window.glass ? theme.window.glassOpacity : 1))
                )
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            theme.color(theme.palette.fg).opacity(isPill && theme.window.glass ? 0.14 : 0),
                            theme.color(theme.palette.accent).opacity(isPill ? 0.30 : 0),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )

    }

    @ViewBuilder
    private var content: some View {
        if controller.terminalActive {
            TerminalPane(theme: theme, initialCommand: controller.terminalInitialCommand, session: controller.terminalSession)
                .padding(LauncherMetrics.innerPadding)
        } else if controller.scratchpadActive {
            ScratchpadView(controller: controller, theme: theme)
                .padding(LauncherMetrics.innerPadding)
        } else if let prompt = controller.prompt {
            PromptView(prompt: prompt, controller: controller, theme: theme, focused: $promptFocused, pill: isPill)
        } else if controller.actionsMode {
            actionsView
        } else {
            resultsView
        }
    }

    private var resultsView: some View {
        Group {
            if controller.items.isEmpty {
                emptyState
            } else {
                let showGroupHeaders = Set(controller.items.compactMap(\.group)).count > 1
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: isPill ? 6 : CGFloat(theme.list.spacing)) {
                            ForEach(Array(controller.items.enumerated()), id: \.element.stableID) { index, item in
                                if showGroupHeaders,
                                   let group = item.group,
                                   index == 0 || controller.items[index - 1].group != group {
                                    Text(group.uppercased())
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(theme.color(theme.palette.fgMuted))
                                        .frame(maxWidth: .infinity, alignment: .leading)
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
                                .contextMenu {
                                    ForEach(controller.actions(for: item)) { action in
                                        Button(action.title) {
                                            controller.run(action, on: item)
                                        }
                                    }
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(.isButton)
                                .accessibilityLabel(rowAccessibilityLabel(item))
                                .accessibilityAction { controller.activate(index) }
                            }
                        }
                        .padding(.horizontal, LauncherMetrics.innerPadding)
                        .padding(.vertical, LauncherMetrics.innerPadding)
                    }
                    .scrollIndicators(theme.list.showScrollbar ? .visible : .hidden)
                    .onChange(of: controller.selectionIndex) { _, _ in
                        guard controller.items.indices.contains(controller.selectionIndex) else { return }
                        let stableID = controller.items[controller.selectionIndex].stableID
                        withAnimation(reduceMotion ? nil : theme.scrollAnimation) {
                            proxy.scrollTo(stableID, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One sentence for VoiceOver: title, subtitle, provider.
    private func rowAccessibilityLabel(_ item: PaletteItem) -> String {
        [item.title, item.subtitle, item.providerName]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
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
            .padding(.horizontal, LauncherMetrics.innerPadding)
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
                            .contextMenu {
                                Button(action.title) {
                                    controller.actionIndex = index
                                    controller.executeAction()
                                }
                            }
                        }
                        if !controller.actionItems.isEmpty {
                            Rectangle()
                                .fill(theme.color(theme.palette.separator).opacity(0.5))
                                .frame(height: 1)
                                .padding(.horizontal, 10)
                                .padding(.top, 8)
                        }
                        keyboardReference
                            .padding(.horizontal, LauncherMetrics.innerPadding)
                            .padding(.top, 6)
                            .padding(.bottom, 6)
                    }
                    .padding(.horizontal, LauncherMetrics.innerPadding)
                    .padding(.bottom, LauncherMetrics.innerPadding)
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

    private static let shortcutHints: [ShortcutHint] = [
        ShortcutHint(keys: "↑↓", label: "Navigate"),
        ShortcutHint(keys: "⏎", label: "Open"),
        ShortcutHint(keys: "⌘⏎", label: "Secondary"),
        ShortcutHint(keys: "⌘K", label: "Actions"),
        ShortcutHint(keys: "⌘R", label: "Reload"),
        ShortcutHint(keys: "esc", label: "Back"),
    ]

    private var keyboardReference: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Keyboard")
                .font(.system(size: 9, weight: .semibold))
                .textCase(.uppercase)
                .foregroundColor(theme.color(theme.palette.fgMuted).opacity(0.7))
                .padding(.bottom, 2)
            ForEach(Self.shortcutHints) { hint in
                HStack(spacing: 8) {
                    Text(hint.keys)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(theme.color(theme.palette.elevated).opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .frame(width: 50, alignment: .leading)
                    Text(hint.label)
                        .font(.system(size: 10))
                }
                .foregroundColor(theme.color(theme.palette.fgMuted).opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: emptyGlyph)
                .font(.system(size: 24, weight: .light))
                .foregroundColor(theme.color(theme.palette.fgMuted).opacity(0.7))
            Text(emptyTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.color(theme.palette.fg).opacity(0.9))
            Text(emptyDetail)
                .font(.system(size: 11))
                .foregroundColor(theme.color(theme.palette.fgMuted).opacity(0.8))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 360)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyGlyph: String {
        if controller.isSearching { return "hourglass" }
        if controller.query.isEmpty { return "magnifyingglass" }
        return "sparkle.magnifyingglass"
    }

    private var emptyTitle: String {
        if controller.isSearching { return "Searching…" }
        if controller.query.isEmpty { return "Start typing" }
        return "No results"
    }

    private var emptyDetail: String {
        if controller.isSearching { return "Results appear as each source responds." }
        if controller.query.isEmpty { return "Search apps, files, clipboard, snippets and more." }
        if controller.scopeLabel != nil { return "Nothing here yet." }
        return "Try a different spelling, or press ⌘, to enable more sources."
    }

    /// The divider spans the card column, and the text sits on the card inset
    /// like the list and the preview.
    /// A card like the others: 16pt radius, 12pt inner padding, its own
    /// palette surface under the glass, separated by the normal card gap.
    private var footer: some View {
        footerContent
            .padding(.horizontal, LauncherMetrics.innerPadding)
            .frame(maxWidth: .infinity)
            .frame(height: LauncherMetrics.footerHeight)
            .cardSurface(theme: theme, background: theme.palette.surface)
    }

    private var footerContent: some View {
        HStack(spacing: 10) {
            if let status = controller.statusMessage {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                Text(status)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if controller.actionsMode {
                hint("esc", "Back")
            } else if let item = controller.selectedItem, let action = item.primaryAction {
                // No primary action means Return does nothing; never advertise it.
                primaryActionPill(action.title)
            }
            Spacer(minLength: 4)
            if !controller.actionsMode {
                hint("⌘K", "Actions")
            }
        }
        .font(theme.font(size: 10, weight: .medium))
        .foregroundColor(theme.color(theme.footer.hintColor))
    }

    /// Shows what Return does on the selected row, read from its primary action.
    private func primaryActionPill(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text("⏎")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(theme.color(theme.palette.elevated).opacity(0.7))
                .clipShape(Capsule())
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.leading, 3)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(theme.color(theme.palette.elevated).opacity(0.35))
        .clipShape(Capsule())
        .layoutPriority(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Press return to \(title)")
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
                // The provider's placeholder carries the real consequence,
                // e.g. /web remove's warning about the shortcut.
                if let detail = prompt.placeholder, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(theme.color(theme.palette.fgMuted))
                }
            } else if prompt.kind == .secureText {
                SecureField(prompt.placeholder ?? "Password", text: Binding(
                    get: { controller.promptValue },
                    set: { controller.promptValue = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(8)
                .background(theme.color(theme.palette.surface).opacity(0.9))
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
                .background(theme.color(theme.palette.surface).opacity(0.9))
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
                    .background(theme.color(theme.palette.elevated).opacity(0.8))
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
        .background(
            GlassSurface(
                shape: RoundedRectangle(cornerRadius: pill ? 18 : 12, style: .continuous),
                tint: theme.color(theme.palette.elevated).opacity(0.55)
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: pill ? 18 : 12, style: .continuous)
                .strokeBorder(theme.color(theme.palette.border).opacity(0.45), lineWidth: 1)
        )
    }
}

struct QuickLookPreviewView: NSViewRepresentable {
    var path: String

    func makeNSView(context: Context) -> QLPreviewView {
        let view: QLPreviewView = QLPreviewView(frame: .zero, style: .compact)
            ?? QLPreviewView(frame: .zero)!
        view.autostarts = true
        view.shouldCloseWithWindow = true
        view.previewItem = URL(fileURLWithPath: path) as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        let url = URL(fileURLWithPath: path)
        if (view.previewItem as? URL) != url {
            view.previewItem = url as NSURL
            view.refreshPreviewItem()
        }
    }
}

/// Right-hand preview used by the dedicated clipboard window. Text is shown
/// verbatim, images at their stored size, and Finder selections get a
/// QuickLook preview plus icons and file metadata.
struct ClipboardPreviewPane: View {
    var item: PaletteItem?
    var theme: Theme
    var focused: Bool = false

    @State private var files: [FileDetail] = []
    @State private var textPreview: String?
    @State private var directoryListing = false

    private struct FileDetail: Sendable {
        var name: String
        var path: String
        var size: Int64
        var isDirectory: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item {
                let header = header(for: item)
                if let title = header.title {
                    Text(title)
                        .font(theme.font(size: 13, weight: .semibold))
                        .foregroundColor(theme.color(theme.palette.fg))
                        .lineLimit(2)
                }
                if let subtitle = header.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(theme.color(theme.palette.fgMuted))
                        .lineLimit(2)
                }
                if header.title != nil || header.subtitle != nil {
                    Rectangle()
                        .fill(theme.color(theme.palette.separator))
                        .frame(height: 1)
                }
                preview(for: item)
            } else {
                Text("Nothing selected")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color(theme.palette.fgMuted))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LauncherMetrics.innerPadding)
        .padding(.vertical, LauncherMetrics.innerPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface(theme: theme)
        .overlay(
            RoundedRectangle(cornerRadius: LauncherMetrics.cardRadius, style: .continuous)
                .strokeBorder(theme.color(theme.palette.accent).opacity(focused ? 0.55 : 0), lineWidth: 1)
        )
        .task(id: item?.stableID) { await load() }
    }

    @ViewBuilder
    private func preview(for item: PaletteItem) -> some View {
        switch item.preview {
        case .text(let value):
            PreviewTextView(text: value, theme: theme)
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
            VStack(alignment: .leading, spacing: 8) {
                if !directoryListing, files.count == 1, let file = files.first, !file.isDirectory {
                    QuickLookPreviewView(path: file.path)
                        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 230)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
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
                            .font(theme.monoFont(size: 10))
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
            }
        case .document(let url, _):
            QuickLookPreviewView(path: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        case nil:
            Text("No preview available")
                .font(.system(size: 11))
                .foregroundColor(theme.color(theme.palette.fgMuted))
        }
    }

    /// The pane already sits under the row, so repeating the row's own title or
    /// subtitle above the same text wastes half of a narrow pane.
    private func header(for item: PaletteItem) -> (title: String?, subtitle: String?) {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = item.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .text(let body) = item.preview else {
            return (title.isEmpty ? nil : title, subtitle)
        }
        let flat = body
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let titleShown = !title.isEmpty && flat.contains(title)
        let subtitleShown = subtitle.map { !$0.isEmpty && flat.contains($0) } ?? false
        return (titleShown ? nil : title, subtitleShown ? nil : subtitle)
    }

    private func load() async {
        files = []
        textPreview = nil
        directoryListing = false
        guard let item, case .files(let paths) = item.preview else { return }

        let result = await Task.detached(priority: .userInitiated) { () -> ([FileDetail], String?, Bool) in
            let manager = FileManager.default
            func detail(_ path: String) -> FileDetail {
                let attributes = try? manager.attributesOfItem(atPath: path)
                return FileDetail(
                    name: (path as NSString).lastPathComponent,
                    path: path,
                    size: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
                    isDirectory: (attributes?[.type] as? FileAttributeType) == .typeDirectory
                )
            }
            // A single directory previews its contents, dirs first, rather
            // than a QuickLook icon that says nothing.
            if paths.count == 1, let path = paths.first, detail(path).isDirectory {
                let children = (try? manager.contentsOfDirectory(
                    at: URL(fileURLWithPath: path),
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                let details = children.map { detail($0.path) }.sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return (Array(details.prefix(60)), nil, true)
            }
            var details: [FileDetail] = []
            for path in paths.prefix(8) {
                details.append(detail(path))
            }
            var rendered: String?
            if paths.count == 1, let path = paths.first, details.first?.isDirectory == false {
                rendered = Self.batPreview(path)
            }
            return (details, rendered, false)
        }.value

        files = result.0
        textPreview = result.1
        directoryListing = result.2
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
extension Notification.Name {
    static let palettePreviewScroll = Notification.Name("palette.preview.scroll")
}

/// Read-only, selectable text preview with keyboard scrolling. Mouse selection
/// plus ⌘C still works through AppKit's standard text machinery.
struct PreviewTextView: NSViewRepresentable {
    var text: String
    var theme: Theme
    /// `nil` keeps the preview's monospaced look; prose answers pass a UI font.
    var font: NSFont?
    var lineSpacing: CGFloat = 0

    final class Coordinator {
        var observer: NSObjectProtocol?
        weak var scrollView: NSScrollView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        context.coordinator.scrollView = scroll
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: .palettePreviewScroll,
            object: nil,
            queue: .main
        ) { [weak scroll] note in
            guard let scroll else { return }
            let dy = note.userInfo?["dy"] as? CGFloat ?? 0
            let dx = note.userInfo?["dx"] as? CGFloat ?? 0
            let clip = scroll.contentView
            let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
            let maxX = max(0, (scroll.documentView?.frame.width ?? 0) - clip.bounds.width)
            var origin = clip.bounds.origin
            if abs(dy) == .greatestFiniteMagnitude {
                origin.y = dy > 0 ? maxY : 0
            } else {
                origin.y = min(max(0, origin.y + dy), maxY)
            }
            origin.x = min(max(0, origin.x + dx), maxX)
            clip.scroll(to: origin)
            scroll.reflectScrolledClipView(clip)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            textView.scrollToBeginningOfDocument(nil)
        }
        let family = theme.typography.mono
        textView.font = font ?? NSFont(name: family, size: 11) ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = theme.nsColor(theme.palette.fg)
        if lineSpacing > 0 {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            textView.defaultParagraphStyle = style
            textView.typingAttributes[.paragraphStyle] = style
            textView.textStorage?.addAttribute(
                .paragraphStyle,
                value: style,
                range: NSRange(location: 0, length: textView.string.utf16.count)
            )
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}


struct ScratchpadView: View {
    @ObservedObject var controller: SearchController
    var theme: Theme
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .foregroundColor(theme.color(theme.palette.accent))
                Text("Scratchpad")
                    .font(theme.font(size: 12, weight: .semibold))
                    .foregroundColor(theme.color(theme.palette.fg))
                TextField("Untitled note", text: $controller.scratchpadTitle)
                    .textFieldStyle(.plain)
                    .font(theme.font(size: 12))
                    .foregroundColor(theme.color(theme.palette.fgMuted))
                    .frame(maxWidth: 260)
                Spacer()
                Button("Paste") { controller.pasteIntoScratchpad() }
                Button("Copy All") { controller.copyScratchpad() }
                Button("Clear") { controller.clearScratchpad() }
                Button("Save & Close") { controller.closeScratchpad(save: true) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Rectangle()
                .fill(theme.color(theme.palette.separator))
                .frame(height: 1)

            TextEditor(text: $controller.scratchpadText)
                .font(theme.monoFont(size: 12))
                .foregroundColor(theme.color(theme.palette.fg))
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .focused($focused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

            HStack(spacing: 14) {
                Text("⌘⏎ copy all")
                Text("⌘S / esc save & close")
                Spacer()
                Text("\(controller.scratchpadText.count) chars")
            }
            .font(.system(size: 10))
            .foregroundColor(theme.color(theme.palette.fgMuted))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(
            GlassSurface(
                shape: RoundedRectangle(cornerRadius: 16, style: .continuous),
                tint: theme.color(theme.palette.elevated).opacity(0.55)
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.color(theme.palette.border).opacity(0.45), lineWidth: 1)
        )
        .onAppear { focused = true }
        .onChange(of: controller.focusToken) { _, _ in focused = true }
    }
}


extension Notification.Name {
    static let paletteTerminalStop = Notification.Name("palette.terminal.stop")
}

struct TerminalPane: NSViewRepresentable {
    var theme: Theme
    var initialCommand: String?
    var session: TerminalSessionConfig

    final class Coordinator {
        weak var view: LocalProcessTerminalView?
        var observer: NSObjectProtocol?
        var started = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        terminal.configureNativeColors()
        terminal.usesMetalLayerSurface = false
        terminal.nativeBackgroundColor = theme.nsColor(theme.palette.bg)
        terminal.nativeForegroundColor = theme.nsColor(theme.palette.fg)
        terminal.wantsLayer = true
        terminal.layer?.backgroundColor = theme.nsColor(theme.palette.bg).cgColor
        terminal.layer?.cornerRadius = 10
        terminal.font = resolvedFont()
        context.coordinator.view = terminal
        nonisolated(unsafe) let stoppable = terminal
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: .paletteTerminalStop,
            object: nil,
            queue: .main
        ) { _ in
            stoppable.terminate()
        }
        DispatchQueue.main.async {
            let shell = resolvedShell()
            let environment = terminalEnvironment(shell: shell)
            let zellij = ToolLocator.shared.path(for: "zellij")
            let tmux = ToolLocator.shared.path(for: "tmux")
            let name = session.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Palette" : session.name
            switch session.multiplexer {
            case .zellij where zellij != nil, .auto where zellij != nil:
                terminal.startProcess(
                    executable: zellij!,
                    args: ["attach", "--create", name],
                    environment: environment,
                    execName: "zellij",
                    currentDirectory: NSHomeDirectory()
                )
            case .tmux where tmux != nil, .auto where tmux != nil:
                terminal.startProcess(
                    executable: tmux!,
                    args: ["new-session", "-A", "-s", name, "--", shell, "-l"],
                    environment: environment,
                    execName: "tmux",
                    currentDirectory: NSHomeDirectory()
                )
            default:
                terminal.startProcess(
                    executable: shell,
                    args: ["-l"],
                    environment: environment,
                    execName: (shell as NSString).lastPathComponent,
                    currentDirectory: NSHomeDirectory()
                )
            }
            terminal.window?.makeFirstResponder(terminal)
            if let command = initialCommand, !command.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    terminal.send(txt: command + "\n")
                }
            }
            if ProcessInfo.processInfo.environment["PALETTE_TERMINAL_DEBUG"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let rows = terminal.terminalStateSnapshot().visibleRows
                        .map(\.text)
                        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    Log.shared.info("Terminal font: \(terminal.font.fontName) \(terminal.font.pointSize)", source: "terminal")
                    Log.shared.info("Terminal rows: \(rows.joined(separator: " | "))", source: "terminal")
                }
            }
        }
        return terminal
    }

    private func resolvedFont() -> NSFont {
        let configured = session.font.trimmingCharacters(in: .whitespacesAndNewlines)
        let kitty = kittyFont()
        let size = session.fontSize > 0 ? session.fontSize : (kitty?.1 ?? 13)

        if !configured.isEmpty, let font = font(named: configured, size: size) {
            return font
        }
        if let kitty, let font = font(named: kitty.0, size: size) {
            return font
        }
        let mono = theme.typography.mono.trimmingCharacters(in: .whitespaces)
        if !mono.isEmpty, let font = font(named: mono, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private func font(named name: String, size: Double) -> NSFont? {
        if let font = NSFont(name: name, size: size) { return font }
        if let font = NSFontManager.shared.font(
            withFamily: name,
            traits: [],
            weight: 5,
            size: size
        ) { return font }
        return nil
    }

    private func kittyFont() -> (String, Double)? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/kitty/kitty.conf")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var family: String?
        var size: Double?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "font_family": family = String(parts[1]).trimmingCharacters(in: .whitespaces)
            case "font_size": size = Double(parts[1].trimmingCharacters(in: .whitespaces))
            default: break
            }
        }
        guard let family else { return nil }
        return (family, size ?? 13)
    }

    private func resolvedShell() -> String {
        let configured = session.shell.trimmingCharacters(in: .whitespacesAndNewlines)
        if configured.isEmpty {
            return ToolLocator.shared.path(for: "fish") ?? "/bin/zsh"
        }
        if configured.contains("/") {
            return FileManager.default.isExecutableFile(atPath: configured) ? configured : "/bin/zsh"
        }
        return ToolLocator.shared.path(for: configured) ?? "/bin/zsh"
    }

    private func terminalEnvironment(shell: String) -> [String] {
        var environment = ProcessInfo.processInfo.environment
            .filter { $0.key != "SHELL" && $0.key != "TERM" }
            .map { "\($0.key)=\($0.value)" }
        environment.append("SHELL=\(shell)")
        environment.append("TERM=xterm-256color")
        return environment
    }

    func updateNSView(_ terminal: LocalProcessTerminalView, context: Context) {
        terminal.nativeBackgroundColor = theme.nsColor(theme.palette.bg)
        terminal.nativeForegroundColor = theme.nsColor(theme.palette.fg)
        terminal.font = resolvedFont()
        terminal.layer?.backgroundColor = theme.nsColor(theme.palette.bg).cgColor
    }

    static func dismantleNSView(_ terminal: LocalProcessTerminalView, coordinator: Coordinator) {
        if let observer = coordinator.observer {
            NotificationCenter.default.removeObserver(observer)
        }
        terminal.terminate()
    }
}
