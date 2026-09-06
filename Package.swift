// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "T7suite", platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "T7Core", targets: ["T7Core"]), .executable(name: "t7inspect", targets: ["T7Inspect"])],
    targets: [.target(name: "T7Core"), .executableTarget(name: "T7Inspect", dependencies: ["T7Core"]), .testTarget(name: "T7CoreTests", dependencies: ["T7Core"])])
