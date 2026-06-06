# Endpoint Privilege Management (EPM) — Hotfix Runbook (Mode B: Ops)
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

Run these first to locate the failure layer.

```powershell
# 1. Check EPM agent (LSMS) service status
Get-Service -Name "LsmsService" -ErrorAction SilentlyContinue

# 2. Check EPM policy file presence on device
$epmPath = "C:\ProgramData\Microsoft\IntuneManagementExtension\Policies\ElevationControl"
Test-Path $epmPath
Get-ChildItem $epmPath -ErrorAction SilentlyContinue | Select-Object Name, LastWriteTime

# 3. Check IME log for EPM policy delivery
Select-String -Path "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log" `
    -Pattern "ElevationControl|EPM|LsmsService" | Select-Object -Last 20

# 4. Check EPM licence — requires Intune Suite or standalone EPM licence
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All"
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "INTUNE_SUITE|EPM" }

# 5. Check elevation rule match for specific application
$epmLog = "C:\ProgramData\Microsoft\EPM\Logs\Microsoft.Management.Elevation.Agent.log"
if (Test-Path $epmLog) { Get-Content $epmLog -Tail 40 }
```

| Result | Action |
|--------|--------|
| `LsmsService` not found / Stopped | → Fix 1: Repair EPM agent |
| EPM path empty / no policy files | → Fix 2: Force Intune sync |
| IME log shows policy assignment error | → Fix 3: Fix policy assignment |
| No `INTUNE_SUITE` or `EPM` SKU | → Fix 4: Assign licence |
| App blocked despite elevation rule | → Fix 5: Fix elevation rule match |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
[Intune Suite licence / standalone EPM licence]
         |
[Entra ID Joined or Hybrid Joined device]
  └─ Intune enrolled
  └─ IME (IntuneManagementExtension) service running
         |
[EPM policy delivered via Intune]
  └─ Elevation Settings policy (enable EPM + default elevation)
  └─ Elevation Rules policy (which apps, which users, elevation type)
  └─ Policies scoped to device/user group
         |
[LsmsService (EPM agent) running on device]
  └─ Policy files present in ElevationControl folder
         |
[User invokes elevation]
  └─ Right-click → "Run with elevated access" OR
  └─ Automatic elevation (configured in rule)
  └─ Support-approved elevation (requires IT approval flow)
```

</details>

---
## Diagnosis & Validation Flow

**1. Confirm EPM agent is installed and running**
```powershell
Get-Service -Name "LsmsService"
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\IntuneWindowsAgent\EPM" -ErrorAction SilentlyContinue
```
Expected: Service `Running`. If absent, EPM component hasn't installed → Fix 1.

**2. Check EPM policy delivery in IME log**
```powershell
$log = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
Select-String -Path $log -Pattern "ElevationControl" | Select-Object -Last 30
```
Expected: Lines showing policy hash received and written. Errors here → Fix 2 or Fix 3.

**3. Validate policy files on disk**
```powershell
$epmPath = "C:\ProgramData\Microsoft\IntuneManagementExtension\Policies\ElevationControl"
Get-ChildItem $epmPath -Recurse | Select-Object FullName, Length, LastWriteTime
```
Expected: JSON policy files present with recent timestamps matching Intune policy assignment.

**4. Review EPM agent log for elevation decisions**
```powershell
$epmLog = "C:\ProgramData\Microsoft\EPM\Logs\Microsoft.Management.Elevation.Agent.log"
Get-Content $epmLog -Tail 50 | Select-String "allow|deny|elevat|rule"
```
Expected: "Elevation allowed — matched rule [RuleName]". If "denied" or "no rule matched" → Fix 5.

**5. Check elevation rule configuration in Intune portal**

Navigate to: Intune → Endpoint Security → Privilege Management → Elevation Rules
- Confirm rule targets the correct app (hash, certificate, or path)
- Confirm rule is assigned to a group containing the affected user/device
- Confirm `Elevation Type` matches expectation (Automatic / User Confirmed / Support Approved)

---
## Common Fix Paths

<details><summary>Fix 1 — Repair or reinstall EPM agent</summary>

Use when: `LsmsService` is missing or won't start.

```powershell
# Check if Intune Management Extension is healthy first
Get-Service -Name "IntuneManagementExtension"
Restart-Service -Name "IntuneManagementExtension" -Force

# Force IME to re-evaluate and re-install EPM component
$imeLog = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
Start-Sleep -Seconds 30
Select-String -Path $imeLog -Pattern "EPM|LsmsService|ElevationControl" | Select-Object -Last 20
```

**If LsmsService still missing after IME restart:**
1. In Intune portal → Devices → select device → Sync
2. Wait 15 minutes and re-check
3. If still absent, check `AppsAndFeatures` for "Microsoft Intune Endpoint Privilege Management" — missing means EPM licence/policy hasn't deployed

**Rollback:** None needed — restarting IME is safe.

</details>

<details><summary>Fix 2 — Force Intune sync to pull EPM policies</summary>

Use when: LsmsService running but no policy files in ElevationControl folder.

```powershell
# Trigger Intune sync via scheduled task
Get-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\*" |
    Where-Object { $_.TaskName -like "*Schedule*" } |
    Start-ScheduledTask

# Or restart IME to force policy check-in
Restart-Service -Name "IntuneManagementExtension" -Force

# Monitor log for policy delivery
$log = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
Get-Content $log -Tail 50 -Wait  # Ctrl+C to stop
```

