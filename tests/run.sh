#!/bin/sh
# コミット前に回す検査。全部通れば exit 0。
# ファズの回数・乱数の種を変えるとき: FUZZ_N=100000 FUZZ_SEED=7 tests/run.sh
set -e
cd "$(dirname "$0")/.."

python3 -I tests/test_karabiner.py

# DownloadsShelf の名前変更のファズ (一時フォルダの中だけで試す。ビルドも一時フォルダ)
BIN=$(mktemp -d)
trap 'rm -rf "$BIN"' EXIT
swiftc -O -parse-as-library -o "$BIN/rename_fuzz" downloads-shelf/RenameFile.swift tests/rename_fuzz.swift
"$BIN/rename_fuzz"

# 配り忘れの確認 (検査はリポジトリ側に対して行うため、配布先が古いと実機と食い違う)
if ! cmp -s karabiner/karabiner.json "$HOME/.config/karabiner/karabiner.json"; then
    echo "注意: karabiner/karabiner.json が配布先 (~/.config/karabiner/) と違う" >&2
fi
