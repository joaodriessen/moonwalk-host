# Architecture

The menu bar app and daemon run in the logged-in macOS user session. The menu owns the user-facing lifecycle and settings. The daemon handles discovery, pairing, session negotiation, capture, input and encoding. The client owns the requested stream mode and decides when to connect.

| Layer | Start here |
| --- | --- |
| Setup, pairing and settings UI | `macos-dist/SkylightMenu` |
| Local daemon commands and peer verification | `src/platform/macos/xpc_control.mm` and the menu’s `HostConnection.swift` |
| GameStream HTTP endpoints and pairing | `src/nvhttp.cpp` |
| Video and transport | `src/video.cpp`, `src/stream.cpp`, `src/platform/macos` |
| Virtual display lifecycle | `src/platform/macos/virtual_display.m` and `vd_helper.m` |
| Config parsing and settings schema | `src/config.cpp` and `src_assets/common/assets/web/config_schema.json` |
| Shipped defaults and signing identity | `macos-dist/sunshine.conf.example` and `macos-dist/skylight-identity.conf` |

## Starting and stopping

The packaged menu app registers the embedded LaunchAgent through `SMAppService`. The daemon uses XPC to verify that the signed menu has attached before starting its public-facing service. It also checks menu presence when accepting a session. Normal quit asks the daemon to shut down. The daemon watches menu exit and has a stale-contact fallback.

The menu and daemon verify each other’s signing identities. Developer builds use a local certificate. Release builds pin the Apple Developer ID team and code identifiers. The existing bundle, service labels and storage paths form part of the install and upgrade contract. [Bundle layout](release-surface.md)

## Pairing

Opening **Pair New Device…** in the menu or the authenticated browser page opens a brief pairing window. The owner selects the request by the address observed by the host and enters the four-digit PIN from the client. The selection is required even when only one device appears. A repeated PIN submission leaves an exchange already underway alone.

Sending the PIN starts the handshake. The menu can show the outcome after the client finishes, and the browser asks the owner to continue on the client. The daemon saves a successful authorization before reporting that the device is paired. It applies the same persistence rule to unpairing. [Pairing flow](../src/nvhttp.cpp)

## Display and video

The daemon maps the client’s request to a capture mode. When virtual display is enabled, it asks the helper to create the mode and manages its lifetime separately from the resumable Desktop target. The helper also monitors its parent so it can exit when the daemon disappears. Test normal disconnect, failed launch and crash cleanup independently. The virtual display uses private macOS APIs, which makes OS upgrades a runtime qualification case.

ScreenCaptureKit supplies display frames and system audio. The host uses VideoToolbox for hardware video encoding. Moonwalk can request a bitrate change over the existing session when both ends support it. That updates the encoder target. The original request, incoming capture cadence, encoded cadence and client presentation rate are separate measurements.

## Settings and upgrades

The native settings UI and web fallback read a shared schema. For web saves with a loaded schema, the daemon validates known values and preserves keys added by another tool or a newer version. The application list has separate storage and a revision check for browser edits. The running session keeps the target and environment that it launched with.

When changing an option, check its shipped default, parser, schema and restart behavior together. Older builds used the Skylight name. Retain macOS bundle and code-signing identifiers, the installed bundle path and the config location unless the change includes a tested migration. [Settings schema](../src_assets/common/assets/web/config_schema.json)
