# Windows SSO Permission Auto-Accept (KB5101650) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

**This is an opt-in admin control, not a bug fix.** Since the July 2026 monthly security update
(**KB5101650** for Windows 11 24H2/25H2), Windows shows a "Continue to sign in?" SSO consent prompt
the first time a user signs in to an app with the same credentials used to sign in to Windows — a
behavior change originally made for the European Economic Area (EEA). Microsoft now ships a registry
policy that lets IT admins suppress that prompt tenant-wide on **managed** devices only. Most tickets
here are "why do users keep seeing a sign-in popup" or "the registry key isn't suppressing the prompt,"
not an outage.

```powershell
# 1. Is the device even eligible? (OS version + build)
Get-ComputerInfo | Select-Object WindowsProductName, OsVersion, OsBuildNumber

# 2. Is the July 2026 security update (or later) installed?
Get-HotFix -Id KB5101650 -ErrorAction SilentlyContinue
# 24H2 uses KB5101650; confirm the 25H2 equivalent build too if this returns nothing:
Get-HotFix | Where-Object { $_.InstalledOn -gt (Get-Date "2026-07-01") } | Select-Object HotFixID, InstalledOn

# 3. Is the registry policy actually present and set?
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AAD" -Name AutoAcceptSsoPermission -ErrorAction SilentlyContinue

# 4. Is the device Entra-joined/hybrid-joined (personal/unmanaged devices are NOT eligible)?
dsregcmd /status | Select-String "AzureAdJoined|DomainJoined|EnterpriseJoined"

# 5. Which account type is signing in? (MSA prompts can NEVER be suppressed by this policy)
whoami /upn
```

| Result | Interpretation |
|---|---|
| `OsBuildNumber` below 26200.8875 (24H2) or the 25H2 equivalent, or `Get-HotFix KB5101650` returns nothing | **Not eligible yet** — the policy key does nothing until the July 2026 (or later) cumulative update is installed. Go to Fix 1. |
| Registry value missing entirely | Policy was never deployed to this device — go to Fix 2 (deploy via Intune/GPO). |
| Registry value present, `AutoAcceptSsoPermission = 1`, prompt still appears | Check account type first (Fix 3) — this policy has zero effect on personal Microsoft accounts (MSA) and unmanaged devices by design, not a bug. |
| `dsregcmd /status` shows neither `AzureAdJoined : YES` nor a hybrid state | **Out of scope for this policy entirely** — unmanaged/workgroup devices always show the prompt; there is no admin override. |
| Ticket says "prompt shows once, then never again" | **Expected default behavior even without this policy** — Windows only asks once per user/app combination; if they said yes once, it won't reappear regardless of this key. Don't treat this as a fix needed. |
| Registry value applied but device is outside the EEA and never saw the prompt | Expected — the underlying sign-in-choice prompt itself is an EEA-driven behavior change; devices outside EEA scope may not show it at all, so this policy has nothing to suppress. Confirm with Fix 4 before assuming misconfiguration. |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
[EEA Windows sign-in choice prompt — the underlying behavior this policy controls]
  └─ Applies to a first-time sign-in per user/app/credential-type combination
         |
[Device eligibility gate — ALL of these must be true, no partial credit]
  ├─ Windows 11, version 24H2 or 25H2 (not Windows 10, not earlier 11 versions, no override)
  ├─ July 2026 security update installed:
  │     KB5101650 → 24H2 (OS builds 26100.8875 / 26120.8875 family)
  │     KB5094126 → 25H2 equivalent build
  ├─ Device is Microsoft Entra joined OR hybrid Entra joined (NOT Entra registered / workgroup)
  └─ Signing-in account is a work/school Entra ID account (NOT a personal Microsoft account)
         |
[Registry policy — HKLM\SOFTWARE\Policies\Microsoft\Windows\AAD]
  └─ AutoAcceptSsoPermission (DWORD) = 1
         |
[Deployment surface — any ONE of these lands the same registry value]
  ├─ Group Policy (GPO) — Computer Configuration > Preferences > Registry, or a custom ADMX
  ├─ Microsoft Intune / MDM — Settings Catalog / custom OMA-URI, or a PowerShell script/Win32 app
  ├─ Microsoft Configuration Manager — Compliance Settings or a deployed script
  └─ Any other registry-policy-capable management tool
         |
[Effective result]
  └─ Eligible managed devices: prompt is silently auto-accepted, user never sees it
  └─ Personal Microsoft accounts on the SAME device: prompt still appears — no override exists
  └─ Unmanaged/personal devices: prompt still appears — no override exists, and the policy key
        has no effect even if manually written to the registry (Windows enforces eligibility
        beyond just reading the value)
