# Microsoft 365 Apps (Office Desktop Client) — Agent Instructions

## What's in this folder

The **Microsoft 365 Apps for enterprise/business desktop client stack**: Click-to-Run installation architecture, the Office Deployment Tool (ODT), update channel selection/servicing (Current, Monthly Enterprise, Semi-Annual Enterprise, Beta), and client-level activation (standard user-based activation and Shared Computer Activation for RDS/Citrix/kiosk scenarios). Includes the July 2026 SAC/MEC cadence unification (Version 2606) as a load-bearing, currently-in-effect platform change.

Does not cover Outlook-specific profile/Autodiscover/OST/COM add-in issues (`M365/Exchange/Outlook-Client-A.md`/`-B.md`), Entra ID license *assignment* (`M365/Licensing/`), or New Outlook/New Teams-style WebView2 apps (architecturally unrelated — no Click-to-Run, no update channel concept).

---

## Before responding, also check

- `M365/Exchange/Outlook-Client-A.md` — if the symptom is Outlook-specific (profile, Autodiscover, OST, COM add-ins) rather than the Click-to-Run install itself
- `M365/Licensing/License-Assignment-A.md` / `Group-Based-Licensing-A.md` — if the issue is which Entra ID SKU a user has, not whether the client can activate against an existing assignment
- `Intune/Troubleshooting/Platform-Scripts-A.md` — if Office deployment is being pushed as an Intune Win32 app rather than via ODT/GPO directly
- `M365/Copilot/_AGENT.md` — if the Copilot ribbon entry point is missing (base license/Click-to-Run must be healthy first, but the actual fix path is Copilot-specific)

---

## Folder contents

| File | What it covers |
|------|---------------|
| `Deployment-UpdateChannels-B.md` | Hotfix runbook — channel/activation triage, diagnosis, and fix paths in under 10 minutes |
| `Deployment-UpdateChannels-A.md` | Deep-dive reference — full Click-to-Run architecture, channel resolution precedence, July 2026 SAC/MEC unification, Symptom → Cause map, remediation playbooks |
| `CompanionAppsRetirement-B.md` | Hotfix — Microsoft 365 companion apps (Calendar/People/Files, AppX `Microsoft.M365Companions`) retirement under MC1474111: close install vectors (admin-center toggle, Intune Required/Available), remove per-user + provisioned package, stop reinstalls before 16 Dec 2026 |
| `CompanionAppsRetirement-A.md` | Deep dive — packaging, the four install vectors, registered-vs-provisioned AppX, Intune `/assign` replace semantics, Remediation-based fleet removal, golden-image clean-up |
| `Scripts/Remove-M365CompanionApps.ps1` | Detect (exit 1/0, Remediation-ready) or `-Remediate` removal of the companion apps for all users + provisioned copy + leftover data folders, with CSV report |
| `PublisherRetirement-B.md` | Hotfix — Microsoft Publisher end of life (M365 access ends 1 Oct 2026; perpetual support ends 13 Oct 2026): subscription vs perpetual triage, `.pub` inventory, bulk PDF/DOCX conversion while a Publisher engine exists |
| `PublisherRetirement-A.md` | Deep dive — format-extinction framing, Publisher COM object model (`ExportAsFixedFormat` PDF=2), PS 5.1 interop requirement, Search vs Purview discovery, perpetual "conversion station", LibreOffice fallback |
| `Scripts/Get-PublisherRetirementReadiness.ps1` | Publisher install-type detection + recursive `.pub` inventory (optional Microsoft Search via Graph) + optional `-Convert`/`-AlsoWord` bulk conversion with log |
| `Scripts/Get-M365AppsHealth.ps1` | Read-only fleet/device health check: install type, resolved update channel + authority (GPO/ODT/admin center), update task state, CDN reachability, activation status |

---

## Common entry points

