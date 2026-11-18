# Changelog

## Unreleased

- Moved Moonwalk Host to its own source repository. The app’s bundle identifiers, pairing storage and configuration paths stay the same.
- Rewrote the install and troubleshooting guides, updated the Moonwalk preview, and added a release checklist for testing on real Macs.
- Added a repository privacy check and updated Apple Silicon CI.
- Fixed clean builds of the signed installer when the shared dependency cache is empty.
- Updated the optional web settings dependencies and removed the unused Codecov plugin.

## Earlier private alpha builds

- Renamed Skylight to Moonwalk Host. The existing `Skylight.app` bundle and signing identifiers were retained.
- Added guided setup, native Settings and pairing, a menu status for active and resumable sessions, and service repair and removal.
- Added on-demand virtual displays and compatibility for Moonwalk’s display scale, clipboard, file transfer and cursor extensions.
- Added Moonwalk’s live bitrate updates and improved capture cadence, encoder recovery and session cleanup.

The [source provenance notes](docs/origin.md) identify the imported revision. The original private repository retains the earlier releases.
