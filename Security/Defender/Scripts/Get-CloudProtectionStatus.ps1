<#
.SYNOPSIS
    Audits Microsoft Defender Cloud Protection (MAPS) state, policy source, cloud
    connectivity, and signature freshness across one or more devices.

.DESCRIPTION
    Queries the local device or remote devices for:
    - Cloud-delivered protection state (CloudProtectionEnabled, MAPSReporting level)
    - The policy source enforcing that state (SpyNetReporting under the Policies key,
      which wins over any local Set-MpPreference change at the next policy refresh)
    - Block At First Seen and automatic sample submission settings (both depend on
      cloud protection being at Advanced level to function)
    - Cloud block level and extended timeout
    - TCP 443 reachability to the Defender cloud endpoints (wdcp/wdcpalt/wd.microsoft.com)
    - Antivirus signature age (cloud sync health proxy)
    - Recent Defender Operational log errors relevant to cloud protection (2001, 2003,
      2004, 3002, 5008)

    Exports results to CSV and prints a colour-coded console summary.

    Does NOT cover:
    - ASR rules, Tamper Protection, or WDAC (separate scripts in this folder)
    - Changing any policy — this script is read-only and does not call Set-MpPreference
    - Proxy remediation — only reports whether a static Defender proxy is configured

.PARAMETER ComputerName
    One or more remote computer names. Defaults to the local machine if omitted.

.PARAMETER DaysBack
    Number of days of Defender Operational event history to scan for cloud-protection-
    related errors. Default: 7.

.PARAMETER OutputPath
    Path for the CSV export. Default: C:\Temp\CloudProtection-Status-<timestamp>.csv

.PARAMETER Credential
    Optional PSCredential for remote connections.

.PARAMETER SkipConnectivityTest
    Skip the Test-NetConnection calls to Defender cloud endpoints (useful when running
    against many devices at once, since each endpoint test can take several seconds per
    device on a machine with no route to the internet).

.EXAMPLE
    .\Get-CloudProtectionStatus.ps1

.EXAMPLE
    .\Get-CloudProtectionStatus.ps1 -ComputerName PC001,PC002 -DaysBack 14

.EXAMPLE
    .\Get-CloudProtectionStatus.ps1 -SkipConnectivityTest -OutputPath "C:\Reports\CloudProt.csv"

.NOTES
    Requires: Windows 10 1709+/Windows 11, Defender AV
    Run As: Local admin for local; equivalent rights for remote (WinRM required)
    Safe: Read-only — no Set-MpPreference or registry writes made
    Cross-references: Security/Defender/CloudProtection-B.md (Fix 1-4) and CloudProtection-A.md
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline)]
    [string[]]$ComputerName = @($env:COMPUTERNAME),

    [int]$DaysBack = 7,

    [string]$OutputPath = "C:\Temp\CloudProtection-Status-$(Get-Date -Format 'yyyyMMdd-HHmm').csv",

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

