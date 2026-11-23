#!/usr/bin/env bash
# Renders the app icons from the logo masters in assets/brand/ (the keyhole K;
# tool/icons/build_svgs.mjs writes them):
#
#   kemlock-icon-square.svg      iOS AppIcon-1024, which rounds the corners itself
#   kemlock-icon(-small).svg     Android's ic_launcher, for launchers without
#                                adaptive icons; the small one up to 48 px
#   kemlock-icon-round.svg       Android's ic_launcher_round
#   kemlock-icon-foreground.svg  Android's adaptive icon, over
#   kemlock-icon-background.svg  its gunmetal background, and
#   kemlock-icon-monochrome.svg  the layer Android 13 tints for themed icons
#
# Runs rsvg-convert in a Fedora container, so nothing has to be installed.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
mobile="$(cd "$here/../.." && pwd)"

(cd "$mobile" && node tool/icons/build_svgs.mjs)

# Git Bash would rewrite the container paths below as Windows paths.
export MSYS_NO_PATHCONV=1
docker run --rm -v "$mobile/assets/brand:/brand:ro" -v "$mobile:/mobile" fedora:44 bash -c '
  set -e
  dnf install -y -q librsvg2-tools ImageMagick >/dev/null
  r() { rsvg-convert -w "$2" -h "$2" "/brand/$1" -o "$3"; }
  # The App Store refuses a marketing icon with an alpha channel.
  ios=/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
  r kemlock-icon-square.svg 1024 "$ios"
  magick "$ios" -background "#16181C" -alpha remove -alpha off PNG24:"$ios"
  for d in mdpi:48:108 hdpi:72:162 xhdpi:96:216 xxhdpi:144:324 xxxhdpi:192:432; do
    name=${d%%:*}; rest=${d#*:}; size=${rest%%:*}; layer=${rest#*:}
    res=/mobile/android/app/src/main/res/mipmap-$name
    if [ "$size" -le 48 ]; then icon=kemlock-icon-small.svg; else icon=kemlock-icon.svg; fi
    r "$icon" "$size" "$res/ic_launcher.png"
    r kemlock-icon-round.svg "$size" "$res/ic_launcher_round.png"
    r kemlock-icon-foreground.svg "$layer" "$res/ic_launcher_foreground.png"
    r kemlock-icon-background.svg "$layer" "$res/ic_launcher_background.png"
    r kemlock-icon-monochrome.svg "$layer" "$res/ic_launcher_monochrome.png"
  done
'
