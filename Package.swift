// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenshotToChatGPT",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ScreenshotToChatGPT", targets: ["ScreenshotToChatGPT"])],
    targets: [.executableTarget(name: "ScreenshotToChatGPT", path: "Sources/ScreenshotToChatGPT")]
)
