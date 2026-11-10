# Watch App Installer

An iOS app that installs **signed watchOS apps** onto your iPhone's paired Apple Watch.

You import an `.ipa` (from Xcode, a colleague, or your CI). The app checks that the watchOS app inside it is
signed for direct installation, then hands it to iOS. iOS installs it on the iPhone and watchOS installs it on the watch.

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
| App Store / TestFlight distribution | ❌ Only installable from the App Store or TestFlight |
| Unsigned, or a bare watchOS `.app` with no iOS container | ❌ |

**Watch-only apps** work too: when you archive a watch-only app, Xcode wraps it in an iOS "stub"
container app. Export that archive (Ad Hoc / Development) and import the resulting IPA.

This app **does not sign or re-sign** anything. Signing requires your Apple Developer certificate
and a profile that includes your devices. Do that in Xcode (or `codesign`) before importing.

### Checks

The detail screen flags:

- no watch app in the IPA, or a raw watchOS binary at the top level
- missing code signature or provisioning profile (on the iOS app or any watch app)
- App Store profiles, expired profiles, or profiles that expire within 7 days
- watch app bundle IDs that don't start with the iOS app's bundle ID, or a `WKCompanionAppBundleIdentifier` mismatch
- the iOS app and watch app signed by different teams
- a UDID checker: paste your watch's UDID to see whether the profile includes it

## Building

Requirements: Xcode 15 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen), iOS 16+ device.

```sh
brew install xcodegen
xcodegen generate
open WatchAppInstaller.xcodeproj
```

Select your team under *Signing & Capabilities*, change the bundle ID if necessary, and run it on your iPhone.
The only dependency is [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) (Swift Package Manager), which reads IPAs.

CI (`.github/workflows/build.yml`) generates the project, runs the unit tests in the simulator and
builds an unsigned IPA artifact.

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
3. In the app, open **Settings › Import .p12 certificate…**, choose `server.p12` and enter its password
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
  Models/    BundleInfo, AppPackage, ProvisioningProfile
  Views/     SwiftUI screens
WatchAppInstallerTests/   Unit tests for parsing, validation, manifest and HTTP handling
scripts/make-local-cert.sh
project.yml               XcodeGen spec
```
