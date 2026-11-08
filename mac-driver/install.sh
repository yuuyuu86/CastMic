#!/bin/sh
# 管理者権限でインストールし、Core Audio を再起動する (音が一瞬途切れる)
set -eu
cd "$(dirname "$0")"
[ -d build/CastMicHAL.driver ] || ./build.sh
sudo rm -rf /Library/Audio/Plug-Ins/HAL/CastMicHAL.driver
sudo cp -R build/CastMicHAL.driver /Library/Audio/Plug-Ins/HAL/
sudo killall coreaudiod
echo "installed. 「CastMic Microphone」「CastMic Speaker」がサウンド設定に出ます。"
