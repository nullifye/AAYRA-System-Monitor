// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AAYRA",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "AAYRA",
            path: "Sources/AAYRA",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
