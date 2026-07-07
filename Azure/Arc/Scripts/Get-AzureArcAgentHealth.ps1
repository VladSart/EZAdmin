<#
.SYNOPSIS
    Reports Azure Arc-enabled server (Connected Machine agent) health: local agent status,
    core service state, recent AZCM error codes, and optionally the Azure-side resource state.

.DESCRIPTION
    Run locally (elevated) on a server onboarded to Azure Arc to produce a health report covering:
      - azcmagent show / azcmagent check output
      - Core service status (himds, GCArcService, ExtensionService)
      - Recent AZCM#### error codes found in the verbose agent log
      - Days since last heartbeat/status change, flagged against the 45-90 day expiry window
      - Optional: Azure-side resource state via Get-AzConnectedMachine, if -ResourceGroupName/
        -MachineName are supplied and an authenticated Az context exists

    Does not modify anything, does not restart services, does not attempt reconnection.
    Safe to run at any time, including during an active incident.

.PARAMETER ResourceGroupName
    Optional. Resource group containing the Azure-side Microsoft.HybridCompute/machines resource.
    If supplied along with -MachineName, the script also queries the Azure-side resource state.

.PARAMETER MachineName
    Optional. Name of the Azure Arc machine resource. Defaults to the local hostname if omitted
    but -ResourceGroupName is supplied.

.PARAMETER WarningDaysDisconnected
    Number of days disconnected at which to raise a WARNING (approaching the 45-90 day expiry
    cliff where the Entra managed identity registration itself expires). Default 30.

.PARAMETER ExportPath
    Path to export the CSV summary. Defaults to C:\Temp\AzureArcHealth_<timestamp>.csv.

.EXAMPLE
    .\Get-AzureArcAgentHealth.ps1

.EXAMPLE
    .\Get-AzureArcAgentHealth.ps1 -ResourceGroupName 'rg-arc-servers' -MachineName 'SRV-FILE01' -WarningDaysDisconnected 21

.NOTES
    Requires:    azcmagent CLI present (installed with the Connected Machine agent) for local checks.
                 Az.ConnectedMachine + Az.Accounts modules only if using -ResourceGroupName/-MachineName.
    Run as:      Administrator (elevated) for full service-status visibility.
    Permissions: Reader (or higher) on the Microsoft.HybridCompute/machines resource, if querying Azure-side.
    Safe to run: Read-only. No services restarted, no reconnect/disconnect actions taken.
    Limits:      Cannot see inside extension-level execution (AMA ingestion success, MDE onboarding
                 state, Update Manager patch state) — this script covers the Arc connectivity/identity
                 layer only. Cross-reference extension-specific tooling for anything above that layer.
#>

[CmdletBinding()]
param(
    [string]$ResourceGroupName,
    [string]$MachineName = $env:COMPUTERNAME,
    [int]$WarningDaysDisconnected = 30,
    [string]$ExportPath = "C:\Temp\AzureArcHealth_$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$findings = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Finding {
    param([string]$Category, [string]$Item, [string]$Value, [string]$Flag = "OK")
    $findings.Add([PSCustomObject]@{ Category = $Category; Item = $Item; Value = $Value; Flag = $Flag })
}

#region — Preflight
Write-Status "Azure Arc-Enabled Server Health Reporter" "INFO"
Write-Status "=========================================" "INFO"

$azcmagentPath = Get-Command azcmagent -ErrorAction SilentlyContinue
if (-not $azcmagentPath) {
    Write-Status "azcmagent CLI not found on PATH. Is the Connected Machine agent installed on this host?" "ERROR"
    Add-Finding "Prerequisite" "azcmagent CLI" "NOT FOUND" "CRITICAL"
} else {
    Write-Status "azcmagent found at: $($azcmagentPath.Source)" "OK"
}

$outDir = Split-Path $ExportPath -Parent
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
#endregion

