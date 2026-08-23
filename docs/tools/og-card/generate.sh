#!/bin/sh
# Render the social card SVG to the committed PNG. Run locally after editing
# og-card.svg; requires librsvg (brew install librsvg). CI never runs this.
set -eu
cd "$(dirname "$0")"
# rsvg-convert only resolves <image> refs beside the source file, so stage the
# brand mark locally for the render.
cp ../../static/images/gori.svg gori-mark.svg
rsvg-convert -w 1200 -h 630 og-card.svg -o ../../static/images/og-card.png
rm -f gori-mark.svg
echo "wrote static/images/og-card.png"
