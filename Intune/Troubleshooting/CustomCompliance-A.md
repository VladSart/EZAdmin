# Intune Custom Compliance Scripts — Reference Runbook (Mode A: Deep Dive)
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

**Covers:**
- Intune Custom Compliance discovery scripts (Windows 10/11)
- Script authoring, JSON output requirements, and common pitfalls
- Compliance rule configuration and key name matching
- IME (Intune Management Extension) lifecycle and logging
- Conditional Access integration and compliance state propagation
- Remediation scripts as a companion to custom compliance
- Compliance policy assignment and group targeting

**Assumes:**
- Intune P1 or above (custom compliance requires Intune Plan 1+)
- Windows 10 20H2 or later (custom compliance not available on earlier builds)
- Microsoft Graph PowerShell SDK installed: `Install-Module Microsoft.Graph`
- Admin roles: Intune Administrator or Policy and Profile Manager

**Out of scope:**
- macOS custom compliance (not currently supported — only built-in settings)
- iOS/Android custom compliance
- Non-Windows platform scripting

---

## How It Works

<details><summary>Full architecture</summary>

Intune Custom Compliance extends the standard compliance framework by allowing a PowerShell script (the **discovery script**) to return arbitrary device state as a JSON payload. The compliance engine then evaluates that JSON against administrator-defined rules.

```
┌─────────────────────────────────────────────────────────────────┐
│                     Intune Service (Cloud)                      │
│                                                                 │
│  Compliance Policy                                              │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  Built-in Settings     Custom Settings                    │  │
│  │  (BitLocker ON,        (linked to Discovery Script)       │  │
│  │   AV up-to-date, ...)  (rules: Key, Operator, Value)      │  │
│  └───────────────────────────────────────────────────────────┘  │
│              │                        │                         │
│              ▼                        ▼                         │
│  Compliance Engine evaluates on next check-in                   │
└────────────────────────────┬────────────────────────────────────┘
                             │  Policy downloaded
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Device (Windows 10/11)                       │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Intune Management Extension (IME)                       │   │
│  │  C:\Program Files (x86)\Microsoft Intune Management      │   │
│  │  Extension\Microsoft.Management.Services.               │   │
│  │  IntuneWindowsAgent.exe                                  │   │
│  │                                                          │   │
│  │  1. Downloads discovery script                           │   │
│  │  2. Runs as SYSTEM (no network proxy, limited access)    │   │
│  │  3. Captures STDOUT                                      │   │
│  │  4. Validates JSON                                       │   │
│  │  5. Reports JSON to Intune service                       │   │
│  └──────────────────────────────────────────────────────────┘   │
│                            │                                    │
│  Discovery Script Output   │                                    │
│  (must be valid JSON only) │                                    │
│  {                         │                                    │
│    "FirewallEnabled": true │                                    │
│    "AuditLogSize": 65536   │                                    │
│  }                         │                                    │
└────────────────────────────┴────────────────────────────────────┘
                             │  JSON reported back
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Intune Service (Cloud)                       │
│                                                                 │
│  Compliance Evaluation:                                         │
│  FirewallEnabled == true  → PASS                                │
│  AuditLogSize >= 65536    → PASS                                │
│  Combined result: COMPLIANT                                     │
│                                                                 │
│  → Compliance state published to Entra ID                       │
│  → Conditional Access evaluates (if required)                   │
└─────────────────────────────────────────────────────────────────┘
```

**Key components:**

