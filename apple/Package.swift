// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NWApple",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "NwVpnWire", targets: ["NwVpnWire"]),
        .library(name: "NWTunnel", targets: ["NWTunnel"]),
    ],
    targets: [
        .target(name: "NwVpnWire"),
        .target(
            name: "NWTunnel",
            dependencies: ["NwVpnWire"],
            linkerSettings: [
                .linkedFramework("NetworkExtension"),
                .linkedFramework("Network"),
            ]
        ),
        .testTarget(
            name: "NWProtocolTests",
            dependencies: ["NwVpnWire"]
        ),
    ]
)
