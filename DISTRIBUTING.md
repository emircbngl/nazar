# Distributing Nazar

Step-by-step guide for shipping a signed, notarized, auto-updating release.

> **TL;DR**
> 1. Get a Developer ID Application certificate from Apple (one-time, $99/yr).
> 2. Save an app-specific password into Keychain under profile `nazar-notarize`.
> 3. Run `IDENTITY="..." ./scripts/notarize.sh` to produce a signed, stapled DMG.
> 4. Upload the DMG to GitHub Releases.
> 5. (Optional) Add Sparkle for auto-updates — see [Sparkle setup](#sparkle-auto-updates) below.

## 1. Developer ID Application certificate

### What it is

A certificate that proves to macOS that *you* (a paying Apple Developer) signed this binary. Without it, users see the "unidentified developer" Gatekeeper warning and have to right-click → Open to bypass. With it, users double-click and the app just opens.

### How to get it

1. **Enroll in the Apple Developer Program** — $99/year.
   <https://developer.apple.com/programs/enroll/>
   - Individual or Organization. Individual is faster.
   - Requires Apple ID + payment.

2. **Open Keychain Access** on your Mac. Menu → Certificate Assistant → **Request a Certificate from a Certificate Authority…**
   - Email: your Apple ID email
   - Common name: your name
   - Saved to disk: yes
   - Save the `.certSigningRequest` (CSR) file.

3. **Go to Apple Developer** → Certificates, IDs & Profiles → **Certificates** → **+** (top-right).
   <https://developer.apple.com/account/resources/certificates/list>
   - Choose **Developer ID Application** under "Software".
   - Upload the CSR from step 2.
   - Download the `.cer` file.

4. **Double-click the .cer** to install it into your login Keychain.

5. **Find your identity name**:
   ```bash
   security find-identity -v -p codesigning
   ```
   You'll see a line like:
   ```
   1) ABC123...  "Developer ID Application: Your Name (TEAMID)"
   ```
   The full string in quotes is your `$IDENTITY` for `notarize.sh`.

## 2. App-specific password for notarization

Apple's notary service authenticates with your Apple ID + an app-specific password (NOT your real password).

1. Go to <https://appleid.apple.com/account/manage> → **App-Specific Passwords** → **+**.
2. Name it "Nazar notarization" → generate.
3. Copy the password (format: `abcd-efgh-ijkl-mnop`).

4. Store it in your Keychain so `notarytool` can use it without prompting:
   ```bash
   xcrun notarytool store-credentials nazar-notarize \
     --apple-id "you@example.com" \
     --team-id  "TEAMID" \
     --password "abcd-efgh-ijkl-mnop"
   ```
   Confirm with:
   ```bash
   xcrun notarytool history --keychain-profile nazar-notarize
   ```

## 3. Build the release DMG

```bash
IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/notarize.sh
```

The script:
1. Runs `swift build -c release`
2. Assembles `Nazar.app` (binary + Info.plist + AppIcon)
3. Codesigns with hardened runtime + your entitlements
4. Builds `build/Nazar-<version>.dmg`
5. Submits to Apple notary, waits for approval (typically 1–5 min)
6. Staples the notarization ticket to both DMG and app

When done, verify Gatekeeper accepts it:
```bash
spctl --assess --type execute --verbose build/Nazar.app
# → accepted, source=Notarized Developer ID
```

## 4. Publish the release

```bash
# Tag the version
git tag -a v1.0.0 -m "v1.0.0"
git push --tags

# Create a release with the DMG attached
gh release create v1.0.0 \
  --title "Nazar 1.0.0" \
  --notes-file CHANGELOG.md \
  build/Nazar-1.0.0.dmg
```

Users download from <https://github.com/your-username/nazar/releases>.

## Sparkle (auto-updates)

[Sparkle](https://sparkle-project.org/) is the de-facto auto-update framework for Mac apps. Users get an in-app "Update Available" prompt instead of having to recheck your release page.

### A. Generate an EdDSA key pair

Sparkle signs every update with EdDSA. The public key ships inside your app's `Info.plist`; the private key stays on your machine.

**Option 1 — use Sparkle's CLI**

1. Download the latest Sparkle release: <https://github.com/sparkle-project/Sparkle/releases>
   (the `.tar.xz`, e.g. `Sparkle-2.6.3.tar.xz`).
2. Extract; inside you'll find `bin/generate_keys`.
3. Run it once:
   ```bash
   ./bin/generate_keys
   ```
   First run creates a new key pair and prints the public key.
   The **private key is stored in your login Keychain** under
   "Private key for signing Sparkle updates" — never leaves your machine.

**Option 2 — use the SPM-bundled tool** (after step B below)

```bash
swift package plugin --allow-writing-to-package-directory \
  generate-appcast --help
```

Save the **public key** somewhere — you'll paste it into Info.plist.

### B. Add Sparkle to Package.swift

```swift
let package = Package(
    name: "Nazar",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Nazar",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Nazar",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", "Nazar/Info.plist"])
            ]
        )
    ]
)
```

### C. Add to Info.plist

```xml
<key>SUFeedURL</key>
<string>https://raw.githubusercontent.com/your-username/nazar/main/appcast.xml</string>
<key>SUPublicEDKey</key>
<string>PASTE_YOUR_PUBLIC_KEY_HERE</string>
<key>SUEnableAutomaticChecks</key>
<true/>
<key>SUScheduledCheckInterval</key>
<integer>86400</integer>
```

### D. Wire the updater in code

Create `Nazar/UpdaterManager.swift`:

```swift
import Sparkle

final class UpdaterManager: NSObject {
    static let shared = UpdaterManager()
    private(set) var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
```

In `NazarApp.swift` add to the Help submenu:

```swift
sub.addItem(menuItem("Check for Updates…", #selector(checkForUpdates)))
// ...
@objc func checkForUpdates() { UpdaterManager.shared.checkForUpdates() }
```

### E. Maintain an appcast

`appcast.xml` is a tiny RSS feed Sparkle polls. Sample:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Nazar</title>
    <item>
      <title>1.0.1</title>
      <description><![CDATA[
        - Fixed crash when /private/var/log is unreadable
        - Improved Trash fallback
      ]]></description>
      <pubDate>Mon, 03 Jun 2026 12:00:00 +0000</pubDate>
      <enclosure
        url="https://github.com/your-username/nazar/releases/download/v1.0.1/Nazar-1.0.1.dmg"
        sparkle:version="2"
        sparkle:shortVersionString="1.0.1"
        sparkle:edSignature="EDDSA_SIGNATURE_HERE"
        length="2150400"
        type="application/octet-stream" />
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
```

For each release, sign the DMG with your private key:

```bash
./bin/sign_update build/Nazar-1.0.1.dmg
# → outputs the sparkle:edSignature value to paste into appcast.xml
```

Then commit + push the updated appcast.xml. Existing installs poll daily and surface the update.

## Troubleshooting

- **`codesign --verify` fails**: re-run `notarize.sh`; the entitlements file may have changed.
- **Notarization rejected**: run `xcrun notarytool log <submission-id> --keychain-profile nazar-notarize` for the JSON report.
- **`spctl` says "Source=NoUSBKey"**: stapler didn't run. Re-execute `xcrun stapler staple build/Nazar-*.dmg`.
- **App opens but immediately quits after auto-update**: the new DMG wasn't signed with the SAME identity as the old one. Sparkle refuses cross-identity updates.
- **Sparkle "no update available" but you released one**: your appcast.xml `sparkle:shortVersionString` must be lexicographically greater than the installed version's `CFBundleShortVersionString`.

## Why no Mac App Store?

Nazar is fundamentally incompatible with App Store sandboxing:
- Cannot terminate other applications (no Apple Events entitlement covers this broadly)
- Cannot read `/private/var/log`
- Cannot invoke `/usr/sbin/softwareupdate` or `/usr/bin/purge`
- Cannot register global Carbon hotkeys

Like CleanMyMac, OnyX, AppCleaner, BetterTouchTool, Karabiner-Elements, Bartender, Alfred, Raycast, iStat Menus — Nazar is distributed via Developer ID + notarization, not the Mac App Store. This is the industry standard for system utilities.
