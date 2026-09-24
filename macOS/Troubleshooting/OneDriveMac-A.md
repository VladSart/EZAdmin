# OneDrive Sync App for Mac (Files On-Demand, Folder Backup, Managed Preferences) — Reference Runbook (Mode A: Deep Dive)
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

**Covers**
- The OneDrive sync app on macOS (standalone `.pkg` build and Mac App Store build) syncing OneDrive for
  work or school and SharePoint libraries.
- Admin configuration through managed preferences (Intune Settings catalog / preference file / custom
  `.mobileconfig`, or Jamf/Munki equivalents).
- Files On-Demand on Apple's File Provider framework, Folder Backup (Known Folder Move, "KFM"), tenant
  restrictions, exclusion rules, update rings, background-item registration on macOS 13+.

**Does not cover**
- Windows sync client behaviour and GPO/ADMX — see `M365/SharePoint-OneDrive/Sync-Issues-A/B.md`.
- Installing/activating the rest of Microsoft 365 Apps for Mac — see `macOS/Troubleshooting/M365AppsMac-A/B.md`.
- SharePoint site permissions / sharing — see `M365/SharePoint-OneDrive/Permissions-A/B.md`.

**Assumptions:** Intune-managed Macs (User Approved MDM), Entra ID accounts, commercial cloud.

---
## How It Works

<details><summary>Full architecture</summary>

### Two builds, two preference domains

| | Standalone (pkg) | Mac App Store |
|---|---|---|
| Preference domain | `com.microsoft.OneDrive` | `com.microsoft.OneDrive-mac` |
| Admin `.plist` location | `/Library/Preferences/com.microsoft.OneDrive.plist` | `/Library/Containers/com.microsoft.OneDrive-mac/Data/Library/Preferences/com.microsoft.OneDrive-mac.plist` |
| Folder Backup (KFM) | Supported | **Not supported** |
| Default folder location lockable | Yes (path created if missing) | No (path must already exist) |

The **keys are identical** across builds; only the domain differs. An Intune profile that writes
`KFMSilentOptIn` to `com.microsoft.OneDrive` does nothing to an App Store install. MDM-delivered values
surface under `/Library/Managed Preferences/<domain>.plist` and take precedence over user-set values.

A few keys live in *other* domains:
- `Tier` (update ring) → `com.microsoft.OneDriveUpdater` (`~/Library/Preferences/com.microsoft.OneDriveUpdater.plist`).
- `DisableOfflineMode` / `DisableOfflineModeForExternalLibraries` (offline mode for OneDrive **on the web**) →
  `com.microsoft.SharePoint-mac` and the `UBF8T346G9.OneDriveStandaloneSuite` group container.

### Preference apply cycle

Microsoft's documented order is: define the `.plist` values → **quit OneDrive** → deploy → **refresh the
preferences cache** → relaunch. OneDrive reads settings at start, so a live profile push to a running
client can appear to "not apply" until the next launch. `cfprefsd` caches preferences; `killall cfprefsd`
is the usual cache refresh when testing by hand.

### Files On-Demand on File Provider

Current OneDrive builds on macOS run Files On-Demand through Apple's **File Provider** framework. The
sync root lives under `~/Library/CloudStorage/OneDrive-<OrgName>` (Finder shows it in the sidebar under
Locations). Consequences:
- Placeholders are managed by macOS, so "free up space" / "always keep on this device" are Finder actions
  backed by the File Provider extension shipped inside `OneDrive.app`.
- Apps that walk the whole tree (backup agents, indexers, some AV) can trigger mass hydration.
  `HydrationDisallowedApps` (JSON list of app IDs + max bundle/build versions) stops named apps from
  auto-downloading online-only files.
- Microsoft recommends leaving Files On-Demand **on**; it's on by default for Mac.

### Folder Backup (KFM) on Mac

Keys and semantics:

