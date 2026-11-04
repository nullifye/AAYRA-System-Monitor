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
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
