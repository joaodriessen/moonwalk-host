<p align="center">
  <img src="docs/assets/skylight-icon.png" width="104" alt="">
</p>

<h1 align="center">Moonwalk Host</h1>

<p align="center">
  <a href="docs/INSTALL.md">Install and pair</a> ·
  <a href="docs/TROUBLESHOOTING.md">Troubleshooting</a> ·
  <a href="https://github.com/joaodriessen/moonwalk-host/releases">Releases</a>
</p>

Moonwalk Host lets you use your Mac from another device on your local network.
It runs in the menu bar, sends your desktop and sound to the client, and passes
the client's keyboard and mouse input to macOS. Connect with
[Moonwalk](https://github.com/joaodriessen/moonwalk) on Linux or a
[Moonlight](https://moonlight-stream.org/) client.

Moonwalk Host is in **alpha** and targets **Apple Silicon** Macs running
**macOS 14 or later**. If you've been invited to test, use the signed and
notarized DMG provided by the project. The [installation guide](docs/INSTALL.md) walks
through the macOS permissions and the first pairing.

## Stream with or without a monitor

By default, the host asks macOS to create a virtual display at the client's
requested size and refresh rate. It tries to make that display primary while
you're connected. The modes and text sizes available depend on macOS and the
client. The Mac needs to be awake and logged in. If you'd rather share what's on
a connected monitor, choose it in [Display settings](docs/guides/settings.md#display).

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/moonwalk-view-dark.png">
    <img src="docs/assets/moonwalk-view-light.png" width="760" alt="Moonwalk on Linux with Studio Mac selected, showing the planned resolution, frame rate and bitrate.">
  </picture>
</p>

<sub>Moonwalk on Linux showing an example Mac and the settings it plans to request.</sub>

## Choose a client

| | Moonwalk | Moonlight |
| --- | --- | --- |
| Video, stereo audio, keyboard and mouse | Yes | Yes |
| Request a virtual display and reconnect to Desktop | Yes | Yes |
| Clipboard, regular-file transfer and remote cursor shapes | With compatible builds | — |
| Request a supported macOS text scale and adjust bitrate during a stream | With compatible builds | — |

Streams start with H.264 and SDR. You can offer HEVC in Settings if your client
supports it. See [compatibility](docs/compatibility.md) for display, controller,
and headless coverage.

## Keep access under your control

Pair only devices you trust. Review or remove them in **Settings → Devices**.
**Quit Moonwalk Host** stops the service. Video is unencrypted with the
default LAN settings, so use a trusted network and leave port forwarding off.
[Security and reporting](SECURITY.md)

## Work on Moonwalk Host

Start with [Building](docs/BUILDING.md), [Contributing](CONTRIBUTING.md), or the [architecture notes](docs/architecture.md). [All documentation](docs/README.md)

Moonwalk Host builds on [Sunshine](https://github.com/LizardByte/Sunshine) and the macOS work in [Lumen](https://github.com/trollzem/Lumen). It uses the GameStream-compatible protocol supported by [Moonlight](https://moonlight-stream.org/). [GPL-3.0-only](LICENSE) · [Third-party code](docs/third-party.md)
