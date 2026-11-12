// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StayAwake",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "StayAwake", targets: ["StayAwake"]),
        .executable(name: "StayAwakeHelper", targets: ["StayAwakeHelper"])
    ],
    dependencies: [
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", from: "8.40.0")
    ],
    targets: [
        // Everything with a decision in it. No UI and no system calls, so it
        // can be tested and driven from the command line
        // (`StayAwake --simulate scenario.json`).
        .target(
            name: "StayAwakeCore",
            path: "Sources/StayAwakeCore"
        ),
        .executableTarget(
            name: "StayAwake",
            dependencies: [
                "StayAwakeCore",
                .product(name: "Sentry", package: "sentry-cocoa")
            ],
            path: "Sources/StayAwake",
            // Info.plist is placed by build.sh, not by SwiftPM.
            exclude: ["Resources/Info.plist", "Resources/weteling-logo.svg"]
        ),
        // Root launchd daemon. A stub until M5.
        .executableTarget(
            name: "StayAwakeHelper",
            dependencies: ["StayAwakeCore"],
            path: "Sources/StayAwakeHelper",
            // The launchd plist is copied into the app bundle by build.sh.
            exclude: ["Resources/com.weteling.stayawake.helper.plist"]
        ),
        .testTarget(
            name: "StayAwakeCoreTests",
            dependencies: ["StayAwakeCore"],
            path: "Tests/StayAwakeCoreTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
