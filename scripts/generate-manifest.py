#!/usr/bin/env python3
"""Generate manifest.json for an AirOS update package."""

import hashlib
import json
import os
import sys
from datetime import datetime, timezone


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <update-dir> <version>", file=sys.stderr)
        sys.exit(1)

    update_dir = sys.argv[1]
    version = sys.argv[2]

    files = {}
    for fname in sorted(os.listdir(update_dir)):
        if fname == "manifest.json":
            continue
        path = os.path.join(update_dir, fname)
        if not os.path.isfile(path):
            continue

        file_type = "image" if fname.endswith((".tar.gz", ".tar")) else "config"
        files[fname] = {
            "sha256": sha256_file(path),
            "type": file_type,
        }

    manifest = {
        "version": version,
        "created": datetime.now(timezone.utc).isoformat(),
        "files": files,
    }

    manifest_path = os.path.join(update_dir, "manifest.json")
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)

    print(f"Generated {manifest_path} ({len(files)} files)")


if __name__ == "__main__":
    main()
