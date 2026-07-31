#!/usr/bin/env python3
"""Regenerate the embedded manifest inside CloudronVersions.json.

The versions channel requires a full manifest inlined into each version
entry, with file:// fields expanded to literal content (the icon stays
file://logo.png). Maintaining that copy by hand guarantees drift: this
round shipped a versions file claiming a 4 GiB memory limit while the
real manifest said 5 GiB. Run this after any manifest change, and let
the manifest be the single source of truth.

Usage: python3 test/sync-versions.py [version] [--check]
  --check exits non-zero if the file would change, for use as a gate.
"""
import json
import os
import sys

EXPAND = ("description", "changelog", "postInstallMessage")


def build(version):
    manifest = json.load(open("CloudronManifest.json"))
    versions = json.load(open("CloudronVersions.json"))
    entry = versions["versions"][version]
    embedded = dict(manifest)
    for field in EXPAND:
        value = embedded.get(field, "")
        if isinstance(value, str) and value.startswith("file://"):
            path = value[len("file://"):]
            if not os.path.exists(path):
                sys.exit(f"missing {path}, referenced by {field}")
            embedded[field] = open(path).read().strip()
    entry["manifest"] = embedded
    versions["versions"][version] = entry
    return json.dumps(versions, indent=2) + "\n"


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    version = args[0] if args else "0.1.0"
    rendered = build(version)
    if "--check" in sys.argv:
        if open("CloudronVersions.json").read() != rendered:
            sys.exit("CloudronVersions.json is stale: run test/sync-versions.py")
        print("CloudronVersions.json is in sync with CloudronManifest.json")
        return
    open("CloudronVersions.json", "w").write(rendered)
    print(f"CloudronVersions.json regenerated for {version}")


if __name__ == "__main__":
    main()
