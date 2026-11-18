# What goes in the app bundle

The downloadable app is assembled by `scripts/package-release.sh`. Finder calls it **Moonwalk Host**. The filesystem name is `Skylight.app`. Install it in `/Applications`, where the daemon expects to find its packaged assets.

| Bundle location | Purpose |
| --- | --- |
| `Contents/MacOS/Skylight` | Swift menu bar app |
| `Contents/Resources/Helpers/Skylight` | C++ streaming daemon |
| `Contents/Resources/Helpers/vd_helper` | Virtual display helper |
| `Contents/Library/LaunchAgents/` | Background service registration for the daemon |
| `Contents/Frameworks/` | Libraries needed at runtime |
| `Contents/Resources/Defaults/` | First-launch configuration and app list |
| `Contents/Resources/config_schema.json` | Shared settings schema |
| `Contents/Resources/assets/` | Desktop artwork and the optional web configuration assets |
| `Contents/Resources/Assets.car` and `sunshine.icns` | App icons for newer and older supported macOS versions |
| `Contents/Resources/LICENSE.txt` and `THIRD-PARTY-NOTICES.txt` | License and dependency notices |

`scripts/release/verify-artifact.sh` checks the layout, library references and signatures. The release flow signs nested components before the app, verifies the DMG and staples the notarization ticket. If you edit a signed bundle, repackage it before testing. Signing or layout checks alone do not exercise Gatekeeper on a fresh Mac, the permission prompts or a live stream. [Release checklist](releasing.md)
