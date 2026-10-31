#!/bin/bash
# 多开助手构建脚本
# 用法: ./build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="多开助手"
BUNDLE_ID="com.qizhibang.multiopener"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)"
OUT="build"
APP="$OUT/$APP_NAME.app"

echo "==> 编译 $APP_NAME v$VERSION ..."
mkdir -p "$OUT"
xcrun swiftc -swift-version 5 -O main.swift -o "$OUT/MultiOpener"

echo "==> 打包 $APP ..."
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/MultiOpener" "$APP/Contents/MacOS/MultiOpener"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 签名（ad-hoc）..."
codesign --force -s - "$APP"
codesign -v "$APP"

echo "==> 完成: $APP"

if [ "${1:-}" = "--install" ]; then
    echo "==> 安装到 /Applications ..."
    osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || pkill -9 -f "$APP_NAME.app/Contents/MacOS" 2>/dev/null || true
    sleep 1
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    rm -rf "$OUT"          # 清理构建目录，避免被 Launchpad 重复索引
    open "/Applications/$APP_NAME.app"
    echo "==> 已安装并启动"
else
    echo "    （加 --install 参数可直接安装到 /Applications）"
fi
