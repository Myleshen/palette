import AppKit
import class SwiftTerm.LocalProcessTerminalView
import class SwiftTerm.TerminalView
import protocol SwiftTerm.LocalProcessTerminalViewDelegate
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

    /// Monospaced preview body at the configured preview size.
    func previewFont(size: Double? = nil) -> NSFont {
        let pointSize = size ?? previewTextSize
        let family = typography.mono.trimmingCharacters(in: .whitespaces)
        return NSFont(name: family, size: pointSize)
            ?? NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
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
                shape.stroke(.primary.opacity(0.55), lineWidth: 1)
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
    /// The horizontal provider strip: 26pt chips with 6pt vertical padding.
    static let providerChipHeight: CGFloat = 26
    static let providerBarVerticalPadding: CGFloat = 6
    static var providerBarHeight: CGFloat {
        providerChipHeight + providerBarVerticalPadding * 2
    }
    static let providerChipGap: CGFloat = 8
    static let providerChipPadding: CGFloat = 12
    /// A long provider name widens its chip only up to this, then ellipsizes.
    static let providerChipMaxWidth: CGFloat = 220
    /// The left provider rail is always this wide. It never collapses: if the
    /// providers do not fit, its scroll view does the work.
    static let railWidth: CGFloat = 220
}

/// The glass + theme fill + hairline used by every launcher card. Cards share
/// one radius, so the shape is not a parameter.
private struct CardSurface: ViewModifier {
    var theme: Theme
    var background: String?
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: LauncherMetrics.cardRadius, style: .continuous)
    }

    /// Every card paints its own palette colour; glass only ever sits on top.
    /// Increase Contrast makes that fill opaque so text never sits on a
    /// desktop-tinted blend the loader did not validate.
    var fill: Color {
        theme.color(background ?? theme.palette.bg)
            .opacity(contrast == .increased ? 1 : (theme.window.glass ? theme.window.glassOpacity : 1))
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
    var lineLimit: Int = 1

    var body: some View {
        Text(attributed)
            .lineLimit(lineLimit)
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
private struct ChipButton: View {    var title: String
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
                    : theme.color(theme.palette.fg))
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

/// One provider chip for the top strip: the rail's glyph and label in a 26pt
/// rounded chip. Selection uses the rail's solid palette pair.
private struct ProviderBarChip: View {
    var entry: ProviderRailEntry
    var width: CGFloat
    var selected: Bool
    var theme: Theme
    var action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ProviderGlyph(entry: entry, theme: theme)
                Text(entry.title)
                    .font(theme.font(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, LauncherMetrics.providerChipPadding)
            .frame(width: width, height: LauncherMetrics.providerChipHeight, alignment: .leading)
            .foregroundColor(theme.color(selected ? theme.palette.accentFg : theme.palette.fg))
            .background(
                RoundedRectangle(cornerRadius: LauncherMetrics.rowRadius, style: .continuous)
                    .fill(
                        selected
                            ? theme.color(theme.palette.accent)
                            : theme.color(theme.palette.elevated).opacity(hovered ? 0.8 : 0)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: LauncherMetrics.rowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(entry.title)
        .accessibilityLabel(entry.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The provider's real icon when it ships one, otherwise a two-letter tile.
/// Shared by the left rail and the top strip so both read the same.
private struct ProviderGlyph: View {
    var entry: ProviderRailEntry
    var theme: Theme

    private var symbol: String? {
        entry.icon.flatMap { raw -> String? in
            raw.hasPrefix("symbol:") ? String(raw.dropFirst("symbol:".count)) : nil
        }
    }

    private var initials: String {
        let words = entry.title.split(whereSeparator: \.isWhitespace).prefix(2)
        return words.compactMap { $0.first }.map { String($0).uppercased() }.joined()
    }

    var body: some View {
        if let symbol {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16)
        } else {
            Text(initials)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 16, height: 16)
        }
    }
}

struct ResultRow: View {
    var item: PaletteItem
    var selected: Bool
    var terms: [String]
    var showProvider: Bool
    var theme: Theme
    var pill: Bool = false
    var titleLineLimit: Int = 1
    var rowHeight: CGFloat? = nil

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
                    weight: selected ? .medium : .regular,
                    lineLimit: titleLineLimit
                )
                if theme.list.showSubtitles, let subtitle = item.subtitle ?? item.trouble?.detail, !subtitle.isEmpty {
                    HStack(spacing: 3) {
                        if item.trouble != nil {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: theme.typography.subtitleSize))
                        }
                        Text(subtitle)
                            .font(.system(size: theme.typography.subtitleSize))
                            .foregroundColor(theme.color(subtitleColor))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
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
        .frame(height: rowHeight ?? CGFloat(theme.effectiveRowHeight))
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
                    .fill(color)
            }
        } else if hovered {
            // Deliberately weaker than selection, and absent when the user
            // turned selection backgrounds off. The themed hover fill is used
            // opaque so its text pair stays the one the loader validates.
            switch style {
            case "none":
                Color.clear
            default:
                RoundedRectangle(cornerRadius: LauncherMetrics.rowRadius, style: .continuous)
                    .fill(theme.color(theme.states.hover.bg ?? theme.palette.elevated))
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

    private var selectedBase: String {
        theme.states.selected.fg ?? theme.palette.selectionFg
    }

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
                .foregroundColor(theme.color(selected ? selectedBase : theme.palette.fgMuted))
            Text(action.title)
                .font(.system(size: theme.typography.size))
                .foregroundColor(theme.color(selected ? selectedBase : theme.palette.fg))
                .lineLimit(1)
            Spacer()
            if let shortcut = action.shortcut {
                Text(shortcut)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(theme.color(selected ? selectedBase : theme.palette.fgMuted))
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
                    .fill(color)
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
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var searchFocused: Bool
    @FocusState private var promptFocused: Bool
    @State private var railScrollTarget: String?
    @State private var barStart = 0
    @State private var barHovered = false
    @State private var barWheelAccum: CGFloat = 0
    @State private var barScrollMonitor: Any?
    private var theme: Theme { themeManager.theme }
    private var isPill: Bool { true }

    /// One focus indicator for the whole launcher: the zone Tab and the arrows
    /// act on gets a ring, never a second row painted like the selection.
    private func zoneRing(_ zone: LauncherZone, radius: CGFloat = LauncherMetrics.cardRadius) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(
                theme.color(theme.palette.accent)
                    .opacity(controller.focusZone == zone ? 1 : 0),
                lineWidth: 2
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    var body: some View {
        pillLayout()
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
        .onChange(of: searchFocused) { _, focused in
            if focused { controller.focusZone = .search }
        }
    }

    /// One grid: search pill, the provider switcher, cards, then the footer.
    /// The terminal replaces the whole grid below the pill: it spans the rail's
    /// width, sits over the footer and takes every remaining point.
    @ViewBuilder
    private func pillLayout() -> some View {
        if controller.terminalActive {
            terminalLayout
        } else {
            VStack(spacing: LauncherMetrics.cardGap) {
                searchBar
                if controller.showsProviderBar {
                    topProviderBar
                }
                HStack(alignment: .top, spacing: LauncherMetrics.cardGap) {
                    if controller.providerBar == .left {
                        rail()
                    }
                    contentArea
                }
                if theme.footer.show {
                    footer
                }
            }
            .padding(LauncherMetrics.outerInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var terminalLayout: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(.horizontal, LauncherMetrics.outerInset)
                .padding(.top, LauncherMetrics.outerInset)
            GeometryReader { proxy in
                let size = WindowConfig.terminalContentSize(in: proxy.size)
                content
                    .frame(width: size.width, height: size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Horizontal strip: one fixed-height row of rail-style chips. Only whole
    /// chips are laid out, so a resting offset never leaves one cut in half.
    private var topProviderBar: some View {
        providerBarContent
    }

    private var providerBarContent: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width - LauncherMetrics.innerPadding * 2)
            let window = barWindow(width: width)
            HStack(spacing: LauncherMetrics.providerChipGap) {
                ForEach(window.entries) { entry in
                    ProviderBarChip(
                        entry: entry,
                        width: chipWidth(entry),
                        selected: controller.activeRailID == entry.id,
                        theme: theme
                    ) {
                        controller.selectRail(entry.id)
                        controller.railFocused = true
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, LauncherMetrics.innerPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if window.startIndex > 0 { providerBarScrim(leading: true) }
            }
            .overlay(alignment: .trailing) {
                if window.endIndex < controller.railEntries.count {
                    providerBarScrim(leading: false)
                }
            }
            .overlay(alignment: .leading) {
                if barHovered, window.startIndex > 0 {
                    barChevron("chevron.left") {
                        shiftBar(by: -max(1, window.count - 1))
                    }
                    .padding(.leading, 4)
                }
            }
            .overlay(alignment: .trailing) {
                if barHovered, window.endIndex < controller.railEntries.count {
                    barChevron("chevron.right") {
                        shiftBar(by: max(1, window.count - 1))
                    }
                    .padding(.trailing, 4)
                }
            }
            .onChange(of: proxy.size.width, initial: true) { _, newWidth in
                settleBar(width: max(0, newWidth - LauncherMetrics.innerPadding * 2))
            }
            .onChange(of: controller.activeRailID, initial: true) { _, _ in
                settleBar(width: width)
            }
        }
        .frame(height: LauncherMetrics.providerBarHeight)
        .background(theme.color(theme.palette.bg))
        .cardSurface(theme: theme)
        .onHover { inside in
            barHovered = inside
            if inside { installBarScrollMonitor() } else { removeBarScrollMonitor() }
        }
        .onDisappear {
            barHovered = false
            removeBarScrollMonitor()
        }
    }

    private struct ProviderBarWindow {
        var entries: [ProviderRailEntry]
        var startIndex: Int
        var endIndex: Int
        var count: Int { entries.count }
    }

    /// Chips from `barStart` that fully fit. The active chip anchors the window
    /// on scope changes, so it is always visible and every edge is a chip edge.
    private func barWindow(width: CGFloat) -> ProviderBarWindow {
        let entries = controller.railEntries
        guard !entries.isEmpty, width > 0 else {
            return ProviderBarWindow(entries: [], startIndex: 0, endIndex: 0)
        }
        let widths = entries.map(chipWidth)
        let gap = LauncherMetrics.providerChipGap
        let start = min(max(0, barStart), entries.count - 1)
        var total: CGFloat = 0
        var end = start
        while end < entries.count {
            let addition = widths[end] + (end == start ? 0 : gap)
            if total + addition > width { break }
            total += addition
            end += 1
        }
        return ProviderBarWindow(
            entries: Array(entries[start..<end]),
            startIndex: start,
            endIndex: end
        )
    }

    /// Put the active provider at the right edge of the widest window that
    /// starts on a chip boundary.
    private func settleBar(width: CGFloat) {
        let entries = controller.railEntries
        guard !entries.isEmpty, width > 0 else {
            barStart = 0
            return
        }
        guard let active = entries.firstIndex(where: { $0.id == controller.activeRailID }) else {
            barStart = 0
            return
        }
        let widths = entries.map(chipWidth)
        let gap = LauncherMetrics.providerChipGap
        var start = active
        var total = widths[active]
        while start > 0 {
            let candidate = widths[start - 1] + gap + total
            if candidate <= width { total = candidate; start -= 1 } else { break }
        }
        barStart = start
    }

    private func shiftBar(by delta: Int) {
        let count = controller.railEntries.count
        guard count > 0 else { return }
        barStart = min(max(0, barStart + delta), count - 1)
    }

    /// Chip widths are measured from the same 11pt label the chip draws, plus
    /// its 16pt glyph, 6pt gap and 12pt padding on each side.
    private func chipWidth(_ entry: ProviderRailEntry) -> CGFloat {
        let label = (entry.title as NSString).size(
            withAttributes: [.font: theme.nsFont(size: 11, weight: .medium)]
        ).width
        let chrome = LauncherMetrics.providerChipPadding * 2 + 16 + 6 + 2
        let maxLabel = LauncherMetrics.providerChipMaxWidth - chrome
        return ceil(min(label, maxLabel)) + chrome
    }

    /// A soft scrim at the edge where more chips continue. It shades the card
    /// itself rather than masking a half chip, so every chip stays whole.
    private func providerBarScrim(leading: Bool) -> some View {
        LinearGradient(
            colors: [
                theme.appearance == "light"
                    ? Color.white.opacity(0.55)
                    : Color.black.opacity(0.5),
                .clear,
            ],
            startPoint: leading ? .leading : .trailing,
            endPoint: leading ? .trailing : .leading
        )
        .frame(width: 26)
        .allowsHitTesting(false)
    }

    private func barChevron(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(theme.color(theme.palette.fg))
                .frame(width: 20, height: 20)
                .background(Circle().fill(theme.color(theme.palette.elevated)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol.hasSuffix("left") ? "Earlier providers" : "More providers")
    }

    private func installBarScrollMonitor() {
        guard barScrollMonitor == nil else { return }
        barScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            let delta = abs(dx) >= abs(dy) ? dx : dy
            if delta != 0 { scrollBarWheel(delta) }
            return nil
        }
    }

    private func removeBarScrollMonitor() {
        if let barScrollMonitor {
            NSEvent.removeMonitor(barScrollMonitor)
            self.barScrollMonitor = nil
        }
    }

    private func scrollBarWheel(_ delta: CGFloat) {
        barWheelAccum += delta
        if barWheelAccum <= -24 {
            barWheelAccum = 0
            shiftBar(by: 1)
        } else if barWheelAccum >= 24 {
            barWheelAccum = 0
            shiftBar(by: -1)
        }
    }

    /// Vertical provider rail: Everything first, one row per provider, full
    /// height between the search pill and the footer. Fixed width: providers
    /// scroll inside it, the rail never narrows to fit.
    private func rail() -> some View {
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
                    railRow(everything)
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
                            railRow(entry)
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
        .frame(width: LauncherMetrics.railWidth)
        .frame(maxHeight: .infinity)
        .cardSurface(theme: theme)
        .overlay(zoneRing(.rail))
    }

    /// Drop a redundant provider prefix before truncating a label mid-word.
    private func railTitle(_ title: String, width: CGFloat) -> String {
        let available = width - LauncherMetrics.innerPadding * 2 - 20 - 16 - 8
        let font = theme.nsFont(size: 11, weight: .medium)
        func fits(_ text: String) -> Bool {
            (text as NSString).size(withAttributes: [.font: font]).width <= available
        }
        if fits(title) { return title }
        for prefix in ["GitHub ", "Bitwarden ", "Neovide ", "Editor "] where title.hasPrefix(prefix) {
            let short = String(title.dropFirst(prefix.count))
            if fits(short) { return short }
        }
        return title
    }

    /// Two initials keep "Editor" and "Editor Folders" apart when a provider
    /// ships no icon.
    private func railInitials(_ title: String) -> String {
        let words = title.split(whereSeparator: \.isWhitespace).prefix(2)
        return words.compactMap { $0.first }.map { String($0).uppercased() }.joined()
    }


    private func railRow(_ entry: ProviderRailEntry) -> some View {
        let selected = controller.activeRailID == entry.id
        return HStack(spacing: 8) {
            ProviderGlyph(entry: entry, theme: theme)
            Text(railTitle(entry.title, width: LauncherMetrics.railWidth))
                .font(theme.font(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        // Accent, not a slightly lighter grey: the active provider has to be
        // obvious at a glance.
        .foregroundColor(theme.color(selected ? theme.palette.accentFg : theme.palette.fgMuted))
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
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
            groupStrip
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .cardSurface(theme: theme)
        .overlay(zoneRing(.list))
    }

    /// Secondary strip for a grouped rail row. It lives in the content column
    /// in every mode, so the top bar and the left rail share one placement.
    @ViewBuilder
    private var groupStrip: some View {
        if let group = controller.activeGroupEntry {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: LauncherMetrics.providerChipGap) {
                        ForEach(group.children) { child in
                            let entry = ProviderRailEntry(
                                id: child.id,
                                title: child.title,
                                icon: child.icon,
                                trigger: child.trigger
                            )
                            ProviderBarChip(
                                entry: entry,
                                width: chipWidth(entry),
                                selected: controller.activeProviderID == child.id,
                                theme: theme
                            ) {
                                controller.selectGroupChild(child)
                                controller.stripFocused = true
                            }
                            .id(child.id)
                        }
                    }
                    .padding(.horizontal, LauncherMetrics.innerPadding)
                    .padding(.vertical, LauncherMetrics.providerBarVerticalPadding)
                }
                .scrollIndicators(.hidden)
                .frame(height: LauncherMetrics.providerBarHeight)
                .onChange(of: controller.activeProviderID, initial: true) { _, id in
                    withAnimation(reduceMotion ? nil : theme.scrollAnimation) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(theme.color(theme.palette.separator).opacity(0.5))
                        .frame(height: 1)
                }
                .overlay(zoneRing(.strip, radius: 10))
            }
        }
    }

    private var previewCard: some View {
        ClipboardPreviewPane(
            item: controller.selectedItem,
            theme: theme,
            focused: controller.previewFocused
        )
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
                        .foregroundColor(theme.color(theme.palette.fgMuted))
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
                TextField("", text: Binding(
                    get: { controller.visibleQuery },
                    set: { controller.editVisibleQuery($0) }
                ))
                    .textFieldStyle(.plain)
                    .font(theme.font(size: theme.typography.size + 3))
                    .foregroundColor(theme.color(theme.palette.fg))
                    .focused($searchFocused)
                    .disabled(controller.prompt != nil || controller.scratchpadActive || controller.terminalActive)
                    .accessibilityLabel(theme.search.placeholder)
                    .onSubmit {
                        if controller.actionsMode { controller.executeAction() } else { controller.executePrimary() }
                    }
                    .onKeyPress(.delete) {
                        guard controller.visibleQuery.isEmpty, controller.queryIsBound else { return .ignored }
                        controller.clearBoundTrigger()
                        return .handled
                    }
            }
            if controller.isSearching {
                PaletteSpinner(color: theme.color(theme.palette.accent))
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
                        .fill(theme.color(theme.palette.bg).opacity(
                            contrast == .increased ? 1 : (isPill && theme.window.glass ? theme.window.glassOpacity : 1)
                        ))
                )
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    theme.color(theme.palette.accent)
                        .opacity(controller.focusZone == .search ? 1 : 0.30),
                    lineWidth: controller.focusZone == .search ? 2 : 1
                )
        )
        .simultaneousGesture(TapGesture().onEnded {
            controller.focusZone = .search
        })

    }

    @ViewBuilder
    private var content: some View {
        if controller.terminalActive {
            TerminalPane(controller: controller, theme: theme)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .cardSurface(theme: theme)
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
                                let wraps = controller.titleWraps(item)
                                ResultRow(
                                    item: item,
                                    selected: index == controller.selectionIndex,
                                    terms: controller.highlightTerms,
                                    showProvider: controller.scopeLabel == nil,
                                    theme: theme,
                                    pill: isPill,
                                    titleLineLimit: wraps ? 2 : 1,
                                    rowHeight: CGFloat(theme.effectiveRowHeight) + (wraps ? 16 : 0)
                                )
                                .id(item.stableID)
                                .onTapGesture { controller.activate(index) }
                                .overlay {
                                    RightClickMenuArea { point in
                                        showRowActions(item, at: point)
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

    /// One sentence for VoiceOver: title, subtitle, provider, and any trouble.
    private func rowAccessibilityLabel(_ item: PaletteItem) -> String {
        [item.title, item.trouble?.title, item.subtitle, item.providerName]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// Right-click opens the same non-tracking panel the Settings menus use,
    /// so a screenshot hotkey still fires while it is open. The native
    /// `.contextMenu` it replaces ran an `NSMenu` tracking loop. ⌘K remains the
    /// keyboard and VoiceOver path for the same actions.
    private func showRowActions(_ item: PaletteItem, at point: NSPoint) {
        let actions = controller.actions(for: item)
        var actionsByID: [String: PaletteAction] = [:]
        let items = actions.enumerated().map { index, action in
            let id = "\(index)|\(action.id)"
            actionsByID[id] = action
            return PaletteMenuItem(id: id, title: action.title, shortcut: action.shortcut)
        }
        presentMenu(items, at: point) { id in
            guard let action = actionsByID[id] else { return }
            controller.run(action, on: item)
        }
    }

    /// The one-item menu a right-click on an action row used to open.
    private func showActionRowMenu(_ action: PaletteAction, index: Int, at point: NSPoint) {
        presentMenu(
            [PaletteMenuItem(id: action.id, title: action.title, shortcut: action.shortcut)],
            at: point
        ) { _ in
            controller.actionIndex = index
            controller.executeAction()
        }
    }

    /// The menu panel takes key focus for Esc/arrows; the launcher must not
    /// auto-hide when that happens, and gets key back on dismissal.
    private func presentMenu(
        _ items: [PaletteMenuItem],
        at point: NSPoint,
        select: @escaping (String) -> Void
    ) {
        let previousSuppress = controller.panel?.suppressAutoHide ?? false
        controller.panel?.suppressAutoHide = true
        PaletteMenuController.shared.show(
            items: items,
            at: point,
            theme: theme,
            onSelect: select,
            onDismiss: { controller.panel?.suppressAutoHide = previousSuppress }
        )
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
                            .overlay {
                                RightClickMenuArea { point in
                                    showActionRowMenu(action, index: index, at: point)
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
                .foregroundColor(theme.color(theme.palette.fgMuted))
                .padding(.bottom, 2)
            ForEach(Self.shortcutHints) { hint in
                let cap = isPill
                    ? AnyShape(Capsule())
                    : AnyShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                HStack(spacing: 8) {
                    Text(hint.keys)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(theme.color(theme.palette.surface))
                        .clipShape(cap)
                        .overlay(cap.stroke(theme.color(theme.palette.border).opacity(0.6), lineWidth: 1))
                        .frame(width: 50, alignment: .leading)
                    Text(hint.label)
                        .font(.system(size: 10))
                }
                .foregroundColor(theme.color(theme.palette.fgMuted))
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
                .foregroundColor(theme.color(theme.palette.fg))
            Text(emptyDetail)
                .font(.system(size: 11))
                .foregroundColor(theme.color(theme.palette.fgMuted))
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
        if let hint = controller.missingToolHint { return hint }
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
            } else if controller.terminalActive {
                hint("esc", "Close")
            } else if let title = controller.returnHint {
                primaryActionPill(title)
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
                .overlay(Capsule().strokeBorder(theme.color(theme.palette.border).opacity(0.6), lineWidth: 1))
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.leading, 3)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(theme.color(theme.palette.surface))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(theme.color(theme.palette.border).opacity(0.6), lineWidth: 1))
        .layoutPriority(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Press return to \(title)")
    }

    private func hint(_ key: String, _ label: String) -> some View {
        let cap = isPill
            ? AnyShape(Capsule())
            : AnyShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        return HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(theme.color(theme.palette.surface))
                .clipShape(cap)
                .overlay(cap.stroke(theme.color(theme.palette.border).opacity(0.6), lineWidth: 1))
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
    @Environment(\.colorSchemeContrast) private var contrast

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
                .frame(maxWidth: 380, alignment: .leading)
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
                .frame(maxWidth: 380, alignment: .leading)
                .focused(focused)
                .onSubmit { controller.submitPrompt() }
            }
            if let message = controller.promptValidationMessage {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(theme.color(theme.palette.danger))
                    Text(message)
                        .foregroundColor(theme.color(theme.palette.fg))
                }
                .font(.system(size: 11))
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
                    .opacity(controller.canSubmitPrompt ? 1 : 0.45)
                    .disabled(!controller.canSubmitPrompt)
            }
            .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            GlassSurface(
                shape: RoundedRectangle(cornerRadius: pill ? 18 : 12, style: .continuous),
                tint: theme.color(theme.palette.elevated).opacity(contrast == .increased ? 1 : 0.55)
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
                .strokeBorder(theme.color(theme.palette.accent).opacity(focused ? 1 : 0), lineWidth: 2)
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
                            .font(theme.monoFont(size: theme.previewTextSize))
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
        textView.font = font ?? theme.previewFont()
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
        textView.font = font ?? theme.previewFont()
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
    @Environment(\.colorSchemeContrast) private var contrast

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
                tint: theme.color(theme.palette.elevated).opacity(contrast == .increased ? 1 : 0.55)
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

/// The terminal card: the live pane plus an end card, so a finished session is
/// obviously over instead of looking like a hung pane showing stale output.
struct TerminalPane: View {
    @ObservedObject var controller: SearchController
    var theme: Theme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        // The card takes its own row instead of covering the last lines of
        // output, so nothing the user may still need to read is hidden.
        VStack(spacing: 0) {
            TerminalSurface(
                theme: theme,
                initialCommand: controller.terminalInitialCommand,
                session: controller.terminalSession,
                restartToken: controller.terminalRestartToken,
                onExit: { [weak controller] code in controller?.noteTerminalExited(code) }
            )
            if let code = controller.terminalExitCode {
                endCard(code)
            }
        }
    }

    private func endCard(_ code: Int32?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.color(theme.palette.accent))
            VStack(alignment: .leading, spacing: 1) {
                Text(code.map { "Session ended (exit \($0))" } ?? "Session ended (terminated)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.color(theme.palette.fg))
                Text("Output stays until you close · esc or ⌘W")
                    .font(.system(size: 10))
                    .foregroundColor(theme.color(theme.palette.fgMuted))
            }
            Spacer()
            Button("Restart") { controller.restartTerminal() }
            Button("Close") { controller.closeTerminalPanel() }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            GlassSurface(
                shape: RoundedRectangle(cornerRadius: 12, style: .continuous),
                tint: theme.color(theme.palette.elevated).opacity(contrast == .increased ? 1 : 0.9)
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.color(theme.palette.border).opacity(0.6), lineWidth: 1)
        )
        .padding(LauncherMetrics.innerPadding)
    }
}

struct TerminalSurface: NSViewRepresentable {
    var theme: Theme
    var initialCommand: String?
    var session: TerminalSessionConfig
    var restartToken: Int
    var onExit: (Int32?) -> Void

    /// The stop observer runs on the main queue but is `@Sendable`; the view
    /// itself is main-actor UI.
    final class Stoppable: @unchecked Sendable {
        let view: LocalProcessTerminalView

        init(_ view: LocalProcessTerminalView) {
            self.view = view
        }
    }

    @MainActor
    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        weak var view: LocalProcessTerminalView?
        var observer: NSObjectProtocol?
        var token = 0
        var cancelled = false
        var session: TerminalSessionConfig
        var initialCommand: String?
        var onExit: (Int32?) -> Void
        /// Sanitized zellij session name; set only while a zellij pane runs.
        private var zellijName: String?
        /// Automatic stale-session rebuilds already spent for this pane.
        private var rebuilds = 0

        init(session: TerminalSessionConfig, initialCommand: String?, token: Int, onExit: @escaping (Int32?) -> Void) {
            self.session = session
            self.initialCommand = initialCommand
            self.token = token
            self.onExit = onExit
        }

        func start(restarting: Bool) {
            guard let view, !cancelled else { return }
            if restarting {
                rebuilds = 0
                zellijName = nil
                // Keep the old output readable, but mark the new run.
                view.feed(text: "\r\n")
            }
            let shell = Self.shell(session)
            let environment = Self.environment(shell: shell)
            let name = session.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Palette" : session.name
            let zellij = ToolLocator.shared.path(for: "zellij")
            let tmux = ToolLocator.shared.path(for: "tmux")
            let zellijWanted = session.multiplexer == .zellij || session.multiplexer == .auto
            let tmuxWanted = session.multiplexer == .tmux || session.multiplexer == .auto

            if zellijWanted, let zellij {
                // Decide before the PTY starts: an exited session of the same
                // name would make attach resurrect stale panes or fail.
                Task { @MainActor in
                    let preparation = await ZellijLauncher.prepare(name: name)
                    guard !self.cancelled, self.view === view else { return }
                    self.zellijName = preparation.name
                    if let warning = preparation.warning {
                        view.feed(text: "\r\nzellij: \(warning)\r\n")
                    }
                    view.startProcess(
                        executable: zellij,
                        args: preparation.recreated
                            ? ["--session", preparation.name]
                            : ["attach", "--create", preparation.name],
                        environment: environment,
                        execName: "zellij",
                        currentDirectory: NSHomeDirectory()
                    )
                    self.didStart(view)
                }
                return
            }

            if tmuxWanted, let tmux {
                view.startProcess(
                    executable: tmux,
                    args: ["new-session", "-A", "-s", name, "--", shell, "-l"],
                    environment: environment,
                    execName: "tmux",
                    currentDirectory: NSHomeDirectory()
                )
            } else {
                view.startProcess(
                    executable: shell,
                    args: ["-l"],
                    environment: environment,
                    execName: (shell as NSString).lastPathComponent,
                    currentDirectory: NSHomeDirectory()
                )
            }
            didStart(view)
        }

        private func didStart(_ view: LocalProcessTerminalView) {
            TerminalProcesses.register(view.process?.shellPid ?? 0)
            view.window?.makeFirstResponder(view)
            if let command = initialCommand, !command.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak view] in
                    view?.send(txt: command + "\n")
                }
            }
            if ProcessInfo.processInfo.environment["PALETTE_TERMINAL_DEBUG"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let rows = view.terminalStateSnapshot().visibleRows
                        .map(\.text)
                        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    Log.shared.info("Terminal font: \(view.font.fontName) \(view.font.pointSize)", source: "terminal")
                    Log.shared.info("Terminal rows: \(rows.joined(separator: " | "))", source: "terminal")
                }
            }
        }

        // MARK: LocalProcessTerminalViewDelegate

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            guard let view else { return }
            TerminalProcesses.unregister(view.process?.shellPid ?? 0)
            // A stale zellij attach (dead session, resurrect prompt) gets one
            // rebuild; anything else is a real end the user has to see.
            if let name = zellijName, rebuilds == 0, exitCode != 0,
               ZellijAttach.isStaleSessionFailure(Self.visibleText(view)) {
                rebuilds = 1
                view.feed(text: "\r\n↻ zellij session \"\(name)\" was stale, rebuilding it\r\n")
                start(restarting: false)
                return
            }
            onExit(exitCode)
        }

        private static func visibleText(_ view: LocalProcessTerminalView) -> String {
            view.terminalStateSnapshot().visibleRows.map(\.text).joined(separator: "\n")
        }

        static func shell(_ session: TerminalSessionConfig) -> String {
            let configured = session.shell.trimmingCharacters(in: .whitespacesAndNewlines)
            if configured.isEmpty {
                return ToolLocator.shared.path(for: "fish") ?? "/bin/zsh"
            }
            if configured.contains("/") {
                return FileManager.default.isExecutableFile(atPath: configured) ? configured : "/bin/zsh"
            }
            return ToolLocator.shared.path(for: configured) ?? "/bin/zsh"
        }

        private static func environment(shell: String) -> [String] {
            var environment = ProcessRunner.sanitizedEnvironment(ProcessInfo.processInfo.environment)
                .filter { $0.key != "SHELL" && $0.key != "TERM" }
                .map { "\($0.key)=\($0.value)" }
            environment.append("SHELL=\(shell)")
            environment.append("TERM=xterm-256color")
            return environment
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, initialCommand: initialCommand, token: restartToken, onExit: onExit)
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        terminal.configureNativeColors()
        terminal.usesMetalLayerSurface = false
        TerminalPalette.apply(theme, to: terminal)
        terminal.wantsLayer = true
        terminal.layer?.cornerRadius = 10
        terminal.font = resolvedFont()
        context.coordinator.view = terminal
        terminal.processDelegate = context.coordinator
        let stoppable = Stoppable(terminal)
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: .paletteTerminalStop,
            object: nil,
            queue: .main
        ) { _ in
            // The observer is registered on the main queue.
            MainActor.assumeIsolated {
                TerminalProcesses.stop(pid: stoppable.view.process?.shellPid ?? 0)
            }
        }
        DispatchQueue.main.async {
            context.coordinator.start(restarting: false)
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

    func updateNSView(_ terminal: LocalProcessTerminalView, context: Context) {
        // A theme change recolours the live pane in place; the session keeps
        // running, so a palette apply does not restart anyone's shell.
        TerminalPalette.apply(theme, to: terminal)
        terminal.font = resolvedFont()
        context.coordinator.session = session
        context.coordinator.initialCommand = initialCommand
        context.coordinator.onExit = onExit
        if context.coordinator.token != restartToken {
            context.coordinator.token = restartToken
            context.coordinator.start(restarting: true)
        }
    }

    static func dismantleNSView(_ terminal: LocalProcessTerminalView, coordinator: Coordinator) {
        coordinator.cancelled = true
        if let observer = coordinator.observer {
            NotificationCenter.default.removeObserver(observer)
        }
        terminal.processDelegate = nil
        terminal.terminate()
    }
}
