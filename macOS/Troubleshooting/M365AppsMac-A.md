# Microsoft 365 Apps for Mac (Install, Activation & MAU Updates) — Reference Runbook (Mode A: Deep Dive)
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

**In scope**
- Microsoft 365 for Mac (subscription) and Office LTSC for Mac 2021/2024 (volume licence) on Intune-managed Macs.
- Deployment via the Intune **Microsoft 365 Apps for macOS** app type, and via individual `.pkg` / VPP alternatives.
- Activation/licensing: subscription sign-in, volume licence serialisation, licence precedence and reset.
- Microsoft AutoUpdate (MAU): preference domain `com.microsoft.autoupdate2`, the `msupdate` CLI, channels, local caching, and update deadlines.

**Out of scope** (see other runbooks)
- Platform SSO / Enterprise SSO plug-in registration → `Platform-SSO-A.md`
- PPPC profile delivery mechanics → `PPPC-A.md`
- Windows Microsoft 365 Apps (Click-to-Run, update channels) → `../../M365/Apps/Deployment-UpdateChannels-A.md`
- Outlook for Mac mailbox/profile problems (Exchange side) → `../../M365/Exchange/Outlook-Client-A.md`

**Assumptions**: engineer has local admin (or a remote shell/Intune shell script) on the Mac, and Intune admin rights for the tenant.

---
## How It Works

<details><summary>Full architecture</summary>

### 1. Packaging model — sandboxed, per-app bundles
Office for Mac is not a monolithic installer like Click-to-Run on Windows. Each app (Word, Excel,
PowerPoint, Outlook, OneNote, OneDrive, Teams) is an independent, Apple-sandboxed `.app` bundle signed by
Microsoft (Team ID `UBF8T346G9`). Consequences:

- **Bundles are immutable after signing.** Microsoft explicitly says you cannot customise the app bundle
  before or after deployment — all customisation is done through *preferences*, never by editing the app.
- **Updates replace whole bundles.** There is no concept of an individual security patch. MAU downloads a
  new (delta or full) bundle per app, so you can stage Word and PowerPoint while holding Excel back.
- **Shared data lives in group containers.** Apps share identity, licensing and some caches through
  `~/Library/Group Containers/UBF8T346G9.Office` (and related `UBF8T346G9.*` containers). Per-app
  preferences live in `~/Library/Containers/<bundle-id>/Data/Library/Preferences/<bundle-id>.plist`.

### 2. Intune delivery — the Microsoft 365 Apps for macOS app type
The built-in app type packages Word, Excel, PowerPoint, Outlook, OneNote, Teams and OneDrive plus MAU and
presents them as **one** app in Intune and Company Portal. Design constraints worth knowing:

| Behaviour | Why it matters |
|---|---|
| No configuration options in the app type | Channel, deadlines, first-run and Outlook settings must be separate profiles/preference files |
| Cannot be uninstalled via Intune | Removal/downgrade is a scripted or manual task |
| Installing while apps are open can lose unsaved work | Schedule Required assignments carefully; prefer Available for existing users |
| Suite, not à-la-carte | For a subset of apps, deploy individual Microsoft-hosted `.pkg` files as macOS LOB/PKG apps instead |

### 3. Licensing — three models, one precedence rule
| Model | How it's applied | Where state lives (typical) |
|---|---|---|
| Microsoft 365 subscription | User signs in with a licensed work account; activation is per user | Per-user identity/licence cache in the Office group container and keychain |
| Office LTSC for Mac (volume) | Volume License Serializer `.pkg` writes a **machine-wide** licence | `/Library/Preferences/com.microsoft.office.licensingV2.plist` |
| Retail / one-time purchase | Activated against a Microsoft account | Per-user licence cache |

The machine-wide volume licence is the classic trap: when present it is used instead of the subscription
licence, so a device that was once LTSC and is now meant to be Microsoft 365 quietly stays LTSC — no
Copilot/subscription features, "Volume License" in *About*. The **License Removal Tool** wipes all licence
state; removing only `licensingV2.plist` is the surgical fix for this specific case.

Sign-in itself uses the Microsoft identity stack (MSAL). If the Microsoft Enterprise SSO plug-in or
Platform SSO is deployed and healthy, the Office sign-in is satisfied silently from the device's SSO
token; if SSO is misconfigured, sign-in prompts or loops are the visible symptom — which is why
activation loops should be triaged alongside `app-sso platform -s`.

### 4. Microsoft AutoUpdate (MAU)
MAU is its own app (`/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app`) with a
privileged daemon. Behaviour is controlled by the `com.microsoft.autoupdate2` preference domain:

