# VibeBoard Plus · Windows 客户端

WPF 托盘应用，识别与设备协议全部由 `core/`（Rust 内核）通过 P/Invoke 提供。

## 构建

需要 .NET 8 SDK 与 Rust 工具链。

```powershell
# 1) 内核 DLL
cd core
cargo build --release -p vibeboard-core

# 2) 应用（自包含，用户无需安装 .NET）
cd ..\Windows
dotnet publish -c Release -r win-x64 --self-contained -o ..\dist\windows
```

`vibeboard_core.dll` 会由 csproj 自动复制到输出目录；发布目录里必须有它。

也可在 macOS/Linux 上交叉编译（只验证编译，不能运行）：

```sh
dotnet build -p:EnableWindowsTargeting=true
dotnet publish -c Release -r win-x64 --self-contained -p:EnableWindowsTargeting=true -o dist/windows
```

CI（`.github/workflows/windows.yml`）在 `windows-latest` 上构建内核 DLL + 应用，产出
`VibeBoardPlus-windows-x64.zip`。

## 功能

- 托盘菜单：状态、显示/复制最近结果、取消识别、设置、打开日志、退出
- 悬浮窗：置顶、不抢焦点（`WS_EX_NOACTIVATE`）、8 秒后自动隐藏、可复制
- 文本输出三种模式：
  - **实时输入**：`SendInput` 逐字写入当前输入框，修订时用退格替换本次内容
  - **完成后粘贴**：剪贴板 + `Ctrl+V`，可选自动复制、结束���恢复原剪贴板
  - **仅悬浮窗**
- 按键映射（K1–K4）：按住说话 / 切换录音 / 复制 / 显示 / 取消 / 粘贴 / 撤销 / 回车 / Escape
- 识别服务：本地 Whisper（默认，`large-v3-turbo-q5_0`）、StepFun 云端、Windows 自带语音识别
- 可选模型：tiny / base / small / small-q5_1 / medium / medium-q5_0 /
  large-v3-turbo / large-v3-turbo-q5_0（547 MB，推荐）/ large-v3-turbo-q8_0
- 本地模型应用内下载（默认 `hf-mirror.com` → `huggingface.co`），断点续传 + 自动重试，
  显示进度与已安装状态；程序不内置模型，首次使用需在设置里下载
- 设置页展示加速后端（CPU / CUDA / Vulkan）、已编译后端、RTF、耗时、线程数与峰值内存
- 语义整理：StepFun chat completions，默认复用识别 Key；额度/密钥错误会显示中文提示
- 凭据：DPAPI（当前用户）加密后存于 `%APPDATA%\VibeBoardPlus\settings.json`
- 日志：`%LOCALAPPDATA%\VibeBoardPlus\vibeboardplus.log`

## 加速后端

whisper.cpp 的后端是编译期选择：

```powershell
# NVIDIA GPU（需要 CUDA Toolkit；CI 产物见下）
cargo build --release -p vibeboard-core --features whisper-cuda
# 跨厂商 GPU
cargo build --release -p vibeboard-core --features whisper-vulkan
```

默认只编 CPU。构建后可在「设置 → 语音识别」看到当前后端与 `whisper.cpp` 的设备报告。

### CUDA 版

`.github/workflows/windows-cuda.yml` 在 `windows-latest` 上安装 CUDA Toolkit 并编译
`--features whisper-cuda`，产出 `vibeboard_core-cuda-windows-x64` 工件（手动触发或打 tag）。
用它替换 `VibeBoardPlus-windows-x64.zip` 里的同名 DLL 即可；目标机器需要 NVIDIA 驱动与
CUDA 运行时（`cudart64_12.dll`、`cublas64_12.dll`、`cublasLt64_12.dll`）。
没有可用 GPU 时 whisper.cpp 会自动回落到 CPU。

## 已知限制

- 需要 Windows 10/11；Windows 自带识别依赖中文语音语言包，缺失时会在日志与状态栏提示
- 由管理员权限运行的窗口不会被注入（Windows 的 UIPI 限制）
- 未做代码签名，首次运行可能出现 SmartScreen 提示
