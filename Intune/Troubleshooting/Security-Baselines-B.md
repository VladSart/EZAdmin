# Intune Security Baselines — Hotfix Runbook (Mode B: Ops)
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

```powershell
# 1. Check what security baseline policies are assigned to this device
# Run in Graph Explorer or via PowerShell with Microsoft.Graph module
# Replace <deviceId> with the Intune device ID (from Intune portal → Devices → <device> → Properties)
$deviceId = "<IntuneDeviceId>"
Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$deviceId/deviceConfigurationStates" |
    Select-Object -ExpandProperty value |
    Where-Object { $_.displayName -like "*baseline*" -or $_.displayName -like "*security*" } |
    Select-Object displayName, state, errorCount, conflictCount

# 2. Check local policy state on the device (run on device via RMM or PSRemoting)
# Security baselines write to registry — check for evidence of application
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\DeviceGuard" -ErrorAction SilentlyContinue
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\LocalPoliciesSecurityOptions" -ErrorAction SilentlyContinue

# 3. Check MDM diagnostic report for baseline conflicts
Start-Process "ms-settings:workplace"   # open Work or School Account settings
# Or collect MDM report:
MdmDiagnosticsTool.exe -out C:\MDMDiag\
# Then open MDMDiagReport.html → search for "Baseline" or the policy name

# 4. Check Intune sync status
Get-ScheduledTask -TaskName "Schedule*Sync*" | Select-Object TaskName, State
# Run sync manually:
Start-ScheduledTask -TaskName "Schedule #3 created by enrollment client"
```