| Key | Purpose |
|---|---|
| `HowToCheck` | `Manual`, `AutomaticCheck`, `AutomaticDownload` — use `Manual` only when another tool owns patching |
| `ChannelName` | Update channel (e.g. `Current`, `Preview`, `Beta`) |
| `UpdateCache` | URL of an internal caching server instead of the Office CDN |
| `UpdateDeadline.DaysBeforeForcedQuit` | Deadline N days after an update is detected (per-app via the `Applications` dictionary) |
| `UpdateDeadline.ApplicationsForcedUpdateSchedule` | Deadline at a fixed UTC date/time tied to a specific version |
| `UpdateDeadline.StartAutomaticUpdates` | Days before deadline that automatic download+install mode starts (default 3) |
| `UpdateDeadline.FinalCountDown` | Countdown minutes before forced quit (10–720, default 60; MAU 4.51+) |

By default MAU checks every 12 hours. **Managed** (configuration-profile) values take precedence over
user values and are also written into the user's preferences — which is why deleting a profile that set
a deadline does not remove the deadline; you must push `0` values.

`msupdate` (MAU 3.18+) is the admin CLI. It communicates with the MAU daemon over XPC, which can raise a
first-run privacy prompt when invoked by a management agent — pre-approve with a PPPC profile. Key rules:
- If MAU itself has a pending update, it must install first; other apps wait.
- `--version` pinning only works for Word, Excel, PowerPoint, Outlook and OneNote.
- `-t`/`-m` (terminate delay + banner message) require MAU 4.24+.
- App IDs: `MSWD2019` Word, `XCEL2019` Excel, `PPT32019` PowerPoint, `OPIM2019` Outlook, `ONMC2019`
  OneNote, `ONDR18` OneDrive, `MSau04` MAU, `IMCP01` Company Portal, `WDAV00` Defender for Endpoint,
  `MSRD10` Windows App, `MSRH01` Remote Help. Use exact casing from management tools.
- Teams is not controllable through `msupdate`; it self-updates on its own cadence.

### 5. macOS support floor
Office for Mac only receives updates on macOS releases Microsoft currently supports (historically the
current release plus the two prior). Older macOS keeps working but silently stops receiving updates —
including security fixes. Check the current floor in the Office for Mac release notes before assuming a
"stuck build" is an MAU fault.
</details>

---
## Dependency Stack

```
[7] User experience: apps open licensed, on the intended build, updates land without disruption
[6] MAU policy: HowToCheck / ChannelName / UpdateCache / UpdateDeadline.* as designed (managed profile)
[5] MAU runtime: MAU current (MSau04), daemon healthy, msupdate PPPC-approved, CDN/cache reachable
[4] Licence state: subscription sign-in succeeds; no stale machine-wide licensingV2.plist
[3] Identity: user licensed in Entra for desktop apps; SSO plug-in / Platform SSO healthy (if used)
[2] App bundles: Microsoft-signed (UBF8T346G9) bundles present in /Applications
[1] Delivery: Intune Microsoft 365 Apps for macOS suite (or PKG apps) assigned + installed
[0] Platform: Mac enrolled in Intune, checking in, on a Microsoft-supported macOS release
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Suite shows Failed in Intune | Device not checking in, disk space, conflicting partial install | `profiles status -type enrollment`, `df -h /`, Intune error code |
| Only some apps present | User deleted apps, or individual PKG deployment scoped differently | `ls /Applications | grep -i microsoft` |
| "Unlicensed Product" / read-only | User not licensed for desktop apps, or licence cache corrupt | Entra licence, *About Word*, License Removal Tool |
| "Volume License" on subscription device | Leftover `com.microsoft.office.licensingV2.plist` | `ls -l /Library/Preferences/com.microsoft.office.licensingV2.plist` |
| Missing subscription features (e.g. Copilot) | Same as above, or channel/build too old | *About Word* + `msupdate --list` |
| Sign-in loop / window closes | Cached identity corrupt; SSO extension misconfigured | Keychain Office entries, `app-sso platform -s` |
| Build never moves | `HowToCheck=Manual`, dead `UpdateCache`, MAU needs update, unsupported macOS | `msupdate --config`, `msupdate --list`, `sw_vers` |
| `msupdate` fails only from scripts | Missing PPPC approval for XPC | `profiles -P`, run interactively to compare |
| Apps force-closed during the day | `UpdateDeadline.*` enforcement | `defaults read com.microsoft.autoupdate2` |
| Deadline persists after profile removed | Managed values copied to user prefs | Push `0` values via managed profile |
| Updates download slowly / fail on-prem only | SSL inspection or proxy blocking the Office CDN | `curl -sI https://officecdnmac.microsoft.com` |

