# Install Moonwalk Host

Set up Moonwalk Host on the Mac you want to use from Linux. It needs Apple
Silicon and macOS 14 or later. Install **Moonwalk** on Linux, or use a
**Moonlight** client on another device. Connect both computers to the same
local network.
[Get Moonwalk for Linux](https://github.com/joaodriessen/moonwalk/blob/main/docs/guides/getting-started.md#install-moonwalk) ·
[Get Moonlight](https://moonlight-stream.org/)

## 1. Copy it to Applications

Download and open `Moonwalk-Host-…-macOS-arm64-notarized.dmg` from
[GitHub Releases](https://github.com/joaodriessen/moonwalk-host/releases).
Drag Moonwalk Host to **Applications**, then open the copy there. If macOS refuses to open the app,
share the message with the maintainer.

Moonwalk Host checks where it's running from. If it isn't in Applications, it asks you to move it first.

## 2. Follow the setup window

A window titled **Welcome to Moonwalk Host** takes you through setup. It comes back each time you open Moonwalk Host until you've finished.

Moonwalk Host enables its login item on first launch and asks whether it can
show notifications. To start it by hand instead, turn off
**Open Moonwalk Host at Login** in **Settings… → Status → General**.

### Allow the background service

Moonwalk Host's streaming service runs in the background. If macOS needs your approval, Moonwalk Host shows **Allow Moonwalk Host in Login Items** with an **Open Login Items** button. Turn Moonwalk Host on in the list that opens.

### Allow two permissions

| Permission | Why Moonwalk Host needs it |
| --- | --- |
| **Screen Recording** | To stream what's on your Mac |
| **Accessibility** | To pass through keyboard and mouse input from your other device |

Press **Allow** next to each, then turn on Moonwalk Host in System Settings. Moonwalk Host restarts its service by itself after you grant Screen Recording.

You may see other requests later. If you pick a microphone as the sound source, macOS asks for Microphone access. macOS may also ask for permission to use your local network.

## 3. Pair your first device

Pairing needs both devices the first time. The client shows the PIN and
Moonwalk Host asks for it on the Mac.

1. On your other device, open Moonwalk or Moonlight and select your Mac to
   get a four-digit PIN. If it doesn't show up, copy an address from
   **Moonwalk Host → Settings… → Network** and paste it into **Add Host** in
   the client.
2. On the Mac, click the Moonwalk Host icon in the menu bar and choose **Pair New Device…**. During setup, you can press **Pair a Device** instead.
3. Select your device’s row, enter the PIN and press **Pair Device**.

When a device asks to pair, the menu item shows a dot and you get a notification, but the pairing window only opens when you choose it.

## 4. Connect

Leave the Mac awake and logged in. In Moonwalk on Linux, click **Connect**.
In Moonlight, open your Mac and choose **Desktop**. The menu bar on the
Mac shows which device is streaming and the video format.

## Everyday use

Moonwalk Host lives in the menu bar, and that's the only place you'll usually see it.

**Quit Moonwalk Host** stops the service. If someone is streaming, it asks
before disconnecting them.

If the client leaves the Desktop session running, the menu shows **Ready to
Resume**. Capture stops and the virtual display is released. Some clients,
including Moonwalk, can also ask the host to end the Desktop session on
disconnect.

## Updating

Moonwalk Host doesn't check for updates by itself. **View Releases…** in **Settings… → Status** opens the download page.

To update, quit Moonwalk Host and replace the app in Applications with the copy from the newer DMG. The app uses the existing settings and paired devices. Use a release signed by the same developer to preserve macOS permissions.

## Removing Moonwalk Host

Open **Settings… → Status → Support → Diagnostics and maintenance**:

- **Uninstall Moonwalk Host…** turns off Open at Login, removes the background service, deletes your settings and paired devices, moves Moonwalk Host to the Trash and quits.
- **Remove Background Service…** removes the service and turns off Open at Login. Your settings and paired devices stay, in case you reinstall. Move Moonwalk Host to the Trash yourself when you're ready.

Screen Recording and Accessibility entries may stay in System Settings afterward, and you can remove them there.

## Where Moonwalk Host keeps its files

Moonwalk Host uses `~/.config/skylight` and `~/Library/Application Support/Skylight`. Its settings are in `sunshine.conf` and its log is in `sunshine.log`, both in the first folder.

If you used an earlier Moonwalk Host, it copies your old `~/.config/sunshine` settings and paired devices the first time it runs, and leaves the old folder alone. A fresh install doesn't import an unrelated Sunshine setup. Uninstalling removes only Moonwalk Host's own data.

---

[Settings](guides/settings.md) · [Troubleshooting](TROUBLESHOOTING.md) · [All guides](guides/README.md)
