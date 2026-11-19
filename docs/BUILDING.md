# Build Moonwalk Host

Build on an Apple Silicon Mac running macOS 14 or later. You need Xcode with its command-line tools and Homebrew. CI uses macOS 15. See [Install](INSTALL.md) for the signed tester package.

Pull requests that only change the web settings build on Linux. Changes that
affect the daemon, menu app or shared settings schema also build on macOS.
Pushes to main and manual workflow runs exercise both.

```sh
git clone https://github.com/joaodriessen/moonwalk-host.git
cd moonwalk-host
brew install cmake pkg-config node openssl@3
git config core.hooksPath .githooks
./scripts/build-dev.sh
```

The developer script builds the pinned native dependencies, creates a local signing identity in your login Keychain, and assembles `build/dev/Skylight.app` with the same service layout as the release bundle. It leaves installation and service registration to you. Use a dedicated Mac if you want to run the app from Applications. The developer and release bundles normally share an identity in macOS, and switching signers can require permissions again. See [the build workflow](../.github/workflows/build.yml) for the configuration used in hosted tests.

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

The command tests and builds the recorded commit in isolation. It signs and notarizes the app before packing it into a signed, notarized DMG. It then mounts the DMG and checks the app inside. The DMG, stage logs and local manifest are written under `build/releases/`. Use `--resume` with the same inputs to continue a build after interruption. The [release checklist](releasing.md#share-an-installer-checksum) shows how to generate shareable source and checksum information.

Builds in the same checkout reuse the downloaded FFmpeg archives after
verifying their checksums. A prepared FFmpeg build is checked against its
recipe, compiler, SDK and the hashes of its static libraries before reuse.
