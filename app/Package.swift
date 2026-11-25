// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OneCastOSS",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "OneCastOSS", targets: ["OneCastOSS"])
    ],
    targets: [
        .target(
            name: "OneCastCoreFFI",
            path: "Sources/OneCastCoreFFI",
            publicHeadersPath: "include"
        ),
        .target(
            name: "OneCastCore",
            dependencies: ["OneCastCoreFFI"],
            path: "Sources/OneCastCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "OneCastOSS",
            dependencies: ["OneCastCore"],
            path: "Sources/App",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags(["-L", "Libs", "-lonecast_core"]),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalFX"),
                .linkedFramework("MetalKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("GameController"),
                .linkedFramework("IOKit"),
                .linkedFramework("AuthenticationServices")
            ]
        ),
        .testTarget(
            name: "OneCastOSSTests",
            dependencies: ["OneCastOSS", "OneCastCore"],
            path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags(["-L", "Libs", "-lonecast_core"]),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration")
            ]
        )
    ]
)
