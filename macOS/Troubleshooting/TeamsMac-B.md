# Microsoft Teams for Mac (Client Install, Sign-in, Cache, Permissions, Meetings) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate "Teams on the Mac won't sign in / is blank / can't share screen / no audio / no notifications" in under 10 minutes.

> Scope: the current Teams client for Mac (`/Applications/Microsoft Teams.app`, bundle ID **`com.microsoft.teams2`**, preference domain `com.microsoft.teams2`). If you find `com.microsoft.teams` ("Microsoft Teams classic.app"), that's the retired classic client — remove it and install the current one (Fix 1). Tenant-side policy problems (meeting/calling/external access) → `../../M365/Teams/_AGENT.md`.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

On the affected Mac, **as the signed-in user**:

```bash
# 1. Which client is installed and what version?
defaults read "/Applications/Microsoft Teams.app/Contents/Info.plist" CFBundleIdentifier 2>/dev/null   # expect com.microsoft.teams2
defaults read "/Applications/Microsoft Teams.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null
ls -d "/Applications/Microsoft Teams classic.app" 2>/dev/null && echo "CLASSIC CLIENT STILL PRESENT"

# 2. Running?
pgrep -fl "Microsoft Teams" | head -5

# 3. Gov-cloud pin (only relevant for GCC/GCCH/DoD/Gallatin tenants)
defaults read "/Library/Managed Preferences/com.microsoft.teams2" CloudType 2>/dev/null || echo "No managed CloudType"

# 4. Basic service reachability (media UDP 3478-3481 is tested by Settings → Devices → Make a test call)
nc -vz -w 3 teams.microsoft.com 443 2>&1 | tail -1
```

