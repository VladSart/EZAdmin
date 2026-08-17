<#
.SYNOPSIS
    Audits Storage Migration Service (SMS) readiness and health on an orchestrator, source,
    or destination computer — service state, firewall prerequisites, admin-rights hints,
    patch level for the two documented ACL-fidelity defects, long-path support, and
    Domain-Controller cutover eligibility.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/StorageMigrationService-B.md and
    StorageMigrationService-A.md. Run this on the ORCHESTRATOR for a general health check,
    or on a SOURCE/DESTINATION computer to validate its half of the prerequisite chain.

    Checks performed:
    - Storage Migration Service / Storage Migration Service Proxy service state
    - Recent Storage Migration Service Admin event log entries (top errors surfaced first)
    - Recent Storage Migration Service Proxy Debug log entries, flagged specifically for the
      "(5) Access is denied" backup-privilege-defect signature (KB4490481)
    - Patch level for KB4490481 (backup-privilege defect) and KB4512534 (ACL-ordering /
      cutover-token-filter-policy defect)
    - LongPathsEnabled registry state (required for source paths over 260 characters)
    - The four role-specific inbound firewall rules (SMB-In / NP-In / DCOM-In / WMI-In on
      source+destination; SMB-In only on the orchestrator)
    - Domain Controller check via Win32_OperatingSystem.ProductType — flags this computer as
      CUTOVER-INELIGIBLE if it is a DC (including SBS/Server Essentials editions), since SMS
      cutover is permanently unsupported from a domain controller

    Produces a console summary with pass/fail/flag per check and exports full detail to CSV.

    Does NOT cover:
    - Fixing any detected issue (that's StorageMigrationService-B.md Fix 1-9 / -A.md Playbooks 1-4)
    - Actually running or monitoring a live inventory/transfer/cutover job (use Get-SmsState for
      that, called out directly in the runbooks' Fix 9 / Command Cheat Sheet)
    - Fleet-wide/multi-server auditing — this is a single-machine diagnostic; run it once per
      role (orchestrator, each source, each destination) involved in a migration
    - DFS Replication's own preseeding validation — see Get-DFSRBacklog.ps1 and
      DFS/Troubleshooting/Replication/Replication-A.md for that half of the ACL-ordering defect

.PARAMETER Role
    Which role this computer plays in the migration: Orchestrator, Source, Destination, or All
    (checks every role-relevant item — useful for a single-server migration where the
    destination doubles as its own orchestrator). Default: All

.PARAMETER RemoteTarget
    Optional FQDN of a source or destination computer to test WMI (135) and SMB (445)
    reachability against from this machine, matching the runbooks' Diagnosis Step 4.

.PARAMETER ExportPath
    Path for CSV export. Default: .\SMSHealth-<timestamp>.csv

.EXAMPLE
    .\Get-StorageMigrationServiceAudit.ps1
    Runs every check relevant to any role on the local machine.

.EXAMPLE
    .\Get-StorageMigrationServiceAudit.ps1 -Role Orchestrator -RemoteTarget fileserver01.contoso.com
    Audits orchestrator-specific prerequisites and tests reachability to a named source/destination.

.EXAMPLE
    .\Get-StorageMigrationServiceAudit.ps1 -Role Source
    Audits this machine as a migration source, including the Domain-Controller cutover-eligibility flag.

.NOTES
    Requires: Windows PowerShell 5.1+
    Run-as: Administrator recommended (event log, hotfix, and some registry reads need elevation)
    Safe: Fully read-only. No service/firewall/registry changes, no migration job actions.
    Tested on: Windows Server 2016+ (orchestrator/destination), Windows Server 2003+ (source, where PowerShell is present)
#>

[CmdletBinding()]
param(
    [ValidateSet("Orchestrator", "Source", "Destination", "All")]
    [string]$Role = "All",

    [string]$RemoteTarget,

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
Write-Status "Get-StorageMigrationServiceAudit — $(Get-Date -Format 'yyyy-MM-dd HH:mm') — Role: $Role"

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\SMSHealth-$timestamp.csv"
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param([string]$Check, [string]$Status, [string]$Detail)
    $results.Add([PSCustomObject]@{
        Check     = $Check
        Status    = $Status
        Detail    = $Detail
        Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    })
    Write-Status "$Check — $Detail" -Status $Status
}
#endregion

#region ─── Service State ──────────────────────────────────────────────────────
Write-Status "--- Service State ---"

$smsService = Get-Service -Name "Storage Migration Service" -ErrorAction SilentlyContinue
if ($smsService) {
    $status = if ($smsService.Status -eq 'Running') { "OK" } else { "WARN" }
    Add-Result -Check "Storage Migration Service" -Status $status -Detail "Status=$($smsService.Status), StartType=$($smsService.StartType)"
} else {
    Add-Result -Check "Storage Migration Service" -Status "INFO" -Detail "Not installed on this computer (expected unless this is the orchestrator)"
}

$proxyService = Get-Service -Name "Storage Migration Service Proxy" -ErrorAction SilentlyContinue
if ($proxyService) {
    $status = if ($proxyService.Status -eq 'Running') { "OK" } else { "WARN" }
    Add-Result -Check "Storage Migration Service Proxy" -Status $status -Detail "Status=$($proxyService.Status) — WS2019+ destination proxy, ~2x transfer speed vs. proxy-less"
} else {
    Add-Result -Check "Storage Migration Service Proxy" -Status "INFO" -Detail "Not installed — expected on WS2016/2012 R2 destinations or if not yet configured on a WS2019+ box"
}
#endregion

#region ─── Event Logs ─────────────────────────────────────────────────────────
if ($Role -in @("Orchestrator", "All")) {
    Write-Status "--- SMS Admin Event Log (top 15) ---"
    try {
        $adminEvents = Get-WinEvent -LogName "Microsoft-Windows-StorageMigrationService/Admin" -MaxEvents 15 -ErrorAction Stop
        foreach ($evt in $adminEvents) {
            $status = if ($evt.LevelDisplayName -in @("Error", "Critical")) { "WARN" } else { "INFO" }
            Add-Result -Check "SMS Admin Event $($evt.Id)" -Status $status -Detail "$($evt.TimeCreated) — $($evt.LevelDisplayName) — $($evt.Message.Substring(0, [Math]::Min(150, $evt.Message.Length)))"
        }
        if (-not $adminEvents) { Add-Result -Check "SMS Admin Event Log" -Status "INFO" -Detail "No events found" }
    } catch {
        Add-Result -Check "SMS Admin Event Log" -Status "INFO" -Detail "Log not present or not accessible on this computer"
    }
}

if ($proxyService) {
    Write-Status "--- SMS Proxy Debug Log — scanning for the backup-privilege-defect signature ---"
    try {
        $proxyErrors = Get-WinEvent -LogName "Microsoft-Windows-StorageMigrationService-Proxy/Debug" -MaxEvents 200 -ErrorAction Stop |
            Where-Object { $_.LevelDisplayName -eq "Error" }
        $accessDeniedHits = $proxyErrors | Where-Object { $_.Message -match "Access is denied" }
        if ($accessDeniedHits) {
            Add-Result -Check "Proxy Debug — (5) Access is denied signature" -Status "WARN" `
                -Detail "$($accessDeniedHits.Count) hit(s) found — likely the pre-KB4490481 backup-privilege defect. Files with a removed Administrators-group ACE may be silently missing from the destination. See Fix 7."
        } elseif ($proxyErrors) {
            Add-Result -Check "Proxy Debug — (5) Access is denied signature" -Status "OK" -Detail "$($proxyErrors.Count) proxy error(s) found, none matching the backup-privilege-defect signature"
        } else {
            Add-Result -Check "Proxy Debug — (5) Access is denied signature" -Status "OK" -Detail "No proxy errors found"
        }
    } catch {
        Add-Result -Check "Proxy Debug Log" -Status "INFO" -Detail "Log not present or not accessible on this computer"
    }
}
#endregion

#region ─── Patch Level for Documented Defects ─────────────────────────────────
Write-Status "--- Patch Level (documented ACL-fidelity defects) ---"

foreach ($kb in @("KB4490481", "KB4512534")) {
    $hotfix = Get-HotFix -Id $kb -ErrorAction SilentlyContinue
    if ($hotfix) {
        Add-Result -Check "Patch $kb" -Status "OK" -Detail "Installed ($($hotfix.InstalledOn))"
    } else {
        $desc = if ($kb -eq "KB4490481") { "backup-privilege defect — files with a removed Administrators ACE may silently fail to transfer" }
                else { "ACL-ordering defect — breaks DFSR preseeding hash comparison; also the 'token filter policy' cutover-validation error" }
        Add-Result -Check "Patch $kb" -Status "WARN" -Detail "NOT detected directly (may be superseded by a later cumulative update — verify before assuming exposure). Risk if genuinely missing: $desc"
    }
}
#endregion

#region ─── Long Path Support ──────────────────────────────────────────────────
Write-Status "--- Long Path Support ---"

$longPaths = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name LongPathsEnabled -ErrorAction SilentlyContinue
if ($longPaths -and $longPaths.LongPathsEnabled -eq 1) {
    Add-Result -Check "LongPathsEnabled" -Status "OK" -Detail "Enabled — paths over 260 characters are supported"
} else {
    Add-Result -Check "LongPathsEnabled" -Status "WARN" -Detail "Disabled or absent — any source path over 260 characters will fail inventory/transfer with a path-related error"
}
#endregion

#region ─── Firewall Rules ─────────────────────────────────────────────────────
Write-Status "--- Firewall Rules ---"

if ($Role -in @("Orchestrator", "All")) {
    $orchRule = Get-NetFirewallRule -DisplayName "File and Printer Sharing (SMB-In)" -ErrorAction SilentlyContinue
    if ($orchRule) {
        $enabledCount = ($orchRule | Where-Object Enabled -eq $true).Count
        $status = if ($enabledCount -gt 0) { "OK" } else { "WARN" }
        Add-Result -Check "Orchestrator: SMB-In rule" -Status $status -Detail "$enabledCount of $($orchRule.Count) profile instance(s) enabled"
    } else {
        Add-Result -Check "Orchestrator: SMB-In rule" -Status "WARN" -Detail "Rule not found"
    }
}

if ($Role -in @("Source", "Destination", "All")) {
    $requiredRules = @(
        "File and Printer Sharing (SMB-In)",
        "Netlogon Service (NP-In)",
        "Windows Management Instrumentation (DCOM-In)",
        "Windows Management Instrumentation (WMI-In)"
    )
    foreach ($ruleName in $requiredRules) {
        $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        if ($rule) {
            $enabledCount = ($rule | Where-Object Enabled -eq $true).Count
            $status = if ($enabledCount -gt 0) { "OK" } else { "WARN" }
            Add-Result -Check "Source/Dest: $ruleName" -Status $status -Detail "$enabledCount of $($rule.Count) profile instance(s) enabled"
        } else {
            Add-Result -Check "Source/Dest: $ruleName" -Status "WARN" -Detail "Rule not found"
        }
    }
}
#endregion

#region ─── Domain Controller / Cutover Eligibility ────────────────────────────
if ($Role -in @("Source", "All")) {
    Write-Status "--- Cutover Eligibility (Domain Controller check) ---"
    $os = Get-CimInstance Win32_OperatingSystem
    if ($os.ProductType -eq 2) {
        Add-Result -Check "Cutover eligibility" -Status "WARN" `
            -Detail "This computer IS a Domain Controller (ProductType=2) — includes SBS/Server Essentials editions even if they don't visually present as a DC. SMS Inventory/Transfer are fully supported; CUTOVER IS NOT SUPPORTED. Plan a manual identity/DNS cutover instead (see -A.md Playbook 3)."
    } else {
        Add-Result -Check "Cutover eligibility" -Status "OK" -Detail "Not a Domain Controller (ProductType=$($os.ProductType)) — SMS cutover is supported from this source, subject to same-domain-with-destination recommendation"
    }
}
#endregion

#region ─── Optional Reachability Test ─────────────────────────────────────────
if ($RemoteTarget) {
    Write-Status "--- Reachability Test: $RemoteTarget ---"
    foreach ($portTest in @(@{Port = 135; Purpose = "WMI/DCOM (inventory)"}, @{Port = 445; Purpose = "SMB (transfer)"})) {
        try {
            $test = Test-NetConnection -ComputerName $RemoteTarget -Port $portTest.Port -WarningAction SilentlyContinue -ErrorAction Stop
            $status = if ($test.TcpTestSucceeded) { "OK" } else { "WARN" }
            Add-Result -Check "Reachability: $RemoteTarget port $($portTest.Port)" -Status $status -Detail "$($portTest.Purpose) — TcpTestSucceeded=$($test.TcpTestSucceeded)"
        } catch {
            Add-Result -Check "Reachability: $RemoteTarget port $($portTest.Port)" -Status "WARN" -Detail "Test failed: $($_.Exception.Message)"
        }
    }
}
#endregion

#region ─── Summary + Export ───────────────────────────────────────────────────
Write-Status "--- Summary ---"
$okCount    = ($results | Where-Object Status -eq "OK").Count
$warnCount  = ($results | Where-Object Status -eq "WARN").Count
$infoCount  = ($results | Where-Object Status -eq "INFO").Count

Write-Status "OK: $okCount | WARN: $warnCount | INFO: $infoCount" -Status $(if ($warnCount -gt 0) { "WARN" } else { "OK" })

$results | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Full detail exported to $ExportPath" -Status "OK"

if ($warnCount -gt 0) {
    Write-Status "Review WARN items above before starting or continuing a migration job." -Status "WARN"
}
#endregion