function Get-CloudProtectionStatusLocal {
    param([string]$Computer, [bool]$SkipConnectivityTest, [int]$DaysBack)

    $result = [PSCustomObject]@{
        ComputerName            = $Computer
        CollectedAt             = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        CloudProtectionEnabled  = "Unknown"
        MAPSReporting           = "Unknown"
        SpyNetReportingPolicy   = "Not set (no policy override)"
        DisableBlockAtFirstSeen = "Unknown"
        SubmitSamplesConsent    = "Unknown"
        CloudBlockLevel         = "Unknown"
        CloudExtendedTimeout    = "Unknown"
        SignatureLastUpdated    = "Unknown"
        SignatureAgeDays        = "Unknown"
        StaticProxyConfigured   = "No"
        Endpoint_wdcp           = "Skipped"
        Endpoint_wdcpalt        = "Skipped"
        Endpoint_wd             = "Skipped"
        RecentCloudErrors5xx    = 0
        WinDefendStatus         = "Unknown"
        Errors                  = ""
    }

    try {
        $mpStatus = Get-MpComputerStatus -ErrorAction Stop
        $result.CloudProtectionEnabled = $mpStatus.CloudProtectionEnabled
        $result.MAPSReporting          = $mpStatus.MAPSReporting
        $result.SignatureLastUpdated   = $mpStatus.AntivirusSignatureLastUpdated
        if ($mpStatus.AntivirusSignatureLastUpdated) {
            $result.SignatureAgeDays = [math]::Round(((Get-Date) - $mpStatus.AntivirusSignatureLastUpdated).TotalDays, 1)
        }
    } catch {
        $result.Errors += "Get-MpComputerStatus failed: $($_.Exception.Message); "
    }

    try {
        $prefs = Get-MpPreference -ErrorAction Stop
        $result.DisableBlockAtFirstSeen = $prefs.DisableBlockAtFirstSeen
        $result.SubmitSamplesConsent    = $prefs.SubmitSamplesConsent
        $result.CloudBlockLevel         = $prefs.CloudBlockLevel
        $result.CloudExtendedTimeout    = $prefs.CloudExtendedTimeout
    } catch {
        $result.Errors += "Get-MpPreference failed: $($_.Exception.Message); "
    }

    try {
        $spynet = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet' -ErrorAction SilentlyContinue
        if ($spynet -and ($spynet.PSObject.Properties.Name -contains "SpyNetReporting")) {
            $result.SpyNetReportingPolicy = switch ($spynet.SpyNetReporting) {
                0 { "0 — MAPS disabled by policy (overrides any local fix)" }
                1 { "1 — Basic MAPS enforced by policy" }
                2 { "2 — Advanced MAPS enforced by policy" }
                default { "$($spynet.SpyNetReporting) — unrecognised value" }
            }
        }
    } catch {
        $result.Errors += "SpyNet policy check failed: $($_.Exception.Message); "
    }

    try {
        $proxy = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Defender' -Name 'ProxyServer' -ErrorAction SilentlyContinue
        if ($proxy -and $proxy.ProxyServer) {
            $result.StaticProxyConfigured = "Yes — $($proxy.ProxyServer)"
        }
    } catch {
        $result.Errors += "Defender proxy check failed: $($_.Exception.Message); "
    }

    if (-not $SkipConnectivityTest) {
        $endpointMap = @{
            Endpoint_wdcp    = 'wdcp.microsoft.com'
            Endpoint_wdcpalt = 'wdcpalt.microsoft.com'
            Endpoint_wd      = 'wd.microsoft.com'
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
        $result.WinDefendStatus = (Get-Service WinDefend -ErrorAction Stop).Status
    } catch {
        $result.Errors += "WinDefend service check failed: $($_.Exception.Message); "
    }

    try {
        $cutoff = (Get-Date).AddDays(-$DaysBack)
        $cloudErrorIds = @(2001, 2003, 2004, 3002, 5008)
        $events = Get-WinEvent -LogName 'Microsoft-Windows-Windows Defender/Operational' -ErrorAction SilentlyContinue |
            Where-Object { $_.TimeCreated -ge $cutoff -and $_.Id -in $cloudErrorIds }
        $result.RecentCloudErrors5xx = ($events | Measure-Object).Count
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
    Write-Status "Checking Cloud Protection status on: $computer" "INFO"

    if ($computer -eq $env:COMPUTERNAME) {
        $res = Get-CloudProtectionStatusLocal -Computer $computer -SkipConnectivityTest $SkipConnectivityTest.IsPresent -DaysBack $DaysBack
    } else {
        try {
            $invokeParams = @{
                ComputerName = $computer
                ScriptBlock  = ${function:Get-CloudProtectionStatusLocal}
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
                ComputerName            = $computer
                CollectedAt             = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                CloudProtectionEnabled  = "N/A"
                MAPSReporting           = "N/A"
                SpyNetReportingPolicy   = "N/A"
                DisableBlockAtFirstSeen = "N/A"
                SubmitSamplesConsent    = "N/A"
                CloudBlockLevel         = "N/A"
                CloudExtendedTimeout    = "N/A"
                SignatureLastUpdated    = "N/A"
                SignatureAgeDays        = "N/A"
                StaticProxyConfigured   = "N/A"
                Endpoint_wdcp           = "N/A"
                Endpoint_wdcpalt        = "N/A"
                Endpoint_wd             = "N/A"
                RecentCloudErrors5xx    = 0
                WinDefendStatus         = "N/A"
                Errors                  = "Connection failed: $($_.Exception.Message)"
            }
        }
    }

    $allResults.Add($res)

    $flag = if ($res.CloudProtectionEnabled -eq $true) { "OK" } else { "WARN" }
    Write-Status "  CloudProtectionEnabled: $($res.CloudProtectionEnabled) | MAPSReporting: $($res.MAPSReporting) | Policy override: $($res.SpyNetReportingPolicy)" $flag

    if ($res.SignatureAgeDays -is [double] -and $res.SignatureAgeDays -gt 1) {
        Write-Status "  Signature age: $($res.SignatureAgeDays) days — stale (>24h)" "WARN"
    }
    if ($res.RecentCloudErrors5xx -gt 0) {
        Write-Status "  Cloud-protection-related Defender errors in last $DaysBack days: $($res.RecentCloudErrors5xx)" "WARN"
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

Write-Host "`n=== Cloud Protection Status Summary ===" -ForegroundColor Cyan
$allResults | Format-Table ComputerName, CloudProtectionEnabled, MAPSReporting, SignatureAgeDays, RecentCloudErrors5xx -AutoSize
