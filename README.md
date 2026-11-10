# Watch App Installer

An iOS app that signs and installs your own apps, including **watchOS apps**, onto your iPhone
and its paired Apple Watch.

1. Once: add your signing certificate (`.p12`) and provisioning profiles.
2. Add an `.ipa` (from Xcode, CI or a colleague).
3. Tap **Sign & Install**. The app re-signs every bundle with your certificate, then iOS installs
   the iPhone app and watchOS installs the watch app.

Apps that are already signed for your devices can be installed without signing.
The layout adapts to the iPhone Duo: folded it's a single list, unfolded the app list and the
selected app sit side by side.

## How it works (and why it works this way)

iOS has **no public API that lets an app install software on an Apple Watch**, and there is no
supported way to talk to the watch's installer directly. What iOS *does* support is
**over-the-air (OTA) installation**: opening an `itms-services://?action=download-manifest&url=…`
link makes iOS download and install a signed IPA. When that IPA contains a watch app in
`Payload/<App>.app/Watch/`, watchOS installs it on the paired watch like any other companion app.
This is the same way enterprise and ad hoc apps are distributed.

So this app:

1. **Inspects the IPA**: finds the iOS container app and every watch app in `Watch/`, reads each
   `Info.plist` and `embedded.mobileprovision`, and checks signing (see *Checks* below).
2. **Serves the IPA over HTTPS**, either
   - **On this iPhone**: a built-in HTTPS server on `127.0.0.1` that only accepts connections from
     the device itself and uses a certificate you create and trust, or
   - **My web server**: the app writes `manifest.plist` plus the IPA for you to upload to any HTTPS host.
3. **Opens the `itms-services` link**. iOS asks you to confirm, downloads the IPA and installs it.
   The watch app then installs automatically (if *Automatic App Install* is on in the Watch app),
   or from **Watch app › My Watch › Available Apps**.

### Which apps can be installed

| Signing | Works? |
| --- | --- |
| Ad Hoc profile listing **both** your iPhone and Apple Watch UDIDs | ✅ |
| Development profile listing both devices | ✅ |
| Enterprise (in-house) profile | ✅ (only if the enterprise certificate is trusted on the device) |
| App Store / TestFlight distribution, unsigned, or signed by someone else | ✅ after **Sign & Install** with your certificate (see below) |
| Apps downloaded from the App Store (FairPlay-encrypted) | ❌ Can't be re-signed; the binary is encrypted |
| A bare watchOS `.app` with no iOS container | ❌ |

**Watch-only apps** work too: when you archive a watch-only app, Xcode wraps it in an iOS "stub"
container app. Export that archive (Ad Hoc / Development) and import the resulting IPA.

## Signing on the iPhone

Open **Settings › Signing** and add:

| File | Where to get it |
| --- | --- |
| Your certificate as a **`.p12`** + its password | Keychain Access on a Mac › right-click your *Apple Development* or *Apple Distribution* certificate (it must show a private key) › Export |
| One **`.mobileprovision`** per bundle ID | developer.apple.com › Profiles, or Xcode. Needed for the iPhone app (`com.you.app`), the watch app (`com.you.app.watchkitapp`), and each extension (widgets, complications, notifications, …). A **wildcard** profile (`com.you.*`) covers all of them if the app uses no special capabilities |

Each profile must include your certificate and, for Development and Ad Hoc, your iPhone's and
Apple Watch's UDIDs. Register the devices first, then regenerate the profiles.

The app matches each bundle in the IPA to the most specific profile (exact App ID beats wildcard),
skips expired/App Store profiles and profiles that don't include your certificate, and shows the
result per bundle before you install. Entitlements come from each bundle's profile, made concrete
the way Xcode does (`TEAMID.*` → `TEAMID.com.you.app.watchkitapp`).

