<#
.SYNOPSIS
    Audits Tamper Protection state, management source, and recent tamper-block events
    across one or more devices.

.DESCRIPTION
    Queries the local device or remote devices for:
    - Current Tamper Protection state and management source (ATP/MDE, MDM/Intune, Locally managed)
    - MDE onboarding state (Tamper Protection managed via MDE cannot be overridden locally)
    - Recent Tamper Protection block events (Event ID 5013) with the offending process name
    - Whether legacy DisableAntiSpyware/DisableRealtimeMonitoring registry keys are present
      but being silently reverted (a common RMM/GPO troubleshooting dead end)
    - Live Defender AV state (RealTimeProtectionEnabled, AntivirusEnabled) for cross-check

    Exports results to CSV and prints a colour-coded console summary.

    Does NOT cover:
    - Toggling Tamper Protection itself — this is deliberately read-only; changes must go
      through security.microsoft.com (MDE-managed) or Intune (MDM-managed), see Fix 1/Fix 2
      in Tamper-Protection-B.md
    - AppLocker/WDAC state (separate scripts)

.PARAMETER ComputerName
    One or more remote computer names. Defaults to the local machine if omitted.

.PARAMETER DaysBack
    Number of days of Tamper Protection event history to retrieve. Default: 7.

.PARAMETER OutputPath
    Path for the CSV export. Default: C:\Temp\TamperProtection-Status-<timestamp>.csv

.PARAMETER Credential
    Optional PSCredential for remote connections.

.EXAMPLE
    .\Get-TamperProtectionStatus.ps1

.EXAMPLE
    .\Get-TamperProtectionStatus.ps1 -ComputerName PC001,PC002 -DaysBack 14

.NOTES
    Requires: Windows 10/11, Defender AV
    Run As: Local admin for local; equivalent rights for remote (WinRM required)
    Safe: Read-only — attempts a Set-MpPreference test toggle to confirm blocking behaviour,
          but immediately reverts via try/catch (the call fails when Tamper Protection is on,
          so nothing is actually changed in the common case)
    Cross-references: Security/Defender/Tamper-Protection-B.md (Fix 1-5)
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline)]
    [string[]]$ComputerName = @($env:COMPUTERNAME),

    [int]$DaysBack = 7,

    [string]$OutputPath = "C:\Temp\TamperProtection-Status-$(Get-Date -Format 'yyyyMMdd-HHmm').csv",

    [PSCredential]$Credential,

    [switch]$SkipWriteTest
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

