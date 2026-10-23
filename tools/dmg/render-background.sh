#!/bin/zsh
# Renders background.html to background.png and background@2x.png with headless Chrome. Run it after you change the
# HTML, and commit both PNGs. release.sh combines them into one Retina TIFF.
set -euo pipefail
cd "${0:A:h}"
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
for scale in 1 2; do
  out=background.png; [[ $scale == 2 ]] && out=background@2x.png
  "$chrome" --headless --disable-gpu --hide-scrollbars --window-size=640,400 --force-device-scale-factor=$scale \
    --screenshot="$PWD/$out" "file://$PWD/background.html" 2>/dev/null
done
