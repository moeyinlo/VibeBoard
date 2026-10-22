# 构建带 CUDA 后端的 vibeboard_core.dll
#
# 前置：
#   * Visual Studio 2022（含 C++ 桌面工作负载）
#   * NVIDIA CUDA Toolkit（12.9 或 13.x；版本要与 MSVC 匹配，否则 CMake 会报
#     "No CUDA toolset found"）
#   * Rust（stable）与 CMake
#
# 用法：
#   pwsh scripts/build-core-cuda.ps1
#   pwsh scripts/build-core-cuda.ps1 -Architectures "75;86;89;90"
#
# 产物：core\target\release\vibeboard_core.dll
# 把它复制到 VibeBoardPlus.exe 同目录，设置页应显示 backend = CUDA。
param(
    [string]$Architectures = "75;86;89;90"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Push-Location (Join-Path $root "core")
try {
    if (-not (Get-Command nvcc -ErrorAction SilentlyContinue)) {
        throw "未找到 nvcc：请安装 CUDA Toolkit 并把 <CUDA>\bin 加入 PATH"
    }
    nvcc --version

    $env:CMAKE_CUDA_ARCHITECTURES = $Architectures
    cargo build --release -p vibeboard-core --features whisper-cuda
    if ($LASTEXITCODE -ne 0) { throw "cargo build 失败" }

    $dll = Join-Path (Get-Location) "target\release\vibeboard_core.dll"
    if (-not (Test-Path $dll)) { throw "未生成 $dll" }
    Get-Item $dll | Format-List Name, Length
    Write-Host ""
    Write-Host "完成：$dll"
    Write-Host "提示：目标机器还需要 NVIDIA 驱动与 CUDA 运行时（cudart64_*.dll、cublas64_*.dll、cublasLt64_*.dll）。"
}
finally {
    Pop-Location
}
