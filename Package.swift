// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LightshotAlt",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LightshotAlt",
            path: "Sources/LightshotAlt",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
package.targets.append(.testTarget(name: "LightshotAltTests", dependencies: ["LightshotAlt"], path: "Tests/LightshotAltTests"))