| Key | Type | Effect |
|---|---|---|
| `KFMOptInWithWizard` | string (tenant ID) | Shows the Folder Backup wizard; reminder in activity center until done |
| `KFMSilentOptIn` | string (tenant ID) | Moves folders with no user interaction |
| `KFMSilentOptInWithNotification` | bool | Notify user after silent move |
| `KFMSilentOptInDesktop` / `KFMSilentOptInDocuments` | bool | Pick folders; neither set = both move |
| `KFMBlockOptOut` | bool | Disables **Stop Backup** |
| `KFMBlockOptIn` | int `1` / `2` | `1` prevents moves; `2` redirects previously backed-up folders back to the device and stops |

Rules that bite:
- Requires the **standalone** build and **Full Disk Access** for OneDrive (grant via PPPC profile).
- Silent move acts on a folder **once**; changing the Desktop/Documents selection afterwards doesn't
  re-move an already-moved folder.
- `KFMBlockOptIn` doesn't take effect if `KFMOptInWithWizard` or `KFMSilentOptIn` is set.
- If the folders were already redirected to **another organization's** OneDrive, redirecting to yours
  creates **new, empty** Desktop/Documents — the user sees an empty desktop. Migration of the old content
  is manual.
- Rollout pacing (shared with Windows): wizard ≤5,000 devices/day and ≤20,000/week; silent ≤1,000 existing
  devices/day and ≤4,000/week. Use `AutomaticUploadBandwidthPercentage` temporarily for heavy folders.

### Account and tenant controls

| Key | Purpose |
|---|---|
| `DisableAutoConfig` = 1 | Prevent silent sign-in using an existing Entra credential available to Microsoft apps |
| `AllowTenantList` (dict of tenant IDs → true) | Only listed tenants may sync; takes priority over block list. **Don't set both** |
| `BlockTenantList` (dict of tenant IDs → true) | Listed tenants blocked; the boolean `true` is mandatory per ID |
| `BlockExternalSync` | Block syncing libraries shared from other orgs |
| `DisablePersonalSync` | Block personal (MSA) OneDrive; signs out an already-added personal account |

### Background execution (macOS 13+)

macOS 13 requires consent for background items. OneDrive's daemon must run in the background, so deploy
a `com.apple.servicemanagement` (Managed Login Items) payload with a `LabelPrefix` rule of
`com.microsoft.OneDrive` (Store: `com.microsoft.OneDrive-mac`) and a `BundleIdentifierPrefix` rule of
`com.microsoft.OneDriveLauncher`. `OpenAtLogin` is deprecated from sync app 24.113. From OneDrive 26.027
on macOS 13+, `open -a OneDrive --args /createloginitem` / `/removeloginitem` register or unregister the
login item and exit without starting the sync client.

### Updates

The sync app updates through rings: Insiders → Production (default) → Enterprise/Deferred (up to a 60-day
controllable window). `Tier` pins the ring and removes user choice.

</details>

---
## Dependency Stack

