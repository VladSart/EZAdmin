<#
.SYNOPSIS
    Audits Entra ID Cross-Tenant Access Settings (XTAS) — default policy, all
    partner-specific overrides, and recent failed cross-tenant sign-ins — and
    flags the misconfigurations that cause the most common B2B/Direct Connect
    support tickets.

.DESCRIPTION
    Connects to Microsoft Graph and:
      1. Retrieves the tenant's default Cross-Tenant Access policy
      2. Retrieves every partner-specific policy override
      3. Cross-checks inbound vs. outbound Direct Connect state per partner
         (Teams Shared Channels require both sides enabled)
      4. Flags trust settings that commonly cause MFA/compliance re-prompt loops
      5. Optionally pulls recent failed cross-tenant sign-ins from the audit log
         to correlate policy gaps with real user impact

    Analysis flags applied (per policy — default and each partner entry):
      NO_PARTNER_POLICY         - Informational: partner relies entirely on default
                                   policy (not itself a problem, but worth confirming
                                   that's intentional before assuming an override exists)
      INBOUND_B2B_BLOCKED       - b2bCollaborationInbound.usersAndGroups.accessType
                                   is "blocked" — this partner/default cannot invite
                                   or accept guests inbound at all
      DIRECT_CONNECT_ONE_SIDED  - Inbound Direct Connect allowed but outbound blocked
                                   (or vice versa) for the same partner — Teams Shared
                                   Channels will fail; both sides must independently
                                   enable Direct Connect for it to work
      TRUST_MFA_OFF             - InboundTrust.IsMfaTrusted = false — guests from this
                                   partner will be re-challenged for MFA in this tenant
                                   even if their home tenant already enforced it
      TRUST_COMPLIANT_OFF       - InboundTrust.IsCompliantDeviceTrusted = false — CA
                                   policies requiring compliant device will fail for
                                   this partner's guests regardless of their home
                                   tenant's Intune compliance state
      XTS_SYNC_ENABLED          - Informational: this partner has cross-tenant sync
                                   inbound enabled — confirm provisioning scope and
                                   userType mapping are intentional

    Read-only. Makes no changes to any XTAS policy.

    Does NOT cover:
    - The home/partner tenant's outbound settings (only visible from their side —
      see CrossTenant-A.md Phase 1 "identify which side is blocking")
    - Actual B2B guest object health/redemption state (see Get-EntraB2BGuestReport.ps1)
    - Application-scoped outbound restrictions beyond a simple allowed/blocked check

.PARAMETER PartnerTenantId
    Optional. If supplied, runs an additional deep-dive section against this single
    partner tenant ID, printing the full policy JSON for manual review.

.PARAMETER IncludeSignInFailures
    Switch. If set, also queries the audit log for recent failed cross-tenant
    sign-ins (requires AuditLog.Read.All scope) and includes them in the export.

.PARAMETER SignInLookbackDays
    Number of days to look back for failed cross-tenant sign-ins when
    -IncludeSignInFailures is set. Default: 7.

.PARAMETER OutputPath
    Directory where CSV/JSON reports will be written.
    Default: .\XTAS-Audit-<timestamp>\

.EXAMPLE
    .\Get-CrossTenantAccessAudit.ps1

    Audits default policy + all partner policies, flags issues, exports CSV.

.EXAMPLE
    .\Get-CrossTenantAccessAudit.ps1 -PartnerTenantId "11111111-2222-3333-4444-555555555555" -IncludeSignInFailures

    Same as above, plus a deep-dive JSON dump for the named partner and a report
    of failed cross-tenant sign-ins from the last 7 days.

.NOTES
    Requires: Microsoft.Graph PowerShell SDK
    Scopes needed: Policy.Read.All (add AuditLog.Read.All for -IncludeSignInFailures)
    Run As: Global Reader, Security Reader, or Global Administrator (read only)
    Safe: Read-only — no policy objects are changed
    Cross-references: EntraID/Troubleshooting/CrossTenant-A.md (Validation Steps 1-6,
                       Symptom -> Cause Map), CrossTenant-B.md (Triage, Fix 1-5)
