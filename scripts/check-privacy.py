#!/usr/bin/env python3
"""Check the Git index or an exact commit for common private material."""
import argparse
from hashlib import sha256
from pathlib import PurePosixPath
import re
import struct
import subprocess
import sys

CREDENTIAL = re.compile(rb"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[A-Z0-9]{16}|"
                        rb"sk-(?:proj-)?[A-Za-z0-9_-]{30,}|xox[baprs]-[A-Za-z0-9-]{15,})\b")
PRIVATE_KEY = re.compile(rb"-----BEGIN ([A-Z ]*PRIVATE KEY)-----\r?\n[A-Za-z0-9+/=]{24,}")
PAIRING_TEST = PurePosixPath("tests/unit/test_http_pairing.cpp")
PAIRING_TEST_KEY_SHA256 = "cb3c1dd0b7418aebd91109a35b867dfeb45e5be0db3499ba4ba69db7b42c500b"
PRIVATE_PATH = re.compile(rb"(?i)(?:/home/|/Users/|[A-Z]:[/\\]Users[/\\])([\w.-]+)[/\\]")
EXAMPLE_HOME = {b"builder", b"example", b"someone", b"alice", b"bob", b"myuser"}
PRIVATE_FILES = re.compile(r"(?i)(?:\.(?:env|pfx|p12|key|etl|pcapng?|log|sqlite3?|dmg|keychain-db|ips)$|^\.env\.|"
                           r"^(?:credentials\.json|known_hosts|id_(?:rsa|ecdsa|ed25519|dsa))$)")
PRIVATE_DIRS = {".claude", ".codex", ".ssh", ".gnupg", ".superpowers"}
PNG = b"\x89PNG\r\n\x1a\n"
PNG_PRIVATE_CHUNKS = {b"eXIf", b"tEXt", b"iTXt", b"zTXt"}
PROJECT_EMAIL = re.compile(rb"(?:[A-Za-z0-9._+\[\]-]+@users\.noreply\.github\.com|"
                           rb"noreply@github\.com|[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.invalid)")


def check_blob(data, path=None):
    if data.startswith(PNG):
        offset = len(PNG)
        while offset + 12 <= len(data):
            length, kind = struct.unpack_from(">I4s", data, offset)
            offset += 12 + length
            if kind in PNG_PRIVATE_CHUNKS:
                yield "PNG text or EXIF metadata"
            if kind == b"IEND":
                if offset != len(data):
                    yield "malformed PNG or data after IEND"
                return
        yield "invalid PNG"
        return
    if CREDENTIAL.search(data):
        yield "possible credential"
    for key in PRIVATE_KEY.finditer(data):
        end_marker = b"-----END " + key[1] + b"-----"
        end = data.find(end_marker, key.end())
        if (path == PAIRING_TEST and end != -1
                and sha256(data[key.start():end + len(end_marker)]).hexdigest() == PAIRING_TEST_KEY_SHA256):
            continue
        yield "possible private key"
    normalized = data.replace(b"\\\\", b"\\")
    if any(match[1].lower() not in EXAMPLE_HOME for match in PRIVATE_PATH.finditer(normalized)):
        yield "personal home path"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--commit", help="check the tree and metadata of a commit instead of the index")
    parser.add_argument("--show-paths", action="store_true", help="include filenames in local findings")
    args = parser.parse_args()
    git = ["git", "-C", str(PurePosixPath(__file__).parent.parent)]
    errors = 0

    def report(reason, path):
        nonlocal errors
        errors += 1
        # Avoid repeating sensitive names in hosted workflow logs.
        where = f": {path}" if args.show_paths else ""
        print(f"Privacy check: {reason}{where}", file=sys.stderr)

    if args.commit:
        commit = subprocess.check_output(git + ["rev-parse", "--verify", "--end-of-options",
                                                f"{args.commit}^{{commit}}"], text=True).strip()
        addresses = subprocess.check_output(git + ["show", "-s", "--format=%ae%n%ce", commit]).splitlines()
        if len(addresses) != 2 or not all(PROJECT_EMAIL.fullmatch(address) for address in addresses):
            report("use a GitHub no-reply address or a project .invalid address", "commit metadata")
        for reason in check_blob(subprocess.check_output(git + ["cat-file", "commit", commit])):
            report(reason, "commit metadata")
        command = ["ls-tree", "-rz", "--full-tree", commit]
    else:
        command = ["ls-files", "--stage", "-z"]
    entries = subprocess.check_output(git + command).split(b"\0")

    with subprocess.Popen(git + ["cat-file", "--batch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE) as batch:
        for entry in filter(None, entries):
            stat, raw_path = entry.split(b"\t", 1)
            mode, first, last = stat.split()
            oid = last if args.commit else first
            path = PurePosixPath(raw_path.decode(errors="surrogateescape"))
            if PRIVATE_DIRS.intersection(path.parts) or PRIVATE_FILES.search(path.name):
                report("private file or directory", path)
            if not args.commit and last != b"0":
                report("unresolved index conflict", path)
                continue
            if mode == b"160000":
                report("unexpected submodule; this repository vendors its dependencies", path)
                continue
            batch.stdin.write(oid + b"\n")
            batch.stdin.flush()
            _, kind, length = batch.stdout.readline().split()
            assert kind == b"blob"
            data = batch.stdout.read(int(length))
            assert batch.stdout.read(1) == b"\n"
            for reason in check_blob(data, path):
                report(reason, path)
        batch.stdin.close()
        if batch.wait() != 0:
            return 1
    if errors:
        print(f"{errors} privacy findings. Review locally with --show-paths.", file=sys.stderr)
        return 1
    print("Commit privacy checks passed." if args.commit else "Staged privacy checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