| Finding | Go to |
|---------|-------|
| Baseline state = "Error" | → [Fix 1: Force re-sync](#fix-1--force-re-sync-and-re-evaluate-baseline) |
| Baseline state = "Conflict" | → [Fix 2: Resolve policy conflict](#fix-2--resolve-security-baseline-conflict) |
| Setting applied but breaks functionality | → [Fix 3: Override a specific setting](#fix-3--override-a-blocking-baseline-setting) |
| Baseline not showing on device at all | → [Fix 4: Check assignment scope](#fix-4--verify-assignment-and-scope) |
| User reports app broken after baseline applied | → [Fix 3](#fix-3--override-a-blocking-baseline-setting) |

---

## Dependency Cascade

<details><summary>What must be true for security baselines to apply</summary>

```
INTUNE PORTAL (Endpoint Security → Security Baselines)
    │
    ├─ Baseline profile assigned to group/device
    │     └─ Device must be in assigned group (Entra group)
    │
    ▼
INTUNE SERVICE
    │  Sends policy to device via MDM channel (DMClient)
    ▼
DEVICE (Enrolled in Intune — Entra joined or Hybrid joined)
    │
    ├─ MDM enrollment active (dsregcmd /status → MDMUrl set)
    ├─ Intune Management Extension (IME) running (for Win32 policies)
    ├─ DMClient service running (OMA-URI delivery)
    │
    ▼
WINDOWS CSP (Configuration Service Provider)
    │  Translates MDM payload to local registry/Group Policy settings
    ▼
LOCAL POLICY APPLIED
    └─ Visible in: Local Security Policy, Registry, MdmDiagReport
```

**Conflict priority (lowest to highest wins):**
```
Group Policy (GPO)  <  MDM CSP  <  Endpoint Security Baseline
```
If a GPO and baseline both target the same setting, the baseline usually wins on MDM-managed devices — but only if `MDMWinsOverGP` is set. Otherwise GPO wins and baseline appears to "conflict".
</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm device MDM enrollment is healthy**
```powershell
# Run on the target device
dsregcmd /status | Select-String "MDMUrl|MdmEnrollmentUrl|IsCompliant|WamDefaultSet"
# Expected: MDMUrl and MdmEnrollmentUrl populated; IsCompliant = YES
```
If MDMUrl is blank → device not enrolled or enrollment broken. Re-enroll.

**Step 2 — Pull MDM diagnostic report**
```powershell
# Run on device — generates HTML report
$outDir = "C:\Temp\MDMDiag"
New-Item $outDir -ItemType Directory -Force | Out-Null
MdmDiagnosticsTool.exe -out $outDir
Start-Process "$outDir\MDMDiagReport.html"
```
In the report, search for:
- `SecurityBaseline` or the baseline name
- Settings showing `Error` or `Conflict` states
- CSP errors (numeric error codes)

**Step 3 — Check for GPO/MDM conflict**
```powershell
# Detect if MDM-wins-over-GP is configured
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceManagement" -ErrorAction SilentlyContinue |
    Select-Object MDMWinsOverGP
# 1 = MDM wins (correct for Intune-managed devices)
# 0 or absent = GPO wins where there's a conflict
```

**Step 4 — Identify which baseline setting is causing an issue**
```powershell
# Run on device — lists all MDM-applied policies and their current values
Get-ChildItem "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device" -ErrorAction SilentlyContinue |
    ForEach-Object {
        Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    } | Select-Object PSChildName, * -ExcludeProperty PS* | Format-List
```
Compare against the expected values for the baseline version in use (documented in Intune portal under the baseline profile → settings view).

**Step 5 — Check Intune device status in portal**
```
Intune Portal → Devices → [Device] → Device configuration
→ Find the baseline profile → Click → View per-setting status
→ Look for red/orange rows — these are erroring or conflicting settings
```

---

## Common Fix Paths

<details><summary>Fix 1 — Force re-sync and re-evaluate baseline</summary>

```powershell
# Run on the target device (local or via PSRemoting/RMM)

# Method 1: Trigger MDM sync via scheduled task
Get-ScheduledTask | Where-Object { $_.TaskName -like "*DMClient*" -or $_.TaskName -like "*enrollment*" } |
    ForEach-Object { Start-ScheduledTask -TaskName $_.TaskName -ErrorAction SilentlyContinue }

# Method 2: Sync via Settings app (trigger via PowerShell)
Start-Process "ms-settings:workplace"

# Method 3: Restart DMClient service (more aggressive)
Restart-Service dmwappushservice -Force
Restart-Service DiagTrack -Force -ErrorAction SilentlyContinue

# Wait 5 minutes then re-check policy state
Start-Sleep -Seconds 300
MdmDiagnosticsTool.exe -out C:\Temp\MDMDiag2
```
After sync, re-check the device in Intune portal — status usually updates within 10-15 minutes.
</details>

<details><summary>Fix 2 — Resolve security baseline conflict</summary>

**Most common cause:** A GPO is setting the same value as the baseline, causing a "conflict" state in Intune (even if the actual value is correct).

```powershell
# Step 1: Enable MDM wins over GP (if appropriate for this device's management model)
# WARNING: Only do this on devices that should be fully MDM-managed (not co-managed with SCCM)
$regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceManagement"
New-Item $regPath -Force | Out-Null
Set-ItemProperty -Path $regPath -Name "MDMWinsOverGP" -Value 1 -Type DWord
Write-Host "MDM will now take precedence over GPO for conflicting settings." -ForegroundColor Green
```

**If you can't use MDMWinsOverGP (co-managed device):**
1. In Group Policy, set the conflicting settings to **Not Configured** (instead of Enabled/Disabled).
2. Or, exclude the conflicting settings from the baseline profile in Intune (create a custom profile variant without those specific settings).
3. In Intune, use the "Conflict" filter to identify exactly which settings conflict.

**Rollback:** `Remove-ItemProperty -Path $regPath -Name "MDMWinsOverGP"`
</details>

<details><summary>Fix 3 — Override a blocking baseline setting</summary>

When a specific baseline setting breaks an application or workflow (e.g., "Block all Office macros" breaks a legacy line-of-business app), you can override it with a higher-priority Configuration Profile.

```powershell
# Identify the exact registry key the baseline is setting
# Example: Windows Security Baseline blocks SMB1
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\mrxsmb10" -Name Start -ErrorAction SilentlyContinue
# Start=4 (Disabled) means baseline applied the SMB1 block

# To override via Intune: create a Settings Catalog profile targeting the same setting
# with the required value, assigned to the same device/group.
# Settings Catalog profiles take effect after Endpoint Security Baselines in Intune's
# conflict resolution order when set with higher priority via assignment groups.
```

**Recommended approach in Intune portal:**
1. Go to **Devices → Configuration profiles → Create profile**
2. Platform: Windows 10 and later | Profile type: Settings catalog
3. Add the specific setting that the baseline is blocking
4. Set the value your application requires
5. Assign to a scope group that includes the affected devices
6. Use assignment filters if only certain devices/users need the exception

**Document every override with a change ticket** — baseline exceptions accumulate and create audit findings.
</details>

<details><summary>Fix 4 — Verify assignment and scope</summary>

```powershell
# Via MS Graph — check which groups the baseline is assigned to
# Run in Graph Explorer with DeviceManagementConfiguration.Read.All

# Get all security baseline profiles
Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/beta/deviceManagement/intents" |
    Select-Object -ExpandProperty value |
    Where-Object { $_.isAssigned -eq $true } |
    Select-Object displayName, id, templateId

# For a specific baseline, check its assignments
$baselineId = "<BaselineProfileId>"
Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/beta/deviceManagement/intents/$baselineId/assignments" |
    Select-Object -ExpandProperty value |
    Select-Object id, @{N='Target';E={$_.target.'@odata.type'}}, @{N='GroupId';E={$_.target.groupId}}
```

Common issues:
- Device is **excluded** from the assigned group (check exclusion assignments)
- Device is in the group but **not yet synced** — Entra group membership can take 5-15 minutes to propagate
- Baseline assigned to **user group** but device compliance check looks at **device groups**
- Assignment filter is excluding the device (`dsregcmd /status` → check AzureAdJoined, Hostname matches filter rules)
</details>

---

## Escalation Evidence

```
TICKET ESCALATION — INTUNE SECURITY BASELINE ISSUE
===================================================
Date/Time:              ___________________
Affected Device(s):     ___________________
Intune Device ID:       ___________________
Baseline Profile Name:  ___________________
Baseline Version:       ___________________

SYMPTOM:
[ ] Baseline not applying (device shows no baseline assignment)
[ ] Baseline state = Error
[ ] Baseline state = Conflict
[ ] Baseline applied but breaking functionality — describe: ___________________

TRIAGE RESULTS:
MDM enrollment healthy (dsregcmd):  [ ] Yes  [ ] No
DMClient service running:            [ ] Yes  [ ] No
MDMWinsOverGP set:                   [ ] Yes  [ ] No  [ ] N/A
GPO conflict detected:               [ ] Yes  [ ] No

CONFLICTING SETTINGS (from MDMDiagReport or Intune portal):
___________________________________________

MDM DIAG REPORT: [ ] Attached (MDMDiagReport.html)
INTUNE PORTAL SCREENSHOT OF SETTING ERRORS: [ ] Attached

FIXES ATTEMPTED:
___________________________________________
```

---

## 🎓 Learning Pointers

- **Baseline versions matter:** Microsoft releases new versions of security baselines (e.g., "Windows 10/11 Security Baseline — November 2023"). Older versions remain supported but don't get new settings. When a new OS version ships, import the new baseline and migrate devices incrementally to avoid mass policy change events. [Intune security baselines](https://learn.microsoft.com/en-us/mem/intune/protect/security-baselines)
- **Conflict ≠ Error:** A "Conflict" in Intune means two policies are fighting for the same setting (often baseline vs. GPO). An "Error" means the CSP returned a failure code (incompatible OS version, missing dependency, or CSP not supported on that Windows SKU). Treat them differently.
- **MDMWinsOverGP risk:** Setting MDM to win over GP is the right call for pure Intune-managed devices but breaks co-management scenarios where SCCM and Intune share workloads. Always confirm the device's co-management status before enabling this. [MDMWinsOverGP](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-controlpolicyconflict)
- **Audit baseline exceptions:** Every time you override a baseline setting, you're creating a deviation from your security posture. Use Intune's **Endpoint Security → Security Baselines → [Profile] → Device Status** view to track which devices have non-compliant settings and review quarterly. [Intune baseline monitoring](https://learn.microsoft.com/en-us/mem/intune/protect/security-baselines-monitor)
- **Windows LAPS and baselines:** The Microsoft Security Baseline for Windows 11 23H2+ includes LAPS settings. If you've deployed LAPS via a separate Intune policy, you may hit conflicts. Consolidate LAPS configuration into the baseline or explicitly exclude LAPS settings from one of the profiles.