- "I changed the update channel and nothing happened" → `Deployment-UpdateChannels-B.md` § Fix 1 — check for a GPO silently overriding ODT/admin center
- "Office repair dialog does nothing when I click Repair" → `Deployment-UpdateChannels-B.md` § Fix 3 — Quick Repair → Online Repair fallback sequence
- "Unlicensed Product / can't sign in" on a shared or kiosk device → `Deployment-UpdateChannels-B.md` § Fix 4 — Shared Computer Activation quota/token issue
- "User has the right license in Entra but Office still shows Unlicensed" → `Deployment-UpdateChannels-B.md` § Fix 5 — stale local licensing cache
- "A feature disappeared after an update" → `Deployment-UpdateChannels-A.md` § Symptom → Cause Map — expected per-channel feature rollout variance, confirm channel before treating as a bug
- "Calendar/People/Files apps keep coming back on the taskbar" / "how do we remove the companion apps" → `CompanionAppsRetirement-B.md` § Fix 2 then Fix 3
- "User can't open their .pub flyer" / "Publisher disappeared from Office" → `PublisherRetirement-B.md` (expected after 1 Oct 2026 — convert on a perpetual install)
- "Find and convert all our Publisher files before the deadline" → `Scripts/Get-PublisherRetirementReadiness.ps1` + `PublisherRetirement-A.md` § Troubleshooting phases
- "Why is our Semi-Annual Enterprise Channel device updating monthly now" → `Deployment-UpdateChannels-A.md` § July 2026 SAC/MEC unification — expected platform change, not a misconfiguration

---

## Key diagnostic commands

```powershell
# Confirm Click-to-Run install and resolved channel/version
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration" -ErrorAction SilentlyContinue |
    Select-Object VersionToReport, UpdateChannel, ClientCulture, Platform

# Confirm whether GPO is overriding the channel (this always wins if present)
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\OfficeUpdate" -ErrorAction SilentlyContinue

# Confirm the update scheduled task is enabled and healthy
Get-ScheduledTask -TaskName "Office Automatic Updates 2.0" | Select-Object State
Get-ScheduledTaskInfo -TaskName "Office Automatic Updates 2.0" | Select-Object LastRunTime, LastTaskResult

# Confirm activation/licensing state
& "$env:ProgramFiles\Microsoft Office\Office16\OSPP.VBS" /dstatus

# Retirements (Sept–Dec 2026)
Get-AppxPackage -AllUsers -Name 'Microsoft.M365Companions'                     # companion apps (retire 16 Dec 2026)
(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration').ProductReleaseIds   # O365* = loses Publisher 1 Oct 2026
```

---

## Key dependency chain

```
Click-to-Run install confirmed →
  Update channel resolved (GPO > ODT config.xml > admin center org default > per-product default) →
    "Office Automatic Updates 2.0" task enabled →
      Office CDN reachable (officecdn.microsoft.com) →
        Click-to-Run servicing engine applies update
                                            (independent chain, same symptom layer)
Entra ID license assignment includes Microsoft 365 Apps SKU →
  Licensing token issued and cached locally (OneAuth) →
    [If Shared Computer Activation] SKU supports SCA AND per-user quota not exceeded →
      App reports Licensed Product
```

Update-channel health and activation health are independent failure domains that share only the symptom layer ("Office seems broken") — always establish which one applies before picking a fix path.

---

## Response format reminder (always 3 layers)

1. **Triage first** — confirm install type (Click-to-Run vs. MSI/LTSC vs. New Outlook), then split into update-channel vs. activation/licensing before touching anything
2. **Fix the specific failure** — use the matching fix path from `Deployment-UpdateChannels-B.md`; escalate to the Mode A reference for GPO precedence chains or the SAC/MEC cadence change
3. **Confirm resolution** — verify via `File > Account` (version/build) and `OSPP.VBS /dstatus` (license status) after any change, not just absence of an error message

> **Cross-reference (run 252):** `OSPP.VBS` is a VBScript file. Once the VBScript Feature on Demand is disabled by default (Phase 2, ~2027), `OSPP.VBS /dstatus` and volume/LTSC Office activation through OSPP stop working unless the FOD is re-enabled. See `Windows/Troubleshooting/VBScriptDeprecation-B.md` Fix 3 and Fix 4 (VBA `VBScript.RegExp`, built in from Version 2508).
