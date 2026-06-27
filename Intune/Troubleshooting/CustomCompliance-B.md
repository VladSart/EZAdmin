# Intune Custom Compliance Scripts — Hotfix Runbook (Mode B: Ops)
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

Run these immediately to understand the problem:

```powershell
# 1. Check custom compliance policy assignments
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All"
Get-MgDeviceManagementCompliancePolicy | Where-Object { $_.Name -like "*custom*" } |
    Select-Object Id, Name, CreatedDateTime, LastModifiedDateTime

# 2. Check compliance state for a specific device
$deviceId = "<DeviceObjectId>"
Get-MgDeviceManagementManagedDevice -ManagedDeviceId $deviceId |
    Select-Object DeviceName, ComplianceState, LastSyncDateTime, OperatingSystem

# 3. Check policy assignment status via Intune portal (Graph)
$policyId = "<CompliancePolicyId>"
Get-MgDeviceManagementCompliancePolicyDeviceStatus -DeviceCompliancePolicyId $policyId |
    Select-Object DeviceDisplayName, Status, LastReportedDateTime | Sort-Object Status
```

**Interpretation:**

| Result | Next Action |
|---|---|
| Device shows `nonCompliant` but script logic seems correct | Check discovery script output — device may be returning unexpected JSON |
| All devices `nonCompliant` after policy change | Script syntax error or wrong JSON key names |
| Policy not visible on device | Assignment not targeting device's group; check group membership |
| Script uploaded but never runs | Check platform — custom compliance scripts only run on Windows 10/11 |
| `error` state on device | Script crashed — check for PowerShell exceptions, missing permissions |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Device enrolled in Intune (Windows 10/11 only — not macOS/iOS/Android)
        │
Intune Management Extension (IME) installed and healthy
  C:\Program Files (x86)\Microsoft Intune Management Extension\
        │
Discovery Script uploaded to Intune (PowerShell, must output valid JSON)
        │
Custom Compliance Policy created and linked to Discovery Script
        │
Compliance Policy assigned to group containing device
        │
Device checks in → IME runs discovery script → JSON output captured
        │
Compliance engine evaluates JSON against compliance rules
        │
Device marked Compliant / NonCompliant / Error
        │
Conditional Access evaluates compliance state (if CA policy requires compliant device)
```

**Critical constraints:**
- Discovery scripts must output **valid JSON** — any non-JSON output causes `error` state
- JSON keys must **exactly match** the compliance rule setting names (case-insensitive but consistent)
- Scripts run in **SYSTEM context** — no user tokens or interactive sessions
- Script must complete in **≤ 30 seconds** (default timeout; can cause errors on slow machines)
- Custom compliance is **Windows-only** — macOS requires a different compliance model

</details>

---

## Diagnosis & Validation Flow

**Step 1: Verify IME is healthy on the device**

```powershell
# Run on the affected device
Get-Service -Name "Microsoft Intune Management Extension" | Select Name, Status, StartType
Get-EventLog -LogName Application -Source "Microsoft Intune Management Extension" -Newest 20 |
    Select TimeGenerated, EntryType, Message | Format-Table -Wrap
```

Expected: Service `Running`. Event log shows recent policy downloads and script executions.

Bad: Service stopped, or errors like "script execution failed" in event log.

---

**Step 2: Check IME logs for discovery script output**

```powershell
# Run on the affected device (as SYSTEM or via Intune Remediation)
$logPath = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
Select-String -Path $logPath -Pattern "custom compliance|discovery|compliance script" | Select-Object -Last 50
```

Expected: Lines showing script execution and JSON output (look for `Output:` lines).

Bad: `Error` entries, empty output, or `timeout` messages.

---

**Step 3: Manually test discovery script output**

```powershell
# Run on affected device as SYSTEM (use PsExec or Intune Remediation to run as SYSTEM)
# Replace with your actual script content or path
$output = & "C:\Path\To\DiscoveryScript.ps1"
$output
# Verify it is valid JSON:
$output | ConvertFrom-Json
```

Expected: Script runs cleanly, outputs valid JSON with expected keys.

Bad: Script throws exceptions, outputs non-JSON text, or keys don't match what compliance rule expects.

---

**Step 4: Verify JSON key names match compliance rules**

In the Intune portal:
1. Navigate to **Devices → Compliance policies → [Policy name] → Properties**
2. Under **Compliance settings**, note the **Setting name** for each custom rule
3. These must **exactly match** the JSON key names output by your discovery script

Example — if your compliance rule setting name is `FirewallEnabled`, your script must output:
```json
{
  "FirewallEnabled": true
}
```

Not: `firewallEnabled`, `Firewall_Enabled`, or any other variation.

---

**Step 5: Force a sync and re-evaluate**

```powershell
# On the device — trigger Intune sync
Start-Process "C:\Program Files (x86)\Microsoft Intune Management Extension\Microsoft.Management.Services.IntuneWindowsAgent.exe" -ArgumentList "sync" -Wait

