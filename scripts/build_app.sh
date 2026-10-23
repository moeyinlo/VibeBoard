#!/bin/bash
# 构建 VibeBoardPlus.app（TCC 需要合法 bundle 才能授予语音识别/麦克风权限）
#
# 识别与设备协议都在 Rust 内核里：这里先编静态库，再把 Swift 壳链接进去。
#   UNIVERSAL=1        同时构建 arm64 + x86_64 并 lipo（需要两个工具链都能用）
#   WHISPER_METAL=1    内核启用 Metal 后端（默认开启）
set -euo pipefail
cd "$(dirname "$0")/.."

SIGNING_IDENTITY="${VBP_SIGNING_IDENTITY:-FB9EC3E1E570D23FC9F52265385233A5A259E237}"
APP=dist/VibeBoardPlus.app
TARGET_DIR=core/target/release

WHISPER_FEATURES="${VBP_WHISPER_FEATURES:-whisper-metal}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

echo "==> building Rust core (features: ${WHISPER_FEATURES:-none})"
cd core
if [ -n "${WHISPER_FEATURES}" ]; then
    cargo build --release -p vibeboard-core --features "${WHISPER_FEATURES}"
else
    cargo build --release -p vibeboard-core
fi
cd ..

if [ "${UNIVERSAL:-0}" = "1" ]; then
    echo "==> building universal core"
    cd core
    cargo build --release -p vibeboard-core --target aarch64-apple-darwin ${WHISPER_FEATURES:+--features "$WHISPER_FEATURES"}
    cargo build --release -p vibeboard-core --target x86_64-apple-darwin ${WHISPER_FEATURES:+--features "$WHISPER_FEATURES"}
    lipo -create \
        target/aarch64-apple-darwin/release/libvibeboard_core.a \
        target/x86_64-apple-darwin/release/libvibeboard_core.a \
        -output "$TARGET_DIR/libvibeboard_core.a"
    cd ..
    swift build -c release --arch arm64 --arch x86_64
else
    swift build -c release
fi

BINARY=$(swift build -c release --show-bin-path)/VibeBoardPlus

if ! security find-identity -v -p codesigning | grep -Fq "$SIGNING_IDENTITY"; then
    echo "Signing identity unavailable. Set VBP_SIGNING_IDENTITY to a valid certificate SHA-1." >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/VibeBoardPlus"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>VibeBoardPlus</string>
    <key>CFBundleIdentifier</key><string>app.vibeboardplus.client</string>
    <key>CFBundleName</key><string>VibeBoardPlus</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>VibeBoardPlus 需要麦克风权限用于本机语音识别。</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>VibeBoardPlus 使用 macOS 语音识别将设备麦克风音频转为文字。</string>
</dict>
</plist>
PLIST
codesign -s "$SIGNING_IDENTITY" --timestamp=none --force "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
