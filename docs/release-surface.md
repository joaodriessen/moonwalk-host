# What goes in the app bundle

The downloadable app is assembled by `scripts/package-release.sh`. Finder calls it **Moonwalk Host**. The filesystem name is `Skylight.app`. Install it in `/Applications` and keep that filename for upgrades. The daemon loads the assets shipped in its own bundle.

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
| `Contents/Resources/ThirdPartyLicenses/` | License texts for the native and web dependencies |

`scripts/release/verify-artifact.sh` checks the layout, library references,
and signatures. The release signs the nested components and staples the
app's ticket before making the DMG. It then checks the DMG and its own
ticket. If you edit a signed bundle, repackage it before testing. Test
Gatekeeper, permission prompts, and streaming on a real Mac.
[Release checklist](releasing.md)