# Or via Graph API (remote sync)
$deviceId = "<DeviceObjectId>"
Invoke-MgDeviceManagementManagedDeviceSyncDevice -ManagedDeviceId $deviceId
```

---

## Common Fix Paths

<details><summary>Fix 1 — Script outputs non-JSON text (most common)</summary>

**Symptom:** Device shows `error` compliance state; IME logs show script ran but output wasn't captured.

**Cause:** Script writes informational text (e.g., `Write-Host`, `Write-Output` of non-JSON), or throws an exception that outputs to stdout.

**Fix:** Discovery scripts must output **only** a valid JSON object. Any other output breaks parsing.

```powershell
# BAD — will break custom compliance
Write-Host "Checking firewall status..."
$fw = Get-NetFirewallProfile -Profile Domain
Write-Output "Firewall is: $($fw.Enabled)"

# GOOD — only JSON output
$result = @{}
$fw = Get-NetFirewallProfile -Profile Domain
$result["FirewallEnabled"] = [bool]$fw.Enabled

return ($result | ConvertTo-Json -Compress)
```

**Rollback:** Not applicable — this is a script fix. After updating, reassign policy to trigger re-evaluation.

</details>

<details><summary>Fix 2 — JSON keys don't match compliance rule setting names</summary>

**Symptom:** Script runs, outputs JSON, but device is always `nonCompliant` regardless of actual state.

**Cause:** Mismatch between JSON key names and Intune compliance rule setting names.

**Fix:**

1. In Intune portal → Compliance policies → Policy → Properties → Compliance settings
2. Note exact "Setting name" values for all custom rules
3. Update discovery script to use exactly matching keys:

```powershell
# If compliance rule setting name = "DomainFirewallEnabled"
$result = @{
    DomainFirewallEnabled = [bool](Get-NetFirewallProfile -Profile Domain).Enabled
    PrivateFirewallEnabled = [bool](Get-NetFirewallProfile -Profile Private).Enabled
}

return ($result | ConvertTo-Json -Compress)
```

4. Upload updated script to Intune → Devices → Scripts and remediations (or update inline in compliance policy)

</details>

<details><summary>Fix 3 — IME not installed / service not running</summary>

**Symptom:** Compliance script never runs; device stays in `unknown` compliance state.

**Cause:** Intune Management Extension not installed (device may not have any Win32 apps or PowerShell scripts assigned).

**Fix:** IME installs automatically when any Win32 app, PowerShell script, or Remediation is assigned. Assign a dummy PowerShell script to trigger IME install:

```powershell
# Create a minimal script to force IME installation
# Upload to Intune: Devices → Scripts → Add → Windows 10 and later
# Content:
Write-Output "IME trigger script - no action"
```

Then check IME installed:

```powershell
# On device
Get-Package -Name "Microsoft Intune Management Extension" -ErrorAction SilentlyContinue
Get-Service -Name "Microsoft Intune Management Extension"
```

If IME is installed but service is stopped:

```powershell
Start-Service -Name "Microsoft Intune Management Extension"
Set-Service -Name "Microsoft Intune Management Extension" -StartupType Automatic
```

</details>

<details><summary>Fix 4 — Policy not assigned to device's group</summary>

**Symptom:** Compliance policy exists but never appears on device; device stays in `unknown` state.

**Cause:** Group membership issue — device not in targeted Azure AD / Entra ID group.

```powershell
# Check device group membership
Connect-MgGraph -Scopes "GroupMember.Read.All", "Device.Read.All"
$deviceId = "<EntraDeviceObjectId>"
Get-MgDeviceMemberOf -DeviceId $deviceId | Select-Object Id, @{N="DisplayName";E={$_.AdditionalProperties.displayName}}

