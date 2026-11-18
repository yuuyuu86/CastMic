#!/bin/sh
# Mac 版 CastMic を Release でビルドし、Developer ID で署名して /Applications に入れる。
# 更新したいときはこれを実行するだけ:  apple/build-mac-app.sh
set -eu
cd "$(dirname "$0")"
OUT=build/mac
rm -rf "$OUT" && mkdir -p "$OUT"
xcodegen -q
cat > "$OUT/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>2PBVY8C5TF</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
xcodebuild -project CastMic.xcodeproj -scheme CastMic -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$OUT/CastMic.xcarchive" \
    -allowProvisioningUpdates -quiet archive
xcodebuild -exportArchive -archivePath "$OUT/CastMic.xcarchive" -exportPath "$OUT/export" \
    -exportOptionsPlist "$OUT/export.plist" -allowProvisioningUpdates -quiet
codesign --verify --deep --strict "$OUT/export/CastMic.app"

# 起動中なら終了してから入れ替える
osascript -e 'tell application id "com.yuuyuu86.castmic" to quit' 2>/dev/null || true
sleep 1
rm -rf /Applications/CastMic.app
ditto "$OUT/export/CastMic.app" /Applications/CastMic.app
echo "installed: /Applications/CastMic.app"