---
## Validation Steps

1. **Enrolment**
   ```bash
   sudo profiles status -type enrollment
   ```
   Good: `Enrolled via DEP: Yes` (or `No` for user-initiated) and `MDM enrollment: Yes (User Approved)`.
   Bad: `MDM enrollment: No` → fix enrolment before touching Office (`ADE-Enrollment-B.md`).

2. **Bundle integrity**
   ```bash
   codesign --verify --deep --strict "/Applications/Microsoft Word.app" && echo OK
   ```
   Good: `OK`. Bad: `invalid signature` / `code object is not signed` → reinstall.

3. **Build inventory**
   ```bash
   defaults read "/Applications/Microsoft Word.app/Contents/Info.plist" CFBundleShortVersionString
   ```
   Good: matches (or is within one release of) the current build in *Update history for Office for Mac*.

4. **Licence state**
   ```bash
   ls -l /Library/Preferences/com.microsoft.office.licensingV2.plist 2>/dev/null || echo "no volume licence"
   ```
   Good (subscription estate): `no volume licence`. Bad: file present on a subscription device.

5. **MAU configuration**
   ```bash
   "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/msupdate" --config
   ```
   Good: `HowToCheck` automatic, expected `ChannelName`, `UpdateCache` either absent or reachable.

6. **Pending updates**
   ```bash
   "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/msupdate" --list
   ```
   Good: no updates, or updates listed that install on `--install`. Bad: repeated identical list after install → check CDN/cache and MAU version.

7. **Managed profile presence**
   ```bash
   sudo profiles -P -o stdout | grep -i -A2 "com.microsoft.autoupdate2"
   ```
   Good: the MAU profile you expect is present exactly once. Bad: two profiles with conflicting values.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Delivery.** Intune status → device check-in → disk space (`df -h /` — the suite needs several GB free) → conflicting individual PKG apps → manual install test from the Microsoft 365 portal.

**Phase 2 — First launch & activation.** *About Word* licence line → Entra licence assignment → stale volume licence file → License Removal Tool → re-sign-in → SSO plug-in health if sign-in loops.

**Phase 3 — Ongoing updates.** `msupdate --config` → MAU self-update (`MSau04`) → channel → cache server → CDN reachability through proxy/SSL inspection → macOS support floor → deadlines.

**Phase 4 — Fleet policy.** Enumerate Intune profiles targeting `com.microsoft.autoupdate2` and Office preference domains; look for overlap/conflict between a legacy Jamf-era profile and a new Intune profile (common after `JamfMigration-B.md` projects).

---
## Remediation Playbooks

<details><summary>Playbook 1 — Convert a device from LTSC volume licence to Microsoft 365 subscription</summary>

```bash
# 1. Quit Office apps
osascript -e 'tell application "Microsoft Word" to quit' 2>/dev/null
# 2. Back up and remove the machine-wide volume licence
sudo cp /Library/Preferences/com.microsoft.office.licensingV2.plist /tmp/licensingV2.plist.bak 2>/dev/null
sudo rm -f /Library/Preferences/com.microsoft.office.licensingV2.plist
# 3. Ensure the device is on current subscription builds (LTSC builds are also updated by MAU)
"/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/msupdate" --install
```
User then opens Word and signs in with the licensed work account. Also remove the Volume License Serializer
package from any Intune assignment so it is not re-applied.

Rollback: restore `/tmp/licensingV2.plist.bak` to `/Library/Preferences/`.
</details>

<details><summary>Playbook 2 — Standardise MAU across the fleet via Intune</summary>

Create **Devices → Configuration → macOS → Templates → Preference file** (or a custom `.mobileconfig`)
for domain `com.microsoft.autoupdate2`:

```xml
<key>HowToCheck</key>        <string>AutomaticDownload</string>
<key>ChannelName</key>       <string>Current</string>
<key>UpdateDeadline.DaysBeforeForcedQuit</key> <integer>5</integer>
<key>UpdateDeadline.StartAutomaticUpdates</key> <integer>2</integer>
<key>UpdateDeadline.FinalCountDown</key> <integer>120</integer>
```
Pilot on a ring group first. Pair with a PPPC profile for `msupdate` if you also run it from Intune shell scripts.

Rollback: to remove deadlines, **edit** the profile to set `DaysBeforeForcedQuit` and `StartAutomaticUpdates` to `0`, sync, then retire the profile.
</details>

<details><summary>Playbook 3 — Emergency push of a specific build (zero-day response)</summary>

