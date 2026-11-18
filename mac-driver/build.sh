#!/bin/sh
# CastMicHAL.driver をビルドする (universal)。出力: build/CastMicHAL.driver
set -eu
cd "$(dirname "$0")"
OUT=build/CastMicHAL.driver/Contents
rm -rf build && mkdir -p "$OUT/MacOS"
clang -bundle -O2 -Wall -Wextra -Werror -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 \
    -framework CoreAudio -framework CoreFoundation \
    -o "$OUT/MacOS/CastMicHAL" CastMicHAL.c
cp Info.plist "$OUT/Info.plist"
# CASTMIC_SIGN_ID に Developer ID を入れると正式署名 (公証用に Hardened Runtime + タイムスタンプ付き)
# 例: CASTMIC_SIGN_ID="Developer ID Application: Yasuyo Mizutani (2PBVY8C5TF)" ./build.sh
if [ -n "${CASTMIC_SIGN_ID:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$CASTMIC_SIGN_ID" build/CastMicHAL.driver
else
    codesign --force --sign - build/CastMicHAL.driver
fi
codesign --verify --strict build/CastMicHAL.driver
echo "built: $(pwd)/build/CastMicHAL.driver"
