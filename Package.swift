// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PulseBoard",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PulseBoard", targets: ["PulseBoard"])
    ],
    targets: [
        .executableTarget(
            name: "PulseBoard",
            dependencies: ["PulseHardware"],
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "PulseHardware",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .testTarget(
            name: "PulseBoardTests",
            dependencies: ["PulseBoard"]
        )
    ]
)
