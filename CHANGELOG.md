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
  redaction when exporting older logs. Startup also keeps configuration values
  such as display names and hook commands out of the log.
- Redact IPv6 addresses, partial certificates, and older request URLs from
  diagnostic archives. Keep timestamps and timing measurements visible.
- Include the native and web dependency licenses in the installer and
  document where to get their exact source revisions.
- Staple the app’s notarization ticket before packaging it and verify the app
  inside the finished DMG.
- Use the current OpenSSL 3.5 LTS security release and MiniUPnPC 2.3.5. Retry
  interrupted dependency downloads without accepting a partial archive.
- Make developer build help and argument errors safe to run. Include the
  display helper and web assets in a fresh developer build.
- Save pairing changes before confirming them. An interrupted write leaves the
  previous device list intact, and new credential files are private to their owner.
- Keep a pending pairing response alive long enough to report a failed handshake
  back to the client. The browser confirms when it sends the PIN and lets you try
  again if the host denies the request or the connection drops.
- The browser settings report failed unpair requests and let you try again.
  Save and Restart show success after the host acknowledges them. Edits stay
  on the page if saving fails.
- Edits to the application list preserve the active stream. A failed write
  leaves the previous list intact, and saving no longer logs the app commands.
- The browser checks that an application still matches the list you opened
  before saving or deleting it. Failed saves leave your draft on the page.
- Load browser files, app artwork and settings schemas from the running Host
  bundle so a second installed copy cannot supply outdated assets.
- The host version command reports the build and source commit without creating
  settings. Invalid daemon flags return an error.
- Remove the inherited Featured Apps catalog and its external request from the
  browser settings.

## Earlier private alpha builds

- Renamed Skylight to Moonwalk Host. The existing `Skylight.app` bundle and signing identifiers were retained.
- Added guided setup, native Settings and pairing, a menu status for active and resumable sessions, and service repair and removal.
- Added on-demand virtual displays and compatibility for Moonwalk’s display scale, clipboard, file transfer and cursor extensions.
- Added Moonwalk’s live bitrate updates and improved capture cadence, encoder recovery and session cleanup.

The [source provenance notes](docs/origin.md) identify the imported revision. The original private repository retains the earlier releases.
