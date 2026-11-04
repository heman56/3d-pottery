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
            supportedInterfaceOrientations: [.portrait, .landscapeLeft, .landscapeRight],
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
