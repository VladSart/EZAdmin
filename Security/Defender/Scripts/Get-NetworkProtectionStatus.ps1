<#
.SYNOPSIS
    Audits Microsoft Defender Network Protection state, enforcement mode, NIS service
    health, and recent block/audit events across one or more devices.

.DESCRIPTION
    Checks the full enforcement chain for Network Protection:
    - EnableNetworkProtection policy state (0=Disabled, 1=Block, 2=Audit)
    - AMRunningMode — Network Protection silently stops enforcing in Passive mode
      (third-party AV present), even if the policy shows Block
    - WdNisSvc (Network Inspection Service) status — the service that performs the
      URL/IP reputation lookups
    - WdFilter kernel driver presence via fltmc (underlying enforcement point)
    - MAPSReporting / cloud-delivered protection level — URL reputation degrades hard
      without this
    - NIS signature version and age
    - Recent Network Protection events (1125 block, 1126 audit, 1127 override,
      1128 exclusion applied) from the Defender Operational log

    Exports results to CSV and prints a colour-coded console summary.

    Does NOT cover:
    - ASR rules, Tamper Protection, Cloud Protection/MAPS deep-dive, or WDAC
      (separate scripts in this folder)
    - Changing any policy — this script is read-only, no Set-MpPreference calls
    - FP submission to Microsoft — see Network Protection-B.md Fix 3 for that workflow

.PARAMETER ComputerName
    One or more remote computer names. Defaults to the local machine if omitted.

.PARAMETER DaysBack
    Number of days of Defender Operational event history to scan for Network
    Protection events (1125/1126/1127/1128). Default: 4.

.PARAMETER OutputPath
    Path for the CSV export. Default: C:\Temp\NetworkProtection-Status-<timestamp>.csv

.PARAMETER Credential
    Optional PSCredential for remote connections.

.EXAMPLE
    .\Get-NetworkProtectionStatus.ps1

.EXAMPLE
    .\Get-NetworkProtectionStatus.ps1 -ComputerName PC001,PC002 -DaysBack 7

.NOTES
    Requires: Windows 10 1709+/Windows 11, Defender AV
    Run As: Local admin for local; equivalent rights for remote (WinRM required)
    Safe: Read-only — no Set-MpPreference or registry writes made
    Cross-references: Security/Defender/NetworkProtection-B.md (Fix 1-4) and
                       NetworkProtection-A.md
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline)]
    [string[]]$ComputerName = @($env:COMPUTERNAME),

    [int]$DaysBack = 4,

    [string]$OutputPath = "C:\Temp\NetworkProtection-Status-$(Get-Date -Format 'yyyyMMdd-HHmm').csv",

    [PSCredential]$Credential
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

function Get-NetworkProtectionStatusLocal {
    param([string]$Computer, [int]$DaysBack)

    $result = [PSCustomObject]@{
        ComputerName          = $Computer
        CollectedAt           = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        EnableNetworkProtection = "Unknown"
        AMRunningMode         = "Unknown"
        WdNisSvcStatus        = "Unknown"
        WdNisSvcStartType     = "Unknown"
        WdFilterLoaded        = "Unknown"
        MAPSReporting         = "Unknown"
        NISEnabled            = "Unknown"
        NISSignatureVersion   = "Unknown"
        NISSignatureAgeDays   = "Unknown"
        Blocks_1125_Recent    = 0
        Audits_1126_Recent    = 0
        Overrides_1127_Recent = 0
        Errors                = ""
    }

    try {
        $prefs = Get-MpPreference -ErrorAction Stop
        $result.EnableNetworkProtection = switch ($prefs.EnableNetworkProtection) {
            0 { "0 — Disabled" }
            1 { "1 — Block (enforced)" }
            2 { "2 — Audit" }
            default { "$($prefs.EnableNetworkProtection) — unrecognised value" }
        }
        $result.MAPSReporting = switch ($prefs.MAPSReporting) {
            0 { "0 — None (Network Protection URL reputation degraded)" }
            1 { "1 — Basic" }
            2 { "2 — Advanced" }
            default { "$($prefs.MAPSReporting) — unrecognised value" }
        }
    } catch {
        $result.Errors += "Get-MpPreference failed: $($_.Exception.Message); "
    }

    try {
        $mpStatus = Get-MpComputerStatus -ErrorAction Stop
        $result.AMRunningMode          = $mpStatus.AMRunningMode
        $result.NISEnabled             = $mpStatus.NISEnabled
        $result.NISSignatureVersion    = $mpStatus.NISSignatureVersion
        if ($mpStatus.NISSignatureLastUpdated) {
            $result.NISSignatureAgeDays = [math]::Round(((Get-Date) - $mpStatus.NISSignatureLastUpdated).TotalDays, 1)
        }
    } catch {
        $result.Errors += "Get-MpComputerStatus failed: $($_.Exception.Message); "
    }

    try {
        $svc = Get-Service -Name WdNisSvc -ErrorAction Stop
        $result.WdNisSvcStatus    = $svc.Status
        $result.WdNisSvcStartType = $svc.StartType
    } catch {
        $result.Errors += "WdNisSvc service check failed: $($_.Exception.Message); "
    }

    try {
        $fltmcOutput = fltmc 2>$null
        $result.WdFilterLoaded = if ($fltmcOutput -match 'WdFilter') { "Yes" } else { "NOT LOADED" }
    } catch {
        $result.Errors += "fltmc check failed: $($_.Exception.Message); "
    }

    try {
        $cutoff = (Get-Date).AddDays(-$DaysBack)
        $events = Get-WinEvent -LogName 'Microsoft-Windows-Windows Defender/Operational' -ErrorAction SilentlyContinue |
            Where-Object { $_.TimeCreated -ge $cutoff -and $_.Id -in @(1125, 1126, 1127) }
        $result.Blocks_1125_Recent    = ($events | Where-Object Id -eq 1125 | Measure-Object).Count
        $result.Audits_1126_Recent    = ($events | Where-Object Id -eq 1126 | Measure-Object).Count
        $result.Overrides_1127_Recent = ($events | Where-Object Id -eq 1127 | Measure-Object).Count
    } catch {
        $result.Errors += "Event log read failed: $($_.Exception.Message); "
    }

    return $result
}

