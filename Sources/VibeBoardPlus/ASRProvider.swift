import Foundation

/// ASR 提供商抽象：本地（Apple Speech）与远程（Relay/字节/小智等 WebSocket）统一接口。
/// 选路策略：默认本机 Apple Speech（延迟最低、无网络依赖），不可用或用户配置时走远程。
protocol ASRProvider {
    var name: String { get }
    var latencyClass: LatencyClass { get }
    func startSession()
    func sendAudio(_ data: Data)
    func finishSession()
    func stop()
}

enum LatencyClass: Int, Comparable {
    case local = 0      // 本机识别，<100ms 级
    case remote = 1     // 网络识别，数百 ms 级

    static func < (a: LatencyClass, b: LatencyClass) -> Bool { a.rawValue < b.rawValue }
}

/// 所有 provider 共用的文本回调
final class ASRPipeline {
    var onText: ((String, Bool) -> Void)?   // (text, isFinal)
    private(set) var providers: [ASRProvider] = []

    func register(_ provider: ASRProvider) { providers.append(provider) }

    /// 按延迟等级排序；local 优先，远程作为回退
    func orderedProviders() -> [ASRProvider] {
        providers.sorted { ($0.latencyClass.rawValue, $0.name) < ($1.latencyClass.rawValue, $1.name) }
    }

    func broadcastText(_ text: String, isFinal: Bool) {
        onText?(text, isFinal)
    }
}