# Check which groups the compliance policy targets
$policyId = "<CompliancePolicyId>"
Get-MgDeviceManagementCompliancePolicyAssignment -DeviceCompliancePolicyId $policyId |
    Select-Object @{N="Target";E={$_.Target.AdditionalProperties}}
```

If device is not in the target group, add it or add the device to a targeted group and wait for sync (~15 min).

</details>

<details><summary>Fix 5 — Script exceeds 30-second timeout</summary>

**Symptom:** IME log shows "script timed out"; compliance state `error`.

**Cause:** Discovery script doing slow operations (DNS lookups, WMI queries with no timeout, network calls).

**Fix:** Optimise script and add timeouts:

```powershell
# Add explicit timeout to slow operations
$job = Start-Job -ScriptBlock {
    # Your slow check here
    Test-NetConnection -ComputerName "dc01" -Port 389 -InformationLevel Quiet
}
$completed = Wait-Job -Job $job -Timeout 10
$result = if ($completed) { Receive-Job $job } else { $false }
Remove-Job -Job $job -Force

$output = @{
    DomainControllerReachable = [bool]$result
}
return ($output | ConvertTo-Json -Compress)
```

</details>

---

## Escalation Evidence

Copy and fill in before raising a ticket with Microsoft Support:

```
=== Intune Custom Compliance Escalation ===

Tenant ID:              ___________________________
Compliance Policy Name: ___________________________
Compliance Policy ID:   ___________________________
Affected Device(s):     ___________________________
Device OS Version:      ___________________________
IME Version:            (C:\Program Files (x86)\Microsoft Intune Management Extension\ → check Properties)

Compliance State:       [ ] nonCompliant  [ ] error  [ ] unknown
Expected State:         ___________________________

Discovery Script Name:  ___________________________
Script last updated:    ___________________________

IME log excerpt:        (attach IntuneManagementExtension.log from C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\)
Graph API output:       (attach output of Get-MgDeviceManagementCompliancePolicyDeviceStatus)
JSON output from manual test: (paste result of running script locally as SYSTEM)

Steps already taken:
[ ] Verified IME service running
[ ] Verified JSON output is valid
[ ] Verified JSON keys match compliance rule setting names
[ ] Forced device sync
[ ] Verified group membership

Support priority: P[1/2/3]
Business impact: ___________________________
```

---

## 🎓 Learning Pointers

- **Custom compliance is Windows-only** — there is no equivalent for macOS, iOS, or Android in the same script-based model. macOS compliance uses built-in settings only (as of mid-2026). This is a frequent source of confusion when trying to standardise compliance checks across platforms.

- **Discovery script context** — scripts run as SYSTEM with no network proxy and limited access. Avoid anything that requires user context, network credentials, or COM automation. Use `Start-Job` with timeouts for any network-dependent checks.

- **JSON must be the only output** — any `Write-Host`, `Write-Output`, or unhandled exception output will break the JSON parser. Suppress all output except the final JSON: use `$ErrorActionPreference = 'SilentlyContinue'` carefully, or wrap everything in `try/catch` and include error state in the JSON itself.

- **IME log is your friend** — `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log` is the single most useful file for diagnosing custom compliance failures. It shows exactly what the script output and whether parsing succeeded. [MS Docs: Troubleshoot custom compliance](https://learn.microsoft.com/en-us/mem/intune/protect/compliance-use-custom-settings)

- **Compliance re-evaluation delay** — after fixing a script and syncing, it can take up to **8 hours** for all devices to re-evaluate compliance. Force immediate re-evaluation by triggering a sync from the Intune portal or via Graph (`Invoke-MgDeviceManagementManagedDeviceSyncDevice`).

- **Test scripts locally first** — before uploading to Intune, test in a local SYSTEM context using `PsExec -s -i powershell.exe` or via a test Remediation script. This saves multiple upload-wait-check cycles. [PsExec download](https://learn.microsoft.com/en-us/sysinternals/downloads/psexec)
