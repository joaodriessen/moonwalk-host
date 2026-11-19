# Contribute to Moonwalk Host

A clear report is often enough to get a fix started. Include the host version, macOS version, client and version, and whether the Mac uses a physical or virtual display. Describe what you did and what you expected. If it worked in an earlier version, include that version. [Issue forms](https://github.com/joaodriessen/moonwalk-host/issues/new/choose)

Review logs and images before sharing them. Use fictional device names and addresses, and leave out pairing data, credentials and account details. For vulnerabilities, follow the [security policy](SECURITY.md).

## Make a change

- Follow the [build guide](docs/BUILDING.md) and run the checks locally while
  Actions is disabled. Changes to display, audio, permissions, or pairing also
  need a live test on a Mac.
- For daemon/menu changes, keep the trusted XPC peer requirements tied to the same release identity. For defaults or settings, check both the C++ parser and the Swift UI. [Architecture](docs/architecture.md)
- Add a focused regression test when an existing test would miss the bug. In the pull request, describe what you verified and what needs a live check.
- Use a GitHub no-reply or project email in commits before pushing. Run the privacy check on the staged changes. Build outputs, diagnostics and personal test data belong outside the repository.
