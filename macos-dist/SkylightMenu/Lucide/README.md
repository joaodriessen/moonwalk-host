# Lucide glyphs

The menu bar app's icons are [Lucide](https://lucide.dev) v1.67.0 (`lucide-static`,
npm tarball verified against its sha512 integrity), under the ISC license in `LICENSE`.

`svg/` holds the upstream files unchanged. `pdf/` is generated from them by `generate.sh`,
because AppKit loads PDF as resolution-independent template images on every macOS this app
supports. `scripts/package-release.sh` copies `pdf/` into `Contents/Resources/Lucide`.

To add a glyph: copy its SVG from the same Lucide version into `svg/`, add a case to
`LucideGlyph` (SkylightMenuCore), and run `generate.sh`.
