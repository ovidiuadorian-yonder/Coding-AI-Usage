// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodingAIUsage",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CodingAIUsage",
            path: "CodingAIUsage",
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("WebKit")
            ]
        ),
        .testTarget(
            name: "CodingAIUsageTests",
            dependencies: ["CodingAIUsage"]
        )
    ]
)
