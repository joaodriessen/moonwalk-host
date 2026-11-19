# Compatibility

Moonwalk Host targets Apple Silicon Macs running macOS 14 or later. The table describes alpha support and the areas still being tested.

| Area | What to expect |
| --- | --- |
| Mac | Apple Silicon, macOS 14 or later. Intel Macs, Linux and Windows are outside the host’s target platforms |
| Linux client | Moonwalk supports optional file, clipboard, cursor, display scale and bitrate extensions when both builds support them |
| Other clients | Moonlight-compatible video, audio and input. Expect client-specific differences in mode requests and codec or encryption support |
| Display | Physical capture or a virtual display. Headless use needs initial setup and an awake, logged-in Mac |
| Text size | Supported 1× and 2× modes. Fractional scaling depends on macOS and the client |
| Video and sound | SDR, stereo, H.264 by default and optional HEVC |
| Controllers | Basic keyboard and mouse mapping |
| Network | One user on a trusted local network |
| Updates | Replace the app from a newer signed DMG in `/Applications` |

Complex multi-display arrangements, permissions after OS updates, locked sessions, wake and recovery after a crash still need broader testing. Virtual displays use macOS APIs that can change between releases. Running multiple display-management tools can affect capture or restoration.

A **Ready to Resume** Desktop can coexist with zero connected clients. Verify that the viewer, capture and temporary display are gone separately from whether a Desktop session can be resumed.

[Install and update](INSTALL.md) · [Security](../SECURITY.md) · [Release checks](releasing.md)
