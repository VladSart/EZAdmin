# Microsoft Teams for Mac (Client Install, Sign-in, Cache, Permissions, Meetings) — Reference Runbook (Mode A: Deep Dive)
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

**In scope:** the current Teams desktop client on macOS (`com.microsoft.teams2`) — deployment via Intune, identity/sign-in on the Mac, local state and cache, macOS privacy (TCC) permissions for meetings, notifications, the gov-cloud `CloudType` preference, log collection, and the device/network side of meeting quality.

**Out of scope (see instead):**
- Teams tenant policies (meeting, messaging, calling, external access) → `../../M365/Teams/Meeting-Policies-A.md`, `ExternalAccess-A.md`, `Calling-A.md`
- Teams Rooms / Teams Android devices → `../../M365/Teams/Teams-Rooms-A.md`, `Device-Policies-A.md`
- Office suite install/activation/MAU → `M365AppsMac-A.md`
- Platform SSO / Enterprise SSO plug-in → `Platform-SSO-A.md`
- The *Teams Meeting* button in Outlook for Mac (native online-meeting integration, `DisableTeamsMeeting`) → `OutlookMac-A.md`
- Windows Teams (MSIX, `teamsbootstrapper.exe`) → M365/Teams

**Assumptions:** Intune-managed Macs; engineer has Teams Administrator (call analytics) and Intune profile rights.

---
## How It Works
<details><summary>Full architecture</summary>

### Two clients, two identities
| | Current Teams | Classic Teams (retired) |
|---|---|---|
| App path | `/Applications/Microsoft Teams.app` | `/Applications/Microsoft Teams classic.app` |
| Bundle ID / pref domain | `com.microsoft.teams2` | `com.microsoft.teams` |
| Local state | `~/Library/Group Containers/UBF8T346G9.com.microsoft.teams`, `~/Library/Containers/com.microsoft.teams2` | `~/Library/Application Support/Microsoft/Teams` |
Any profile, detection rule or script still targeting `com.microsoft.teams` is targeting the retired client.

### Deployment
- Microsoft distributes the Mac client as a **.pkg**. Intune options: the **Microsoft 365 Apps for macOS** suite (includes Teams), or a macOS app (PKG) with detection on `com.microsoft.teams2`.
- The PKG can also install the **Teams audio driver** (`/Library/Audio/Plug-Ins/HAL/MSTeamsAudioDevice.driver`) used when a presenter shares *system audio*. It's a Core Audio HAL plug-in, loaded by `coreaudiod` — which is why driver trouble can affect audio outside Teams.
- Teams updates itself. (For Office update mechanics see `M365AppsMac-A.md`; this repo treats Teams update cadence as Teams-owned.)

### Identity
Teams uses MSAL with tokens in the user's login keychain and shares the Microsoft identity broker path with other Microsoft apps. Where Conditional Access requires a compliant/managed device, the Mac proves device state via the Microsoft Enterprise SSO plug-in (Company Portal) or Platform SSO. Multiple work/school accounts and tenants can be signed in side-by-side in the same client.

