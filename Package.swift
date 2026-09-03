// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "NapeProFix",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NapeProFix", targets: ["NapeProFix"])
    ],
    targets: [
        .executableTarget(
            name: "NapeProFix",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "NapeProFixTests",
            dependencies: ["NapeProFix"]
        )
    ]
)
