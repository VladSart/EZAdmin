# Microsoft 365 Apps Deployment & Update Channels — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [🎓 Learning Pointers](#-learning-pointers)

---
## Triage

This topic covers the **Microsoft 365 Apps desktop client stack itself** — Click-to-Run installation, the Office Deployment Tool (ODT), update channels, and activation/licensing at the install level. It is distinct from `M365/Exchange/Outlook-Client-A.md` (Outlook-specific profile/Autodiscover/OST issues) and from `M365/Licensing/` (Entra ID license *assignment*, not the client's ability to activate against a valid assignment).

```powershell
# 1. Confirm this is a Click-to-Run install, not New Outlook/MSI/LTSC — different repair paths entirely
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration" -ErrorAction SilentlyContinue |
    Select-Object VersionToReport, UpdateChannel, ClientCulture, Platform

# 2. Current update channel and version/build
& "$env:ProgramFiles\Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe" /getversion 2>$null
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration" | Select-Object VersionToReport, UpdateChannel

# 3. Is the update task actually enabled? (missing/disabled task is a top root cause of "never updates")
Get-ScheduledTask -TaskName "Office Automatic Updates 2.0" -ErrorAction SilentlyContinue | Select-Object State

# 4. Is the update channel forced by Group Policy? (GPO always wins over ODT config file)
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\OfficeUpdate" -ErrorAction SilentlyContinue |
    Select-Object updatebranch, enableautomaticupdates

# 5. Activation/licensing state for the signed-in user
& "$env:ProgramFiles\Microsoft Office\Office16\OSPP.VBS" /dstatus 2>$null
```

| If... | Then... |
|---|---|
| `ClickToRun\Configuration` key doesn't exist at all | Not a Click-to-Run install — check for MSI-based Office (2016/2019/2021 volume-licensed) or **New Outlook/New Teams-style WebView2 apps**, which use an entirely different update/repair model. Stop here and reroute. |
| Update channel shown doesn't match what was intended (e.g. Current instead of Monthly Enterprise) | GPO is very likely overriding ODT — check Fix path 1 registry key first, before touching ODT config. |
| "Office Automatic Updates 2.0" task missing or disabled | Updates silently stop working with no user-visible error. See Fix 2. |
| Repair dialog appears but nothing happens when "Repair" is clicked | Known Click-to-Run repair-process bug — use the Quick Repair → Online Repair fallback sequence. See Fix 3. |
| "We can't sign you in" / "Unlicensed Product" on a shared/kiosk device | Almost certainly a Shared Computer Activation (SCA) licensing-token or seat-limit issue, not a general activation bug. See Fix 4. |
| User signed in, correct license assigned in Entra, but Office still shows Unlicensed | Local licensing cache is stale/corrupt — clear and re-activate. See Fix 5. |
| Feature X used to exist, now missing after an update | Update channel behaves as designed — feature rollout differs per channel and can regress a specific device's feature set if the channel was changed. Confirm intended channel before treating as a bug. |
| July 2026+: a device that was Semi-Annual Enterprise Channel now behaves like Monthly Enterprise Channel | **Expected** — SAC/MEC unification landed July 2026; this is a platform change, not a misconfiguration. See Learning Pointers. |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
[Microsoft 365 Apps feature/security/non-security update reaches the device]
         |
         ▼
[Update channel resolved]  ── one of: Current / Current (Preview) / Monthly Enterprise /
         |                            Semi-Annual Enterprise / Beta (Insider)
         |     Resolution precedence: Group Policy > ODT config.xml Channel attribute >
         |                            M365 admin center org default > per-product default (Current)
         ▼
["Office Automatic Updates 2.0" scheduled task enabled]
         |
         ▼
[Device can reach the Office CDN (or configured update source)]
         |
         ▼
[Click-to-Run servicing engine downloads + applies update in the background]
         |
         ▼
[App relaunch picks up new version — File > Account shows updated Version/Build]
         |
         ▼ (separate, parallel dependency — NOT update-channel-gated)
[Activation: signed-in identity → Entra license assignment → licensing token cached locally]
         |
         ▼
[App reports Licensed Product, all activation-gated features unlocked]
```

Update channel and activation are **independent failure domains** that produce overlapping symptoms ("app is broken/missing features") — always triage which one you're actually looking at before picking a fix path.

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm installation type**
```powershell
Test-Path "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration"
```
`True` = Click-to-Run (this runbook applies). `False` = check for MSI/volume-licensed Office (different update model entirely — WSUS/SCCM-managed, no update channel concept) or New Outlook (separate WebView2 app, no `.ost`, no COM add-ins, own reset path).

**Step 2 — Confirm current channel and version**
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration" |
    Select-Object VersionToReport, UpdateChannel, ClientCulture
```
Cross-check `UpdateChannel` GUID against the known channel URLs (see Command Cheat Sheet) — it's a GUID, not a friendly name, and is easy to misread.

**Step 3 — Confirm what's actually controlling the channel**
```powershell
# GPO always wins if present
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\OfficeUpdate" -ErrorAction SilentlyContinue
```
If this key exists and has a value, **any** change made via ODT config, Microsoft 365 admin center org settings, or the Office Deployment Tool's `Channel` attribute will be silently overridden. This is the single most common "I changed the channel and nothing happened" root cause.

**Step 4 — Confirm the update task is enabled and has actually run recently**
```powershell
Get-ScheduledTask -TaskName "Office Automatic Updates 2.0" | Select-Object State
(Get-ScheduledTaskInfo -TaskName "Office Automatic Updates 2.0").LastRunTime
```

**Step 5 — Confirm CDN reachability**
```powershell
Test-NetConnection -ComputerName officecdn.microsoft.com -Port 443
```

**Step 6 — Confirm activation/licensing state**
```powershell
& "$env:ProgramFiles\Microsoft Office\Office16\OSPP.VBS" /dstatus
```
Look for `LICENSE STATUS: ---LICENSED---`. Anything else (`NOTIFICATIONS`, `OOB_GRACE`, `OOT_GRACE`) points at a licensing-token problem, not a channel/update problem.

---
## Common Fix Paths

<details><summary>Fix 1 — GPO silently overriding intended update channel</summary>

**When:** Channel shown in `ClickToRun\Configuration` doesn't match what was set via ODT or the M365 admin center.

```powershell
# Check for the overriding policy
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\OfficeUpdate" -ErrorAction SilentlyContinue |
    Select-Object updatebranch, enableautomaticupdates
```

Fix: update the GPO itself (Computer Configuration > Policies > Administrative Templates > Microsoft 365 Apps/Office 2016 (Machine) > Updates > "Update Channel") — editing ODT or the admin center setting will have no effect while this GPO is linked and enforced.

**Rollback:** revert the GPO to Not Configured to hand channel control back to ODT/admin center — note that this can shift the device to a different channel/version than the current one, so schedule the change deliberately.

</details>

<details><summary>Fix 2 — "Office Automatic Updates 2.0" task missing or disabled</summary>

```powershell
$task = Get-ScheduledTask -TaskName "Office Automatic Updates 2.0" -ErrorAction SilentlyContinue
if (-not $task) {
    Write-Host "Task missing — re-run the Click-to-Run repair to recreate it." -ForegroundColor Red
} elseif ($task.State -eq "Disabled") {
    Enable-ScheduledTask -TaskName "Office Automatic Updates 2.0"
    Write-Host "Task re-enabled." -ForegroundColor Green
}
```

If the task is missing entirely, a Quick Repair (Fix 3) recreates the Click-to-Run scheduled tasks without requiring a full reinstall.

**Rollback:** N/A — re-enabling a legitimate update mechanism is non-destructive.

</details>

<details><summary>Fix 3 — Repair dialog does nothing when "Repair" is clicked</summary>

**When:** A known Click-to-Run issue where the repair process fails to launch from the dialog itself.

1. Close all Office apps.
2. **Settings > Apps > Installed apps** → find the Microsoft 365 Apps entry → **Modify**.
3. Select **Quick Repair** first — faster, doesn't require internet re-download of the full package, fixes most corruption/missing-file scenarios.
4. If Quick Repair doesn't resolve it, re-run **Modify > Online Repair** — this re-downloads and re-validates the full Click-to-Run package (slower, requires network, fixes deeper corruption Quick Repair can't touch).
5. Restart the computer after either repair completes — some fixes don't take effect until reboot.

