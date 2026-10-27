// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AirScan",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [
    .library(name: "AirScan", targets: ["AirScan"]),
    .executable(name: "airscan-scan-flatbed", targets: ["AirScanScanFlatbed"]),
    .executable(name: "airscan-diagnose", targets: ["AirScanDiagnose"]),
  ],
  targets: [
    .target(name: "AirScan"),
    .executableTarget(
      name: "AirScanScanFlatbed",
      dependencies: ["AirScan"]
    ),
    .executableTarget(
      name: "AirScanDiagnose",
      dependencies: ["AirScan"]
    ),
    .testTarget(name: "AirScanTests", dependencies: ["AirScan"]),
  ]
)
