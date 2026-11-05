#!/bin/sh
# DownloadsShelf.app をビルドして ~/Applications へ配布する。Xcode 不要 (コマンドラインツールの swiftc のみ)。
# 署名はアドホック。再ビルドで署名が変わるため、ダウンロードフォルダへのアクセス許可を再度聞かれることがある。
set -eu
cd "$(dirname "$0")"

APP=build/DownloadsShelf.app
DEST="$HOME/Applications/DownloadsShelf.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/DownloadsShelf" DownloadsShelf.swift
codesign --force --sign - "$APP"

# 起動中なら終了させてから差し替える
pkill -x DownloadsShelf 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "deployed: $DEST"
