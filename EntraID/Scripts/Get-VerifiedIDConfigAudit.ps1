<#
.SYNOPSIS
    Read-only configuration audit for Microsoft Entra Verified ID authorities and contracts.

.DESCRIPTION
    Verified ID is NOT part of Microsoft Graph — it has its own Admin API hosted at
    https://verifiedid.did.msidentity.com, protected by its own OAuth resource / App ID URI
    (6a8b4b39-c021-437c-b060-5a14a3fd65f3). There is no Microsoft.Graph.VerifiedId module,
    so this script authenticates with a plain OAuth2 client-credentials call and drives the
    Admin API directly via Invoke-RestMethod. No PowerShell module dependency beyond what
    ships in Windows PowerShell 5.1 / PowerShell 7.

    Requires an app registration with the "Verifiable Credentials Service Admin" API
    permission and, at minimum, VerifiableCredential.Authority.ReadWrite (there is no
    documented read-only equivalent for this permission as of this writing, so a
    read-only-in-effect audit script still needs the ReadWrite grant to list authorities
    and contracts).

    Flags:
      AUTHORITY_DID_OUT_OF_SYNC       - didDocumentStatus = outOfSync (signing key
                                         rotated/created but DID document never re-published
                                         and synchronized). Issuance/verification may be
                                         validating against a stale published key.
      AUTHORITY_LEGACY_DID_ION        - authority DID starts with "did:ion:". did:ion was
                                         preview-only and retired December 2023; this
                                         authority is on a deprecated, unsupported-for-new-use
                                         trust system and should be migrated to did:web.
      AUTHORITY_DID_SUBMITTED_PENDING - didDocumentStatus = submitted (did:ion only). The DID
                                         document is still propagating to the ledger, or stuck.
      WELLKNOWN_VALIDATION_FAILED     - (requires -ValidateWellKnown) the service's own
                                         validateWellKnownDidConfiguration call did not return
                                         204 for this authority — domain linkage is broken and
                                         end users will see an "unverified" warning in Authenticator.
      CONTRACT_MANIFEST_UNREACHABLE   - (requires -CheckManifestReachability) the contract's
                                         manifestUrl did not return HTTP 200 on an anonymous GET.
                                         This URL is fetched by the holder's wallet, not by an
                                         authenticated caller, so any auth requirement or outage
                                         here silently breaks issuance for every holder.
      CONTRACT_MULTIPLE_INDEXED_CLAIMS - more than one claimMapping in the contract's rules has
                                         indexed:true. Only one indexed claim mapping is
                                         supported per contract for revocation search purposes.

    Explicitly OUT OF SCOPE (documented here rather than silently omitted):
      - Azure Key Vault permission model (Vault Access Policy vs. Azure RBAC) is not exposed
        by this API at all — verify manually in the Azure portal per authority's Key Vault.
      - Firewall/NSG rules for callback traffic are outside the Verified ID API surface entirely.
      - Request Service API (issuance/presentation) call-level error logs are the calling
        application's responsibility, not visible from the Admin API.
      - No New-/Update-/Remove-/Revoke-/optout calls are made anywhere in this script — the one
        POST used for well-known validation is a stateless validation call with no side effects.

.PARAMETER TenantId
    Entra tenant ID to authenticate against.

.PARAMETER ClientId
    App registration (client) ID. Must have the "Verifiable Credentials Service Admin" API
    permission (VerifiableCredential.Authority.ReadWrite, VerifiableCredential.Contract.ReadWrite)
    with admin consent granted.

.PARAMETER ClientSecret
    Client secret for the app registration, as a SecureString.

.PARAMETER ValidateWellKnown
    Optional switch. Calls validateWellKnownDidConfiguration for each authority (a stateless,
    read-only-in-effect validation call — makes no changes) and flags failures.

.PARAMETER CheckManifestReachability
    Optional switch. Performs an anonymous, unauthenticated HTTP GET against each contract's
    manifestUrl and flags non-200 responses.

.PARAMETER OutputPath
    Path for the CSV export. Defaults to .\VerifiedIDConfigAudit_<timestamp>.csv in the
    current directory.

