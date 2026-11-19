#!/bin/bash
set -euo pipefail

usage() { echo "Usage: $0 [--repo-only | --team-id TEAMID APP]"; }
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --repo-only)
    [ "$#" -eq 1 ] || { usage >&2; exit 64; }
    # Validate release facts and local navigation, independent of headings or prose length.
    python3 - "$REPO" <<'PY'
import pathlib
import re
import subprocess
import sys
import urllib.parse

repo = pathlib.Path(sys.argv[1]).resolve()

def fail(message):
    sys.exit(f"ERROR: {message}")

try:
    tracked = subprocess.check_output(["git", "-C", str(repo), "ls-files", "-z"], text=True)
except (OSError, subprocess.CalledProcessError) as error:
    fail(f"cannot check tracked private paths: {error}")
for name in tracked.split("\0"):
    path = pathlib.PurePosixPath(name)
    if ({".claude", ".codex", ".ssh", ".gnupg"}.intersection(path.parts)
            or path.name in {".env", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "credentials.json"}):
        fail(f"private local state must not be tracked: {name}")

documents = ["README.md", "CONTRIBUTING.md", "SECURITY.md", "CHANGELOG.md",
             "docs/INSTALL.md", "docs/BUILDING.md", "macos-dist/README.md"]
documents += [str(p.relative_to(repo)) for p in sorted((repo / "docs").rglob("*.md"))
              if str(p.relative_to(repo)) not in documents]
texts = {}
for name in documents:
    path = repo / name
    if not path.is_file():
        fail(f"missing release document {name}")
    text = path.read_text()
    texts[name] = text
    # Inline Markdown links and images: external URLs need no network during this audit.
    targets = re.findall(r"!?\[[^\]]*\]\(([^\s)]+)(?:\s+[^)]*)?\)", text)
    targets += re.findall(r'\b(?:src|srcset)="([^"]+)"', text)
    for target in targets:
        target = target.strip("<>")
        url = urllib.parse.urlsplit(target)
        if url.scheme or url.netloc or not url.path:
            continue
        linked = (path.parent / urllib.parse.unquote(url.path)).resolve()
        if not linked.is_relative_to(repo) or not linked.exists():
            fail(f"broken local link in {name}: {target}")

readme = texts["README.md"]
install = texts["docs/INSTALL.md"]
for label, pattern, text in [
    ("alpha status", r"\balpha\b", readme),
    ("Apple Silicon support", r"\bApple\s+Silicon\b", readme),
    ("macOS minimum", r"\bmacOS\s+14\s+or\s+(?:later|newer)\b", readme),
    ("signed and notarized DMG installation", r"\bsigned\s+and\s+notarized\s+DMG\b", readme),
    ("Screen Recording permission", r"\bScreen\s+Recording\b", install),
    ("Accessibility permission", r"\bAccessibility\b", install),
]:
    if not re.search(pattern, text, re.IGNORECASE):
        fail(f"release documentation is missing {label}")
for target in ("docs/INSTALL.md", "CONTRIBUTING.md", "SECURITY.md"):
    if not re.search(r"\]\(" + re.escape(target) + r"(?:[# )])", readme):
        fail(f"README is missing navigation to {target}")
PY
    for file in help.yml bug.yml feature.yml config.yml; do
      [ -f "$REPO/.github/ISSUE_TEMPLATE/$file" ] || { echo "ERROR: missing issue template $file" >&2; exit 1; }
    done
    echo "repository release verification: PASS"
    exit 0
    ;;
  --team-id)
    [ "$#" -eq 3 ] || { usage >&2; exit 64; }
    TEAM_ID="$2"; APP="$3"
    "$DIR/tests/test-app-layout.sh" "$APP"
    "$DIR/audit-dependencies.sh" "$APP"
    "$DIR/audit-signing.sh" --team-id "$TEAM_ID" "$APP"
    if rg -a -l '/opt/homebrew|/opt/local|/Users/[^/]+/Projects/Skylight|Skylight Local Signing' "$APP" | grep -q .; then
      echo "ERROR: local build path or identity leaked into app" >&2
      exit 1
    fi
    echo "artifact verification: PASS"
    ;;
  *) usage >&2; exit 64 ;;
esac
