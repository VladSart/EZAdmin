<#
.SYNOPSIS
    Read-only inventory and migration-readiness audit for Exchange Online cross-tenant
    Free/Busy, MailTips, and Calendar Sharing configurations ahead of the EWS-driven
    Microsoft 365 Cross-Tenant Access Policy (XTAP) migration.

.DESCRIPTION
    Exchange Web Services (EWS) deprecation in Exchange Online begins October 1, 2026.
    Organization Relationships, Availability Address Spaces (OrgWideFBToken method), and
    Sharing Policies used for tenant-to-tenant Free/Busy, MailTips, and external Calendar
    Sharing all depend on EWS today and must migrate to Microsoft 365 Cross-Tenant Access
    Policy before that date.

    This script performs a READ-ONLY inventory of all three legacy mechanisms, sizes the
    blast radius (which mailboxes are actually assigned an affected Sharing Policy), and
    checks — for each partner Tenant ID it can resolve via Entra Cross-Tenant Access Policy
    partner records — whether the prerequisite Microsoft 365 Collaboration trust
    (m365CollaborationInbound) and any XTAP capability objects already exist.

    It does NOT create, modify, disable, or remove any configuration — including trust
    relationships, capability objects, or legacy sharing objects. It also cannot confirm a
    partner organization's own inbound-side configuration; that always requires direct
    coordination with the partner's own admin.

.PARAMETER OutputPath
    Directory to write CSV/text exports to. Defaults to the current directory.

.EXAMPLE
    .\Get-CrossTenantSharingMigrationAudit.ps1 -OutputPath C:\Audits

.NOTES
    Requires: Connect-ExchangeOnline (Organization Management or equivalent) and
    Connect-MgGraph -Scopes "Policy.Read.All" (Microsoft Graph PowerShell SDK, beta profile
    recommended — Select-MgProfile beta — since the cross-tenant capability endpoints used
    here are beta as of this writing).
    Safe/read-only: issues no writes, creates no trust relationships, disables nothing.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Status "Starting Cross-Tenant Sharing (EWS -> XTAP) migration readiness audit" "INFO"
Write-Status "Reminder: EWS deprecation in Exchange Online begins October 1, 2026" "WARN"

# --- Preflight: confirm required connections ---
try {
    $null = Get-OrganizationConfig -ErrorAction Stop
}
catch {
    Write-Status "Not connected to Exchange Online. Run Connect-ExchangeOnline first." "ERROR"
    throw
}

$graphConnected = $true
try {
    $null = Get-MgContext -ErrorAction Stop
    if (-not (Get-MgContext)) { $graphConnected = $false }
}
catch {
    $graphConnected = $false
}
if (-not $graphConnected) {
    Write-Status "Not connected to Microsoft Graph. Entra trust/capability checks will be skipped. Run Connect-MgGraph -Scopes 'Policy.Read.All' to enable them." "WARN"
}

# --- Step 1: Organization Relationships ---
Write-Status "Inventorying Organization Relationships..." "INFO"
$orgRels = Get-OrganizationRelationship | Where-Object { $_.Enabled -eq $true }
$orgRels | Select-Object Name, DomainNames, FreeBusyAccessEnabled, FreeBusyAccessLevel, MailTipsAccessEnabled, MailTipsAccessLevel, TargetSharingEpr, TargetAutodiscoverEpr, TargetApplicationUri |
    Export-Csv (Join-Path $OutputPath "OrganizationRelationships.csv") -NoTypeInformation
Write-Status "Found $($orgRels.Count) enabled Organization Relationship(s)." "INFO"

# --- Step 2: Availability Address Spaces ---
Write-Status "Inventorying Availability Address Spaces..." "INFO"
$aas = Get-AvailabilityAddressSpace
$aasExposed = $aas | Where-Object { $_.AccessMethod -eq "OrgWideFBToken" }
$aas | Select-Object ForestName, AccessMethod, TargetAutodiscoverEpr, TargetServiceEpr, TargetTenantId |
    Export-Csv (Join-Path $OutputPath "AvailabilityAddressSpaces.csv") -NoTypeInformation
