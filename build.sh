#!/bin/zsh
# Builds "WhatsApp PiP.app" and installs it to ~/Applications.
set -e
cd "${0:A:h}"
APP="build/WhatsApp PiP.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macos15.2 main.swift -o "$APP/Contents/MacOS/WhatsAppPiP"

# App icon: icon/icon.png (redraw with `swift icon/make_icon.swift icon/icon.png`) -> AppIcon.icns
ICONSET=build/AppIcon.iconset
mkdir -p $ICONSET
for s in 16 32 128 256 512; do
  sips -z $s $s icon/icon.png --out $ICONSET/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) icon/icon.png --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $ICONSET -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>WhatsApp PiP</string>
  <key>CFBundleIdentifier</key><string>local.whatsapp-pip</string>
  <key>CFBundleExecutable</key><string>WhatsAppPiP</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>15.2</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign - "$APP"
mkdir -p ~/Applications
rm -rf ~/Applications/"WhatsApp PiP.app"
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/WhatsApp PiP.app"
