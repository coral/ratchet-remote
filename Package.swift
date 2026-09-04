// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ratchet-remote",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "RatchetProtocol", targets: ["RatchetProtocol"]),
        .library(name: "RMEControl", targets: ["RMEControl"]),
        .library(name: "RemoteCore", targets: ["RemoteCore"]),
        .executable(name: "RatchetRemote", targets: ["RatchetRemote"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-protobuf.git",
            exact: "1.38.1"
        ),
    ],
    targets: [
        .target(
            name: "RatchetProtocol",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            plugins: [
                .plugin(name: "SwiftProtobufPlugin", package: "swift-protobuf"),
            ]
        ),
        .target(
            name: "RMEControl",
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit"),
            ]
        ),
        .target(
            name: "RemoteCore",
            dependencies: ["RatchetProtocol", "RMEControl"],
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "RatchetRemote",
            dependencies: ["RemoteCore", "RMEControl"],
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "RatchetProtocolTests",
            dependencies: ["RatchetProtocol"]
        ),
        .testTarget(
            name: "RMEControlTests",
            dependencies: ["RMEControl"]
        ),
        .testTarget(
            name: "RemoteCoreTests",
            dependencies: ["RemoteCore", "RatchetProtocol", "RMEControl"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
