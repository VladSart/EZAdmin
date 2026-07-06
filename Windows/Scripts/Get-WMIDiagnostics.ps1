<#
.SYNOPSIS
    Collects WMI service health, repository consistency, and provider error state for triage or escalation.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/WMI-B.md.
    Gathers, in one pass, everything the runbook's triage and diagnosis steps ask for:
    - winmgmt service state
    - Basic WMI query test (Get-CimInstance Win32_OperatingSystem)
    - Repository consistency via winmgmt /verifyrepository
    - Recent WinMgmt provider error/warning counts from the Application event log
    - C: drive free space (low disk space is a known repository-corruption contributor)
    - A read-only inventory of WMI permanent event subscriptions (__EventFilter / __EventConsumer /
      __FilterToConsumerBinding) — a common malware persistence mechanism — for security review

    Produces a console summary with pass/fail per check and exports full detail to CSV, so the
    output can be pasted directly into the runbook's Escalation Evidence template.

    Does NOT cover:
    - Rebuilding the WMI repository (that's Fix 2 in WMI-B.md — destructive, requires explicit admin decision)
    - Removing WMI event subscriptions (Fix 4 — flagged for security review, never auto-removed by this script)
    - Re-registering specific providers (Fix 3 — this script only surfaces which providers are erroring)

.PARAMETER ExportPath
    Path for CSV export. Default: .\WMIDiagnostics-<timestamp>.csv
    A companion file with suffix ".subscriptions.csv" is written if any WMI event subscriptions are found.

.EXAMPLE
    .\Get-WMIDiagnostics.ps1
    Runs the full read-only sweep and exports results to CSV.

.NOTES
    Requires: Windows PowerShell 5.1+
    Run-as: Administrator recommended — root\subscription namespace and some event log queries require elevation
    Safe: Fully read-only. Does not restart winmgmt, rebuild the repository, or remove any subscriptions.
    Tested on: Windows 10 21H2+, Windows 11, domain-joined and workgroup.
#>

[CmdletBinding()]
param(
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
Write-Status "Get-WMIDiagnostics — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\WMIDiagnostics-$timestamp.csv"
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

#region ─── 1. winmgmt service state ────────────────────────────────────────────
try {
    $winmgmt = Get-Service -Name winmgmt -ErrorAction Stop
    if ($winmgmt.Status -eq 'Running') {
        Add-Result "WinMgmtService" "OK" "Running (StartType: $($winmgmt.StartType))"
    } else {
        Add-Result "WinMgmtService" "ERROR" "Status: $($winmgmt.Status) — WMI is unavailable until this service is running (Start-Service winmgmt)"
    }
} catch {
    Add-Result "WinMgmtService" "ERROR" "Could not query winmgmt service: $_"
}
#endregion

#region ─── 2. Basic WMI query test ──────────────────────────────────────────────
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    Add-Result "BasicWMIQuery" "OK" "Query succeeded: $($os.Caption), last boot $($os.LastBootUpTime)"
} catch {
    Add-Result "BasicWMIQuery" "ERROR" "Get-CimInstance Win32_OperatingSystem failed: $_ — WMI is broken or unresponsive (Fix 1)"
}
#endregion

#region ─── 3. Repository consistency check ─────────────────────────────────────
try {
    $verifyOutput = winmgmt /verifyrepository 2>&1 | Out-String
    if ($verifyOutput -match "consistent" -and $verifyOutput -notmatch "inconsistent") {
        Add-Result "RepositoryConsistency" "OK" "Repository reports consistent"
    } elseif ($verifyOutput -match "inconsistent") {
        Add-Result "RepositoryConsistency" "ERROR" "Repository reports INCONSISTENT — repository rebuild required (Fix 2). This is rare on modern Windows; check chkdsk and Windows Update history for a correlated cause first."
    } else {
        Add-Result "RepositoryConsistency" "WARN" "Unrecognized output from winmgmt /verifyrepository: $verifyOutput"
    }
} catch {
    Add-Result "RepositoryConsistency" "WARN" "Could not run winmgmt /verifyrepository: $_"
}
#endregion

#region ─── 4. Recent WinMgmt provider errors in event log ──────────────────────
try {
    $wmiEvents = Get-WinEvent -FilterHashtable @{
        LogName      = 'Application'
        ProviderName = 'WinMgmt'
        StartTime    = (Get-Date).AddHours(-4)
    } -ErrorAction SilentlyContinue

    if ($wmiEvents -and $wmiEvents.Count -gt 0) {
        $errorEvents = $wmiEvents | Where-Object { $_.LevelDisplayName -eq "Error" }
        if ($errorEvents.Count -gt 0) {
            Add-Result "WinMgmtEventErrors" "WARN" "$($errorEvents.Count) Error-level WinMgmt event(s) in last 4 hours — may indicate a provider crash loop (Fix 3). Most recent: $($errorEvents[0].TimeCreated) — $($errorEvents[0].Message.Substring(0, [Math]::Min(120, $errorEvents[0].Message.Length)))"
        } else {
            Add-Result "WinMgmtEventErrors" "INFO" "$($wmiEvents.Count) WinMgmt event(s) in last 4 hours, none at Error level"
        }
    } else {
        Add-Result "WinMgmtEventErrors" "OK" "No WinMgmt events in the last 4 hours"
    }
} catch {
    Add-Result "WinMgmtEventErrors" "WARN" "Could not query WinMgmt Application event log entries: $_"
}
#endregion

#region ─── 5. Disk space (corruption risk factor) ──────────────────────────────
try {
    $cDrive = Get-PSDrive C -ErrorAction Stop
    $freeGB = [math]::Round($cDrive.Free / 1GB, 1)
    if ($freeGB -lt 5) {
        Add-Result "DiskSpace" "WARN" "C: free space is ${freeGB}GB — below 5GB threshold flagged as a repository-corruption risk factor in the runbook"
    } else {
        Add-Result "DiskSpace" "OK" "C: free space: ${freeGB}GB"
    }
} catch {
    Add-Result "DiskSpace" "WARN" "Could not query C: drive space: $_"
}
#endregion

#region ─── 6. WMI permanent event subscription inventory (security review) ─────
$subscriptionRows = @()
try {
    $filters   = Get-WmiObject -Namespace root\subscription -Class __EventFilter -ErrorAction SilentlyContinue
    $consumers = Get-WmiObject -Namespace root\subscription -Class __EventConsumer -ErrorAction SilentlyContinue
    $bindings  = Get-WmiObject -Namespace root\subscription -Class __FilterToConsumerBinding -ErrorAction SilentlyContinue

    $filterCount   = if ($filters)   { @($filters).Count }   else { 0 }
    $consumerCount = if ($consumers) { @($consumers).Count } else { 0 }
    $bindingCount  = if ($bindings)  { @($bindings).Count }  else { 0 }

    if ($filterCount -eq 0 -and $consumerCount -eq 0 -and $bindingCount -eq 0) {
        Add-Result "WMISubscriptions" "OK" "No WMI permanent event subscriptions found in root\subscription"
    } else {
        Add-Result "WMISubscriptions" "WARN" "$filterCount filter(s), $consumerCount consumer(s), $bindingCount binding(s) found in root\subscription — review for legitimacy before assuming malicious. Do NOT remove without escalating to security if unrecognized (Fix 4)."

        foreach ($f in $filters) {
            $subscriptionRows += [PSCustomObject]@{ Type = "EventFilter"; Name = $f.Name; Detail = $f.Query }
        }
        foreach ($c in $consumers) {
            $detail = if ($c.CommandLineTemplate) { $c.CommandLineTemplate } elseif ($c.ScriptText) { $c.ScriptText } else { "(no command line / script text property)" }
            $subscriptionRows += [PSCustomObject]@{ Type = "EventConsumer"; Name = $c.Name; Detail = $detail }
        }
        foreach ($b in $bindings) {
            $subscriptionRows += [PSCustomObject]@{ Type = "FilterToConsumerBinding"; Name = "$($b.Filter) -> $($b.Consumer)"; Detail = "" }
        }
    }
} catch {
    Add-Result "WMISubscriptions" "WARN" "Could not enumerate root\subscription namespace: $_"
}
#endregion

#region ─── Summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── WMI Diagnostics Summary ─────────────────────────────" -ForegroundColor Cyan
$errorCount = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
$warnCount  = ($results | Where-Object { $_.Status -eq "WARN" }).Count

Write-Host "  Checks run   : $($results.Count)"
Write-Host "  Errors       : $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Warnings     : $warnCount" -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "Green" })

if ($errorCount -eq 0 -and $warnCount -eq 0) {
    Write-Host "  Overall: WMI service and repository look healthy on this device." -ForegroundColor Green
} else {
    Write-Host "  Overall: Issues found — cross-reference against WMI-B.md Fix 1-4." -ForegroundColor Yellow
}
Write-Host ""
#endregion

#region ─── Export ──────────────────────────────────────────────────────────────
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Exported → $ExportPath" "OK"

if ($subscriptionRows.Count -gt 0) {
    $subsPath = "$ExportPath.subscriptions.csv"
    $subscriptionRows | Export-Csv -Path $subsPath -NoTypeInformation -Encoding UTF8
    Write-Status "Subscription inventory exported → $subsPath (review for security)" "WARN"
}

Write-Status "Done — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
