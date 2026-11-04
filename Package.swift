// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AAYRA",
    platforms: [.macOS(.v15)],
    targets: [
        // Tiny C helper: the NVMe SMART interface is a COM-style IOKit plug-in, easiest to call from C.
        .target(
            name: "CNVMe",
            path: "Sources/CNVMe",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .executableTarget(
            name: "AAYRA",
            dependencies: ["CNVMe"],
            path: "Sources/AAYRA",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("DiskArbitration"),   // how external drives are connected (USB, Thunderbolt…)
                .linkedFramework("Carbon"),            // global keyboard shortcut (RegisterEventHotKey)
            ]
        ),
        // Unit tests for the parsers and formatters (`swift test`); run by CI on every push.
        .testTarget(
            name: "AAYRATests",
            dependencies: ["AAYRA"],
            path: "Tests/AAYRATests"
        )
    ],
    swiftLanguageModes: [.v5]
)
