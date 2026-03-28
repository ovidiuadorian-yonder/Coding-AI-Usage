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
                .linkedFramework("Security"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
