#!/bin/sh
# Render the two social-card images from the brand wallpaper and mark, both
# committed so CI never needs the tooling. Run locally after editing either
# input; requires ImageMagick 7 and librsvg (brew install imagemagick librsvg).
#
#   static/images/og-card.png   the landing's brand card (og-card.svg over
#                               gori-wallpaper.webp), set by the two index
#                               pages' `image` and by og.default_image.
#   tools/og-card/backdrop.png  the backdrop hwaro's og.auto_image draws each
#                               page's title onto (config.toml). hwaro caps
#                               its own logo at 48px, so the mark is baked
#                               in here, above the `framed` style's title.
set -eu
cd "$(dirname "$0")"
IMG=../../static/images
INK='#080a11'
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Brand card. rsvg-convert only resolves <image> refs beside the source
# file, so the art is staged next to a copy of the SVG.
magick "$IMG/gori-wallpaper.webp" -resize '1200x675^' -gravity center \
  -crop 1200x630+0+0 +repage "$work/og-card-art.png"
cp og-card.svg "$work/"
rsvg-convert -w 1200 -h 630 "$work/og-card.svg" -o "$IMG/og-card.png"

# Page backdrop: the logo-free wallpaper, dimmed by 65% overall (the gold
# clouds otherwise outshine the title) and further in a feathered ellipse
# where the title and description sit, with the gold mark and a soft glow
# at the top. The dim lives here, not in og.auto_image.overlay_opacity,
# because hwaro lays its overlay over the whole backdrop, mark included.
# hwaro writes PNG only, and its encoder spends ~1MB a card on the gold-dust
# grain; a median pass and 48 flat colours (wallpaper layer only, so the
# glow stays smooth) halve the deployed og-images/ with no visible loss.
magick "$IMG/wallpaper.webp" -resize '1200x675^' -gravity north \
  -crop 1200x630+0+20 +repage -fill "$INK" -colorize 65% \
  -statistic median 3 +dither -colors 48 "$work/wall.png"
magick -size 1200x630 xc:black -fill white \
  -draw 'ellipse 600,350 520,190 0,360' -blur 0x90 -evaluate multiply 0.95 \
  "$work/mask.png"
magick -size 1200x630 "xc:$INK" "$work/mask.png" -alpha off \
  -compose CopyOpacity -composite "$work/shade.png"
rsvg-convert -w 168 -h 168 "$IMG/gori.svg" -o "$work/mark.png"
magick "$work/mark.png" -channel A -evaluate multiply 0.9 +channel \
  -background none -gravity center -extent 360x360 -blur 0x24 "$work/glow.png"
magick "$work/wall.png" "$work/shade.png" -composite \
  "$work/glow.png" -gravity north -geometry +0-42 -composite \
  "$work/mark.png" -gravity north -geometry +0+54 -composite \
  -strip backdrop.png

echo "wrote static/images/og-card.png and tools/og-card/backdrop.png"
