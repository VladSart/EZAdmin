<#
.SYNOPSIS
    Audits Microsoft Intune Cloud PKI certification authority health, capacity, and issuance state tenant-wide.

.DESCRIPTION
    Read-only Graph-based audit of Microsoft Cloud PKI for Intune. Cloud PKI has no dedicated
    typed PowerShell module or cmdlet set as of this writing, so this script queries the beta
    Cloud PKI Graph resources directly via Invoke-MgGraphRequest.

    Reports, for every Certification Authority object in the tenant:
      - CA type (Root / Issuing / BYOCA) and current status (Active / Signing required / Disabled)
      - Whether the CA is nearing the shared 3-CA-per-tenant capacity cap (flags CA_CAPACITY_NEAR_LIMIT
        at 2 of 3 and CA_CAPACITY_AT_LIMIT at 3 of 3)
      - BYOCA CAs stuck in "Signing required" past a configurable staleness threshold
        (flags BYOCA_SIGNING_STALE) since this is the single most common false-alarm state
        in a fresh Cloud PKI deployment (see CloudPKI-A.md Learning Pointers)
      - Key backing (HSM vs. software) per CA, flagging TRIAL_SOFTWARE_KEYS as an informational
        note (not an error) since trial-created CAs can never be converted to HSM-backed keys
      - A rollup of certificates issued per CA against the admin-center-known 1,000-row display
        limitation, flagging HIGH_ISSUANCE_VOLUME as informational guidance to use
        Devices > Monitor > Certificates for the authoritative full list rather than the CA's
        own "View all certificates" pane

    This script does NOT attempt device-side validation (trust chain presence, leaf certificate
    delivery) — that is inherently device-local and is covered by the manual validation steps
    in CloudPKI-A.md's Evidence Pack. This script is a tenant-wide CA/capacity health sweep only.

.PARAMETER StaleSigningDays
    Number of days a BYOCA CA may sit in "Signing required" before being flagged as stale.
    Default: 7.

.PARAMETER HighIssuanceThreshold
    Certificate count per CA above which HIGH_ISSUANCE_VOLUME is flagged as a reminder to use
    the Devices > Monitor > Certificates view instead of the CA's own capped list. Default: 900.

.EXAMPLE
    .\Get-CloudPKIHealth.ps1
    Runs a full tenant-wide Cloud PKI CA health and capacity audit with default thresholds.

.EXAMPLE
    .\Get-CloudPKIHealth.ps1 -StaleSigningDays 3 -HighIssuanceThreshold 500
    Uses tighter thresholds for a more conservative MSP monitoring pass.

.NOTES
    Requires: Microsoft.Graph.Authentication module, Microsoft Graph beta profile
    (Cloud PKI Graph resources are beta as of this writing).
    Required scopes: DeviceManagementConfiguration.Read.All
    Run-as: any account with at least the Intune "Read CAs" custom-role permission.
    Read-only — makes no changes to any CA, profile, or certificate.
#>

#Requires -Modules Microsoft.Graph.Authentication

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [int]$StaleSigningDays = 7,

    [Parameter(Mandatory = $false)]
    [int]$HighIssuanceThreshold = 900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Starting Cloud PKI health audit..." "INFO"

try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "No active Graph session — connecting with required scope." "WARN"
        Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All" -NoWelcome
    }
    Select-MgProfile -Name "beta" -ErrorAction SilentlyContinue
}
catch {
    Write-Status "Failed to establish Graph session: $($_.Exception.Message)" "ERROR"
    throw
}

$findings = [System.Collections.Generic.List[pscustomobject]]::new()
$caCapacityMax = 3

# ---------------------------------------------------------------------------
# Detect: enumerate Cloud PKI certification authorities
# ---------------------------------------------------------------------------
Write-Status "Querying Cloud PKI certification authorities (beta Graph resource)..." "INFO"

$caList = $null
try {
    # Cloud PKI CA objects are exposed under the beta deviceManagement pkiCertificationAuthority
    # resource path. Endpoint name/shape may shift while the API is in beta — this script
    # deliberately isolates the raw request so a schema change is a one-line fix.
    $uri = "https://graph.microsoft.com/beta/deviceManagement/pkiCertificationAuthorities"
    $response = Invoke-MgGraphRequest -Method GET -Uri $uri
    $caList = $response.value
}
catch {
    Write-Status "Could not query Cloud PKI CA objects via Graph beta endpoint: $($_.Exception.Message)" "ERROR"
    Write-Status "Confirm the signed-in account holds the Intune 'Read CAs' custom-role permission and that Cloud PKI is enabled for this tenant." "ERROR"
    throw
}

if (-not $caList -or $caList.Count -eq 0) {
    Write-Status "No Cloud PKI certification authorities found in this tenant. Either Cloud PKI is not yet configured, or the account lacks Read CAs permission." "WARN"
}

# ---------------------------------------------------------------------------
# Evaluate: capacity cap
# ---------------------------------------------------------------------------
$totalCAs = $caList.Count
Write-Status "Total CA objects in tenant: $totalCAs / $caCapacityMax" "INFO"

