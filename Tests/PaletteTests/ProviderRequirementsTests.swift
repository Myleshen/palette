import XCTest
@testable import PaletteCore

final class ProviderRequirementsTests: XCTestCase {
    /// The install line is copied verbatim into a terminal, so it must be the
    /// published formula, not a local build recipe.
    func testInstallCommandsAreExact() {
        XCTAssertEqual(ProviderRequirements.requirements(forProviderID: "proj").first?.install, "brew install Myleshen/tap/devx")
        XCTAssertEqual(ProviderRequirements.requirements(forProviderID: "atlas").first?.install, "brew install Myleshen/tap/atlas")
        XCTAssertEqual(ProviderRequirements.requirements(forProviderID: "zj").first?.install, "brew install zellij")
        XCTAssertEqual(ProviderRequirements.requirements(forProviderID: "ghp").first?.install, "brew install gh")
        XCTAssertEqual(ProviderRequirements.requirements(forProviderID: "bwt").first?.install, "brew install bitwarden-cli")
        XCTAssertEqual(ProviderRequirements.requirements(forProviderID: "docker").first?.install, "brew install --cask docker")
        XCTAssertEqual(ProviderRequirements.pathTools.map(\.install), ["brew install fd", "brew install fzf"])
    }

    func testEveryRequirementExplainsItself() {
        for requirement in ProviderRequirements.map.values.joined() {
            XCTAssertFalse(requirement.why.isEmpty, requirement.tool)
        }
        XCTAssertEqual(ProviderRequirements.requirements(forProviderID: "nope"), [])
    }
}
