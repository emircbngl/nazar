// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Nazar",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Nazar",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Nazar",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Nazar/Info.plist"])
            ]
        )
    ]
)
