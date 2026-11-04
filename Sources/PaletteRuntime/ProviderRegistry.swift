import Foundation
import PaletteCore

public struct RegistrySearchResult: Sendable {
    public var items: [PaletteItem]
    public var diagnostics: [Diagnostic]
    public var parsed: ParsedQuery

    public init(items: [PaletteItem], diagnostics: [Diagnostic], parsed: ParsedQuery) {
        self.items = items
        self.diagnostics = diagnostics
        self.parsed = parsed
    }
}

public final class ProviderRegistry: @unchecked Sendable {
    public let providers: [any PaletteProvider]
    public let parser: QueryParser
    public let diagnostics: [Diagnostic]

    private let byID: [String: any PaletteProvider]
    private let globalProviders: [any PaletteProvider]

    public init(
        providers: [any PaletteProvider],
        prefix: String,
        aliases: [String: [String]] = [:],
        order: [String] = [],
        disabled: [String] = [],
        diagnostics initialDiagnostics: [Diagnostic] = []
    ) {
        var diagnostics = initialDiagnostics
        let disabledIDs = Set(disabled.map { $0.lowercased() })
        var byID: [String: any PaletteProvider] = [:]
        for provider in providers {
            let id = provider.descriptor.id
            if disabledIDs.contains(id.lowercased()), id != "apps" { continue }
            if byID[id] != nil {
                diagnostics.append(Diagnostic(.warning, "Duplicate provider id '\(id)'; the later provider was ignored.", source: "providers"))
                continue
            }
            byID[id] = provider
        }

        let orderIndex = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        self.providers = byID.values.sorted {
            let lhs = orderIndex[$0.descriptor.id] ?? Int.max
            let rhs = orderIndex[$1.descriptor.id] ?? Int.max
            if lhs != rhs { return lhs < rhs }
            if $0.descriptor.priority != $1.descriptor.priority {
                return $0.descriptor.priority > $1.descriptor.priority
            }
            return $0.descriptor.id < $1.descriptor.id
        }
        self.byID = byID

        var triggers = self.providers.compactMap { provider -> TriggerEntry? in
            guard let trigger = provider.descriptor.trigger else { return nil }
            return TriggerEntry(trigger: trigger, providerID: provider.descriptor.id, priority: provider.descriptor.priority)
        }
        var seen: [String: String] = [:]
        for entry in triggers.sorted(by: { $0.providerID < $1.providerID }) {
            let key = entry.trigger.lowercased()
            if let existing = seen[key] {
                diagnostics.append(Diagnostic(.warning, "Providers '\(existing)' and '\(entry.providerID)' both use trigger '\(entry.trigger)'; '\(existing)' wins.", source: "providers"))
            } else {
                seen[key] = entry.providerID
            }
        }

        for providerID in aliases.keys.sorted() {
            guard let provider = byID[providerID] else {
                diagnostics.append(Diagnostic(.warning, "Aliases are configured for unknown provider '\(providerID)'.", source: "providers"))
                continue
            }
            for alias in aliases[providerID] ?? [] {
                let word = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !word.isEmpty,
                      word.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
                    diagnostics.append(Diagnostic(.warning, "Alias '\(alias)' for '\(providerID)' is not a valid trigger word.", source: "providers"))
                    continue
                }
                let key = word.lowercased()
                if let existing = seen[key] {
                    diagnostics.append(Diagnostic(.warning, "Alias '\(word)' for '\(providerID)' collides with '\(existing)'.", source: "providers"))
                    continue
                }
                seen[key] = providerID
                triggers.append(TriggerEntry(trigger: word, providerID: providerID, priority: provider.descriptor.priority))
            }
        }

        self.parser = QueryParser(prefix: prefix, triggers: triggers)
        self.globalProviders = self.providers.filter { $0.descriptor.isGlobal }
        self.diagnostics = diagnostics
    }

    public func search(raw: String) async -> RegistrySearchResult {
        let parsed = parser.parse(raw)
        var diagnostics: [Diagnostic] = []

        switch parsed.scope {
        case .provider(let id):
            guard let provider = byID[id] else {
                diagnostics.append(Diagnostic(.error, "No provider is registered for that prefix.", source: "providers"))
                return RegistrySearchResult(items: [], diagnostics: diagnostics, parsed: parsed)
            }
            do {
                let items = try await provider.search(SearchRequest(text: parsed.text, limit: 5000, isBound: true))
                return RegistrySearchResult(items: Array(items.prefix(5000)), diagnostics: diagnostics, parsed: parsed)
            } catch is CancellationError {
                return RegistrySearchResult(items: [], diagnostics: [], parsed: parsed)
            } catch ProviderError.cancelled {
                return RegistrySearchResult(items: [], diagnostics: [], parsed: parsed)
            } catch {
                diagnostics.append(Diagnostic(.warning, message(for: error, provider: provider.descriptor.name), source: provider.descriptor.id))
                return RegistrySearchResult(items: [], diagnostics: diagnostics, parsed: parsed)
            }

        case .global:
            let providers = globalProviders
            guard !providers.isEmpty else {
                return RegistrySearchResult(items: [], diagnostics: diagnostics, parsed: parsed)
            }
            let providerLimit = parsed.text.isEmpty ? 500 : 8

            let collected = await withTaskGroup(of: (Int, [PaletteItem], Diagnostic?).self) { group in
                for (index, provider) in providers.enumerated() {
                    group.addTask {
                        do {
                            let items = try await provider.search(SearchRequest(text: parsed.text, limit: providerLimit, isBound: false))
                            return (index, Array(items.prefix(providerLimit)), nil)
                        } catch is CancellationError {
                            return (index, [], nil)
                        } catch ProviderError.cancelled {
                            return (index, [], nil)
                        } catch {
                            let diagnostic = Diagnostic(
                                .warning,
                                "\(provider.descriptor.name): \(error.localizedDescription)",
                                source: provider.descriptor.id
                            )
                            return (index, [], diagnostic)
                        }
                    }
                }
                var results: [(Int, [PaletteItem], Diagnostic?)] = []
                for await result in group { results.append(result) }
                return results
            }

            var items: [PaletteItem] = []
            for (_, providerItems, diagnostic) in collected.sorted(by: { $0.0 < $1.0 }) {
                items.append(contentsOf: providerItems)
                if let diagnostic { diagnostics.append(diagnostic) }
            }
            return RegistrySearchResult(items: items, diagnostics: diagnostics, parsed: parsed)
        }
    }

    public func activate(item: PaletteItem, action: PaletteAction) async throws {
        guard let provider = byID[item.providerID] else {
            throw ProviderError.failed("Provider '\(item.providerID)' is no longer available")
        }
        try await provider.activate(item, action: action)
    }

    public func shutdown() async {
        for provider in providers {
            if let external = provider as? ExternalProvider {
                await external.shutdown()
            }
        }
    }

    private func message(for error: Error, provider: String) -> String {
        if let providerError = error as? ProviderError {
            switch providerError {
            case .toolMissing(let tool):
                return "\(provider): \(tool) is not installed"
            default:
                return "\(provider): \(providerError.localizedDescription)"
            }
        }
        return "\(provider): \(error.localizedDescription)"
    }
}