**Rollback:** N/A — repair operations are self-contained and don't remove user data or settings.

</details>

<details><summary>Fix 4 — Shared Computer Activation (SCA) licensing-token failure</summary>

**When:** "Unlicensed Product," "we can't sign you in," or similar on a shared/kiosk/RDS-hosted device using Shared Computer Activation.

Root causes, in likely order:
1. **License doesn't support SCA** — confirm the assigned Microsoft 365 Apps license actually supports shared computer activation (not all SKUs do).
2. **Per-user activation-count limit exceeded** — Microsoft caps how many shared computers a single user can be activated on within a rolling period; the fix is de-activating stale sessions, not re-licensing.
3. **Licensing token corrupted locally on the shared device** — clear and re-obtain:
```powershell
& "$env:ProgramFiles\Microsoft Office\Office16\OSPP.VBS" /dstatus
# If token is stale/corrupt, sign the user out completely, clear cached credentials
# (Credential Manager entries for "MicrosoftOffice*" / "OneAuth*"), then sign back in
```
4. Confirm SCA is actually enabled at the ODT/deployment level (`SharedComputerLicensing="1"` in the ODT config used at install time) — SCA is an install-time deployment setting, not a per-session toggle.

**Rollback:** N/A — token refresh is non-destructive; re-signing in doesn't affect other users on the shared device.

