# Administrator Protection (Windows 11) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate an Administrator Protection ticket in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

> **Source note:** Administrator Protection began rolling out more broadly to Windows 11 24H2/25H2 via cumulative update KB5120998 around September 2026, per Microsoft's Windows IT Pro Blog and independent community reporting. As of this writing it is not yet a mature, fully-documented GA feature on Microsoft Learn — some specifics below (exact GPO wording, rollout pacing) should be re-confirmed against Windows Release Health / Microsoft Learn before being treated as fixed fact on any given device.

Run these first — results tell you which fix path to follow:

```powershell
# 1. Is Administrator Protection even present/configurable on this build?
[System.Environment]::OSVersion.Version
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name CurrentBuild, DisplayVersion -ErrorAction SilentlyContinue
# Requires Windows 11 24H2 (build 26100) or later; broader default-adjacent rollout tied to KB5120998 (~Sept 2026)

# 2. Is Administrator Protection actually turned ON for this device?
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -ErrorAction SilentlyContinue |
    Select-Object FilterAdministratorToken, EnableLUA, ConsentPromptBehaviorAdmin
# Administrator Protection is layered on top of UAC/Admin Approval Mode — if EnableLUA=0, UAC (and therefore
# Administrator Protection) is fully off for the device, which is the single most common "why isn't this working" cause

# 3. Is the signed-in user actually running as a standard user (the AP model), or classic split-token admin?
whoami /groups | Select-String "S-1-5-32-544"
# With Administrator Protection working correctly, an admin's DAILY token should NOT show the local
# Administrators SID (S-1-5-32-544) as Enabled — elevation is granted per-task via a separate identity, not
# carried on the everyday token the way classic UAC split-tokens work

# 4. Does the hidden, system-managed shadow admin account exist?
Get-LocalUser | Where-Object { $_.Name -like "admin_*" }
# Windows provisions a per-user, profile-separated "admin_<username>" account the first time Administrator
# Protection actually performs an elevation on that device — absence doesn't mean AP is broken, it may just
# mean no elevation has happened yet on this device/profile

# 5. Is a specific app/installer the actual complaint (not a systemic AP failure)?
Get-Process | Where-Object { $_.ProcessName -match "install|setup" } -ErrorAction SilentlyContinue
```

**Interpretation table:**

| Finding | Action |
|---|---|
| Build below 26100 (Windows 11 24H2) | Not eligible — Administrator Protection cannot be enabled. Close as "not eligible" |
| `EnableLUA = 0` | UAC is fully disabled fleet-wide/on this device — Administrator Protection cannot function until UAC itself is re-enabled (see Fix 1) |
| Admin's daily token still shows S-1-5-32-544 Enabled | Administrator Protection is not actually engaged for this user — check policy state (Fix 2) |
| `admin_<username>` account never appears despite AP enabled | Either no elevation has occurred yet (normal), or provisioning failed — Fix 3 |
| Elevated app's settings/shortcuts "disappear" for the normal user | Profile-separation behavior working as designed, not a bug — Fix 4 |
| Legacy installer, RMM agent, or LOB app fails/hangs only after enabling AP | App-compatibility gap — Fix 5 |
| Org wants to pilot or roll back Administrator Protection fleet-wide | Deploy/remove the policy — Fix 1 |
| A user is fully locked out of any admin action after enabling AP | Emergency rollback — Fix 6 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Windows 11 24H2 (build 26100) or later, with the Administrator Protection feature
component present (broader rollout via KB5120998, ~September 2026)
        │
UAC / Admin Approval Mode itself enabled (EnableLUA = 1)
   Administrator Protection is an enhancement layered ON TOP OF UAC/AAM,
   not an independent replacement mechanism — if UAC is off, AP cannot function
        │
LocalPoliciesSecurityOptions CSP / Local Security Policy configured:
   UserAccountControl_TypeOfAdminApprovalMode → "Admin Approval Mode with
     Administrator protection" (GPO: "User Account Control: Configure type
     of Admin Approval Mode" under Local Policies > Security Options)
   UserAccountControl_BehaviorOfTheElevationPromptForAdministratorProtection
     → consent vs. credential-confirmation behavior for the AP elevation flow
        │
