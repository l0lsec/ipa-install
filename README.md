# ipa-install

Automates the IPA patch, sign, and install pipeline for iOS penetration testing.

## Prerequisites


| Tool             | Install                         | Purpose                                                |
| ---------------- | ------------------------------- | ------------------------------------------------------ |
| Xcode            | Mac App Store                   | Required for auto-generating provisioning profiles     |
| libimobiledevice | `brew install libimobiledevice` | `idevice_id`, `ideviceinstaller`, `ideviceprovision`   |
| objection        | `pip3 install objection`        | Patches IPA with Frida gadget                          |
| applesign        | `npm install -g applesign`      | Re-signs IPA with your identity + provisioning profile |
| frida-tools      | `pip3 install frida-tools`      | Runtime instrumentation                                |


**One-time setup:**

1. Open Xcode → Settings (Cmd+,) → Accounts → (+) → Apple ID → sign in
2. Connect your iOS device via USB and tap "Trust" when prompted
3. The script will handle everything else — no need to manually create a project or profile

Once set up, the script auto-generates a provisioning profile matching your team whenever none exists.

## Directory Layout

```
ipa-install/
├── ipa-install.sh         # main script
├── README.md
└── stub-project/          # bundled Xcode project template used to auto-generate profiles
    ├── Stub.xcodeproj/
    │   └── project.pbxproj
    └── Stub/
        └── StubApp.swift
```

## Usage

```bash
./ipa-install.sh <path-to-ipa> [options]
```

### Options


| Flag                 | Description                                                                                                                                                                                                                                                          |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--jailbroken`       | Skip patching/signing, install directly                                                                                                                                                                                                                              |
| `--no-patch`         | Re-sign only (no Frida gadget injection)                                                                                                                                                                                                                             |
| `--identity <hash>`  | Code signing identity hash (auto-detected if omitted)                                                                                                                                                                                                                |
| `--provision <path>` | Path to `.mobileprovision` file (auto-detected if omitted)                                                                                                                                                                                                           |
| `--attach`           | Attach Objection after install                                                                                                                                                                                                                                       |
| `--bundle-id <id>`   | Override bundle ID (auto-extracted from IPA if omitted)                                                                                                                                                                                                              |
| `--min-os <ver>`     | Manually lower `MinimumOSVersion` in the app + every embedded framework + every plugin `Info.plist`. Overrides the same-major auto-detection (see [MinimumOSVersion Patching](#minimumosversion-patching)). Forces the manual codesign path (`applesign` is skipped) |
| `-h`, `--help`       | Show help                                                                                                                                                                                                                                                            |


## Examples

```bash
# Jailbroken device — install directly, no signing needed
./ipa-install.sh target.ipa --jailbroken

# Full flow — inject Frida gadget + sign + install
./ipa-install.sh target.ipa

# Re-sign only (run the app without Frida gadget)
./ipa-install.sh target.ipa --no-patch

# Patch + install + auto-attach Objection
./ipa-install.sh target.ipa --attach

# Specify identity and provisioning profile manually
./ipa-install.sh target.ipa \
    --identity DEB0EF15DEA28BBFCD2806C08F5053055BE70979 \
    --provision ~/Library/MobileDevice/Provisioning\ Profiles/abc.mobileprovision

# Jailbroken + attach
./ipa-install.sh target.ipa --jailbroken --attach --bundle-id com.target.app

# Device iOS < app MinimumOSVersion (same major) — auto-handled, no flag needed
./ipa-install.sh target.ipa --no-patch
# [+] App MinimumOSVersion: 15.8.4
# [+] Auto-lowering MinimumOSVersion: device 15.8.2 < app min 15.8.4 (same major 15 — safe)

