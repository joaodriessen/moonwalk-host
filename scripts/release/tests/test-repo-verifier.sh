#!/bin/bash
set -euo pipefail

SOURCE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO/scripts/release" "$REPO/docs" "$REPO/macos-dist" \
  "$REPO/.github/ISSUE_TEMPLATE" "$REPO/.github/workflows"
cp "$SOURCE_REPO/scripts/release/verify-artifact.sh" "$REPO/scripts/release/"
cp "$SOURCE_REPO/README.md" "$SOURCE_REPO/CONTRIBUTING.md" "$SOURCE_REPO/SECURITY.md" "$SOURCE_REPO/CHANGELOG.md" \
  "$SOURCE_REPO/LICENSE" "$SOURCE_REPO/NOTICE" "$REPO/"
cp "$SOURCE_REPO/docs/"*.md "$REPO/docs/"
cp -R "$SOURCE_REPO/docs/guides" "$REPO/docs/guides"
cp -R "$SOURCE_REPO/docs/assets" "$REPO/docs/assets"
cp "$SOURCE_REPO/.github/ISSUE_TEMPLATE/"*.yml "$REPO/.github/ISSUE_TEMPLATE/"
cp "$SOURCE_REPO/.github/workflows/build.yml" "$REPO/.github/workflows/"
cp "$SOURCE_REPO/macos-dist/README.md" "$REPO/macos-dist/"
git -C "$REPO" init -q
git -C "$REPO" add .

verify() { bash "$REPO/scripts/release/verify-artifact.sh" --repo-only; }
expect_failure() {
  if verify > "$WORK/failure.log" 2>&1; then
    echo "FAIL: accepted $1" >&2
    exit 1
  fi
  grep -Fq "$2" "$WORK/failure.log" || { cat "$WORK/failure.log" >&2; exit 1; }
}

# Check the actual release documents before introducing invalid fixtures.
verify
mkdir -p "$REPO/local/.codex"
printf 'synthetic fixture\n' > "$REPO/local/.codex/session.jsonl"
git -C "$REPO" add local/.codex/session.jsonl
expect_failure 'tracked private agent state' 'private local state must not be tracked'
git -C "$REPO" rm -q -f local/.codex/session.jsonl
printf 'synthetic fixture\n' > "$REPO/.env"
git -C "$REPO" add .env
expect_failure 'tracked environment credentials' 'private local state must not be tracked'
git -C "$REPO" rm -q -f .env
printf 'EXAMPLE=placeholder\n' > "$REPO/.env.example"
git -C "$REPO" add .env.example
verify
cp "$REPO/README.md" "$WORK/readme"
printf '\nNo Intel Mac or internet streaming support; no auto-update.\n' >> "$REPO/README.md"
verify

# Headings and line count are presentation choices, not release facts.
python3 - "$REPO/README.md" <<'PY'
import pathlib
import sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace("## Try it", "## Getting started") + "\n" * 110)
PY
verify

printf '\n[Missing image](docs/missing.png)\n' >> "$REPO/README.md"
expect_failure 'a broken local asset link' 'broken local link'
cp "$WORK/readme" "$REPO/README.md"

printf '\n<img src="docs/missing.png">\n' >> "$REPO/README.md"
expect_failure 'a broken HTML screenshot' 'broken local link'
cp "$WORK/readme" "$REPO/README.md"

cp "$REPO/docs/guides/settings.md" "$WORK/settings.md"
printf '\n[Missing guide](missing.md)\n' >> "$REPO/docs/guides/settings.md"
expect_failure 'a broken guide link' 'broken local link'
cp "$WORK/settings.md" "$REPO/docs/guides/settings.md"

python3 - "$REPO/README.md" <<'PY'
import pathlib
import sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace("Apple Silicon", "Intel"))
PY
expect_failure 'an unsupported platform scope' 'Apple Silicon support'
cp "$WORK/readme" "$REPO/README.md"

mv "$REPO/docs/INSTALL.md" "$WORK/install"
expect_failure 'missing installation instructions' 'broken local link'
mv "$WORK/install" "$REPO/docs/INSTALL.md"
mv "$REPO/.github/ISSUE_TEMPLATE/bug.yml" "$WORK/bug.yml"
expect_failure 'a missing issue template' 'missing issue template bug.yml'
mv "$WORK/bug.yml" "$REPO/.github/ISSUE_TEMPLATE/bug.yml"
verify
echo 'PASS: repository release facts, navigation, layout independence and negative scope mentions'
