<#
.SYNOPSIS
    Read-only pre/post-enablement audit for Microsoft Entra Domain Services' enhanced
    sAMAccountName synchronization (Public Preview) feature.

.DESCRIPTION
    Supports the workflow documented in SamAccountNameSync-A.md / SamAccountNameSync-B.md:
      - Confirms the managed domain's SKU is Enterprise or Premium (a hard, silent gate —
        the feature does not exist on Standard SKU)
      - Inventories hybrid users (onPremisesSyncEnabled = true) tenant-wide who are MISSING
        a populated onPremisesSamAccountName attribute — these users will silently continue
        using the old mailNickname-based generation logic even after enhanced sync is enabled,
        which is worth knowing before a client assumes "everyone" got the new consistent naming
      - Optionally, when run FROM a management VM domain-joined to the managed domain
        (-ManagedDomainFQDN supplied and the ActiveDirectory RSAT module present), compares
        a supplied sample of users' onPremisesSamAccountName (Entra ID side) against their
        actual sAMAccountName on the managed domain (Domain Services side) to confirm whether
        enhanced sync is currently active and behaving as expected for those specific users

    This script does NOT enable or disable the feature (no confirmed PowerShell/Graph cmdlet
    exists for that setting as of this preview — it must be changed in the Entra admin center),
    and does NOT modify any user or domain configuration. It is read-only by design.

.PARAMETER DomainServiceName
    The name of the Microsoft Entra Domain Services resource (managed domain) in Azure.

.PARAMETER ResourceGroupName
    Resource group containing the Domain Services resource.

.PARAMETER ManagedDomainFQDN
    Optional. The managed domain's FQDN (e.g. dscontoso.com). If supplied and the
    ActiveDirectory RSAT module is available, enables the per-user comparison checks.

.PARAMETER SampleUpns
    Optional. An array of specific user UPNs to run the per-user comparison against when
    -ManagedDomainFQDN is supplied. If omitted, only the tenant-wide missing-attribute
    inventory runs.

.PARAMETER OutputPath
    Optional. Folder to write the CSV export(s) to. Defaults to the current directory.

.EXAMPLE
    .\Get-SamAccountNameSyncAudit.ps1 -DomainServiceName "dscontoso" -ResourceGroupName "rg-identity"

.EXAMPLE
    .\Get-SamAccountNameSyncAudit.ps1 -DomainServiceName "dscontoso" -ResourceGroupName "rg-identity" `
        -ManagedDomainFQDN "dscontoso.com" -SampleUpns @("alice@contoso.com","bob@contoso.com")

.NOTES
    Requires: Az.DomainServices, Microsoft.Graph.Users PowerShell modules; ActiveDirectory RSAT
    module only if -ManagedDomainFQDN is supplied.
    Run as: any account with Directory.Read.All (Graph) and Reader on the Domain Services
    resource (Az); domain-joined RSAT checks require standard AD read access.
    Safe/unsafe: fully read-only, safe to run in production at any time. Does not change the
    enhanced-sync setting itself.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DomainServiceName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$ManagedDomainFQDN,

    [Parameter(Mandatory = $false)]
    [string[]]$SampleUpns,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

if (-not (Test-Path -Path $OutputPath)) {
    Write-Status "Output path '$OutputPath' does not exist — creating it." "WARN"
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

# ---------------------------------------------------------------------------
# Step 1 — SKU eligibility check
# ---------------------------------------------------------------------------
Write-Status "Checking Az PowerShell connection..."
try {
    $azCtx = Get-AzContext -ErrorAction Stop
    if (-not $azCtx) { throw "Not connected" }
}
catch {
    Write-Status "Not connected to Azure. Connecting now..." "WARN"
    Connect-AzAccount | Out-Null
}

Write-Status "Checking managed domain SKU for '$DomainServiceName'..."
$domainService = Get-AzADDomainService -Name $DomainServiceName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
Write-Host "  Managed domain : $($domainService.Name)"
Write-Host "  SKU            : $($domainService.Sku)"

if ($domainService.Sku -eq "Standard") {
    Write-Status "SKU is Standard — enhanced sAMAccountName synchronization is NOT available on this managed domain. Stopping here." "ERROR"
    return
}
else {
    Write-Status "SKU '$($domainService.Sku)' is eligible for enhanced sAMAccountName synchronization." "OK"
}

# ---------------------------------------------------------------------------
# Step 2 — Tenant-wide inventory of hybrid users missing onPremisesSamAccountName
# ---------------------------------------------------------------------------
Write-Status "Checking Microsoft Graph PowerShell connection..."
try {
    $mgCtx = Get-MgContext -ErrorAction Stop
    if (-not $mgCtx) { throw "Not connected" }
}
catch {
    Write-Status "Not connected to Microsoft Graph. Connecting now..." "WARN"
    Connect-MgGraph -Scopes "User.Read.All" -NoWelcome
}

Write-Status "Inventorying hybrid users missing a populated onPremisesSamAccountName (tenant-wide)..."
$hybridUsers = Get-MgUser -All -Filter "onPremisesSyncEnabled eq true" `
    -Property Id, DisplayName, UserPrincipalName, OnPremisesSamAccountName

