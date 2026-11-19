#!/usr/bin/env python3
"""Write shareable source and checksum information for a verified Moonwalk Host DMG."""

import argparse
import hashlib
import json
from pathlib import Path
import re


def make_receipt(manifest, image):
    if manifest["status"] != "complete" or manifest["git"]["dirty"] is not False:
        raise ValueError("the manifest must describe a completed build from clean source")
    if manifest["notarization"]["status"] != "Accepted":
        raise ValueError("Apple must have accepted the candidate for notarization")

    revision = manifest["git"]["commit"]
    version = manifest["version"]
    minimum_macos = manifest["deploymentTarget"]
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("expected a full source commit")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[a-zA-Z0-9]+(?:[.-][a-zA-Z0-9]+)*)?", version):
        raise ValueError("invalid product version")
    if not re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", minimum_macos):
        raise ValueError("invalid macOS deployment target")

    architecture = manifest["architecture"]
    if architecture != "arm64" or image.name != f"Moonwalk-Host-{version}-macOS-{architecture}.dmg":
        raise ValueError("the DMG filename and architecture must match the manifest")

    digest = hashlib.sha256()
    size = 0
    with image.open("rb") as contents:
        for block in iter(lambda: contents.read(1024 * 1024), b""):
            digest.update(block)
            size += len(block)
    if not size or digest.hexdigest() != manifest["artifact"]["sha256"]:
        raise ValueError("the DMG checksum differs from the verified candidate")

    return {
        "product": "Moonwalk Host",
        "version": version,
        "source_commit": revision,
        "minimum_macos": minimum_macos,
        "architecture": architecture,
        "artifact": {"name": image.name, "size_bytes": size, "sha256": digest.hexdigest()},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path, help="local release-manifest.json from scripts/release.sh")
    parser.add_argument("dmg", type=Path, help="the final, stapled DMG")
    args = parser.parse_args()
    try:
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
        receipt = make_receipt(manifest, args.dmg)
    except (OSError, TypeError, KeyError, ValueError) as error:
        parser.exit(1, f"Could not create a release receipt: {error}\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
