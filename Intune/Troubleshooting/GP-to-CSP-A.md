# Group Policy to CSP Migration — Reference Runbook (Mode A: Deep Dive)
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

**In scope:**
- Migration of Group Policy Objects (GPOs) to Intune Configuration Service Provider (CSP) settings
- Group Policy Analytics tool in Intune
- OMA-URI custom profiles and Settings Catalog
- Policy conflict resolution between GPO and MDM
- Devices in Co-Management and cloud-native (Azure AD Joined / Intune-enrolled) scenarios

**Out of scope:**
- Group Policy Preferences (GPP) migration (different tooling: logon scripts → Intune remediation scripts)
- On-premises Active Directory GPO administration
- Third-party MDM CSP equivalents

**Assumptions:**
- Devices are Azure AD Joined or Hybrid Azure AD Joined with Intune enrollment
- Admin has Intune Administrator role
- Source GPOs accessible from a domain-joined machine for analysis

---

## How It Works

<details><summary>Full architecture — GPO vs CSP policy delivery</summary>

### Group Policy Architecture (Legacy)
```
Domain Controller
    └── SYSVOL share (GPO files)
        └── Group Policy Client (gpsvc)
            └── Registry (HKLM\Software\Policies, HKCU\Software\Policies)
                └── Applications / Windows features
```
- GPO delivery requires **line-of-sight to domain controller**
- Settings applied at machine startup (Computer GPO) or user login (User GPO)
- Result-of-set computed by **GPRESULT** / RSOP

### CSP / MDM Architecture (Modern)
```
Intune (Microsoft Endpoint Manager)
    └── OMA-DM protocol (over HTTPS)
        └── Windows MDM Agent (DmClient / EnrollmentService)
            └── CSP tree (./Device/Vendor/MSFT/... or ./User/...)
                └── Registry / Windows APIs / WMI
                    └── Applications / Windows features
```
- CSP delivery requires only **internet connectivity** — no domain line-of-sight
- Settings delivered via **DM session** (every 8 hours by default, or triggered via sync)
- Result-of-set visible in: Intune Device Configuration reports, MDM Diagnostics (`mdmdiagnosticstool.exe`)

### The CSP Tree
Every MDM setting maps to a **URI in the CSP tree**:
```
./Device/Vendor/MSFT/Policy/Config/<Area>/<PolicyName>
./User/Vendor/MSFT/Policy/Config/<Area>/<PolicyName>
```
Example:
- GPO: `Computer Config → Windows Settings → Security Settings → Account Policies → Password Policy → Minimum password length = 14`
- CSP: `./Device/Vendor/MSFT/Policy/Config/DeviceLock/MinDevicePasswordLength` = `14`

### Policy Conflict: GPO vs CSP (MDM wins on AADJ, GPO wins on HAADJ by default)
```
Azure AD Joined (cloud-native):
    MDM (Intune CSP) wins for all supported settings
    GPO has NO effect (no domain controller reachable for AADJ-only devices)

Hybrid Azure AD Joined (Co-Managed):
    Default: GPO wins
    Override: Enable "MDM Wins over GPO" in Co-Management workload settings
    OR use: ControlPolicyConflict CSP → MDMWinsOverGP = 1
```

### GPO Analytics Tool — How It Works
The Intune **Group Policy Analytics** feature:
1. Admin exports GPO as XML from GPMC: `Backup-GPO` or right-click → Save Report
2. Admin uploads XML to: Intune → Devices → Group Policy Analytics
3. Tool parses each GPO setting, maps to CSP equivalent
4. Output: **Supported** (direct CSP mapping exists), **Deprecated** (no CSP equivalent), **Not supported** (no MDM equivalent)

**Coverage gap:** Approximately 25–40% of GPO settings have no direct CSP equivalent as of 2026. These require alternative approaches: Remediation scripts, compliance policies, or acceptance that the setting is not manageable via Intune.

