// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "Benchmark",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.15.0"),
    .package(url: "https://github.com/FluidInference/FluidAudio.git", branch: "main"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.0"),
  ],
  targets: [
    .executableTarget(
      name: "benchmark",
      dependencies: [
        .product(name: "WhisperKit", package: "WhisperKit"),
        .product(name: "FluidAudio", package: "FluidAudio"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      path: "Sources"
    ),
  ]
)
