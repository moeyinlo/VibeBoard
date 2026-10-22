import Foundation
import AppKit

// VibeBoardPlus 第三方客户端入口（菜单栏 UI）：
//   设备协议 / 鉴权 / ASR 编排全部在 Rust 内核（core/crates/vibeboard-core）里，
//   这里只做菜单栏、悬浮窗、文本注入和设置界面。
VLog.reset()
let coordinator = VibeBoardCoordinator()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let menuBar = MenuBarController()
menuBar.buttonSettings = coordinator.buttonSettings
coordinator.onButtonAction = { menuBar.performButtonAction($0) }
coordinator.onRecognitionCancelled = { menuBar.cancelRecognition() }
coordinator.onStatus = { menuBar.updateStatus($0) }
coordinator.onFinalText = { menuBar.receive($0) }
coordinator.onPartialText = { menuBar.receivePartial($0) }
coordinator.onSessionStart = { menuBar.beginRecognition() }
coordinator.start()
vlog("keyboard post access=\(CGPreflightPostEventAccess()) accessibility=\(AXIsProcessTrusted())")
vlog("started — waiting for VibeBoard device…")

// 设置窗口保存后立即把新配置推给内核（识别服务/模型/按键映射）。
NotificationCenter.default.addObserver(
    forName: .vibeboardConfigurationChanged, object: nil, queue: .main
) { _ in
    coordinator.refreshConfiguration()
}

// 苹果本机识别授权：弹窗需要合法的 bundle；未授权时内核仍可用 StepFun / Whisper。
if Bundle.main.bundleIdentifier != nil {
    if AppleSpeechProvider.isAuthorized {
        vlog("apple speech already authorized — local recognition enabled")
    } else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            vlog("requesting apple speech authorization…")
            AppleSpeechProvider.requestAuthorization { granted in
                vlog("apple speech \(granted ? "authorized — local recognition enabled" : "denied — falling back")")
            }
        }
    }
} else {
    vlog("running unbundled CLI — apple speech disabled")
}

// 调试/截图用：VBP_SHOW_MAIN_WINDOW=1 启动时直接打开主窗口。
if ProcessInfo.processInfo.environment["VBP_SHOW_MAIN_WINDOW"] == "1" {
    menuBar.openMainWindowForDebugging()
}

app.run()