### Settings Catalog vs. OMA-URI
| Method | When to use | Format |
|--------|-------------|--------|
| **Settings Catalog** | Setting exists in catalog (most modern settings) | GUI-based, named settings |
| **Custom OMA-URI** | Setting not in catalog; has known CSP URI | URI + data type + value |
| **ADMX Ingestion** | Setting uses ADMX-backed policy (e.g., Chrome, Firefox) | Upload ADMX + ADML, then configure |
| **Remediation Script** | No CSP equivalent; registry-level configuration | PowerShell detect + remediate |

</details>

---

## Dependency Stack

```
Source Environment
    └── Active Directory Domain Controller
        └── SYSVOL / GPOs (exported via GPMC as XML)
            └── Group Policy Analytics (Intune import)
                └── CSP Mapping Engine
                    ├── Supported → Settings Catalog / OMA-URI
                    ├── Deprecated → Alternative approach needed
                    └── Not supported → Remediation Scripts / Accept gap

Target Environment
    └── Microsoft Intune
        ├── Configuration Profiles
        │   ├── Settings Catalog (GUI — recommended)
        │   ├── Custom (OMA-URI — advanced)
        │   └── ADMX Templates (for non-MSFT ADMX)
        ├── Compliance Policies (enforce, not configure)
        ├── Remediation Scripts (detect + fix via PowerShell)
        └── MDM Agent (DmClient on device)
            └── Requires: Intune enrollment + AAD Join / HAADJ
                Device must reach: manage.microsoft.com, dm.microsoft.com

Co-Management (HAADJ):
    └── SCCM / ConfigMgr (existing)
        └── Intune (MDM authority for selected workloads)
            └── Workload slider: Compliance / Device Config / Windows Update
            └── MDMWinsOverGP CSP (device-level override)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| GPO setting not applying after migration | Device still receiving GPO via HAADJ domain link | `gpresult /r`; check if MDMWinsOverGP enabled |
| CSP setting not applying | Profile not assigned to device/user group; enrollment not complete | Intune device compliance report; check profile assignment |
| Settings conflict — Intune wins sometimes, GPO other times | HAADJ without MDMWinsOverGP; workload not moved in Co-Mgmt | Co-Management workload settings; `MDMWinsOverGP` registry |
| OMA-URI shows "Error" status in Intune | Incorrect URI format; unsupported CSP on OS version; wrong data type | Verify URI from docs.microsoft.com; check OS version requirements |
| Settings Catalog item missing | Not all GPO settings have a catalog equivalent | Use Group Policy Analytics to identify coverage |
| Device shows "Not applicable" for profile | Profile scoped to wrong OS version or enrollment type | Check profile OS filter and assignment filter |
| ADMX-backed policy not available in catalog | ADMX not ingested; wrong ADMX version | Ingest ADMX via Intune custom ADMX feature |
| User setting not applying | Profile uses Device scope, not User scope; or vice versa | Check CSP `./User/` vs `./Device/` path |
| "MDM Enrollment not found" | Device not enrolled in Intune; MDM discovery URL wrong | `dsregcmd /status`; check MDM enrollment |
| Setting reverts after reboot | GPO still linked and overriding CSP | OU GPO link; `gpresult /h`; check block inheritance |

---

## Validation Steps

**1. Confirm device enrollment status**
```powershell
# On device:
dsregcmd /status
# Look for:
#   AzureAdJoined: YES
#   MDMUrl: https://enrollment.manage.microsoft.com/...
#   MDMEnrolled: YES
```

**2. Check Group Policy Analytics status in Intune**
```
Intune → Devices → Group Policy Analytics
→ Click on imported GPO
→ Review: Supported %, Not Supported %, MDM Support column per setting
```

**3. Verify MDM diagnostic log on device**
```powershell
# Generate MDM diagnostic report:
$outPath = "C:\Temp\MDMDiag"
New-Item -ItemType Directory -Path $outPath -Force
MdmDiagnosticsTool.exe -out $outPath
# Open: C:\Temp\MDMDiag\MDMDiagReport.html
# Check: Applied Policies, Unapplied Policies, Error codes
```

**4. Check MDMWinsOverGP status (HAADJ devices)**
```powershell
# On device:
$key = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\MDM"
if (Test-Path $key) {
    Get-ItemProperty $key | Select-Object ControlPolicyConflict
    # ControlPolicyConflict = 1 means MDM wins
} else {
    Write-Host "MDMWinsOverGP not configured — GPO wins by default"
}
```

**5. Verify OMA-URI profile delivery in Intune**
```powershell
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All"
# Get device configuration profiles:
Get-MgDeviceManagementDeviceConfiguration | Select-Object DisplayName, Id, OdataType
# Get profile assignment status for specific device:
# Via Intune portal: Device → Configuration profiles → view per-device status
```

**6. Test GPO still applying on HAADJ device**
```powershell
# On device (run as admin):
gpresult /r /scope computer
# If GPO settings appear here AND in Intune, there's a conflict
gpresult /h C:\Temp\GPresult.html; Start-Process C:\Temp\GPresult.html
```

**7. Verify CSP setting is written to registry**
```powershell
# Most CSP settings write to:
# HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\<Area>\<Policy>
# OR the traditional policy path:
# HKLM:\SOFTWARE\Policies\<vendor>\<app>

