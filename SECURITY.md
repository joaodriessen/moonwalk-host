# Security

Use Moonwalk Host with devices you control on a trusted local network. A paired client can see your screen and control the logged-in user session while the host is open and the client is streaming. Review or remove devices in **Settings → Devices**. Leave the router’s port forwarding and UPnP off.

| Part of the connection | Protection |
| --- | --- |
| Pairing | Enter a PIN on the Mac to confirm the request. Pairing uses a PIN-derived key during the initial HTTP exchange, then the client and host use certificates |
| Keyboard and mouse | Session encryption, with older modes for legacy clients |
| Clipboard and files | Paired HTTPS, with session and file path checks |
| LAN video | Unencrypted by default. Choose **Required** under **Settings → Network → Advanced → Local network encryption** to require encryption from clients that support it |
| Audio | Encrypted when the client requests it |

The menu app and service verify each other’s signing identity. Quit closes the service. A release DMG uses Developer ID signing, hardened runtime and Apple notarization. Diagnostics are saved locally and redact common identifiers and secrets. Review them before sharing.

## Report a vulnerability

While this repo is private, use a private channel to contact the maintainer. If you need help finding a channel, open an issue asking how to report privately and leave out technical details. Include the affected build, impact and a minimal reproduction with example data once a private channel is available.

Before making the repo public, verify GitHub’s private vulnerability reporting or publish a monitored private contact here. The current alpha line is maintained on a best-effort basis.

[Release checklist](docs/releasing.md)
