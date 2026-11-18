# Settings

Open **Settings…** from the Moonwalk Host menu bar icon.

## The menu

Click the Moonwalk Host icon in the menu bar. The first line tells you what's happening:

| It says | What it means |
| --- | --- |
| **Starting Up…** | Moonwalk Host is getting ready. |
| **Ready** | Your other devices can connect. |
| **Ready to Resume** | You disconnected, and your Desktop is waiting for you. |
| **Streaming to …** | A device is connected. It shows the device, the picture size and the video format. |
| **Not Running** or **Can't Verify Moonwalk Host** | The service isn't reachable or couldn't be confirmed. See [troubleshooting](../TROUBLESHOOTING.md#the-menu-says-not-running-or-cant-verify-moonwalk-host). |

Below that are **Finish Setup…** until setup is complete, then **Pair New Device…** (with a dot when a device is asking), **Settings…** and **Quit Moonwalk Host**.

## The Settings window

Some changes apply straight away. Others show **Some changes take effect after Moonwalk Host restarts**, with a **Restart Now** button. Restarting ends the current stream.

### Status

| Item | What it does |
| --- | --- |
| **Streaming service** and **Streaming** | Show whether everything is running, and who's connected. |
| **End Current Session…** | Disconnects the current device. It stays paired. |
| **Devices & Permissions** | Shows how many devices are paired and which permissions are granted. |
| **Check Permissions…** | Reopens the permission checklist. |
| **Restart Moonwalk Host…** | The first thing to try when something's wrong. Ends the current stream. |
| **Name devices see** | The name clients list for this Mac, after Moonwalk Host restarts, unless you've renamed the Mac in the client. |
| **Open Moonwalk Host at Login** | Starts Moonwalk Host when you log in. |
| **About Moonwalk Host** | Shows the versions, and **View Releases…** opens the download page. |
| **Support** | **Diagnostics and maintenance** has diagnostics, repair and uninstall. |
| **Saved Setups** | Names a copy of your settings so you can go back to it. Paired devices aren't included. |

### Streaming

| Item | What it does |
| --- | --- |
| **Video codec** | The video format. The shipped defaults offer H.264. Choosing HEVC offers that to your device too, which can look sharper at the same bitrate, and your device decides which to use. **Automatic** offers every format this Mac can encode, so HEVC may be used. |
| **Stream this Mac's sound** | Turn this off for a silent stream. |
| **Sound source** | **This Mac's system audio** is recommended, and streams in stereo. You can choose an input device instead, which needs Microphone permission. |
| **Test Sound** | A two-second test of the source, which plays and saves nothing. Not available during a stream. |

Under **Advanced**:

| Item | What it does |
| --- | --- |
| **Video engine** | **Hardware** uses the Mac's video encoder and is the right choice for nearly everyone. **Software** uses the processor. |
| **Low-latency encoding** | Prefers less delay. |
| **Keep motion smooth when the screen is still** | Keeps sending at least 30 frames a second when nothing is changing. |

### Display

**Virtual display** is on by default. When you connect, Moonwalk Host asks macOS for a virtual display based on the client’s requested size and refresh rate. It tries to make the virtual display primary and restore the physical display arrangement when the stream ends.

Turn it off to share an existing screen, then choose one under **Capture display** in **Advanced**.

### Devices

| Item | What it does |
| --- | --- |
| **Current Connection** | Appears while streaming. Shows who's connected. |
| **Paired Devices** | Lists every paired device, with **Unpair** for each, **Pair New Device…** and **Unpair All Devices…**. |
| **Allow keyboard control** and **Allow mouse control** | Stop keyboard and mouse input, for all devices. A controller on your device can still press keys and move the pointer. |
| **End session when the last device disconnects** | Off means your Desktop stays ready to resume. |
| **Share clipboard with devices** | On by default. Works during a stream, with a client that supports it. |

### Network

This page shows your Mac's addresses, each with a **Copy** button, for adding it to another device by hand. Most people don't need anything else here.

Under **Advanced**:

| Item | What it does |
| --- | --- |
| **Local network encryption** | **Off** by default: video isn't encrypted, and sound is encrypted if the client asks. **Optional**: video is encrypted if the client asks. **Required**: video and sound are always encrypted, and clients that can't are refused. |
| **Internet encryption** | The same, for connections from outside your network. **Optional** by default. |
| **Set up router automatically (UPnP)** | Off by default. It asks your router to open Moonwalk Host's ports to the internet, so leave it off. |
| **Base port** | Moves all of Moonwalk Host's ports. Clients need to know the new port. |
| **Web configuration page** | Off by default. An older settings page in a browser, which most people never need. |
| **Allow IPv6 connections** | Allows connections using IPv6, the newer style of network address. |

---

[Performance](performance.md) · [All guides](README.md)
