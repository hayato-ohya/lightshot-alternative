// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LightshotAlt",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "LightshotAlt",
            path: "Sources/LightshotAlt",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
package.targets.append(.testTarget(name: "LightshotAltTests", dependencies: ["LightshotAlt"], path: "Tests/LightshotAltTests", swiftSettings: [.swiftLanguageMode(.v5)]))
