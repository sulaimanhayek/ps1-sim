// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PS1Sim",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CLibretro"),
        // Pure logic with no UI or emulator dependencies, so it can be tested
        // by a plain executable — the toolchain here ships no XCTest.
        .target(name: "PS1SimKit"),
        .executableTarget(
            name: "PS1Sim",
            dependencies: ["CLibretro", "PS1SimKit"],
            linkerSettings: [.linkedFramework("Metal"), .linkedFramework("MetalKit")]
        ),
        .executableTarget(name: "PS1SimKitTests", dependencies: ["PS1SimKit"]),
    ]
)
