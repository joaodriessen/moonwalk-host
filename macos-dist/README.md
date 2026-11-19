# macOS app and installer

This directory contains the Swift menu bar app, the service templates, the shipped defaults and the signing configuration. Start with the [build guide](../docs/BUILDING.md) for an isolated developer build or a Developer ID release.

- `SkylightMenu/` is the Swift package for the menu bar app and its tests.
- `skylight-identity.conf` defines the default bundle identifiers, signing and service names, and packaged version. The gitignored `skylight-identity.local.conf` is for intentional local development overrides.
- `generate-identity.sh` generates ignored Swift and C++ files with the peer requirements used during XPC authentication.
- `../scripts/build-dev.sh` assembles the current developer bundle in `build/dev`. The older `make-bundle.sh` supports the legacy standalone menu and service layout.
- `sunshine.conf.example` contains the defaults used when setting up the packaged host. The installer resources and entitlements must agree with the signer and host binaries.
- `tests/` includes checks for the schema and scripts that exercise a running host. Use a dedicated test Mac for tests that launch streams or change displays.

The existing `Skylight.app` name and bundle identifiers are the upgrade contract. See the [architecture](../docs/architecture.md) and [bundle layout](../docs/release-surface.md) before changing them.
