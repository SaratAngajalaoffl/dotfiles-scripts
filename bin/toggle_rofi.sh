#!/usr/bin/env bash

# Check if a rofi process is running
if pgrep -x "rofi" > /dev/null; then
    pkill -x rofi
else
    rofi -show combi
fi