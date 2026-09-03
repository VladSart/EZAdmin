<#
.SYNOPSIS
    Audits a local (or remote) machine for lingering dependencies on the deprecated
    WMIC (wmic.exe) command-line utility ahead of its 2026 full removal from Windows.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/WMICRemoval-B.md and -A.md.

    Runs a read-only sweep for:
    - Current WMIC presence/state on this machine (Feature on Demand install state)
    - OS build/version, to place the machine on Microsoft's published removal timeline
      (KB5067470: disabled-by-default 23H2/24H2, removed-on-25H2-upgrade,
      fully-removed-no-FoD-restore in the 2026 feature update)
    - Underlying WMI (Winmgmt) service health, to distinguish a genuine WMIC-removal
      issue from an unrelated WMI repository/service problem
    - Local scheduled tasks whose action executable or arguments reference "wmic"
    - Common local script directories for literal "wmic" references in .ps1/.bat/.cmd files

    Supports -ComputerName for a small set of remote machines via PowerShell remoting
    (WinRM must already be configured/reachable — this script does not configure it).

    Does NOT and CANNOT do:
    - Enumerate GPO SYSVOL logon/startup/shutdown scripts across the domain — that
      requires direct access to \\<domain>\SYSVOL and is intentionally left as a
      separate, explicit review step (see the companion -A.md runbook's Playbook 1)
      since it touches domain-wide policy content rather than a single machine
    - Modify, rewrite, or remove any WMIC reference it finds — fully read-only by design
    - Determine whether a third-party/vendor product shells out to WMIC internally
      beyond flagging its scheduled task or process footprint if one is registered

.PARAMETER ComputerName
    One or more remote computer names to audit via PowerShell remoting. Omit for local-only.

.PARAMETER ScriptSearchPath
    Additional local directory path(s) to search for "wmic" references in script files.
    Defaults to C:\Scripts and C:\ProgramData if present.

.PARAMETER ExportPath
    Path for CSV export. Default: .\WMICUsageAudit-<timestamp>.csv

.EXAMPLE
    .\Get-WMICUsageAudit.ps1
    Audits the local machine for WMIC presence, state, and dependency footprint.

.EXAMPLE
    .\Get-WMICUsageAudit.ps1 -ComputerName SRV01,SRV02 -ScriptSearchPath "D:\Automation" -ExportPath C:\Temp\wmic-audit.csv
    Audits two remote machines plus an additional script directory and exports combined results.

.NOTES
    Requires: Windows PowerShell 5.1+
    Run-as:   Administrator recommended (full scheduled-task action visibility and
              some Get-WindowsCapability detail benefit from elevation)
    Safe:     Fully read-only. No configuration changes, no WMIC install/removal performed.
    Tested on: Windows 11 (all supported versions) and Windows Server 2012 through 2025.
               Safe to run on machines where WMIC is already fully removed — will simply
               report NotPresent/absent and continue.
#>

[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [string[]]$ScriptSearchPath,
    [string]$ExportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-WMICAuditData {
    [CmdletBinding()]
    param([string[]]$SearchPaths)

    $result = [ordered]@{
        ComputerName        = $env:COMPUTERNAME
        Timestamp           = Get-Date -Format "o"
        WMICCommandFound    = $false
        WMICCapabilityState = "Unknown"
        OSBuildNumber       = $null
        WindowsVersion      = $null
        WinmgmtServiceStatus = $null
        CimBaselineOK       = $false
        ScheduledTasksWithWMIC = @()
        ScriptFileMatches   = @()
        RemovalTimelineNote = ""
    }

    # 1. WMIC command / capability presence
    $cmd = Get-Command wmic.exe -ErrorAction SilentlyContinue
    $result.WMICCommandFound = [bool]$cmd

    try {
        $cap = Get-WindowsCapability -Online -Name "WMIC*" -ErrorAction Stop
        if ($cap) { $result.WMICCapabilityState = ($cap | Select-Object -First 1).State }
    } catch {
        $result.WMICCapabilityState = "CheckFailed: $($_.Exception.Message)"
    }

    # 2. OS build/version
    try {
        $osInfo = Get-ComputerInfo -Property WindowsProductName, OsBuildNumber, WindowsVersion -ErrorAction Stop
        $result.OSBuildNumber  = $osInfo.OsBuildNumber
        $result.WindowsVersion = $osInfo.WindowsVersion
    } catch {
        $result.OSBuildNumber = "CheckFailed"
    }

    # 3. WMI service health baseline (distinguish WMIC-removal from WMI-wide issues)
    try {
        $svc = Get-Service Winmgmt -ErrorAction Stop
        $result.WinmgmtServiceStatus = $svc.Status
    } catch {
        $result.WinmgmtServiceStatus = "CheckFailed"
    }
    try {
        $null = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $result.CimBaselineOK = $true
    } catch {
        $result.CimBaselineOK = $false
    }

    # 4. Scheduled tasks referencing wmic
    try {
        $tasks = Get-ScheduledTask -ErrorAction Stop | ForEach-Object {
            $matchingActions = $_.Actions | Where-Object {
                ($_.Execute -and $_.Execute -like "*wmic*") -or
                ($_.Arguments -and $_.Arguments -like "*wmic*")
            }
            if ($matchingActions) {
                [PSCustomObject]@{
                    TaskName = $_.TaskName
                    TaskPath = $_.TaskPath
                    Execute  = ($matchingActions | Select-Object -First 1).Execute
                }
            }
        }
        $result.ScheduledTasksWithWMIC = @($tasks)
    } catch {
        Write-Status "Scheduled task enumeration failed: $($_.Exception.Message)" "WARN"
    }

    # 5. Script directory scan for literal "wmic" references
    $pathsToSearch = @()
    if ($SearchPaths) { $pathsToSearch += $SearchPaths }
    foreach ($default in @("C:\Scripts", "C:\ProgramData")) {
        if (Test-Path $default) { $pathsToSearch += $default }
    }
    $pathsToSearch = $pathsToSearch | Select-Object -Unique

    $matches = @()
    foreach ($p in $pathsToSearch) {
        if (-not (Test-Path $p)) { continue }
        try {
            $hits = Get-ChildItem -Path $p -Include *.ps1, *.bat, *.cmd -Recurse -ErrorAction SilentlyContinue |
                Select-String -Pattern "wmic" -SimpleMatch -ErrorAction SilentlyContinue
            foreach ($h in $hits) {
                $matches += [PSCustomObject]@{
                    Path       = $h.Path
                    LineNumber = $h.LineNumber
                    Line       = $h.Line.Trim()
                }
            }
        } catch {
            Write-Status "Search of $p failed: $($_.Exception.Message)" "WARN"
        }
    }
    $result.ScriptFileMatches = @($matches)

    # 6. Removal timeline note
    if (-not $result.WMICCommandFound) {
        $result.RemovalTimelineNote = "WMIC not present — either never installed as FoD, disabled-by-default (23H2/24H2), or fully removed (25H2+/2026 feature update). Cross-check OSBuildNumber."
    } elseif ($result.WMICCapabilityState -eq "Installed") {
        $result.RemovalTimelineNote = "WMIC currently present and installed. Machine has NOT yet crossed the removal line — plan remediation ahead of its next feature update."
    } else {
        $result.RemovalTimelineNote = "WMIC command resolved but capability state unclear — investigate manually."
    }

    return [PSCustomObject]$result
}

# ---- Main ----

$allResults = @()

if ($ComputerName) {
    foreach ($cn in $ComputerName) {
        Write-Status "Auditing remote machine: $cn"
        try {
            $r = Invoke-Command -ComputerName $cn -ScriptBlock ${function:Get-WMICAuditData} -ArgumentList (,$ScriptSearchPath) -ErrorAction Stop
            $allResults += $r
        } catch {
            Write-Status "Failed to audit $cn : $($_.Exception.Message)" "ERROR"
        }
    }
} else {
    Write-Status "Auditing local machine: $env:COMPUTERNAME"
    $allResults += Get-WMICAuditData -SearchPaths $ScriptSearchPath
}

# ---- Report ----
foreach ($r in $allResults) {
    Write-Host ""
    Write-Status "=== $($r.ComputerName) ===" "INFO"
    Write-Status "WMIC command found: $($r.WMICCommandFound) | Capability state: $($r.WMICCapabilityState)" $(if ($r.WMICCommandFound) { "WARN" } else { "OK" })
    Write-Status "OS Build: $($r.OSBuildNumber) ($($r.WindowsVersion))" "INFO"
    Write-Status "Winmgmt service: $($r.WinmgmtServiceStatus) | CIM baseline OK: $($r.CimBaselineOK)" $(if ($r.CimBaselineOK) { "OK" } else { "ERROR" })
    Write-Status $r.RemovalTimelineNote "INFO"
    if ($r.ScheduledTasksWithWMIC.Count -gt 0) {
        Write-Status "$($r.ScheduledTasksWithWMIC.Count) scheduled task(s) reference wmic — remediate these first (widest blast radius):" "WARN"
        $r.ScheduledTasksWithWMIC | ForEach-Object { Write-Host "    - $($_.TaskPath)$($_.TaskName)" }
    }
    if ($r.ScriptFileMatches.Count -gt 0) {
        Write-Status "$($r.ScriptFileMatches.Count) script file line(s) reference wmic:" "WARN"
        $r.ScriptFileMatches | Select-Object -First 10 | ForEach-Object { Write-Host "    - $($_.Path):$($_.LineNumber)" }
        if ($r.ScriptFileMatches.Count -gt 10) { Write-Host "    ... and $($r.ScriptFileMatches.Count - 10) more (see CSV export)" }
    }
}

# ---- Export ----
if (-not $ExportPath) {
    $ExportPath = ".\WMICUsageAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
}
$flatExport = foreach ($r in $allResults) {
    [PSCustomObject]@{
        ComputerName            = $r.ComputerName
        Timestamp               = $r.Timestamp
        WMICCommandFound        = $r.WMICCommandFound
        WMICCapabilityState     = $r.WMICCapabilityState
        OSBuildNumber            = $r.OSBuildNumber
        WindowsVersion           = $r.WindowsVersion
        WinmgmtServiceStatus     = $r.WinmgmtServiceStatus
        CimBaselineOK            = $r.CimBaselineOK
        ScheduledTaskCount       = $r.ScheduledTasksWithWMIC.Count
        ScriptFileMatchCount     = $r.ScriptFileMatches.Count
        RemovalTimelineNote      = $r.RemovalTimelineNote
    }
}
$flatExport | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Host ""
Write-Status "Summary CSV exported: $ExportPath" "OK"
Write-Status "NOTE: this script does not enumerate domain GPO SYSVOL logon scripts — review those separately (see WMICRemoval-A.md Playbook 1) since a single GPO script fix has org-wide blast radius." "WARN"
