// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Nazar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Nazar",
            path: "Nazar",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Nazar/Info.plist"])
            ]
        )
    ]
)
