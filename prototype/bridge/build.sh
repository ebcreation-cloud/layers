#!/bin/bash
# Builds CalendarBridge.app. It must be an app bundle: a bare CLI binary has its
# permission requests attributed to the parent process, which fails silently.
set -e
cd "$(dirname "$0")"
APP="CalendarBridge.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>CalendarBridge</string>
  <key>CFBundleDisplayName</key><string>Calendar Bridge</string>
  <key>CFBundleIdentifier</key><string>com.eunbi.calendarbridge</string>
  <key>CFBundleExecutable</key><string>CalendarBridge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>Reads events so the calendar app and the weekly draft can use them.</string>
  <key>NSRemindersFullAccessUsageDescription</key>
  <string>Reads captured notes so they land on the day they were written.</string>
  <key>NSPhotoLibraryUsageDescription</key>
  <string>Exports photos from a chosen date range into a blog draft.</string>
</dict></plist>
PL
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/CalendarBridge" src/main.swift
codesign --force --sign - --identifier com.eunbi.calendarbridge "$APP"
echo "built: $(pwd)/$APP"
