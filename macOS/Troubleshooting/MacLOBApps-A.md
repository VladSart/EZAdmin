# macOS LOB Apps (Managed PKG via MDM) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---
## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps (by phase)](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions
- **In scope:** the Intune **macOS > Line-of-business app** type: package building and signing, upload-time metadata extraction, the MDM `InstallEnterpriseApplication` delivery path, the **Included apps** detection model, **Install as managed**, updates, and removal.
- **Out of scope:** the agent-delivered **macOS app (PKG)** / **(DMG)** types ([`PKG-DMG-Apps-A.md`](PKG-DMG-Apps-A.md)), VPP/App Store apps ([`VPP-App-Deployment-A.md`](VPP-App-Deployment-A.md), [`VPP-DDM-A.md`](VPP-DDM-A.md)), and Microsoft 365 Apps ([`M365AppsMac-A.md`](M365AppsMac-A.md)).
- **Assumes:** the Mac is MDM-enrolled (ADE or user-approved), the engineer has an Apple Developer account with a **Developer ID Installer** identity (or the vendor ships one), and the admin side has Intune Application Manager (or equivalent) permissions.
- Facts are current to Learn pages dated 2026-03-30 / 2026-04-14 (checked 2026-09-25).

---
## How It Works
<details><summary>Full architecture</summary>

### 1. Where LOB sits among the macOS app types
| Type | Delivered by | Package rules | Managed (removable) | Size limit |
|---|---|---|---|---|
| **macOS LOB app** | **MDM protocol**: Intune service → APNs push → `mdmclient` runs `InstallEnterpriseApplication` | Signed (**Developer ID Installer**) component/distribution pkg; payload required; no nested `.dmg`/bare `.app` | Optional (**Install as managed**, macOS 11+, single app into `/Applications`) | 2 GB |
| macOS app (PKG) | Intune management agent (`IntuneMdmDaemon`) | Unsigned OK; any location; pre/post scripts | No | 8 GB |
| macOS app (DMG) | Intune management agent | DMG containing `.app`(s) | No (Uninstall intent supported by agent) | 8 GB |

The design point: LOB is the **only** path where macOS itself owns the install through Apple's MDM spec. That gives you native managed-app semantics, but it also means Apple's rules (signing, manifest, `/Applications`) are enforced strictly and Intune sees only what `mdmclient` reports.

### 2. Upload-time processing (admin center)
When you upload the `.pkg`, Intune parses the Distribution/PackageInfo XML and pre-fills:
- **Included apps**: `bundleId` + `buildNumber`/`versionNumber` per app found (Graph: `macOSLobApp.childApps`). The **first** entry is the "primary app" used in reporting.
- **Primary bundle ID / version** (Graph: `bundleId`, `versionNumber`, `buildNumber`).
If the package lacks `version`/`CFBundleVersion` or a usable `install-location`, the object can still be created. The install then fails **silently** on devices. This is the scenario in Learn's "macOS LOB apps aren't deployed".

### 3. Delivery sequence
```
Intune service                      APNs                     Mac
──────────────                      ────                     ───
Assignment evaluated ──push──────▶  push ─────────────────▶  mdmclient wakes, checks in
                                                               │
◀────────────────────────── check-in requests next command ────┘
InstallEnterpriseApplication (manifest URL, bundle IDs,
  versions, ManagementFlags if managed) ─────────────────────▶ mdmclient
                                                               │ download pkg from Intune CDN
                                                               │ verify signature (Developer ID Installer)
                                                               │ hand to macOS Installer (PackageKit)
                                                               │   → /var/log/install.log
                                                               ▼
                                              app lands in /Applications, receipt written
◀──── Acknowledged / Error  +  later InstalledApplicationList (QueryInstalledApps) ──
Intune compares reported bundle IDs + versions against childApps ─▶ Installed / Failed
```
Key consequence: **install result ≠ Intune status.** Intune marks *Installed* only when **every** childApp is reported at the expected version (or present, if *Ignore app version* = Yes). That's why a correct install can show **0x87D13BA2**.

### 4. Install as managed
With **Install as managed = Yes**, the install command asks macOS to track the app as MDM-managed (macOS 11+). Benefits: the **Uninstall** intent becomes available, and the app is removed when the MDM profile is removed. Eligibility: a single app, **no nested packages**, and installing to `/Applications`. The flag is set per app object at creation. To change it, create a new app object.