Signing uses [zsign](https://github.com/zhlynn/zsign) (MIT) compiled into the app, with OpenSSL.
See `Packages/ZSignKit/README.md` for what was changed. The `.p12` is stored in the Keychain on
this iPhone only. During signing the key is written to a temporary, file-protected folder and
deleted straight afterwards.

Things signing can't change:

- **Bundle IDs.** If you sign under a different team, you need profiles for the IPA's existing bundle IDs.
- **App Store downloads.** These are encrypted and won't launch after re-signing. Use your own builds.
- **Free Apple ID accounts.** No Ad Hoc profiles; Development profiles last 7 days.
- **Developer Mode.** Development-signed apps need it on both the iPhone and the watch
  (Settings › Privacy & Security › Developer Mode).

### Checks

The detail screen flags:

- no watch app in the IPA (warning only), or a raw watchOS binary at the top level
- watch apps that need their iPhone app (not marked `WKRunsIndependentlyOfCompanionApp`)
- missing code signature or provisioning profile (on the iOS app or any watch app)
- App Store profiles, expired profiles, or profiles that expire within 7 days
- watch app bundle IDs that don't start with the iOS app's bundle ID, or a `WKCompanionAppBundleIdentifier` mismatch
- the iOS app and watch app signed by different teams
- a UDID checker: paste your watch's UDID to see whether the profile includes it

## Building

Requirements: **Xcode 27.1 or later** (the iOS 27.1 SDK makes the app fill both iPhone Duo displays),
[XcodeGen](https://github.com/yonaskolb/XcodeGen), an iOS 16+ device.

```sh
brew install xcodegen
xcodegen generate
open WatchAppInstaller.xcodeproj
```

Select your team under *Signing & Capabilities*, change the bundle ID if necessary, and run it on your iPhone.
Dependencies (Swift Package Manager): [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) for reading IPAs,
and the local `Packages/ZSignKit` (zsign + [OpenSSL](https://github.com/krzyzanowskim/OpenSSL-Package)) for signing.

CI (`.github/workflows/build.yml`) runs on GitHub's `xcode-27` runner (macOS 27, Apple silicon) with
Xcode 27.1. It generates the project, runs the unit tests on the **iPhone Duo** simulator and builds
an unsigned IPA artifact. GitHub names these images after the Xcode version, so there's no
`macos-27.1` label. The step log shows the exact macOS build.

## Setting up "On this iPhone" mode

`itms-services` only accepts HTTPS with a certificate the device trusts, so the built-in server needs
one. Create it once:

```sh
scripts/make-local-cert.sh            # writes ./local-cert/
scripts/make-local-cert.sh out mypass # custom folder and .p12 password
```

1. Send `local-cert/rootCA.mobileconfig` to the iPhone (AirDrop, Files or Mail) and install it in
   **Settings › General › VPN & Device Management**.
2. Turn on full trust in **Settings › General › About › Certificate Trust Settings**.
3. In the app, open **Settings › Install Method › Add server.p12…**, choose `server.p12` and enter its password
   (default `watchinstaller`).

The root certificate has X.509 *name constraints* that limit it to `localhost`, `127.0.0.1` and `::1`, so it
can't be used to impersonate other websites. Still, keep `rootCA.key` private, or delete it.

## Setting up "My web server" mode

Enter the HTTPS folder URL in **Settings** (for example `https://example.com/apps/`). When you tap Install, the app
writes `manifest.plist` and `<App>.ipa`. Share them, upload both to that folder, then tap **Install from my server**.
The server needs a publicly trusted certificate (Let's Encrypt is fine).

## Troubleshooting

- **Nothing happens / "Unable to install"**: the profile probably doesn't include this iPhone's or watch's UDID,
  or the certificate isn't trusted. The Activity log shows whether iOS requested `manifest.plist` and `app.ipa`.
- **No request in the log**: the root certificate isn't fully trusted (step 2 above), or the host in
  Settings doesn't match the certificate.
- **The download stops partway**: iOS gives a backgrounded app about 30 seconds to keep its server running.
  Large IPAs may not finish in that time. Use web-server mode for those.
- **The iPhone app installs but the watch app doesn't**: open the Watch app › My Watch › Available Apps.
  If it isn't listed, check the watch app's profile includes the watch's UDID and that the watch's
  watchOS version is at least the app's `MinimumOSVersion`.
- **Developer Mode**: on iOS 16+ and watchOS 9+, apps signed with a *development* profile need
  Developer Mode enabled on both devices (Settings › Privacy & Security › Developer Mode).

## Project layout

```
WatchAppInstaller/
  App/       App entry point
  Core/      IPA inspection, validation, manifest, HTTPS server, Keychain, install flow
  Core/Signing/  profile matching, entitlements, certificate/profile storage, signing
  Models/    BundleInfo, AppPackage, ProvisioningProfile
  Views/     SwiftUI screens
Packages/ZSignKit/        zsign-based signer (C++/OpenSSL) with a Swift API
WatchAppInstallerTests/   Unit tests for parsing, validation, signing plans, manifest and HTTP handling
scripts/make-local-cert.sh
project.yml               XcodeGen spec
```
