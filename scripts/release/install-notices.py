#!/usr/bin/env python3
"""Copy the licenses for the native libraries and web assets in the release."""
import argparse
import json
from pathlib import Path
import shutil


def copy_notice(source, destination):
    if not source.is_file() or not source.stat().st_size:
        raise ValueError(f"missing license: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)


def one_license(directory, pattern):
    matches = list(directory.glob(pattern))
    if len(matches) != 1:
        raise ValueError(f"expected one {pattern} in {directory}")
    return matches[0]


def install(repo, dependencies, ffmpeg, build, destination):
    sources = dependencies / "sources"
    native = {
        "openssl/LICENSE.txt": one_license(sources, "openssl-*/LICENSE.txt"),
        "opus/COPYING": one_license(sources, "opus-*/COPYING"),
        "miniupnpc/LICENSE": one_license(sources, "miniupnpc-*/LICENSE"),
        "ffmpeg/COPYING.GPLv2": one_license(ffmpeg, "ffmpeg-*/COPYING.GPLv2"),
        "ffmpeg/COPYING.LGPLv2.1": one_license(ffmpeg, "ffmpeg-*/COPYING.LGPLv2.1"),
        "boost/LICENSE_1_0.txt": build / "_deps/boost-src/LICENSE_1_0.txt",
        "nlohmann-json/LICENSE.MIT": build / "_deps/json-src/LICENSE.MIT",
        "simple-web-server/LICENSE": repo / "third-party/Simple-Web-Server/LICENSE",
        "enet/LICENSE": repo / "third-party/moonlight-common-c/enet/LICENSE",
        "libdisplaydevice/LICENSE": repo / "third-party/libdisplaydevice/LICENSE",
        "nanors/LICENSE": repo / "third-party/nanors/LICENSE",
        "tray/LICENSE": repo / "third-party/tray/LICENSE",
    }
    for name, source in native.items():
        copy_notice(source, destination / "native" / name)
    upstream = repo / "licenses/upstream"
    for name in ("x264", "x265", "svt-av1"):
        for source in sorted((upstream / name).iterdir()):
            copy_notice(source, destination / "native" / name / source.name)

    lock = json.loads((repo / "package-lock.json").read_text())
    for directory, package in lock["packages"].items():
        if not directory or package.get("dev"):
            continue
        installed = repo / directory
        name = installed.relative_to(repo / "node_modules")
        notices = [p for p in sorted(installed.iterdir()) if p.is_file()
                   and p.name.upper().startswith(("LICENSE", "COPYING", "NOTICE"))]
        if not notices and name.as_posix() == "@vue/devtools-api" and package["version"] == "6.6.4":
            notices = [upstream / "vue-devtools-api/LICENSE"]
        if not notices:
            raise ValueError(f"no license found for {name} {package['version']}")
        for source in notices:
            copy_notice(source, destination / "web" / name / source.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dependencies", type=Path)
    parser.add_argument("ffmpeg", type=Path)
    parser.add_argument("build", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        install(Path(__file__).resolve().parents[2], args.dependencies, args.ffmpeg,
                args.build, args.destination)
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"Could not package third-party notices. {error}\n")


if __name__ == "__main__":
    main()
