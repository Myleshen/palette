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
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.99.0"),
    ],
    targets: [
        .target(
            name: "PaletteCore",
            dependencies: [
                .product(name: "TOMLKit", package: "TOMLKit"),
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .target(
            name: "PalettePlatform",
            dependencies: ["PaletteCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "PaletteProviders",
            dependencies: [
                "PaletteCore", "PalettePlatform",
                .product(name: "TOMLKit", package: "TOMLKit"),
            ]
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
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .testTarget(
            name: "PaletteTests",
            dependencies: [
                "PaletteCore", "PalettePlatform", "PaletteProviders", "PaletteRuntime",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
