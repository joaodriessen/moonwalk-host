#!/bin/bash
# Turn the vendored Lucide SVGs into vector PDFs for template NSImages. Needs rsvg-convert.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rm -f "$DIR"/pdf/*.pdf
for svg in "$DIR"/svg/*.svg; do
  name="$(basename "$svg" .svg)"
  # 24 px at 72 dpi gives a 24 pt page, the glyph's own grid; currentColor renders black,
  # and template images only use the alpha.
  rsvg-convert -f pdf --dpi-x 72 --dpi-y 72 -o "$DIR/pdf/$name.pdf" "$svg"
done
