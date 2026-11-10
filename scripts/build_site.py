#!/usr/bin/env python3
"""Assembles the static GitHub Pages install site.

Usage: build_site.py OUT_DIR --base-url URL --version V --build B --commit SHA
                     [--signed-ipa PATH --signing-info JSON] [--unsigned-ipa PATH]

Copies site/ to OUT_DIR, draws the icons, and writes info.json plus (for a signed
build) manifest.plist with an absolute IPA URL, which iOS requires.
"""
import argparse
import datetime
import json
import math
import os
import plistlib
import shutil
import struct
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TITLE = "Watch Installer"


def png(size):
    """A simple app icon: blue gradient with a white watch outline."""
    rows = []
    c = size / 2
    body_w, body_h, radius = size * 0.36, size * 0.44, size * 0.1
    strap_w = size * 0.22
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            t = y / size
            r, g, b = int(20 + 30 * t), int(110 + 40 * t), int(230 - 20 * t)
            dx, dy = abs(x + 0.5 - c), abs(y + 0.5 - c)
            # Rounded-rectangle watch body.
            qx, qy = max(dx - (body_w / 2 - radius), 0), max(dy - (body_h / 2 - radius), 0)
            dist = math.hypot(qx, qy) - radius
            in_strap = dx < strap_w / 2 and dy >= body_h / 2 - 1
            if -size * 0.035 < dist <= 0 or (in_strap and dist > 0):
                r, g, b = 255, 255, 255
            row += bytes((r, g, b))
        rows.append(bytes(row))

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b""))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--commit", default="")
    parser.add_argument("--signed-ipa")
    parser.add_argument("--signing-info")
    parser.add_argument("--unsigned-ipa")
    args = parser.parse_args()

    base = args.base_url.rstrip("/") + "/"
    shutil.rmtree(args.out, ignore_errors=True)
    shutil.copytree(os.path.join(ROOT, "site"), args.out)
    for size in (180, 512):
        with open(os.path.join(args.out, f"icon-{size}.png"), "wb") as f:
            f.write(png(size))

    build_id = f"{args.version}-{args.build}-{args.commit[:7] or 'local'}"
    sw = os.path.join(args.out, "sw.js")
    with open(sw) as f:
        text = f.read().replace("__BUILD_ID__", build_id)
    with open(sw, "w") as f:
        f.write(text)

    info = {
        "version": args.version,
        "build": args.build,
        "commit": args.commit[:7],
        "builtAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
        "signed": False,
        "hasUnsigned": False,
    }

    if args.unsigned_ipa and os.path.exists(args.unsigned_ipa):
        shutil.copy(args.unsigned_ipa, os.path.join(args.out, "WatchInstaller-unsigned.ipa"))
        info["hasUnsigned"] = True

    if args.signed_ipa and os.path.exists(args.signed_ipa):
        with open(args.signing_info) as f:
            signing = json.load(f)
        shutil.copy(args.signed_ipa, os.path.join(args.out, "WatchInstaller.ipa"))
        manifest = {
            "items": [{
                "assets": [{"kind": "software-package", "url": base + "WatchInstaller.ipa"}],
                "metadata": {
                    "bundle-identifier": signing["bundleIdentifier"],
                    "bundle-version": args.version,
                    "kind": "software",
                    "title": TITLE,
                },
            }]
        }
        with open(os.path.join(args.out, "manifest.plist"), "wb") as f:
            plistlib.dump(manifest, f)
        info.update(signing)
        info["signed"] = True

    with open(os.path.join(args.out, "info.json"), "w") as f:
        json.dump(info, f, indent=2)
    # Serve files as-is (no Jekyll processing on GitHub Pages).
    open(os.path.join(args.out, ".nojekyll"), "w").close()
    print(f"Site written to {args.out} (signed: {info['signed']})")


if __name__ == "__main__":
    main()
