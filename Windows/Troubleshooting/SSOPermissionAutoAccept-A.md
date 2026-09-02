# Windows SSO Permission Auto-Accept (KB5101650) — Reference Runbook (Mode A: Deep Dive)
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
- [Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

This runbook covers the **admin control for SSO prompts in Windows** — a registry-based policy,
`AutoAcceptSsoPermission`, available beginning with the July 2026 monthly security update for Windows
11, version 24H2 (KB5101650) and 25H2 (KB5094126). It does **not** cover:
- General Entra ID single sign-on architecture, PRT (Primary Refresh Token) issuance, or WAM (Web
  Account Manager) internals beyond what's needed to explain this prompt — see `EntraID/Troubleshooting/`
  for PRT-specific troubleshooting.
- macOS Platform SSO (`macOS/Troubleshooting/Platform-SSO-A.md`) — an architecturally unrelated feature
  on a different OS with a different consent model.
- Browser-based SSO extensions (Entra ID SSO plug-in for Chrome/Firefox) — those govern browser-to-IdP
  sign-in, not the OS-level "use my Windows credentials for this app" prompt covered here.

Assumes: Windows 11 24H2/25H2 fleet, managed via Intune and/or Group Policy, Entra ID or hybrid Entra
ID joined devices. Server SKUs and Windows 10 are out of scope — this control does not exist there.

---
## How It Works

<details><summary>Full architecture</summary>

**Background — why the prompt exists at all.** In the European Economic Area (EEA), regulatory
pressure led Microsoft to change the default Windows sign-in experience so that signing in to Windows
no longer silently and automatically signs the user in to every other Microsoft app or service that
supports the same credential. Instead, the first time a user opens an app capable of using either a
personal Microsoft account (MSA) or a work/school Entra ID account already active on the device,
Windows shows a modal: "Continue to sign in?" with the account identity displayed, an explanation that
using the same account signs the user into other Microsoft apps/services, a link to `aka.ms/sso-info`,
and two buttons — "Don't sign in" (default focus in some builds, grey) and "Continue" (blue, the
accept action). If the user selects Continue, the choice is remembered for that user/app combination
and the prompt does not reappear for it. If they select "Don't sign in," the app falls back to
requiring an explicit separate sign-in.

This is fundamentally a **consent friction** mechanism, not a security control — it does not block
sign-in, it only adds a click. But at enterprise scale, thousands of users independently answering this
dialog for line-of-business apps generates unnecessary helpdesk load and confusion, especially in
already-fully-trusted managed environments where the organization has already established the identity
trust relationship at the device-join level.

**The admin control.** Starting with KB5101650 (24H2) / KB5094126 (25H2), Microsoft added a registry
value IT admins can deploy to managed devices to **automatically accept** this prompt on the user's
behalf, suppressing it entirely for eligible sign-ins:

```
Registry Path : HKLM\SOFTWARE\Policies\Microsoft\Windows\AAD
Value Name    : AutoAcceptSsoPermission
Value Type    : REG_DWORD
Value Data    : 1  (enable auto-accept)  |  0 or absent  (default prompt behavior)
```

**Eligibility is enforced by Windows, not just by the value being present.** Setting the registry key
on an ineligible device (wrong OS version, missing update, unmanaged device, or a personal Microsoft
account signing in) has no effect — Windows evaluates the full eligibility chain at prompt-time, not
just "does this registry value exist." This is a deliberate design choice: Microsoft explicitly scoped
this control to **managed enterprise devices only**, specifically to avoid extending an
automatic-consent mechanic to consumer/personal contexts where the original EEA regulatory concern
(user awareness and control over cross-service credential sharing) still applies.

**Why this shipped as a security update (KB), not a feature update.** Because the underlying prompt
behavior itself was already live (an earlier, separate change), this admin control is a targeted
addition to existing sign-in code paths rather than a new feature surface — hence its delivery via the
monthly cumulative/security update channel rather than a feature update or enablement package (compare
to `Windows11-26H2-A.md`'s eKB model, which is architecturally different).

**Relationship to WAM and PRT.** The prompt sits at the Web Account Manager (WAM) broker layer — the
same OS component that already brokers PRT-backed silent sign-in for Entra-joined devices. The
auto-accept policy does not change PRT issuance, token lifetime, or any Conditional Access evaluation;
it only changes whether WAM's own **user-consent gate** (the "may I use this account for this app"
question) is skipped. A device with a broken PRT or a Conditional Access block will still fail sign-in
even with `AutoAcceptSsoPermission = 1` — this policy has no bearing on authentication success or
failure, only on the extra confirmation click.

</details>

---
## Dependency Stack

```
[Windows 11, version 24H2 or 25H2]                              ← OS version floor (bottom layer)
        │
[July 2026+ cumulative/security update installed]                ← KB5101650 (24H2) / KB5094126 (25H2)
        │                                                            or later — code path doesn't exist
        │                                                            before this
[Device management state: Microsoft Entra joined OR hybrid       ← enforced by Windows at
 Entra joined]                                                       evaluation time, not just by
        │                                                            registry-key presence
[Signing-in identity: work/school Entra ID account]               ← personal Microsoft accounts (MSA)
        │                                                            are permanently excluded
[WAM (Web Account Manager) broker — evaluates the SSO             ← same broker used for ordinary
 consent gate on this specific user/app/credential combo]            PRT-backed silent sign-in
        │
[Registry policy read: HKLM\SOFTWARE\Policies\Microsoft\          ← the actual admin control
 Windows\AAD\AutoAcceptSsoPermission = 1]
        │
[Deployment/enforcement surface — any ONE of:]                   ← top layer: how the value
  ├─ Group Policy (Computer Configuration > Preferences)             physically lands on the device
  ├─ Microsoft Intune (Settings Catalog / OMA-URI / Win32 script)
  ├─ Microsoft Configuration Manager (Compliance Settings / script)
  └─ Any registry-policy-capable MDM tool
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Users on managed devices still see the "Continue to sign in?" prompt after policy deployment | Missing prerequisite cumulative update — the registry value is inert without it | `Get-HotFix -Id KB5101650` / build number check |
| Registry value exists and equals `1`, prompt still appears | Personal Microsoft account (MSA) signing in — permanently out of scope | `whoami /upn`, account type |
| Registry value exists and equals `1`, prompt still appears, device confirmed eligible | App isn't using WAM/OS-brokered sign-in at all (fully custom in-app login) | Confirm the app's sign-in implementation with the vendor/dev team |
| Registry value never applied to the device | GPO/Intune targeting gap, or sync/processing hasn't run yet | `gpresult /h`, Intune device policy assignment status |
| "We deployed this tenant-wide and nothing changed" (non-EEA tenant) | Underlying prompt may never have been shown in that region/scope to begin with | Confirm EEA/regional applicability before assuming misconfiguration |
| Prompt reappears for an app the user previously accepted | Expected only if a **different** credential/app combination is now involved, or app data/profile was reset | Confirm exact app + account match to the prior acceptance |
| Registry key present under the wrong hive/path (e.g., HKCU instead of HKLM) | Manual/incorrect deployment — this is a machine-wide (HKLM) policy only | Verify exact path: `HKLM:\SOFTWARE\Policies\Microsoft\Windows\AAD` |

---
## Validation Steps

**1. OS eligibility**
```powershell
Get-ComputerInfo | Select-Object WindowsProductName, OsVersion, OsBuildNumber
```
Good: build number at/above the 24H2 (26200.8875 family) or 25H2 post-July-2026 servicing baseline.
Bad: any Windows 10 build, or a 24H2/25H2 build below the documented minimum — no admin control exists.

**2. Update installed**
```powershell
Get-HotFix -Id KB5101650 -ErrorAction SilentlyContinue
```
Good: a result is returned with an `InstalledOn` date. Bad: empty result — check for the 25H2-specific
KB (KB5094126) or a later superseding cumulative update before concluding it's missing.

**3. Registry policy value**
```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AAD" -Name AutoAcceptSsoPermission -ErrorAction SilentlyContinue
```
Good: `AutoAcceptSsoPermission : 1`. Bad: path/value not found (never deployed), or value `0`
(explicitly disabled — a valid state, not a fault, if that's the intended tenant posture).

**4. Device join/management state**
```powershell
dsregcmd /status
```
Good: `AzureAdJoined : YES` (with or without `DomainJoined : YES` for hybrid). Bad: `AzureAdJoined : NO`
with only workplace-join (`WorkplaceJoined : YES`) — that device is out of scope regardless of registry
state.

**5. End-to-end behavioral confirmation**
On an eligible, policy-applied device, sign in to a never-before-used app with the same Entra ID
credential as the Windows sign-in. Good: no "Continue to sign in?" prompt appears. Bad: prompt still
appears — work back up the eligibility chain from Validation Steps 1–4 before treating this as a defect.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Confirm the platform even applies here.** Verify OS version, build, and update level before
touching any policy tooling. This single check resolves the majority of "policy doesn't work" reports.

**Phase 2 — Confirm policy delivery.** Treat this exactly like any other registry-based Group
Policy/Intune setting: check assignment scope (correct OU/security group/device group), sync timing
(`gpupdate /force`, Intune device sync), and conflicting GPOs/profiles that might overwrite the same
registry path from a different, lower-priority source.

**Phase 3 — Confirm identity/account scope.** Rule out personal Microsoft accounts and workplace-joined
(not fully managed-joined) devices — both are permanent, by-design exclusions, not misconfigurations to
chase.

**Phase 4 — Confirm the specific app's sign-in implementation.** A small number of line-of-business or
third-party apps implement their own login UI entirely separate from WAM/OS-brokered SSO. This admin
control has no effect on apps that never call into the OS SSO broker in the first place.

**Phase 5 — Escalate with evidence.** If all prior phases check out and the behavior still doesn't
match documentation, this is a candidate for a genuine platform issue — capture the Evidence Pack below
before opening a Microsoft support case.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Fleet-wide rollout via Intune Settings Catalog / custom policy</summary>

```
1. Inventory eligible devices first — build a dynamic Entra ID device group filtered to
   Windows 11 24H2/25H2 AND Entra-joined/hybrid-joined (exclude workplace-joined/BYOD).
2. Deploy the registry value via a Settings Catalog custom policy (or Win32/PowerShell script
   deployment if the native CSP surface hasn't caught up yet — see the PowerShell snippet in the
   -B.md Fix 2 section).
3. Assign to the eligible device group from step 1 — do NOT assign tenant-wide if the group
   includes BYOD/personal devices, since the policy is inert there but a broad assignment can mask
   later legitimate scoping questions.
4. Validate on a pilot ring (5-10 devices) before full rollout — confirm end-to-end prompt
   suppression with the Validation Steps above.
5. Monitor helpdesk ticket volume for "unexpected sign-in behavior" for one week post-rollout as a
   soft signal the policy applied as expected.
```

**Rollback:** Remove the assignment (Intune) or the GPO link; existing devices revert to prompting
once the policy value is removed/re-set to `0` and re-applied — no reboot required for the registry
read itself, though already-cached WAM consent decisions for previously-suppressed apps are unaffected
retroactively (removing the policy does not "un-accept" prior automatic acceptances).

</details>

<details><summary>Playbook 2 — Reactive fix for a specific ticket ("why do I see this popup")</summary>

```
1. Confirm the exact prompt text matches the documented "Continue to sign in?" dialog (not a
   different consent/MFA/certificate prompt).
2. Run the Validation Steps against the affected device.
3. If the device is eligible and policy-compliant, this is a one-time, per-app/per-account
   acknowledgment — advise the user to select "Continue" once; it will not reappear for that
   specific app/account combination.
4. If the device is NOT eligible (missing update, wrong join state, personal account), explain the
   scope limitation rather than attempting a workaround — none exists for out-of-scope
   devices/accounts by design.
```

**Rollback:** N/A — this playbook is diagnostic/explanatory, not a configuration change.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects SSO Permission Auto-Accept eligibility and policy-state evidence for escalation.
#>
$evidence = [ordered]@{
    ComputerName          = $env:COMPUTERNAME
    OSBuild               = (Get-ComputerInfo).OsBuildNumber
    KB5101650Installed    = [bool](Get-HotFix -Id KB5101650 -ErrorAction SilentlyContinue)
    RegistryValue         = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AAD" `
                                -Name AutoAcceptSsoPermission -ErrorAction SilentlyContinue).AutoAcceptSsoPermission
    DsregcmdStatus        = (dsregcmd /status | Out-String)
    SignedInUPN           = (whoami /upn)
    RecentCumulativeUpdates = (Get-HotFix | Where-Object { $_.InstalledOn -gt (Get-Date).AddMonths(-3) } |
                                Select-Object HotFixID, InstalledOn)
}
$evidence | ConvertTo-Json -Depth 4 | Out-File "$env:TEMP\SSOAutoAccept-Evidence.json"
Write-Host "Evidence written to $env:TEMP\SSOAutoAccept-Evidence.json"
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-ComputerInfo \| Select OsBuildNumber` | Confirm OS build eligibility |
| `Get-HotFix -Id KB5101650` | Confirm July 2026 (24H2) update installed |
| `Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\AAD -Name AutoAcceptSsoPermission` | Read current policy value |
| `dsregcmd /status` | Confirm Entra join/management state |
| `whoami /upn` | Identify signed-in account type |
| `gpupdate /force` | Force Group Policy reprocessing after a GPO change |
| `gpresult /h report.html` | Full applied-policy report for a device |
| `UsoClient StartScan` | Trigger a Windows Update scan if the prerequisite KB is missing |

---
## 🎓 Learning Pointers

- **Read the source doc for the exact eligibility matrix before assuming any workaround exists** — the
  scope restrictions (managed devices only, work/school accounts only) are explicit product decisions,
  not gaps. [Admin control for SSO prompts in Windows](https://learn.microsoft.com/en-us/entra/identity/devices/sso-admin-control)
- **This is a consent-friction control, not an authentication or security control** — don't confuse
  troubleshooting this with PRT, Conditional Access, or token-issuance troubleshooting; a broken PRT
  will still break sign-in regardless of this policy's state.
- **Registry-based Windows policies without a mature Settings Catalog entry are common in the first
  service-release cycle after a feature ships** — this is a general pattern worth recognizing across
  many recent Windows admin controls, not unique to this one.
- **The EEA origin of the underlying prompt matters for expectation-setting with non-EEA clients** — a
  tenant that never sees the prompt isn't misconfigured; the control has nothing to suppress there.
- **Cross-reference `WindowsBackup-A.md`'s Enterprise State Roaming consolidation section** — both this
  policy and that consolidation reflect the same broader mid-2026 trend of Microsoft adding
  enterprise-specific overrides to consumer-oriented default behaviors on managed Windows devices.
