# vibeboard-core

平台无关的 VibeBoard 客户端内核：USB 串口协议、设备鉴权、音频解码、ASR 与会话编排。
macOS（Swift/AppKit）和 Windows（C#/WPF）只做各自的界面壳，共用这一份实现。

```
core/
  crates/vibeboard-core/    # 库：protocol / discovery / link / auth / opus（后续 asr / session / ffi）
  crates/vibeboard-cli/     # 无界面 CLI，真机与 CI 联调用
```

## 为什么这样拆

两端的**界面与系统能力**无法共享，必须各写一份：

| 能力 | macOS | Windows |
|---|---|---|
| 托盘 | `NSStatusItem` | `NotifyIcon` |
| 悬浮窗 | `NSPanel`（不抢焦点） | `WS_EX_NOACTIVATE` + WPF |
| 文本注入 | Accessibility AX API | `SendInput` + UIA |
| 凭据 | Keychain | DPAPI |
| 本机识别 | `SFSpeechRecognizer` | `System.Speech` / Whisper |

其余全部留在内核：分帧、握手、心跳、重连、注册/token、Opus 解码、ASR、会话状态机、
超时策略、语义整理。协议细节见 `../../docs/PROTOCOL.md`。

## 当前状态（P0 完成）

- [x] 分帧/组帧与重同步（14 个单元测试）
- [x] 设备发现（`serialport` 统一 IOKit / SetupAPI，按 `303A:1001` + MAC 序列号筛选）
- [x] 串口链路：`transport` → `transport_ready` → 心跳 → `get_device_info` 轮询、握手超时、复位重放
- [x] 设备注册 / token 交换（HMAC-SHA256，签名与 macOS 端自检值逐字节一致）
- [x] Opus → 16 kHz 单声道 PCM 解码
- [x] CLI 联调工具与离线回放
- [x] StepFun 流式（WebSocket）/ 非流式（multipart）识别
- [x] 语义整理（StepFun chat completions，含结果校验）
- [x] 按键状态机、会话编排、超时与取消、外部识别通道（P1）
- [x] App 层：发现循环、注册、断线后重连、外部凭据注入（P1）
- [ ] 本地 Whisper 接入
- [ ] C ABI（P2）
- [ ] macOS / Windows 壳接线（P3 / P4）

## CLI

```sh
cd core

# 完整链路：发现 → 握手 → 注册 → 按键录音 → StepFun 识别 → 打印文本
STEPFUN_API_KEY=sk-... cargo run -p vibeboard-cli

# 只验证串口协议与音频统计（不联网）
cargo run -p vibeboard-cli -- --probe --no-auth

# 用壳侧识别（Apple Speech / System.Speech）并录一段 WAV
cargo run -p vibeboard-cli -- --provider external --record /tmp/vibeboard.wav

# 开启语义整理
cargo run -p vibeboard-cli -- --asr-key sk-... --rewrite --rewrite-key sk-...

# 离线解析抓包（CI 用，不连硬件）
cargo run -p vibeboard-cli -- --replay frames.bin

cargo run -p vibeboard-cli -- --help
```

## 测试

```sh
cargo test --all
cargo clippy --all-targets -- -D warnings
cargo fmt --all -- --check
```

串口链路的测试通过注入一个假的 `LinkIo`（脚本化上行字节 + 记录下行帧）完成，
不需要硬件：握手顺序、`device_info` 后的 `ui_state ready`、音频/按键事件分发、
复位横幅触发重放握手、`ui_state`/`provision` 出队都覆盖到了。

## 构建产物

GitHub Actions 在三个平台跑 `fmt + clippy + test`，并在
`macos-14` 产出 `libvibeboard_core.a`、`windows-latest` 产出 `vibeboard_core.dll`。

## 设计约束

- 内核不依赖任何 UI 框架，也不做线程调度决策：回调在链路/网络工作线程上触发，
  壳负责切回主线程并拷贝字符串。
- 内核不做凭据持久化：密钥由壳从 Keychain / DPAPI 取出后注入（`Credentials` 接口）。
- 会话状态机是单线程的：设备事件、识别结果与定时器走同一个队列，避免并发竞态。
- 串口发现要 MAC 形态的序列号：注册用的 `mac` 就是它，换平台必须保持一致。