</details>

<details><summary>Fix 5 — Local licensing cache stale despite correct Entra license assignment</summary>

```powershell
# Confirm the Entra-side assignment is actually correct first (rule this out before touching the client)
# Connect-MgGraph -Scopes "User.Read.All"
# Get-MgUserLicenseDetail -UserId <UPN> | Select SkuPartNumber

# On the client: sign out of all Office apps, clear the OneAuth/Office identity cache
Get-Process -Name "OUTLOOK","WINWORD","EXCEL","POWERPNT" -ErrorAction SilentlyContinue | Stop-Process -Force
Remove-Item "$env:LOCALAPPDATA\Microsoft\Office\16.0\OfficeFileCache" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\Microsoft\OneAuth" -Recurse -Force -ErrorAction SilentlyContinue
```
Relaunch an Office app and sign in fresh. This forces a new licensing token pull rather than reusing a stale cached one.

**Rollback:** none needed — cache clear only forces re-authentication, no data loss.

</details>

---
## Escalation Evidence

```
Ticket: Microsoft 365 Apps deployment/update/activation issue
─────────────────────────────────────────────────────────────
User/Device name:            <____________________>
Install type (Click-to-Run/MSI/New Outlook/LTSC): <____________>
Current update channel (UpdateChannel GUID + resolved name): <____________________>
Channel controlled by (GPO/ODT/admin center/default): <____________________>
"Office Automatic Updates 2.0" task state: <____________________>
Version/Build reported (File > Account):  <____________________>
Activation status (OSPP.VBS /dstatus LICENSE STATUS): <____________________>
Shared Computer Activation in use? Y / N
CDN reachable (officecdn.microsoft.com:443)? Y / N
GPO OfficeUpdate registry key present? Y / N — value: <____________________>
```

---
## 🎓 Learning Pointers

- **Update channel and activation/licensing are two entirely separate failure domains** that produce nearly identical user-facing symptoms ("Office is broken," "missing feature," "won't sign in"). Always establish which one you're diagnosing in Step 1 before picking a fix path — most wasted troubleshooting time in this area comes from applying a channel fix to an activation problem or vice versa. [Overview of update channels](https://learn.microsoft.com/en-us/microsoft-365-apps/updates/overview-update-channels)

- **Group Policy always wins over the Office Deployment Tool and the Microsoft 365 admin center's org-wide setting.** If GPO has ever been used to set the update channel — even once, even if later "removed" from active management — check the registry key directly rather than trusting the ODT config file or admin center screen at face value. [Change the Microsoft 365 Apps update channel](https://learn.microsoft.com/en-us/microsoft-365-apps/updates/change-update-channels)

- **Beginning with the July 2026 update (Version 2606), Semi-Annual Enterprise Channel and Monthly Enterprise Channel are unified** — SAC now receives feature and security updates monthly instead of twice yearly, and SAC's support window dropped from 8 months to an effective 3-month window (1 month support + 2 months rollback). No admin action or policy migration is required for this to apply, but any reporting, dashboard, or compliance process that specifically keys off "Semi-Annual Enterprise Channel" as a distinct value may need updating once devices start reporting differently post-update. This is exactly the kind of platform change worth proactively flagging to clients running SAC on regulated or slow-to-test devices. [Upcoming channel unification: SAC to MEC](https://learn.microsoft.com/en-us/microsoft-365-apps/updates/unified-update-channels)

- **Quick Repair should always be tried before Online Repair.** Quick Repair works from local cached files (fast, no re-download, fixes the large majority of corruption issues); Online Repair fully re-downloads and re-validates the Click-to-Run package (slow, requires a stable connection, but resolves deeper corruption Quick Repair can't reach). Jumping straight to Online Repair on a bandwidth-constrained or remote site wastes time and data unnecessarily. [Repair process does not start for Click-to-Run](https://learn.microsoft.com/en-us/troubleshoot/microsoft-365-apps/office-suite-issues/click-to-run-app-repair-process)

- **Shared Computer Activation is an install-time deployment decision, not a runtime toggle** — `SharedComputerLicensing="1"` must be set in the ODT configuration file used for the original install. If a client later needs SCA on a device that wasn't originally deployed with it, that typically means a redeployment via ODT, not a registry tweak. [Troubleshoot shared computer activation](https://learn.microsoft.com/en-us/microsoft-365-apps/licensing-activation/troubleshoot-shared-computer-activation)
