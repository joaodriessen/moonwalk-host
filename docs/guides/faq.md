# Common questions

## What do I install where?

Put Moonwalk Host on the Mac you want to use remotely. On the device in front of you, install [Moonwalk](https://github.com/joaodriessen/moonwalk) for Linux or [Moonlight](https://moonlight-stream.org/). Pair the two on the same local network. [Installation](../INSTALL.md)

## Can a paired device control my Mac later?

Yes, while Moonwalk Host is open. Pair only devices you trust and remove old ones under **Settings → Devices**. Since video is unencrypted with the default LAN setting, use a trusted network and keep port forwarding off. [Security](../../SECURITY.md)

## Can I use my Mac with no monitor?

Virtual display, enabled by default, is intended for this. The Mac needs to be awake and logged in. Use a monitor or Screen Sharing to finish setup first. Wake, lock screen and closed-lid behavior still need broader qualification. [Compatibility](../compatibility.md)

## What happens to the physical display?

When a virtual display becomes primary, macOS rearranges the desktop around it. The host attempts to restore the previous arrangement when streaming ends. If you want to share an existing screen, turn off **Virtual display** and choose the capture display. [Display settings](settings.md#display)

## What do the permissions do?

Screen Recording lets the host capture the desktop. Accessibility lets it send keyboard and mouse input to macOS. Microphone permission is needed if you choose a microphone as the audio source.

## Does the app contact a server?

There are no accounts, analytics or automatic update checks in the app. Release links open in your browser. The optional web settings page has its own network requests. [Network behavior](how-it-works.md#network-behavior)

## How do I stop, update or remove it?

Choose **Quit Moonwalk Host** in the menu bar to stop the service. To stop launching it at login, turn off **Open Moonwalk Host at Login** in Settings. For a newer version, replace the old app with the one from the DMG. For removal, use the uninstall action in the app. [Update and removal](../INSTALL.md#updating)
