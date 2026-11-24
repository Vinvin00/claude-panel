#!/bin/sh
# Builds ~/Applications/Claude Panel.app (no Dock icon, floats over everything).
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/Claude Panel.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O Panel.swift -o "$APP/Contents/MacOS/ClaudePanel"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ClaudePanel</string>
<key>CFBundleIdentifier</key><string>local.claude-panel</string>
<key>CFBundleName</key><string>Claude Panel</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
echo "built: $APP"