```

</details>

---
## Diagnosis & Validation Flow

**1. Confirm the build/update prerequisite (most common false-negative)**
```powershell
[System.Environment]::OSVersion.Version
Get-HotFix -Id KB5101650 -ErrorAction SilentlyContinue
```
Expect a build number at or above 26200.8875 for 24H2, or the equivalent 25H2 servicing baseline
(KB5094126). If the device is behind on updates, the registry key exists but is inert — this is the
single most common reason engineers report "the policy isn't working."

**2. Confirm the policy value is actually applied (not just deployed)**
```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AAD" -Name AutoAcceptSsoPermission -ErrorAction SilentlyContinue |
    Select-Object AutoAcceptSsoPermission
```
Expect `AutoAcceptSsoPermission : 1`. If the key path exists but the value is `0` or absent, the
deployment mechanism (GPO/Intune) either hasn't applied yet or targets the wrong OU/group — check
`gpresult /h report.html` or the Intune device's policy assignment status before assuming the setting
itself is broken.

**3. Confirm device management/join state**
```powershell
dsregcmd /status
```
Expect `AzureAdJoined : YES` (cloud-only) or both `DomainJoined : YES` and `AzureAdJoined : YES`
(hybrid). `AzureAdJoined : NO` with only `WorkplaceJoined` (Entra registered, e.g. a personal device
with a work account added) is explicitly **out of scope** — that's the workplace-join model, not a
managed device, and Microsoft's documented scope only covers managed enterprise devices.

**4. Confirm which account triggered the prompt**
Ask which account experienced the prompt, or check `whoami /upn` in the affected session. If it's a
personal Microsoft account (`@outlook.com`, `@hotmail.com`, `@live.com`, or a custom domain configured
as an MSA), stop — this policy structurally cannot suppress that prompt. Redirect the conversation to
"why is a personal account being used on this managed device" instead.

**5. Confirm the prompt is actually the SSO consent prompt, not something else**
The dialog title is "Continue to sign in?" with body text referencing using Windows credentials to
sign in to other apps/services, and a link to `aka.ms/sso-info`. If the reported prompt has different
text (e.g., an MFA challenge, a certificate trust prompt, or an app-specific consent screen), this is
the wrong runbook — do not apply these fixes.

---
## Common Fix Paths

<details><summary>Fix 1 — Device is not yet eligible (missing prerequisite update)</summary>

Use when: `Get-HotFix KB5101650` (or the 25H2 equivalent) returns nothing, or the build number is below
the documented minimum.

```powershell
# Trigger a scan for the July 2026 (or later) cumulative update via Windows Update
UsoClient StartScan

# Or, if managed via WSUS/Configuration Manager, confirm the update is approved and deployed
# to the target collection/group — this is a normal patch-compliance issue, not specific to this policy
```

**Rollback:** N/A — installing a cumulative security update is not something to roll back for this
purpose; simply wait for normal patch compliance if the update isn't due to install immediately.

</details>

<details><summary>Fix 2 — Deploy the registry policy (device is eligible but key is missing)</summary>

Use when: Triage steps 1–2 pass (eligible build + update installed) but step 3 shows no registry value.

**Via Intune (Settings Catalog / custom OMA-URI):**
```
1. Intune admin center > Devices > Configuration > Create > New Policy
2. Platform: Windows 10 and later, Profile type: Settings Catalog
3. Search for "AAD" or add via custom OMA-URI:
   OMA-URI: ./Device/Vendor/MSFT/Policy/Config/ADMX_AAD/AutoAcceptSsoPermission
   (If not yet exposed as a native Settings Catalog setting, use a Win32/PowerShell script deployment
   instead — see below.)
4. Assign to the target device group and confirm deployment status in Intune.
```

**Via PowerShell script deployment (Intune Win32 app, GPO Group Policy Preferences, or Configuration
Manager script) — most reliable path today since native CSP/ADMX exposure may lag the OS release:**
```powershell
$regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AAD"
if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
}
New-ItemProperty -Path $regPath -Name "AutoAcceptSsoPermission" -Value 1 -PropertyType DWord -Force
```

**Via Group Policy:**
```
Computer Configuration > Preferences > Windows Settings > Registry
  Action: Update
  Hive: HKEY_LOCAL_MACHINE
  Key Path: SOFTWARE\Policies\Microsoft\Windows\AAD
  Value name: AutoAcceptSsoPermission
  Value type: REG_DWORD
  Value data: 1
