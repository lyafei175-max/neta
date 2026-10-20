// swift-tools-version: 5.9
import PackageDescription

// 说明：这是一个 Swift Package 形式的源码包，便于在 macOS 上快速编译验证核心逻辑。
// 若要打包成 IPA，请在 Xcode 中新建 iOS App 目标并加入 NetaL/ 目录下的源码，
// 或直接运行 `xcodebuild` 用 project.yml 生成工程（见 README）。

let package = Package(
    name: "NetaL",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "NetaL", targets: ["NetaL"])
    ],
    targets: [
        .target(
            name: "NetaL",
            path: "NetaL",
            exclude: [
                "App/NetaLApp.swift",      // 仅作 iOS App 入口，不参与库编译
                "UI/ContentView.swift",     // SwiftUI 视图，同上
                "UI/BleCaptureView.swift"   // 同上
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        )
    ]
)