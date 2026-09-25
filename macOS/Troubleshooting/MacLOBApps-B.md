# macOS LOB Apps (Managed PKG via MDM) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate "macOS line-of-business app never installs, no error", "0x87D13BA2 invalid bundleIDs", "LOB app keeps reinstalling", "installed but Intune says Failed", or "no Uninstall option for my Mac LOB app" in under 10 minutes.

> **Context (Sept 2026):** this runbook covers the **macOS line-of-business app** type only. Intune sends it to the Mac over the **MDM channel**: the service issues `InstallEnterpriseApplication`, and macOS's own `mdmclient` downloads and installs the package. **The Intune management agent isn't involved.** For the agent-delivered **macOS app (PKG)** and **macOS app (DMG)** types, use [`PKG-DMG-Apps-B.md`](PKG-DMG-Apps-B.md).
>
> Hard requirements from Learn: the `.pkg` must be a component package or a distribution containing packages; it must **not** contain a bundle, disk image or bare `.app`; it must be **signed with a "Developer ID Installer" certificate**; and it must **contain a payload**. The limit is **2 GB**. **Install as managed** needs macOS 11+, a single app, no nested packages, and an install location of `/Applications`. Sources: [Add macOS LOB apps (Learn, ms.date 2026-04-14)](https://learn.microsoft.com/en-us/intune/app-management/deployment/add-lob-macos); [macOS LOB apps aren't deployed (Learn, 2026-03-30)](https://learn.microsoft.com/en-us/troubleshoot/mem/intune/app-management/macos-lob-apps-not-deployed); [Error 0x87D13BA2 (Learn, 2026-03-30)](https://learn.microsoft.com/en-us/troubleshoot/mem/intune/app-management/error-0x87d13ba2-deploy-macos-lob-app).

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage
**On the Mac** (Terminal, admin account). Allow about 60 seconds:

```bash
# 1. What does mdmclient think is installed? (This is what gets reported to Intune.)
sudo /usr/libexec/mdmclient QueryInstalledApps > /tmp/InstalledApps.txt; grep -i -A3 "<bundle.id>" /tmp/InstalledApps.txt

# 2. Did the MDM install command arrive, and what did it say? (last 2 h)
log show --last 2h --style compact --predicate 'process == "mdmclient" AND (eventMessage CONTAINS[c] "InstallEnterpriseApplication" OR eventMessage CONTAINS[c] "<bundle.id>")' | tail -30

# 3. Did macOS Installer actually run the package?
grep -iE "<package name or bundle.id>|Installer\[|PackageKit: Installed" /var/log/install.log | tail -20

# 4. Package receipt and on-disk version
pkgutil --pkgs | grep -i "<bundle.id or vendor>"
defaults read "/Applications/<App Name>.app/Contents/Info" CFBundleIdentifier
defaults read "/Applications/<App Name>.app/Contents/Info" CFBundleShortVersionString
```

**Admin side** (PowerShell 7, Microsoft.Graph.Beta.Devices.CorporateManagement, scope `DeviceManagementApps.Read.All`):

```powershell
Connect-MgGraph -Scopes DeviceManagementApps.Read.All -NoWelcome
$app = Get-MgBetaDeviceAppManagementMobileApp -All | Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.macOSLobApp' -and $_.DisplayName -like '*<App Name>*' }
$app.AdditionalProperties | Select-Object bundleId, versionNumber, buildNumber, installAsManaged, ignoreVersionDetection, fileName, size
$app.AdditionalProperties.childApps | ForEach-Object { [pscustomobject]$_ }   # the "Included apps" detection list
```

| Result | Meaning | Go to |
|---|---|---|
| No `InstallEnterpriseApplication` in the mdmclient log | Command never delivered: assignment, enrollment, or APNs | Fix 1 |
| Command arrived, no install.log entry, no error in Intune | Package metadata is missing `version`/`CFBundleVersion` or a valid `install-location` | Fix 2 |
| install.log shows signature / "untrusted" error | Not signed with a **Developer ID Installer** cert (Application cert or unsigned) | Fix 3 |
| App on disk, Intune **Failed** with **0x87D13BA2** | "Included apps" lists a bundle ID mdmclient doesn't report | Fix 4 |
| App reinstalls every check-in / every 24 h | Payload-free package, or version in Intune never matches disk | Fix 5 |
| "Installed" in Intune, app not on disk | Stale receipt, or detection too broad | Fix 6 |
| No **Uninstall** assignment option | App wasn't uploaded with **Install as managed = Yes** (or isn't eligible) | Fix 7 |
| Not visible in Company Portal | No logo uploaded, or duplicate app name | Fix 8 |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Intune reports "Installed"
└── Every bundle ID in "Included apps" (childApps) is reported by mdmclient QueryInstalledApps
    │   at the uploaded version (unless "Ignore app version" = Yes → presence only)
    └── macOS Installer completed the package (install.log: "Installed …")
        ├── Payload present, lands in /Applications (or a subfolder)
        ├── Distribution/PackageInfo carries version + CFBundleVersion + install-location
        ├── Signature: Developer ID Installer (Apple-issued), not expired/revoked; notarized for smooth Gatekeeper
        └── Package downloaded by mdmclient from Intune CDN (≤ 2 GB)
            └── mdmclient received InstallEnterpriseApplication
                ├── Device meets Minimum OS; managed install additionally needs macOS 11+
                └── Device MDM-enrolled, MDM profile present, APNs reachable (push → check-in)
                    └── App assigned: Required / Available for enrolled devices / Uninstall (managed only)
