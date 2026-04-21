// swift-tools-version: 6.2
import PackageDescription

let targets: [Target] = [
    .executableTarget(
        name: "Type4Me",
        path: "Type4Me",
        exclude: ["Resources"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
        name: "Type4MeTests",
        dependencies: ["Type4Me"],
        path: "Type4MeTests"
    ),
]

let package = Package(
    name: "Type4Me",
    platforms: [.macOS(.v14)],
    dependencies: [],
    targets: targets
)