```
[7] User experience: Finder sidebar OneDrive-<Org>, Desktop/Documents backed up, files open on demand
[6] Folder Backup (KFM): standalone build + Full Disk Access + KFM keys w/ tenant ID
[5] File Provider domain registered by OneDrive's extension → ~/Library/CloudStorage/OneDrive-<Org>
[4] Signed-in account in an allowed tenant (Allow/Block lists, DisablePersonalSync, DisableAutoConfig)
[3] OneDrive running: Background Services profile / login item allowed (macOS 13+)
[2] Managed prefs in the MATCHING domain, applied after quit + cache refresh + relaunch
[1] Correct build installed (standalone vs App Store), supported macOS, current OneDrive version
[0] MDM enrollment (User Approved) + network reach to Microsoft 365 / SharePoint endpoints
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| None of the admin settings apply | Profile targets `com.microsoft.OneDrive` but App Store build installed (or reverse) | `defaults read /Applications/OneDrive.app/Contents/Info.plist CFBundleIdentifier` |
| Settings apply only after reboot | OneDrive was running at profile delivery; prefs read at launch | Quit → `killall cfprefsd` → relaunch |
| Folder Backup never starts | App Store build, no Full Disk Access, domain name instead of tenant GUID | `defaults read com.microsoft.OneDrive KFMSilentOptIn` |
| Only Desktop moved, not Documents | `KFMSilentOptInDesktop` true, `…Documents` unset/false; or Documents already moved elsewhere | Read both keys |
| Empty Desktop after rollout | Folders previously redirected to another tenant | Ask user; check other account in OneDrive prefs |
| User can't stop backup | `KFMBlockOptOut` = true (by design) | `defaults read … KFMBlockOptOut` |
| OneDrive not running after login | Background item blocked / no servicemanagement profile | `sudo sfltool dumpbtm \| grep -i onedrive` |
| "Excluded from sync" icons | `EnableODIgnore` / `EnableODIgnoreFolders` match | Read keys |
| Backup tool / indexer downloads entire OneDrive | App hydrating placeholders | Add to `HydrationDisallowedApps` |
| Can't add second work account | Tenant not in `AllowTenantList` / in `BlockTenantList` | Read keys, compare tenant IDs |
| Mass-delete prompt when user tidies folders | `LocalMassDeleteFileDeleteThreshold` (default 200 files) | Expected — confirm or restore |
| Downloads stop, "not enough space" | `MinDiskSpaceLimitInMB` reached | `df -h ~` |

---
## Validation Steps

1. **Build and domain**
   `defaults read /Applications/OneDrive.app/Contents/Info.plist CFBundleIdentifier`
   Good: `com.microsoft.OneDrive`. Bad: `com.microsoft.OneDrive-mac` when KFM is required.

2. **Managed preferences delivered**
   `defaults read "/Library/Managed Preferences/com.microsoft.OneDrive"`
   Good: your configured keys. Bad: "Domain … does not exist" → profile not delivered or wrong domain.

3. **Effective preferences**
   `defaults read com.microsoft.OneDrive | grep -E "KFM|Tenant|ODIgnore|Hydration"`
   Good: managed values shown. Bad: stale user values → app not restarted since delivery.

4. **Running & background item allowed**
   `pgrep -lx OneDrive` and `sudo sfltool dumpbtm | grep -i -A4 onedrive`
   Good: process present; item allowed. Bad: disallowed by user in System Settings → Login Items.

5. **File Provider root**
   `ls ~/Library/CloudStorage/` → Good: `OneDrive-<Org>`. Bad: absent while signed in → reset.

6. **Folder Backup**
   `ls -ld ~/Library/CloudStorage/OneDrive-*/{Desktop,Documents}`
   Good: both exist inside OneDrive. Bad: only under `~`.

7. **Full Disk Access (PPPC) profile present**
   `sudo profiles show -type configuration | grep -i -B2 -A6 "SystemPolicyAllFiles"`
   Good: an entry for `com.microsoft.OneDrive`. Bad: none → KFM can't move folders.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Install:** Right build? If users installed from the App Store themselves and you need KFM,
replace it. Check `pkgutil --pkgs | grep -i onedrive` for the standalone receipt.

**Phase 2 — Policy delivery:** Is the profile assigned to the device/user group? Is the device checking in?
Does `/Library/Managed Preferences/` contain the domain? If yes but the app ignores it, the build/domain
don't match.

**Phase 3 — Launch & background:** macOS 13+ Background Items. Is the servicemanagement profile present?
Did the user switch OneDrive off in System Settings → General → Login Items & Extensions?

**Phase 4 — Sign-in:** Silent sign-in requires `DisableAutoConfig` not set to 1 and an existing Entra
credential (e.g. from Company Portal / Platform SSO). Tenant allow/block errors show at sign-in.

**Phase 5 — File Provider:** Sync root present? Extension registered (`pluginkit -mAvvv | grep -i onedrive`)?
If the domain is wedged, reset (Playbook 4).

**Phase 6 — Folder Backup:** standalone + FDA + tenant GUID + not previously moved to another tenant.
Read `~/Library/Logs/OneDrive/` for the move failure reason.

**Phase 7 — Steady state:** Exclusions, hydration blocks, bandwidth/disk limits, update ring.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Baseline Intune configuration for Mac OneDrive (standalone)</summary>

1. **App:** deploy the standalone OneDrive `.pkg` (or Microsoft 365 Apps for Mac suite, which includes it).
2. **PPPC:** grant `com.microsoft.OneDrive` **SystemPolicyAllFiles** (Full Disk Access). See `PPPC-A.md`.
3. **Managed Login Items:** `com.apple.servicemanagement` rules — `LabelPrefix com.microsoft.OneDrive`,
   `BundleIdentifierPrefix com.microsoft.OneDriveLauncher`.
4. **Settings catalog → Microsoft OneDrive** (domain `com.microsoft.OneDrive`):
   - `KFMSilentOptIn` = `<tenantId>` and `KFMOptInWithWizard` = `<tenantId>` (fallback prompt)
   - `KFMBlockOptOut` = true (if policy requires)
   - `AllowTenantList` = `{ <tenantId>: true }`
   - `EnableSyncAdminReports` = 1
   - Leave Files On-Demand at default (on)
5. Pilot on a small ring; respect the per-day KFM rollout limits for existing devices.
</details>

<details><summary>Playbook 2 — Migrate App Store installs to standalone</summary>

1. Inventory: Intune **Apps → Monitor → Discovered apps**, filter "OneDrive", split by bundle ID.
2. Deploy the standalone pkg as **Required** to the affected group.
3. Uninstall the App Store build (MDM uninstall if it was VPP-deployed; otherwise user action).
4. Re-target any existing `com.microsoft.OneDrive-mac` preference profile to `com.microsoft.OneDrive`.
5. Validate with Validation Steps 1–3.
Rollback: reassign the Store app; the cloud data is unaffected either way.
</details>

<details><summary>Playbook 3 — Reverse Folder Backup centrally</summary>

1. Remove `KFMSilentOptIn` / `KFMOptInWithWizard` / `KFMBlockOptOut` from the profile.
2. Add `KFMBlockOptIn` = `2` — redirects previously backed-up folders back to the device and stops.
3. After devices report back, you can switch to `1` to keep preventing new moves.
**Destructive-ish:** content moves back to local disk; ensure disk space and that users understand the
files are no longer backed up.
</details>

<details><summary>Playbook 4 — Reset a broken client</summary>

```bash
osascript -e 'quit app "OneDrive"'
/Applications/OneDrive.app/Contents/Resources/ResetOneDriveAppStandalone.command   # standalone
# /Applications/OneDrive.app/Contents/Resources/ResetOneDriveApp.command           # App Store
open -a OneDrive
```
Check the activity center for pending uploads **before** resetting. After reset the user signs in again;
online-only files rehydrate on demand.
</details>

<details><summary>Playbook 5 — Lock down cross-tenant sync</summary>

- Use **either** `AllowTenantList` (preferred: allow-list your tenant and trusted partners) **or**
  `BlockTenantList` — not both. Each tenant ID entry must carry the boolean `true`.
- Add `DisablePersonalSync` = true to block consumer OneDrive.
- Add `BlockExternalSync` = true to stop syncing libraries shared from other orgs.
Existing accounts in disallowed tenants stop syncing; warn users before rollout.
</details>

---
## Evidence Pack

Run `macOS/Scripts/Get-OneDriveMacHealth.sh` as the affected user (it writes a CSV to `/tmp`), then:

```bash
#!/bin/bash
# Collect OneDrive for Mac evidence bundle (run as the affected user)
OUT="/tmp/OneDriveMacEvidence_$(scutil --get ComputerName | tr ' ' '_')_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"
sw_vers > "$OUT/sw_vers.txt"
defaults read /Applications/OneDrive.app/Contents/Info.plist > "$OUT/onedrive_info_plist.txt" 2>&1
defaults read com.microsoft.OneDrive > "$OUT/prefs_effective.txt" 2>&1
defaults read com.microsoft.OneDrive-mac > "$OUT/prefs_effective_store.txt" 2>&1
defaults read com.microsoft.OneDriveUpdater > "$OUT/prefs_updater.txt" 2>&1
ls -la "/Library/Managed Preferences/" > "$OUT/managed_prefs_dir.txt" 2>&1
ls -la ~/Library/CloudStorage/ > "$OUT/cloudstorage.txt" 2>&1
pluginkit -mAvvv 2>/dev/null | grep -i -B1 -A3 onedrive > "$OUT/pluginkit.txt"
log show --last 2h --predicate 'process CONTAINS "OneDrive"' --style compact > "$OUT/unified_log.txt" 2>&1
cp -R ~/Library/Logs/OneDrive "$OUT/OneDriveLogs" 2>/dev/null
( cd /tmp && zip -qr "$(basename "$OUT").zip" "$(basename "$OUT")" )
echo "Evidence: $OUT.zip"
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Build type | `defaults read /Applications/OneDrive.app/Contents/Info.plist CFBundleIdentifier` |
| Version | `defaults read /Applications/OneDrive.app/Contents/Info.plist CFBundleShortVersionString` |
| Managed prefs delivered | `defaults read "/Library/Managed Preferences/com.microsoft.OneDrive"` |
| Effective prefs | `defaults read com.microsoft.OneDrive` |
| Update ring | `defaults read com.microsoft.OneDriveUpdater Tier` |
| Refresh prefs cache | `killall cfprefsd` |
| Quit / start | `osascript -e 'quit app "OneDrive"'` / `open -a OneDrive` |
| Register login item (26.027+) | `open -a OneDrive --args /createloginitem` |
| Background items | `sudo sfltool dumpbtm \| grep -i -A4 onedrive` |
| Sync root | `ls ~/Library/CloudStorage/` |
| File Provider extension | `pluginkit -mAvvv \| grep -i onedrive` |
| Logs | `ls -lt ~/Library/Logs/OneDrive/` |
| Unified log | `log show --last 30m --predicate 'process CONTAINS "OneDrive"'` |
| Reset (standalone) | `/Applications/OneDrive.app/Contents/Resources/ResetOneDriveAppStandalone.command` |
| Pkg receipt | `pkgutil --pkgs \| grep -i onedrive` |

---
## 🎓 Learning Pointers
- Full key reference, including which keys live outside the main domain (`Tier`, offline-mode keys): [Deploy and configure the OneDrive sync app for Mac](https://learn.microsoft.com/en-us/sharepoint/deploy-and-configure-on-macos)
- KFM on Mac: prerequisites (standalone + Full Disk Access), cross-tenant empty-desktop caveat, pacing limits: [Redirect and move macOS known folders to OneDrive](https://learn.microsoft.com/en-us/sharepoint/redirect-known-folders-macos)
- Microsoft's opinionated baseline for sync settings: [Recommended sync app configuration](https://learn.microsoft.com/en-us/sharepoint/ideal-state-configuration)
- Update rings and how Deferred/Enterprise gives you a 60-day window: [OneDrive sync app update process](https://learn.microsoft.com/en-us/sharepoint/sync-client-update-process)
- Fleet-level visibility without touching each Mac: [OneDrive sync reports in the Apps Admin Center](https://learn.microsoft.com/en-us/sharepoint/sync-health)
- Related repo runbooks: `macOS/Troubleshooting/PPPC-A.md` (Full Disk Access), `ManagedLoginItems-A.md` (background items), `M365AppsMac-A.md` (suite install/MAU).
