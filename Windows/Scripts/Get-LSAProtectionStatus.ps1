<#
.SYNOPSIS
    Reports LSA Protection (RunAsPPL) ground-truth status on a Windows endpoint — distinct from VBS/Credential Guard.

.DESCRIPTION
    Local diagnostic companion to Windows/Troubleshooting/LSA-Protection-A.md and -B.md.

    LSA Protection (Protected Process Light for lsass.exe) is a VBS-independent, kernel-level feature
    that can auto-enable on Windows 11 22H2+ enterprise-joined, HVCI-capable devices WITHOUT ever
    writing the RunAsPPL registry value — the registry alone is not a reliable signal. This script
    establishes ground truth via the WinInit Event ID 12 boot event (per the runbook's #1 Learning
    Pointer), evaluates the three auto-enablement criteria independently, and scans the
    CodeIntegrity/Operational log for both enforcement-blocked (3033/3063) and audit-only (3065/3066)
    LSA plug-in events so a blocked smart card driver, VPN auth module, or password filter DLL can be
    identified before or after a client-impacting break. Also flags Smart App Control state, since it
    silently suppresses the audit-only events this script otherwise surfaces.

    This script is read-only / reporting only. It does NOT enable, disable, or otherwise change
    RunAsPPL, Smart App Control, or any LSA plug-in. Use the runbook's Remediation Playbooks for
    actual remediation.

.PARAMETER EventLogHours
    How many hours back to scan the CodeIntegrity/Operational event log for LSA plug-in
    audit/enforcement events. Default: 168 (7 days).

.PARAMETER OutputPath
    Folder to write the CSV report to. Default: $env:TEMP.

.EXAMPLE
    .\Get-LSAProtectionStatus.ps1
    Runs a full local LSA Protection status check with default settings.

.EXAMPLE
    .\Get-LSAProtectionStatus.ps1 -EventLogHours 720 -OutputPath C:\Temp\Evidence
    Scans the last 30 days of CodeIntegrity events and writes the CSV to a custom folder.

.NOTES
    Requires: Run as Administrator (some registry keys and the System/CodeIntegrity event logs
              return incomplete data without elevation).
    Safe: Read-only. No configuration changes are made.
    Companion runbooks: Windows/Troubleshooting/LSA-Protection-A.md (deep dive),
                         Windows/Troubleshooting/LSA-Protection-B.md (hotfix triage).
    Related but distinct: Windows/Scripts/Get-VBSCredentialGuardStatus.ps1 — Credential Guard/VBS is
                           a separate, hypervisor-based feature that can be present independently of
                           LSA Protection. Run both if the ticket is ambiguous about which is in play.
#>
[CmdletBinding()]
param(
    [int]$EventLogHours = 168,
    [string]$OutputPath = $env:TEMP
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Status "Not running as Administrator — some registry keys and event log queries may fail or return incomplete data." "WARN"
}

$results = [ordered]@{}
$since = (Get-Date).AddHours(-$EventLogHours)

# ---------------------------------------------------------------------------
# 1. Registry configuration intent (NOT ground truth — see step 2)
# ---------------------------------------------------------------------------
Write-Status "Reading RunAsPPL registry configuration..."
Try {
    $lsaReg = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -ErrorAction Stop
    $runAsPPL = $lsaReg.RunAsPPL
} Catch {
    $runAsPPL = $null
}
$results["Registry_RunAsPPL"] = if ($null -ne $runAsPPL) { $runAsPPL } else { "Not set" }

Try {
    $csp = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\LocalSecurityAuthority' -ErrorAction Stop
    $results["Intune_CSP_ConfigureLsaProtectedProcess"] = $csp.ConfigureLsaProtectedProcess
} Catch {
    $results["Intune_CSP_ConfigureLsaProtectedProcess"] = "Not present"
}

If ($null -eq $runAsPPL -or $runAsPPL -eq 0) {
    Write-Status "Registry shows RunAsPPL not configured — this does NOT mean protection is off. Checking ground truth..." "WARN"
} Else {
    Write-Status "Registry RunAsPPL = $runAsPPL" "OK"
}

