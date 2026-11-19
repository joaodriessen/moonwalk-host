# Troubleshooting

Open **Settings…** from the Moonwalk Host menu bar icon. The **Status** page
shows the service, permissions, and repair controls.

## My Mac doesn't appear on my other device

- Check that the Moonwalk Host icon is in the menu bar. If it isn't, open Moonwalk Host.
- Check the menu's first line. It should say **Ready**. If it says **Starting Up…**, wait a moment. If it says **Not Running**, see the next section. If it says **Finish Setup…**, setup isn't done yet, so open it and follow the steps.
- Check that both devices are on the same local network. Guest Wi-Fi networks often keep devices apart.
- If macOS shows a Login Items request, approve Moonwalk Host.
- Add the Mac by address on your other device, using **Add Host** in Moonlight or **Add Host…** in Moonwalk. **Settings… → Network** shows the address, with a **Copy** button.

## The menu says Not Running or Can't Verify Moonwalk Host

**Can't Verify Moonwalk Host** means the app couldn't confirm that the service is genuinely Moonwalk Host's. If the steps below don't clear it, install a fresh copy from the DMG.

For either message, open **Settings… → Status** and choose
**Repair Streaming Host…** if offered. Repair checks the installation and starts
the service again. It keeps your settings and paired devices.

## I'm stuck on "Setup needs attention"

Press **Try Again**. If it still fails, press **Repair Streaming Host…**. Check that Moonwalk Host is in your Applications folder and not running from the DMG.

## Pairing fails

- Enter the PIN on the Mac, not on the other device. The other device shows it.
- Open **Pair New Device…** from the menu **before** you type, and select your device's row. You have to select it even if it's the only one.
- If you've paired this device before, remove the old entry in **Settings… → Devices** and try again.
- A pairing request stops being valid after a few minutes. If yours has expired, start it again from the other device.

## Keyboard or mouse doesn't work

Moonwalk Host needs the Accessibility permission. In **Settings… → Status**, press **Check Permissions…**. Also check that **Allow keyboard control** and **Allow mouse control** are on in **Settings… → Devices**.

## The picture doesn't appear

Moonwalk Host needs the Screen Recording permission. Press **Check Permissions…** in **Settings… → Status**. If it was already on, turn it off and on again in System Settings, then quit and reopen Moonwalk Host.

## Black screen or wrong display

Open **Settings… → Status** and press **Restart Moonwalk Host…**. This ends the current stream.

Other remote-desktop or display-management tools can disable Moonwalk Host's display, and running several at once isn't supported. Either turn off the other tool's virtual display management, or turn off **Virtual display** in **Settings… → Display** and choose a screen under **Capture display**. If Moonwalk Host can't prepare its display, your other device shows an error, and you can retry once the conflict is gone.

## There's no sound

End the stream, then open **Settings… → Streaming**. Turn on **Stream this
Mac’s sound**, play something on the Mac, and press **Test Sound**. The test
reports whether it picked up sound from the selected source. For a microphone,
check the Microphone permission in the same section.

## The stream is choppy

See [Diagnose a choppy stream](guides/performance.md).

## My settings changed by themselves

If another tool or a text edit changes Moonwalk Host's settings file while Settings is open, Moonwalk Host asks whether to **Use Outside Value** or **Keep My Edit**. To go back to an earlier setup, use **Saved Setups** in **Settings… → Status**, which saves your current settings first.

## Asking for help

1. Open **Settings… → Status → Support → Diagnostics and maintenance** and choose **Save Diagnostics…**. This makes a ZIP on your Mac with system details, the names of your settings and a redacted log. It stays on your Mac until you choose to share it.
2. Review the archive and remove personal details before sharing it. Include the host and client versions and the relevant log excerpt.
3. [Open an issue](https://github.com/joaodriessen/moonwalk-host/issues/new/choose). The form asks for the rest.

For more detail, turn on **Detailed logging** in **Settings… → Status → Advanced** first, and restart Moonwalk Host.

---

[All guides](guides/README.md) · [Install Moonwalk Host](INSTALL.md)