| Result | Meaning | Go to |
|---|---|---|
| No `com.microsoft.teams2` / only classic present | Wrong or missing client | Fix 1 |
| Blank/white window, "Something went wrong", stuck loading | Corrupt cache / WebView state | Fix 2 |
| Sign-in loop, "need admin approval", error 53003/530003 | Identity / Conditional Access | Fix 3 |
| Screen share shows black or prompt keeps returning | Screen Recording (TCC) not granted — MDM **cannot** pre-grant | Fix 4 |
| No camera/mic in meetings | Camera/Microphone TCC denied | Fix 4 |
| No notifications | macOS notifications off for Teams | Fix 5 |
| Tenant is GCC High/DoD and sign-in goes to commercial | Missing `CloudType` pref | Fix 6 |
| Meeting audio robotic/drops, others fine | Network (UDP blocked / VPN hairpin) or audio driver | Fix 7 |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Teams for Mac working (chat + meetings)
├── Correct client installed: /Applications/Microsoft Teams.app (com.microsoft.teams2)
│   └── macOS within Teams client system requirements
├── Identity
│   ├── User licensed for Teams (Teams service plan enabled)
│   ├── MSAL token (login keychain) valid
│   └── Conditional Access satisfied → Mac registered + compliant (Company Portal / Platform SSO)
├── Correct cloud endpoint (gov tenants: com.microsoft.teams2 CloudType)
├── Local state healthy
│   ├── ~/Library/Group Containers/UBF8T346G9.com.microsoft.teams
│   └── ~/Library/Containers/com.microsoft.teams2
├── macOS privacy (TCC) grants — user-approved
│   ├── Screen Recording  (MDM can't allow; only deny or let standard users approve)
│   ├── Camera / Microphone (MDM can't allow; only deny)
│   └── Accessibility (for giving control in a share)
├── Notifications allowed (com.apple.notificationsettings payload or user)
└── Network
    ├── *.teams.microsoft.com / *.microsoft.com over TCP 443
    └── Media: UDP 3478-3481 to 52.112.0.0/14, 52.122.0.0/15 (no proxy/VPN inspection)
```
</details>

---
## Diagnosis & Validation Flow

1. **Client identity**
   ```bash
   defaults read "/Applications/Microsoft Teams.app/Contents/Info.plist" CFBundleIdentifier
   ```
   Expect `com.microsoft.teams2`. Anything else → Fix 1.

2. **Collect Teams' own logs first** (before clearing anything): in Teams **Help → Collect support files** or press **Option + Command + Shift + 1**. Two sets land in `~/Downloads` (MS Teams Support Log Files + Weblogs). Wait for the *Downloading web logs* banner to clear. Zip the support folder for escalation.

3. **Sign-in evidence:** Entra admin center → Sign-in logs → user → Application *Microsoft Teams*. Success + CA success = identity is fine; move on to cache (Fix 2). Failure codes → Fix 3.

4. **Privacy grants** (read-only; user TCC DB may need Full Disk Access for the Terminal):
   System Settings → Privacy & Security → *Screen & System Audio Recording*, *Camera*, *Microphone* → Microsoft Teams should be **on**.

5. **Managed prefs present?**
   ```bash
   ls "/Library/Managed Preferences/" | grep -i teams
   sudo profiles show -type configuration | grep -i -B2 -A8 "teams2"
   ```

6. **Validate after fix:** relaunch Teams, sign in, place a test call (**Settings → Devices → Make a test call**), share a window.

---
## Common Fix Paths

<details><summary>Fix 1 — Install (or replace) the correct client</summary>

- Intune: deploy the **Microsoft 365 Apps for macOS** suite (includes Teams) or a macOS PKG app for Teams with detection bundle ID `com.microsoft.teams2`.
- Remove the classic client if present:
```bash
osascript -e 'quit app "Microsoft Teams classic"' 2>/dev/null
sudo rm -rf "/Applications/Microsoft Teams classic.app"
```
Uninstalling current Teams is a normal drag-to-Trash of `/Applications/Microsoft Teams.app`. Re-install and relaunch.
</details>

<details><summary>Fix 2 — Clear the Teams cache (Microsoft-documented)</summary>

```bash
osascript -e 'quit app "Microsoft Teams"'
sleep 3
pkill -x "Microsoft Teams" 2>/dev/null
rm -rf ~/Library/Group\ Containers/UBF8T346G9.com.microsoft.teams
rm -rf ~/Library/Containers/com.microsoft.teams2
open -a "Microsoft Teams"
```
"Operation not permitted" = macOS app-data protection: grant the Terminal app **Full Disk Access** (or run from a Terminal that has it). **Do not** disable SIP.
Effect: user signs in again; local settings (theme, notification prefs) reset. Chat/files are server-side and unaffected.
</details>

<details><summary>Fix 3 — Sign-in loop / Conditional Access</summary>

1. Read the Entra sign-in failure code:
   - 53000 / 53003 → device not compliant / blocked by CA → check Intune compliance (`Compliance-Policies-B.md`).
   - 530003 → device must be managed/registered → Company Portal registration or Platform SSO (`Platform-SSO-B.md`).
   - 50105 / "need admin approval" → user not assigned / consent — check Enterprise Apps.
2. Confirm licence: M365 admin center → user → Licenses → Microsoft Teams service plan **on**.
3. Clear Teams cache (Fix 2). If still looping, sign out of all Office apps and relaunch Teams.
</details>

<details><summary>Fix 4 — Screen sharing / camera / microphone permissions</summary>

MDM (PPPC) **cannot grant** Screen Recording, Camera or Microphone — Apple only allows MDM to *deny* them (and, for Screen Recording, to let standard users approve). The user must approve.

```bash
# Reset the decision so macOS re-prompts (user context)
tccutil reset ScreenCapture com.microsoft.teams2
tccutil reset Camera com.microsoft.teams2
tccutil reset Microphone com.microsoft.teams2
osascript -e 'quit app "Microsoft Teams"'; open -a "Microsoft Teams"
```
Then System Settings → Privacy & Security → *Screen & System Audio Recording* → enable Microsoft Teams → **Quit & Reopen** (screen recording needs a Teams restart; the user must drop and rejoin the meeting).
If a PPPC profile *denies* these, the toggle is greyed out → fix the profile in Intune.
</details>

<details><summary>Fix 5 — No notifications</summary>

User: System Settings → Notifications → Microsoft Teams → **Allow notifications** on.
Fleet: Intune Settings Catalog → *Notifications* (`com.apple.notificationsettings`) with Bundle Identifier `com.microsoft.teams2`, Notifications Enabled = true, Alert type = Banners/Alerts.
Also check Focus modes aren't silencing Teams.
</details>

<details><summary>Fix 6 — Government cloud endpoint (GCC / GCCH / DoD / Gallatin)</summary>

Intune → macOS → Configuration → **Preference file**, domain `com.microsoft.teams2`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CloudType</key><integer>3</integer>  <!-- 1 Commercial, 2 GCC, 3 GCCH, 4 DoD, 7 Gallatin -->
</dict></plist>
```
Clear cache (Fix 2) after the profile lands so pre-sign-in endpoints are re-resolved.
Rollback: remove the profile.
</details>

<details><summary>Fix 7 — Poor meeting audio/video</summary>

1. Check the call in Teams admin center → Users → user → **Meetings & calls** → the session → network (packet loss/jitter, UDP vs TCP).
2. Media running over TCP/HTTPS = UDP 3478–3481 blocked or VPN tunnelling media. Split-tunnel Teams media (`52.112.0.0/14`, `52.122.0.0/15`) on the VPN.
3. Teams audio driver conflicts (sharing system sound): quit Teams, check `/Library/Audio/Plug-Ins/HAL/MSTeamsAudioDevice.driver`; reinstalling Teams reinstalls the driver. Removing it only affects *share system audio*:
```bash
ls -la /Library/Audio/Plug-Ins/HAL/ | grep -i teams
# sudo rm -rf /Library/Audio/Plug-Ins/HAL/MSTeamsAudioDevice.driver && sudo killall coreaudiod
```
</details>

---
## Escalation Evidence

```
Ticket: Teams for Mac — <symptom>
User UPN:              <UPN>
Tenant cloud:          [ ] Commercial [ ] GCC [ ] GCCH [ ] DoD
Teams bundle / ver:    <com.microsoft.teams2> / <version>
macOS / hardware:      <sw_vers -productVersion> / <Apple silicon | Intel>
Classic client present:[ ] yes [ ] no
Managed CloudType:     <value or none>
Entra sign-in result:  <success / error code + request ID>
TCC grants:            Screen Rec <on/off>  Camera <on/off>  Mic <on/off>
Network:               VPN <name/none>  UDP 3478 reachable <y/n>
Call ID / time (UTC):  <from Teams admin center call analytics>
Fixes tried:           <Fix #s>
Attachments:           MS Teams Support Log Files (zipped) + Weblogs from ~/Downloads,
                       /tmp/TeamsMacHealth_<host>_<ts>.csv
```

---
## 🎓 Learning Pointers
- The cache-clear in Fix 2 is Microsoft's documented procedure in [Teams for Mac — overview and prerequisites](https://learn.microsoft.com/en-us/microsoftteams/teams-client-mac-install-prerequisites); it resets local state only, which is why it's safe as a first move after logs are collected.
- Apple deliberately blocks MDM from *approving* Screen Recording/Camera/Microphone — that's a platform privacy rule, not an Intune gap. See Apple's [Privacy Preferences Policy Control payload](https://support.apple.com/guide/deployment/privacy-preferences-policy-control-payload-dep38df53c2a/web).
- `CloudType` in `com.microsoft.teams2` only affects pre-sign-in endpoint selection for gov clouds — see [Bulk deploy the Teams client — Gov cloud deployments](https://learn.microsoft.com/en-us/microsoftteams/teams-client-bulk-install).
- Log collection shortcut and file set: [Collect log files in Teams](https://learn.microsoft.com/en-us/microsoftteams/log-files).
- Media quality is almost always network: learn the [Microsoft 365 URLs and IP ranges](https://learn.microsoft.com/en-us/microsoft-365/enterprise/urls-and-ip-address-ranges) Teams rows (ID 11–12) and split-tunnel them.
- Deep dive: `TeamsMac-A.md`; device script: `../Scripts/Get-TeamsMacHealth.sh`.
