import Foundation

/// The contrast bars every theme clears after loading. Ratios are WCAG 2.x
/// contrast against the palette background. `bg` is never moved, so the body
/// bar is capped by what that background physically allows (a mid-tone
/// background cannot reach 7:1 with any foreground).
public enum ThemeContrastThresholds {
    public static let body = 7.0
    public static let muted = 4.5
    public static let accent = 4.5
    public static let accentFg = 4.5
    public static let selection = 4.5
    public static let badge = 4.5
    public static let selectedRow = 4.5
    public static let semantic = 3.0
}

public struct ThemeContrastChange: Equatable, Sendable {
    public var field: String
    public var original: String
    public var repaired: String
    public var before: Double
    public var after: Double
    public var hueShift: Double

    public init(field: String, original: String, repaired: String, before: Double, after: Double, hueShift: Double) {
        self.field = field
        self.original = original
        self.repaired = repaired
        self.before = before
        self.after = after
        self.hueShift = hueShift
    }
}

public struct ThemeContrastReport: Equatable, Sendable {
    public var changes: [ThemeContrastChange]

    public init(changes: [ThemeContrastChange] = []) {
        self.changes = changes
    }
}

/// Repairs authored palettes by moving only OKLab lightness, keeping hue and
/// chroma until the sRGB gamut forces a chroma reduction. The search always
/// takes the smallest lightness move that clears the bar, and does nothing
/// when the authored colour already passes.
public enum ThemeContrastRepair {
    public static func repair(_ theme: inout Theme) -> ThemeContrastReport {
        var report = ThemeContrastReport()
        let name = theme.name
        let bg = theme.palette.bg

        adjust(&theme.palette.fg, field: "fg", backgrounds: [bg],
               minimum: ThemeContrastThresholds.body, theme: name, report: &report)
        adjust(&theme.palette.fgMuted, field: "fg_muted", backgrounds: [bg],
               minimum: ThemeContrastThresholds.muted, theme: name, report: &report)
        adjust(&theme.palette.accent, field: "accent",
               backgrounds: [bg, theme.palette.surface, theme.palette.elevated],
               minimum: ThemeContrastThresholds.accent, theme: name, report: &report)
        adjust(&theme.palette.accentFg, field: "accent_fg", backgrounds: [theme.palette.accent],
               minimum: ThemeContrastThresholds.accentFg, theme: name, report: &report)
        adjust(&theme.palette.selectionFg, field: "selection_fg", backgrounds: [theme.palette.selectionBg],
               minimum: ThemeContrastThresholds.selection, theme: name, report: &report)
        adjust(&theme.palette.badgeFg, field: "badge_fg", backgrounds: [theme.palette.badgeBg],
               minimum: ThemeContrastThresholds.badge, theme: name, report: &report)
        adjust(&theme.palette.danger, field: "danger", backgrounds: [bg],
               minimum: ThemeContrastThresholds.semantic, theme: name, report: &report)
        adjust(&theme.palette.warning, field: "warning", backgrounds: [bg],
               minimum: ThemeContrastThresholds.semantic, theme: name, report: &report)
        adjust(&theme.palette.success, field: "success", backgrounds: [bg],
               minimum: ThemeContrastThresholds.semantic, theme: name, report: &report)
        adjust(&theme.palette.info, field: "info", backgrounds: [bg],
               minimum: ThemeContrastThresholds.semantic, theme: name, report: &report)

        if let selectedBg = theme.states.selected.bg, theme.states.selected.fg != nil {
            var foreground = theme.states.selected.fg ?? ""
            adjust(&foreground, field: "states.selected.fg", backgrounds: [selectedBg],
                   minimum: ThemeContrastThresholds.selectedRow, theme: name, report: &report)
            theme.states.selected.fg = foreground
        }
        return report
    }

    /// Best ratio any opaque colour can reach on `background`; the body bar is
    /// clamped to this so a mid-tone background does not fail forever.
    public static func maximumContrast(on background: RGBA) -> Double {
        let black = RGBA(red: 0, green: 0, blue: 0)
        let white = RGBA(red: 1, green: 1, blue: 1)
        return max(black.contrast(with: background), white.contrast(with: background))
    }

