# From private alpha to public release

Moonwalk Host has its own installer and macOS qualification. Moonwalk for Linux has its own packaging and release cycle. Use the [compatibility guide](compatibility.md) for features that depend on both ends.

1. **Establish the source repo.** Verify a clean clone, macOS CI, project links, upstream attribution and the privacy of every ref and asset. Keep old tester builds and working history in the original private repository.
2. **Qualify an installer.** Build the candidate from an exact commit, sign and notarize it, and test install, upgrade and removal. Keep the tested DMG and its checksum with the source revision.
3. **Test the stream on real Macs.** Cover the minimum macOS version and a newer version, a monitor and headless use, Moonwalk and a standard Moonlight client, and display restoration after a disconnect or failure.
4. **Prepare support.** Verify the private vulnerability reporting route and record which environments passed. Publish only after a visibility decision.

See the [release checklist](releasing.md) for the evidence each step needs.
