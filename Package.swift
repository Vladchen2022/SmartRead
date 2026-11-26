// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SmartRead",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(
            name: "VLCKit",
            path: ".build/dependencies/vlckit-3.7.3/VLCKit.xcframework"
        ),
        .executableTarget(
            name: "SmartRead",
            dependencies: ["VLCKit"],
            resources: [
                .copy("Resources/Readability.js"),
                .copy("Resources/Readability-LICENSE.md"),
                .copy("Resources/Readability-APACHE-2.0.txt"),
                .copy("Resources/ExtractArticle.js"),
                .copy("Resources/KokoroWorker.py"),
                .copy("Resources/SmartRead.icns")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path",
                              "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(name: "SmartReadTests", dependencies: ["SmartRead", "VLCKit"],
                    resources: [.copy("Fixtures/VideoPlayback")],
                    linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."])])
    ]
)
