# Administrator Protection (Windows 11) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why Administrator Protection changes Windows' elevation model, not just what to click.

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
- [Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

**In scope:**
- Administrator Protection's just-in-time (JIT) elevation architecture and how it differs from classic UAC split-tokening
- The isolated, profile-separated shadow admin account model (`admin_<username>`)
- Governance via the `LocalPoliciesSecurityOptions` CSP / Local Security Policy, and Intune/GPO deployment paths
- App-compatibility implications of profile separation and the lack of persistent elevated context
- Known compatibility/rollout friction reported during the 24H2/25H2 rollout window, including the broader deployment via KB5120998 (~September 2026)

**Out of scope:**
- Classic UAC/Admin Approval Mode fundamentals not specific to Administrator Protection (assumed baseline knowledge)
- Third-party PAM/PIM tooling (CyberArk, BeyondTrust, etc.) — architecturally unrelated, though organizations running both should validate interaction behavior separately
- Server-side/Windows Server admin models — Administrator Protection as covered here is a Windows 11 client feature

**Assumptions:**
- Windows 11, version 24H2 (build 26100) or later, with cumulative updates current enough to include Administrator Protection components (broader rollout tied to KB5120998, ~September 2026)
- Reader has local admin on the device and Intune/GPO edit rights if a policy-level change is needed
- **Source-confidence note:** Administrator Protection has limited mature, dedicated conceptual documentation on Microsoft Learn as of this writing relative to longer-established Windows security features. Several structural facts in this document (the CSP node names, the exact `admin_` account prefix behavior, and specific compatibility findings) are corroborated across the Windows IT Pro Blog, community technical write-ups (4sysops, Petri, XPN Infosec, Windows Forum), and CSP reference documentation rather than a single authoritative conceptual Learn article — treat as directionally accurate and current as of writing, and re-verify against Microsoft Learn before making firm representations in a compliance or security-audit context.

---

## How It Works

<details><summary>Full architecture</summary>

### Why Administrator Protection Exists

Classic Windows User Account Control (UAC) has run on a **split-token** model since Windows Vista: a local administrator's logon session is issued two tokens — a filtered, standard-user token used for everyday activity, and a full administrator token held in reserve. Elevation ("Run as administrator," a UAC consent prompt) simply switches the active process to the pre-existing admin token. This model has a well-understood weakness: the admin token already exists and is associated with the logged-on session at all times, meaning malware or an attacker with code-execution on the standard-token side has a persistent, local target to attempt to reach or abuse (token theft, UAC-bypass techniques, DLL/COM auto-elevation abuse) without ever needing the user to type a password.

Administrator Protection restructures this relationship entirely:

```
CLASSIC UAC (split-token):
  Logon → [Standard token] + [Admin token, pre-existing, same session]
                                      │
                          "Run as admin" / consent prompt
                                      │
                          Process switches to the PRE-EXISTING admin token

ADMINISTRATOR PROTECTION (just-in-time):
  Logon → [Standard token ONLY — user is a genuine standard user, no admin
           token exists anywhere in the session at rest]
                                      │
                          Elevation requested
                                      │
                 Explicit re-authentication (Hello / credential confirmation)
                                      │
        Windows provisions/reuses a hidden, profile-separated shadow
        identity ("admin_<username>") and issues a BRAND-NEW, TEMPORARY
        elevated token scoped to the requesting process only
                                      │
                          Task completes
                                      │
                    Token is destroyed — no admin-capable credential
                    material persists anywhere in the user's session
```

The practical security claim: there is no standing admin token to steal, replay, or silently reuse — every single elevated operation must independently re-earn its elevated token, and that token cannot outlive the operation it was issued for.

### The Shadow Admin Account (`admin_<username>`)

Rather than elevating the signed-in user's own identity, Windows creates a separate, hidden, local, profile-isolated account the first time a given user actually performs an elevation on a device — conventionally named with an `admin_` prefix followed by the originating username (e.g., user `jsmith` → shadow account `admin_jsmith`). This account:

- Does not appear in the normal Settings > Accounts user list and is not intended for direct interactive sign-in
- Has its own separate user profile — meaning any per-user state an elevated process writes (registry `HKCU` keys, `%APPDATA%`/`%LOCALAPPDATA%` files, Start menu shortcut placement) lands in *that* profile, not the signed-in user's normal profile
- Is provisioned lazily (on first actual elevation), not proactively when the policy is enabled — a device with Administrator Protection turned on but no elevation ever attempted will show no shadow account yet

This is the architectural reason behind the most common category of Administrator Protection support ticket: "I installed something as admin and now I can't find it / its settings are gone" — the install genuinely happened, but under a profile the user has never signed into and doesn't see in normal Explorer/Settings navigation.

### Explicit Re-Authentication, Not Click-Through Consent

Classic UAC's default "Prompt for consent" mode for admin accounts requires only a click (Yes/No) — no credential re-entry. Administrator Protection's design intent is to close exactly this gap: the `UserAccountControl_BehaviorOfTheElevationPromptForAdministratorProtection` setting lets an organization require actual credential confirmation (password, PIN, or biometric via Windows Hello) specifically for the Administrator Protection elevation flow, independent of whatever the organization has configured for ordinary UAC prompts elsewhere. Configuring this to require credentials (rather than simple consent) is the setting most directly responsible for defeating "click-through" malware techniques that rely on a user reflexively dismissing a UAC dialog.

### Governance Surface: LocalPoliciesSecurityOptions CSP

Administrator Protection's policy surface lives under the `LocalPoliciesSecurityOptions` configuration service provider — the same CSP family that has long carried classic Local Security Policy settings (account lockout, audit policy, etc.), rather than a brand-new dedicated CSP of its own. The two settings that matter operationally:

- **`UserAccountControl_TypeOfAdminApprovalMode`** — the master switch. Its values include the long-standing Legacy Admin Approval Mode behaviors plus the new "Admin Approval Mode with Administrator protection" value that actually engages the JIT model described above. Locally, this is the same setting historically exposed as "User Account Control: Configure type of Admin Approval Mode" under `secpol.msc` > Local Policies > Security Options.
- **`UserAccountControl_BehaviorOfTheElevationPromptForAdministratorProtection`** — governs whether the Administrator Protection elevation flow specifically uses consent-only or credential-confirmation prompting, independent of the general UAC elevation-prompt-behavior setting that governs ordinary (non-AP) elevation.

Both are deployable via Intune Settings Catalog (category: Local Policies Security Options), traditional on-prem GPO-delivered Local Security Policy, or direct `secpol.msc`/registry configuration on a single device for testing.

### App Compatibility: The Practical Fault Lines

Community testing and vendor advisories (independent of a single Microsoft Learn source) have converged on a consistent set of compatibility fault lines:

1. **Profile-separated writes** — installers/apps that write Start menu shortcuts, registry `HKCU` state, or `%APPDATA%` content while elevated land in the isolated shadow profile, not the user's normal profile, unless the app is specifically designed to write to the invoking (unelevated) user's context
2. **No persistent elevated session** — legacy automation, some installers, and tooling that expects to stay elevated across multiple sequential operations within one logical task can fail partway through, since each elevation is independently scoped and destroyed
3. **Network/mapped-drive access under elevation** — an elevated process does not automatically inherit the signed-in user's mapped drives or SSO context the way a classic split-token elevated process would, because it is architecturally a different (shadow) identity
4. **Virtualization-adjacent workflows** (Hyper-V, WSL configuration tooling) — some tooling built assuming classic admin-token semantics has been reported to need re-validation under Administrator Protection
5. **Documented design-flaw/bypass research** — independent security researchers (XPN Infosec, Petri, 4sysops) have published analyses of edge cases and, in some cases, bypass techniques against early Administrator Protection implementations; Microsoft has patched disclosed issues via cumulative updates. This is a genuinely active area — keep devices current and do not treat any single community write-up as the final word on current security posture.

Enterprise rollout was reportedly delayed at points specifically over these compatibility concerns (community reporting references a 25H2 enterprise-rollout delay) before resuming with the broader KB5120998-tied deployment — reinforcing that a pilot-before-fleet-wide approach is not just good practice but a reflection of Microsoft's own rollout caution.

</details>

---

## Dependency Stack

```
Windows 11 24H2 (build 26100) or later
   │  cumulative updates current enough for Administrator Protection components
   │  (broader rollout via KB5120998, ~September 2026)
   ▼
UAC / Admin Approval Mode enabled (EnableLUA = 1)
   │  Administrator Protection is an enhancement layer on UAC, not independent of it
   ▼
LocalPoliciesSecurityOptions CSP / Local Security Policy configured:
   UserAccountControl_TypeOfAdminApprovalMode = Admin Approval Mode
     with Administrator protection
   │
   ▼
Reboot completed after policy change
   │  token/security model is established at logon, not live-appliable mid-session
   ▼
Signed-in user holds a genuine standard-user token at rest
   (no persistent admin token anywhere in the session)
   │
   ▼
Elevation requested (UAC prompt / "Run as administrator")
   │
   ▼
Elevation-prompt behavior policy evaluated:
   UserAccountControl_BehaviorOfTheElevationPromptForAdministratorProtection
   = Prompt for consent  OR  Prompt for credentials (recommended)
   │
   ▼
Shadow admin_<username> account provisioned or reused (hidden,
profile-separated, not a normal interactive-sign-in account)
   │
   ▼
Temporary, isolated elevated token issued to the requesting PROCESS only
   │
   ▼
Task completes → token destroyed, elevated context ends
   │  no persistent elevated session survives the single operation
   ▼
App-compatibility surface: profile-separated writes, no persistent
elevation across sequential operations, no automatic inheritance of
the signed-in user's mapped drives/SSO context under the shadow identity
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| AP policy configured but nothing changes | `EnableLUA = 0` — UAC itself is off | `Get-ItemProperty ...Policies\System -Name EnableLUA` |
| AP policy configured but nothing changes, UAC is on | No reboot since policy change | `gpresult /r`, then reboot |
| Admin's daily token still shows local Administrators (S-1-5-32-544) | Policy not yet applied to this account/session, or account is exempted | `whoami /groups`, re-check policy assignment scope |
| `admin_<username>` account never appears | No elevation attempted yet (normal) OR provisioning blocked by AV/EDR | Attempt a test elevation; check System log for provisioning errors |
| Elevated app's shortcuts/settings missing for the normal user | Profile-separation working as designed | Confirm write happened while elevated; not a fault |
| Legacy installer/RMM agent fails only with AP enabled | App-compatibility gap — assumes persistent elevated context or shared profile | Vendor compatibility check; pilot-group scoping |
| User fully locked out of any elevation | Misconfiguration or missing credential-confirmation factor | Emergency rollback via policy reversion + reboot |
| "This used to just need a click, now it wants my password every time" | Elevation-prompt behavior set to "Prompt for credentials" (working as configured) | Confirm this was the organization's intended hardening choice before "fixing" |

---

## Validation Steps

**1. Confirm OS eligibility:**
```powershell
[System.Environment]::OSVersion.Version
Get-HotFix | Where-Object { $_.HotFixID -eq "KB5120998" }
```
Expected: build 26100+ ; KB5120998 or a later cumulative update present for the broader rollout-era behavior.

**2. Confirm UAC is enabled:**
```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" | Select-Object EnableLUA
```
Expected: `EnableLUA = 1`.

**3. Confirm Admin Approval Mode type:**
```powershell
gpresult /r | Select-String "Administrator protection" -Context 2,2
# Or locally: secpol.msc > Local Policies > Security Options >
# "User Account Control: Configure type of Admin Approval Mode"
```
Expected (if AP intended): "Admin Approval Mode with Administrator protection."

**4. Confirm the elevation-prompt behavior matches intended hardening level:**
```powershell
# Cross-reference against secpol.msc > "User Account Control: Behavior of the elevation
# prompt for Administrator protection" — no single reliable registry read confirmed
# across all builds as of this writing; treat secpol.msc/gpresult as ground truth
```

**5. Confirm token state for a representative user:**
```powershell
whoami /groups | Select-String "S-1-5-32-544"
```
Expected under AP: absent or not Enabled on the daily token.

**6. Confirm shadow account behavior after a deliberate test elevation:**
```powershell
Get-LocalUser | Where-Object { $_.Name -like "admin_*" }
```
Expected: appears after the user has performed at least one elevation post-policy.

---

## Troubleshooting Steps (by phase)

### Phase 1: Eligibility and Prerequisite Gate

1. Confirm OS build and cumulative-update currency.
2. Confirm `EnableLUA = 1` — this single check resolves the largest share of "policy configured, nothing happens" tickets.

### Phase 2: Policy Applied But Not Taking Effect

1. Confirm the policy actually applied via `gpresult /r` or the Intune device policy report, not just that it was assigned.
2. Confirm a reboot occurred after the policy landed — this is a boot-time security-state change.
3. Re-check token state (Validation Step 5) post-reboot.

### Phase 3: Shadow Account / Elevation Failures

1. Attempt a deliberate, observed test elevation and watch for the shadow account being created.
2. If elevation itself fails (not just the account), check the System event log for the failure window and rule out AV/EDR interference with local-account provisioning.

### Phase 4: App-Compatibility Investigation

1. Reproduce the specific failure on a pilot device with logging/observation, not on a random production device mid-incident.
2. Classify the failure against the five known fault lines (profile-separated writes, no persistent session, no mapped-drive inheritance, virtualization tooling, or a genuine unresolved bypass/defect) before assuming it's unfixable.
3. Check current vendor guidance for the specific application/agent — this compatibility landscape is actively evolving.

### Phase 5: Emergency Rollback

1. Revert `UserAccountControl_TypeOfAdminApprovalMode` to Legacy Admin Approval Mode via the fastest available admin channel (Intune, GPO, or local `secpol.msc`).
2. Force policy sync/`gpupdate /force`, then reboot — this is not a live-appliable change.
3. Document the specific trigger before any re-attempt, and re-attempt on a pilot group only.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Piloted fleet-wide rollout</summary>

```
Devices > Configuration > Policies > Create > Windows 10 and later > Settings catalog
Category: Local Policies Security Options
  User Account Control: Type of Admin Approval Mode = Admin Approval Mode with Administrator protection
  User Account Control: Behavior of the elevation prompt for Administrator protection = Prompt for credentials
Assign: PILOT group first (recommend including at least one device running each critical LOB
installer/RMM agent/automation workflow in active use)
```

**Verify:** Steps 1-6 of Validation, on each pilot device, post-reboot.

**Expand:** Only after the pilot group shows no unresolved app-compatibility findings for a full patch cycle.

**Rollback:** Remove assignment or set the policy back to Legacy Admin Approval Mode; re-sync; reboot.

</details>

<details><summary>Playbook 2 — Scoped exception for an incompatible legacy application</summary>

Use when the org-wide rollout is otherwise proceeding but one specific application/agent has a confirmed, vendor-acknowledged incompatibility.

```
Create a separate device group excluding the affected devices from the Administrator
Protection Settings Catalog assignment, while those devices remain covered by all other
security baselines
```

**Verify:** Confirm the excluded devices retain Legacy Admin Approval Mode and the application functions normally; confirm all other devices remain on Administrator Protection.

**Rollback:** Once the vendor ships a compatible version, move the device group back into the standard AP assignment and re-validate.

</details>

<details><summary>Playbook 3 — Emergency full-tenant rollback</summary>

Use only if a widespread, unresolved issue is affecting elevation across many devices simultaneously.

```
Devices > Configuration > Policies > [Administrator Protection policy] > Assignments
Remove all assignments (or set the underlying setting back to Legacy Admin Approval Mode)
Force a policy sync across affected devices
```

Devices require a reboot to fully return to legacy behavior — communicate this to affected users/sites before executing at scale.

**Rollback of the rollback:** Re-pilot on a smaller group once the root cause is identified and resolved, rather than re-enabling fleet-wide immediately.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Administrator Protection evidence for escalation
.NOTES     Run elevated for policy/registry reads. Read-only — makes no changes.
#>

$OutputDir = "C:\Temp\AdminProtection-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# 1. OS build and hotfix currency
[System.Environment]::OSVersion.Version | Out-File "$OutputDir\OSVersion.txt"
Get-HotFix | Where-Object { $_.HotFixID -eq "KB5120998" } | Out-File "$OutputDir\KB5120998.txt"

# 2. UAC / EnableLUA state
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -ErrorAction SilentlyContinue |
    Out-File "$OutputDir\UAC-Policy.txt"

# 3. Applied Group Policy result (Administrator protection section)
gpresult /r | Out-File "$OutputDir\GPResult.txt"

# 4. Current user token group membership
whoami /groups | Out-File "$OutputDir\TokenGroups.txt"

# 5. Shadow admin account inventory
Get-LocalUser | Where-Object { $_.Name -like "admin_*" } | Out-File "$OutputDir\ShadowAdminAccounts.txt"

# 6. Recent elevation-related System log errors/warnings
Get-WinEvent -LogName System -MaxEvents 200 -ErrorAction SilentlyContinue |
    Where-Object { $_.TimeCreated -gt (Get-Date).AddHours(-24) -and $_.LevelDisplayName -in "Error","Warning" } |
    Select-Object TimeCreated, Id, ProviderName, Message |
    Out-File "$OutputDir\RecentSystemEvents.txt"

Write-Host "Evidence collected: $OutputDir" -ForegroundColor Green
Compress-Archive -Path "$OutputDir\*" -DestinationPath "$OutputDir.zip"
Write-Host "Archive: $OutputDir.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

```powershell
# OS build / hotfix eligibility
[System.Environment]::OSVersion.Version
Get-HotFix | Where-Object { $_.HotFixID -eq "KB5120998" }

# UAC master switch
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" | Select-Object EnableLUA

# Applied Admin Approval Mode type (search GP result for the setting name)
gpresult /r | Select-String "Administrator protection" -Context 2,2

# Local Security Policy UI path
secpol.msc
# Local Policies > Security Options >
#   "User Account Control: Configure type of Admin Approval Mode"
#   "User Account Control: Behavior of the elevation prompt for Administrator protection"

# Token group membership (confirm standard vs. classic split-token admin)
whoami /groups | Select-String "S-1-5-32-544"

# Shadow admin account inventory
Get-LocalUser | Where-Object { $_.Name -like "admin_*" }

# Force policy sync (Intune) / refresh (on-prem)
Get-ScheduledTask -TaskName "PushLaunch" -ErrorAction SilentlyContinue | Start-ScheduledTask
gpupdate /force

# Recent elevation-adjacent System log activity
Get-WinEvent -LogName System -MaxEvents 200 |
    Where-Object { $_.LevelDisplayName -in "Error","Warning" } |
    Select-Object TimeCreated, Id, ProviderName, Message | Format-Table -Wrap
```

---

## 🎓 Learning Pointers

- **Administrator Protection is a just-in-time elevation model, not a rebranded UAC.** The core shift — no standing admin token anywhere in a normal session, a temporary token manufactured and destroyed per elevation — is what closes the token-theft/silent-reuse attack surface that classic split-tokening has always carried. Understanding this distinction is the fastest way to correctly diagnose whether a ticket is "AP working as designed" vs. "AP genuinely broken."

- **The shadow `admin_<username>` account is lazily provisioned, not proactively created.** Don't chase its absence as a fault on a freshly-configured device — confirm an elevation has actually been attempted first.

- **Profile separation is the design, not a defect.** An elevated install landing in the shadow profile rather than the user's own is expected; the correct response is planning (unelevated install where possible, vendor compatibility check) rather than trying to restore shared-profile behavior.

- **This feature is still actively maturing in documentation and rollout as of this writing** — the broader KB5120998-tied deployment lands around September 2026, and both Microsoft and independent security researchers continue to publish compatibility and hardening findings. Treat this document's specifics as a snapshot; re-verify against Microsoft Learn and Windows Release Health before firm compliance representations. [Administrator protection on Windows 11 — Windows IT Pro Blog](https://techcommunity.microsoft.com/blog/windows-itpro-blog/administrator-protection-on-windows-11/4303482)

- **A reboot is mandatory after any Admin Approval Mode type change.** This is a boot-time token/security-state configuration; a live `gpupdate /force` without a subsequent restart will not change observed elevation behavior, which is the second most common "policy configured but nothing changed" misdiagnosis after the `EnableLUA` check.

- **Pilot before fleet-wide, always.** Microsoft's own rollout paused at points over compatibility concerns during 24H2/25H2 — that is a strong signal for any MSP that a blanket tenant-wide deployment without a pilot phase carries real operational risk, not just a theoretical one.