# Example — check BitLocker CSP:
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\BitLocker"

# Compare with GPO path:
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\FVE"
```

---

## Troubleshooting Steps (by phase)

### Phase 1: GPO Analysis and Export

**1a. Export GPO for upload to Group Policy Analytics**
```powershell
# On domain-joined machine with GPMC:
Import-Module GroupPolicy

# Export all GPOs in domain:
$domain = (Get-ADDomain).DNSRoot
$gpos   = Get-GPO -All -Domain $domain

foreach ($gpo in $gpos) {
    $xml = Get-GPOReport -Guid $gpo.Id -ReportType Xml -Domain $domain
    $safeName = $gpo.DisplayName -replace '[\\/:*?"<>|]', '_'
    $xml | Out-File "C:\Temp\GPOExport\$safeName.xml" -Encoding utf8
}

Write-Host "Exported $($gpos.Count) GPOs to C:\Temp\GPOExport"
```

**1b. Identify settings with no CSP equivalent**
```powershell
# After uploading to Group Policy Analytics:
# Intune → Devices → Group Policy Analytics → select GPO → export report to CSV
# Filter CSV for: MDM Support = "Not supported" or "Deprecated"
# These need alternative handling (Remediation scripts, Compliance, or documented gaps)
```

### Phase 2: Building Settings Catalog Profiles

**2a. Map common GPO areas to Settings Catalog**

| GPO Area | Settings Catalog Area |
|----------|-----------------------|
| Computer Config → Security Settings → Account Policies | Device Lock |
| Computer Config → Administrative Templates → Windows Components → Windows Update | Windows Update for Business |
| Computer Config → Administrative Templates → System → Logon | Authentication / Credential providers |
| Computer Config → Administrative Templates → Network → DNS | Network / DNS |
| User Config → Administrative Templates → Windows Components → File Explorer | Windows Components |

**2b. Create profile from Settings Catalog**
```
Intune → Devices → Configuration → Create → New Policy
→ Platform: Windows 10 and later
→ Profile type: Settings Catalog
→ Add settings → search for the setting name
→ Configure value → Assign to device group → Create
```

### Phase 3: Custom OMA-URI for Missing Settings

**3a. Find the CSP URI**
- Search: `docs.microsoft.com/en-us/windows/client-management/mdm/`
- Or use: [GPMC to MDM mapping tool](https://docs.microsoft.com/en-us/windows/client-management/mdm/policy-configuration-service-provider)
- Or: Group Policy Analytics → click supported setting → "MDM URI" column

**3b. Create custom OMA-URI profile**
```powershell
# Example — enable SMB signing via OMA-URI (not in Settings Catalog as of 2026):
# URI: ./Device/Vendor/MSFT/Policy/Config/MSSLegacy/AllowICMPRedirectsToOverrideOSPFGeneratedRoutes
# Data type: Integer
# Value: 0

