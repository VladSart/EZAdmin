<#
.SYNOPSIS
    Audits Microsoft Defender for Cloud Apps (MDA) integration health on one or more
    endpoints — MDE-to-MDA traffic forwarding, MDE onboarding/health prerequisites,
    and reachability to the MDA proxy domain.

.DESCRIPTION
    MDA has no local client service of its own (unlike MDE/AV) — its two main data
    paths are the MDE sensor forwarding signals, and Conditional Access App Control
    (CAAC) proxying browser sessions through *.mcas.ms. This script checks the parts
    of that chain that are actually visible from the endpoint:
    - ForwardCloudAppTraffic policy value (governs MDE → MDA Cloud Discovery data flow)
    - MDE onboarding/health state, since MDA signal quality depends on MDE being healthy
    - Reachability to *.mcas.ms and portal.cloudappsecurity.com (proxy/API endpoints)
    - Recent WinDefend/Sense-related event log errors that would explain missing signals

    It does NOT and cannot check (these are cloud/portal-side only — see MDA-B.md and
    MDA-A.md for portal-side triage):
    - MDA policy configuration, alerts, or Cloud Discovery data itself
    - CA session policy application (verify via sign-in logs / Entra sign-in log, not
      from the endpoint)
    - App connector / OAuth health for SaaS app connectors (no endpoint signal exists)
    - Licensing (requires Microsoft Graph — use Get-MgSubscribedSku separately)

    Exports results to CSV and prints a colour-coded console summary.

.PARAMETER ComputerName
    One or more remote computer names. Defaults to the local machine if omitted.

.PARAMETER OutputPath
    Path for the CSV export. Default: C:\Temp\MDA-Status-<timestamp>.csv

.PARAMETER Credential
    Optional PSCredential for remote connections.

.PARAMETER SkipConnectivityTest
    Skip the Test-NetConnection calls to MDA endpoints.

.EXAMPLE
    .\Get-MDAStatus.ps1

.EXAMPLE
    .\Get-MDAStatus.ps1 -ComputerName PC001,PC002 -OutputPath "C:\Reports\MDA.csv"

.NOTES
    Requires: Windows 10 1709+/Windows 11, device onboarded to MDE (or at minimum
              Defender AV present) for the ForwardCloudAppTraffic key to be meaningful
    Run As: Local admin for local; equivalent rights for remote (WinRM required)
    Safe: Read-only — no registry writes, no Set-MpPreference calls
    Cross-references: Security/Defender/MDA-B.md (Fix 3-4) and MDA-A.md
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline)]
    [string[]]$ComputerName = @($env:COMPUTERNAME),

    [string]$OutputPath = "C:\Temp\MDA-Status-$(Get-Date -Format 'yyyyMMdd-HHmm').csv",

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