Deploy as an Intune macOS shell script (run as root, run once):
```bash
#!/bin/bash
MSU="/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/msupdate"
[ -x "$MSU" ] || { echo "MAU missing"; exit 1; }
"$MSU" --install --apps MSau04 --wait 600
"$MSU" --install --apps MSWD2019 XCEL2019 PPT32019 OPIM2019 ONMC2019 \
  -t 600 -m "Office will close in 10 minutes to install a security update. Please save your work." \
  --wait 1800
"$MSU" --list
```
`-t`/`-m` need MAU 4.24+. Pin a version with `--version <build>` for a single app when needed.
</details>

<details><summary>Playbook 4 — Full Office reset for a single user (last resort)</summary>

1. Collect evidence first (`Get-M365MacAppsHealth.sh`).
2. Sign out of Office, quit apps, run the License Removal Tool.
3. Remove Office identity entries from the user's login keychain (Keychain Access → search `Office`).
4. Reinstall the suite via Company Portal.
5. Sign in and verify *About Word*.

Destructive note: do **not** delete `~/Library/Group Containers/UBF8T346G9.Office` wholesale for Outlook
users — it can contain the Outlook profile/local cache; re-download can be large and on-my-computer
(legacy) data could be lost. Back up first.
</details>

---
## Evidence Pack

Run the companion script and attach the CSV:

```bash
sudo bash Get-M365MacAppsHealth.sh
# optional: also attempt a live 'msupdate --list' (network)
sudo bash Get-M365MacAppsHealth.sh --check-updates
```

Portal-side evidence to add manually: Intune device install status + error code for the suite, the user's
licence assignment (Entra → Users → Licenses), and exported MAU configuration profile(s).

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| App build | `defaults read "/Applications/Microsoft Word.app/Contents/Info.plist" CFBundleShortVersionString` |
| Signature check | `codesign -dv --verbose=2 "/Applications/Microsoft Excel.app"` |
| MAU config | `"$MSU" --config` (MSU = `/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/msupdate`) |
| MAU config (plist) | `"$MSU" --config --format plist` |
| List updates | `"$MSU" --list` |
| Update everything | `"$MSU" --install` |
| Update MAU only | `"$MSU" --install --apps MSau04` |
| Pin Outlook build | `"$MSU" --install --apps OPIM2019 --version <build>` |
| Graceful forced update | `"$MSU" --install --apps XCEL2019 -t 180 -m "Excel will close in 3 minutes"` |
| Set check mode | `defaults write com.microsoft.autoupdate2 HowToCheck -string AutomaticDownload` |
| Volume licence present? | `ls -l /Library/Preferences/com.microsoft.office.licensingV2.plist` |
| Managed profiles | `sudo profiles -P -o stdout \| grep -i autoupdate2` |
| CDN reachability | `curl -sI https://officecdnmac.microsoft.com` |
| Enrolment | `sudo profiles status -type enrollment` |

---
## 🎓 Learning Pointers

- **Preferences, not packages.** Because Office for Mac follows Apple sandboxing, you customise via `defaults`/profiles in the app container, never the bundle — design your Intune config around preference domains. [Deploy preferences for Office for Mac](https://learn.microsoft.com/en-us/microsoft-365-apps/mac/deploy-preferences-for-office-for-mac)
- **Know which tool owns patching.** Set `HowToCheck=Manual` only when another system (e.g. a patch-management platform) is deploying bundles — otherwise you've switched updates off. [Deploy updates for Office for Mac](https://learn.microsoft.com/en-us/microsoft-365-apps/mac/deploy-updates-for-office-for-mac)
- **msupdate is your zero-day lever** — pin versions, force MAU first, and warn users with `-m`. [Update Microsoft applications for Mac by using msupdate](https://learn.microsoft.com/en-us/microsoft-365-apps/mac/update-office-for-mac-using-msupdate)
- **Deadlines are sticky by design** — the "set to 0, then retire" pattern avoids ghost deadlines. [Set a deadline for updates from MAU](https://learn.microsoft.com/en-us/microsoft-365-apps/mac/mau-deadline)
- **Licence precedence is machine-wide for LTSC.** Treat `licensingV2.plist` as the first check on any "wrong licence" ticket. [How to remove Office license files on a Mac](https://support.microsoft.com/en-us/microsoft-365-activation-licensing/how-to-remove-office-license-files-on-a-mac)
- Community depth: Paul Bowden's MobileConfigs repo (`github.com/pbowden-msft/MobileConfigs`) for PPPC/MAU sample profiles, and the *MacAdmins Slack* `#microsoft-office` channel for build-regression chatter.
