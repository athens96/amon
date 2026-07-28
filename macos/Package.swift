// swift-tools-version:5.9
import PackageDescription

// amon — macOS 메뉴바(상태바) 앱.
// 메뉴바 아이콘을 클릭하면 패널 화면이 뜨는 형태의 네이티브 SwiftUI 앱이다.
// 로컬 AI 코딩 도구(Claude Code · Codex · OpenCode)의 토큰 사용량을 집계해 보여준다.
let package = Package(
    name: "AIMonitor",
    platforms: [
        // MenuBarExtra Scene 은 macOS 13(Ventura)+ 에서 지원된다.
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "AIMonitor",
            path: "Sources/AIMonitor",
            resources: [
                .process("Assets"),
                .process("PetSprites"),
            ]
        ),
        .testTarget(
            name: "AIMonitorTests",
            dependencies: ["AIMonitor"],
            path: "Tests/AIMonitorTests"
        )
    ]
)
