// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VibeBoardPlus",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/alta/swift-opus.git", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "VibeBoardPlus",
            dependencies: [.product(name: "Opus", package: "swift-opus")],
            path: "Sources/VibeBoardPlus"
        ),
        .testTarget(name: "VibeBoardPlusTests", dependencies: ["VibeBoardPlus", .product(name: "Opus", package: "swift-opus")])
    ]
)
