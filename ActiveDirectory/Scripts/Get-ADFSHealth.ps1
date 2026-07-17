<#
.SYNOPSIS
    One-shot AD FS farm health check: certificate expiry/rollover state, relying party trust
    status, farm topology, and recent AD FS/Admin log errors.

.DESCRIPTION
    Read-only diagnostic script for on-premises Active Directory Federation Services (AD FS).
    Run on any AD FS farm node with the AD FS PowerShell module available (it ships with the
    AD FS role, no separate install needed).

    Covers:
      - Farm topology and farm behavior level (Get-AdfsFarmInformation)
      - Farm properties, including AutoCertificateRollover state (Get-AdfsProperties)
      - Token-Signing / Token-Decrypting certificate inventory with days-until-expiry
      - Relying party trust inventory (enabled state, monitoring, identifier)
      - Recent AD FS/Admin log errors and warnings (last 50 events)
      - Optional: Web Application Proxy trust state, if -CheckWap is specified and run on a WAP box

    Does NOT cover:
      - Client-side federated sign-in testing (use a browser or Invoke-WebRequest against
        /federationmetadata/2007-06/federationmetadata.xml separately)
      - Entra ID-side federation configuration (use Get-MgDomainFederationConfiguration from a
        Graph-connected admin workstation to cross-check certificate thumbprints)
      - Claims rule content validation beyond simple enumeration — see ADFS-A.md Playbook 2 for
        the immutableid mismatch investigation, which requires comparing against Entra Connect

.PARAMETER OutputPath
    Directory to write the JSON evidence pack to. Defaults to the current directory.

.PARAMETER CheckWap
    If specified, also queries Web Application Proxy configuration and recent proxy-trust
    related event IDs (224, 276, 394, 395, 396). Only meaningful when run on a WAP server.

.PARAMETER WarnDays
    Number of days remaining on a certificate below which it is flagged as at-risk in the
    console summary. Defaults to 14.

.EXAMPLE
    .\Get-ADFSHealth.ps1
    Runs a standard farm health check on the local AD FS node and writes a JSON evidence pack
    to the current directory.

.EXAMPLE
    .\Get-ADFSHealth.ps1 -CheckWap -WarnDays 21 -OutputPath C:\Temp
    Runs on a WAP server, flags any certificate with fewer than 21 days remaining, and writes
    output to C:\Temp.

.NOTES
    Requires: AD FS PowerShell module (included with the AD FS or Web Application Proxy role).
    Run-as: Local admin on the AD FS/WAP server; farm-level read access is sufficient — this
    script makes no configuration changes.
    Safe/unsafe: Fully read-only. No certificates, trusts, or farm settings are modified.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = ".",
    [switch]$CheckWap,
    [int]$WarnDays = 14
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---- Preflight ----
if (-not (Get-Module -ListAvailable -Name ADFS)) {
    Write-Status "AD FS PowerShell module not found. Run this on an AD FS or WAP server." "ERROR"
    return
}
Import-Module ADFS -ErrorAction Stop

$results = [ordered]@{
    CollectedAt = (Get-Date).ToString("s")
    ComputerName = $env:COMPUTERNAME
}

# ---- Farm topology ----
Write-Status "Checking farm topology..."
try {
    $farm = Get-AdfsFarmInformation
    $results.FarmBehaviorLevel = $farm.CurrentFarmBehavior
    $results.FarmNodes = $farm.FarmNodes
    Write-Status "Farm behavior level: $($farm.CurrentFarmBehavior); nodes: $($farm.FarmNodes -join ', ')" "OK"
} catch {
    Write-Status "Could not retrieve farm information: $_" "ERROR"
    $results.FarmError = $_.Exception.Message
}

# ---- Farm properties ----
Write-Status "Checking farm properties (auto-rollover, host identity)..."
try {
    $props = Get-AdfsProperties
    $results.HostName = $props.HostName
    $results.Identifier = $props.Identifier.OriginalString
    $results.AutoCertificateRollover = $props.AutoCertificateRollover
    $results.CertificateGenerationThreshold = $props.CertificateGenerationThreshold
    $results.CertificateDuration = $props.CertificateDuration

    if (-not $props.AutoCertificateRollover) {
        Write-Status "AutoCertificateRollover is DISABLED — certificates will not renew automatically." "WARN"
    } else {
        Write-Status "AutoCertificateRollover is enabled." "OK"
    }
} catch {
    Write-Status "Could not retrieve AD FS properties: $_" "ERROR"
    $results.PropertiesError = $_.Exception.Message
}

