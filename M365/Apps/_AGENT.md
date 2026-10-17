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
| `Activation-B.md` | Hotfix — Microsoft 365 Apps activation/licensing: Unlicensed Product / Product Deactivated / Subscription expired, WAM wrong-account and sign-in loops, SCA on/off on existing installs, 5-device limit, Business↔Enterprise SKU mismatch, scripted activation reset |
| `Activation-A.md` | Deep dive — vNext licensing (per-user licence files, why OSPP.VBS shows nothing, vNextDiag.ps1), WAM/PRT identity dependency, user-based vs SCA vs device-based modes, SCA token roaming on FSLogix/non-persistent VDI, tenant-migration and product-switch playbooks |
| `Scripts/Get-M365AppsActivationDiagnostics.ps1` | Read-only per-user/device activation audit: product IDs, SCA (C2R/policy/token override) vs host type, licence/token file age, cached Office identities vs expected UPN, legacy ADAL overrides, dsregcmd PRT, BrokerPlugin, endpoint 443, AAD events, optional Graph Apps-plan check |
| `OfficeVolumeActivation-B.md` | Hotfix — volume-licensed Office LTSC 2024/2021 & Office 2019 (incl. volume Visio/Project) activation via KMS/ADBA/MAK: Volume-vs-Retail product check, Office licence rows in Windows SPP via CIM (no VBScript), `_vlmcs` SRV/TCP 1688, Office-specific count of 5, 0xC004F074/F038/F042/C008/F050 routing, GVLK/host/MAK/ODT fixes |
| `OfficeVolumeActivation-A.md` | Deep dive — Office-in-SPP architecture (app ID `0ff1ce15-…`), product licence files vs keys, KMS per-generation host OS + Volume License Pack rules (2024 → Server 2019+), ADBA for Office, MAK/VAMT, OSPP.VBS→CIM method mapping, coexistence with M365 Apps, 5 playbooks |
| `Scripts/Get-OfficeVolumeActivationHealth.ps1` | Read-only client/KMS-host check: install classification (Volume/Retail/Subscription), Office licence rows + status/grace/reason decode, manual vs discovered KMS host, SRV + 1688 test, SPP events; `-HostMode` adds Office CSVLK rows, client count, firewall + 12290 activity; CSV |
| `OfficeToM365Migration-B.md` | Hotfix — moving MSI Office 2010–2016, Office 2013 C2R, retail/OEM 2016–2024 and LTSC 2024/2021/2019 volume C2R to Microsoft 365 Apps: install classification from `ProductReleaseIds`/uninstall keys, remove-then-install (ODT `Remove` vs `RemoveMSI`), volume Visio/Project coexistence caveats, bitness (`MigrateArch`), stale SPP key cleanup |
| `OfficeToM365Migration-A.md` | Deep dive — the two 16.0 coexistence rules, C2R configuration key + channel GUIDs, ODT element matrix (Remove/RemoveMSI/IgnoreProduct/MatchPreviousMSI/MigrateArch), licence hand-over SPP → vNext, product ID ↔ licence family, 5 playbooks incl. Intune dependency chain |
| `Scripts/Get-OfficeMigrationReadiness.ps1` | Read-only device readiness: C2R products/bitness/channel decode, MSI + Office 2013 C2R detection, LTSC update-policy pinning, SPP keys, disk/reboot/busy C2R; classifies (MSI / LTSC-Volume / Retail / Half-migrated / Already-M365) with steps; `-GenerateXml` writes remove.xml + install.xml; CSV |
| `Scripts/Get-M365AppsHealth.ps1` | Read-only fleet/device health check: install type, resolved update channel + authority (GPO/ODT/admin center), update task state, CDN reachability, activation status |

---

## Common entry points

- "Unlicensed Product" / "Product Deactivated" / "Subscription expired" / wrong account in File > Account → `Activation-B.md` (identity first, then reset)
- "Enable Shared Computer Activation on an existing RDS/AVD host" or "users hit the 5-device limit on the session host" → `Activation-B.md` Fix 4 / `Activation-A.md` Playbook 1
- "Office LTSC 2024 / 2021 says Unlicensed" / "KMS isn't activating Office" / 0xC004F074, 0xC004F038, 0xC004F042 on Office → `OfficeVolumeActivation-B.md` (confirm *Volume* product first)
- "Our KMS host activates Windows but not Office 2024" → `OfficeVolumeActivation-B.md` Fix 3 / `OfficeVolumeActivation-A.md` Playbook A (VLP + CSVLK per generation)
- "Move users from Office LTSC 2024 / Office 2019 / Office 2016 MSI to Microsoft 365 Apps" / "both Office LTSC and Microsoft 365 show in Apps" / "Intune Remove other versions didn't remove LTSC" / "Visio broke after the Office migration" → `OfficeToM365Migration-B.md` → `OfficeToM365Migration-A.md` playbooks → `Scripts/Get-OfficeMigrationReadiness.ps1 -GenerateXml`
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
