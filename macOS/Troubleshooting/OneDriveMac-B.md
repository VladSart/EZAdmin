# OneDrive Sync App for Mac (Files On-Demand, Folder Backup, Managed Preferences) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate "OneDrive on the Mac isn't syncing / Desktop & Documents not backing up / my policy isn't applying" in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Two builds of OneDrive exist on macOS and they read **different preference domains**. Most "policy
didn't apply" tickets are a policy written to the wrong domain. Run on the affected Mac as the
signed-in user (not `sudo`, except where shown):

```bash
# 1. Which build is installed? (Standalone = com.microsoft.OneDrive ; App Store = com.microsoft.OneDrive-mac)
defaults read /Applications/OneDrive.app/Contents/Info.plist CFBundleIdentifier
defaults read /Applications/OneDrive.app/Contents/Info.plist CFBundleShortVersionString
ls -d "/Applications/OneDrive.app/Contents/_MASReceipt" 2>/dev/null && echo "App Store build"

# 2. Is it running, and is the sync root present under the File Provider location?
pgrep -lx OneDrive
ls -d ~/Library/CloudStorage/OneDrive-* 2>/dev/null

# 3. What managed (MDM) preferences actually landed?
ls /Library/Managed\ Preferences/ | grep -i onedrive
defaults read "/Library/Managed Preferences/com.microsoft.OneDrive" 2>/dev/null

# 4. Is the Background Items (login item) permission in place? (macOS 13+)
sudo sfltool dumpbtm | grep -i -A4 onedrive | head -30
```

**Interpretation table:**

| Finding | Action |
|---|---|
| Bundle ID `com.microsoft.OneDrive-mac` (App Store build) and user wants Folder Backup (KFM) | Fix 1 — replace with the **standalone** build; App Store build does not support Folder Backup |
| Managed prefs exist for `com.microsoft.OneDrive` but App Store build installed (or vice versa) | Fix 2 — retarget the Preference/Settings-catalog payload to the right domain |
| No managed prefs file at all | Fix 2 — profile not delivered; check Intune assignment / device check-in |
| `pgrep` shows nothing after reboot; `sfltool dumpbtm` shows OneDrive disallowed or absent | Fix 3 — deploy the Background Services (`com.apple.servicemanagement`) profile / register login item |
| Not running, user says "it opens then quits" | Fix 6 — reset the sync app |
| `~/Library/CloudStorage/OneDrive-*` missing while user is signed in | Fix 6 — File Provider domain broken; reset |
| KFM set but Desktop/Documents still local | Fix 4 — standalone build, Full Disk Access, correct `TenantID`, no `KFMBlockOptIn` |
| User sees an **empty Desktop** after KFM | Fix 4b — folders were previously redirected to *another* tenant's OneDrive |
| Files show "Excluded from sync" icon | Expected — `EnableODIgnore` / `EnableODIgnoreFolders` match; review rules (Fix 5) |
| App can't open online-only files / hangs on open | Fix 5 — `HydrationDisallowedApps` or a legacy app not File Provider-aware |
| "Your organization doesn't allow you to sync" on a second account | Expected — `AllowTenantList` / `BlockTenantList` / `DisablePersonalSync` doing its job |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Mac enrolled in Intune (or other MDM) — needed for managed prefs, PPPC and background-item profiles
 └─ Correct OneDrive build installed
     ├─ Standalone (pkg)   → domain com.microsoft.OneDrive      ← required for Folder Backup
     └─ Mac App Store      → domain com.microsoft.OneDrive-mac  ← no Folder Backup support
         └─ Managed preferences delivered to the MATCHING domain
             └─ OneDrive quit → prefs deployed → prefs cache refreshed → OneDrive relaunched
                 └─ Background Services profile (macOS 13+) so OneDrive can run at login / in background
                     └─ User signs in (silently via DisableAutoConfig=0 + existing Entra credential, or interactively)
                         └─ Tenant allowed (AllowTenantList / BlockTenantList / DisablePersonalSync)
                             └─ File Provider domain registered → ~/Library/CloudStorage/OneDrive-<Org>
                                 ├─ Files On-Demand (default on) — hydration on open
                                 └─ Folder Backup (KFM) — needs standalone build + Full Disk Access
                                     └─ Network: *.sharepoint.com / OneDrive endpoints reachable, no TLS inspection breakage