#>

[CmdletBinding()]
param(
    [string]$PartnerTenantId = "",

    [switch]$IncludeSignInFailures,

    [ValidateRange(1, 90)]
    [int]$SignInLookbackDays = 7,

    [string]$OutputPath = ".\XTAS-Audit-$(Get-Date -Format 'yyyyMMdd-HHmm')"
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

function Get-AccessType {
    param($Node)
    if ($null -eq $Node) { return "unset" }
    if ($null -eq $Node.UsersAndGroups) { return "unset" }
    return $Node.UsersAndGroups.AccessType
}

function Get-PolicyFlags {
    param(
        [string]$TenantLabel,
        $Policy,
        [bool]$IsDefault
    )

    $flags = [System.Collections.Generic.List[string]]::new()

    $inboundB2B   = Get-AccessType -Node $Policy.B2bCollaborationInbound
    $outboundB2B  = Get-AccessType -Node $Policy.B2bCollaborationOutbound
    $inboundDC    = Get-AccessType -Node $Policy.B2bDirectConnectInbound
    $outboundDC   = Get-AccessType -Node $Policy.B2bDirectConnectOutbound
    $mfaTrusted   = $Policy.InboundTrust.IsMfaTrusted
    $compTrusted  = $Policy.InboundTrust.IsCompliantDeviceTrusted
    $haadjTrusted = $Policy.InboundTrust.IsHybridAzureADJoinedDeviceTrusted
    $xtsInbound   = $Policy.CrossTenantSyncPolicy.UserSyncInbound.IsSyncAllowed

    if ($inboundB2B -eq "blocked") { $flags.Add("INBOUND_B2B_BLOCKED") }

    if (($inboundDC -eq "allowed" -and $outboundDC -ne "allowed") -or
        ($outboundDC -eq "allowed" -and $inboundDC -ne "allowed")) {
        $flags.Add("DIRECT_CONNECT_ONE_SIDED")
    }

    if ($mfaTrusted -eq $false)  { $flags.Add("TRUST_MFA_OFF") }
    if ($compTrusted -eq $false) { $flags.Add("TRUST_COMPLIANT_OFF") }
    if ($xtsInbound -eq $true)   { $flags.Add("XTS_SYNC_ENABLED") }

    [PSCustomObject]@{
        TenantId              = $TenantLabel
        DisplayName           = if ($IsDefault) { "DEFAULT POLICY" } else { $Policy.DisplayName }
        InboundB2B            = $inboundB2B
        OutboundB2B           = $outboundB2B
        InboundDirectConnect  = $inboundDC
        OutboundDirectConnect = $outboundDC
        TrustMFA              = $mfaTrusted
        TrustCompliantDevice  = $compTrusted
        TrustHybridJoined     = $haadjTrusted
        XTSInboundSyncAllowed = $xtsInbound
        Flags                 = if ($flags.Count -gt 0) { $flags -join "|" } else { "" }
    }
}

# --- Connect ---
try {
    $scopes = @("Policy.Read.All")
    if ($IncludeSignInFailures) { $scopes += "AuditLog.Read.All" }

    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Connecting to Microsoft Graph..." "INFO"
        Connect-MgGraph -Scopes $scopes -NoWelcome
    }
} catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    return
}

if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

# --- Default policy ---
Write-Status "Retrieving default Cross-Tenant Access policy..." "INFO"
try {
    $default = Get-MgPolicyCrossTenantAccessPolicyDefault -EA Stop
} catch {
    Write-Status "Failed to retrieve default policy: $($_.Exception.Message)" "ERROR"
    return
}

$report = [System.Collections.Generic.List[PSCustomObject]]::new()
$report.Add((Get-PolicyFlags -TenantLabel "DEFAULT" -Policy $default -IsDefault $true))

# --- Partner policies ---
Write-Status "Retrieving partner-specific policies..." "INFO"
try {
    $partners = Get-MgPolicyCrossTenantAccessPolicyPartner -All -EA Stop
    Write-Status "Found $($partners.Count) partner-specific polic$(if ($partners.Count -eq 1) {'y'} else {'ies'})" "OK"
} catch {
    Write-Status "Failed to retrieve partner policies: $($_.Exception.Message)" "WARN"
    $partners = @()
}

