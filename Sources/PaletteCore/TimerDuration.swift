import Foundation

/// Parsing and formatting for `/timer` durations.
///
/// Accepts `25m`, `90s`, `1h30m`, `1h 30m`, `1:30` (minutes:seconds) and a bare
/// number, which means minutes.
public enum TimerDuration {
    public static func parse(_ raw: String) -> TimeInterval? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: " ", with: "")

        if text.contains(":") {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 || parts.count == 3,
                  let first = Double(parts[parts.count - 2]),
                  let last = Double(parts[parts.count - 1]),
                  first >= 0, last >= 0, last < 60 else { return nil }
            if parts.count == 3 {
                guard let hours = Double(parts[0]), hours >= 0 else { return nil }
                return hours * 3600 + first * 60 + last
            }
            return first * 60 + last
        }

        if let minutes = Double(text) {
            return minutes > 0 ? minutes * 60 : nil
        }

        var total: TimeInterval = 0
        var digits = ""
        for character in text {
            if character.isNumber || character == "." {
                digits.append(character)
                continue
            }
            guard let value = Double(digits), value >= 0 else { return nil }
            switch character {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            default: return nil
            }
            digits = ""
        }
        guard digits.isEmpty else { return nil }
        return total > 0 ? total : nil
    }

    /// `25:00` under an hour, `1:05:00` above it.
    public static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.up)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }

    /// Human label for a duration, e.g. `25 minutes` or `1 hour 30 minutes`.
    public static func label(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        if parts.isEmpty { parts.append("\(seconds) second\(seconds == 1 ? "" : "s")") }
        return parts.joined(separator: " ")
    }
}
