#!/bin/zsh
# Build BlazieStream.app, sign it with the stable Apple Development identity (so macOS keeps its
# Screen Recording and Accessibility grants across rebuilds) and (re)start its LaunchAgent.
set -euo pipefail
cd "${0:A:h}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
APP=$PWD/build/BlazieStream.app
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.blazie.stream</string>
  <key>CFBundleName</key><string>Blazie Stream</string>
  <key>CFBundleDisplayName</key><string>Blazie Stream</string>
  <key>CFBundleExecutable</key><string>BlazieStream</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
lane build -- xcrun swiftc -O -swift-version 5 -import-objc-header BlazieStream/VirtualDisplay.h BlazieStream/main.swift -o "$APP/Contents/MacOS/BlazieStream"
codesign --force --sign "Apple Development: Created via API (265V39N664)" --identifier dev.blazie.stream "$APP"
PL=~/Library/LaunchAgents/dev.blazie.stream.plist
cat > $PL <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.blazie.stream</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/BlazieStream</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/.blazie/stream.log</string>
  <key>StandardErrorPath</key><string>$HOME/.blazie/stream.log</string>
</dict></plist>
PLIST
launchctl bootout gui/$(id -u)/dev.blazie.stream 2>/dev/null || true
launchctl bootstrap gui/$(id -u) $PL
echo "BlazieStream built and running"
