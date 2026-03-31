// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SophaxChat",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "SophaxChatCore", targets: ["SophaxChatCore"]),
    ],
    targets: [
        // Prebuilt XCFramework containing the mls-rs Rust static library + C FFI headers.
        // Rebuilt by running: bash scripts/build_mls_xcframework.sh
        .binaryTarget(
            name: "SophaxMLS",
            path: "Frameworks/SophaxMLS.xcframework"
        ),
        .target(
            name: "SophaxChatCore",
            dependencies: ["SophaxMLS"],
            path: "Sources/SophaxChatCore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "SophaxChatCoreTests",
            dependencies: ["SophaxChatCore"],
            path: "Tests/SophaxChatCoreTests"
        )
    ]
)