| Component | Location | Purpose |
|---|---|---|
| Discovery Script | Intune portal (uploaded) | PowerShell that runs on device and outputs JSON |
| Compliance Policy | Intune portal | Defines rules that reference JSON keys |
| IME | Device | Runs scripts, reports results |
| IME Logs | `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\` | Execution logs |
| Compliance State | Entra ID device object | Used by Conditional Access |

**Compliance rule operators:**

| Operator | Meaning | Example |
|---|---|---|
| `IsEqual` | JSON value equals setting value | `FirewallEnabled IsEqual true` |
| `IsNotEqual` | JSON value does not equal | `PendingReboot IsNotEqual true` |
| `IsGreaterThan` | Numeric greater than | `AuditLogSizeMB IsGreaterThan 100` |
| `IsGreaterThanOrEqual` | Numeric ≥ | `DiskEncryptionPercent IsGreaterThanOrEqual 100` |
| `IsLessThan` | Numeric less than | |
| `IsLessThanOrEqual` | Numeric ≤ | |

**JSON type handling:**

| PowerShell Type | JSON Type | Compliance Value Type |
|---|---|---|
| `[bool]$true` | `true` | Boolean |
| `[bool]$false` | `false` | Boolean |
| `[int]65536` | `65536` | Number |
| `"compliant"` | `"compliant"` | String |

> ⚠️ PowerShell's `$true` in an array or hashtable may serialise as `True` (capitalised string) with `ConvertTo-Json` unless cast as `[bool]`. Always be explicit: `[bool]$variable`.

**Discovery script execution schedule:**

IME runs compliance discovery scripts approximately every **8 hours** (default check-in interval). Scripts do not run on every policy sync — only at the compliance evaluation interval. To force immediate execution, trigger a device sync from Intune portal or via Graph API.

**Script execution context:**

```
User:        SYSTEM (NT AUTHORITY\SYSTEM)
Network:     No proxy configuration inherited
Profile:     No user profile loaded (HKCU registry not accessible)
Timeout:     30 seconds (scripts that exceed this are killed; device reports 'error')
Output:      Only STDOUT is captured — STDERR and Write-Host are discarded by parser
```

> `Write-Host` in PowerShell 5.1 writes to the information stream (stream 6), not STDOUT. In PowerShell 7, `Write-Host` also goes to information stream. In both cases, **only `Write-Output` / `return` / unassigned expressions go to STDOUT**. The IME captures STDOUT only.

</details>

---

## Dependency Stack

```
Intune Compliance Policy (with Custom Compliance settings)
        │
Custom Compliance Discovery Script (uploaded to Intune)
        │
Intune Management Extension (IME) — Windows service on device
        │
Windows PowerShell 5.1 (script execution engine)
        │
Device enrolled in Intune (MDM enrolled, not just registered)
        │
Intune check-in (device must be able to reach *.manage.microsoft.com)
        │
Entra ID Device Object (compliance state stored here)
        │
Conditional Access (reads compliance state from Entra ID)
        │
Resource Access (Teams, SharePoint, etc. — blocked if non-compliant + CA enforcing)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Device `error` compliance state | Script output is not valid JSON, or script threw exception | IME log → look for JSON parse errors |
| Device always `nonCompliant` regardless of state | JSON key name mismatch with compliance rule setting name | Compare policy setting names vs script output keys |
| Device `unknown` state | IME not installed, or policy not yet received | Check IME service, check assignment group |
| Script runs locally but not via Intune | Script relies on user context, HKCU, or proxy | Retest as SYSTEM: `psexec -s -i powershell.exe` |
| Compliance state not updating after fix | 8-hour evaluation interval not elapsed | Force sync + wait, or trigger via Graph |
| `nonCompliant` on specific check only | Logic error in script for that condition | Manually extract that check and test as SYSTEM |
| Slow compliance re-evaluation in CA | Conditional Access token cache not expired | Normal behaviour; CA evaluates at token issuance |
| Policy not assigned to device | Device not in targeted Entra group | Check group membership and dynamic group rules |
| IME logs show "Access denied" | Script requires admin rights or protected registry paths | Review script — IME runs as SYSTEM, should have access; check UAC/AppLocker |
| Multiple compliance policies conflicting | Stacked policies with contradictory rules | Check all policy assignments; non-compliant on any = non-compliant overall |

---

## Validation Steps

**1. Verify IME is installed and running**

