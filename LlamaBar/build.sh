#!/bin/bash
set -e
cd "$(dirname "$0")"
APP="$PWD/LlamaBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/LlamaBar" main.swift ModelLogic.swift
cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>LlamaBar</string>
    <key>CFBundleIdentifier</key><string>com.rajatarya.llamabar</string>
    <key>CFBundleName</key><string>LlamaBar</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --sign - --force "$APP" 2>/dev/null
echo "✅ Built & signed: $APP"
echo "   Run: open $APP"
