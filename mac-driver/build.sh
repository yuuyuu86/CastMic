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
codesign --force --sign - build/CastMicHAL.driver
echo "built: $(pwd)/build/CastMicHAL.driver"
