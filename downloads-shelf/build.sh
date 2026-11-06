#!/bin/sh
# DownloadsShelf.app をビルドして ~/Applications へ配布する。Xcode 不要 (コマンドラインツールの swiftc のみ)。
# 署名は make-cert.sh で作る自己署名証明書。毎回同じ証明書で署名するので、ダウンロードフォルダへの
# アクセス許可は初回だけで済む (アドホック署名だと再ビルドのたびに聞かれる)。
set -eu
cd "$(dirname "$0")"

APP=build/DownloadsShelf.app
DEST="$HOME/Applications/DownloadsShelf.app"
SIGN_ID="DownloadsShelf Local Signing"

if ! security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
    echo "署名用の証明書がありません。先に ./make-cert.sh を実行してください" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/DownloadsShelf" DownloadsShelf.swift
codesign --force --sign "$SIGN_ID" "$APP"

# 起動中なら終了させてから差し替える
pkill -x DownloadsShelf 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "deployed: $DEST"