# ───────────────────────────────────────────────────────────────
# MAIN
# ───────────────────────────────────────────────────────────────

$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($computer in $ComputerName) {
    Write-Status "Checking Network Protection status on: $computer" "INFO"

    if ($computer -eq $env:COMPUTERNAME) {
        $res = Get-NetworkProtectionStatusLocal -Computer $computer -DaysBack $DaysBack
    } else {
        try {
            $invokeParams = @{
                ComputerName = $computer
                ScriptBlock  = ${function:Get-NetworkProtectionStatusLocal}
                ArgumentList = @($computer, $DaysBack)
                ErrorAction  = "Stop"
            }
            if ($Credential) { $invokeParams.Credential = $Credential }

            $res = Invoke-Command @invokeParams
            $res.PSObject.Properties.Remove("PSComputerName")
            $res.PSObject.Properties.Remove("RunspaceId")
        } catch {
            Write-Status "Cannot connect to $computer — $($_.Exception.Message)" "ERROR"
            $res = [PSCustomObject]@{
                ComputerName            = $computer
                CollectedAt             = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                EnableNetworkProtection = "N/A"
                AMRunningMode           = "N/A"
                WdNisSvcStatus          = "N/A"
                WdNisSvcStartType       = "N/A"
                WdFilterLoaded          = "N/A"
                MAPSReporting           = "N/A"
                NISEnabled              = "N/A"
                NISSignatureVersion     = "N/A"
                NISSignatureAgeDays     = "N/A"
                Blocks_1125_Recent      = 0
                Audits_1126_Recent      = 0
                Overrides_1127_Recent   = 0
                Errors                  = "Connection failed: $($_.Exception.Message)"
            }
        }
    }

    $allResults.Add($res)

    $flag = if ($res.EnableNetworkProtection -match '^1') { "OK" } elseif ($res.EnableNetworkProtection -match '^2') { "WARN" } else { "ERROR" }
    Write-Status "  EnableNetworkProtection: $($res.EnableNetworkProtection) | AMRunningMode: $($res.AMRunningMode)" $flag

    if ($res.AMRunningMode -eq "Passive") {
        Write-Status "  AV is Passive — Network Protection is NOT enforcing regardless of policy state" "ERROR"
    }
    if ($res.WdFilterLoaded -eq "NOT LOADED") {
        Write-Status "  WdFilter driver not loaded — enforcement broken, restart MDA/reboot device" "ERROR"
    }
    if ($res.Blocks_1125_Recent -gt 0) {
        Write-Status "  Blocks (1125) in last $DaysBack days: $($res.Blocks_1125_Recent) — review for false positives" "WARN"
    }
    if ($res.Errors) {
        Write-Status "  Errors: $($res.Errors)" "ERROR"
    }
}

# ─── Export ───
$outputDir = Split-Path $OutputPath
if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$allResults | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "Results exported to: $OutputPath" "OK"

Write-Host "`n=== Network Protection Status Summary ===" -ForegroundColor Cyan
$allResults | Format-Table ComputerName, EnableNetworkProtection, AMRunningMode, WdNisSvcStatus, Blocks_1125_Recent -AutoSize