Signed-in user account provisioned as a STANDARD user (no persistent
Administrators-group membership carried on the daily token)
        │
Elevation request occurs (UAC prompt / "Run as administrator")
        │
Windows creates or reuses a hidden, profile-separated shadow account
("admin_<username>") — NOT visible in Settings > Accounts, isolated profile
        │
Explicit re-authentication required for the elevation (Windows Hello /
credential confirmation) — no simple click-through consent
        │
A temporary, isolated elevated token is issued to the requesting process only
        │
Task completes → elevated token is destroyed, elevated process context ends
   No persistent elevated session — every subsequent elevation repeats
   the authentication + shadow-account + temporary-token cycle
```

**Key concepts:**
- **This is not classic UAC split-tokening.** Classic UAC gives an admin user two tokens (standard + admin) at logon and elevation just "unlocks" the admin one. Administrator Protection instead keeps the signed-in user genuinely standard and manufactures a temporary, isolated admin identity per elevation — a materially different security model, not a rebrand.
- **Profile separation is the #1 source of "weird" tickets.** An elevated installer/app runs under the shadow `admin_<username>` profile, not the normal user's profile — Start menu shortcuts, per-user settings, and some installer state can land in a profile the user never signs into directly.
- **No persistent elevated context.** Automation, scripts, or legacy tooling that assumes an elevated session stays elevated across multiple operations (e.g., some installers, mapped-drive/network-share access under an elevated context) can break — this is an explicit design goal (credential-theft/silent-privilege-escalation resistance), not a bug to "fix" by restoring the old behavior for that one app.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm eligibility**
```powershell
[System.Environment]::OSVersion.Version
```
Build must be 26100 (24H2) or later. Below that → not eligible, stop here.

**Step 2 — Confirm UAC itself is on**
```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" | Select-Object EnableLUA
```
`EnableLUA = 0` → Administrator Protection cannot function regardless of any AP-specific policy. This is the most common silent blocker on hardened/legacy images that disabled UAC outright years ago.

**Step 3 — Confirm the Admin Approval Mode policy state**
```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Policies\System" -ErrorAction SilentlyContinue
# Also check via Local Security Policy: secpol.msc > Local Policies > Security Options >
# "User Account Control: Configure type of Admin Approval Mode"
# Expected for AP enabled: "Admin Approval Mode with Administrator protection"
# Legacy default: "Admin Approval Mode for the Built-in Administrator account" only, or Legacy AAM
```

**Step 4 — Confirm the user's daily token is standard, not split-token admin**
```powershell
whoami /groups | Select-String "S-1-5-32-544"
```
Present and Enabled on a user who is *supposed* to be under Administrator Protection → the account is still a full member of local Administrators with classic behavior, not yet migrated to the AP model.

**Step 5 — Confirm the shadow admin account behavior**
```powershell
Get-LocalUser | Where-Object { $_.Name -like "admin_*" }
```
This account is provisioned on first elevation, not at policy-enable time — its absence on a freshly-configured device is expected, not a fault.

---

## Common Fix Paths

<details><summary>Fix 1 — Deploy or pilot Administrator Protection fleet-wide</summary>

**Cause:** Org wants to roll this out as part of a credential-theft/lateral-movement hardening initiative.

**Via Intune (Settings Catalog, preferred):**
```
Devices > Configuration > Policies > Create > Windows 10 and later > Settings catalog
Category: Local Policies Security Options
  → "User Account Control: Type of Admin Approval Mode" = Admin Approval Mode with Administrator protection
  → "User Account Control: Behavior of the elevation prompt for Administrator protection" = Prompt for credentials (recommended over "Prompt for consent" — a credential prompt cannot be click-through-dismissed by malware the way a consent prompt can)
