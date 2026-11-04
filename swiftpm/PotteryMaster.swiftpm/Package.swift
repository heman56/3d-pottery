// swift-tools-version: 5.9
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "製陶大師",
    platforms: [.iOS("18.0")],
    products: [
        .iOSApplication(
            name: "製陶大師",
            targets: ["AppModule"],
            bundleIdentifier: "com.hemanlu.PotteryMaster",
            displayVersion: "1.0",
            bundleVersion: "1",
            supportedDeviceFamilies: [.pad, .phone],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))   // iPad 要支援全部四個方向（多工）
            ],
            additionalInfoPlistContentFilePath: "Info-additions.plist"
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "Sources",
            resources: [.process("Resources")]
        )
    ]
)
