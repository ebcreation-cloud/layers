#!/bin/bash
# 아이폰 시뮬레이터용 빌드. Xcode 프로젝트 없이 swiftc 로 바로 굽는다.
# 실기기에 넣으려면 프로비저닝 프로파일이 필요해서 Xcode GUI 를 한 번 거쳐야 한다.
set -e
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
APP="build/ios/Layers.app"
rm -rf "$APP"; mkdir -p "$APP"

cat > "$APP/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Layers</string>
  <key>CFBundleDisplayName</key><string>Layers</string>
  <key>CFBundleIdentifier</key><string>com.eunbi.layers</string>
  <key>CFBundleExecutable</key><string>Layers</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>MinimumOSVersion</key><string>18.0</string>
  <key>UIDeviceFamily</key><array><integer>1</integer></array>
  <key>UILaunchScreen</key><dict/>
  <key>UISupportedInterfaceOrientations</key>
  <array><string>UIInterfaceOrientationPortrait</string></array>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
  <key>DTPlatformName</key><string>iphonesimulator</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>Layers shows your Google and Outlook calendars together.</string>
  <key>NSRemindersFullAccessUsageDescription</key>
  <string>Layers places the notes you capture on the day you captured them.</string>
</dict></plist>
PL

xcrun --sdk iphonesimulator swiftc \
  -target arm64-apple-ios18.0-simulator -sdk "$SDK" \
  -O -swift-version 5 -parse-as-library \
  -o "$APP/Layers" \
  Sources/LayersApp.swift Sources/Model/*.swift Sources/Views/*.swift
codesign --force --sign - "$APP"
echo "빌드 완료: $(pwd)/$APP"