# Via PowerShell (Graph API):
Connect-MgGraph -Scopes "DeviceManagementConfiguration.ReadWrite.All"
$profile = @{
    "@odata.type"  = "#microsoft.graph.windows10CustomConfiguration"
    displayName    = "Custom OMA-URI - SMB Signing"
    omaSettings    = @(
        @{
            "@odata.type" = "#microsoft.graph.omaSettingInteger"
            displayName   = "Enable SMB Signing"
            omaUri        = "./Device/Vendor/MSFT/Policy/Config/MSSLegacy/AllowICMPRedirectsToOverrideOSPFGeneratedRoutes"
            value         = 0
        }
    )
}
Invoke-MgGraphRequest -Method POST `
    -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations" `
    -Body ($profile | ConvertTo-Json -Depth 5)
```

**3c. Validate OMA-URI after deployment**
```powershell
# On device — check MDM policy applied:
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\<Area>" |
    Select-Object <PolicyName>
```

### Phase 4: Enabling MDM Wins Over GPO

**4a. Via Co-Management workload (recommended for co-managed)**
```
Intune → Devices → Co-management → select collection → Workloads
→ Device Configuration: Pilot Intune (or Intune)
→ This moves the workload; Intune profiles now take precedence
```

**4b. Via CSP (individual device or all enrolled)**
```powershell
# Via Intune custom OMA-URI profile:
# OMA-URI: ./Device/Vendor/MSFT/Policy/Config/ControlPolicyConflict/MDMWinsOverGP
# Data type: Integer
# Value: 1

# Verify on device after policy applies:
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\MDM" |
    Select-Object ControlPolicyConflict
# 1 = MDM wins
```

**4c. Staged rollout — pilot group approach**
```
1. Create AAD group: "Pilot-MDM-Wins"
2. Assign OMA-URI profile (MDMWinsOverGP = 1) to Pilot group
3. Add 10–20 test devices
4. Monitor in Intune: Device → Configuration → per-device status
5. Check MDM Diagnostic logs on pilot devices
6. Expand group after validation
```

### Phase 5: ADMX-Backed Policies (Third-Party Apps)

**5a. Ingest ADMX files**
```
Intune → Devices → Configuration → Import ADMX
→ Upload ADMX file (e.g., googlechrome.admx)
→ Upload ADML file (language file)
→ Wait for processing (~15 minutes)
→ Then available in Settings Catalog under "Imported Administrative Templates"
```

**5b. Configure ADMX-backed setting**
```
Settings Catalog → search for imported ADMX setting name
→ Configure value as per ADMX documentation
```

---

## Remediation Playbooks

<details><summary>Playbook 1 — Full GPO-to-CSP migration for a workload</summary>

**Scenario:** Migrating Windows Update GPO settings to Intune Windows Update for Business

```powershell
# Step 1: Export existing GPO
Import-Module GroupPolicy
$gpoName = "<GPOName>"
Get-GPOReport -Name $gpoName -ReportType Xml | Out-File "C:\Temp\$gpoName.xml"

# Step 2: Upload to Group Policy Analytics in Intune (manual via portal)
# Intune → Devices → Group Policy Analytics → Import

# Step 3: Create Windows Update ring in Intune (via portal or PowerShell)
Connect-MgGraph -Scopes "DeviceManagementConfiguration.ReadWrite.All"
$updateRing = @{
    "@odata.type"                             = "#microsoft.graph.windowsUpdateForBusinessConfiguration"
    displayName                               = "WUfB - Production Ring"
    businessReadyUpdatesOnly                  = "businessReadyOnly"
    microsoftUpdateServiceAllowed             = $true
    driversExcluded                           = $false
    qualityUpdatesDeferralPeriodInDays        = 7
    featureUpdatesDeferralPeriodInDays        = 30
    featureUpdatesRollbackWindowInDays        = 10
    automaticUpdateMode                       = "autoInstallAndRebootWithoutEndUserControl"
    installationSchedule                      = @{
        "@odata.type"         = "#microsoft.graph.windowsUpdateScheduledInstall"
        scheduledInstallDay   = "wednesday"
        scheduledInstallTime  = "3:00:00.0000000"
    }
}
Invoke-MgGraphRequest -Method POST `
    -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations" `
    -Body ($updateRing | ConvertTo-Json -Depth 5)

