// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Palette",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Palette", targets: ["PaletteApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.5.0"),
    ],
    targets: [
        .target(
            name: "PaletteCore",
            dependencies: [.product(name: "TOMLKit", package: "TOMLKit")]
        ),
        .target(
            name: "PalettePlatform",
            dependencies: ["PaletteCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "PaletteProviders",
            dependencies: ["PaletteCore", "PalettePlatform"]
        ),
        .target(
            name: "PaletteRuntime",
            dependencies: [
                "PaletteCore", "PalettePlatform", "PaletteProviders",
                .product(name: "TOMLKit", package: "TOMLKit"),
            ]
        ),
        .executableTarget(
            name: "PaletteApp",
            dependencies: [
                "PaletteCore", "PalettePlatform", "PaletteProviders", "PaletteRuntime",
            ]
        ),
        .testTarget(
            name: "PaletteTests",
            dependencies: [
                "PaletteCore", "PalettePlatform", "PaletteProviders", "PaletteRuntime",
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
