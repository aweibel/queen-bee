// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "QueenBeeCore",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "QueenBeeCore", targets: ["QueenBeeCore"]),
        .library(name: "QueenBeeLink", targets: ["QueenBeeLink"]),
    ],
    targets: [
        .target(name: "QueenBeeCore"),
        .target(name: "QueenBeeLink", dependencies: ["QueenBeeCore"]),
        .testTarget(name: "QueenBeeCoreTests", dependencies: ["QueenBeeCore"]),
        .testTarget(name: "QueenBeeLinkTests", dependencies: ["QueenBeeLink"]),
    ],
    swiftLanguageModes: [.v6]
)
