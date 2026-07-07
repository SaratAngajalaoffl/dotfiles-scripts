#! /usr/bin/zsh
#
~/.local/bin/select_wallpaper.sh

notify-send "System" "Updated wallpaper successfully!"

killall hyprpaper
hyprpaper