Write-Status "Found $($aas.Count) Availability Address Space(s); $($aasExposed.Count) using OrgWideFBToken (in scope for tenant-to-tenant XTAP migration)." "INFO"

# --- Step 3: Sharing Policies ---
Write-Status "Inventorying Sharing Policies..." "INFO"
$sharingPolicies = Get-SharingPolicy | Where-Object { $_.Enabled -eq $true }
$sharingPolicies | Select-Object Name, Enabled, Domains, Default |
    Export-Csv (Join-Path $OutputPath "SharingPolicies.csv") -NoTypeInformation
Write-Status "Found $($sharingPolicies.Count) enabled Sharing Policy(ies)." "INFO"

# --- Step 4: Blast radius — mailboxes assigned an affected Sharing Policy ---
Write-Status "Sizing blast radius (mailboxes by assigned Sharing Policy)..." "INFO"
$mailboxSharingAssignment = Get-EXOMailbox -ResultSize Unlimited -RecipientTypeDetails UserMailbox, SharedMailbox -Properties SharingPolicy |
    Group-Object SharingPolicy | Select-Object @{N = "SharingPolicy"; E = { $_.Name } }, Count
$mailboxSharingAssignment | Export-Csv (Join-Path $OutputPath "MailboxSharingPolicyAssignment.csv") -NoTypeInformation

# --- Step 5: Entra Cross-Tenant Access Policy partner trust + XTAP capability check ---
$partnerFindings = @()
if ($graphConnected) {
    Write-Status "Checking Entra Cross-Tenant Access Policy partner trust relationships (beta)..." "INFO"
    try {
        $partners = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners"
        foreach ($partner in $partners.value) {
            $hasM365Trust = $null -ne $partner.m365CollaborationInbound
            $capabilities = $null
            try {
                $capResp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners/$($partner.tenantId)/microsoft365CapabilitiesInbound"
                $capabilities = ($capResp.value | ForEach-Object { $_.'@odata.type' }) -join "; "
            }
            catch {
                $capabilities = "(unable to query — check permissions/beta profile)"
            }
            $partnerFindings += [PSCustomObject]@{
                PartnerTenantId       = $partner.tenantId
                M365CollaborationTrust = $hasM365Trust
                XTAPCapabilities      = $capabilities
            }
        }
    }
    catch {
        Write-Status "Could not query Cross-Tenant Access Policy partners: $($_.Exception.Message)" "WARN"
    }
    $partnerFindings | Export-Csv (Join-Path $OutputPath "XTAPPartnerTrustStatus.csv") -NoTypeInformation
    Write-Status "Found $($partnerFindings.Count) existing Cross-Tenant Access Policy partner record(s). Cross-reference partner Tenant IDs against the domains in OrganizationRelationships.csv/SharingPolicies.csv manually — legacy objects are keyed by domain, XTAP by Tenant ID." "INFO"
}
else {
    Write-Status "Skipping Entra trust/capability checks (Graph not connected)." "WARN"
}

# --- Summary ---
Write-Host ""
Write-Status "=== Summary ===" "INFO"
Write-Status "Organization Relationships (enabled): $($orgRels.Count)" "INFO"
Write-Status "Availability Address Spaces using OrgWideFBToken: $($aasExposed.Count)" "INFO"
Write-Status "Sharing Policies (enabled): $($sharingPolicies.Count)" "INFO"
$totalExposed = $orgRels.Count + $aasExposed.Count + $sharingPolicies.Count
if ($totalExposed -gt 0) {
    Write-Status "This tenant has $totalExposed legacy EWS-dependent sharing configuration(s) in scope for migration before October 1, 2026." "WARN"
}
else {
    Write-Status "No enabled legacy Organization Relationship, OrgWideFBToken Availability Address Space, or Sharing Policy found. This tenant does not appear exposed for these three scenarios." "OK"
}
Write-Status "This script cannot confirm any partner organization's own inbound XTAP configuration — that always requires direct coordination with the partner admin." "WARN"
Write-Status "Evidence exported to $OutputPath" "OK"
