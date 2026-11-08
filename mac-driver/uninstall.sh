#!/bin/sh
set -eu
sudo rm -rf /Library/Audio/Plug-Ins/HAL/CastMicHAL.driver
sudo killall coreaudiod
echo "uninstalled."
