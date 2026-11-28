// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SmartReadSync",
    platforms: [.macOS(.v14), .iOS("18.0")],
    products: [.library(name: "SmartReadSync", targets: ["SmartReadSync"])],
    targets: [.target(name: "SmartReadSync")]
)
