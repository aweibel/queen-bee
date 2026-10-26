// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "QueenBeeCore",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "QueenBeeCore", targets: ["QueenBeeCore"]),
        .library(name: "QueenBeeLink", targets: ["QueenBeeLink"]),
        .library(name: "QueenBeeDesign", targets: ["QueenBeeDesign"]),
    ],
    targets: [
        .target(name: "QueenBeeCore"),
        .target(name: "QueenBeeLink", dependencies: ["QueenBeeCore"]),
        // How the Mac and the iPhone and iPad apps look: colours, type, measures and the parts screens are built from.
        .target(name: "QueenBeeDesign"),
        .testTarget(name: "QueenBeeCoreTests", dependencies: ["QueenBeeCore"]),
        .testTarget(name: "QueenBeeLinkTests", dependencies: ["QueenBeeLink"]),
        .testTarget(name: "QueenBeeDesignTests", dependencies: ["QueenBeeDesign"]),
    ],
    swiftLanguageModes: [.v6]
)
