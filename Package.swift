// swift-tools-version:5.9
import Foundation
import PackageDescription

// The shared Rust core is linked statically into the app. Build it first:
//   cd core && cargo build --release -p vibeboard-core
// CI builds arm64 + x86_64 and lipos them into one archive.
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let coreLibraryDirectory = ProcessInfo.processInfo.environment["VIBEBOARD_CORE_LIB_DIR"]
    ?? "\(packageDirectory)/core/target/release"

let package = Package(
    name: "VibeBoardPlus",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CVibeBoardCore",
            path: "Sources/CVibeBoardCore",
            linkerSettings: [
                // Link the static archive explicitly: the build directory also contains a
                // cdylib of the same name, which the linker would otherwise prefer.
                .unsafeFlags(["\("\(coreLibraryDirectory)/libvibeboard_core.a")", "-lc++"]),
                .linkedFramework("Accelerate"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "VibeBoardPlus",
            dependencies: ["CVibeBoardCore"],
            path: "Sources/VibeBoardPlus"
        ),
        .testTarget(
            name: "VibeBoardPlusTests",
            dependencies: ["VibeBoardPlus"],
            path: "Tests/VibeBoardPlusTests"
        ),
    ]
)
