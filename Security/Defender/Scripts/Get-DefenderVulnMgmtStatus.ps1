<#
.SYNOPSIS
    Audits Microsoft Defender Vulnerability Management (MDVM) prerequisite health on
    one or more devices — MDE onboarding, sensor state, software inventory collection,
    and cloud connectivity — the four things that must be true before MDVM data appears.

.DESCRIPTION
    MDVM has no local "MDVM service" of its own — every capability rides on top of the
    MDE (Sense) sensor. This script queries the local device or remote devices for:
    - Sense service state and MDE OnboardingState/OrgId registry values
    - Antivirus scan recency (QuickScanAge) as a secondary health signal
    - Installed-software inventory count via Win32_Product (a low WMI count vs. a
      known-populated Programs and Features list indicates WMI repository corruption,
      the most common cause of "0 software" in the MDVM portal)
    - Recency of the "Microsoft Compatibility Appraiser" scheduled task, one of the
      inventory feeds MDVM relies on
    - TCP 443 reachability to core MDE/MDVM cloud endpoints
    - Recent SENSE/Operational log errors

    Exports results to CSV and prints a colour-coded console summary.

    Does NOT cover:
    - Exposure score or CVE-level data — that lives only in the Defender portal
      (security.microsoft.com → Vulnerability Management), not locally queryable
    - License validation (run Get-MgUserLicenseDetail / Get-MgOrganization separately —
      requires Graph auth and is intentionally left out of this device-scoped script)
    - Remediation activity / Intune integration status (see DefenderVulnMgmt-B.md Fix 5)

.PARAMETER ComputerName
    One or more remote computer names. Defaults to the local machine if omitted.

.PARAMETER DaysBack
    Number of days of SENSE/Operational event history to scan for errors. Default: 7.

.PARAMETER OutputPath
    Path for the CSV export. Default: C:\Temp\MDVM-Status-<timestamp>.csv

.PARAMETER Credential
    Optional PSCredential for remote connections.

.PARAMETER SkipConnectivityTest
    Skip the Test-NetConnection calls to MDE/MDVM cloud endpoints.

.EXAMPLE
    .\Get-DefenderVulnMgmtStatus.ps1

.EXAMPLE
    .\Get-DefenderVulnMgmtStatus.ps1 -ComputerName PC001,PC002 -DaysBack 14

.NOTES
    Requires: Windows 10/11 or Windows Server, device onboarded to MDE (any plan);
              full MDVM feature set requires MDE P2 or the MDVM standalone add-on
    Run As: Local admin for local; equivalent rights for remote (WinRM required)
    Safe: Read-only — no onboarding, service, or inventory-refresh actions taken.
          Win32_Product enumeration is read-only via WMI but is known to trigger a
          Windows Installer self-repair/consistency check on some older MSI packages —
          this is a well-documented Win32_Product side effect, not something this
          script introduces. Skip with caution if that class of side effect is a concern
          on production servers.
    Cross-references: Security/Defender/DefenderVulnMgmt-B.md (Fix 1-6) and DefenderVulnMgmt-A.md,
                      MDE-Onboarding-B.md (if OnboardingState is not 1)
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline)]
    [string[]]$ComputerName = @($env:COMPUTERNAME),

    [int]$DaysBack = 7,

    [string]$OutputPath = "C:\Temp\MDVM-Status-$(Get-Date -Format 'yyyyMMdd-HHmm').csv",

    [PSCredential]$Credential,

    [switch]$SkipConnectivityTest
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