```
</details>

---
## Diagnosis & Validation Flow
1. **Confirm enrollment and MDM channel.**
   `profiles status -type enrollment` → expect `MDM enrollment: Yes (User Approved)`. `No` → device-side enrollment problem, see [`ADE-Enrollment-B.md`](ADE-Enrollment-B.md) / [`MDM-Certificate-Renewal-B.md`](MDM-Certificate-Renewal-B.md).
2. **Force a check-in and watch the command arrive.**
   In Company Portal select **Check settings**, or in Intune select **Devices > (device) > Sync**. Then:
   `log stream --style compact --predicate 'process == "mdmclient"' | grep -i -E "InstallEnterpriseApplication|InstallApplication|Error"`
   Good: a command line naming the manifest/bundle ID, followed by download progress. Bad: nothing after 5 minutes, so check assignment group membership and APNs (port 443/5223 to `*.push.apple.com`).
3. **Inspect the package itself (on any Mac, with the same .pkg you uploaded).**
   ```bash
   pkgutil --check-signature "<file>.pkg"     # Good: "Developer ID Installer: <Org> (<TEAMID>)" + "signed by a developer certificate issued by Apple for distribution"
   spctl -a -vv -t install "<file>.pkg"        # Good: "accepted  source=Notarized Developer ID"
   pkgutil --expand "<file>.pkg" /tmp/lobcheck && ls /tmp/lobcheck
   grep -iE "pkg-ref|install-location|customLocation|CFBundleVersion|version=" /tmp/lobcheck/Distribution /tmp/lobcheck/*/PackageInfo 2>/dev/null
   pkgutil --payload-files "<file>.pkg" | head  # Good: ./Applications/<App>.app/... Bad: empty (no payload)
   ```
   Bad signs: `Developer ID Application` (wrong cert type), `no signature`, no `install-location`, payload outside `/Applications`, or a `.dmg`/bare `.app` inside the package.
4. **Compare detection vs reality.** Diff the Graph `childApps` list against `/tmp/InstalledApps.txt`. Every childApp bundle ID must appear there, at `versionNumber` unless version detection is ignored.
5. **Check the receipt.** `pkgutil --pkg-info <package-id>` shows the version and location macOS believes it installed.

---
## Common Fix Paths

<details><summary>Fix 1 — Install command never reaches the Mac</summary>

1. Confirm the device (or user) is in the assigned group, and that no **Excluded** group also contains it. Mixed user/device include+exclude is the classic trap.
2. Confirm the app's **Minimum operating system** isn't above the device's `sw_vers -productVersion`.
3. Force a sync, then watch `mdmclient` (step 2 above). If other MDM commands also stall, it's the channel, not the app: check APNs and the MDM push certificate.

```powershell
# Admin: see assignments for the app
Get-MgBetaDeviceAppManagementMobileAppAssignment -MobileAppId $app.Id | Select-Object Intent, @{n='Target';e={$_.Target.AdditionalProperties.'@odata.type'}}, @{n='GroupId';e={$_.Target.AdditionalProperties.groupId}}
```
</details>

<details><summary>Fix 2 — Silent non-install: missing version / install-location metadata</summary>

Learn documents this as "no error messages are shown in Intune". The Distribution or PackageInfo is missing the package `version` and `CFBundleVersion`, or the `install-location` isn't `/Applications` (or a subfolder).

Rebuild the package so the metadata is generated for you, from the signed `.app`:
```bash
# Build a distribution package that installs the app into /Applications
productbuild --component "/path/to/<App>.app" /Applications "/tmp/<App>-unsigned.pkg"
# Sign with the Developer ID *Installer* identity (must be in the login keychain)
productsign --sign "Developer ID Installer: <Org> (<TEAMID>)" "/tmp/<App>-unsigned.pkg" "/tmp/<App>.pkg"
# Notarize and staple (recommended)
xcrun notarytool submit "/tmp/<App>.pkg" --keychain-profile "<profile>" --wait
xcrun stapler staple "/tmp/<App>.pkg"
```
If the vendor ships the package and you can't rebuild it, use the agent-delivered **macOS app (PKG)** type instead. It tolerates unsigned and non-`/Applications` packages. See [`PKG-DMG-Apps-B.md`](PKG-DMG-Apps-B.md).
</details>

<details><summary>Fix 3 — Signature is wrong type, expired, or missing</summary>

`pkgutil --check-signature` must show **Developer ID Installer**. An app signed with *Developer ID Application* but wrapped in an unsigned pkg fails. Re-sign with `productsign` (see Fix 2). If the certificate has expired, the existing package may still validate against its timestamp, but new builds need a renewed certificate from the Apple Developer account (Account Holder role).
</details>

<details><summary>Fix 4 — 0x87D13BA2 "One or more apps contain invalid bundleIDs"</summary>

Common with multi-component packages (the Teams-style example in Learn). **The app may actually be installed fine.**
```bash
sudo /usr/libexec/mdmclient QueryInstalledApps > ~/Desktop/InstalledApps.txt
```
In Intune, go to **Apps > (app) > Properties > App information > Edit > Included apps**. Remove every entry that **isn't** in `InstalledApps.txt`, plus anything that isn't an `.app` in `/Applications`. Save, then sync the device. The first entry is the "primary app" used in reports, so keep the main app first.
Rollback: re-add entries through the same Edit pane. No reinstall is triggered by editing Included apps alone.
</details>

<details><summary>Fix 5 — Reinstall loop</summary>

- **No payload** (scripts-only or "payload-free" package): per Learn, it "attempts to reinstall as long as the app remains assigned". Move it to a **shell script** or the unmanaged **macOS app (PKG)** type, or add a real payload.
- **Version never matches:** the app self-updates (so the on-disk version is higher than uploaded), or `CFBundleShortVersionString` in the pkg differs from the app's own Info.plist. Set **Ignore app version = Yes** for self-updating apps. For your own builds, fix the mismatch.
- **Required + updated content:** installs are retried at the next check-in and then **every 24 hours** after a failure. That's expected behaviour, not a loop.
</details>

<details><summary>Fix 6 — "Installed" in Intune but app missing (stale receipt)</summary>

```bash
pkgutil --pkgs | grep -i "<vendor or bundle>"
sudo pkgutil --forget <package-id>     # removes the receipt only, not files
```
Then sync the device so status is re-evaluated. This is non-destructive to app files. If the app files are also gone, the next Required evaluation reinstalls it.
</details>

<details><summary>Fix 7 — Need managed removal / Uninstall intent</summary>

The **Uninstall** assignment only appears for LOB apps uploaded with **Install as managed = Yes**. That requires macOS 11+, a single app with **no nested packages**, and an install location of `/Applications`. To convert: upload a new LOB app object with the setting on (you can't flip an existing object), assign it, then retire the old object.
**Caution:** managed apps are **removed when the MDM profile is removed** (unenrol, retire, migration). Warn before retiring devices mid-migration; see [`DeviceMigration-B.md`](DeviceMigration-B.md).
</details>

<details><summary>Fix 8 — Missing from Company Portal</summary>

Upload a **logo** (Learn: LOB apps without a logo aren't displayed in the apps section), make sure the **Name** is unique (duplicate names show only one), and confirm the assignment is **Available for enrolled devices**.
</details>

---
## Escalation Evidence
```
Ticket: macOS LOB app (managed PKG via MDM) — <App Name>
Tenant: <tenantName>          Intune app ID: <appId>
Device: <serial> / <deviceName>   macOS: <sw_vers>   Enrollment: <ADE|BYOD|Company Portal>
Assignment intent/group: <Required|Available|Uninstall> / <group>
Install as managed: <Yes|No>   Ignore app version: <Yes|No>   Uploaded version/build: <x>/<y>
pkg signature (pkgutil --check-signature): <paste first 4 lines>
spctl -t install result: <accepted/rejected + source>
Distribution install-location / CFBundleVersion present: <Y/N> / <Y/N>
Included apps (childApps) vs QueryInstalledApps diff: <list missing IDs>
mdmclient log excerpt (InstallEnterpriseApplication): <paste>
/var/log/install.log excerpt: <paste>
Intune status + code: <e.g. Failed 0x87D13BA2>
Steps already tried: <Fix #s>
```
Attach the output of `Scripts/Get-MacLOBAppStatus.sh` (run with `--pkg <file.pkg> --bundle-id <bundle.id> --collect`).

---
## 🎓 Learning Pointers
- The LOB type is an **Apple MDM command**, not an Intune agent job. That's why its logs are in `mdmclient` and `install.log`, not `/Library/Logs/Microsoft/Intune`. Compare the two paths in [`PKG-DMG-Apps-A.md`](PKG-DMG-Apps-A.md).
- The "silent failure with no error" is almost always package metadata. Learn's [macOS LOB apps aren't deployed](https://learn.microsoft.com/en-us/troubleshoot/mem/intune/app-management/macos-lob-apps-not-deployed) shows the `xar`/`install-location` check.
- Detection is only as good as **Included apps**. Learn's [0x87D13BA2 article](https://learn.microsoft.com/en-us/troubleshoot/mem/intune/app-management/error-0x87d13ba2-deploy-macos-lob-app) uses `mdmclient QueryInstalledApps` as the source of truth.
- Apple's [Signing Mac software with Developer ID](https://developer.apple.com/developer-id/) explains the *Application* vs *Installer* certificate split behind most signature failures.
- Before you decide an app "must" be LOB, read the type-selection table in [`PKG-DMG-Apps-A.md`](PKG-DMG-Apps-A.md). Unmanaged PKG is the escape hatch for vendor packages you can't rebuild.