# Step 4: Assign to device group
# Step 5: Remove or unlink the original GPO from OU (after validation)
# Step 6: Monitor compliance in Intune → Devices → Monitor → Device configuration
```

</details>

<details><summary>Playbook 2 — Handle "Not Supported" GPO settings via Remediation Script</summary>

**Scenario:** GPO sets a registry value with no CSP equivalent

```powershell
# DETECTION script (runs on schedule — 15 min to hourly):
$regPath  = "HKLM:\SOFTWARE\<Vendor>\<App>"
$regName  = "<SettingName>"
$expected = "<ExpectedValue>"

try {
    $current = (Get-ItemProperty -Path $regPath -Name $regName -ErrorAction Stop).$regName
    if ($current -eq $expected) {
        Write-Host "Compliant"
        exit 0  # Compliant — no remediation needed
    } else {
        Write-Host "Non-compliant: $current (expected $expected)"
        exit 1  # Non-compliant — trigger remediation
    }
} catch {
    Write-Host "Key missing — non-compliant"
    exit 1
}

# REMEDIATION script:
$regPath  = "HKLM:\SOFTWARE\<Vendor>\<App>"
$regName  = "<SettingName>"
$value    = "<ExpectedValue>"
$type     = "String"  # String, DWORD, QWORD, MultiString, ExpandString, Binary

try {
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    Set-ItemProperty -Path $regPath -Name $regName -Value $value -Type $type
    Write-Host "Remediated: $regPath\$regName = $value"
    exit 0
} catch {
    Write-Host "ERROR: $_"
    exit 1
}
```

**Deployment:**
```
Intune → Devices → Remediations → Create
→ Upload Detection script
→ Upload Remediation script
→ Run as: System (for HKLM) or User (for HKCU)
→ Schedule: Every hour (or Daily)
→ Assign to device group
```

</details>

<details><summary>Playbook 3 — Verify full migration health for a device</summary>

```powershell
# Run on migrated device to compare GPO vs CSP coverage
param(
    [string]$OutputPath = "C:\Temp\GPtoCSpReport.html"
)

