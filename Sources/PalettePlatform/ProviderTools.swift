import Foundation
import PaletteCore

public extension ProviderRequirements {
    /// The requirements `ToolLocator` cannot resolve. `ToolLocator` memoises
    /// both hits and misses, so asking from a row render is cheap.
    static func missing(_ requirements: [ProviderRequirement]) -> [ProviderRequirement] {
        requirements.filter { ToolLocator.shared.path(for: $0.tool) == nil }
    }
}
