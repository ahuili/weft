// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Weft",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Weft", targets: ["Weft"]),
    ],
    targets: [
        .target(name: "WeftCore"),
        .target(name: "WeftAI", dependencies: ["WeftCore"]),
        .executableTarget(name: "Weft", dependencies: ["WeftCore", "WeftAI"]),
        // CommandLineTools 环境没有 XCTest，用一个自测可执行文件代替
        .executableTarget(name: "WeftSelfTest", dependencies: ["WeftCore", "WeftAI"]),
    ]
)
