import XCTest
@testable import PaletteCore

final class TroubleRoutingTests: XCTestCase {
    private func item(trouble: ItemTrouble?) -> PaletteItem {
        PaletteItem(
            id: "row",
            title: "Install Bitwarden CLI",
            actions: [PaletteAction(id: "install", title: "Open Terminal", kind: .custom)],
            trouble: trouble,
            providerID: "bw"
        )
    }

    func testTroubleRowRoutesReturnToItsSettingsAnchor() {
        let row = self.item(trouble: ItemTrouble(
            title: "Install bw",
            detail: "brew install bitwarden-cli",
            settingsAnchor: "providers-missing-tools"
        ))
        XCTAssertEqual(row.returnRoute, .settings("providers-missing-tools"))
    }

    func testNormalRowKeepsItsPrimaryAction() {
        let row = self.item(trouble: nil)
        XCTAssertEqual(row.returnRoute, .action(row.actions[0]))
    }

    func testTroubleWithoutAnchorFallsBackToTheAction() {
        let row = self.item(trouble: ItemTrouble(title: "Vault locked"))
        XCTAssertEqual(row.returnRoute, .action(row.actions[0]))
    }

    func testTroubleWithoutAnyActionHasNoRoute() {
        let row = PaletteItem(id: "row", title: "Nothing to do", providerID: "bw")
        XCTAssertNil(row.returnRoute)
    }

    /// Providers use the shared helper so the detail is always the published
    /// install command, not a hand-written one.
    func testMissingToolTroubleCarriesTheProviderRequirementsInstallLine() {
        let requirement = ProviderRequirements.requirements(forProviderID: "proj")[0]
        let trouble = ItemTrouble.missingTool(requirement)
        XCTAssertEqual(trouble.title, "Install devx")
        XCTAssertEqual(trouble.detail, "brew install Myleshen/tap/devx")
        XCTAssertEqual(trouble.settingsAnchor, "providers-missing-tools")
    }
}
