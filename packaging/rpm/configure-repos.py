#!/usr/bin/env python3
"""Point an AlmaLinux build root at the matching x86_64_v2 repositories.

The appliance composes from AlmaLinux 10.2 x86_64_v2 packages behind the
Aliyun mirror.  The RPM build must use the same package set, so this rewrites
the base repository files before build dependencies are installed.
"""

from __future__ import annotations

import argparse
import configparser
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

REPOSITORIES = {
    "baseos": "BaseOS",
    "appstream": "AppStream",
    "crb": "CRB",
    "extras": "extras",
}
ARCH = "x86_64_v2"


def read_release(root: Path) -> dict[str, str]:
    release = {}
    for line in (root / "etc/os-release").read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            release[key] = value.strip().strip('"')
    if release.get("ID") != "almalinux":
        raise ValueError("repository setup requires an AlmaLinux build root")
    if not re.fullmatch(r"10(?:\.\d+)?", release.get("VERSION_ID", "")):
        raise ValueError("repository setup requires AlmaLinux 10")
    return release


def validate_mirror(mirror: str) -> str:
    endpoint = urllib.parse.urlsplit(mirror)
    if (
        endpoint.scheme != "https"
        or not endpoint.netloc
        or endpoint.username
        or endpoint.password
        or endpoint.query
        or endpoint.fragment
    ):
        raise ValueError("repository mirror must be HTTPS without credentials or query")
    return mirror.rstrip("/")


def check_repository(baseurl: str) -> None:
    repomd = f"{baseurl}repodata/repomd.xml"
    try:
        with urllib.request.urlopen(repomd, timeout=30) as response:
            if response.status != 200:
                raise ValueError(f"{repomd} returned HTTP {response.status}")
            response.read(1)
    except (OSError, urllib.error.URLError) as exc:
        raise ValueError(f"repository is not reachable: {repomd}: {exc}") from exc
    print(f"repository ok: {baseurl}")


def configure(root: Path, mirror: str, verify: bool) -> None:
    mirror = validate_mirror(mirror)
    release = read_release(root)
    version = release["VERSION_ID"]
    baseurls = {
        section: f"{mirror}/{version}/{directory}/{ARCH}/os/"
        for section, directory in REPOSITORIES.items()
    }
    if verify:
        for baseurl in baseurls.values():
            check_repository(baseurl)

    for path in sorted((root / "etc/yum.repos.d").glob("*.repo")):
        config = configparser.ConfigParser(interpolation=None, strict=False)
        config.read(path)
        changed = False
        for section in config.sections():
            if section in baseurls:
                config[section]["name"] = (
                    f"AlmaLinux {version} {REPOSITORIES[section]} ({ARCH})"
                )
                config[section]["baseurl"] = baseurls[section]
                for key in ("mirrorlist", "metalink"):
                    if config.has_option(section, key):
                        config.remove_option(section, key)
                config[section]["enabled"] = "1"
                config[section]["countme"] = "0"
                config[section]["gpgcheck"] = "1"
                config[section]["sslverify"] = "1"
                changed = True
            elif path.name.startswith("almalinux-") or section.endswith("-debuginfo"):
                # Keep the build off unrelated or non-v2 package streams.
                if config[section].get("enabled", "0") != "0":
                    config[section]["enabled"] = "0"
                    changed = True
            elif "epel" in "\n".join(
                config[section].get(key, "")
                for key in ("baseurl", "mirrorlist", "metalink")
            ):
                # EPEL is not part of the appliance payload.
                if config[section].get("enabled", "0") != "0":
                    config[section]["enabled"] = "0"
                    changed = True
        if changed:
            with path.open("w", encoding="utf-8") as target:
                config.write(target)

    print(f"configured AlmaLinux {version} {ARCH} repositories from {mirror}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--mirror",
        default=os.environ.get("MIRROR", "https://mirrors.aliyun.com/almalinux"),
    )
    parser.add_argument("--root", type=Path, default=Path("/"))
    parser.add_argument(
        "--no-verify",
        action="store_true",
        help="skip the repomd reachability check",
    )
    args = parser.parse_args(argv)
    try:
        configure(args.root, args.mirror, not args.no_verify)
    except (ValueError, OSError) as exc:
        print(f"repository setup failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