function Get-MDVMStatusLocal {
    param([string]$Computer, [bool]$SkipConnectivityTest, [int]$DaysBack)

    $result = [PSCustomObject]@{
        ComputerName             = $Computer
        CollectedAt              = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        SenseServiceStatus       = "Unknown"
        OnboardingState          = "Unknown"
        SenseIsRunning           = "Unknown"
        OrgId                    = "Unknown"
        QuickScanAgeDays         = "Unknown"
        Win32ProductCount        = "Unknown"
        CompatApproaiserLastRun  = "Unknown"
        Endpoint_winatpGwCus     = "Skipped"
        Endpoint_winatpGwEus     = "Skipped"
        Endpoint_eventsData      = "Skipped"
        RecentSenseErrors        = 0
        Errors                   = ""
    }

    try {
        $result.SenseServiceStatus = (Get-Service -Name "Sense" -ErrorAction Stop).Status
    } catch {
        $result.Errors += "Sense service not found — device likely not onboarded to MDE: $($_.Exception.Message); "
    }

    try {
        $reg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status" -ErrorAction Stop
        $result.OnboardingState = if ($null -ne $reg.OnboardingState) { $reg.OnboardingState } else { "Not set" }
        $result.SenseIsRunning  = if ($null -ne $reg.SenseIsRunning) { $reg.SenseIsRunning } else { "Not set" }
        $result.OrgId           = if ($reg.OrgId) { $reg.OrgId } else { "Not set" }
    } catch {
        $result.Errors += "MDE onboarding registry key not found — device not onboarded: $($_.Exception.Message); "
    }

    try {
        $mpStatus = Get-MpComputerStatus -ErrorAction Stop
        if ($mpStatus.QuickScanAge -ne $null) {
            $result.QuickScanAgeDays = $mpStatus.QuickScanAge
        }
    } catch {
        $result.Errors += "Get-MpComputerStatus failed: $($_.Exception.Message); "
    }

    try {
        $result.Win32ProductCount = (Get-CimInstance -ClassName Win32_Product -ErrorAction Stop | Measure-Object).Count
    } catch {
        $result.Errors += "Win32_Product enumeration failed: $($_.Exception.Message); "
    }

    try {
        $task = Get-ScheduledTaskInfo -TaskName "Microsoft Compatibility Appraiser" -TaskPath "\Microsoft\Windows\Application Experience\" -ErrorAction Stop
        $result.CompatApproaiserLastRun = $task.LastRunTime
    } catch {
        $result.CompatApproaiserLastRun = "Task not found or never run"
    }

    if (-not $SkipConnectivityTest) {
        $endpointMap = @{
            Endpoint_winatpGwCus = 'winatp-gw-cus.microsoft.com'
            Endpoint_winatpGwEus = 'winatp-gw-eus.microsoft.com'
            Endpoint_eventsData  = 'us-v20.events.data.microsoft.com'
        }
        foreach ($prop in $endpointMap.Keys) {
            try {
                $test = Test-NetConnection -ComputerName $endpointMap[$prop] -Port 443 -WarningAction SilentlyContinue -InformationLevel Quiet -ErrorAction Stop
                $result.$prop = if ($test) { "Reachable" } else { "UNREACHABLE" }
            } catch {
                $result.$prop = "Test failed: $($_.Exception.Message)"
            }
        }
    }

    try {
        $cutoff = (Get-Date).AddDays(-$DaysBack)
        $events = Get-WinEvent -LogName "Microsoft-Windows-SENSE/Operational" -ErrorAction SilentlyContinue |
            Where-Object { $_.TimeCreated -ge $cutoff -and $_.LevelDisplayName -eq "Error" }
        $result.RecentSenseErrors = ($events | Measure-Object).Count
    } catch {
        $result.Errors += "SENSE/Operational log read failed: $($_.Exception.Message); "
    }

    return $result
}

# ───────────────────────────────────────────────────────────────
# MAIN
# ───────────────────────────────────────────────────────────────

$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($computer in $ComputerName) {
    Write-Status "Checking MDVM prerequisite status on: $computer" "INFO"

    if ($computer -eq $env:COMPUTERNAME) {
        $res = Get-MDVMStatusLocal -Computer $computer -SkipConnectivityTest $SkipConnectivityTest.IsPresent -DaysBack $DaysBack
    } else {
        try {
            $invokeParams = @{
                ComputerName = $computer
                ScriptBlock  = ${function:Get-MDVMStatusLocal}
                ArgumentList = @($computer, $SkipConnectivityTest.IsPresent, $DaysBack)
                ErrorAction  = "Stop"
            }
            if ($Credential) { $invokeParams.Credential = $Credential }

            $res = Invoke-Command @invokeParams
            $res.PSObject.Properties.Remove("PSComputerName")
            $res.PSObject.Properties.Remove("RunspaceId")
        } catch {
            Write-Status "Cannot connect to $computer — $($_.Exception.Message)" "ERROR"
            $res = [PSCustomObject]@{
                ComputerName             = $computer
                CollectedAt              = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                SenseServiceStatus       = "N/A"
                OnboardingState          = "N/A"
                SenseIsRunning           = "N/A"
                OrgId                    = "N/A"
                QuickScanAgeDays         = "N/A"
                Win32ProductCount        = "N/A"
                CompatApproaiserLastRun  = "N/A"
                Endpoint_winatpGwCus     = "N/A"
                Endpoint_winatpGwEus     = "N/A"
                Endpoint_eventsData      = "N/A"
                RecentSenseErrors        = 0
                Errors                   = "Connection failed: $($_.Exception.Message)"
            }
        }
    }

    $allResults.Add($res)

    $flag = if ($res.OnboardingState -eq 1 -and $res.SenseServiceStatus -eq "Running") { "OK" } else { "WARN" }
    Write-Status "  Sense: $($res.SenseServiceStatus) | OnboardingState: $($res.OnboardingState) | OrgId: $($res.OrgId)" $flag

    if ($res.Win32ProductCount -is [int] -and $res.Win32ProductCount -lt 5) {
        Write-Status "  Win32_Product count suspiciously low ($($res.Win32ProductCount)) — possible WMI corruption limiting software inventory" "WARN"
    }
    if ($res.RecentSenseErrors -gt 0) {
        Write-Status "  SENSE/Operational errors in last $DaysBack days: $($res.RecentSenseErrors)" "WARN"
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

Write-Host "`n=== MDVM Prerequisite Status Summary ===" -ForegroundColor Cyan
$allResults | Format-Table ComputerName, SenseServiceStatus, OnboardingState, Win32ProductCount, RecentSenseErrors -AutoSize