function Get-MDAStatusLocal {
    param([string]$Computer, [bool]$SkipConnectivityTest)

    $result = [PSCustomObject]@{
        ComputerName            = $Computer
        CollectedAt             = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        ForwardCloudAppTraffic  = "Not configured (no MDE→MDA forwarding policy present)"
        MDESenseServiceStatus   = "Unknown"
        MDEOnboardingState      = "Unknown"
        AMRunningMode           = "Unknown"
        RealTimeProtection      = "Unknown"
        Endpoint_mcas           = "Skipped"
        Endpoint_cloudappsec    = "Skipped"
        RecentSenseErrors       = 0
        Errors                  = ""
    }

    try {
        $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection'
        $val = Get-ItemProperty -Path $key -Name 'ForwardCloudAppTraffic' -ErrorAction SilentlyContinue
        if ($val -and ($val.PSObject.Properties.Name -contains 'ForwardCloudAppTraffic')) {
            $result.ForwardCloudAppTraffic = switch ($val.ForwardCloudAppTraffic) {
                1 { "1 — MDE is forwarding Cloud App traffic to MDA" }
                0 { "0 — Forwarding explicitly disabled by policy" }
                default { "$($val.ForwardCloudAppTraffic) — unrecognised value" }
            }
        }
    } catch {
        $result.Errors += "ForwardCloudAppTraffic check failed: $($_.Exception.Message); "
    }

    try {
        $sense = Get-Service -Name Sense -ErrorAction SilentlyContinue
        $result.MDESenseServiceStatus = if ($sense) { $sense.Status } else { "Not installed (device not onboarded to MDE)" }
    } catch {
        $result.Errors += "Sense service check failed: $($_.Exception.Message); "
    }

    try {
        $mpStatus = Get-MpComputerStatus -ErrorAction Stop
        $result.AMRunningMode      = $mpStatus.AMRunningMode
        $result.RealTimeProtection = $mpStatus.RealTimeProtectionEnabled
    } catch {
        $result.Errors += "Get-MpComputerStatus failed: $($_.Exception.Message); "
    }

    try {
        $onboard = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status' -Name 'OnboardingState' -ErrorAction SilentlyContinue
        if ($onboard) {
            $result.MDEOnboardingState = switch ($onboard.OnboardingState) {
                1 { "1 — Onboarded" }
                0 { "0 — Not onboarded" }
                default { "$($onboard.OnboardingState) — unrecognised value" }
            }
        } else {
            $result.MDEOnboardingState = "Registry key not found — likely not onboarded"
        }
    } catch {
        $result.Errors += "Onboarding state check failed: $($_.Exception.Message); "
    }

    if (-not $SkipConnectivityTest) {
        $endpointMap = @{
            Endpoint_mcas        = 'security.microsoft.com'
            Endpoint_cloudappsec = 'portal.cloudappsecurity.com'
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
        $cutoff = (Get-Date).AddDays(-3)
        $events = Get-WinEvent -LogName 'Microsoft-Windows-SENSE/Operational' -ErrorAction SilentlyContinue |
            Where-Object { $_.TimeCreated -ge $cutoff -and $_.LevelDisplayName -eq 'Error' }
        $result.RecentSenseErrors = ($events | Measure-Object).Count
    } catch {
        $result.Errors += "SENSE event log read failed (log may not exist if not onboarded): $($_.Exception.Message); "
    }

    return $result
}

# ───────────────────────────────────────────────────────────────
# MAIN
# ───────────────────────────────────────────────────────────────

$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($computer in $ComputerName) {
    Write-Status "Checking MDA integration status on: $computer" "INFO"

    if ($computer -eq $env:COMPUTERNAME) {
        $res = Get-MDAStatusLocal -Computer $computer -SkipConnectivityTest $SkipConnectivityTest.IsPresent
    } else {
        try {
            $invokeParams = @{
                ComputerName = $computer
                ScriptBlock  = ${function:Get-MDAStatusLocal}
                ArgumentList = @($computer, $SkipConnectivityTest.IsPresent)
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
                ForwardCloudAppTraffic  = "N/A"
                MDESenseServiceStatus   = "N/A"
                MDEOnboardingState      = "N/A"
                AMRunningMode           = "N/A"
                RealTimeProtection      = "N/A"
                Endpoint_mcas           = "N/A"
                Endpoint_cloudappsec    = "N/A"
                RecentSenseErrors       = 0
                Errors                  = "Connection failed: $($_.Exception.Message)"
            }
        }
    }

    $allResults.Add($res)

    $flag = if ($res.ForwardCloudAppTraffic -match '^1') { "OK" } else { "WARN" }
    Write-Status "  ForwardCloudAppTraffic: $($res.ForwardCloudAppTraffic)" $flag
    Write-Status "  MDEOnboardingState: $($res.MDEOnboardingState) | Sense service: $($res.MDESenseServiceStatus) | AMRunningMode: $($res.AMRunningMode)" "INFO"

    if ($res.AMRunningMode -eq "Passive") {
        Write-Status "  AV is in Passive mode — signals to MDA may be degraded (third-party AV present)" "WARN"
    }
    if ($res.RecentSenseErrors -gt 0) {
        Write-Status "  Recent SENSE operational errors: $($res.RecentSenseErrors)" "WARN"
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

Write-Host "`n=== MDA Integration Status Summary ===" -ForegroundColor Cyan
$allResults | Format-Table ComputerName, ForwardCloudAppTraffic, MDEOnboardingState, AMRunningMode, RecentSenseErrors -AutoSize

Write-Host "`nNote: MDA policy configuration, alerts, and Cloud Discovery data are portal-only —" -ForegroundColor DarkGray
Write-Host "check https://security.microsoft.com/cloudapps for those. This script only covers" -ForegroundColor DarkGray
Write-Host "the endpoint-visible half of the integration (MDE forwarding + reachability)." -ForegroundColor DarkGray