Assign to a PILOT device group first — do not deploy tenant-wide without testing line-of-business installers, RMM agents, and any automation that assumes persistent elevated context
```

**Via on-prem Local Security Policy (single device or GPP):**
```
secpol.msc > Local Policies > Security Options >
"User Account Control: Configure type of Admin Approval Mode" → Admin Approval Mode with Administrator protection
```

**Verify:**
```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -ErrorAction SilentlyContinue
whoami /groups | Select-String "S-1-5-32-544"
```

**Rollback:** Set "Configure type of Admin Approval Mode" back to Legacy Admin Approval Mode (or Not Configured) and re-sync/`gpupdate /force`. Restart required for the change to fully apply — the AP model is a boot-time security state, not a live-toggle setting.

</details>

<details><summary>Fix 2 — Administrator Protection enabled by policy but user still has a classic admin token</summary>

**Cause:** The policy landed, but the device hasn't rebooted since, or the user's account is genuinely still a persistent member of the local Administrators group in a way the AP model doesn't override for pre-existing sessions.

```powershell
# Confirm policy actually applied vs. just assigned
gpresult /r | Select-String "Administrator protection" -Context 2,2
```

**Remediation:**
1. Force a reboot — Administrator Protection's token model is established at logon, not applied live mid-session
2. Re-run Step 4 of Diagnosis after reboot
3. If still showing a classic split-token after reboot, confirm the policy actually applied (`gpresult /r` or Intune device policy report) rather than assuming the CSP push alone is sufficient

**Rollback:** N/A — this is a state-refresh action, not a destructive change.

</details>

<details><summary>Fix 3 — Shadow admin_&lt;username&gt; account never provisions on elevation attempt</summary>

**Cause:** Either the elevation is failing before account provisioning (check Step 2/3 first), or a security tool/AV/EDR is blocking the account-creation operation itself.

```powershell
# Check for elevation-related failures in the System log around the time of the failed attempt
Get-WinEvent -LogName System -MaxEvents 200 |
    Where-Object { $_.TimeCreated -gt (Get-Date).AddHours(-2) -and $_.LevelDisplayName -in "Error","Warning" } |
    Select-Object TimeCreated, Id, ProviderName, Message | Format-Table -Wrap
