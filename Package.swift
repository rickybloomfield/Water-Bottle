// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HidrateKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HidrateKit", targets: ["HidrateKit"]),
        .executable(name: "hidrate-cli", targets: ["HidrateCLI"]),
    ],
    targets: [
        .target(
            name: "HidrateKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "HidrateCLI",
            dependencies: ["HidrateKit"],
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                // Embed an Info.plist so macOS lets a bare CLI use CoreBluetooth
                // (without NSBluetoothAlwaysUsageDescription the process is killed).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/HidrateCLI/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "HidrateKitTests",
            dependencies: ["HidrateKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
