#!/bin/sh
# Builds ~/Applications/Claude Panel.app (no Dock icon, floats over everything).
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/Claude Panel.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O Panel.swift -o "$APP/Contents/MacOS/ClaudePanel"

# the icon is drawn in code, so there is no image file to keep around
swiftc -O icon.swift -o "$TMP/icon"
"$TMP/icon" "$TMP/AppIcon.iconset"
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# a complete Info.plist is what makes Spotlight and Launchpad treat this as a normal app
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ClaudePanel</string>
<key>CFBundleIdentifier</key><string>local.claude-panel</string>
<key>CFBundleName</key><string>Claude Panel</string>
<key>CFBundleDisplayName</key><string>Claude Panel</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSUIElement</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Claude Panel opens your Claude sessions in Terminal and manages its start-at-login setting.</string>
</dict></plist>
EOF

codesign --force --deep --sign - "$APP"
# tell macOS about the new bundle so Spotlight and the Dock pick it up
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true
mdimport "$APP" 2>/dev/null || true
echo "built: $APP"
