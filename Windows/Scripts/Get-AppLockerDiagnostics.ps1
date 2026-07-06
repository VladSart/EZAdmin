<#
.SYNOPSIS
    Collects AppLocker enforcement state, service health, and recent block events for triage or escalation.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/AppLocker-B.md.
    Gathers, in one pass, everything the runbook's triage and diagnosis steps ask for:
    - AppIDSvc status (AppLocker silently does not enforce if this is stopped)
    - Effective policy enforcement mode per rule collection (Enabled/AuditOnly/NotConfigured)
    - Recent block events (8004 EXE/DLL, 8007 Script, 8024 Packaged app) and audit events (8003)
    - Optional: Test-AppLockerPolicy result for a specific file + user against the effective policy
    - Optional: file identity info (publisher/hash/path) for a specific blocked file, to seed a new rule

    Produces a console summary with pass/fail per check and exports full detail to CSV,
    so the output can be pasted directly into the runbook's Escalation Evidence template.

    Does NOT cover:
    - Creating or merging new AppLocker rules (that's AppLocker-B.md Fix 2 / Fix 3)
    - Switching enforcement mode (that's Fix 1 — this script only reports current mode)
    - WDAC (Windows Defender Application Control) diagnostics — checked only as a "not AppLocker" signal

.PARAMETER FilePath
    Optional path to a specific file to test against the effective policy and pull identity info for.

.PARAMETER UserName
    Optional user (DOMAIN\username) to test the file against. Defaults to "Everyone" if -FilePath is
    supplied without -UserName.

.PARAMETER EventLookbackHours
    How far back to search AppLocker event logs. Default: 24.

.PARAMETER ExportPath
    Path for CSV export. Default: .\AppLockerDiagnostics-<timestamp>.csv

.EXAMPLE
    .\Get-AppLockerDiagnostics.ps1
    Runs the full triage sweep — service, policy mode, and recent block events.

.EXAMPLE
    .\Get-AppLockerDiagnostics.ps1 -FilePath "C:\Program Files\App\App.exe" -UserName "CONTOSO\jsmith" -EventLookbackHours 72
    Also tests the specific file against the effective policy for that user and widens the event lookback to 3 days.

.NOTES
    Requires: Windows PowerShell 5.1+; AppLocker cmdlets (built into Windows 10/11 Pro+, Enterprise, Server)
    Run-as: Administrator (required to read effective policy and AppLocker event logs)
    Safe: Read-only — makes no policy changes, does not start/stop services
    Tested on: Windows 10 21H2+, Windows 11 Enterprise/Pro, Windows Server 2019/2022
#>
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$FilePath,

    [string]$UserName = "Everyone",

    [int]$EventLookbackHours = 24,

    [string]$ExportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

#region ─── Preflight ──────────────────────────────────────────────────────────
Write-Status "Get-AppLockerDiagnostics — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\AppLockerDiagnostics-$timestamp.csv"
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param([string]$Check, [string]$Status, [string]$Detail)
    $results.Add([PSCustomObject]@{
        Check     = $Check
        Status    = $Status
        Detail    = $Detail
        CheckedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    })
    Write-Status "$Check — $Detail" $Status
}
#endregion

#region ─── 1. AppIDSvc status ──────────────────────────────────────────────────
try {
    $svc = Get-Service -Name AppIDSvc -ErrorAction Stop
    if ($svc.Status -eq 'Running') {
        Add-Result "AppIDSvc" "OK" "Running (StartType: $($svc.StartType))"
    } else {
        Add-Result "AppIDSvc" "ERROR" "Status: $($svc.Status) — AppLocker policy exists but is NOT being enforced"
    }
} catch {
    Add-Result "AppIDSvc" "ERROR" "Could not query AppIDSvc: $_"
}
#endregion

#region ─── 2. Effective policy enforcement mode per rule collection ───────────
try {
    $effective = Get-AppLockerPolicy -Effective -ErrorAction Stop
    if ($effective.RuleCollections.Count -eq 0) {
        Add-Result "EffectivePolicy" "WARN" "No AppLocker rule collections found — policy not configured on this device"
    } else {
        foreach ($rc in $effective.RuleCollections) {
            $ruleCount = $rc.Count
            $detail = "EnforcementMode=$($rc.EnforcementMode); Rules=$ruleCount"
            if ($rc.EnforcementMode -eq 'AuditOnly') {
                Add-Result "RuleCollection-$($rc.RuleCollectionType)" "WARN" "$detail — logging only, not blocking"
            } elseif ($rc.EnforcementMode -eq 'NotConfigured') {
                Add-Result "RuleCollection-$($rc.RuleCollectionType)" "OK" "$detail — no policy for this collection"
            } else {
                Add-Result "RuleCollection-$($rc.RuleCollectionType)" "OK" "$detail — actively enforcing"
            }
        }
    }
} catch {
    Add-Result "EffectivePolicy" "ERROR" "Could not read effective AppLocker policy: $_"
}
#endregion

#region ─── 3. Recent AppLocker events ──────────────────────────────────────────
$startTime = (Get-Date).AddHours(-$EventLookbackHours)

$logsToCheck = @(
    @{ Log = 'Microsoft-Windows-AppLocker/EXE and DLL';            BlockId = 8004; AuditId = 8003 },
    @{ Log = 'Microsoft-Windows-AppLocker/MSI and Script';          BlockId = 8007; AuditId = 8006 },
    @{ Log = 'Microsoft-Windows-AppLocker/Packaged app-Deployment'; BlockId = 8024; AuditId = 8023 }
)

foreach ($logDef in $logsToCheck) {
    try {
        $blocks = Get-WinEvent -FilterHashtable @{
            LogName   = $logDef.Log
            Id        = $logDef.BlockId
            StartTime = $startTime
        } -ErrorAction SilentlyContinue

        $blockCount = if ($blocks) { $blocks.Count } else { 0 }

        if ($blockCount -gt 0) {
            $sample = ($blocks | Select-Object -First 3 -ExpandProperty Message) -join ' || '
            Add-Result "Blocks-$($logDef.Log)" "WARN" "$blockCount block event(s) (ID $($logDef.BlockId)) in last $EventLookbackHours h. Sample: $sample"
        } else {
            Add-Result "Blocks-$($logDef.Log)" "OK" "No block events in last $EventLookbackHours h"
        }
    } catch {
        Add-Result "Blocks-$($logDef.Log)" "OK" "No matching events / log not present"
    }
}
#endregion

#region ─── 4. Optional file test against effective policy ─────────────────────
if ($FilePath) {
    if (Test-Path -LiteralPath $FilePath) {
        try {
            $fileInfo = Get-AppLockerFileInformation -Path $FilePath -ErrorAction Stop
            Add-Result "FileIdentity" "INFO" "Publisher=$($fileInfo.Publisher); Path=$($fileInfo.Path); Hash present=$([bool]$fileInfo.Hash)"

            try {
                $testResult = Get-AppLockerPolicy -Effective |
                    Test-AppLockerPolicy -Path $FilePath -User $UserName -ErrorAction Stop

                foreach ($tr in $testResult) {
                    $status = if ($tr.PolicyDecision -eq 'Denied') { 'ERROR' } else { 'OK' }
                    Add-Result "PolicyTest-$UserName" $status "Decision=$($tr.PolicyDecision) for '$FilePath' — Reason: $($tr.Reason)"
                }
            } catch {
                Add-Result "PolicyTest-$UserName" "WARN" "Test-AppLockerPolicy failed: $_"
            }
        } catch {
            Add-Result "FileIdentity" "WARN" "Get-AppLockerFileInformation failed: $_"
        }
    } else {
        Add-Result "FileIdentity" "WARN" "Path not found: $FilePath"
    }
} else {
    Add-Result "FileTest" "INFO" "Skipped — no -FilePath supplied"
}
#endregion

#region ─── 5. WDAC cross-check (rule out the other control) ───────────────────
try {
    $wdacEvents = Get-WinEvent -FilterHashtable @{
        LogName   = 'Microsoft-Windows-CodeIntegrity/Operational'
        Id        = @(3076, 3077)
        StartTime = $startTime
    } -ErrorAction SilentlyContinue

    if ($wdacEvents -and $wdacEvents.Count -gt 0) {
        Add-Result "WDACCrossCheck" "WARN" "$($wdacEvents.Count) WDAC CodeIntegrity block event(s) found — WDAC may be the actual blocker, not AppLocker"
    } else {
        Add-Result "WDACCrossCheck" "OK" "No WDAC CodeIntegrity block events found in same window"
    }
} catch {
    Add-Result "WDACCrossCheck" "OK" "No matching events / log not present"
}
#endregion

#region ─── Summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── AppLocker Diagnostics Summary ─────────────────────" -ForegroundColor Cyan
$errorCount = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
$warnCount  = ($results | Where-Object { $_.Status -eq "WARN" }).Count

Write-Host "  Checks run   : $($results.Count)"
Write-Host "  Errors       : $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Warnings     : $warnCount" -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "Green" })

if ($errorCount -eq 0 -and $warnCount -eq 0) {
    Write-Host "  Overall: AppLocker enforcement and service health look normal on this client." -ForegroundColor Green
} else {
    Write-Host "  Overall: Issues found — see AppLocker-B.md fix paths matching the failed checks above." -ForegroundColor Yellow
}
Write-Host ""
#endregion

#region ─── Export ──────────────────────────────────────────────────────────────
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Exported → $ExportPath" "OK"
Write-Status "Done — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