if ($totalCAs -ge $caCapacityMax) {
    $findings.Add([pscustomobject]@{
        CAName = "(tenant-wide)"; CAType = ""; Status = ""
        Flag = "CA_CAPACITY_AT_LIMIT"
        Detail = "Tenant has $totalCAs of $caCapacityMax CA objects (Root+Issuing+BYOCA combined) — at hard capacity. No new CA can be created until one is retired."
    })
}
elseif ($totalCAs -eq ($caCapacityMax - 1)) {
    $findings.Add([pscustomobject]@{
        CAName = "(tenant-wide)"; CAType = ""; Status = ""
        Flag = "CA_CAPACITY_NEAR_LIMIT"
        Detail = "Tenant has $totalCAs of $caCapacityMax CA objects — one slot remaining before hitting the hard cap."
    })
}

# ---------------------------------------------------------------------------
# Evaluate: per-CA status, signing staleness, key backing, issuance volume
# ---------------------------------------------------------------------------
foreach ($ca in $caList) {
    $caName   = $ca.displayName
    $caType   = $ca.certificationAuthorityType   # expected: root / issuing / bringYourOwn (schema may vary while in beta)
    $caStatus = $ca.status                       # expected: active / signingRequired / disabled

    Write-Status "CA '$caName' — type: $caType, status: $caStatus" "INFO"

    # Flag: BYOCA stuck in Signing required past threshold
    if ($caStatus -match "signingRequired|SigningRequired") {
        $createdDate = $null
        if ($ca.createdDateTime) { $createdDate = [datetime]$ca.createdDateTime }
        $daysStale = if ($createdDate) { (New-TimeSpan -Start $createdDate -End (Get-Date)).Days } else { $null }

        if ($null -ne $daysStale -and $daysStale -ge $StaleSigningDays) {
            $findings.Add([pscustomobject]@{
                CAName = $caName; CAType = $caType; Status = $caStatus
                Flag = "BYOCA_SIGNING_STALE"
                Detail = "In 'Signing required' for $daysStale day(s) (threshold $StaleSigningDays). Likely an incomplete BYOCA onboarding — download the CSR, sign via internal CA, upload cert + chain. Not a Microsoft-side fault."
            })
        }
        else {
            $findings.Add([pscustomobject]@{
                CAName = $caName; CAType = $caType; Status = $caStatus
                Flag = "BYOCA_SIGNING_PENDING"
                Detail = "In 'Signing required' — normal transient BYOCA state, no action needed yet unless it persists past $StaleSigningDays day(s)."
            })
        }
    }

    # Flag: key backing (informational — trial CAs permanently software-backed)
    if ($ca.keyStorageProvider -match "software|Software") {
        $findings.Add([pscustomobject]@{
            CAName = $caName; CAType = $caType; Status = $caStatus
            Flag = "TRIAL_SOFTWARE_KEYS"
            Detail = "CA uses software-backed keys (typical of a trial-created CA). This cannot be converted to HSM-backed keys even after licensing — informational only, confirm this meets the client's compliance requirements."
        })
    }

    # Flag: disabled CA still present (capacity consumed by an inactive CA)
    if ($caStatus -match "disabled|Disabled") {
        $findings.Add([pscustomobject]@{
            CAName = $caName; CAType = $caType; Status = $caStatus
            Flag = "DISABLED_CA_CONSUMING_CAPACITY"
            Detail = "CA is disabled but still counts toward the 3-CA capacity cap. Consider deletion if no devices depend on it (verify via Devices > Monitor > Certificates first)."
        })
    }

    # Evaluate issuance volume (informational — admin center UI caps display at 1,000)
    try {
        $certsUri = "https://graph.microsoft.com/beta/deviceManagement/pkiCertificationAuthorities/$($ca.id)/certificates?`$count=true"
        $certsResponse = Invoke-MgGraphRequest -Method GET -Uri $certsUri -Headers @{ "ConsistencyLevel" = "eventual" }
        $certCount = $certsResponse.'@odata.count'
        if ($null -ne $certCount -and $certCount -ge $HighIssuanceThreshold) {
            $findings.Add([pscustomobject]@{
                CAName = $caName; CAType = $caType; Status = $caStatus
                Flag = "HIGH_ISSUANCE_VOLUME"
                Detail = "Approximately $certCount certificates issued — approaching or past the admin center's 1,000-row 'View all certificates' display cap. Use Devices > Monitor > Certificates for the authoritative full list."
            })
        }
    }
    catch {
        Write-Status "Could not retrieve certificate count for CA '$caName': $($_.Exception.Message)" "WARN"
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Cloud PKI Health Summary ===" -ForegroundColor Cyan
Write-Host "Total CA objects: $totalCAs / $caCapacityMax"
Write-Host "Total findings: $($findings.Count)"
Write-Host ""

if ($findings.Count -gt 0) {
    $findings | Format-Table -AutoSize -Wrap
}
else {
    Write-Status "No findings — all CAs Active, within capacity, and no stale BYOCA signing states detected." "OK"
}

$csvPath = ".\CloudPKIHealth_$(Get-Date -Format yyyyMMdd_HHmmss).csv"
$findings | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Status "Full results exported to: $csvPath" "OK"
