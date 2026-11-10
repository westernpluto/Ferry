# ZSignKit

On-device IPA signing for Watch App Installer. It wraps [zsign](https://github.com/zhlynn/zsign)
(MIT, see `LICENSE-zsign`) and links OpenSSL from
[krzyzanowskim/OpenSSL-Package](https://github.com/krzyzanowskim/OpenSSL-Package) (Apache 2.0).

- `Sources/CZSign/zsign/`: zsign sources from commit `9299685bab7ef99827e06e5dfda93af747386590`
  (the command-line `zsign.cpp`, `certcheck.*`, `metadata.*`, the bundled zlib and the
  Windows-only minizip files are left out; the system zlib is used instead).
- `Sources/CZSign/bridge.cpp` and `include/CZSign.h`: a C entry point that extracts an IPA,
  signs every bundle with per-bundle profiles and entitlements, and re-archives it.
- `Sources/ZSignKit/ZSigner.swift`: the Swift API.

## Changes to zsign

Each change is marked `[WatchAppInstaller patch]` in the source:

1. `common/log.cpp`: an optional `g_zsign_log_hook` so log lines reach the app instead of stdout.
2. `signing.cpp`: skip the `/usr/bin/csreq` + `popen` debug path when `ZSIGN_IOS_APP` is defined
   (iOS apps can't spawn processes).
3. `openssl.cpp`: when an entitlements file is given, its `application-identifier` decides which
   bundle the profile signs. This lets one wildcard profile sign each bundle with its own concrete
   App ID (`TEAMID.com.example.app.watchkitapp`), as Xcode does.