# ---------------------------------------------------------------------------
# 2. GROUND TRUTH — WinInit Event ID 12 (did LSASS actually start protected this boot?)
# ---------------------------------------------------------------------------
Write-Status "Checking WinInit Event ID 12 for ground-truth runtime state..."
Try {
    $evt12 = Get-WinEvent -LogName System -MaxEvents 1000 -ErrorAction Stop |
        Where-Object { $_.ProviderName -eq 'Microsoft-Windows-Wininit' -and $_.Id -eq 12 } |
        Select-Object -First 1

    If ($evt12) {
        $results["GroundTruth_LSAProtectionActive"] = $true
        $results["GroundTruth_EventMessage"] = ($evt12.Message -replace "`r?`n", " ")
        $results["GroundTruth_EventTime"] = $evt12.TimeCreated
        Write-Status "LSA Protection IS active this boot (WinInit Event ID 12 found)." "OK"
    } Else {
        $results["GroundTruth_LSAProtectionActive"] = $false
        $results["GroundTruth_EventMessage"] = "No Event ID 12 found in current boot's System log window"
        $results["GroundTruth_EventTime"] = $null
        Write-Status "LSA Protection is NOT active this boot (no WinInit Event ID 12)." "WARN"
    }
} Catch {
    $results["GroundTruth_LSAProtectionActive"] = "Unknown (event log query failed)"
    Write-Status "Could not query System event log: $($_.Exception.Message)" "ERROR"
}

# ---------------------------------------------------------------------------
# 3. Auto-enablement criteria (Windows 11 22H2+, enterprise-joined, HVCI-capable)
# ---------------------------------------------------------------------------
Write-Status "Evaluating auto-enablement criteria..."
Try {
    $os = Get-CimInstance Win32_OperatingSystem
    $buildNumber = [int]$os.BuildNumber
    $results["OS_Build"] = $buildNumber
    $results["OS_Win11_22H2OrLater"] = $buildNumber -ge 22621
} Catch {
    $results["OS_Build"] = "Unknown"
    $results["OS_Win11_22H2OrLater"] = "Unknown"
}

Try {
    $dsreg = (dsregcmd /status) -join "`n"
    $aadJoined = $dsreg -match 'AzureAdJoined\s*:\s*YES'
    $domainJoined = $dsreg -match 'DomainJoined\s*:\s*YES'
    $results["Join_EntraJoined"] = [bool]$aadJoined
    $results["Join_DomainJoined"] = [bool]$domainJoined
    $results["Join_EnterpriseJoined"] = [bool]($aadJoined -or $domainJoined)
} Catch {
    $results["Join_EnterpriseJoined"] = "Unknown (dsregcmd failed)"
}

Try {
    $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop
    $hvciCapable = $dg.AvailableSecurityProperties -contains 2
    $results["Hardware_HVCICapable"] = $hvciCapable
    $results["DeviceGuard_SecurityServicesRunning"] = ($dg.SecurityServicesRunning -join ',')
} Catch {
    $results["Hardware_HVCICapable"] = "Unknown (Win32_DeviceGuard query failed)"
}

$autoEligible = ($results["OS_Win11_22H2OrLater"] -eq $true) -and
                ($results["Join_EnterpriseJoined"] -eq $true) -and
                ($results["Hardware_HVCICapable"] -eq $true)
$results["AutoEnablement_CriteriaMet"] = $autoEligible

If ($autoEligible -and $results["GroundTruth_LSAProtectionActive"] -eq $true -and ($null -eq $runAsPPL -or $runAsPPL -eq 0)) {
    Write-Status "This device matches the auto-enablement pattern: protected, but no registry trace. Expected behavior, not a misconfiguration." "OK"
}

