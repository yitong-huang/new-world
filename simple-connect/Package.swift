// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SimpleConnect",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SimpleConnect", targets: ["SimpleConnect"]),
    ],
    targets: [
        .executableTarget(
            name: "SimpleConnect",
            path: "Sources"
        ),
    ]
)
