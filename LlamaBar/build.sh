#!/bin/bash
# Build LlamaBar.app. Compiles into a staging bundle and swaps it in only on
# success, so a broken build never deletes the working app.
#   ./build.sh             build
#   ./build.sh --relaunch  build, quit the running LlamaBar, open the new one
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/LlamaBar.app"
STAGE="$PWD/.LlamaBar.app.build"
rm -rf "$STAGE"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Contents/MacOS"
swiftc -O -o "$STAGE/Contents/MacOS/LlamaBar" main.swift ModelLogic.swift Shell.swift
cat > "$STAGE/Contents/Info.plist" << 'EOF'
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
codesign --sign - --force "$STAGE" 2>/dev/null
rm -rf "$APP"
mv "$STAGE" "$APP"
echo "✅ Built & signed: $APP"

if [[ "${1:-}" == "--relaunch" ]]; then
  pkill -x LlamaBar 2>/dev/null && sleep 1 || true
  open "$APP"
  echo "🔄 Relaunched LlamaBar"
else
  echo "   Run: open $APP   (or ./build.sh --relaunch)"
fi
