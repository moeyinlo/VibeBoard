import Foundation
import AppKit

// VibeBoardPlus 第三方客户端入口（菜单栏 UI 后续接入；当前核心链路）：
//   USB 热插拔 → 注册/鉴权（HMAC-SHA256，逆向还原）→ ASR provider 选路（本机 Apple Speech 优先）
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

// 签名算法自检：与逆向还原的 computeSignature 保持一致
let sample = DeviceAuthClient.computeSignature(secret: "test-secret", deviceID: "test-device",
                                               timestamp: 1700000000, nonce: "nonce-1")
vlog("signature self-test: \(sample.prefix(16))… (\(sample.count) hex chars)")

// 苹果本机识别授权：仅打包成 .app 时可用（TCC 需要合法 bundle + Info.plist 声明；
// 裸 CLI 调用会 abort 进程）。CLI 模式自动走 Relay ASR。
if Bundle.main.bundleIdentifier != nil {
    if AppleSpeechProvider.isAuthorized {
        vlog("apple speech already authorized — local recognition enabled")
    } else {
        // 延迟到一切就绪后请求；需经 LaunchServices（open）启动，终端直跑会 abort
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            vlog("requesting apple speech authorization…")
            AppleSpeechProvider.requestAuthorization { granted in
                vlog("apple speech \(granted ? "authorized — local recognition enabled" : "denied — falling back to relay ASR")")
            }
        }
    }
    // 音频流自测：touch /tmp/vbp_selftest_go 触发（say 合成→Opus 编码→解码→本机识别）
    AudioSelfTest.startPolling(provider: { coordinator.appleSpeech })
} else {
    vlog("running unbundled CLI — apple speech disabled, using relay ASR")
}

app.run()
