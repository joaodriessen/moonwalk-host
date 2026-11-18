# Qt transfer response closure regression

This opt-in loopback probe links the actual Starlight `FileTransfer` and `NvHTTP`
sources. It uploads and downloads a Unicode file of 2 MiB + 37 bytes with exact
byte/hash checks, then exercises complete 403/409/500/503 responses followed by a
successful transfer. Its TLS fixture delays planned closure by 10 ms: omitting
`Connection: close` reproduces a Qt `RemoteHostClosedError`; declaring closure
lets the client complete each operation. The preflight `/serverinfo` response,
file successes and file errors all declare closure in the positive cases.

The probe models the response contract; it does not invoke the installed host,
its authenticated session/ownership guards, or any capture/clipboard/input APIs.
A final installed-pair test is needed to verify the production route wiring.
It creates fresh identity credentials, files and a self-signed TLS certificate
inside temporary directories and removes them afterwards. Detailed output is
written only to the caller's new output directory. No paired identity is used.

Build with an existing Starlight checkout/common library and the Qt/OpenSSL/SDL2
build dependencies already used by that checkout:

```sh
mkdir /tmp/qt-transfer-close-build
cd /tmp/qt-transfer-close-build
qmake6 /path/to/skylight/tests/probes/qt_file_transfer_close/worker.pro \
  STARLIGHT_SOURCE=/path/to/starlight-src \
  COMMON_LIBRARY=/path/to/existing/libmoonlight-common-c.a
make -j2
python3 /path/to/skylight/tests/probes/qt_file_transfer_close/fixture.py \
  --worker ./qt-file-transfer-close-worker \
  --output /tmp/qt-transfer-close-results --require-red
```

`--require-red` verifies the negative timing control too. Without it, the positive
contract remains required and `legacy_reproduced` reports whether that Qt/TLS
build exhibited the legacy race. The `.cc` probe is intentionally outside the
host's ordinary `tests/*.cpp` test executable: this is a separate Qt integration
program and must not introduce another `main()` into the host suite.

Protocol basis: [RFC 9112 §9.3](https://www.rfc-editor.org/rfc/rfc9112.html#section-9.3)
and [§9.6](https://www.rfc-editor.org/rfc/rfc9112.html#section-9.6). HTTP/1.1 defaults
to persistent connections; a response that plans to close must advertise that
choice so the recipient does not reuse the connection for its next request.
