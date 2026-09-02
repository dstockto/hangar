// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Hangar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "HangarCore"),
        .executableTarget(
            name: "Hangar",
            dependencies: ["HangarCore"]
        ),
        .executableTarget(
            name: "hangar-probe",
            dependencies: ["HangarCore"]
        ),
        .testTarget(
            name: "HangarCoreTests",
            dependencies: ["HangarCore"]
        ),
    ]
)
