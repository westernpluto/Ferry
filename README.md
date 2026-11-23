# Ferry

Ferry signs and installs your own iOS apps on your iPhone, without a Mac. Apple Watch apps inside
them install on your paired watch too.

1. Once: add your signing certificate (`.p12`) and provisioning profiles.
2. Add an `.ipa` (from Xcode, CI or a colleague), or get one from a **source**.
3. Tap **Sign & Install**. The app re-signs every bundle with your certificate, then iOS installs
   the iPhone app and watchOS installs the watch app.

Apps that are already signed for your devices can be installed without signing. Apple TV apps
(tvOS) are signed the same way and installed on a paired Apple TV over Wi-Fi (see *Apple TV*).

## Sources and updates

The **Sources** tab takes AltStore-style sources: a JSON file listing apps and their versions, the
format AltStore, SideStore and Feather use. Add one by address (`altstore://source?url=…` links work
too), tap **Get** on an app, and it's added to your library.

Ferry checks your sources when it opens and when you pull down on a list. When a source has a newer
version (higher version number, or the same version with a higher build number) of an app in your
library, the app shows **Update** and the Apps tab gets a badge. Updating downloads the new IPA and
**overwrites the app's IPA in place**: the library entry, its settings and its bundle ID choices stay,
and no second copy is kept. Importing a file for an app that's already in the library does the same.
Ferry also deletes the signed copy once an install finishes, and clears leftovers when it starts, so
the library only ever holds one IPA per app.

### Installed apps

Ferry keeps track of what it installed where, and checks it against your library and sources:

- **Apple TV**: Ferry asks each paired TV which apps it has (at launch, when you pull to refresh, and
  after each install), so versions are exact and apps you removed disappear. Apps on the TV that
  match your library or a source are tracked too, even if something else installed them.
- **iPhone**: iOS doesn't let apps see what's installed, so Ferry records each install it hands to iOS
  (version, bundle ID, date, and when its profile expires). These entries mean "last sent by Ferry".
  Swipe one away on the app's page if you deleted the app.

An installed app that's behind a source or your library, or whose signature expires within 7 days,
shows in **Sources › Installed Apps**, on its library row and page, and on the TV's app list, and
counts toward the Apps tab badge. Tap it to open the app and install the new version.

### Updating Ferry itself

Ferry can update itself from a source. Your Ferry install page publishes one for your copy at
`https://<user>.github.io/<repo>/source.json`. It lists the unsigned build, with the workflow run
number as the build number, so every published build counts as newer. Add that address in the
Sources tab (any source that lists Ferry works too).

When a newer build is listed, Ferry offers it when it opens (**Update**, **Later** or **Skip This
Version**), and **Settings › Ferry Updates** shows it with an **Update Ferry** button. There you can
also pick which source to use and turn off the check when Ferry opens. Updating downloads the build
into your library (replacing the previous copy), signs it with your certificate under the **bundle
ID and team this copy already has**, and installs it over itself with your install method. iOS closes
Ferry while it installs. Your apps, profiles and certificate stay because the app's identity doesn't
change. If no imported profile covers Ferry's bundle ID, Ferry adds the profile it was installed with,
which always does. Ferry's own build number isn't changed when it signs itself, so it can tell when
it's up to date. Tapping Sign & Install on the Ferry entry in your library signs it the same way.

## Your own bundle IDs and team

Some apps ask for bundle IDs or a team your profiles don't cover (for example a third-party app, or
one whose extensions use a different team). On the app's page, under **Signing**:

- **Match My Profiles** picks bundle IDs your profiles do cover. It prefers an explicit profile whose
  App ID ends like the app's (`com.dev.Notes` → `com.you.Notes`), otherwise a wildcard profile
  (`com.you.*` → `com.you.Notes`), moves the extensions and watch app along with it
  (`….Notes.widget`), and keeps everything on one team.