### 5. Updates
Upload the new `.pkg` under **Properties > App information > Select file to update**. The new package **must increment `CFBundleShortVersionString`**. With Required intent, the install is attempted at the next check-in, and on failure retried **every 24 hours**. *Ignore app version = No* means "install if missing **or** version differs", so a self-updating app ends up fighting Intune. Use *Yes* for those.

### 6. Company Portal visibility
LOB apps without a **logo** aren't displayed in the apps section. Duplicate app names mean only one appears.
</details>

---
## Dependency Stack
```
[7] Intune status "Installed"  ← childApps ⊆ QueryInstalledApps (version-matched unless ignored)
[6] macOS Installer success     ← payload → /Applications, receipt (pkgutil --pkgs)
[5] Package validity            ← Developer ID Installer signature, valid chain, (notarized), version + CFBundleVersion + install-location, ≤ 2 GB
[4] mdmclient InstallEnterpriseApplication  ← downloaded from Intune CDN (HTTPS)
[3] Device eligibility          ← Minimum OS; macOS 11+ for managed; not already at version
[2] MDM channel                 ← MDM profile, APNs cert valid, *.push.apple.com 443/5223
[1] Assignment                  ← user/device group, intent, no exclusion overlap
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| Never installs, **no error** in Intune | Missing `version`/`CFBundleVersion`/`install-location` in pkg metadata | `pkgutil --expand` → grep Distribution/PackageInfo |
| **0x87D13BA2** "invalid bundleIDs", app works | childApps contains IDs not reported by mdmclient (helpers, frameworks, non-/Applications apps) | `mdmclient QueryInstalledApps` vs childApps |
| Reinstalls repeatedly | Payload-free package, or version mismatch (self-updater / Info.plist ≠ pkg version) | `pkgutil --payload-files`; compare versions |
| install.log: signature/untrusted | Signed with Developer ID *Application*, unsigned, or revoked cert | `pkgutil --check-signature`, `spctl -t install` |
| Upload rejected / can't select file | `.dmg` or `.app` uploaded, or > 2 GB | Use DMG type, or split |
| No Uninstall intent | Not created as managed / not eligible | Graph `installAsManaged` |
| App vanished after retire/migration | Managed app removed with MDM profile (by design) | Device action history |
| Missing in Company Portal | No logo / duplicate name / no Available assignment | App properties |
| "Installed" but files missing | Stale receipt, or broad detection | `pkgutil --pkg-info`, then `--forget` |
| Stuck "Not applicable" | Device below Minimum OS | `sw_vers` vs app setting |

---
## Validation Steps
1. **Enrollment:** `profiles status -type enrollment`. Good: `MDM enrollment: Yes (User Approved)`. Bad: `No`, or not user-approved (managed install and some payloads are refused).
2. **Signature:** `pkgutil --check-signature app.pkg`. Good: `Status: signed by a developer certificate issued by Apple for distribution` + `Developer ID Installer:`. Bad: `no signature`, `Developer ID Application`, or `untrusted`.
3. **Gatekeeper install assessment:** `spctl -a -vv -t install app.pkg`. Good: `accepted`, `source=Notarized Developer ID`. Bad: `rejected`.
4. **Metadata:** `pkgutil --expand app.pkg /tmp/x; grep -iE "install-location|customLocation|CFBundleVersion|pkg-ref" /tmp/x/Distribution /tmp/x/*/PackageInfo`. Good: version attributes present and location `/Applications`. Bad: missing or pointing elsewhere.
5. **Payload:** `pkgutil --payload-files app.pkg | head`. Good: `./Applications/App.app/...`. Bad: empty.
6. **Command delivery:** `log show --last 1h --predicate 'process == "mdmclient"' | grep -i InstallEnterpriseApplication`. Good: present after sync.
7. **Detection parity:** every childApps bundle ID appears in `sudo /usr/libexec/mdmclient QueryInstalledApps`.

---
## Troubleshooting Steps (by phase)
**Phase 1 — Build/package (before upload).** Validate steps 2–5 on the build Mac. Most "Intune bugs" in this area are package-shape problems. If you can't rebuild a vendor package, choose the unmanaged PKG type.

**Phase 2 — Upload/object.** Review the pre-filled **Included apps**. Delete anything that isn't an `.app` installed into `/Applications`, and anything that won't exist post-install. Set *Ignore app version* for self-updaters. Decide *Install as managed* now, because it can't be changed later on the same object. Upload a logo.

**Phase 3 — Delivery.** Sync, then `log stream --predicate 'process == "mdmclient"'`. No command → assignment/channel. Command with an error → read the error text: download failures (network/proxy to the Intune CDN) versus install failures.

**Phase 4 — Install.** `/var/log/install.log` is authoritative. Look for `Installer[...]` and `PackageKit` lines, and for errors about signature, disk space, or the destination volume.

**Phase 5 — Reporting.** Compare childApps against `QueryInstalledApps`. Intune status lags the device, so allow a check-in after changes.

---
## Remediation Playbooks
<details><summary>Playbook 1 — Rebuild a compliant LOB package from a signed .app</summary>

```bash
APP="/path/to/<App>.app"
# Confirm the app itself is Developer ID Application-signed and notarized
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Authority|TeamIdentifier"
spctl -a -vv "$APP"
# Build + sign installer package
productbuild --component "$APP" /Applications /tmp/unsigned.pkg
productsign --sign "Developer ID Installer: <Org> (<TEAMID>)" /tmp/unsigned.pkg "/tmp/<App>-<version>.pkg"
xcrun notarytool submit "/tmp/<App>-<version>.pkg" --keychain-profile "<profile>" --wait
xcrun stapler staple "/tmp/<App>-<version>.pkg"
pkgutil --check-signature "/tmp/<App>-<version>.pkg"
```
`productbuild --component` writes the Distribution with the app's bundle version and the `/Applications` location, which covers the metadata Intune needs.
</details>

<details><summary>Playbook 2 — Clear 0x87D13BA2 (detection list mismatch)</summary>

1. On an affected Mac: `sudo /usr/libexec/mdmclient QueryInstalledApps > ~/InstalledApps.txt`.
2. Admin center: **Apps > app > Properties > App information > Edit > Included apps**. Remove every bundle ID absent from the file. Keep the primary app first.
3. Save, then sync the devices. Status recalculates without reinstalling.
Rollback: re-add removed entries. There's no device impact.
</details>

<details><summary>Playbook 3 — Convert an unmanaged LOB to managed (to gain Uninstall)</summary>

1. Validate eligibility: single app, no nested pkgs, `/Applications`, fleet on macOS 11+.
2. Create a **new** LOB object from the same pkg with *Install as managed = Yes* (give it a distinct name while both exist).
3. Assign the new object Required to a pilot group. Whether macOS adopts an already-installed unmanaged copy as managed isn't documented by Microsoft, so test it: on a pilot Mac, confirm the app is still present and reported, and that an **Uninstall** assignment to a test device actually removes it.
4. Remove the old object's assignments, then delete it.
**Risk:** from now on, retire/unenrol removes the app. Communicate this before bulk migrations.
Rollback: re-assign the old unmanaged object and remove the new one's assignment (the app isn't uninstalled unless you assign **Uninstall**).
</details>

<details><summary>Playbook 4 — Stop a reinstall loop</summary>

- Payload-free package → move the logic to a macOS shell script or the unmanaged PKG type.
- Self-updating app → set *Ignore app version = Yes* on the object.
- Your own build with version drift → make pkg `version`, the app's `CFBundleShortVersionString`, and the uploaded object agree, then re-upload with an incremented version.
</details>

<details><summary>Playbook 5 — Reset a stale receipt (destructive to receipt only)</summary>

```bash
pkgutil --pkgs | grep -i "<vendor>"
pkgutil --pkg-info <package-id>
sudo pkgutil --forget <package-id>
```
Then sync the device. App files aren't touched. Rollback: reinstalling the package recreates the receipt.
</details>

---
## Evidence Pack
Device side: run `sudo bash macOS/Scripts/Get-MacLOBAppStatus.sh --bundle-id <bundle.id> [--pkg /path/to/file.pkg] --collect`. It writes a CSV and a log bundle to `/tmp`.

Admin side (PowerShell 7):
```powershell
#Requires -Modules Microsoft.Graph.Beta.Devices.CorporateManagement
param([Parameter(Mandatory)][string]$AppNameLike, [string]$OutDir = "$PWD")
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Connect-MgGraph -Scopes DeviceManagementApps.Read.All -NoWelcome
$apps = @(Get-MgBetaDeviceAppManagementMobileApp -All | Where-Object {
    $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.macOSLobApp' -and $_.DisplayName -like "*$AppNameLike*" })
if ($apps.Count -eq 0) { Write-Warning "No macOS LOB app matched '$AppNameLike'"; return }
$rows = foreach ($a in $apps) {
    $p = $a.AdditionalProperties
    $children = @($p['childApps']) | Where-Object { $_ } | ForEach-Object { "$($_['bundleId'])@$($_['versionNumber'])" }
    $assign = @(Get-MgBetaDeviceAppManagementMobileAppAssignment -MobileAppId $a.Id) | ForEach-Object { "$($_.Intent):$($_.Target.AdditionalProperties['groupId'])" }
    [pscustomobject]@{
        DisplayName = $a.DisplayName; Id = $a.Id; BundleId = $p['bundleId']
        Version = $p['versionNumber']; Build = $p['buildNumber']; FileName = $p['fileName']; SizeBytes = $p['size']
        InstallAsManaged = $p['installAsManaged']; IgnoreVersion = $p['ignoreVersionDetection']
        ChildApps = ($children -join '; '); Assignments = ($assign -join '; ')
        LargeIconPresent = [bool]$a.LargeIcon
    }
}
$rows | Format-List
$rows | Export-Csv (Join-Path $OutDir "MacLOBApp-Evidence-$(Get-Date -f yyyyMMdd-HHmm).csv") -NoTypeInformation
```

---
## Command Cheat Sheet
| Purpose | Command |
|---|---|
| Enrollment state | `profiles status -type enrollment` |
| Installed apps as MDM sees them | `sudo /usr/libexec/mdmclient QueryInstalledApps` |
| Live MDM command stream | `log stream --style compact --predicate 'process == "mdmclient"'` |
| Past MDM install commands | `log show --last 4h --predicate 'process == "mdmclient"' \| grep -i InstallEnterpriseApplication` |
| Installer log | `grep -i "<name>" /var/log/install.log` |
| Package signature | `pkgutil --check-signature file.pkg` |
| Gatekeeper install check | `spctl -a -vv -t install file.pkg` |
| Expand package XML | `pkgutil --expand file.pkg /tmp/x` |
| Payload listing | `pkgutil --payload-files file.pkg` |
| Receipts | `pkgutil --pkgs` / `pkgutil --pkg-info <id>` |
| Forget receipt | `sudo pkgutil --forget <id>` |
| App bundle ID / version | `defaults read "/Applications/X.app/Contents/Info" CFBundleIdentifier` / `CFBundleShortVersionString` |
| Build + sign pkg | `productbuild --component X.app /Applications u.pkg && productsign --sign "Developer ID Installer: …" u.pkg s.pkg` |
| Notarize + staple | `xcrun notarytool submit s.pkg --keychain-profile <p> --wait && xcrun stapler staple s.pkg` |
| Graph: list LOB apps | `Get-MgBetaDeviceAppManagementMobileApp -All \| ? { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.macOSLobApp' }` |

---
## 🎓 Learning Pointers
- [Add macOS LOB apps (Learn)](https://learn.microsoft.com/en-us/intune/app-management/deployment/add-lob-macos) is the authority for the four package requirements, the 2 GB limit, **Install as managed** eligibility, and the 24-hour retry on Required updates.
- [macOS LOB apps aren't deployed (Learn)](https://learn.microsoft.com/en-us/troubleshoot/mem/intune/app-management/macos-lob-apps-not-deployed) explains why a missing `install-location`/`CFBundleVersion` produces a failure with no error at all.
- [Error 0x87D13BA2 (Learn)](https://learn.microsoft.com/en-us/troubleshoot/mem/intune/app-management/error-0x87d13ba2-deploy-macos-lob-app) shows the reporting model: Intune trusts `mdmclient`'s installed-app list, not the installer's exit code.
- Apple Platform Deployment's app distribution chapters and the MDM `InstallEnterpriseApplication` command reference (developer.apple.com, Device Management) describe the protocol Intune is driving.
- [macadmins.org](https://macadmins.org) Slack (#packaging, #intune) and Armin Briegel's *Packaging for Apple Administrators* are the community references for `productbuild`/`pkgbuild` edge cases.
- Pair this with [`PKG-DMG-Apps-A.md`](PKG-DMG-Apps-A.md) for type selection and [`Gatekeeper-Notarization-A.md`](Gatekeeper-Notarization-A.md) for signing and notarization failures.