**From Intune portal:** Devices → [Device Name] → Sync. Also run "Collect diagnostics" to capture current EPM state.

**Rollback:** N/A — sync is non-destructive.

</details>

<details><summary>Fix 3 — Fix EPM policy assignment</summary>

Use when: IME log shows policy received but with scope errors, or policy not assigned to device.

```powershell
Connect-MgGraph -Scopes "DeviceManagementConfiguration.ReadWrite.All","Group.Read.All"

# List EPM policies
Get-MgDeviceManagementIntent | Where-Object { $_.DisplayName -like "*Elevation*" -or $_.DisplayName -like "*EPM*" }

# Check assignments for a specific policy
$policy = Get-MgDeviceManagementConfigurationPolicy | Where-Object { $_.Name -like "*Elevation*" }
Get-MgDeviceManagementConfigurationPolicyAssignment -DeviceManagementConfigurationPolicyId $policy.Id |
    Select-Object Target
```

**In Intune portal:**
1. Endpoint Security → Privilege Management → Elevation Settings / Elevation Rules
2. Verify both policy types are assigned to a group containing the affected device/user
3. EPM requires **two** policies: Elevation Settings (enables EPM) AND Elevation Rules (defines what to elevate)
4. Confirm no exclusion group is accidentally including the affected device

**Rollback:** Remove incorrect group assignments from the portal.

</details>

<details><summary>Fix 4 — Assign EPM / Intune Suite licence</summary>

Use when: No qualifying licence found. EPM requires Microsoft Intune Suite or standalone Microsoft Endpoint Privilege Management add-on.

```powershell
Connect-MgGraph -Scopes "User.ReadWrite.All","Organization.Read.All"

# Find Intune Suite SKU
$sku = Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "INTUNE_SUITE" }
Write-Host "Available: $($sku.PrepaidUnits.Enabled - $sku.ConsumedUnits)"

# Assign to user
Set-MgUserLicense -UserId <UPN> `
    -AddLicenses @{ SkuId = $sku.SkuId } `
    -RemoveLicenses @()
```

**Note:** EPM licence is assigned to the **user**, not the device. All users who need elevation on managed devices require the licence.

</details>

<details><summary>Fix 5 — Fix elevation rule to match application</summary>

Use when: Agent log shows "no rule matched" for an application the user should be able to elevate.

EPM rule matching options (in order of specificity):
1. **File hash** — most secure, breaks on app update
2. **Certificate + file name** — recommended for signed apps
3. **Path** — least secure, avoid for production

```powershell
# Get file hash and certificate info for the target EXE
$filePath = "<PathToExe>"
$hash = Get-FileHash $filePath -Algorithm SHA256
$sig = Get-AuthenticodeSignature $filePath

[PSCustomObject]@{
    FilePath    = $filePath
    SHA256      = $hash.Hash
    Publisher   = $sig.SignerCertificate.Subject
    Issuer      = $sig.SignerCertificate.Issuer
    IsSigned    = $sig.Status
}
```

**In Intune portal:**
1. Endpoint Security → Privilege Management → Elevation Rules → Edit rule
2. Update `File Hash` field with the SHA256 from above
3. Or switch to `Certificate` matching using the Publisher CN from above
4. Save and wait for policy to sync to device (~15 min)

**Rollback:** Previous rule hash can be re-entered. Rules are additive — adding a new hash for a new version doesn't remove the old hash.

</details>

---
## Escalation Evidence

```
EPM ESCALATION
==============
Date/Time              : 
Tenant ID              : 
Device Name            : 
Intune Device ID       : 
User UPN               : 
LsmsService Status     : Running / Stopped / Missing
EPM Licence SKU        : (INTUNE_SUITE / EPM addon / None)
Policy Files Present   : YES / NO
Elevation Rule Name    : 
Application Path       : 
Application Hash       : 
Elevation Type         : Automatic / User Confirmed / Support Approved
Agent Log Errors       : (paste last 20 lines from Elevation.Agent.log)
IME Log Errors         : (paste ElevationControl lines)
Intune Sync Last Run   : 
Steps Already Tried    : 
```

---
## 🎓 Learning Pointers

- **Two policies are mandatory** — EPM will silently do nothing if you only deploy the Elevation Settings policy without an Elevation Rules policy (or vice versa). Both must be assigned and delivered.
- **File hash breaks on every update** — build elevation rules using certificate + filename matching for commercially-signed apps. Reserve file hash for in-house unsigned executables.
- **EPM is user-licensed, not device-licensed** — the licence follows the user account. A shared device needs each interactive user to have the licence.
- **Support-approved elevation creates an audit trail** — for high-risk elevations, use `Support Approved` type. The user gets a one-time code and IT must approve via Intune portal → Privilege Management → Pending Requests.
- **Official docs:** [EPM overview](https://learn.microsoft.com/en-us/mem/intune/protect/epm-overview) | [Configure EPM policies](https://learn.microsoft.com/en-us/mem/intune/protect/epm-policies) | [EPM reports](https://learn.microsoft.com/en-us/mem/intune/protect/epm-reports)
- **Community:** [Intune Tech Community](https://techcommunity.microsoft.com/t5/microsoft-intune/bd-p/Microsoft_Intune)
