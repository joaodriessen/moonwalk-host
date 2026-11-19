# Compatibility

Moonwalk Host targets Apple Silicon Macs running macOS 14 or later. We're
still testing the range of Macs, displays, and clients that work together.

| Area | What to expect |
| --- | --- |
| Mac | Apple Silicon on macOS 14 or later |
| Linux client | Moonwalk supports optional file, clipboard, cursor, display scale and bitrate extensions when both builds support them |
| Other clients | Moonlight-compatible video, audio and input. Expect client-specific differences in mode requests and codec or encryption support |
| Display | Physical capture or a virtual display. Headless use needs initial setup and an awake, logged-in Mac |
| Text size | Supported 1× and 2× modes. Fractional scaling depends on macOS and the client |
| Video and sound | SDR, stereo, H.264 by default and optional HEVC |
| Controllers | A virtual gamepad where macOS allows it, with keyboard and mouse emulation as a fallback. Controller coverage is limited |
| Network | One user on a trusted local network |
| Updates | Replace the app from a newer signed DMG in `/Applications` |

Complex multi-display arrangements, permissions after OS updates, locked sessions, wake and recovery after a crash still need broader testing. Virtual displays use macOS APIs that can change between releases. Running multiple display-management tools can affect capture or restoration.

**Ready to Resume** means a Desktop entry can be reopened. There can be zero
viewers connected and no active capture or virtual display.

[Install and update](INSTALL.md) · [Security](../SECURITY.md) · [Release checks](releasing.md)