#region — Core service status
Write-Status "Checking core Arc agent services..." "INFO"
foreach ($svcName in @('himds', 'GCArcService', 'ExtensionService')) {
    try {
        $svc = Get-Service -Name $svcName -ErrorAction Stop
        $flag = if ($svc.Status -eq 'Running') { 'OK' } else { 'CRITICAL' }
        Add-Finding "Service" $svcName $svc.Status $flag
        Write-Status "  $svcName : $($svc.Status)" $(if ($flag -eq 'OK') { 'OK' } else { 'ERROR' })
    } catch {
        Add-Finding "Service" $svcName "NOT FOUND" "CRITICAL"
        Write-Status "  $svcName : NOT FOUND (agent may not be installed, or this is not Windows)" "ERROR"
    }
}
#endregion

#region — azcmagent show
if ($azcmagentPath) {
    Write-Status "Running 'azcmagent show'..." "INFO"
    try {
        $showOutput = & azcmagent show 2>&1
        $showText = $showOutput -join "`n"
        Write-Host $showText

        $agentStatus = if ($showText -match "Agent Status\s*:\s*(\S+)") { $Matches[1] } else { "Unknown" }
        $flag = switch ($agentStatus) {
            "Connected"    { "OK" }
            "Disconnected" { "CRITICAL" }
            default        { "WARN" }
        }
        Add-Finding "Agent" "Agent Status" $agentStatus $flag

        if ($showText -match "Last Heartbeat\s*:\s*(.+)") {
            $lastHeartbeatRaw = $Matches[1].Trim()
            Add-Finding "Agent" "Last Heartbeat" $lastHeartbeatRaw "INFO"
            try {
                $lastHeartbeat = [datetime]::Parse($lastHeartbeatRaw)
                $daysSince = (New-TimeSpan -Start $lastHeartbeat -End (Get-Date)).Days
                $hbFlag = if ($daysSince -ge $WarningDaysDisconnected) { "WARN" } else { "OK" }
                if ($daysSince -ge 45) { $hbFlag = "CRITICAL" }
                Add-Finding "Agent" "Days Since Last Heartbeat" $daysSince $hbFlag
                if ($daysSince -ge 45) {
                    Write-Status "  Machine has been disconnected $daysSince days — approaching/past the 45-90 day Entra managed identity expiry window. Standard reconnect troubleshooting may not work; see AzureArc-A.md Playbook 2." "ERROR"
                } elseif ($daysSince -ge $WarningDaysDisconnected) {
                    Write-Status "  Machine has been disconnected $daysSince days — remediate now, before it approaches the expiry cliff." "WARN"
                }
            } catch {
                Write-Status "  Could not parse last heartbeat timestamp for age calculation." "WARN"
            }
        }
    } catch {
        Write-Status "azcmagent show failed: $_" "ERROR"
        Add-Finding "Agent" "Agent Status" "ERROR: $_" "CRITICAL"
    }

    #region — azcmagent check
    Write-Status "Running 'azcmagent check' (endpoint connectivity probe)..." "INFO"
    try {
        $checkOutput = & azcmagent check 2>&1
        $checkText = $checkOutput -join "`n"
        Write-Host $checkText

        $failedLines = $checkOutput | Select-String -Pattern "fail" -SimpleMatch -CaseSensitive:$false
        if ($failedLines) {
            Add-Finding "Connectivity" "azcmagent check" "One or more endpoints FAILED" "CRITICAL"
            foreach ($line in $failedLines) {
                Write-Status "  FAILED: $line" "ERROR"
            }
        } else {
            Add-Finding "Connectivity" "azcmagent check" "All endpoints passed" "OK"
        }
    } catch {
        Write-Status "azcmagent check failed to run: $_" "WARN"
        Add-Finding "Connectivity" "azcmagent check" "ERROR: $_" "WARN"
    }
    #endregion
}
#endregion

