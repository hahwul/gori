#!/bin/sh
# Rebuild hangul-bold.otf, the font hwaro's og.auto_image renders Korean
# page titles with. The hwaro Docker image CI builds with ships only DejaVu,
# so without it every Hangul glyph is dropped from the ko/ cards.
#
# It is a Hangul-only subset of Pretendard Bold (SIL OFL 1.1, see
# OFL-Pretendard.txt): hwaro puts font_path at the head of its font chain,
# so Latin still falls through to the bundled Space Grotesk. U+0020 is kept
# so a space after a Hangul run takes a Hangul-width advance. A subset is a
# Modified Version under the OFL and "Pretendard" is a Reserved Font Name,
# hence the rename.
#
# hwaro's OG cache keys font_path by name, not contents, and CI restores
# og-images/ from gh-pages: after rebuilding, save under a new file name
# (and point config.toml at it) or the deployed cards keep the old font.
#
# Run locally only; requires gh, unzip and python3 (fonttools is installed
# into a throwaway venv).
set -eu
cd "$(dirname "$0")"
VERSION=1.3.9
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

gh release download "v$VERSION" --repo orioncactus/pretendard \
  -p "Pretendard-$VERSION.zip" -D "$work"
unzip -q "$work/Pretendard-$VERSION.zip" -d "$work/src"
python3 -m venv "$work/venv"
"$work/venv/bin/pip" -q install fonttools

"$work/venv/bin/pyftsubset" "$work/src/public/static/Pretendard-Bold.otf" \
  --unicodes="U+0020,U+1100-11FF,U+3130-318F,U+AC00-D7A3" \
  --layout-features='*' --no-hinting --output-file="$work/subset.otf"

"$work/venv/bin/python" - "$work/subset.otf" hangul-bold.otf <<'PY'
import sys
from fontTools.ttLib import TTFont
font = TTFont(sys.argv[1])
names = {1: "Gori OG Hangul", 2: "Bold", 3: "GoriOGHangul-Bold",
         4: "Gori OG Hangul Bold", 6: "GoriOGHangul-Bold",
         16: "Gori OG Hangul", 17: "Bold"}
for rec in list(font["name"].names):
    if rec.nameID in names:
        rec.string = names[rec.nameID]
cff = font["CFF "].cff
cff.fontNames = ["GoriOGHangul-Bold"]
cff[0].FullName = "Gori OG Hangul Bold"
cff[0].FamilyName = "Gori OG Hangul"
font.save(sys.argv[2])
PY
echo "wrote tools/og-card/hangul-bold.otf"
