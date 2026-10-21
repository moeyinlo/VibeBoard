#!/bin/bash
# 打包 VibeBoardPlus.app（CI / 无证书环境）。
# 与 build_app.sh 的区别：没有可用签名证书时改用 ad-hoc 签名，便于下载后直接试跑。
#   WHISPER_FEATURES=whisper-metal   （默认）
#   VBP_SIGNING_IDENTITY=<sha1>      （可选，有证书时用它）
set -euo pipefail
cd "$(dirname "$0")/.."

APP=dist/VibeBoardPlus.app
TARGET_DIR=core/target/release
WHISPER_FEATURES="${WHISPER_FEATURES:-whisper-metal}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

echo "==> building Rust core (features: ${WHISPER_FEATURES:-none})"
cd core
if [ -n "${WHISPER_FEATURES}" ]; then
    cargo build --release -p vibeboard-core --features "${WHISPER_FEATURES}"
else
    cargo build --release -p vibeboard-core
fi
cd ..

echo "==> building Swift shell"
swift build -c release
BINARY="$(swift build -c release --show-bin-path)/VibeBoardPlus"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/VibeBoardPlus"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>VibeBoardPlus</string>
    <key>CFBundleIdentifier</key><string>app.vibeboardplus.client</string>
    <key>CFBundleName</key><string>VibeBoardPlus</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>VibeBoardPlus 需要麦克风权限用于本机语音识别。</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>VibeBoardPlus 使用 macOS 语音识别将设备麦克风音频转为文字。</string>
</dict>
</plist>
PLIST

if [ -n "${VBP_SIGNING_IDENTITY:-}" ] && security find-identity -v -p codesigning | grep -Fq "$VBP_SIGNING_IDENTITY"; then
    echo "==> signing with $VBP_SIGNING_IDENTITY"
    codesign -s "$VBP_SIGNING_IDENTITY" --timestamp=none --force "$APP"
else
    echo "==> ad-hoc signing (no developer certificate available)"
    codesign -s - --force --deep "$APP"
fi
codesign --verify --deep --strict "$APP"

rm -f dist/VibeBoardPlus-macos.zip
ditto -c -k --keepParent "$APP" dist/VibeBoardPlus-macos.zip
echo "Built $APP and dist/VibeBoardPlus-macos.zip"