```powershell
# On device
$ime = Get-Service -Name "Microsoft Intune Management Extension" -ErrorAction SilentlyContinue
if (-not $ime) { Write-Warning "IME not installed" }
else { $ime | Select Name, Status, StartType }
```

Expected: `Running`, `Automatic`.

---

**2. Check IME version**

```powershell
$imePath = "C:\Program Files (x86)\Microsoft Intune Management Extension\Microsoft.Management.Services.IntuneWindowsAgent.exe"
(Get-Item $imePath).VersionInfo.FileVersion
```

Expected: Recent version (check [IME release notes](https://learn.microsoft.com/en-us/mem/intune/apps/intune-management-extension) for current version).

---

**3. Validate discovery script output format**

```powershell
# Run as SYSTEM using PsExec, or via a test Intune Remediation
# Test that output is valid JSON
$scriptPath = "<PathToDiscoveryScript.ps1>"
$output = & $scriptPath 2>$null
try {
    $json = $output | ConvertFrom-Json
    Write-Host "JSON valid. Keys: $($json.PSObject.Properties.Name -join ', ')" -ForegroundColor Green
} catch {
    Write-Warning "JSON parse failed: $_"
    Write-Warning "Raw output: $output"
}
```

---

**4. Verify JSON key names match compliance rule setting names**

```powershell
# Via Graph — get compliance policy and its settings
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All"
$policyId = "<CompliancePolicyId>"
$policy = Get-MgDeviceManagementCompliancePolicy -DeviceCompliancePolicyId $policyId
$policy | Select-Object Id, Name, @{N="Settings";E={($_ | Get-MgDeviceManagementCompliancePolicySetting).SettingInstance}}
```

Manually compare the `SettingDefinitionId` values against your JSON keys.

---

**5. Check device compliance state and last script output**

```powershell
# Graph API — get device compliance details
$deviceId = "<ManagedDeviceId>"
$device = Get-MgDeviceManagementManagedDevice -ManagedDeviceId $deviceId
$device | Select DeviceName, ComplianceState, LastSyncDateTime, ConfigurationManagerClientEnabledFeatures

# Detailed compliance report
Get-MgDeviceManagementManagedDeviceCompliancePolicyState -ManagedDeviceId $deviceId |
    Select DisplayName, State, SettingCount
```

---

**6. Check IME logs for script execution**

```powershell
$logPath = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
# Find custom compliance execution entries
Get-Content $logPath | Select-String -Pattern "CustomCompliance|DiscoveryScript|compliance script|JSON" | Select-Object -Last 100
```

---

## Troubleshooting Steps (by phase)

### Phase 1 — Script Not Running

1. Verify IME installed and running (Step 1 above)
2. If IME missing: assign any Win32 app or PowerShell script to device to trigger IME install
3. Verify device is MDM enrolled (not just Entra registered): `dsregcmd /status` → `MDMEnrolled : YES`
4. Verify compliance policy is assigned to a group containing the device
5. Force sync: Intune portal → Device → Sync

---

### Phase 2 — Script Runs but Returns Error

1. Check IME log for error messages around script execution
2. Run script manually as SYSTEM via PsExec and observe output
3. Common errors:
   - Script outputs non-JSON text → sanitise output
   - Script throws exception → wrap in try/catch
   - Script exceeds 30s → optimise or add timeouts
4. Upload corrected script and reassign policy

---

### Phase 3 — Wrong Compliance State Despite Correct JSON

1. Extract exact JSON keys from your script output
2. Compare against compliance rule setting names in Intune portal
3. Check JSON value types — boolean vs string vs number
4. Look for Unicode/whitespace issues in key names (copy-paste from Word/PDF can introduce invisible characters)
5. Rebuild compliance rules from scratch to confirm correct key-value mapping

---

### Phase 4 — Compliance State Not Propagating to CA

1. Compliance state updates to Entra ID take up to **15 minutes** after IME reports results
2. Conditional Access tokens are evaluated at issuance — existing sessions are not immediately revoked
3. Force token re-evaluation: user signs out and back in, or admin revokes all refresh tokens:
   ```powershell
   Revoke-MgUserSignInSession -UserId "<UserUPN>"
   ```
4. Check Entra ID Sign-in logs to confirm CA policy is evaluating compliance correctly

---

### Phase 5 — Multiple Policies / Policy Stacking Issues

Intune compliance uses a **most restrictive wins** model:
- If a device is assigned 5 compliance policies and fails any one, it is non-compliant overall
- Check all assigned policies:

```powershell
$deviceId = "<ManagedDeviceId>"
Get-MgDeviceManagementManagedDeviceCompliancePolicyState -ManagedDeviceId $deviceId |
    Select DisplayName, State, SettingCount | Sort-Object State
```

Identify which policy is failing and focus troubleshooting on that one.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Write a Correct Discovery Script (Template)</summary>

**Best-practice template for custom compliance discovery scripts:**

```powershell
<#
.SYNOPSIS
    Custom Compliance Discovery Script — <Description>
.DESCRIPTION
    Outputs JSON with compliance-relevant settings for Intune Custom Compliance evaluation.
    IMPORTANT: Only outputs JSON — no other text to STDOUT.
.NOTES
    Runs as: SYSTEM (no user context)
    Timeout: 30 seconds
    Output:  Valid JSON only
    Required keys: <list your keys here>
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Initialise result object — include all keys even if check fails
$result = [ordered]@{
    DomainFirewallEnabled   = $false
    PrivateFirewallEnabled  = $false
    PublicFirewallEnabled   = $false
    AuditLogMaxSizeKB       = 0
    ScreenLockEnabled       = $false
}

try {
    # Firewall checks
    $fw = Get-NetFirewallProfile
    $result["DomainFirewallEnabled"]  = [bool]($fw | Where Profile -eq "Domain").Enabled
    $result["PrivateFirewallEnabled"] = [bool]($fw | Where Profile -eq "Private").Enabled
    $result["PublicFirewallEnabled"]  = [bool]($fw | Where Profile -eq "Public").Enabled

    # Audit log size
    $auditLog = Get-WinEvent -ListLog "Security" -ErrorAction SilentlyContinue
    if ($auditLog) {
        $result["AuditLogMaxSizeKB"] = [int]($auditLog.MaximumSizeInBytes / 1KB)
    }

    # Screen lock (via registry)
    $screenLock = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
        -Name "InactivityTimeoutSecs" -ErrorAction SilentlyContinue
    $result["ScreenLockEnabled"] = [bool]($screenLock -and $screenLock.InactivityTimeoutSecs -gt 0)

} catch {
    # On error, keys remain at safe defaults (false/0)
    # Do NOT output error text — it would break JSON parsing
}

# Output ONLY JSON — nothing else
return ($result | ConvertTo-Json -Compress)
```

</details>

<details><summary>Playbook 2 — Upload and Link Discovery Script</summary>

```powershell
# Upload via Graph API (alternative to portal UI)
Connect-MgGraph -Scopes "DeviceManagementConfiguration.ReadWrite.All"

$scriptContent = Get-Content -Path ".\DiscoveryScript.ps1" -Raw -Encoding UTF8
$scriptB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($scriptContent))

$body = @{
    displayName = "Custom Compliance - Security Baseline"
    description = "Checks firewall, audit log, and screen lock settings"
    scriptContent = $scriptB64
} | ConvertTo-Json

$script = Invoke-MgGraphRequest -Method POST `
    -Uri "https://graph.microsoft.com/beta/deviceManagement/reusablePolicySettings" `
    -Body $body -ContentType "application/json"

Write-Host "Script uploaded. ID: $($script.id)"
Write-Host "Link this script to a compliance policy in the Intune portal."
```

> Note: After uploading, link the script to a compliance policy via the Intune portal (Devices → Compliance policies → Create → Custom Compliance → select script and define rules). The portal UI is the supported path for linking scripts to policies.

</details>

<details><summary>Playbook 3 — Deploy Companion Remediation Script</summary>

**Use case:** Auto-remediate non-compliant settings detected by custom compliance.

```powershell
# Detection script (upload as Remediation Detection)
<#
.SYNOPSIS Detect if domain firewall is disabled
#>
$fw = Get-NetFirewallProfile -Profile Domain
if ($fw.Enabled -eq $false) {
    Write-Host "NonCompliant: Domain firewall disabled"
    exit 1  # 1 = non-compliant, triggers remediation
}
exit 0  # 0 = compliant

#---

# Remediation script (upload as Remediation Remediation)
<#
.SYNOPSIS Enable domain firewall
#>
Set-NetFirewallProfile -Profile Domain -Enabled True
if ((Get-NetFirewallProfile -Profile Domain).Enabled) {
    Write-Host "Remediated: Domain firewall enabled"
    exit 0
} else {
    Write-Host "Failed: Could not enable domain firewall"
    exit 1
}
```

**Deploy via Intune:** Devices → Scripts and remediations → Add → configure detection + remediation scripts → assign to same group as compliance policy.

</details>

<details><summary>Playbook 4 — Audit Custom Compliance Across All Devices</summary>

```powershell
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All", "DeviceManagementManagedDevices.Read.All"

$policyId = "<CompliancePolicyId>"

# Get all device statuses for this policy
$statuses = Get-MgDeviceManagementCompliancePolicyDeviceStatus -DeviceCompliancePolicyId $policyId -All

$report = $statuses | ForEach-Object {
    [PSCustomObject]@{
        DeviceName          = $_.DeviceDisplayName
        UserName            = $_.UserName
        Status              = $_.Status
        LastReported        = $_.LastReportedDateTime
        ComplianceGracePeriodExpiration = $_.ComplianceGracePeriodExpirationDateTime
    }
}

$report | Sort-Object Status, DeviceName |
    Export-Csv -Path ".\CustomCompliance-Audit-$(Get-Date -Format yyyyMMdd).csv" -NoTypeInformation

Write-Host "Compliant:    $(($report | Where Status -eq 'compliant').Count)"
Write-Host "NonCompliant: $(($report | Where Status -eq 'nonCompliant').Count)"
Write-Host "Error:        $(($report | Where Status -eq 'error').Count)"
Write-Host "Unknown:      $(($report | Where Status -eq 'unknown').Count)"
```

</details>

---

## Evidence Pack

```powershell
# Collect all evidence for escalation

Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All", "DeviceManagementManagedDevices.Read.All"

$policyId    = "<CompliancePolicyId>"
$deviceId    = "<ManagedDeviceId>"   # Intune device ID (not Entra device ID)
$outputPath  = ".\CustomCompliance-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

# Policy details
Get-MgDeviceManagementCompliancePolicy -DeviceCompliancePolicyId $policyId |
    ConvertTo-Json -Depth 5 | Out-File "$outputPath\01-Policy.json"

# Policy assignments
Get-MgDeviceManagementCompliancePolicyAssignment -DeviceCompliancePolicyId $policyId |
    ConvertTo-Json -Depth 5 | Out-File "$outputPath\02-Assignments.json"

# Device compliance state
Get-MgDeviceManagementManagedDevice -ManagedDeviceId $deviceId |
    ConvertTo-Json -Depth 3 | Out-File "$outputPath\03-Device.json"

# Per-policy state on device
Get-MgDeviceManagementManagedDeviceCompliancePolicyState -ManagedDeviceId $deviceId |
    ConvertTo-Json -Depth 5 | Out-File "$outputPath\04-DeviceComplianceState.json"

# All device statuses for the policy
Get-MgDeviceManagementCompliancePolicyDeviceStatus -DeviceCompliancePolicyId $policyId -All |
    Export-Csv -Path "$outputPath\05-AllDeviceStatuses.csv" -NoTypeInformation

# IME log (must be run on device separately — copy here)
Write-Host ""
Write-Host "TODO: Also collect from device:" -ForegroundColor Yellow
Write-Host "  C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
Write-Host "  Output of: & <DiscoveryScript.ps1> (run as SYSTEM)"
Write-Host ""
Write-Host "Evidence in: $outputPath"
```

---

## Command Cheat Sheet

| Task | Command |
|---|---|
| List all compliance policies | `Get-MgDeviceManagementCompliancePolicy -All \| Select Id, Name` |
| Get device compliance state | `Get-MgDeviceManagementManagedDevice -ManagedDeviceId <id> \| Select ComplianceState` |
| Get per-policy state on device | `Get-MgDeviceManagementManagedDeviceCompliancePolicyState -ManagedDeviceId <id>` |
| Get all device statuses for policy | `Get-MgDeviceManagementCompliancePolicyDeviceStatus -DeviceCompliancePolicyId <id> -All` |
| Force device sync (remote) | `Invoke-MgDeviceManagementManagedDeviceSyncDevice -ManagedDeviceId <id>` |
| Revoke user sign-in sessions | `Revoke-MgUserSignInSession -UserId <UPN>` |
| Check IME service (on device) | `Get-Service "Microsoft Intune Management Extension"` |
| Test JSON validity | `$output \| ConvertFrom-Json` |
| Run script as SYSTEM (test) | `psexec -s -i powershell.exe -File <script.ps1>` |
| View IME log | `Get-Content C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log \| Select-String "compliance"` |
| Count compliant vs not | See Playbook 4 |

---

## 🎓 Learning Pointers

- **Custom compliance script JSON must be the sole STDOUT output** — this is the single most common failure mode. Even a single `Write-Host` or unhandled exception message will cause the compliance engine to mark the device as `error`. Use `2>$null` and `try/catch` to suppress all non-JSON output. [MS Docs: Custom compliance discovery scripts](https://learn.microsoft.com/en-us/mem/intune/protect/compliance-use-custom-settings)

- **IME is the orchestrator, not a standalone agent** — IME handles Win32 app installs, PowerShell scripts, Remediations, and custom compliance discovery. Understanding IME logs means understanding all these features at once. The single log at `IntuneManagementExtension.log` covers all of them — search by keywords (`CustomCompliance`, `Win32App`, `Remediation`) to isolate the relevant entries.

- **Boolean serialisation gotcha** — PowerShell's `ConvertTo-Json` will serialise `$true` as `true` (correct) only when the value is an actual `[bool]`. If you store `"true"` (a string), the JSON emits `"true"` (a string), and the compliance rule evaluating against a Boolean `true` will fail. Always cast: `[bool]$variable`. [GitHub issue tracking this behaviour](https://github.com/PowerShell/PowerShell/issues/3160)

- **Custom compliance + Remediations is a powerful combo** — use Custom Compliance to detect non-compliance, and a paired Intune Remediation script to auto-fix it. The workflow: device fails custom compliance → engineer creates Remediation for the same check → Remediation auto-corrects → next compliance evaluation cycle marks device compliant. This reduces helpdesk tickets dramatically for common drift issues.

- **Compliance grace period** — compliance policies can be configured with a grace period (e.g., 24h). During this period, a non-compliant device is marked as "in grace period" rather than "non-compliant", which means Conditional Access may still grant access. Know your tenant's grace period configuration before assuming non-compliant = blocked. [MS Docs: Compliance grace period](https://learn.microsoft.com/en-us/mem/intune/protect/device-compliance-get-started#compliance-policy-settings)

- **Test with Intune's built-in script tester** — the Intune portal includes a "Test" option for discovery scripts (currently in preview) that shows the raw JSON output from a target device without waiting for the full compliance cycle. Use this to rapidly validate script output during development. If not available in your tenant, use a test Remediation script as a proxy runner.