```
</details>

---
## Diagnosis & Validation Flow

1. **Confirm build and version**
   ```bash
   defaults read /Applications/OneDrive.app/Contents/Info.plist CFBundleIdentifier
   defaults read /Applications/OneDrive.app/Contents/Info.plist CFBundleShortVersionString
   ```
   Expected: `com.microsoft.OneDrive` and a current build. `com.microsoft.OneDrive-mac` = App Store build —
   every admin key must target `com.microsoft.OneDrive-mac` instead, and Folder Backup won't work.

2. **Confirm the policy the app actually sees**
   ```bash
   defaults read com.microsoft.OneDrive 2>/dev/null | grep -E "KFM|Tenant|DisableAutoConfig|FilesOnDemand|Tier|ODIgnore"
   ```
   Expected: the keys you configured in Intune (managed values override user values in `defaults read`).
   Missing → profile not delivered or wrong domain.

3. **Confirm the File Provider sync root**
   ```bash
   ls -la ~/Library/CloudStorage/
   pluginkit -mAvvv 2>/dev/null | grep -i -B1 -A3 "onedrive" | head -20
   ```
   Expected: `OneDrive-<OrgName>` directory and a OneDrive File Provider extension listed. No extension →
   app install damaged (Fix 6 / reinstall).

4. **Check the sync app's own logs for the failure**
   ```bash
   ls -lt ~/Library/Logs/OneDrive/ | head
   log show --last 30m --predicate 'process CONTAINS "OneDrive"' --style compact | tail -50
   ```
   Expected: recent activity; look for auth errors, "tenant not allowed", disk-space or permission messages.

5. **Folder Backup state**
   ```bash
   ls -la ~ | grep -E "Desktop|Documents"
   ls -ld ~/Library/CloudStorage/OneDrive-*/Desktop ~/Library/CloudStorage/OneDrive-*/Documents 2>/dev/null
   ```
   Expected after a successful move: `Desktop`/`Documents` exist inside the OneDrive root. If they only exist
   under `~` → KFM hasn't run (Fix 4).

---
## Common Fix Paths

<details><summary>Fix 1 — Replace the App Store build with the standalone build</summary>

Folder Backup is only supported on the standalone build. Deploy the standalone `.pkg` via Intune
(**Apps → macOS → Add → macOS app (PKG)**) or as part of the Microsoft 365 Apps for Mac suite.

```bash
# Confirm which build is on disk first
defaults read /Applications/OneDrive.app/Contents/Info.plist CFBundleIdentifier
# After removing the App Store build (user quits OneDrive, drags app to Trash or MDM uninstall),
# verify the standalone package landed:
pkgutil --pkgs | grep -i onedrive
```
Rollback: none needed — the user's cloud data is unaffected; they will need to sign in again and
re-pick the sync location if the App Store build used a different path.
</details>

<details><summary>Fix 2 — Managed preferences not applying</summary>

1. In Intune, build the payload in **Settings catalog → Microsoft OneDrive** (or a Preference file /
   custom `.mobileconfig`) targeting domain **`com.microsoft.OneDrive`** for the standalone build.
2. Force a check-in: Company Portal → **Check settings**, or on the device:
   ```bash
   sudo profiles renew -type configuration 2>/dev/null || true
   ```
3. Microsoft's documented apply sequence is: quit OneDrive → deploy prefs → refresh the preferences
   cache → relaunch:
   ```bash
   osascript -e 'quit app "OneDrive"'
   killall cfprefsd          # refreshes the preferences cache
   open -a OneDrive
   ```
4. Re-check with `defaults read com.microsoft.OneDrive`.
</details>

<details><summary>Fix 3 — OneDrive doesn't start at login / stops in background (macOS 13+)</summary>

Since macOS 13 apps can't run in the background without consent. `OpenAtLogin` is deprecated from sync
app 24.113 — use Background Services instead.

1. Deploy a **Managed Login Items** profile (`com.apple.servicemanagement`) with rules:
   - `LabelPrefix` = `com.microsoft.OneDrive` (`com.microsoft.OneDrive-mac` for the Store app)
   - `BundleIdentifierPrefix` = `com.microsoft.OneDriveLauncher`
   (See `ManagedLoginItems-A/B.md` for the payload mechanics.)
2. On OneDrive 26.027+ and macOS 13+, the login item can be (re)registered from the command line:
   ```bash
   open -a OneDrive --args /createloginitem
   # to undo:
   open -a OneDrive --args /removeloginitem
   ```
3. Verify: `sudo sfltool dumpbtm | grep -i -A4 onedrive` shows it allowed/managed.
</details>

<details><summary>Fix 4 — Folder Backup (Known Folder Move) not happening</summary>

Checklist (all must be true):
- Standalone build (Fix 1).
- **Full Disk Access** granted to OneDrive via a PPPC profile (see `PPPC-A/B.md`).
- `KFMSilentOptIn` (and/or `KFMOptInWithWizard`) set to the **tenant ID** (GUID), not the domain name.
- `KFMBlockOptIn` **not** set — it's ignored when opt-in keys are present, but mixed profiles confuse triage.
- User is signed in to that tenant's account.

```bash
defaults read com.microsoft.OneDrive KFMSilentOptIn
defaults read com.microsoft.OneDrive KFMSilentOptInDesktop 2>/dev/null
defaults read com.microsoft.OneDrive KFMSilentOptInDocuments 2>/dev/null
defaults read com.microsoft.OneDrive KFMBlockOptIn 2>/dev/null
```
Silent move only acts on a folder **once** — changing the Desktop/Documents selection later won't re-move
a folder that already moved. Pair `KFMSilentOptIn` with `KFMOptInWithWizard` so a failed silent move
prompts the user to fix the error.

**Fix 4b — Empty Desktop after KFM:** the user's folders were previously redirected to a *different*
organization's OneDrive. Redirecting to your tenant creates new empty folders. Files must be moved manually
from the other tenant's OneDrive. Where possible, stop backup to the old tenant first.

To reverse Folder Backup centrally, set `KFMBlockOptIn` = `2` (redirects previously backed-up folders back to
the device and stops the setting from running further). `1` only prevents new moves.
</details>

<details><summary>Fix 5 — Files excluded, or apps can't open online-only files</summary>

```bash
defaults read com.microsoft.OneDrive EnableODIgnore 2>/dev/null
defaults read com.microsoft.OneDrive EnableODIgnoreFolders 2>/dev/null
defaults read com.microsoft.OneDrive HydrationDisallowedApps 2>/dev/null
```
- `EnableODIgnore` (wildcards) / `EnableODIgnoreFolders` (exact names, no wildcards) silently skip new
  uploads; items show "Excluded from sync". Changes to folder rules need an OneDrive restart. Removing a rule
  can cause matching local content to start uploading — review first.
- `HydrationDisallowedApps` blocks listed apps from auto-downloading online-only files. If a line-of-business
  app fails on online-only files, either add it deliberately or have the user **Always keep on this device**
  for the working folder.
</details>

<details><summary>Fix 6 — Reset the sync app (crash on launch, broken File Provider domain)</summary>

Resetting disconnects and resyncs; it doesn't delete cloud data. Online-only files will need to rehydrate.

```bash
osascript -e 'quit app "OneDrive"'
# Standalone build:
/Applications/OneDrive.app/Contents/Resources/ResetOneDriveAppStandalone.command
# App Store build:
# /Applications/OneDrive.app/Contents/Resources/ResetOneDriveApp.command
open -a OneDrive
```
Rollback: none — user signs back in. Warn the user first if they have **locally-only** changes that haven't
uploaded (check the activity center for pending uploads before resetting).
</details>

---
## Escalation Evidence

```
Ticket: ____________     Tenant ID: ____________________________
User UPN: ______________________   Device serial: ______________
macOS version: ________   OneDrive build (CFBundleShortVersionString): __________
Build type:  [ ] Standalone (com.microsoft.OneDrive)   [ ] App Store (com.microsoft.OneDrive-mac)
Managed prefs present in /Library/Managed Preferences?  [ ] Yes  [ ] No
Keys configured (paste `defaults read com.microsoft.OneDrive`): 
____________________________________________________________
File Provider root ~/Library/CloudStorage/OneDrive-*:  [ ] present  [ ] missing
Background item (sfltool dumpbtm) allowed?  [ ] Yes  [ ] No
Full Disk Access profile deployed?  [ ] Yes  [ ] No
Symptom / exact error text: _________________________________
Reset performed?  [ ] Yes (time: ______)  [ ] No
Logs attached: ~/Library/Logs/OneDrive/ (zipped)  [ ]   Get-OneDriveMacHealth.sh CSV  [ ]
```

---
## 🎓 Learning Pointers
- The **domain mismatch** (standalone `com.microsoft.OneDrive` vs Store `com.microsoft.OneDrive-mac`) is the Mac equivalent of targeting the wrong registry hive — check the bundle ID before anything else. [Deploy and configure the OneDrive sync app for Mac](https://learn.microsoft.com/en-us/sharepoint/deploy-and-configure-on-macos)
- Folder Backup on Mac has rollout guidance: prompt ≤5,000 devices/day, silent ≤1,000 existing devices/day (limits shared with Windows). [Redirect and move macOS known folders to OneDrive](https://learn.microsoft.com/en-us/sharepoint/redirect-known-folders-macos)
- `OpenAtLogin` is on its way out — Background Services (`com.apple.servicemanagement`) is the supported way to keep OneDrive running on macOS 13+. See `macOS/Troubleshooting/ManagedLoginItems-A.md`.
- Use `EnableSyncAdminReports` to get Mac sync health into the Microsoft 365 Apps admin center instead of chasing logs one device at a time. [OneDrive sync reports](https://learn.microsoft.com/en-us/sharepoint/sync-health)
- Microsoft's baseline for a well-configured sync estate (Files On-Demand on, silent KFM, tenant allow list): [Recommended sync app configuration](https://learn.microsoft.com/en-us/sharepoint/ideal-state-configuration)
- Windows-side equivalent and cross-platform sync errors: `M365/SharePoint-OneDrive/Sync-Issues-A.md`.
