# Release checklist

Build from a clean commit with the [release command](BUILDING.md#build-a-tester-installer). Preserve the bundle and signing identifiers for upgrades. The command produces a local DMG, so release uploads and visibility changes are separate steps.

## Source and distribution

- Review all Git refs and their metadata. Check the exact tree with `python3 scripts/check-privacy.py --commit HEAD`. Check screenshots, archives, GitHub assets and logs separately. Verify the [public pairing fixture](test-fixtures.md) by fingerprint.
- Confirm that a clean Apple Silicon checkout builds with the documented dependencies. Check the actual signed package against the [dependency sources and licenses](third-party.md), including patches used by FFmpeg. Keep the corresponding source available to the recipients of the DMG.
- Review issues, pull requests and attachments for private data. Prepare a [private reporting route](../SECURITY.md). GitHub offers its form on public repositories. If using it, enable it and verify it from a non-maintainer account as soon as the repository is public, before announcing it. Check anonymous source access at the same time. [GitHub setup guide](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository)
- Inspect the Developer ID name embedded in the app and DMG signatures before sharing either artifact. macOS exposes that name through the signatures. The checksum receipt omits it. Review source visibility and installer distribution separately.
- Set the intended version in `macos-dist/skylight-identity.conf` and record the changes. Keep the source commit, checksum, release manifest and verified DMG together. Retain a previously tested signed DMG for rollback.

## Share an installer checksum

Use the release manifest and the exact final DMG to generate a receipt. It
records the source commit and verifies the image checksum before writing the
shareable fields. Keep the original manifest and signing logs local.

```sh
python3 scripts/release/make-release-receipt.py /path/to/release-manifest.json \
  /path/to/Moonwalk-Host-0.4.0-alpha.16-macOS-arm64.dmg > release-receipt.json
```

Once the release is approved, attach the receipt next to that DMG. It lists
the SHA-256 users can compare after downloading. The DMG’s Developer ID
signature and stapled notarization ticket are checked by the release command.

## Installer and live qualification

| Exercise | What to verify |
| --- | --- |
| Fresh install from DMG | Gatekeeper accepts the stapled DMG, setup reaches Ready, and denying or revoking permissions produces a clear recovery path |
| Upgrade and rollback | Existing pairing, settings and macOS permission grants survive the supported upgrade. Test the previous DMG when documenting a downgrade |
| Ordinary connection | Pair with Moonwalk and with a standard Moonlight client. Verify desktop, UI scale, keyboard and mouse, sound and actual frame cadence |
| Session end and interruption | Check release of live resources and physical display restoration after disconnect, failed launch and abrupt client or host exit |
| Display and OS coverage | Test the minimum macOS version and a newer release, with a single physical screen, a headless Mac and a multi-display arrangement |
| Disable and remove | Quit stops the service. Login item removal, data-preserving service removal and full uninstall match the guide |

Record the Mac, OS, client, source revision and artifact hash with each result. Use the [compatibility page](compatibility.md) to reflect measured coverage. A hosted build exercises the native code and logic tests. It takes a real logged-in session to qualify capture, prompts, input and restoration.

## Maintenance

Review Actions and npm updates through CI. The C++ dependencies in `third-party/` are vendored. Update those sources and package dependencies against their upstream releases, with license and build checks. Run release signing on a maintainer-controlled Mac. Keep credentials out of pull request workflows and review artifacts before attaching them to a release.