function Get-TamperStatusLocal {
    param([string]$Computer, [bool]$SkipWriteTest, [int]$DaysBack)

    $result = [PSCustomObject]@{
        ComputerName          = $Computer
        CollectedAt           = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        IsTamperProtected     = "Unknown"
        TamperProtectionSource= "Unknown"
        MDEOnboarded          = "Unknown"
        RealTimeProtOn        = "Unknown"
        AntivirusEnabled      = "Unknown"
        LegacyDisableKeySet   = "Unknown"
        WriteTestResult       = "Skipped"
        TamperBlockEvents5013 = 0
        RecentBlockedProcesses= "None"
        Errors                = ""
    }

    try {
        $mpStatus = Get-MpComputerStatus -ErrorAction Stop
        $result.IsTamperProtected      = $mpStatus.IsTamperProtected
        $result.TamperProtectionSource = if ($mpStatus.PSObject.Properties.Name -contains "TamperProtectionSource") { $mpStatus.TamperProtectionSource } else { "N/A (older Windows build)" }
        $result.RealTimeProtOn         = $mpStatus.RealTimeProtectionEnabled
        $result.AntivirusEnabled       = $mpStatus.AntivirusEnabled
    } catch {
        $result.Errors += "Get-MpComputerStatus failed: $($_.Exception.Message); "
    }

    try {
        $mdeKey = "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status"
        if (Test-Path $mdeKey) {
            $onboarding = (Get-ItemProperty $mdeKey -EA SilentlyContinue).OnboardingState
            $result.MDEOnboarded = switch ($onboarding) { 1 {"Yes"} 0 {"No"} default {"Unknown ($onboarding)"} }
        } else {
            $result.MDEOnboarded = "No (key not present)"
        }
    } catch {
        $result.Errors += "MDE onboarding check failed: $($_.Exception.Message); "
    }

    try {
        $defenderKey = "HKLM:\SOFTWARE\Microsoft\Windows Defender"
        $props = Get-ItemProperty $defenderKey -EA SilentlyContinue
        $legacySet = ($props.DisableAntiSpyware -eq 1) -or ($props.DisableRealtimeMonitoring -eq 1)
        $result.LegacyDisableKeySet = if ($legacySet) { "Yes — check if Defender still active (Tamper likely reverting it)" } else { "No" }
    } catch {
        $result.Errors += "Legacy key check failed: $($_.Exception.Message); "
    }

    if (-not $SkipWriteTest) {
        try {
            $originalValue = (Get-MpPreference -EA SilentlyContinue).DisableRealtimeMonitoring
            try {
                Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
                # If this succeeds, Tamper Protection is OFF or not enforcing this setting — revert immediately
                Set-MpPreference -DisableRealtimeMonitoring ([bool]$originalValue) -ErrorAction SilentlyContinue
                $result.WriteTestResult = "ACCEPTED — Tamper Protection did not block the change (may be OFF)"
            } catch {
                $result.WriteTestResult = "BLOCKED — Tamper Protection is actively enforcing (expected/healthy state)"
            }
        } catch {
            $result.WriteTestResult = "Test inconclusive: $($_.Exception.Message)"
        }
    }

    try {
        $cutoff = (Get-Date).AddDays(-$DaysBack)
        $events = Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -ErrorAction SilentlyContinue |
            Where-Object { $_.TimeCreated -ge $cutoff -and $_.Id -eq 5013 }

        $result.TamperBlockEvents5013 = ($events | Measure-Object).Count

        $recent = $events | Sort-Object TimeCreated -Descending | Select-Object -First 5 |
            ForEach-Object {
                $msg = ($_.Message -split "`n" | Select-Object -First 1)
                "$($_.TimeCreated.ToString('yyyy-MM-dd HH:mm')) — $msg"
            }
        $result.RecentBlockedProcesses = if ($recent) { $recent -join " ;; " } else { "None in last $DaysBack days" }

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
    Write-Status "Checking Tamper Protection status on: $computer" "INFO"

    if ($computer -eq $env:COMPUTERNAME) {
        $res = Get-TamperStatusLocal -Computer $computer -SkipWriteTest $SkipWriteTest.IsPresent -DaysBack $DaysBack
    } else {
        try {
            $invokeParams = @{
                ComputerName = $computer
                ScriptBlock  = ${function:Get-TamperStatusLocal}
                ArgumentList = @($computer, $SkipWriteTest.IsPresent, $DaysBack)
                ErrorAction  = "Stop"
            }
            if ($Credential) { $invokeParams.Credential = $Credential }

            $res = Invoke-Command @invokeParams
            $res.PSObject.Properties.Remove("PSComputerName")
            $res.PSObject.Properties.Remove("RunspaceId")
        } catch {
            Write-Status "Cannot connect to $computer — $($_.Exception.Message)" "ERROR"
            $res = [PSCustomObject]@{
                ComputerName           = $computer
                CollectedAt            = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                IsTamperProtected      = "N/A"
                TamperProtectionSource = "N/A"
                MDEOnboarded           = "N/A"
                RealTimeProtOn         = "N/A"
                AntivirusEnabled       = "N/A"
                LegacyDisableKeySet    = "N/A"
                WriteTestResult        = "N/A"
                TamperBlockEvents5013  = 0
                RecentBlockedProcesses = "N/A"
                Errors                 = "Connection failed: $($_.Exception.Message)"
            }
        }
    }

    $allResults.Add($res)

    $flag = if ($res.IsTamperProtected -eq $true) { "OK" } else { "WARN" }
    Write-Status "  Tamper Protected: $($res.IsTamperProtected) | Source: $($res.TamperProtectionSource) | MDE Onboarded: $($res.MDEOnboarded)" $flag

    if ($res.TamperBlockEvents5013 -gt 0) {
        Write-Status "  Tamper block events (ID 5013) in last $DaysBack days: $($res.TamperBlockEvents5013)" "WARN"
    }
    if ($res.LegacyDisableKeySet -match "^Yes") {
        Write-Status "  Legacy DisableAntiSpyware/DisableRealtimeMonitoring key is set — likely being silently reverted" "WARN"
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

Write-Host "`n=== Tamper Protection Status Summary ===" -ForegroundColor Cyan
$allResults | Format-Table ComputerName, IsTamperProtected, TamperProtectionSource, MDEOnboarded, TamperBlockEvents5013 -AutoSize