#region — Recent AZCM error codes in the verbose log
$logPath = if ($IsLinux) { "/var/opt/azcmagent/log/azcmagent.log" } else { "$env:ProgramData\AzureConnectedMachineAgent\Log\azcmagent.log" }
Write-Status "Scanning agent log for recent AZCM error codes: $logPath" "INFO"
if (Test-Path $logPath) {
    try {
        $recentErrors = Get-Content $logPath -Tail 500 -ErrorAction Stop | Select-String -Pattern "AZCM\d{4}" | Select-Object -Last 10
        if ($recentErrors) {
            Add-Finding "Log" "Recent AZCM Errors" "$($recentErrors.Count) found in last 500 lines" "WARN"
            foreach ($err in $recentErrors) {
                Write-Status "  $($err.Line.Trim())" "WARN"
            }
        } else {
            Add-Finding "Log" "Recent AZCM Errors" "None found in last 500 lines" "OK"
        }
    } catch {
        Write-Status "Could not read agent log: $_" "WARN"
        Add-Finding "Log" "Recent AZCM Errors" "ERROR reading log: $_" "WARN"
    }
} else {
    Write-Status "Agent log not found at expected path — agent may not be installed, or path differs on this OS/version." "WARN"
    Add-Finding "Log" "Log File" "NOT FOUND at $logPath" "WARN"
}
#endregion

#region — Optional Azure-side resource check
if ($ResourceGroupName -and $MachineName) {
    Write-Status "Checking Azure-side resource state for $MachineName in $ResourceGroupName..." "INFO"
    try {
        if (-not (Get-Module -ListAvailable -Name Az.ConnectedMachine)) {
            Write-Status "Az.ConnectedMachine module not installed — skipping Azure-side check. Install with: Install-Module Az.ConnectedMachine -Scope CurrentUser" "WARN"
            Add-Finding "Azure" "Az.ConnectedMachine module" "NOT INSTALLED" "WARN"
        } else {
            $ctx = Get-AzContext
            if (-not $ctx) {
                Write-Status "No Azure context — launching interactive login..." "WARN"
                Connect-AzAccount | Out-Null
            }
            $azm = Get-AzConnectedMachine -ResourceGroupName $ResourceGroupName -Name $MachineName -ErrorAction Stop
            Add-Finding "Azure" "Resource Status" $azm.Status $(if ($azm.Status -eq 'Connected') { 'OK' } else { 'CRITICAL' })
            Add-Finding "Azure" "Last Status Change" $azm.LastStatusChange "INFO"
            Add-Finding "Azure" "Agent Version (Azure-reported)" $azm.AgentVersion "INFO"
            Write-Status "  Azure-side status: $($azm.Status) | Last change: $($azm.LastStatusChange) | Agent version: $($azm.AgentVersion)" $(if ($azm.Status -eq 'Connected') { 'OK' } else { 'ERROR' })
        }
    } catch {
        Write-Status "Could not query Azure-side resource: $_" "WARN"
        Add-Finding "Azure" "Resource Query" "ERROR: $_" "WARN"
    }
} else {
    Write-Status "No -ResourceGroupName/-MachineName supplied — skipping Azure-side resource check (local-only report)." "INFO"
}
#endregion

#region — Summary and export
Write-Status "" "INFO"
Write-Status "=== SUMMARY ===" "INFO"
$critical = $findings | Where-Object { $_.Flag -eq "CRITICAL" }
$warnings = $findings | Where-Object { $_.Flag -eq "WARN" }

if ($critical) {
    Write-Status "$($critical.Count) CRITICAL finding(s):" "ERROR"
    $critical | Format-Table -AutoSize
}
if ($warnings) {
    Write-Status "$($warnings.Count) WARNING finding(s):" "WARN"
    $warnings | Format-Table -AutoSize
}
if (-not $critical -and -not $warnings) {
    Write-Status "No critical or warning findings — agent appears healthy." "OK"
}

$findings | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Report exported: $ExportPath" "OK"
#endregion