$html = @"
<html><head><title>GP-to-CSP Migration Report</title>
<style>body{font-family:Consolas,monospace;margin:20px}
table{border-collapse:collapse;width:100%}
th,td{border:1px solid #ccc;padding:8px;text-align:left}
th{background:#003366;color:white}
.ok{color:green;font-weight:bold} .warn{color:orange;font-weight:bold} .error{color:red;font-weight:bold}
</style></head><body>
<h1>GP-to-CSP Migration Health Report</h1>
<h2>Device: $env:COMPUTERNAME — $(Get-Date)</h2>
"@

# MDM enrollment status
$dsreg = dsregcmd /status
$aadJoined   = ($dsreg | Select-String "AzureAdJoined\s*:\s*(\w+)").Matches[0].Groups[1].Value
$mdmEnrolled = ($dsreg | Select-String "MDMEnrolled\s*:\s*(\w+)").Matches[0].Groups[1].Value
$mdmUrl      = ($dsreg | Select-String "MDMUrl\s*:\s*(.+)").Matches[0].Groups[1].Value

$html += "<h3>Enrollment Status</h3><table>"
$html += "<tr><th>Property</th><th>Value</th><th>Status</th></tr>"
$html += "<tr><td>AzureAdJoined</td><td>$aadJoined</td><td class='$(if($aadJoined -eq "YES"){"ok"}else{"error"})'>$(if($aadJoined -eq "YES"){"✓"}else{"✗"})</td></tr>"
$html += "<tr><td>MDMEnrolled</td><td>$mdmEnrolled</td><td class='$(if($mdmEnrolled -eq "YES"){"ok"}else{"error"})'>$(if($mdmEnrolled -eq "YES"){"✓"}else{"✗"})</td></tr>"
$html += "<tr><td>MDM URL</td><td>$mdmUrl</td><td></td></tr>"

# MDMWinsOverGP
$mdmWins = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\MDM" -ErrorAction SilentlyContinue).ControlPolicyConflict
$html += "<tr><td>MDMWinsOverGP</td><td>$(if($mdmWins -eq 1){"Enabled (1)"}else{"Disabled/Not set"})</td><td class='$(if($mdmWins -eq 1){"ok"}else{"warn"})'>$(if($mdmWins -eq 1){"✓"}else{"⚠"})</td></tr>"
$html += "</table>"

# GPO result summary
$html += "<h3>Active GPO Count</h3><table><tr><th>Scope</th><th>Count</th></tr>"
try {
    $gpoResult = gpresult /r 2>&1
    $computerGPOs = ($gpoResult | Select-String "Applied GPOs" -A 20 | Select-String "^\s{4}\S").Count
    $html += "<tr><td>Computer GPOs Applied</td><td>$computerGPOs</td></tr>"
} catch {
    $html += "<tr><td colspan='2'>gpresult unavailable (may be AADJ-only device)</td></tr>"
}
$html += "</table>"

$html += "</body></html>"
$html | Out-File $OutputPath -Encoding utf8
Write-Host "[OK] Report saved to $OutputPath" -ForegroundColor Green
Start-Process $OutputPath
```

</details>

---

## Evidence Pack

```powershell
<#
  EZAdmin — GP-to-CSP Migration Evidence Collector
  Collects MDM enrollment state, active GPOs, and CSP policy registry keys
  Run as Administrator on the affected device
#>

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outDir    = "C:\Temp\GPCSPEvidence-$timestamp"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

# 1. dsregcmd full output
dsregcmd /status | Out-File "$outDir\dsregcmd.txt"

# 2. MDM Diagnostics
MdmDiagnosticsTool.exe -out "$outDir\MDMDiag" 2>&1 | Out-Null

# 3. GPResult (HTML)
try {
    gpresult /h "$outDir\gpresult.html" /f
} catch {
    "gpresult not available (likely AADJ-only)" | Out-File "$outDir\gpresult-error.txt"
}

# 4. CSP policy registry dump
$mdmPolicies = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device"
if (Test-Path $mdmPolicies) {
    Get-ChildItem $mdmPolicies -Recurse | ForEach-Object {
        [PSCustomObject]@{
            Path  = $_.PSPath
            Name  = $_.PSChildName
            Value = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue)
        }
    } | Export-Csv "$outDir\MDMPolicies.csv" -NoTypeInformation
}

# 5. MDMWinsOverGP state
$mdmWinsKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\MDM"
if (Test-Path $mdmWinsKey) {
    Get-ItemProperty $mdmWinsKey | Export-Csv "$outDir\MDMWinsOverGP.csv" -NoTypeInformation
} else {
    "MDMWinsOverGP registry key not present" | Out-File "$outDir\MDMWinsOverGP.txt"
}

# 6. Enrollment info
Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Enrollments" -ErrorAction SilentlyContinue |
    Get-ItemProperty | Export-Csv "$outDir\EnrollmentInfo.csv" -NoTypeInformation

# 7. Event log — MDM Diagnostics
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" `
    -MaxEvents 100 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Export-Csv "$outDir\MDMEventLog.csv" -NoTypeInformation

# 8. Compress and report
Compress-Archive -Path $outDir -DestinationPath "$outDir.zip" -Force
Write-Host "[OK] Evidence collected: $outDir.zip" -ForegroundColor Green
Write-Host "[INFO] Upload to Intune support ticket or share with engineering team" -ForegroundColor Cyan
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check enrollment status | `dsregcmd /status` |
| Check MDMWinsOverGP | `Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\MDM"` |
| Run MDM diagnostics | `MdmDiagnosticsTool.exe -out C:\Temp\MDMDiag` |
| Force Intune sync | `Start-Process "ms-device-enrollment://enrollment"` OR Intune portal sync |
| Check applied GPOs | `gpresult /r` |
| Get GPO HTML report | `gpresult /h C:\Temp\gpresult.html /f` |
| Export GPO to XML | `Get-GPOReport -Name <Name> -ReportType Xml \| Out-File C:\Temp\gpo.xml` |
| Check CSP policy keys | `Get-ChildItem "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device" -Recurse` |
| Enable MDMWinsOverGP (via CSP) | OMA-URI: `./Device/Vendor/MSFT/Policy/Config/ControlPolicyConflict/MDMWinsOverGP` = `1` |
| List Intune config profiles | `Get-MgDeviceManagementDeviceConfiguration \| Select DisplayName, Id` |
| Import GPO to Group Policy Analytics | Intune portal → Devices → Group Policy Analytics → Import |
| List all enrolled devices | `Get-MgDeviceManagementManagedDevice \| Select DeviceName, EnrollmentType, ComplianceState` |

---

## 🎓 Learning Pointers

- **Not every GPO setting has a CSP equivalent — and that's permanent:** As of 2026, approximately 25–40% of typical enterprise GPO settings have no direct MDM/CSP equivalent. The Group Policy Analytics tool will flag these. For each gap, the options are: (1) use a Remediation script to enforce via registry, (2) accept the gap and compensate elsewhere (compliance policy, monitoring), or (3) raise a UserVoice request. Don't block a migration waiting for perfect parity. [GP Analytics documentation](https://learn.microsoft.com/en-us/mem/intune/configuration/group-policy-analytics)

- **MDMWinsOverGP is not set automatically on HAADJ:** Hybrid Azure AD Joined devices receive both GPO (via domain) and CSP (via Intune). By default, **GPO wins** for any conflicting setting. The `MDMWinsOverGP` CSP must be explicitly enabled or the Co-Management workload moved to Intune. Many MSP engineers assume Intune is authoritative and spend hours debugging policies that GPO is silently overwriting. [MDMWinsOverGP CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-controlpolicyconflict)

- **Settings Catalog is the right home for new settings:** OMA-URI custom profiles work but are fragile (a typo in the URI silently fails). The Settings Catalog is the modern, validated way to configure settings — Microsoft continuously expands it. Always check the catalog first before reaching for OMA-URI. [Settings Catalog overview](https://learn.microsoft.com/en-us/mem/intune/configuration/settings-catalog)

- **ADMX ingestion enables third-party app management:** Chrome, Firefox, Adobe, Zoom, and many enterprise apps ship ADMX templates. Intune supports importing these ADMX files, making the settings available in Settings Catalog under "Imported Administrative Templates". This replaces complex OMA-URI strings and is far more maintainable. [ADMX-backed policies in Intune](https://learn.microsoft.com/en-us/mem/intune/configuration/administrative-templates-import-custom)

- **The MDM Diagnostics report is your best on-device debugging tool:** `MdmDiagnosticsTool.exe -out <path>` generates a comprehensive HTML report showing every policy the MDM agent received, its current state, any errors, and the CSP URI. It's the equivalent of `gpresult /h` for MDM. Always pull this before escalating a CSP non-application issue. [MDM Diagnostics](https://learn.microsoft.com/en-us/windows/client-management/mdm/diagnose-mdm-failures-in-windows-10)

- **Migration is a phased workload — don't boil the ocean:** Migrate workloads one at a time (Windows Update → Security Baseline → App Config → etc.) using Co-Management workload sliders or assignment filters. Validate each workload on a pilot group before expanding. A big-bang GPO cutover on co-managed devices is a common cause of mass policy regressions. [Co-Management workloads](https://learn.microsoft.com/en-us/mem/configmgr/comanage/workloads)
