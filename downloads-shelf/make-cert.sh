#!/bin/sh
# build.sh が使うコード署名用の自己署名証明書をログインキーチェーンに作る (マシンごとに一度だけ)。
# アドホック署名だと再ビルドのたびに署名が変わり、ダウンロードフォルダへのアクセス許可を毎回聞かれる。
# 同じ証明書で署名し続ければ macOS からは同じアプリに見えるので、許可は初回だけで済む。
set -eu

NAME="DownloadsShelf Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "already exists: $NAME"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
# macOS の security が読める形式 (-legacy) で書き出す。パスワードは取り込みにだけ使う使い捨て
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/cert.p12" -passout pass:tmp 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/cert.p12" -passout pass:tmp
security import "$TMP/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P tmp -T /usr/bin/codesign
echo "created: $NAME"
