#!/bin/sh
# 构建 release 版并打包成 DJIMicTray.app（ad-hoc 签名，仅供本机使用）。
set -eu
cd "$(dirname "$0")"
swift build -c release
APP=build/DJIMicTray.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/DJIMicTray" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp LICENSE-dji-mic-mo.md "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "$APP"
