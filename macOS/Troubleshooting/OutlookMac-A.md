# Outlook for Mac (New vs Legacy, EWS Retirement, Profiles, Managed Preferences) — Reference Runbook (Mode A: Deep Dive)
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
- Outlook for Mac from Microsoft 365 subscriptions, Outlook LTSC for Mac 2021/2024, and the App Store build.
- The *new* Outlook for Mac vs *legacy* Outlook for Mac runtime modes, and the October 2026 break of legacy against Exchange Online (EWS retirement).
- Admin control surfaces: `com.microsoft.Outlook` / `com.microsoft.office` preferences (Intune Preference file or Settings Catalog), and Exchange Online CAS mailbox gates (`MacOutlookEnabled`, `EwsAllowMacOutlook`).
- Profiles, identity cache, and fleet-level migration off legacy.

**Out of scope (see instead)**
- Office install/activation/MAU → `M365AppsMac-A.md`
- Exchange-side mailbox, Autodiscover and Windows Outlook issues → `../../M365/Exchange/Outlook-Client-A.md`
- Platform SSO / Enterprise SSO plug-in → `Platform-SSO-A.md`
- Teams meeting button in Outlook → the meeting is created by Outlook's native online-meeting integration, gated by `DisableTeamsMeeting`; Teams client issues → `TeamsMac-A.md`

**Assumptions:** Intune-managed Macs; engineer has Exchange Administrator for EXO PowerShell and Intune Policy and Profile Manager (or equivalent) for profile changes.

---
## How It Works
<details><summary>Full architecture</summary>

### One app, two engines
`/Applications/Microsoft Outlook.app` (bundle `com.microsoft.Outlook`) ships two sync engines. The *Legacy Outlook* switch chooses between them at launch:

```
                    Microsoft Outlook.app (com.microsoft.Outlook)
                     │                                   │
          Legacy mode (switch ON)               New mode (switch OFF)
                     │                                   │
     Exchange Web Services (EWS)            Microsoft sync technology
     SOAP over HTTPS to EXO / on-prem       (cloud sync service; EXO mailboxes)
                     │                                   │
   CAS gate: EwsEnabled + EwsAllowMacOutlook   CAS gate: MacOutlookEnabled (EXO only)
                     │                                   │
     EXO: retires 1 Oct 2026  ✗               EXO: supported ✓
     On-prem SE: security fixes to 9 Oct 2029
```

