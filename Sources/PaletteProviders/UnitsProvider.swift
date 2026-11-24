import AppKit
import Foundation
import PaletteCore

/// Unit and currency conversion: `10 km in mi`, `72 f to c`, `20 usd in eur`.
/// Units are offline; currencies use a cached daily rate table.
public final class UnitsProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "unit",
        name: "Convert",
        trigger: "unit",
        isGlobal: true,
        priority: 42,
        icon: "symbol:arrow.left.arrow.right",
        keywords: ["convert", "unit", "currency", "km", "miles", "kg", "pounds", "celsius", "fahrenheit", "usd", "eur"]
    )

    private let bridge: HostBridge

    public init(bridge: HostBridge) {
        self.bridge = bridge
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            guard request.isBound else { return [] }
            return [hintRow()]
        }
        guard let conversion = Units.parse(query) else { return [] }
        if conversion.isCurrency {
            guard let result = await Currency.convert(conversion) else {
                return [infoRow(
                    title: "Currency rates unavailable",
                    subtitle: "Check your connection, then try again",
                    conversion: conversion
                )]
            }
            return [row(conversion, value: result)]
        }
        return [row(conversion, value: Units.convert(conversion))]
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        if action.id == "unit-hint" {
            await bridge.notify("Type a value, for example 10 km to miles")
            return
        }
        guard let value = action.value.text else { return }
        await bridge.copyToClipboard(value, concealed: false, clearAfterMs: nil)
    }

    private func hintRow() -> PaletteItem {
        PaletteItem(
            id: "unit:hint",
            title: "Convert a value",
            subtitle: "10 km to miles · 100 usd to eur · 20 c to f — mm cm m km in ft yd mi · g kg oz lb · ml l cup pint gal · b kb mb gb tb · c f k · usd eur gbp inr jpy aud cad chf sgd aed",
            icon: .symbol("arrow.left.arrow.right"),
            badge: "CONVERT",
            actions: [PaletteAction(id: "unit-hint", title: "How to use", kind: .custom)],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private func row(_ conversion: Units.Conversion, value: Double) -> PaletteItem {
        let number = Units.format(value)
        let title = "\(Units.format(conversion.amount)) \(conversion.from.upperSymbol) = \(number) \(conversion.to.upperSymbol)"
        return PaletteItem(
            id: "convert:\(conversion.from.code):\(conversion.to.code):\(conversion.amount)",
            title: title,
            subtitle: "Press Enter to copy \(number)",
            icon: .symbol("arrow.left.arrow.right"),
            badge: "CONVERT",
            group: "Convert",
            score: 10_000,
            actions: [PaletteAction(id: "copy", title: "Copy \(number)", kind: .custom, value: .text(number))],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private func infoRow(title: String, subtitle: String, conversion: Units.Conversion) -> PaletteItem {
        PaletteItem(
            id: "convert-error",
            title: title,
            subtitle: subtitle,
            icon: .symbol("exclamationmark.triangle"),
            group: "Convert",
            score: 1_000,
            actions: [PaletteAction(id: "retry", title: "Retry", kind: .custom, value: .none)],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }
}

// MARK: - Parsing

public enum Units {
    public struct Unit: Sendable, Equatable {
        public var code: String
        public var kind: Kind
        public var factor: Double      // to the kind's base unit
        public var offset: Double      // for temperature

        public var upperSymbol: String { code.uppercased() }
    }

    public enum Kind: String, Sendable {
        case length, mass, volume, data, temperature, currency
    }

    public struct Conversion: Sendable {
        public var amount: Double
        public var from: Unit
        public var to: Unit
        public var isCurrency: Bool { from.kind == .currency || to.kind == .currency }
    }

    static let units: [String: Unit] = {
        var table: [String: Unit] = [:]
        func add(_ codes: [String], _ kind: Kind, _ factor: Double, offset: Double = 0) {
            for code in codes {
                table[code] = Unit(code: code, kind: kind, factor: factor, offset: offset)
            }
        }
        // Length, base metre.
        add(["mm", "millimeter", "millimetre"], .length, 0.001)
        add(["cm", "centimeter", "centimetre"], .length, 0.01)
        add(["m", "meter", "metre"], .length, 1)
        add(["km", "kilometer", "kilometre"], .length, 1000)
        add(["in", "inch", "inches"], .length, 0.0254)
        add(["ft", "foot", "feet"], .length, 0.3048)
        add(["yd", "yard", "yards"], .length, 0.9144)
        add(["mi", "mile", "miles"], .length, 1609.344)
        // Mass, base gram.
        add(["g", "gram", "grams"], .mass, 1)
        add(["kg", "kilogram", "kilograms"], .mass, 1000)
        add(["oz", "ounce", "ounces"], .mass, 28.349523125)
        add(["lb", "lbs", "pound", "pounds"], .mass, 453.59237)
        // Volume, base litre.
        add(["ml", "milliliter", "millilitre"], .volume, 0.001)
        add(["l", "liter", "litre"], .volume, 1)
        add(["cup", "cups"], .volume, 0.2365882365)
        add(["pint", "pints"], .volume, 0.473176473)
        add(["gal", "gallon", "gallons"], .volume, 3.785411784)
        // Data, base byte.
        add(["b", "byte", "bytes"], .data, 1)
        add(["kb"], .data, 1_000)
        add(["mb"], .data, 1_000_000)
        add(["gb"], .data, 1_000_000_000)
        add(["tb"], .data, 1_000_000_000_000)
        add(["kib"], .data, 1_024)
        add(["mib"], .data, 1_048_576)
        add(["gib"], .data, 1_073_741_824)
        // Temperature uses offsets, handled separately.
        add(["c", "celsius"], .temperature, 1)
        add(["f", "fahrenheit"], .temperature, 1)
        add(["k", "kelvin"], .temperature, 1)
        // Currencies: factor is filled from the rate table at conversion time.
        for code in ["usd", "eur", "gbp", "inr", "jpy", "aud", "cad", "chf", "sgd", "aed"] {
            table[code] = Unit(code: code, kind: .currency, factor: 1, offset: 0)
        }
        return table
    }()

    public static func parse(_ raw: String) -> Conversion? {
        let text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let pattern = #"^\s*(-?\d+(?:[.,]\d+)?)\s*([a-z]+)\s+(?:in|to|as)\s+([a-z]+)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges == 4,
              let amountRange = Range(match.range(at: 1), in: text),
              let fromRange = Range(match.range(at: 2), in: text),
              let toRange = Range(match.range(at: 3), in: text) else {
            return nil
        }
        let amount = Double(text[amountRange].replacingOccurrences(of: ",", with: ".")) ?? 0
        guard let from = units[String(text[fromRange])], let to = units[String(text[toRange])] else { return nil }
        guard from.kind == to.kind else { return nil }
        if from.kind == .currency { return Conversion(amount: amount, from: from, to: to) }
        return Conversion(amount: amount, from: from, to: to)
    }

    /// Converts a non-currency pair. Currencies go through `Currency`.
    public static func convert(_ conversion: Conversion) -> Double {
        let from = conversion.from
        let to = conversion.to
        if from.kind == .temperature {
            let celsius: Double
            switch from.code {
            case "f", "fahrenheit": celsius = (conversion.amount - 32) * 5 / 9
            case "k", "kelvin": celsius = conversion.amount - 273.15
            default: celsius = conversion.amount
            }
            switch to.code {
            case "f", "fahrenheit": return celsius * 9 / 5 + 32
            case "k", "kelvin": return celsius + 273.15
            default: return celsius
            }
        }
        let base = conversion.amount * from.factor
        return base / to.factor
    }

    public static func format(_ value: Double) -> String {
        if value == 0 { return "0" }
        if abs(value) >= 1_000 || abs(value) < 0.01 {
            return String(format: "%.4g", value)
        }
        return String(format: "%.4f", value)
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
    }
}

// MARK: - Currency

enum Currency {
    private struct Rates: Sendable {
        var base: String
        var values: [String: Double]
        var fetchedAt: Date
    }

    private static var cache: Rates?

    static func convert(_ conversion: Units.Conversion) async -> Double? {
        let from = conversion.from.code.uppercased()
        let to = conversion.to.code.uppercased()
        guard let rates = await table(base: from) else { return nil }
        guard let rate = rates.values[to] else { return nil }
        return conversion.amount * rate
    }

    private static func table(base: String) async -> Rates? {
        if let cache, cache.base == base, Date().timeIntervalSince(cache.fetchedAt) < 3600 {
            return cache
        }
        guard let url = URL(string: "https://api.frankfurter.app/latest?from=\(base)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = object["rates"] as? [String: Double] else {
            if let cache, cache.base == base, Date().timeIntervalSince(cache.fetchedAt) < 86_400 {
                return cache
            }
            return nil
        }
        var merged = values
        merged[base] = 1
        let rates = Rates(base: base, values: merged, fetchedAt: Date())
        cache = rates
        return rates
    }
}
