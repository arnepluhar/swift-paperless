// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AirScan",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [.library(name: "AirScan", targets: ["AirScan"])],
  targets: [
    .target(name: "AirScan"),
    .testTarget(name: "AirScanTests", dependencies: ["AirScan"]),
  ]
)
