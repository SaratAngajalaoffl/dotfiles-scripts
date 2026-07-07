#!/usr/bin/env bash
# Select wallpaper based on time: gojo during day (7 AM–7 PM), sukuna at night (7 PM–7 AM).

WALLPAPER_DIR=~/media/pictures/wallpapers
CACHE_DIR=~/.cache/appearance
CACHE_FILE="$CACHE_DIR/wallpaper.png"

hour=$(date +%H)

if [[ $hour -ge 7 && $hour -lt 19 ]]; then
  src="$WALLPAPER_DIR/gojo_neon.png"
else
  src="$WALLPAPER_DIR/sukuna_neon.png"
fi

mkdir -p "$CACHE_DIR"
cp -- "$src" "$CACHE_FILE"