# Force a cross-major downgrade (app will likely crash on launch — use sparingly)
./ipa-install.sh target.ipa --no-patch --min-os 12.5.7
```

## What It Does

1. **Detects device** — confirms an iOS device is connected via USB, grabs its UDID and current iOS version (via `ideviceinfo -k ProductVersion`)
2. **Extracts bundle ID and minimum OS** — pulls `CFBundleIdentifier` and `MinimumOSVersion` from the IPA's `Info.plist`. If the device's iOS version is older than the app's `MinimumOSVersion` **within the same major release**, sets the patch target automatically (see [MinimumOSVersion Patching](#minimumosversion-patching))
3. **Auto-detects signing identity and effective team** — finds a valid codesigning identity in your Keychain, then extracts the team ID from **both** the friendly name (`(TEAMID)`) and the cert's `OU` field. On Personal Team accounts these disagree (Apple ID is tied to one team but Xcode generates certs labeled with another). The script prefers the cert `OU` because that's the team Xcode and Apple's developer portal actually recognize, which is what `xcodebuild -allowProvisioningUpdates` needs to succeed
4. **Auto-detects or auto-generates provisioning profile** (priority-ordered to avoid bundle ID rewriting):
  - Searches both profile directories (Xcode 26 split them):
    - `~/Library/MobileDevice/Provisioning Profiles/`
    - `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`
  - **Step 1**: looks for an existing profile whose `application-identifier` covers the IPA's actual bundle ID (exact, full wildcard `*`, or prefix wildcard `com.foo.*`) and whose cert is in your keychain
  - **Step 2**: same search across all teams (Personal Team fallback)
  - **Step 3**: if no covering profile exists, runs `xcodebuild -downloadAllProvisioningProfiles` to pull from Apple, then **auto-generates a fresh profile templated with the IPA's exact bundle ID** by building the bundled stub Xcode project with `xcodebuild -allowProvisioningUpdates`. Xcode/Apple register the App ID under your team automatically — no per-IPA setup
  - **Step 4-6 (fallbacks)**: if per-bundle generation fails (e.g., Apple won't let your team claim that ID), falls back to any usable profile for the team, then any profile across teams, then a stub-bundle auto-gen — all of which trigger the bundle ID rewrite path
  - **Validates the profile covers this device's UDID** — if not, regenerates the profile targeting the connected device so Xcode registers it with the developer portal (preserving the existing bundle ID coverage)
5. **Patches IPA** — injects Frida gadget via Objection (skipped with `--no-patch` or `--jailbroken`)
6. **Signs IPA** — tries `applesign`, falls back to manual `codesign` if identity/profile mismatch:
  - Parses the provisioning profile's `application-identifier`
  - If the app's bundle ID doesn't match, **rewrites `CFBundleIdentifier`** to match the profile (handles wildcard, prefix-wildcard, and exact-match profiles)
  - If `--min-os <ver>` was passed, lowers `MinimumOSVersion` in the main `Info.plist` and every framework/plugin `Info.plist` (forces this manual path so applesign can't ship the IPA before patching)
  - Embeds the provisioning profile into the `.app` bundle
  - Extracts entitlements from the profile and applies them during signing
  - Signs frameworks, plugins, and the main bundle in correct order
  - Verifies with `codesign --verify --deep --strict`
7. **Installs provisioning profile on device** — uses `ideviceprovision install` and lists current profiles
8. **Installs IPA** — pushes via `ideviceinstaller`
9. **Saves a copy** — drops the signed IPA at `./<basename>-installed.ipa` in the current working directory for later re-use
10. **Attaches** — optionally launches Objection REPL against the running app

### Bundle ID Preservation

By default the script tries hard to **avoid** rewriting the IPA's bundle ID, because that breaks anti-tamper checks, keychain groups, push tokens, Universal Links, App Groups, MDM policies, and anything else namespaced by `CFBundleIdentifier`.

The dynamic flow:

1. If you already have a profile covering the IPA's bundle ID, it's used as-is
2. Otherwise the script tells `xcodebuild -allowProvisioningUpdates` to generate a profile for that exact bundle ID under your team. Apple's developer portal allows different teams to register the same explicit App ID independently — `27H7DDSDFEWFXQQU9Y.com.com.app.staging` is a separate App ID from TestApp's own
3. Subsequent runs reuse the freshly-generated profile, so this only happens once per bundle ID

When per-bundle generation fails (rare — happens when Apple reserves the namespace, or your team has hit the App ID limit), the script falls back to bundle ID rewriting and warns you:

```
[!] Per-bundle auto-gen failed (Apple may not allow this team to claim com.foo.bar)
[!] Falling back to any usable profile (bundle ID will be rewritten)
```

In that fallback case, the renamed app may misbehave on:

- Anti-tamper / jailbreak detection that compares `[NSBundle mainBundle].bundleIdentifier` to a hardcoded value
- Saved keychain credentials (different access group)
- Push notification delivery (server doesn't know the new token's bundle ID)
- Universal Links from Safari, Mail, etc. (`apple-app-site-association` lists the original ID)
- App Groups and shared containers across extensions
- MDM policy enforcement targeted at the original bundle ID

For pentesting modern enterprise apps (banking, health, etc.), the per-bundle path is strongly preferred. If you can't use it (e.g., the real app is already installed on the device under another team — installd rejects same-bundle/different-team second installs with `0xe800800c`), uninstall the App Store version first.

**Caveat for the real-app conflict:** if `com.target.app` is already installed under team A, you can't install your re-signed copy under team B with the same bundle ID. Either uninstall it, or fall back to bundle ID rewriting by passing `--provision <a-non-matching-profile>`.

### MinimumOSVersion Patching

`installd` rejects an install with `DeviceOSVersionTooLow` when the device's iOS version is older than the app's `MinimumOSVersion`. The script handles this in two ways:

**Auto-detect (default, same-major only):**
On every run the script reads the device's iOS version and the app's `MinimumOSVersion`. If the device is older but on the same major release (e.g., device `15.8.2`, app needs `15.8.4`), it automatically lowers `MinimumOSVersion` in the main `Info.plist` and every nested framework / plugin `Info.plist` to the device's exact version before signing. You'll see:

```
[+] Auto-lowering MinimumOSVersion: device 15.8.2 < app min 15.8.4 (same major 15 — safe)
```

If the gap crosses a major boundary (e.g., device `12.5.7`, app needs `15.8.4`), the script logs a warning and refuses to auto-patch — that combination almost always crashes on launch:

```
[!] Device iOS 12.5.7 is older than app minimum 15.8.4 (different majors: 12 vs 15)
[!] Skipping auto-patch — pass --min-os 12.5.7 to override (app likely to crash on launch due to missing symbols)
```

**Manual override (`--min-os <ver>`):**
Passing `--min-os <ver>` explicitly sets the value and disables auto-detection. Use this to force a cross-major downgrade (when you know what you're doing) or to pin a different value.

Why the same-major rule is safe:

- **Same major (`15.8.2` ↔ `15.8.4`):** Apple `.x.y` patch releases only ship security fixes. The SDK surface is identical; the app installs and runs normally.
- **Cross-major (`12.5.7` ↔ `15.8.4`):** install succeeds but the app will almost certainly crash with `dyld: Symbol not found` or `dyld: Library not loaded` because it's linked against frameworks/symbols that don't exist on the older OS.

Implementation notes:

- The Mach-O `LC_BUILD_VERSION` load command is intentionally **not** patched — `installd`'s preflight check reads the plist, not the Mach-O header.
- When any `MinimumOSVersion` patch will run (auto or manual), the `applesign` fast path is skipped; the script goes straight to manual `codesign` so the plist edit lands before signing.
- `--jailbroken` disables auto-detection entirely (no resign happens, so there's nothing to patch).

## Troubleshooting


| Error                                                                               | Fix                                                                                                                                                                                                                                                                                                                          |
| ----------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `No iOS device detected`                                                            | Connect via USB, unlock device, tap "Trust" on the prompt                                                                                                                                                                                                                                                                    |
| `No signing identity found`                                                         | Open Xcode, sign in to your Apple account, let it generate certs                                                                                                                                                                                                                                                             |
| `No provisioning profile found`                                                     | Sign Xcode in to your Apple ID (Xcode → Settings → Accounts), then re-run — the script will auto-generate a profile from the bundled stub project                                                                                                                                                                            |
| `Profile does not include this device's UDID`                                       | Script auto-regenerates targeting your device. If that fails, plug the device into Xcode and build any project to register it with the portal                                                                                                                                                                                |
| `Identity name says team X, but cert OU is Y (Personal Team)`                       | Informational warning. The script uses the cert OU team (Y) because that's what Xcode and Apple recognize — no action needed. This message appears once per run on Personal Team accounts                                                                                                                                    |
| `No Account for Team "X". Add a new account in Accounts settings` (during auto-gen) | The team ID being passed to `xcodebuild` doesn't match any account signed into Xcode. Open Xcode → Settings → Accounts and confirm an Apple ID is signed in for the team. If you see this for a team ID that came from your cert's friendly name (not the OU), update to the latest script — it now uses the cert OU upfront |
| `ApplicationVerificationFailed` (0xe8008015)                                        | Bundle ID doesn't match profile — script normally generates a per-bundle profile to avoid this. Verify the profile covers your device UDID                                                                                                                                                                                   |
| `ApplicationVerificationFailed` (0xe800800c)                                        | Same bundle ID is already installed on the device under a different team. Uninstall the existing copy first, or pass an alternate `--provision` to force the bundle ID rewrite path                                                                                                                                          |
| `ApplicationVerificationFailed` (other)                                             | Device UDID not in provisioning profile; regenerate profile with device added                                                                                                                                                                                                                                                |
| `InvalidCodeSignature`                                                              | Re-run with explicit `--identity` and `--provision` flags                                                                                                                                                                                                                                                                    |
| `A valid provisioning profile for this executable was not found`                    | Profile's `application-identifier` doesn't cover the app's bundle ID; script auto-rewrites in the manual codesign path                                                                                                                                                                                                       |
| App crashes on launch                                                               | Architecture mismatch (`lipo -archs` on the binary), or — if you used `--min-os` — the device OS lacks symbols/frameworks the app was linked against. Cross-major downgrades are risky                                                                                                                                       |
| Profile expired                                                                     | Free Apple ID profiles expire in 7 days; regenerate and re-install                                                                                                                                                                                                                                                           |
| `DeviceOSVersionTooLow`                                                             | The script auto-patches when the device and app share a major version. If you see this error, the gap crosses a major (e.g. iOS 12 device vs iOS 15 app) — pass `--min-os <device_version>` to force the patch, but expect a launch crash from missing symbols                                                               |