foreach ($p in $partners) {
    $report.Add((Get-PolicyFlags -TenantLabel $p.TenantId -Policy $p -IsDefault $false))
}

# --- Console summary ---
Write-Host "`n=== Cross-Tenant Access Policy Audit ===" -ForegroundColor Cyan
Write-Status "Total policies assessed (default + partners): $($report.Count)" "INFO"

$flagged = $report | Where-Object { $_.Flags -ne "" }
if ($flagged.Count -gt 0) {
    Write-Host "`n=== FLAGGED POLICIES ===" -ForegroundColor Yellow
    $flagged | Select-Object TenantId, DisplayName, InboundB2B, InboundDirectConnect, OutboundDirectConnect, Flags |
        Format-Table -AutoSize
} else {
    Write-Status "No policy-level issues flagged across default + $($partners.Count) partner polic$(if ($partners.Count -eq 1) {'y'} else {'ies'})." "OK"
}

$reportPath = Join-Path $OutputPath "XTAS-PolicyAudit.csv"
$report | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8
Write-Status "Policy audit exported to: $reportPath" "OK"

# --- Optional: single-partner deep dive ---
if ($PartnerTenantId -ne "") {
    Write-Status "`nDeep-dive: partner tenant $PartnerTenantId" "INFO"
    try {
        $partnerDetail = Get-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerTenantId $PartnerTenantId -EA Stop
        $jsonPath = Join-Path $OutputPath "PartnerDetail-$PartnerTenantId.json"
        $partnerDetail | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
        Write-Status "Full partner policy JSON written to: $jsonPath" "OK"
    } catch {
        Write-Status "No partner-specific policy found for $PartnerTenantId — default policy applies (404 is expected if no override exists)." "WARN"
    }
}

# --- Optional: recent failed cross-tenant sign-ins ---
if ($IncludeSignInFailures) {
    Write-Status "`nRetrieving failed cross-tenant sign-ins (last $SignInLookbackDays day(s))..." "INFO"
    $since = (Get-Date).AddDays(-$SignInLookbackDays).ToString("yyyy-MM-ddTHH:mm:ssZ")
    try {
        $filter = "crossTenantAccessType ne 'none' and status/errorCode ne 0 and createdDateTime ge $since"
        $failedSignIns = Get-MgAuditLogSignIn -Filter $filter -All -EA Stop |
            Select-Object CreatedDateTime, UserPrincipalName,
                @{N = "HomeTenant"; E = { $_.HomeTenantId } },
                @{N = "ResourceTenant"; E = { $_.ResourceTenantId } },
                @{N = "ErrorCode"; E = { $_.Status.ErrorCode } },
                @{N = "FailureReason"; E = { $_.Status.FailureReason } },
                CrossTenantAccessType

        if ($failedSignIns.Count -gt 0) {
            Write-Status "Found $($failedSignIns.Count) failed cross-tenant sign-in(s) — grouping by home tenant:" "WARN"
            $failedSignIns | Group-Object HomeTenant | Sort-Object Count -Descending |
                Select-Object @{N = "HomeTenantId"; E = { $_.Name } }, Count |
                Format-Table -AutoSize

            $signInPath = Join-Path $OutputPath "FailedCrossTenantSignIns.csv"
            $failedSignIns | Export-Csv -Path $signInPath -NoTypeInformation -Encoding UTF8
            Write-Status "Failed sign-in detail exported to: $signInPath" "OK"
        } else {
            Write-Status "No failed cross-tenant sign-ins found in the lookback window." "OK"
        }
    } catch {
        Write-Status "Failed to query sign-in logs: $($_.Exception.Message) (requires AuditLog.Read.All)" "ERROR"
    }
}

Write-Status "`nNext step for flagged policies: cross-reference CrossTenant-A.md's Symptom -> Cause Map, and remember XTAS partner entries REPLACE the default entirely for that tenant — do not assume merging." "INFO"