```

**Rollback:** Delete the `AutoAcceptSsoPermission` value (or set it to `0`) and re-run `gpupdate /force`
(GPO) or sync the device (Intune). The consent prompt returns to its default per-user/per-app behavior —
no reboot required for the policy read itself, though the affected app's own SSO session cache may need
a sign-out/sign-in cycle to visibly change.

</details>

<details><summary>Fix 3 — Prompt still appears despite correct policy + eligible device</summary>

Use when: Triage steps 1–3 all pass, but the user still reports seeing the prompt.

```
1. Confirm the account type per Diagnosis step 4 — if it's a personal Microsoft account, this is
   expected; there is no fix, only user education ("use your work account for work apps").
2. Confirm the app itself is actually using Windows Web Account Manager (WAM) / the same
   Entra ID credential Windows signed in with, not a fully separate sign-in flow the app manages
   itself (some line-of-business apps have their own login screens unrelated to this OS-level prompt).
3. Confirm the user hasn't already dismissed/declined the prompt for that specific app once already —
   a prior explicit "Don't sign in" choice is sticky per app and is a different state than "never asked."
   Test with a different, never-before-signed-into app if possible.
4. If all of the above check out and the prompt still appears, capture a screenshot of the exact
   dialog text and escalate — this may be a genuine platform issue outside documented behavior.
```

**Rollback:** N/A — diagnostic only.

</details>

<details><summary>Fix 4 — Confirm EEA/regional scope before troubleshooting further</summary>

Use when: a non-EEA tenant reports "we never see this prompt at all, is our policy broken?"

```
This is not a defect. The underlying sign-in-choice prompt was introduced specifically for the
European Economic Area sign-in experience change. Tenants/devices outside that scope may not display
the prompt in the first place, meaning AutoAcceptSsoPermission has nothing to suppress — deploying the
policy is still harmless (and future-proofs the tenant if scope expands), but its absence of visible
effect is not evidence of misconfiguration.
```

**Rollback:** N/A — no change was made.

</details>

---
## Escalation Evidence

```
SSO PERMISSION AUTO-ACCEPT ESCALATION
=========================================
Date/Time                              :
Device name                            :
Windows version/build (OsBuildNumber)  :
KB5101650 / KB5094126 installed?       : Yes / No
dsregcmd join state                    : AzureAdJoined=___  DomainJoined=___
AutoAcceptSsoPermission registry value :
Deployment mechanism (Intune/GPO/CM)   :
Deployment/assignment status           :
Account type experiencing prompt       : Work/School / Personal (MSA)
App where prompt appeared              :
Exact prompt text (verbatim)           :
Steps Already Tried                    :
```

---
## 🎓 Learning Pointers

- **This is a brand-new (July 2026) admin control, not a legacy setting** — many engineers won't have
  seen `HKLM\SOFTWARE\Policies\Microsoft\Windows\AAD\AutoAcceptSsoPermission` before; it doesn't exist
  on devices without the prerequisite cumulative update installed, so "the key is missing" is often just
  a patch-currency problem. [Admin control for SSO prompts in Windows](https://learn.microsoft.com/en-us/entra/identity/devices/sso-admin-control)
- **The underlying prompt itself predates this policy** — Windows already asked this "Continue to sign
  in?" question for EEA users; this update only adds an admin override, it doesn't introduce the prompt.
  [Upcoming changes to Windows single sign-on](https://techcommunity.microsoft.com/blog/windows-itpro-blog/upcoming-changes-to-windows-single-sign-on/4008151)
- **Scope is a hard boundary, not a tuning knob** — personal Microsoft accounts and unmanaged devices
  are permanently excluded by design (privacy/consent reasons for personal accounts). Don't spend time
  trying to extend this policy to those scenarios.
- **Treat this the same as any other registry-based device policy for deployment troubleshooting** —
  GPO processing order, Intune assignment/sync timing, and OMA-URI/CSP availability lag are the same
  failure modes you already know from other policy rollouts; nothing about the SSO-specific mechanism
  changes standard MDM/GPO triage.
- **Watch for native Settings Catalog/CSP exposure to catch up after initial release** — Microsoft
  documents GPO/Intune/Configuration Manager/"any MDM tool" as valid deployment paths from day one, but
  a dedicated Settings Catalog UI entry (vs. a raw OMA-URI/registry push) may land in a later Intune
  service release. Check for a native setting before defaulting to the manual OMA-URI/script path.