### Gov clouds: `CloudType`
Domain `com.microsoft.teams2`, key `CloudType` (Int): 1 Commercial, 2 GCC, 3 GCCH, 4 DoD, 7 Gallatin. It pins **pre-sign-in** endpoint selection so the client talks to the right cloud before it knows who the user is. Deliver via Intune Preference file profile. Source: [Bulk deploy the Teams client — Gov cloud deployments for PC and Mac](https://learn.microsoft.com/en-us/microsoftteams/teams-client-bulk-install).

### macOS privacy (TCC) — the meeting-feature gate
```
Feature                  TCC service            Can MDM (PPPC) pre-approve?
Share screen / window    ScreenCapture          No — deny only; or allow STANDARD users to approve
Camera                   Camera                 No — deny only
Microphone               Microphone             No — deny only
Give/take control        Accessibility          Yes (PPPC allow)
```
Screen Recording changes only take effect after Teams restarts, which is why the user has to leave and rejoin a meeting after granting it (Microsoft's documented flow). Source: [Teams for Mac — overview and prerequisites](https://learn.microsoft.com/en-us/microsoftteams/teams-client-mac-install-prerequisites).

### Notifications
If the user dismisses macOS's first notification prompt, Teams stays silent until **Allow notifications** is enabled in System Settings. Fleet-wide, the Apple `com.apple.notificationsettings` payload (Intune Settings Catalog → *Notifications*) keyed on `com.microsoft.teams2` pre-sets this.

### Local state & cache
Both container paths are safe to delete when Teams is quit (Microsoft's documented cache clear). Chats, files, meetings are server-side. Since macOS 14, deleting another app's container from Terminal requires the Terminal to have Full Disk Access (app-data protection) — the "Operation not permitted" error is that, not SIP.

### Logs
**Help → Collect support files** or **Option + Command + Shift + 1** writes two sets to `~/Downloads`: *MS Teams Support Log Files* (media, signalling, platform) and *Weblogs* (app events, already compressed). Zip the support folder before uploading. Source: [Collect log files in Teams](https://learn.microsoft.com/en-us/microsoftteams/log-files).

### Media path
```
Teams client ── UDP 3478-3481 ──▶ Teams Transport Relays (52.112.0.0/14, 52.122.0.0/15)
      │             (preferred)
      └── TCP/TLS 443 fallback (higher latency, worse quality)
```
VPNs that tunnel or inspect this traffic are the #1 cause of "Teams on Mac is choppy but only at home". Split-tunnel the Optimize-category Teams ranges.
</details>

---
## Dependency Stack

```
[8] Meeting features (share/camera/mic/notifications) working
[7] TCC grants (user-approved) + notification settings
[6] Local state healthy (Group Container + Container)
[5] Signed in: licence + MSAL token + CA satisfied
[4] Correct cloud (CloudType for gov tenants)
[3] Network: 443 to service, UDP 3478-3481 to media relays
[2] Current client installed (com.microsoft.teams2), classic removed
[1] Intune delivery (M365 suite or PKG app; profiles delivered)
[0] macOS within Teams client system requirements
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| White/blank window, endless loading | Corrupt local state | Clear cache (Playbook 1) |
| "Something went wrong" after macOS upgrade | Stale token/state | Sign-in logs; clear cache |
| Sign-in loop with CA error 53000/53003/530003 | Device not compliant / not registered | Intune compliance; Company Portal / PSSO |
| Gov tenant user redirected to commercial login | `CloudType` missing | Managed prefs |
| Screen share black / others see desktop wallpaper only | Screen Recording not granted or Teams not restarted | Privacy & Security |
| Camera toggle greyed in Teams | TCC denied by user or PPPC deny | `tccutil`/profiles |
| No banners for chats | macOS notifications off / Focus | Notifications settings |
| System-audio share fails or distorts | Audio driver not installed/broken | `/Library/Audio/Plug-Ins/HAL` |
| Choppy calls only on VPN | Media over TCP/through tunnel | Call analytics (UDP vs TCP) |
| Intune says Teams "not detected" after install | Detection rule uses `com.microsoft.teams` | App detection config |
| Two Teams icons | Classic client left behind | `/Applications` |

---
## Validation Steps

1. **Client**
   ```bash
   defaults read "/Applications/Microsoft Teams.app/Contents/Info.plist" CFBundleIdentifier
   ```
   Good: `com.microsoft.teams2`. Bad: missing, or classic app also present.

2. **Managed prefs**
   ```bash
   defaults read "/Library/Managed Preferences/com.microsoft.teams2" 2>/dev/null
   ```
   Good (commercial): absent or `CloudType = 1`. Good (GCCH): `CloudType = 3`.

3. **Profiles affecting Teams**
   ```bash
   sudo profiles show -type configuration | grep -i -B3 -A10 "teams2"
   ```
   Look for PPPC entries (`Services` → `ScreenCapture`/`Camera` with `Authorization = Deny`) and notification payloads.

4. **Audio driver**
   ```bash
   ls -la /Library/Audio/Plug-Ins/HAL/ | grep -i teams
   ```
   Good: `MSTeamsAudioDevice.driver` present if system-audio sharing is expected.

5. **Identity** — Entra sign-in logs, app *Microsoft Teams*: Success with CA Success.

6. **Media** — Teams admin center → Users → user → Meetings & calls → session → *Network*: transport **UDP**, packet loss < 1%.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Collect logs** (Option+Cmd+Shift+1) before changing anything; cache clears destroy local evidence.

**Phase 2 — Client correctness.** Right bundle ID, classic removed, version current.

**Phase 3 — Identity.** Sign-in log first. Error code decides: compliance, registration, assignment, licence.

**Phase 4 — Local state.** Clear cache; relaunch; re-test.

**Phase 5 — Feature gates.** TCC for share/camera/mic; notifications; audio driver.

**Phase 6 — Network/media.** Call analytics → UDP vs TCP, loss, jitter; VPN split tunnel.

**Phase 7 — Service.** Microsoft 365 admin center → Service health → Microsoft Teams for active incidents before escalating.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Clean reset of the Teams client for one user</summary>

```bash
osascript -e 'quit app "Microsoft Teams"'; sleep 3; pkill -x "Microsoft Teams" 2>/dev/null
rm -rf ~/Library/Group\ Containers/UBF8T346G9.com.microsoft.teams
rm -rf ~/Library/Containers/com.microsoft.teams2
tccutil reset ScreenCapture com.microsoft.teams2
open -a "Microsoft Teams"
```
Resets local prefs and re-prompts for screen recording. Server data unaffected. No rollback needed.
</details>

<details><summary>Playbook 2 — Fleet: remove classic Teams via Intune shell script</summary>

```bash
#!/bin/bash
# Run as root via Intune shell script; idempotent
APP="/Applications/Microsoft Teams classic.app"
if [[ -d "$APP" ]]; then
  pkill -f "Microsoft Teams classic" 2>/dev/null
  rm -rf "$APP" && echo "Removed classic Teams" || { echo "Failed to remove"; exit 1; }
else
  echo "Classic Teams not present"
fi
```
Pair with an app assignment for current Teams so users aren't left without a client. Rollback: none needed (classic is retired).
</details>

<details><summary>Playbook 3 — Fleet: pre-configure notifications and Accessibility</summary>

1. Settings Catalog → **Notifications** → add item: Bundle Identifier `com.microsoft.teams2`, Notifications Enabled **true**, Alert Type **Banner** (or Alert), Show in Lock Screen as per policy.
2. Settings Catalog → **Privacy Preferences Policy Control** → Accessibility: Identifier `com.microsoft.teams2`, Identifier Type *bundleID*, Code Requirement from:
   ```bash
   codesign -dr - "/Applications/Microsoft Teams.app" 2>&1 | sed -n 's/^designated => //p'
   ```
   Allowed **true**.
3. Screen Recording: only *Allow Standard User to Set System Service* is possible — use it if users are standard accounts.
Rollback: unassign the profiles.
</details>

<details><summary>Playbook 4 — Gov cloud pin</summary>

Preference file profile, domain `com.microsoft.teams2`, `CloudType` integer (1/2/3/4/7). After delivery, run Playbook 1 on already-affected devices. Rollback: unassign.
</details>

<details><summary>Playbook 5 — Audio driver repair (system-audio sharing)</summary>

```bash
osascript -e 'quit app "Microsoft Teams"'
sudo rm -rf /Library/Audio/Plug-Ins/HAL/MSTeamsAudioDevice.driver
sudo killall coreaudiod
# Reinstall the Teams PKG (Intune: redeploy / Company Portal reinstall) to restore the driver
```
Destructive for system-audio sharing until reinstall. `killall coreaudiod` briefly interrupts all audio on the Mac.
</details>

---
## Evidence Pack

```bash
#!/bin/bash
# Collect-TeamsMacEvidence.sh — run as the affected user; read-only
OUT="/tmp/TeamsMacEvidence_$(hostname -s)_$(date +%Y%m%d_%H%M%S)"; mkdir -p "$OUT"
sw_vers > "$OUT/sw_vers.txt"; uname -m >> "$OUT/sw_vers.txt"
defaults read "/Applications/Microsoft Teams.app/Contents/Info.plist" > "$OUT/teams_info.txt" 2>&1
ls -d /Applications/Microsoft\ Teams* > "$OUT/apps.txt" 2>&1
defaults read "/Library/Managed Preferences/com.microsoft.teams2" > "$OUT/managed_prefs.txt" 2>&1
ls -la /Library/Audio/Plug-Ins/HAL/ > "$OUT/hal_plugins.txt" 2>&1
pgrep -fl "Microsoft Teams" > "$OUT/processes.txt" 2>&1
du -sh ~/Library/Group\ Containers/UBF8T346G9.com.microsoft.teams ~/Library/Containers/com.microsoft.teams2 > "$OUT/state_size.txt" 2>&1
scutil --proxy > "$OUT/proxy.txt" 2>&1
nc -vz -w 3 teams.microsoft.com 443 > "$OUT/reach_443.txt" 2>&1
cp -R ~/Downloads/MS\ Teams\ Support\ Log\ Files* "$OUT/" 2>/dev/null
cp ~/Downloads/*[Ww]eblogs* "$OUT/" 2>/dev/null
( cd /tmp && zip -qr "$OUT.zip" "$(basename "$OUT")" ) && echo "Evidence: $OUT.zip"
```
Plus: Entra sign-in request ID, Teams admin center call ID and time (UTC), `Get-TeamsMacHealth.sh` CSV.

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Client bundle ID | `defaults read "/Applications/Microsoft Teams.app/Contents/Info.plist" CFBundleIdentifier` |
| Version | `... CFBundleShortVersionString` |
| Quit Teams | `osascript -e 'quit app "Microsoft Teams"'` |
| Clear cache | `rm -rf ~/Library/Group\ Containers/UBF8T346G9.com.microsoft.teams ~/Library/Containers/com.microsoft.teams2` |
| Collect logs | Option + Command + Shift + 1 (→ ~/Downloads) |
| Reset screen-recording prompt | `tccutil reset ScreenCapture com.microsoft.teams2` |
| Reset camera / mic prompt | `tccutil reset Camera com.microsoft.teams2` / `Microphone` |
| Managed prefs | `defaults read "/Library/Managed Preferences/com.microsoft.teams2"` |
| Profiles touching Teams | `sudo profiles show -type configuration \| grep -i -A10 teams2` |
| Code requirement (PPPC) | `codesign -dr - "/Applications/Microsoft Teams.app"` |
| Audio driver | `ls /Library/Audio/Plug-Ins/HAL/ \| grep -i teams` |
| Proxy config | `scutil --proxy` |
| Health script | `bash Get-TeamsMacHealth.sh` |

---
## 🎓 Learning Pointers
- Start from [Teams for Mac — overview and prerequisites](https://learn.microsoft.com/en-us/microsoftteams/teams-client-mac-install-prerequisites): notifications, screen-sharing permission flow and the documented cache paths are all there.
- TCC limits come from Apple, not Microsoft — read the [PPPC payload reference](https://support.apple.com/guide/deployment/privacy-preferences-policy-control-payload-dep38df53c2a/web) to see exactly which services MDM can allow vs only deny.
- For the network side, learn the Teams Optimize rows in [Microsoft 365 URLs and IP address ranges](https://learn.microsoft.com/en-us/microsoft-365/enterprise/urls-and-ip-address-ranges) and why UDP matters; then use call analytics per user to prove UDP vs TCP.
- [Collect log files in Teams](https://learn.microsoft.com/en-us/microsoftteams/log-files) — always collect before clearing cache; Microsoft support will ask for both log sets.
- Gov tenants: `CloudType` in [Bulk deploy the Teams client](https://learn.microsoft.com/en-us/microsoftteams/teams-client-bulk-install) is the Mac equivalent of the Windows `HKCU\SOFTWARE\Policies\Microsoft\Office\16.0\Teams\CloudType` value.
