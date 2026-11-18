# VideoToolbox patches

The macOS build compiles FFmpeg from a pinned archive and applies these patches in the order set by `scripts/release/build-ffmpeg.sh`.

- **`ffmpeg-vtenc-sync-output.patch`** adds synchronous output and an optional wait deadline. A bounded in-flight queue limits how far encoded frames can fall behind submissions during overload.
- **`ffmpeg-vtenc-completion.patch`** lets the caller collect a completed packet without submitting another frame. Between-capture polling is excluded from the default streaming path.
- **`ffmpeg-vtenc-live-bitrate.patch`** lets the host update the bitrate target on an existing VideoToolbox session. The next input frame applies the new target.

The build script verifies source and patch hashes and records the built library hash. The macOS CMake build verifies any caller-supplied prepared tree. If you change the FFmpeg revision, confirm that all patches apply without fuzz, run the linked encoder logic tests and compare live capture and encode cadence. For sync output, also test end-of-stream behavior if you reuse the patch outside this host. The host discards tail packets during session teardown.
