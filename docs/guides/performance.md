# Diagnose a choppy stream

Start with a moving window or a scrolling page. Compare the frame rate you
requested with what the client receives and renders. That helps narrow down
where the stream is falling behind.

1. **Use Moonwalk’s Automatic mode if available.** It starts from the local display. Compatible versions can lower bitrate on the running stream when the link is struggling. A different codec, refresh rate or resolution generally takes effect when you connect again.
2. **Compare the stream during steady motion.** A still desktop is a poor frame-rate test. Record the requested resolution and frame rate, delivered frames, network drops and decode time if your client shows these figures.
3. **Compare Ethernet and Wi-Fi if possible.** Loss and jitter can cause stutter even on a connection with a high average transfer rate.
4. **Keep the host Video engine on Hardware.** See **Settings → Streaming → Advanced**. If the client supports HEVC, compare it with H.264 at the same resolution, frame rate and bitrate. Change one setting at a time.

The client requests a bitrate and the host caps it at 80 Mbps by default.
Lowering bitrate can help on a congested link. If the host is already sending
too few frames on a clean link, compare encoder settings before changing the
desktop resolution.

If you report a problem, include the Mac model, macOS and client versions, display mode, codec, and what was moving when the stream stuttered. Remove your host names, addresses and personal data from screenshots and diagnostics. [Troubleshooting](../TROUBLESHOOTING.md)