$missingAttribute = $hybridUsers | Where-Object { -not $_.OnPremisesSamAccountName }

Write-Status "Found $($hybridUsers.Count) hybrid user(s) tenant-wide; $($missingAttribute.Count) are missing onPremisesSamAccountName." "OK"

if ($missingAttribute.Count -gt 0) {
    $missingAttribute | Select-Object DisplayName, UserPrincipalName | Format-Table -AutoSize
    $missingCsvPath = Join-Path -Path $OutputPath -ChildPath "SamAccountNameSync-MissingAttribute-$timestamp.csv"
    $missingAttribute | Select-Object DisplayName, UserPrincipalName, Id |
        Export-Csv -Path $missingCsvPath -NoTypeInformation -Encoding UTF8
    Write-Status "Exported missing-attribute inventory to: $missingCsvPath" "OK"
    Write-Status "These users will continue using mailNickname-based generation even after enhanced sync is enabled." "WARN"
}

# ---------------------------------------------------------------------------
# Step 3 — Optional per-user cloud-side vs. managed-domain-side comparison
# ---------------------------------------------------------------------------
if ($ManagedDomainFQDN -and $SampleUpns -and $SampleUpns.Count -gt 0) {

    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        Write-Status "ActiveDirectory RSAT module not found — skipping per-user comparison checks. Run this script from a management VM domain-joined to the managed domain to enable this step." "WARN"
    }
    else {
        Import-Module ActiveDirectory -ErrorAction Stop
        Write-Status "Running per-user comparison against managed domain '$ManagedDomainFQDN' for $($SampleUpns.Count) sample user(s)..."

        $comparisonResults = foreach ($upn in $SampleUpns) {
            $entraUser = $hybridUsers | Where-Object { $_.UserPrincipalName -eq $upn }
            if (-not $entraUser) {
                $entraUser = Get-MgUser -UserId $upn -Property OnPremisesSamAccountName -ErrorAction SilentlyContinue
            }

            $adsUser = $null
            try {
                $adsUser = Get-ADUser -Filter "UserPrincipalName -eq '$upn'" -Server $ManagedDomainFQDN -Properties SamAccountName -ErrorAction Stop
            }
            catch {
                Write-Status "Could not resolve '$upn' on managed domain '$ManagedDomainFQDN' — check the UPN and domain connectivity." "WARN"
            }

            [pscustomobject]@{
                UPN                          = $upn
                EntraOnPremSamAccountName    = $entraUser.OnPremisesSamAccountName
                DomainServicesSamAccountName = $adsUser.SamAccountName
                Match                        = if ($adsUser -and $entraUser) { $entraUser.OnPremisesSamAccountName -eq $adsUser.SamAccountName } else { "N/A - could not resolve one or both sides" }
            }
        }

        $comparisonResults | Format-Table -AutoSize

        $mismatches = $comparisonResults | Where-Object { $_.Match -eq $false }
        if ($mismatches.Count -gt 0) {
            Write-Status "$($mismatches.Count) user(s) show a MISMATCH between Entra ID's onPremisesSamAccountName and the managed domain's current sAMAccountName." "WARN"
            Write-Status "This is expected if enhanced sync has not yet been enabled, or the user has no onPremisesSamAccountName populated. Cross-reference against SamAccountNameSync-B.md Triage before treating as an error." "WARN"
        }
        else {
            Write-Status "All sampled users match — enhanced sync appears to be active and consistent for this sample." "OK"
        }

        $comparisonCsvPath = Join-Path -Path $OutputPath -ChildPath "SamAccountNameSync-Comparison-$timestamp.csv"
        $comparisonResults | Export-Csv -Path $comparisonCsvPath -NoTypeInformation -Encoding UTF8
        Write-Status "Exported comparison results to: $comparisonCsvPath" "OK"
    }
}
else {
    Write-Status "Skipping per-user comparison (no -ManagedDomainFQDN and/or -SampleUpns supplied). Tenant-wide missing-attribute inventory above is still valid." "INFO"
}

Write-Status "Audit complete." "OK"