    // MARK: - One field

    private static func adjust(
        _ color: inout String,
        field: String,
        backgrounds: [String],
        minimum: Double,
        theme name: String,
        report: inout ThemeContrastReport
    ) {
        let backdrops = backgrounds.compactMap { RGBA(hex: $0) }
        guard let original = RGBA(hex: color), !backdrops.isEmpty else { return }
        let before = worstContrast(original, backdrops)
        let ceiling = backdrops.map(maximumContrast(on:)).min() ?? 0
        let target = min(minimum, ceiling)
        guard before < target - 0.000_001 else { return }
        guard let repaired = adjustedColor(original, backdrops: backdrops, target: target) else { return }
        let hex = PalettePalette.hex(repaired)
        guard hex != color else { return }
        let after = worstContrast(RGBA(hex: hex) ?? repaired, backdrops)
        report.changes.append(ThemeContrastChange(
            field: field,
            original: color,
            repaired: hex,
            before: before,
            after: after,
            hueShift: hueShift(original, RGBA(hex: hex) ?? repaired)
        ))
        color = hex
    }

    /// Smallest lightness move either toward white or toward black that makes
    /// every backdrop pass. If no move can, the first backdrop (the body
    /// background) keeps priority and the other surfaces take what is left.
    private static func adjustedColor(_ original: RGBA, backdrops: [RGBA], target: Double) -> RGBA? {
        let lab = oklab(original)
        let white = search(lab, extreme: 1, backdrops: backdrops, target: target)
        let black = search(lab, extreme: 0, backdrops: backdrops, target: target)
        let candidates = [white, black]
        let passing = candidates.filter { worstContrast($0.color, backdrops) >= target - 0.000_001 }
        if let closest = passing.min(by: { $0.distance < $1.distance }) {
            return closest.color
        }
        // No single colour clears every backdrop. The first backdrop is the
        // hard bar (`bg`); keep that passing when possible, then take whichever
        // direction reads best on the rest. One bright-background port has a
        // dark sunken surface and a brighter raised one, where those two cannot
        // both pass no matter what the accent is.
        let primary = backdrops[0]
        let primaryPassing = candidates.filter { $0.color.contrast(with: primary) >= target - 0.000_001 }
        let pool = primaryPassing.isEmpty ? candidates : primaryPassing
        return pool.max { worstContrast($0.color, backdrops) < worstContrast($1.color, backdrops) }?.color
    }

    private struct Candidate {
        var color: RGBA
        /// OKLab lightness distance from the authored colour.
        var distance: Double
    }

    private static func search(_ lab: OKLab, extreme: Double, backdrops: [RGBA], target: Double) -> Candidate {
        var low = 0.0
        var high = 1.0
        var best: (color: RGBA, t: Double)?
        for _ in 0..<28 {
            let mid = (low + high) / 2
            let candidate = quantized(lab, t: mid, extreme: extreme)
            if worstContrast(candidate, backdrops) >= target {
                best = (candidate, mid)
                high = mid
            } else {
                low = mid
            }
        }
        if let best {
            return Candidate(color: best.color, distance: best.t * abs(extreme - lab.l))
        }
        return Candidate(color: quantized(lab, t: 1, extreme: extreme), distance: abs(extreme - lab.l))
    }

    /// OKLab colour at `t` of the way from the authored lightness to `extreme`,
    /// with chroma scaled down only as far as sRGB needs. The result is the
    /// exact 8-bit colour that would be written, so the search judges the same
    /// value a second load would see and stays idempotent.
    private static func quantized(_ lab: OKLab, t: Double, extreme: Double) -> RGBA {
        let lightness = lab.l + (extreme - lab.l) * t
        let mapped = gamutMapped(OKLab(l: lightness, a: lab.a, b: lab.b))
        return RGBA(hex: PalettePalette.hex(mapped)) ?? mapped
    }

