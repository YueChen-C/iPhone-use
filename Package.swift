// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iphone-use",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "iphone-use", targets: ["iPhoneUse"])
    ],
    targets: [
        .executableTarget(
            name: "iPhoneUse",
            path: "Sources/iPhoneUse",
            resources: [.copy("Resources/AppIcon.icns")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "iPhoneUseTests",
            dependencies: ["iPhoneUse"],
            path: "Tests/iPhoneUseTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