# ---------------------------------------------------------------------------
# 4. LSA plug-in compatibility events (blocked + audit-only)
# ---------------------------------------------------------------------------
Write-Status "Scanning CodeIntegrity/Operational log for LSA plug-in events (last $EventLogHours hours)..."
$pluginEvents = @()
Try {
    $pluginEvents = Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -MaxEvents 2000 -ErrorAction Stop |
        Where-Object { $_.TimeCreated -ge $since -and $_.Id -in 3033, 3063, 3065, 3066 } |
        ForEach-Object {
            [PSCustomObject]@{
                TimeCreated = $_.TimeCreated
                EventId     = $_.Id
                Type        = if ($_.Id -in 3033, 3063) { 'BLOCKED (enforcement)' } else { 'AUDIT-ONLY (pre-flight)' }
                Message     = ($_.Message -replace "`r?`n", " ").Substring(0, [Math]::Min(300, ($_.Message -replace "`r?`n", " ").Length))
            }
        }

    $blockedCount = ($pluginEvents | Where-Object { $_.Type -like 'BLOCKED*' }).Count
    $auditCount = ($pluginEvents | Where-Object { $_.Type -like 'AUDIT*' }).Count
    $results["PluginEvents_BlockedCount"] = $blockedCount
    $results["PluginEvents_AuditOnlyCount"] = $auditCount

    If ($blockedCount -gt 0) {
        Write-Status "$blockedCount plug-in(s)/driver(s) actively BLOCKED from loading into LSASS — this is a likely root cause for auth/credential-related symptoms." "WARN"
    }
    If ($auditCount -gt 0) {
        Write-Status "$auditCount audit-only event(s) found — these will become BLOCKED once enforcement is turned on. Review before rollout." "WARN"
    }
    If ($blockedCount -eq 0 -and $auditCount -eq 0) {
        Write-Status "No LSA plug-in compatibility events found in the scan window." "OK"
    }
} Catch {
    $results["PluginEvents_BlockedCount"] = "Unknown (query failed)"
    Write-Status "Could not query CodeIntegrity/Operational log: $($_.Exception.Message)" "ERROR"
}

# ---------------------------------------------------------------------------
# 5. Smart App Control state (suppresses audit-only events when On)
# ---------------------------------------------------------------------------
Write-Status "Checking Smart App Control state..."
Try {
    $sac = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name VerifiedAndReputablePolicyState -ErrorAction Stop
    $sacState = switch ($sac.VerifiedAndReputablePolicyState) {
        0 { "Off" }
        1 { "On (Enforce)" }
        2 { "Evaluation" }
        default { "Unknown ($($sac.VerifiedAndReputablePolicyState))" }
    }
    $results["SmartAppControl_State"] = $sacState
    If ($sac.VerifiedAndReputablePolicyState -eq 1) {
        Write-Status "Smart App Control is ON — audit-only events (3065/3066) are suppressed. Turn off temporarily for pre-flight testing." "WARN"
    }
} Catch {
    $results["SmartAppControl_State"] = "Not present / not applicable"
}

# ---------------------------------------------------------------------------
# 6. UEFI lock indicator (best-effort — definitive confirmation requires vendor tooling)
# ---------------------------------------------------------------------------
$results["Note_UEFILock"] = "RunAsPPL=1 indicates a UEFI-locked configuration was requested. This script cannot definitively confirm firmware-level lock state; treat any RunAsPPL=1 device as locked until proven otherwise via a test registry change + reboot, or the vendor opt-out tool."

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== LSA PROTECTION (RunAsPPL) STATUS SUMMARY ===" -ForegroundColor Cyan
$results.GetEnumerator() | ForEach-Object { Write-Host ("{0,-40} {1}" -f $_.Key, $_.Value) }

If ($pluginEvents.Count -gt 0) {
    Write-Host ""
    Write-Host "=== LSA PLUG-IN EVENTS (detail) ===" -ForegroundColor Cyan
    $pluginEvents | Sort-Object TimeCreated -Descending | Format-Table -AutoSize
}

$summaryPath = Join-Path $OutputPath "LSAProtectionStatus-Summary-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
$eventsPath = Join-Path $OutputPath "LSAProtectionStatus-PluginEvents-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"

$results.GetEnumerator() |
    Select-Object @{N='Property'; E={$_.Key}}, @{N='Value'; E={$_.Value}} |
    Export-Csv -Path $summaryPath -NoTypeInformation -Encoding UTF8

If ($pluginEvents.Count -gt 0) {
    $pluginEvents | Export-Csv -Path $eventsPath -NoTypeInformation -Encoding UTF8
}

Write-Host ""
Write-Status "Summary CSV: $summaryPath" "OK"
If ($pluginEvents.Count -gt 0) { Write-Status "Plug-in events CSV: $eventsPath" "OK" }
