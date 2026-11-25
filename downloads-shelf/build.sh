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
mkdir -p "$APP/Contents/Resources"
cp -R terminal "$APP/Contents/Resources/"   # ターミナルの画面 (xterm.js)
# 動画のプレビュー欄は MovieCutter (同じ Workspace の別リポジトリ) の切り出し画面をそのまま使う。コピーせず直接ビルドに含める
MC=../../MovieCutter/Sources/MovieCutter
# コマンドラインツールの macOS 27 SDK は SwiftUI の @State がマクロになり、その部品 (SwiftUIMacros) が入っていないため
# ビルドできない (2026-11 時点)。26 の SDK に固定する。27 SDK で通るようになったら外す
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/DownloadsShelf" main.swift DownloadsShelf.swift RenameFile.swift \
    "$MC/CutterView.swift" "$MC/PlayerView.swift" "$MC/VideoTrimmer.swift"
codesign --force --sign "$SIGN_ID" "$APP"

# 起動中なら終了させてから差し替える
pkill -x DownloadsShelf 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "deployed: $DEST"
