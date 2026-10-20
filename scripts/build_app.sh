#!/bin/bash
# 构建 VibeBoardPlus.app（TCC 需要合法 bundle 才能授予语音识别/麦克风权限）
set -euo pipefail
cd "$(dirname "$0")/.."
# Keep the signing identity stable so TCC permissions survive local updates.
SIGNING_IDENTITY="${VBP_SIGNING_IDENTITY:-FB9EC3E1E570D23FC9F52265385233A5A259E237}"
if ! security find-identity -v -p codesigning | grep -Fq "$SIGNING_IDENTITY"; then
    echo "Signing identity unavailable. Set VBP_SIGNING_IDENTITY to a valid certificate SHA-1." >&2
    exit 1
fi
swift build -c release 2>&1 | tail -1
APP=dist/VibeBoardPlus.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/VibeBoardPlus "$APP/Contents/MacOS/VibeBoardPlus"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>VibeBoardPlus</string>
    <key>CFBundleIdentifier</key><string>app.vibeboardplus.client</string>
    <key>CFBundleName</key><string>VibeBoardPlus</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
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
