// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PS1Sim",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CLibretro"),
        .executableTarget(
            name: "PS1Sim",
            dependencies: ["CLibretro"],
            linkerSettings: [.linkedFramework("Metal"), .linkedFramework("MetalKit")]
        ),
    ]
)
