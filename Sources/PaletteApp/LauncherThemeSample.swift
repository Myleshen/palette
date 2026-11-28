import SwiftUI
import PaletteCore

/// A miniature Palette window drawn in a theme: search pill, one selected and
/// one plain result, provider chips and a preview card. Settings' theme browser
/// and the theme deck's focused preview both show this, so "how Palette looks"
/// is one component, not two drifting copies.
struct LauncherThemeSample: View {
    let theme: Theme

    var body: some View {
        let accent = theme.color(theme.palette.accent)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                Text(theme.search.placeholder)
                    .font(theme.font(size: min(theme.typography.size, 15)))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("⌘K")
                    .font(theme.monoFont(size: 9))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(theme.color(theme.palette.bg).opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            .foregroundStyle(theme.color(theme.palette.fgMuted))
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(theme.color(theme.palette.elevated))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            resultRow(title: "Safari", subtitle: "Application", icon: "safari", selected: true)
            resultRow(title: "Theme Browser", subtitle: "Settings", icon: "paintpalette", selected: false)

            HStack(spacing: 5) {
                chip("apps", filled: true)
                chip("theme", filled: false)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("PREVIEW")
                    .font(theme.monoFont(size: 9, weight: .semibold))
                    .foregroundStyle(accent)
                Text("Palette — quick, local, yours")
                    .font(theme.font(size: min(theme.typography.size, 14)))
                    .foregroundStyle(theme.color(theme.palette.fg))
                    .lineLimit(1)
                Text("mono: glitch in the matrix")
                    .font(theme.monoFont(size: min(theme.typography.monoSize, 12)))
                    .foregroundStyle(theme.color(theme.palette.fgMuted))
                    .lineLimit(1)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.color(theme.palette.surface))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(theme.color(theme.palette.border).opacity(0.6), lineWidth: 1)
            )
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color(theme.palette.bg))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(theme.color(theme.palette.border), lineWidth: 1)
        )
    }

    private func resultRow(
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
                    ? theme.color(theme.palette.accent)
                    : theme.color(theme.palette.fgMuted))
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(theme.font(size: min(theme.typography.size, 13), weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Text(subtitle)
                    .font(theme.font(size: min(theme.typography.subtitleSize, 10)))
                    .foregroundStyle(theme.color(theme.palette.fgMuted))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if selected {
                Text("↩")
                    .font(theme.monoFont(size: 9))
                    .foregroundStyle(theme.color(theme.palette.selectionFg))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .foregroundStyle(selected
            ? theme.color(theme.palette.selectionFg)
            : theme.color(theme.palette.fg))
        .background(selected
            ? theme.color(theme.palette.selectionBg)
            : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func chip(_ title: String, filled: Bool) -> some View {
        Text(title)
            .font(theme.monoFont(size: 9, weight: .medium))
            .foregroundStyle(filled
                ? theme.color(theme.palette.accentFg)
                : theme.color(theme.palette.fgMuted))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(filled
                ? theme.color(theme.palette.accent)
                : theme.color(theme.palette.elevated))
            .clipShape(Capsule())
    }
}
