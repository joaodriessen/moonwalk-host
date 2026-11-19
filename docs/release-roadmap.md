# From private alpha to public release

Moonwalk Host has its own installer and macOS qualification. Moonwalk for Linux has its own packaging and release cycle. Use the [compatibility guide](compatibility.md) for features that depend on both ends.

1. **Prepare the source.** Check a clean clone, project links, upstream credits,
   and the history and assets that will become public. Keep old tester builds
   and working history in the original private repository. Run the local build
   before opening the repository, then check hosted CI when Actions is enabled.
2. **Qualify an installer.** Build the candidate from an exact commit, sign and notarize it, and test install, upgrade and removal. Keep the tested DMG and its checksum with the source revision.
3. **Test the stream on real Macs.** Cover the minimum macOS version and a newer version, a monitor and headless use, Moonwalk and a standard Moonlight client, and display restoration after a disconnect or failure.
4. **Prepare support.** Verify the private vulnerability reporting route and record which environments passed. Publish only after a visibility decision.

See the [release checklist](releasing.md) for the evidence each step needs.