# ---- Certificate inventory ----
Write-Status "Checking Token-Signing / Token-Decrypting certificates..."
$certResults = @()
try {
    $certs = Get-AdfsCertificate
    foreach ($c in $certs) {
        $daysLeft = [math]::Round(($c.Certificate.NotAfter - (Get-Date)).TotalDays, 1)
        $flag = if ($daysLeft -lt 0) { "EXPIRED" } elseif ($daysLeft -lt $WarnDays) { "AT_RISK" } else { "OK" }

        $certResults += [pscustomobject]@{
            CertificateType = $c.CertificateType
            IsPrimary       = $c.IsPrimary
            Thumbprint      = $c.Certificate.Thumbprint
            NotAfter        = $c.Certificate.NotAfter
            DaysLeft        = $daysLeft
            Flag            = $flag
        }

        if ($flag -eq "EXPIRED") {
            Write-Status "$($c.CertificateType) certificate (primary=$($c.IsPrimary)) EXPIRED on $($c.Certificate.NotAfter)." "ERROR"
        } elseif ($flag -eq "AT_RISK") {
            Write-Status "$($c.CertificateType) certificate (primary=$($c.IsPrimary)) expires in $daysLeft days." "WARN"
        }
    }
    if (-not ($certResults | Where-Object Flag -in @("EXPIRED","AT_RISK"))) {
        Write-Status "All certificates within safe validity window." "OK"
    }
} catch {
    Write-Status "Could not retrieve certificates: $_" "ERROR"
}
$results.Certificates = $certResults

# ---- Relying party trusts ----
Write-Status "Checking relying party trusts..."
$rpResults = @()
try {
    $rps = Get-AdfsRelyingPartyTrust
    foreach ($rp in $rps) {
        $rpResults += [pscustomobject]@{
            Name              = $rp.Name
            Enabled           = $rp.Enabled
            MonitoringEnabled = $rp.MonitoringEnabled
            Identifier        = ($rp.Identifier -join ', ')
        }
        if (-not $rp.Enabled) {
            Write-Status "Relying party trust '$($rp.Name)' is DISABLED." "WARN"
        }
    }
    Write-Status "Found $($rpResults.Count) relying party trust(s)." "OK"
} catch {
    Write-Status "Could not retrieve relying party trusts: $_" "ERROR"
}
$results.RelyingPartyTrusts = $rpResults

# ---- Recent AD FS/Admin log errors ----
Write-Status "Scanning AD FS/Admin event log for recent errors/warnings..."
$eventResults = @()
try {
    $events = Get-WinEvent -LogName 'AD FS/Admin' -MaxEvents 50 -ErrorAction Stop |
        Where-Object { $_.LevelDisplayName -in @('Error','Warning') }
    foreach ($e in $events) {
        $eventResults += [pscustomobject]@{
            TimeCreated = $e.TimeCreated
            Id          = $e.Id
            Level       = $e.LevelDisplayName
            Message     = ($e.Message -split "`n")[0]
        }
    }
    Write-Status "Found $($eventResults.Count) error/warning event(s) in the last 50 log entries." $(if ($eventResults.Count -gt 0) { "WARN" } else { "OK" })
} catch {
    Write-Status "Could not read AD FS/Admin event log: $_" "ERROR"
}
$results.RecentErrorEvents = $eventResults

# ---- Optional WAP check ----
if ($CheckWap) {
    Write-Status "Checking Web Application Proxy configuration (per -CheckWap)..."
    try {
        $wapConfig = Get-WebApplicationProxyConfiguration
        $results.WapConfiguration = [pscustomobject]@{
            ADFSUrl = $wapConfig.ADFSUrl
        }

        $wapEvents = Get-WinEvent -LogName 'AD FS/Admin' -MaxEvents 100 -ErrorAction Stop |
            Where-Object { $_.Id -in @(224,276,394,395,396) } | Sort-Object TimeCreated -Descending

        $wapEventResults = $wapEvents | ForEach-Object {
            [pscustomobject]@{ TimeCreated = $_.TimeCreated; Id = $_.Id; Message = ($_.Message -split "`n")[0] }
        }
        $results.WapProxyTrustEvents = $wapEventResults

        $latestTrustFailure = $wapEvents | Where-Object Id -in @(224,276) | Select-Object -First 1
        $latestTrustSuccess = $wapEvents | Where-Object Id -eq 396 | Select-Object -First 1
        if ($latestTrustFailure -and (-not $latestTrustSuccess -or $latestTrustFailure.TimeCreated -gt $latestTrustSuccess.TimeCreated)) {
            Write-Status "Most recent proxy trust event is a FAILURE (Event $($latestTrustFailure.Id)) with no subsequent successful renewal — proxy trust may be lapsed." "ERROR"
        } else {
            Write-Status "No unresolved proxy trust failures found in recent events." "OK"
        }
    } catch {
        Write-Status "Could not retrieve WAP configuration/events (is this a WAP server?): $_" "ERROR"
    }
}

# ---- Export ----
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$jsonPath = Join-Path $OutputPath "ADFSHealth-$timestamp.json"
$csvPath  = Join-Path $OutputPath "ADFSHealth-Certificates-$timestamp.csv"

$results | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Encoding utf8
$certResults | Export-Csv -Path $csvPath -NoTypeInformation

Write-Status "Full results written to: $jsonPath" "OK"
Write-Status "Certificate summary written to: $csvPath" "OK"
