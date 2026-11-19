# Build Moonwalk Host

Build on an Apple Silicon Mac running macOS 14 or later. You need Xcode with its command-line tools and Homebrew. CI uses macOS 15. See [Install](INSTALL.md) for the signed tester package.

Pull requests that only change the web settings build on Linux. Changes that
affect the daemon, menu app or shared settings schema also build on macOS.
Pushes to main and manual workflow runs exercise both.

```sh
git clone https://github.com/joaodriessen/moonwalk-host.git
cd moonwalk-host
brew install cmake boost pkg-config openssl@3 opus llvm doxygen graphviz node icu4c@78 miniupnpc
git config core.hooksPath .githooks
./scripts/build-dev.sh --prefix "$PWD/build/dev"
```

The developer script creates a local signing identity in your login Keychain, generates the XPC requirements and assembles `build/dev/Skylight.app`. With `--prefix` it skips installation and service registration. Run it on a development Mac. To reproduce the configure flags used in hosted tests, see [the build workflow](../.github/workflows/build.yml).

## Tests and repository checks

```sh
swift test --package-path macos-dist/SkylightMenu
bash scripts/release/verify-artifact.sh --repo-only
bash scripts/release/tests/test-repo-verifier.sh
python3 scripts/check-privacy.py
```

Generate the local identity with `bash macos-dist/generate-identity.sh` before building the Swift package by itself. For C++, configure with `-DBUILD_TESTS=ON`, build the `test_sunshine` target and run the binary under `build/tests/`. CI runs it with a temporary configuration directory and excludes fixtures that move the pointer, capture audio or exercise real encoders. Use a dedicated Mac for those cases and for live session tests.

## Build a tester installer

Run from a clean Git checkout with a Developer ID Application certificate and an existing `notarytool` Keychain profile:

```sh
./scripts/release.sh \
  --identity "Developer ID Application: Name (TEAMID)" \
  --notary-profile "test-notary-profile" \
  --quiet
```

The command tests and builds the recorded commit in isolation. It signs and notarizes the app before packing it into a signed, notarized DMG. It then mounts the DMG and checks the app inside. The DMG, stage logs and provenance manifest are written under `build/releases/`. Use `--resume` with the same inputs to continue a build after interruption. Keep signing material and the local output outside Git. [Release checklist](releasing.md)
