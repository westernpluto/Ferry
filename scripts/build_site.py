#!/usr/bin/env python3
"""Assembles the static GitHub Pages install site.

Usage: build_site.py OUT_DIR --base-url URL --version V --build B --commit SHA
                     [--run-id ID] [--unsigned-ipa PATH]
                     [--signed-ipa PATH --signing-info JSON [--install-key KEY --expires-at ISO]]

Copies site/ to OUT_DIR, draws the icons and writes info.json. With an unsigned IPA it also
writes source.json, an AltStore-style source listing it, which Ferry uses to update itself
(it re-signs the unsigned build with the user's own certificate). For a signed build it
also writes manifest.plist with an absolute IPA URL, which iOS requires:

- Public mode (no --install-key): Ferry.ipa and manifest.plist sit at the site root
  and the page offers Install to everyone.
- Private mode (--install-key): they go under i/<key>/, a folder nobody can guess or
  list, and the root info.json doesn't mention them. Only someone with the link
  (…/#k=<key>) can install.
"""
import argparse
import datetime
import json
import os
import plistlib
import re
import shutil
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ferry_icon import png  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TITLE = "Ferry"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--commit", default="")
    parser.add_argument("--run-id", default="")
    parser.add_argument("--signed-ipa")
    parser.add_argument("--signing-info")
    parser.add_argument("--unsigned-ipa")
    parser.add_argument("--install-key", default="")
    parser.add_argument("--expires-at", default="")
    args = parser.parse_args()

    key = args.install_key.strip()
    if key and not re.fullmatch(r"[0-9a-f]{32,128}", key):
        sys.exit("The install key must be 32–128 lowercase hex characters.")

    base = args.base_url.rstrip("/") + "/"
    shutil.rmtree(args.out, ignore_errors=True)
    shutil.copytree(os.path.join(ROOT, "site"), args.out)
    for size in (180, 512):
        with open(os.path.join(args.out, f"icon-{size}.png"), "wb") as f:
            f.write(png(size))

    build_id = f"{args.version}-{args.build}-{args.commit[:7] or 'local'}-{args.run_id or '0'}"
    sw = os.path.join(args.out, "sw.js")
    with open(sw) as f:
        text = f.read().replace("__BUILD_ID__", build_id)
    with open(sw, "w") as f:
        f.write(text)

    info = {
        "version": args.version,
        "build": args.build,
        "commit": args.commit[:7],
        "runId": args.run_id,
        "builtAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
        "signed": False,
        "private": bool(key),
        "hasUnsigned": False,
    }

    if args.unsigned_ipa and os.path.exists(args.unsigned_ipa):
        shutil.copy(args.unsigned_ipa, os.path.join(args.out, "Ferry-unsigned.ipa"))
        info["hasUnsigned"] = True
        write_source(args, base)

    if args.signed_ipa and os.path.exists(args.signed_ipa):
        with open(args.signing_info) as f:
            signing = json.load(f)
        folder = os.path.join(args.out, "i", key) if key else args.out
        prefix = f"i/{key}/" if key else ""
        os.makedirs(folder, exist_ok=True)
        shutil.copy(args.signed_ipa, os.path.join(folder, "Ferry.ipa"))
        manifest = {
            "items": [{
                "assets": [{"kind": "software-package", "url": base + prefix + "Ferry.ipa"}],
                "metadata": {
                    "bundle-identifier": signing["bundleIdentifier"],
                    "bundle-version": args.version,
                    "kind": "software",
                    "title": TITLE,
                },
            }]
        }
        with open(os.path.join(folder, "manifest.plist"), "wb") as f:
            plistlib.dump(manifest, f)

        signed_info = dict(info, signed=True, **signing)
        if args.expires_at:
            signed_info["expiresAt"] = args.expires_at
        if key:
            # The root stays generic; the details live next to the private build.
            with open(os.path.join(folder, "info.json"), "w") as f:
                json.dump(signed_info, f, indent=2)
        else:
            info = signed_info

    with open(os.path.join(args.out, "info.json"), "w") as f:
        json.dump(info, f, indent=2)
    # Serve files as-is (no Jekyll processing on GitHub Pages).
    open(os.path.join(args.out, ".nojekyll"), "w").close()
    print(f"Site written (signed: {bool(args.signed_ipa)}, private: {bool(key)})")


def bundle_info(ipa):
    """Info.plist of the app in an IPA."""
    with zipfile.ZipFile(ipa) as archive:
        for name in archive.namelist():
            parts = name.split("/")
            if len(parts) == 3 and parts[0] == "Payload" and parts[1].endswith(".app") and parts[2] == "Info.plist":
                return plistlib.loads(archive.read(name))
    return {}


def write_source(args, base):
    """source.json: Ferry's own update source, pointing at the unsigned build."""
    plist = bundle_info(args.unsigned_ipa)
    today = datetime.datetime.now(datetime.timezone.utc)
    notes = f"Build {args.build}" + (f" ({args.commit[:7]})" if args.commit else "")
    source = {
        "name": "Ferry",
        "identifier": plist.get("CFBundleIdentifier", "com.example.Ferry") + ".source",
        "subtitle": "Updates for Ferry. Ferry signs them with your own certificate.",
        "iconURL": base + "icon-512.png",
        "website": base,
        "apps": [{
            "name": TITLE,
            "bundleIdentifier": plist.get("CFBundleIdentifier", "com.example.Ferry"),
            "developerName": "Ferry",
            "subtitle": "Sign and install your own apps",
            "localizedDescription": "Signs and installs your own iOS, Apple Watch and Apple TV apps without a Mac.",
            "iconURL": base + "icon-512.png",
            "versions": [{
                "version": args.version,
                "buildVersion": args.build,
                "date": today.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "localizedDescription": notes,
                "downloadURL": base + "Ferry-unsigned.ipa",
                "size": os.path.getsize(args.unsigned_ipa),
                "minOSVersion": plist.get("MinimumOSVersion", "16.0"),
            }],
        }],
        "news": [],
    }
    with open(os.path.join(args.out, "source.json"), "w") as f:
        json.dump(source, f, indent=2)


if __name__ == "__main__":
    main()
