// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PulseBoard",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PulseBoard", targets: ["PulseBoard"]),
        .executable(name: "PulseBoardHelper", targets: ["PulseBoardHelper"])
    ],
    targets: [
        .executableTarget(
            name: "PulseBoard",
            dependencies: ["PulseHardware"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "PulseHardware",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(name: "PulseBoardHelper"),
        .testTarget(
            name: "PulseBoardTests",
            dependencies: ["PulseBoard"]
        )
    ]
)