    private static func worstContrast(_ color: RGBA, _ backdrops: [RGBA]) -> Double {
        backdrops.map { color.contrast(with: $0) }.min() ?? 0
    }

    // MARK: - OKLab

    private struct OKLab {
        var l: Double
        var a: Double
        var b: Double
    }

    private static func oklab(_ color: RGBA) -> OKLab {
        func linear(_ value: Double) -> Double {
            value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let r = linear(color.red)
        let g = linear(color.green)
        let b = linear(color.blue)
        let l = cbrt(0.412_221_470_8 * r + 0.536_332_536_3 * g + 0.051_445_992_9 * b)
        let m = cbrt(0.211_903_498_2 * r + 0.680_699_545_1 * g + 0.107_396_956_6 * b)
        let s = cbrt(0.088_302_461_9 * r + 0.281_718_837_6 * g + 0.629_978_700_5 * b)
        return OKLab(
            l: 0.210_454_255_3 * l + 0.793_617_785_0 * m - 0.004_072_046_8 * s,
            a: 1.977_998_495_1 * l - 2.428_592_205_0 * m + 0.450_593_709_9 * s,
            b: 0.025_904_037_1 * l + 0.782_771_766_2 * m - 0.808_675_766_0 * s
        )
    }

    private static func linearRGB(_ lab: OKLab) -> (Double, Double, Double) {
        let l = pow(lab.l + 0.396_337_777_4 * lab.a + 0.215_803_757_3 * lab.b, 3)
        let m = pow(lab.l - 0.105_561_345_8 * lab.a - 0.063_854_172_8 * lab.b, 3)
        let s = pow(lab.l - 0.089_484_177_5 * lab.a - 1.291_485_548_0 * lab.b, 3)
        return (
            4.076_741_662_1 * l - 3.307_711_591_3 * m + 0.230_969_929_2 * s,
            -1.268_438_004_6 * l + 2.609_757_401_1 * m - 0.341_319_396_5 * s,
            -0.004_196_086_3 * l - 0.703_418_614_7 * m + 1.707_614_701_0 * s
        )
    }

    private static func inGamut(_ lab: OKLab) -> Bool {
        let rgb = linearRGB(lab)
        let epsilon = 0.000_001
        return rgb.0 >= -epsilon && rgb.0 <= 1 + epsilon
            && rgb.1 >= -epsilon && rgb.1 <= 1 + epsilon
            && rgb.2 >= -epsilon && rgb.2 <= 1 + epsilon
    }

    private static func gamutMapped(_ lab: OKLab) -> RGBA {
        var scale = 1.0
        if !inGamut(lab) {
            var low = 0.0
            var high = 1.0
            for _ in 0..<24 {
                let mid = (low + high) / 2
                if inGamut(OKLab(l: lab.l, a: lab.a * mid, b: lab.b * mid)) {
                    low = mid
                } else {
                    high = mid
                }
            }
            scale = low
        }
        let rgb = linearRGB(OKLab(l: lab.l, a: lab.a * scale, b: lab.b * scale))
        func sRGB(_ value: Double) -> Double {
            let clamped = min(1, max(0, value))
            return clamped <= 0.003_130_8 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        }
        return RGBA(red: sRGB(rgb.0), green: sRGB(rgb.1), blue: sRGB(rgb.2))
    }

    /// Circular OKLab hue distance in degrees. Near-neutral colours have no
    /// meaningful hue after 8-bit rounding, so they report zero drift.
    private static func hueShift(_ first: RGBA, _ second: RGBA) -> Double {
        let a = oklchHue(first)
        let b = oklchHue(second)
        guard let a, let b else { return 0 }
        let difference = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(difference, 360 - difference)
    }

    private static func oklchHue(_ color: RGBA) -> Double? {
        let lab = oklab(color)
        let chroma = (lab.a * lab.a + lab.b * lab.b).squareRoot()
        guard chroma >= 0.02 else { return nil }
        let degrees = atan2(lab.b, lab.a) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }
}
