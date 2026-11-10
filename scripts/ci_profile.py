#!/usr/bin/env python3
"""Reads a decoded provisioning profile (plist) and prepares signing for CI.

Usage: ci_profile.py PROFILE_PLIST ENTITLEMENTS_OUT INFO_JSON_OUT [BUNDLE_ID]

- Chooses the bundle ID: BUNDLE_ID if given (must be covered by the profile), the
  profile's App ID if it isn't a wildcard, or `<wildcard prefix>watchinstaller`.
- Writes entitlements for that bundle ID, made concrete the way Xcode does.
- Writes non-sensitive facts about the profile (no device IDs) as JSON.
- Prints `KEY=value` lines for the workflow ($GITHUB_ENV).
"""
import datetime
import json
import plistlib
import shlex
import sys

DEFAULT_BUNDLE_ID = "com.example.WatchAppInstaller"


def fail(message):
    print(f"::error::{message}", file=sys.stderr)
    sys.exit(1)


def main():
    if len(sys.argv) < 4:
        fail(__doc__)
    profile_path, entitlements_path, info_path = sys.argv[1:4]
    override = sys.argv[4].strip() if len(sys.argv) > 4 else ""

    with open(profile_path, "rb") as f:
        profile = plistlib.load(f)

    entitlements = profile.get("Entitlements", {})
    app_id = entitlements.get("application-identifier", "")
    if "." not in app_id:
        fail("The provisioning profile has no application-identifier.")
    prefix, pattern = app_id.split(".", 1)
    team = (profile.get("TeamIdentifier") or [prefix])[0]

    def covers(bundle_id):
        if pattern.endswith("*"):
            return bundle_id.startswith(pattern[:-1])
        return bundle_id == pattern

    if override:
        if not covers(override):
            fail(f"APP_BUNDLE_ID {override} isn't covered by the profile's App ID ({pattern}).")
        bundle_id = override
    elif pattern.endswith("*"):
        base = pattern[:-1]
        bundle_id = f"{base}watchinstaller" if base else DEFAULT_BUNDLE_ID
    else:
        bundle_id = pattern

    expires = profile.get("ExpirationDate")
    now = datetime.datetime.now(datetime.timezone.utc)
    if expires is not None:
        if expires.tzinfo is None:
            expires = expires.replace(tzinfo=datetime.timezone.utc)
        if expires <= now:
            fail(f"The provisioning profile “{profile.get('Name')}” expired on {expires:%Y-%m-%d}.")

    devices = profile.get("ProvisionedDevices")
    if profile.get("ProvisionsAllDevices"):
        kind = "Enterprise"
    elif devices is not None:
        kind = "Development" if entitlements.get("get-task-allow") else "Ad Hoc"
    else:
        fail("This is an App Store profile. Use a Development, Ad Hoc or Enterprise profile.")

    concrete_id = f"{prefix}.{bundle_id}"
    result = {}
    for key, value in entitlements.items():
        if isinstance(value, str):
            if value == "*":
                continue
            result[key] = concrete_id if value.endswith(".*") else value
        elif isinstance(value, list):
            items = []
            for item in value:
                if isinstance(item, str):
                    if item == "*":
                        continue
                    items.append(concrete_id if item.endswith(".*") else item)
                else:
                    items.append(item)
            if items:
                result[key] = items
        else:
            result[key] = value
    result["application-identifier"] = concrete_id
    result["com.apple.developer.team-identifier"] = team
    result.setdefault("keychain-access-groups", [concrete_id])

    with open(entitlements_path, "wb") as f:
        plistlib.dump(result, f)

    info = {
        "bundleIdentifier": bundle_id,
        "profileKind": kind,
        "profileExpires": expires.strftime("%Y-%m-%d") if expires else None,
        "deviceCount": len(devices) if devices is not None else None,
    }
    with open(info_path, "w") as f:
        json.dump(info, f)

    print(f"BUNDLE_ID={shlex.quote(bundle_id)}")
    print(f"PROFILE_KIND={shlex.quote(kind)}")
    print(f"PROFILE_UUID={shlex.quote(profile.get('UUID', ''))}")


if __name__ == "__main__":
    main()