- **Bundle IDs & Team…** lets you set them yourself: the app's ID (extensions under it follow), any
  extension individually (or pick one of your profiles' App IDs from the list), and the team whose
  profiles are used. Each row shows which profile will sign it.

Ferry rewrites `CFBundleIdentifier` (and the watch app's `WKCompanionAppBundleIdentifier` /
`WKAppBundleIdentifier` references) before signing. Choices are saved per app, so updates from a
source are signed the same way. An app signed under a new bundle ID installs alongside the original
rather than replacing it, and App Groups, iCloud containers and other capabilities come from your
profiles.

## Apple TV

Ferry can install tvOS apps on an Apple TV (tvOS 17 or later) on the same Wi-Fi, without a Mac or
cable. It pairs the way Xcode does: open **Settings › Remotes and Devices › Remote App and Devices**
on the TV, then in Ferry **Settings › Apple TV**, tap the TV and enter the code it shows. The pairing
is kept in the Keychain.

- The TV's page shows its **UDID** (tap to copy) for your provisioning profiles, its tvOS version,
  and its installed apps, which you can remove.
- Add a tvOS `.ipa` to the library (or from a source). Its page shows **Sign & Install on <TV>**:
  Ferry signs it with your certificate and profiles (bundle ID choices apply here too), uploads it
  and installs it, showing progress. With several TVs, pick one under the button.
- Pair by IP address if the TV doesn't show up. Leave the port empty and Ferry asks the TV.
- Ferry only asks for Local Network access once you open the Apple TV screen.

This uses the open-source [`idevice`](https://github.com/jkcoxson/idevice) Rust library (MIT)
through a small C bridge in `Packages/ATVBridge` (from iOStoATV): RemotePairing with the PIN, a
CoreDevice tunnel, AFC to upload the IPA, then InstallationProxy to install it. If the TV refuses an
app (`ApplicationVerificationFailed`), its profile doesn't include the TV's UDID.
The layout adapts to the iPhone Duo: folded it's a single list, unfolded the app list and the
selected app sit side by side.

## How it works (and why it works this way)

iOS has no public API that lets an app install other apps directly, and none that installs
software on an Apple Watch. What iOS *does* support is
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

## Installing the app itself from GitHub Pages (no Mac needed)

Ferry's install page lets anyone sign and install Ferry with their own certificate, in their own
GitHub account. Nothing personal goes through anyone else's repository or page.

**One-time setup (each person):**
1. **Copy Ferry to your account:** fork this repository (the page links to it). The original must be
   public for others to copy it.
2. In your copy, turn on **Settings › Pages › Source: GitHub Actions**, and open the **Actions** tab once
   to turn workflows on.
3. Create a [fine-grained token](https://github.com/settings/personal-access-tokens/new) for **your copy
   only**, with **Actions** and **Secrets** set to *Read and write* and **Pages** set to *Read*. A short
   expiry is fine.

**Signing, on any Ferry install page** (`https://<user>.github.io/<repo>/`), under **Sign with your certificate**:
enter your copy (`your-name/Ferry`), pick your **.p12** and password and your **.mobileprovision**, choose
how long the install link should last, paste the token, and tap **Sign & Publish**. The page:

1. Reads the profile in the browser and rejects expired or App Store profiles, or a bundle ID the profile
   doesn't cover. (With a wildcard `com.you.*` profile the app is signed as `com.you.ferry`.)
2. Checks your copy has the workflow, workflows turned on and Pages set up, and explains how to fix
   anything that's missing.
3. Encrypts your files in the browser (libsodium sealed boxes, as GitHub requires) and saves them as your
   copy's secrets, then starts its build and follows it.
4. Gives you your install link. Open it in Safari on the iPhone and tap **Install**.

### Private by default

| What | Where it goes |
| --- | --- |
| Your `.p12`, password and profile | Encrypted secrets in **your** copy. They can't be read back, and by default they're **deleted as soon as the build has used them**. The build keeps them in a temporary keychain that's deleted afterwards |
| The signed Ferry app (it includes your profile: team name and device UDIDs) | Your Pages site, in a folder named by a random 256-bit key (`…/i/<key>/`). Nobody can guess it, and nothing on the public page points to it. You get the link `…/#k=<key>`. The part after `#` is never sent to a server |
| How long it stays online | Removed automatically after 15, 30 (default), 60 or 120 minutes: the workflow republishes the site without it. Or choose **Public** to keep an always-available Install button |
| The build's own copy of the site | Deleted from the run as soon as it's deployed, so it can't be downloaded from the Actions tab |
| Your token | Only used in that browser tab, never saved. Only the name of your copy is remembered on that device |

The one limit is that iOS downloads the app with no login, so while the link is up, anyone who has it
could download the app. That's why it's secret and short-lived. Once Ferry is installed, nothing else
needs the web: it signs and installs your apps on the iPhone, offline.

You can also add the secrets by hand in your copy's Settings (`SIGNING_CERTIFICATE_P12`,
`SIGNING_CERTIFICATE_PASSWORD`, `PROVISIONING_PROFILE` as base64 for the files, and optionally
`INSTALL_KEY`, 64 hex characters, for private mode) and run the **Install page** workflow.

The page is plain static files: no server code and no outside scripts or fonts (TweetNaCl, public domain,
is bundled for the encryption). It's cached by a service worker, so it opens without a connection and
can be added to the Home Screen. Signing and installing need internet.

## Building

Requirements: **Xcode 27.1 or later** (the iOS 27.1 SDK makes the app fill both iPhone Duo displays),
[XcodeGen](https://github.com/yonaskolb/XcodeGen), [rustup](https://rustup.rs) (for the Apple TV
bridge), an iOS 16+ device.

```sh
brew install xcodegen
scripts/build-atv-bridge.sh   # -> Frameworks/ATVBridge.xcframework
xcodegen generate
open Ferry.xcodeproj
```

Select your team under *Signing & Capabilities*, change the bundle ID if necessary, and run it on your iPhone.
Dependencies (Swift Package Manager): [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) for reading IPAs,
and the local `Packages/ZSignKit` (zsign + [OpenSSL](https://github.com/krzyzanowskim/OpenSSL-Package)) for signing.

CI (`.github/workflows/build.yml`) checks the Rust bridge on Linux (`cargo fmt`, `clippy`, `test`), then
on GitHub's `xcode-27` runner (macOS 27, Apple silicon) with Xcode 27.1 builds the bridge, generates the project, runs the unit tests on the **iPhone Duo** simulator and builds
an unsigned IPA artifact. GitHub names these images after the Xcode version, so there's no
`macos-27.1` label. The step log shows the exact macOS build.

## Setting up "On this iPhone" mode

`itms-services` only accepts HTTPS with a certificate the device trusts, so the built-in server needs
one. The app makes it for you. Open **Settings › Install Method** and:

1. Tap **Generate Certificate**. This creates a root certificate and an HTTPS server certificate on
   the iPhone, both stored in its Keychain.
2. Tap **Download Profile in Safari**, allow the download, then install "Ferry Local Root"
   in **Settings › General › VPN & Device Management**. (If Safari isn't your default browser, use
   **Save Profile to Files** and tap the file in the Files app instead.)
3. Turn on full trust for it in **Settings › General › About › Certificate Trust Settings**.

Come back to the app and the status changes to **Ready**. The app checks this itself.

The root certificate has X.509 *name constraints* that limit it to `localhost`, `127.0.0.1`, `::1`,
`localtest.me` and `127-0-0-1.sslip.io` (public names that always resolve to 127.0.0.1), so it can't be
used to impersonate other websites. Its private key never leaves the iPhone's Keychain.
The server certificate is valid for 800 days (iOS's limit for user-trusted roots is 825).
**Renew Server Certificate** (under Advanced) re-issues it from the same root, so nothing needs reinstalling.

Prefer to make the certificate on a computer? `scripts/make-local-cert.sh` still works. Import its
`server.p12` with **Advanced › Use My Own server.p12…** and install `rootCA.mobileconfig` the same way.

## Setting up "My web server" mode

Enter the HTTPS folder URL in **Settings** (for example `https://example.com/apps/`). When you tap Install, the app
writes `manifest.plist` and `<App>.ipa`. Share them, upload both to that folder, then tap **Install from my server**.
The server needs a publicly trusted certificate (Let's Encrypt is fine).

## Troubleshooting

- **The iPhone app updates but the watch app doesn't (until the watch restarts)**: watchOS can keep the
  old watch app when an update arrives with the same build number. With **New build number for each
  install** (Settings › Signing, on by default) Ferry gives the iPhone app, the watch app and their
  extensions one new, matching build number every time, so the watch always sees an update. The
  version you see (e.g. 1.0.2) doesn't change. If it still sticks, it's watchOS's install service on
  the watch: restarting the watch, or removing the watch app in the Watch app and installing it again,
  clears it.
- **"Cannot connect to 127.0.0.1"**: iOS's installer won't fetch apps from a bare IP address (it never
  even connects). Ferry now serves from **127-0-0-1.sslip.io** by default, a public name whose DNS always
  answers 127.0.0.1, so the app still comes from this iPhone. Its certificate covers that name. If you
  generated the certificate in an older version, Settings › Install Method shows **Update Certificate**:
  tap it, then install and trust the new profile (and remove the old one). The name needs an internet
  connection to look up. `ferry.localtest.me` and `localhost` are alternatives in the same screen.
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
Ferry/
  App/       App entry point
  Core/      IPA inspection, validation, manifest, HTTPS server, Keychain, install flow
  Core/Signing/  profile matching, bundle ID/team overrides, entitlements, certificate/profile storage, signing
  Core/Sources/  AltStore-style sources: parsing, update checks, downloads
  AppleTV/   Apple TV pairing, discovery and install (Swift side of Packages/ATVBridge)
  Models/    BundleInfo, AppPackage, ProvisioningProfile
  Views/     SwiftUI screens
Packages/ZSignKit/        zsign-based signer (C++/OpenSSL) with a Swift API
Packages/ATVBridge/       Rust C bridge over idevice for Apple TV pairing and installs
scripts/build-atv-bridge.sh  builds Frameworks/ATVBridge.xcframework
FerryTests/               Unit tests for parsing, validation, signing plans, manifest and HTTP handling
scripts/make-local-cert.sh
scripts/ci_sign_app.sh, ci_profile.py, build_site.py   CI signing and the install page
site/                     Static, offline-capable install page (GitHub Pages) with in-browser upload
project.yml               XcodeGen spec
```