Microsoft's lifecycle statement: legacy stops working against Exchange Online mailboxes from October 2026 because EWS in Exchange Online retires on 1 October 2026; against Exchange SE on-premises it gets security updates only through 9 October 2029 with best-effort technical support. Non-subscription builds (standalone Outlook 2024+, Office Home & Business 2024+, App Store) don't support legacy at all. Source: [End of support for legacy Outlook for Mac](https://support.microsoft.com/en-us/outlook/end-of-support-for-legacy-outlook-for-mac).

### The admin switch: `EnableNewOutlook`
Domain `com.microsoft.Outlook`, Integer, available from 16.38, does **not** require a Configuration Profile (but a profile is what makes it non-overridable):

| Value | Behaviour |
|---|---|
| 0 | Switch hidden |
| 1 | Switch displayed, default **off** (i.e. legacy by default) |
| 2 | Switch displayed, default **on** (default) |
| 3 | New Outlook enabled, switch hidden |

In October 2025 Microsoft stated that Outlook for Mac will *continue to respect* this admin preference. That is the mechanism by which organisations kept users on legacy — and it's why, after 1 October 2026, a stale `0`/`1` profile turns into an outage for EXO users rather than something the app corrects itself.

### Preference plumbing
- `defaults write com.microsoft.Outlook <Key>` sets a user-level default the user can change.
- A Configuration Profile (Intune Preference file or Settings Catalog) lands in `/Library/Managed Preferences/com.microsoft.Outlook.plist` (and per-user under `/Library/Managed Preferences/<user>/`) and is enforced.
- Keys marked *Requires Configuration Profile* ignore `defaults write` entirely: `DisableImport`, `DisableExport`, `DisableFolderPermissionsSetup`, `DisableSkypeMeeting`, `DisableTeamsMeeting`, `DisableCalendarSharingPermissionsSetup`, `DisableDelegationPermissionsSetup`, `DisableEncryptOnly`, `DisableSignatures`, `DisablePrideTheming`, `DisableFocusedInbox`.
- Many keys **only apply to new Outlook** (e.g. `DisableEncryptOnly`, `DisableDoNotForward`, S/MIME keys, `DisableJunkOptionsPrefKey`, `HideRetentionPolicyInfobar`, `FocusedInboxOffByDefault`), and `HideFoldersOnMyComputerRootInFolderList` only applies to legacy.
- First-launch account setup: `OfficeAutoSignIn` (domain **`com.microsoft.office`**, suppresses first-run dialogs across Office) and `DefaultEmailAddressOrDomain` (domain `com.microsoft.Outlook`).
- Account restriction: `AllowedEmailDomains` / `DisallowedEmailDomains` — neither removes accounts already added.
- Security hardening (newer builds): `DisableBasic` (16.93), `FailAllCertificateErrors` (16.94), `TrustO365AutodiscoverRedirect`.

Reference: [Set preferences for Outlook for Mac](https://learn.microsoft.com/en-us/microsoft-365-apps/mac/preferences-outlook) (ms.date 2026-09-17).

### Exchange Online mailbox gates
- `MacOutlookEnabled` — *Exchange Online only*; enables/disables Outlook for Mac clients that use Microsoft Sync technology (new Outlook). Default `$true`.
- `EwsAllowMacOutlook` — enables/disables Outlook for Mac clients that use EWS (legacy). Irrelevant for EXO once EWS retires.
Source: [Set-CASMailbox](https://learn.microsoft.com/en-us/powershell/module/exchange/set-casmailbox).

### Data locations
```
~/Library/Group Containers/UBF8T346G9.Office/
├── Outlook/Outlook 15 Profiles/<ProfileName>/   ← profile DB + cached data (legacy "On My Computer" items live here only)
├── (licensing, shared Office state — do NOT wipe wholesale)
~/Library/Containers/com.microsoft.Outlook/      ← sandbox container, prefs, caches
/Applications/Microsoft Outlook.app/Contents/SharedSupport/Outlook Profile Manager.app
```
The profile folder name "Outlook 15 Profiles" is historical and unchanged in current builds.

### Identity
Outlook uses the shared Office identity stack (MSAL). Tokens sit in the login keychain (entries labelled *Microsoft Office Identities Cache/Settings <n>*). Conditional Access requiring a compliant device is satisfied through the Microsoft Enterprise SSO plug-in / Platform SSO with the Mac registered via Company Portal.

### Mode indicator
There is no documented admin-facing read-only key for "which mode is this user in". Community tooling commonly reads `IsRunningNewOutlook` from the user's `com.microsoft.Outlook` domain (1 = new). Treat it as an observed indicator, not a contract — the UI switch is authoritative.
</details>

---
## Dependency Stack

```
[7] Mail/calendar sync working in Outlook for Mac
[6] Profile healthy (Outlook 15 Profiles/<default>)
[5] Engine = NEW (for EXO)  ← EnableNewOutlook ∉ {0,1}; user switch off
[4] Mailbox gate open       ← MacOutlookEnabled = True (EXO)  |  EwsAllowMacOutlook (on-prem legacy)
[3] Identity                ← licence/activation, MSAL token in keychain, CA satisfied (SSO plug-in / PSSO)
[2] App current             ← Microsoft AutoUpdate, version ≥ key availability
[1] Device managed          ← Intune MDM, managed prefs delivered to /Library/Managed Preferences
[0] macOS supported by current Office for Mac build
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Legacy Outlook stopped receiving mail from Oct 2026, on-prem users fine | EWS retirement in EXO | Mailbox location; running mode |
| No *Legacy Outlook* switch visible, user stuck in legacy | Managed `EnableNewOutlook = 0` | `/Library/Managed Preferences/com.microsoft.Outlook` |
| Switch visible but every new user lands in legacy | Managed `EnableNewOutlook = 1` | Same |
| New Outlook: account won't add/sync, legacy used to work | `MacOutlookEnabled = False` | `Get-CASMailbox` |
| User adds personal Gmail despite policy | `AllowedEmailDomains` doesn't remove existing accounts / key in wrong domain | Managed prefs; account list |
| `DisableExport` set but export still works | Delivered via `defaults write`, needs a profile | `profiles show` |
| S/MIME or encryption keys ignored | Key is new-Outlook-only and user is on legacy | Running mode |
| "Teams Meeting" button missing | `DisableTeamsMeeting = true` or Teams not signed in | Managed prefs |
| Repeated sign-in prompts | Stale keychain identity cache or CA/device registration | Keychain; Entra sign-in logs |
| Crash at launch / missing folders after switching | Corrupt profile; legacy local-only data | Profile Manager |
| Certificate prompts disappeared and connection fails | `FailAllCertificateErrors = true` (blocks silently) | Managed prefs |

---
## Validation Steps

1. **Version & mode**
   ```bash
   defaults read "/Applications/Microsoft Outlook.app/Contents/Info.plist" CFBundleShortVersionString
   defaults read com.microsoft.Outlook IsRunningNewOutlook 2>/dev/null
   ```
   Good: current 16.x build; `1`. Bad: `0` for an EXO user.

2. **Effective managed prefs**
   ```bash
   defaults read "/Library/Managed Preferences/com.microsoft.Outlook" 2>/dev/null
   ```
   Good: no `EnableNewOutlook` or `EnableNewOutlook = 3`. Bad: `0`/`1`.

3. **Profile source**
   ```bash
   sudo profiles show -type configuration | grep -B3 -A15 "com.microsoft.Outlook"
   ```
   Good: one profile owns the domain. Bad: two profiles set the same key (conflict — outcome undefined).

4. **Mailbox gate**
   ```powershell
   Get-CASMailbox -Identity <UPN> | Format-List MacOutlookEnabled, EwsEnabled, EwsAllowMacOutlook
   ```
   Good: `MacOutlookEnabled : True`.

5. **Identity**
   Entra sign-in logs → user → Application *Microsoft Office*, client *Mobile Apps and Desktop clients*. Good: Success, CA *Success*. Bad: 53000 (device not compliant) / 530003 (device must be managed).

6. **Profile**
   ```bash
   ls -la ~/Library/Group\ Containers/UBF8T346G9.Office/Outlook/Outlook\ 15\ Profiles/
   ```
   Good: one expected profile, recent modification time.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Scope.** One user or many? Many + same week as a profile change or 1 Oct 2026 → fleet issue; go to the Intune profile and the fleet audit (Evidence Pack) before touching devices.

**Phase 2 — Engine.** Determine mode. EXO + legacy = move to new (Playbook 1); nothing else will help.

**Phase 3 — Gate.** New mode but no sync → `MacOutlookEnabled`. Also check EXO service health for Outlook for Mac incidents.

**Phase 4 — Identity.** Prompts/loops → sign-in logs; clear keychain cache; verify device registration.

**Phase 5 — Profile/data.** Crashes, missing folders → new profile via Profile Manager; export legacy local data first.

**Phase 6 — Policy correctness.** Key ignored → domain, Configuration-Profile-only, new-only, version availability.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Fleet migration off legacy before/after the EWS cut-over</summary>

1. **Inventory**: run `../Scripts/Get-OutlookMacHealth.sh` via Intune shell script (runs as root; pass nothing — it inspects the console user) and collect the CSVs, or scope by profile: find every Intune macOS profile touching `com.microsoft.Outlook` → `EnableNewOutlook`.
2. **Local data**: communicate that legacy "On My Computer" folders are not moved; users export `.olm` (**File → Export**) before the switch if they need them. If you enforce `DisableExport`, relax it temporarily.
3. **Change the profile** to `EnableNewOutlook = 3` (hide switch, force new) — or remove the key if users may keep the switch. Pilot group first.
4. **Mailbox gates**: `Get-CASMailbox -ResultSize Unlimited | Where-Object { -not $_.MacOutlookEnabled }` — fix before rollout.
5. **Validate** a pilot device (Validation Steps 1–2), then widen assignment.

Rollback: re-assign the previous profile. For EXO mailboxes after 1 Oct 2026, rolling back to legacy is not a working state — the only rollback is Outlook on the web while you fix new Outlook.
</details>

<details><summary>Playbook 2 — Restrict accounts to corporate domains</summary>

Preference file, domain `com.microsoft.Outlook`:
```xml
<key>AllowedEmailDomains</key>
<array><string><yourdomain.com></string></array>
<key>HideCanAddOtherAccountTypesTipText</key><true/>
```
Existing non-corporate accounts remain — remove them per user or rebuild the profile. Rollback: remove the keys.
</details>

<details><summary>Playbook 3 — Rebuild a corrupt profile (non-destructive)</summary>

```bash
osascript -e 'quit app "Microsoft Outlook"'
open "/Applications/Microsoft Outlook.app/Contents/SharedSupport/Outlook Profile Manager.app"
```
New profile → Set as Default → launch → add account. Keep the old profile for a week. Rollback: set old profile default.
</details>

<details><summary>Playbook 4 — Clear identity cache (sign-in loops)</summary>

```bash
osascript -e 'quit app "Microsoft Outlook"'
security dump-keychain ~/Library/Keychains/login.keychain-db 2>/dev/null | grep -i '"Microsoft Office Identities' | sort -u
security delete-generic-password -l "Microsoft Office Identities Cache 3" 2>/dev/null
security delete-generic-password -l "Microsoft Office Identities Settings 3" 2>/dev/null
```
Affects all Office apps' sign-in (they'll prompt once). No mail data loss.
</details>

<details><summary>Playbook 5 — Harden new Outlook (security baseline)</summary>

Configuration Profile, domain `com.microsoft.Outlook`:
```xml
<key>DisableBasic</key><true/>                     <!-- 16.93+ -->
<key>FailAllCertificateErrors</key><true/>         <!-- 16.94+, blocks silently -->
<key>AutomaticallyDownloadExternalContent</key><integer>1</integer>
<key>ItemsToOtherAccountsEnabled</key><integer>0</integer>
<key>DisableExport</key><true/>                    <!-- profile-only -->
```
Pilot `FailAllCertificateErrors` — TLS-inspecting proxies will break mail with no user prompt. Rollback: remove keys.
</details>

---
## Evidence Pack

Tenant side (run on an admin workstation; device side = `../Scripts/Get-OutlookMacHealth.sh`):

```powershell
<#
.SYNOPSIS  Collect Exchange Online evidence for an Outlook for Mac escalation.
.NOTES     Requires ExchangeOnlineManagement; read-only.
#>
param([Parameter(Mandatory)][string]$UserPrincipalName,
      [string]$OutDir = "$env:TEMP\OutlookMacEvidence_$(Get-Date -Format yyyyMMdd_HHmmss)")
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
if (-not (Get-ConnectionInformation -ErrorAction SilentlyContinue)) { Connect-ExchangeOnline -ShowBanner:$false }

Get-EXOMailbox -Identity $UserPrincipalName -Properties RecipientTypeDetails |
    Select-Object DisplayName, PrimarySmtpAddress, RecipientTypeDetails |
    Export-Csv "$OutDir\Mailbox.csv" -NoTypeInformation
Get-CASMailbox -Identity $UserPrincipalName |
    Select-Object PrimarySmtpAddress, MacOutlookEnabled, EwsEnabled, EwsAllowMacOutlook, OutlookMobileEnabled, OWAEnabled |
    Export-Csv "$OutDir\CASMailbox.csv" -NoTypeInformation
Get-OrganizationConfig |
    Select-Object EwsEnabled, EwsAllowMacOutlook, OAuth2ClientProfileEnabled |
    Export-Csv "$OutDir\OrgConfig.csv" -NoTypeInformation
Get-CASMailbox -ResultSize Unlimited | Where-Object { -not $_.MacOutlookEnabled } |
    Select-Object PrimarySmtpAddress | Export-Csv "$OutDir\MacOutlookBlocked.csv" -NoTypeInformation
Write-Host "Evidence written to $OutDir" -ForegroundColor Green
```
Attach: both CSV sets, Entra sign-in log request IDs, Intune profile name + assignment, `sw_vers` output.

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Outlook version | `defaults read "/Applications/Microsoft Outlook.app/Contents/Info.plist" CFBundleShortVersionString` |
| Managed Outlook prefs | `defaults read "/Library/Managed Preferences/com.microsoft.Outlook"` |
| Managed Office prefs | `defaults read "/Library/Managed Preferences/com.microsoft.office"` |
| Mode indicator (observed) | `defaults read com.microsoft.Outlook IsRunningNewOutlook` |
| Which profile sets it | `sudo profiles show -type configuration \| grep -A15 com.microsoft.Outlook` |
| Quit Outlook | `osascript -e 'quit app "Microsoft Outlook"'` |
| Profile Manager | `open "/Applications/Microsoft Outlook.app/Contents/SharedSupport/Outlook Profile Manager.app"` |
| Update Outlook | `msupdate --install --apps OPIM2019` |
| Mailbox gate | `Get-CASMailbox <UPN> \| fl MacOutlookEnabled,EwsAllowMacOutlook` |
| Unblock new Outlook | `Set-CASMailbox <UPN> -MacOutlookEnabled $true` |
| Blocked list | `Get-CASMailbox -ResultSize Unlimited \| ? { -not $_.MacOutlookEnabled }` |
| Device health script | `sudo bash Get-OutlookMacHealth.sh` |

---
## 🎓 Learning Pointers
- The whole October 2026 story is one line of architecture: legacy = EWS, EWS in EXO retires. Read [End of support for legacy Outlook for Mac](https://support.microsoft.com/en-us/outlook/end-of-support-for-legacy-outlook-for-mac) and the [EWS retirement post](https://techcommunity.microsoft.com/t5/exchange-team-blog/retirement-of-exchange-web-services-in-exchange-online/ba-p/3924440).
- Treat [Set preferences for Outlook for Mac](https://learn.microsoft.com/en-us/microsoft-365-apps/mac/preferences-outlook) as a matrix: domain × requires-profile × new-only × min-version. Most "policy broken" tickets fail one of those four columns.
- [Deploy preferences for Office for Mac](https://learn.microsoft.com/en-us/microsoft-365-apps/mac/deploy-preferences-for-office-for-mac) explains the default-vs-forced model you rely on for every Office app, not just Outlook.
- [Set-CASMailbox](https://learn.microsoft.com/en-us/powershell/module/exchange/set-casmailbox) documents the `MacOutlookEnabled` vs `EwsAllowMacOutlook` split — know which engine each one gates.
- Other EWS casualties in the same tenant (cross-tenant free/busy, third-party apps) → `../../M365/Exchange/CrossTenantCalendarSharing-A.md`.
