#!/bin/bash
# Xcode 없이 맥 앱을 빌드한다. 커맨드라인 툴에 macOS SDK 가 들어 있어 SwiftUI 가 컴파일된다.
# 아이폰은 Xcode 가 있어야 한다 (iOS SDK, 시뮬레이터, 기기 서명).
#
# EventKit 권한은 반드시 .app 번들이어야 뜬다. 커맨드라인 바이너리로 직접 돌리면
# macOS 가 요청을 부모 앱(터미널)에 귀속시켜 다이얼로그도 없이 거부된다.
set -e
cd "$(dirname "$0")"
APP="Layers.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<'PL'
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
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>Layers</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>구글과 아웃룩 일정을 읽고 고치기 위해 캘린더에 접근한다.</string>
  <key>NSRemindersFullAccessUsageDescription</key>
  <string>핀보드에 캡처한 메모를 날짜에 맞춰 보여주기 위해 미리 알림을 읽는다.</string>
</dict></plist>
PL
cp Icon/Layers.icns "$APP/Contents/Resources/Layers.icns"
swiftc -O -swift-version 5 -parse-as-library \
  -o "$APP/Contents/MacOS/Layers" \
  Sources/LayersApp.swift Sources/Model/*.swift Sources/Views/*.swift
# 고정된 자체서명 인증서로 서명한다. ad-hoc 은 지정 요구사항이 cdhash 라
# 빌드마다 바뀌고, 그러면 TCC 가 매번 새 앱으로 보고 권한을 다시 묻는다.
# 인증서로 서명하면 지정 요구사항이 identifier + certificate root 라 고정된다.
# 개인키는 로그인 키체인에 있다. 신뢰 설정은 필요 없다 (TCC 는 신뢰가 아니라 DR 로 본다).
IDENTITY=$(security find-certificate -c "Layers Dev" -Z ~/Library/Keychains/login.keychain-db 2>/dev/null \
  | awk '/SHA-1/{print $3; exit}')
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" --identifier com.eunbi.layers "$APP"
else
  echo "경고: Layers Dev 인증서가 없어 ad-hoc 으로 서명한다. 빌드마다 권한을 다시 묻는다."
  codesign --force --sign - --identifier com.eunbi.layers "$APP"
fi
codesign -d -r- "$APP" 2>&1 | grep designated
echo "빌드 완료: $(pwd)/$APP"
