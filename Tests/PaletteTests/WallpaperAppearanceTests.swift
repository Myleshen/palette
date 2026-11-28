import XCTest
import PaletteCore
@testable import PalettePlatform

final class WallpaperAppearanceTests: XCTestCase {
    private func pixels(_ value: Double) -> WallpaperPixels {
        let color = RGBA(red: value, green: value, blue: value, alpha: 1)
        return WallpaperPixels(width: 4, height: 4, pixels: Array(repeating: color, count: 16))
    }

    func testBrightPictureSuggestsLightAndDarkPictureDark() {
        XCTAssertEqual(WallpaperPalette.suggestedAppearance(pixels: pixels(0.95)), "light")
        XCTAssertEqual(WallpaperPalette.suggestedAppearance(pixels: pixels(0.04)), "dark")
    }

    @MainActor
    func testAutoUsesThePictureAndExplicitStaysExplicit() async {
        let bright = pixels(0.95)
        let auto = await ThemingEngine.wallpaperPalette(
            from: URL(fileURLWithPath: "/tmp/bright.png"),
            appearance: "auto",
            saturation: 0,
            contrast: 0,
            readPixels: { _ in bright }
        )
        XCTAssertEqual(auto?.appearance, "light")

        let forced = await ThemingEngine.wallpaperPalette(
            from: URL(fileURLWithPath: "/tmp/bright.png"),
            appearance: "dark",
            saturation: 0,
            contrast: 0,
            readPixels: { _ in bright }
        )
        XCTAssertEqual(forced?.appearance, "dark")
    }
}
