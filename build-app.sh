#!/bin/bash
# 构建 macOS App：dist/无边记.app
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/无边记.app"
BUILD="build"
TARGET="$(uname -m)-apple-macos12.0"

rm -rf "$APP" "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web" "$BUILD"

echo "→ 编译"
swiftc -O -target "$TARGET" -framework Cocoa -framework WebKit app/main.swift -o "$APP/Contents/MacOS/Wubianji"

echo "→ 生成图标"
swiftc -O -target "$TARGET" -framework Cocoa app/icon.swift -o "$BUILD/mkicon"
"$BUILD/mkicon" "$BUILD/AppIcon.iconset"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cp index.html "$APP/Contents/Resources/web/index.html"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>无边记</string>
  <key>CFBundleDisplayName</key><string>无边记</string>
  <key>CFBundleIdentifier</key><string>local.wubianji.canvas</string>
  <key>CFBundleExecutable</key><string>Wubianji</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>本地思维导图与无限画布</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoadsInWebContent</key><true/>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>无边记画板</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>local.wubianji.board</string></array>
      <key>CFBundleTypeIconFile</key><string>AppIcon</string>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>local.wubianji.board</string>
      <key>UTTypeDescription</key><string>无边记画板</string>
      <key>UTTypeConformsTo</key><array><string>public.json</string></array>
      <key>UTTypeIconFile</key><string>AppIcon</string>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>wbj</string></array></dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
rm -rf "$BUILD"
echo "✓ 完成：$APP"
