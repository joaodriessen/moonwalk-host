# Security

Pair only devices you trust. A paired client can view and control your
logged-in Mac while streaming. Review or remove devices under
**Settings → Devices**. Use a trusted network and leave the router's port
forwarding and UPnP off.

| Part of the connection | Protection |
| --- | --- |
| Pairing | Enter a PIN on the Mac to confirm the request. Pairing uses a PIN-derived key during the initial HTTP exchange, then the client and host use certificates |
| Keyboard and mouse | Session encryption, with older modes for legacy clients |
| Clipboard and files | Paired HTTPS, with session and file path checks |
| LAN video | Unencrypted by default. Choose **Required** under **Settings → Network → Advanced → Local network encryption** to require encryption from clients that support it |
| Audio | Encrypted when the client requests it |

The menu and the streaming service check each other's signing identity.
**Quit Moonwalk Host** stops the service. Release DMGs use Developer ID
signing, hardened runtime, and Apple notarization. **Save Diagnostics…**
writes a ZIP locally and masks common identifiers and credentials. Review
the archive before sharing it.

## Report a vulnerability

Use GitHub's [private vulnerability reporting form](https://github.com/joaodriessen/moonwalk-host/security/advisories/new). Include the affected build, impact, and a minimal reproduction with example data. If you need another private channel, open an issue asking how to contact the maintainer. Keep technical details out of public issues and pull requests. The current alpha is maintained on a best-effort basis.

[Release checklist](docs/releasing.md)