.EXAMPLE
    $secret = Read-Host -AsSecureString "Client secret"
    .\Get-VerifiedIDConfigAudit.ps1 -TenantId "contoso.onmicrosoft.com" -ClientId "<appId>" -ClientSecret $secret -ValidateWellKnown -CheckManifestReachability

.NOTES
    Run-as: any account/app capable of client-credentials auth against the app registration
    above — no interactive Entra role is required since this uses app-only auth.
    Safe/unsafe: fully read-only against tenant state. The well-known validation call and
    manifest reachability check are outbound network calls only, not tenant mutations.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$ClientId,

    [Parameter(Mandatory)]
    [securestring]$ClientSecret,

    [switch]$ValidateWellKnown,

    [switch]$CheckManifestReachability,

    [string]$OutputPath = ".\VerifiedIDConfigAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Preflight — acquire an app-only token for the Verified ID Admin API resource
# ---------------------------------------------------------------------------
Write-Status "Requesting token for Verified ID Admin API (resource 6a8b4b39-c021-437c-b060-5a14a3fd65f3)..."

$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ClientSecret)
try {
    $plainSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
} finally {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

$tokenBody = @{
    client_id     = $ClientId
    client_secret = $plainSecret
    scope         = "6a8b4b39-c021-437c-b060-5a14a3fd65f3/.default"
    grant_type    = "client_credentials"
}

try {
    $tokenResponse = Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Body $tokenBody -ContentType "application/x-www-form-urlencoded"
} catch {
    Write-Status "Failed to acquire token: $($_.Exception.Message)" "ERROR"
    Write-Status "Confirm the app registration has 'Verifiable Credentials Service Admin' API permission with admin consent granted." "ERROR"
    throw
}

$headers = @{ Authorization = "Bearer $($tokenResponse.access_token)" }
$base    = "https://verifiedid.did.msidentity.com/v1.0/verifiableCredentials"
$findings = [System.Collections.Generic.List[object]]::new()

# ---------------------------------------------------------------------------
# Detect — list authorities
# ---------------------------------------------------------------------------
Write-Status "Listing authorities..."
try {
    $authorities = (Invoke-RestMethod -Headers $headers -Uri "$base/authorities").value
} catch {
    Write-Status "Failed to list authorities: $($_.Exception.Message)" "ERROR"
    throw
}

if (-not $authorities -or $authorities.Count -eq 0) {
    Write-Status "No authorities found. Tenant may not be onboarded to Verified ID yet." "WARN"
}

foreach ($authority in $authorities) {
    $did        = $authority.didModel.did
    $didStatus  = $authority.didModel.didDocumentStatus
    $linkedUrls = $authority.didModel.linkedDomainUrls -join "; "

    Write-Status "Authority '$($authority.name)' [$($authority.id)] — DID: $did — status: $didStatus"

    if ($didStatus -eq "outOfSync") {
        $findings.Add([pscustomobject]@{
            Flag         = "AUTHORITY_DID_OUT_OF_SYNC"
            AuthorityId  = $authority.id
            AuthorityName= $authority.name
            Detail       = "didDocumentStatus=outOfSync — signing key rotated/created but DID document not resynced"
            ContractId   = ""
            ContractName = ""
        })
    }
    elseif ($didStatus -eq "submitted") {
        $findings.Add([pscustomobject]@{
            Flag         = "AUTHORITY_DID_SUBMITTED_PENDING"
            AuthorityId  = $authority.id
            AuthorityName= $authority.name
            Detail       = "didDocumentStatus=submitted — legacy did:ion ledger propagation pending or stuck"
            ContractId   = ""
            ContractName = ""
        })
    }

    if ($did -like "did:ion:*") {
        $findings.Add([pscustomobject]@{
            Flag         = "AUTHORITY_LEGACY_DID_ION"
            AuthorityId  = $authority.id
            AuthorityName= $authority.name
            Detail       = "DID uses deprecated did:ion trust system (preview support ended Dec 2023) — plan migration to did:web"
            ContractId   = ""
            ContractName = ""
        })
    }

    if ($ValidateWellKnown) {
        try {
            Invoke-RestMethod -Method Post -Headers $headers `
                -Uri "$base/authorities/$($authority.id)/validateWellKnownDidConfiguration" -ErrorAction Stop | Out-Null
            Write-Status "  Well-known DID configuration validated OK" "OK"
        } catch {
            $findings.Add([pscustomobject]@{
                Flag         = "WELLKNOWN_VALIDATION_FAILED"
                AuthorityId  = $authority.id
                AuthorityName= $authority.name
                Detail       = "validateWellKnownDidConfiguration failed for linked domain(s) [$linkedUrls]: $($_.Exception.Message)"
                ContractId   = ""
                ContractName = ""
            })
            Write-Status "  Well-known DID configuration validation FAILED" "WARN"
        }
    }

    # -----------------------------------------------------------------
    # Detect — contracts under this authority
    # -----------------------------------------------------------------
    try {
        $contracts = (Invoke-RestMethod -Headers $headers -Uri "$base/authorities/$($authority.id)/contracts").value
    } catch {
        Write-Status "  Failed to list contracts for authority $($authority.id): $($_.Exception.Message)" "ERROR"
        continue
    }

    foreach ($contract in $contracts) {
        # Rules payload may come back as a JSON string or already-parsed object depending on API version
        $rules = $contract.rules
        if ($rules -is [string]) {
            try { $rules = $rules | ConvertFrom-Json } catch { $rules = $null }
        }

        if ($rules -and $rules.attestations) {
            $indexedCount = 0
            foreach ($attType in @('idTokens','idTokenHints','presentations','selfIssued','accessTokens')) {
                $items = $rules.attestations.$attType
                if ($items) {
                    foreach ($item in $items) {
                        if ($item.mapping) {
                            $indexedCount += @($item.mapping | Where-Object { $_.indexed -eq $true }).Count
                        }
                    }
                }
            }
            if ($indexedCount -gt 1) {
                $findings.Add([pscustomobject]@{
                    Flag         = "CONTRACT_MULTIPLE_INDEXED_CLAIMS"
                    AuthorityId  = $authority.id
                    AuthorityName= $authority.name
                    Detail       = "$indexedCount claim mappings marked indexed:true — only one is supported per contract"
                    ContractId   = $contract.id
                    ContractName = $contract.name
                })
            }
        }

        if ($CheckManifestReachability -and $contract.manifestUrl) {
            try {
                $resp = Invoke-WebRequest -Uri $contract.manifestUrl -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
                if ($resp.StatusCode -ne 200) {
                    $findings.Add([pscustomobject]@{
                        Flag         = "CONTRACT_MANIFEST_UNREACHABLE"
                        AuthorityId  = $authority.id
                        AuthorityName= $authority.name
                        Detail       = "manifestUrl returned HTTP $($resp.StatusCode)"
                        ContractId   = $contract.id
                        ContractName = $contract.name
                    })
                }
            } catch {
                $findings.Add([pscustomobject]@{
                    Flag         = "CONTRACT_MANIFEST_UNREACHABLE"
                    AuthorityId  = $authority.id
                    AuthorityName= $authority.name
                    Detail       = "manifestUrl unreachable: $($_.Exception.Message)"
                    ContractId   = $contract.id
                    ContractName = $contract.name
                })
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
if ($findings.Count -eq 0) {
    Write-Status "No issues found across $($authorities.Count) authorit$(if ($authorities.Count -eq 1) {'y'} else {'ies'})." "OK"
} else {
    Write-Status "Found $($findings.Count) issue(s):" "WARN"
    $findings | Format-Table -AutoSize
}

$findings | Export-Csv -Path $OutputPath -NoTypeInformation
Write-Status "Findings exported to $OutputPath" "INFO"

if (-not $ValidateWellKnown) {
    Write-Status "Tip: re-run with -ValidateWellKnown to check live domain linkage per authority." "INFO"
}
if (-not $CheckManifestReachability) {
    Write-Status "Tip: re-run with -CheckManifestReachability to check anonymous reachability of each contract's manifestUrl." "INFO"
}
Write-Status "Not covered by this script (verify manually): Key Vault permission model, firewall/NSG rules for callback traffic, Request Service API call-level error logs." "INFO"
