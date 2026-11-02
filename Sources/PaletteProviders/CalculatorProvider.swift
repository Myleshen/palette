import Foundation
import PaletteCore

public final class CalculatorProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "calc",
        name: "Calculator",
        trigger: "calc",
        isGlobal: true,
        priority: 90,
        icon: "symbol:function"
    )

    public init() {}

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let input = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, Calculator.looksLikeExpression(input), let result = Calculator.evaluate(input) else {
            return []
        }
        let formatted = result.formatted
        return [PaletteItem(
            id: "result",
            title: formatted,
            subtitle: "\(input) — copy result",
            icon: .symbol("equal.square"),
            score: 2_000,
            actions: [
                PaletteAction(id: "copy", title: "Copy Result", kind: .copyText, value: .text(formatted)),
                PaletteAction(id: "paste", title: "Paste Result", kind: .pasteText, value: .text(formatted)),
            ],
            providerID: descriptor.id,
            providerName: descriptor.name
        )]
    }
}
