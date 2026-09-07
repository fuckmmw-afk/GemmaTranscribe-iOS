// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "LiteRTLM",
  platforms: [
    .iOS(.v15),
    .macOS(.v12)
  ],
  products: [
    .library(
      name: "LiteRTLM",
      targets: ["LiteRTLM"]
    )
  ],
  targets: [
    .binaryTarget(
      name: "CLiteRTLM",
      url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.16.0/CLiteRTLM.xcframework.zip",
      checksum: "4e0f683da07566ee79c143d2d58d387f77052b0e6a41562c969e5d2728fc9f4b"
    ),
    .target(
      name: "LiteRTLM",
      dependencies: ["CLiteRTLM"],
      path: "Sources"
    )
  ]
)
