# Changelog

## 0.4.0-alpha.16 (candidate)

- Moved Moonwalk Host to its own source repository. The app’s bundle identifiers, pairing storage and configuration paths stay the same.
- Rewrote the install and troubleshooting guides, updated the Moonwalk preview, and added a release checklist for testing on real Macs.
- Added a repository privacy check and updated Apple Silicon CI.
- Fixed clean builds of the signed installer when the shared dependency cache is empty.
- Updated the optional web settings dependencies and removed the unused Codecov plugin.
- Pointed the web settings page to Moonwalk Host releases and source instead of
  offering unrelated Sunshine updates.
- Removed request headers and parameters from daemon debug logging and improved
  redaction when exporting older logs.
- Include the native and web dependency licenses in the installer and
  document where to get their exact source revisions.
- Staple the app’s notarization ticket before packaging it and verify the app
  inside the finished DMG.
- Use the current OpenSSL 3.5 LTS security release and MiniUPnPC 2.3.5. Retry
  interrupted dependency downloads without accepting a partial archive.
- Make developer build help and argument errors safe to run. Include the
  display helper and web assets in a fresh developer build.

## Earlier private alpha builds

- Renamed Skylight to Moonwalk Host. The existing `Skylight.app` bundle and signing identifiers were retained.
- Added guided setup, native Settings and pairing, a menu status for active and resumable sessions, and service repair and removal.
- Added on-demand virtual displays and compatibility for Moonwalk’s display scale, clipboard, file transfer and cursor extensions.
- Added Moonwalk’s live bitrate updates and improved capture cadence, encoder recovery and session cleanup.

The [source provenance notes](docs/origin.md) identify the imported revision. The original private repository retains the earlier releases.
