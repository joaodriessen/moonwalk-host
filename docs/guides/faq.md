# Common questions

## What do I install where?

Put Moonwalk Host on the Mac you want to use remotely. On the device in front of you, install [Moonwalk](https://github.com/joaodriessen/moonwalk) for Linux or [Moonlight](https://moonlight-stream.org/). Pair the two on the same local network. [Installation](../INSTALL.md)

## Can a paired device control my Mac later?

Yes, while Moonwalk Host is open. Pair only devices you trust and remove old ones under **Settings → Devices**. Since video is unencrypted with the default LAN setting, use a trusted network and keep port forwarding off. [Security](../../SECURITY.md)

## Can I use my Mac with no monitor?

Yes, with **Virtual display** enabled and the Mac awake and logged in. Use a
monitor or Screen Sharing to finish setup first. Wake, lock screen, and
closed-lid behavior are still being tested. [Compatibility](../compatibility.md)

## What happens to the physical display?

When a virtual display becomes primary, macOS rearranges the desktop around it. The host attempts to restore the previous arrangement when streaming ends. If you want to share an existing screen, turn off **Virtual display** and choose the capture display. [Display settings](settings.md#display)

## What do the permissions do?

Screen Recording lets the host capture the desktop. Accessibility lets it send keyboard and mouse input to macOS. Microphone permission is needed if you choose a microphone as the audio source.

## Does the app contact a server?

Moonwalk Host has no account or analytics service and doesn't check for updates
automatically. Release links open in your browser. Cover art search in the web
settings contacts external services. [Network behavior](how-it-works.md#network-behavior)

## How do I stop, update or remove it?

Choose **Quit Moonwalk Host** in the menu bar to stop the service. To stop launching it at login, turn off **Open Moonwalk Host at Login** in Settings. For a newer version, replace the old app with the one from the DMG. For removal, use the uninstall action in the app. [Update and removal](../INSTALL.md#updating)