```

**Remediation:**
1. Confirm UAC/EnableLUA and the AP policy state are both correct (Steps 2-3)
2. Temporarily disable third-party AV/EDR local-account-creation blocking rules (if any) on a test device to isolate whether security tooling is the blocker
3. If confirmed, add an exception for the OS-level shadow-account provisioning mechanism per your AV/EDR vendor's guidance rather than disabling Administrator Protection

**Rollback:** Re-enable any AV/EDR rule that was temporarily disabled for testing.

</details>

<details><summary>Fix 4 — Elevated app's settings, shortcuts, or updates "disappear" for the normal user</summary>

**Cause:** This is Administrator Protection's profile-separation behavior working as designed — the elevated process ran under the isolated `admin_<username>` profile, not the signed-in user's normal profile.

**Remediation:**
1. Confirm the symptom matches the pattern: something was installed/configured *while elevated* and doesn't show up for the normal (unelevated) user
2. For Start menu shortcuts: reinstall the affected application unelevated where the installer supports a per-user (non-admin) install mode, if business need allows
3. For LOB apps that fundamentally require persistent elevated context (rare, but exists in legacy tooling): treat as an app-compatibility exception — see Fix 5 rather than trying to "restore" shared-profile behavior, which is not how Administrator Protection is designed to work

**Rollback:** N/A — not a fault condition to roll back, a behavior change to plan around.

</details>

<details><summary>Fix 5 — Legacy installer, RMM agent, or automation breaks after enabling Administrator Protection</summary>

**Cause:** Tooling built against the classic split-token/persistent-elevation model doesn't tolerate a per-task, isolated elevated identity with no persistent session.

**Remediation:**
1. Check the vendor's current documentation/support statement for Administrator Protection compatibility — this is an actively-evolving compatibility landscape as of this writing
2. Test the specific failing workflow on a pilot device with AP enabled before wider rollout, not after
3. If a specific application must be exempted while the rest of the fleet proceeds with AP, scope the Settings Catalog assignment to exclude that device group rather than abandoning the rollout org-wide
4. For agents/services that run as SYSTEM (most RMM/management agents), Administrator Protection's per-user elevation model does not apply — confirm the actual failure is user-context elevation, not an unrelated service-account issue, before attributing it to AP

**Rollback:** Remove the device/group from the Administrator Protection policy assignment; `gpupdate /force` or Intune sync, then reboot.

</details>

<details><summary>Fix 6 — Emergency: a user/admin is fully locked out of any elevation action</summary>

**Cause:** Misconfiguration, a credential-confirmation factor that isn't enrolled/available, or a genuine provisioning failure leaving no working elevation path.

**Remediation (fastest safe path):**
1. If Intune-managed and reachable: remove the device from the Administrator Protection Settings Catalog assignment, force a policy sync, then require a reboot
2. If on-prem/local and reachable via another admin credential or remote tooling: set "Configure type of Admin Approval Mode" back to Legacy Admin Approval Mode via `secpol.msc` or a remote registry/GPO push, then reboot
3. If completely locked out (no working admin path at all): this requires the same recovery approach as any other complete local-admin lockout — offline recovery media, a break-glass local admin account maintained per your org's standard admin-account recovery procedure, or Autopilot Reset/re-provisioning as a last resort

**Rollback:** This *is* the rollback path — document the root cause before re-attempting a piloted (not fleet-wide) re-enable.

</details>

---

## Escalation Evidence

```
ESCALATION TICKET — Administrator Protection Issue
=====================================
Device Name:              [hostname]
Windows Build:             [ver / [System.Environment]::OSVersion.Version output]
KB5120998 or later installed: [Yes/No — Get-HotFix]
EnableLUA:                 [0/1]
Admin Approval Mode type:  [Legacy | Admin Approval Mode with Administrator protection]
Elevation prompt behavior: [Prompt for consent | Prompt for credentials]
User's daily token shows S-1-5-32-544 Enabled: [Yes/No]
admin_<username> shadow account present:        [Yes/No]
Deployment channel:        [Intune Settings Catalog | On-prem Local Security Policy | Manual]

Symptom description:
[what the user/admin reported]

Steps already attempted:
[ ] Confirmed OS build eligibility (24H2/26100+)
[ ] Confirmed EnableLUA = 1
[ ] Confirmed Admin Approval Mode policy state
[ ] Confirmed reboot occurred after policy change
[ ] Checked System event log for elevation-related errors
[ ] Ruled out AV/EDR interference with shadow-account provisioning
[ ] Isolated whether issue is app-specific or systemic
```

---

## 🎓 Learning Pointers

- **Administrator Protection is layered on UAC, not a replacement for it.** If `EnableLUA = 0` on a hardened legacy image, no amount of Administrator Protection policy configuration will do anything — always confirm UAC itself is on first. This is the single fastest wrong-diagnosis trap in this topic.

- **The shadow `admin_<username>` account is provisioned lazily, on first elevation — not at policy-enable time.** Don't treat its absence on a freshly-configured device as a failure signal; confirm an elevation has actually been attempted first.

- **Profile separation is a deliberate anti-credential-theft design choice, not a bug.** An elevated process's settings/shortcuts genuinely landing in an isolated profile is the feature working correctly — reframe these tickets as "plan around this" rather than "fix this."

- **This is an actively rolling-out, still-maturing feature as of this writing** — broader deployment via KB5120998 began around September 2026, and Microsoft/independent researchers have both published compatibility and design-flaw findings since the original 24H2 introduction. Re-verify current guidance via Windows Release Health and Microsoft Learn before treating any specific behavior here as permanently fixed, and keep affected devices current on cumulative updates.

- **Test line-of-business installers, RMM/management agents, and any automation expecting persistent elevated context on a pilot group before fleet-wide rollout.** The no-persistent-elevated-session design is exactly the kind of change that silently breaks legacy tooling nobody has re-validated in years.

- **A reboot is required for Admin Approval Mode type changes to take effect** — this is a boot-time token/security-state configuration, not a live-appliable policy the way many other Settings Catalog items are.
