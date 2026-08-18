<#
.SYNOPSIS
    Read-only readiness/health audit for Microsoft Graph Data Connect (MGDC)
    onboarding prerequisites — everything reachable via the Az and
    Microsoft.Graph PowerShell modules.

.DESCRIPTION
    Microsoft Graph Data Connect has no dedicated PowerShell module of its own,
    and several pieces of its state are Azure-portal-only or M365-admin-center-only
    with no documented Graph/REST read surface (the tenant-wide enablement toggle,
    per-app Pre-consent/Approved status, and pipeline run history). This script
    audits only the pieces that ARE programmatically readable:

      1. Tenant/subscription boundary alignment (Entra tenant ID on both sides)
      2. Microsoft.GraphServices resource provider registration state (billing gate)
      3. Entra app registration owner eligibility for one or more specified apps
         (non-guest UserType, presence of a mailbox via the Mail property, and a
         non-zero assigned-license count — flagged for manual E5-tier verification
         since SKU part numbers vary by agreement type and should not be hardcoded)
      4. Service principal RBAC on a specified destination storage account
         (presence/absence of Storage Blob Data Contributor)
      5. Storage account network rule posture (open vs. firewalled, with IP rule count)

    Does NOT read, change, or attempt to infer: the tenant MGDC enablement toggle,
    app consent/approval status, dataset/column scope selected during app
    registration, or any pipeline run history — all of these must be checked
    manually per the Escalation Evidence template in GraphDataConnect-B.md.
    This script performs zero write operations.

.PARAMETER AppObjectId
    One or more Entra application object IDs (not client/app IDs) to audit
    owner eligibility for.

.PARAMETER ServicePrincipalObjectId
    Object ID of the service principal used by the MGDC pipeline's linked
    service, for storage RBAC validation. Optional — omit to skip storage checks.

.PARAMETER StorageAccountResourceId
    Full Azure resource ID of the destination storage account. Required if
    -ServicePrincipalObjectId is supplied.

.PARAMETER OutputPath
    Folder to write the CSV export to. Default: current directory.

.EXAMPLE
    .\Get-GraphDataConnectReadinessAudit.ps1 -AppObjectId "11111111-2222-3333-4444-555555555555"

.EXAMPLE
    .\Get-GraphDataConnectReadinessAudit.ps1 `
        -AppObjectId "11111111-2222-3333-4444-555555555555" `
        -ServicePrincipalObjectId "66666666-7777-8888-9999-000000000000" `
        -StorageAccountResourceId "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<name>" `
        -OutputPath "C:\Evidence"

.NOTES
    Requires: Az.Accounts, Az.Resources, Az.Storage, Microsoft.Graph.Applications,
    Microsoft.Graph.Users PowerShell modules; a signed-in Az context
    (Connect-AzAccount) and Microsoft Graph session (Connect-MgGraph -Scopes
    "Application.Read.All","User.Read.All") with at minimum read access to the
    relevant application, subscription, and storage account.
    Read-only. No Set-/New-/Remove-/Update- cmdlets are used anywhere in this
    script's executable code.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$AppObjectId,

    [Parameter(Mandatory = $false)]
    [string]$ServicePrincipalObjectId,

    [Parameter(Mandatory = $false)]
    [string]$StorageAccountResourceId,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$results = [System.Collections.Generic.List[object]]::new()

# ------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------
Write-Status "Verifying Az and Microsoft Graph sessions..."
try {
    $azContext = Get-AzContext
    if (-not $azContext) { throw "No Az context." }
} catch {
    Write-Status "Not connected to Azure. Run Connect-AzAccount first." -Status "ERROR"
    throw
}

try {
    $mgContext = Get-MgContext
    if (-not $mgContext) { throw "No Microsoft Graph context." }
} catch {
    Write-Status "Not connected to Microsoft Graph. Run Connect-MgGraph -Scopes 'Application.Read.All','User.Read.All' first." -Status "ERROR"
    throw
}

# ------------------------------------------------------------------
# 1. Tenant/subscription boundary alignment
# ------------------------------------------------------------------
Write-Status "Checking tenant/subscription boundary alignment..."
try {
    $azTenantId = $azContext.Tenant.Id
    $entraOrg = Get-MgOrganization -ErrorAction Stop
    $entraTenantId = $entraOrg.Id
    $boundaryOk = $azTenantId -eq $entraTenantId

    $results.Add([PSCustomObject]@{
        Category = "TenantBoundary"
        Item     = "Az subscription tenant vs. Entra tenant"
        Status   = if ($boundaryOk) { "OK" } else { "FAIL" }
        Detail   = "AzTenantId=$azTenantId; EntraTenantId=$entraTenantId"
    })
    Write-Status "Tenant boundary: $(if ($boundaryOk) { 'OK — same tenant' } else { 'MISMATCH — MGDC cannot function across tenants' })" -Status $(if ($boundaryOk) { "OK" } else { "ERROR" })
} catch {
    Write-Status "Could not verify tenant boundary: $($_.Exception.Message)" -Status "WARN"
    $results.Add([PSCustomObject]@{ Category = "TenantBoundary"; Item = "Az subscription tenant vs. Entra tenant"; Status = "ERROR"; Detail = $_.Exception.Message })
}

# ------------------------------------------------------------------
# 2. Microsoft.GraphServices resource provider registration
# ------------------------------------------------------------------
Write-Status "Checking Microsoft.GraphServices resource provider registration..."
try {
    $provider = Get-AzResourceProvider -ProviderNamespace "Microsoft.GraphServices" -ErrorAction Stop
    $regState = $provider.RegistrationState | Select-Object -First 1
    $providerOk = $regState -eq "Registered"

    $results.Add([PSCustomObject]@{
        Category = "ResourceProvider"
        Item     = "Microsoft.GraphServices"
        Status   = if ($providerOk) { "OK" } else { "FAIL" }
        Detail   = "RegistrationState=$regState (billing gate — must be Registered before app registration will succeed)"
    })
    Write-Status "Microsoft.GraphServices: $regState" -Status $(if ($providerOk) { "OK" } else { "ERROR" })
} catch {
    Write-Status "Could not check resource provider: $($_.Exception.Message)" -Status "WARN"
    $results.Add([PSCustomObject]@{ Category = "ResourceProvider"; Item = "Microsoft.GraphServices"; Status = "ERROR"; Detail = $_.Exception.Message })
}

# ------------------------------------------------------------------
# 3. App owner eligibility (per app)
# ------------------------------------------------------------------
foreach ($appId in $AppObjectId) {
    Write-Status "Checking app owner eligibility for app object ID $appId..."
    try {
        $owners = Get-MgApplicationOwner -ApplicationId $appId -ErrorAction Stop
        if (-not $owners -or $owners.Count -eq 0) {
            Write-Status "  App $appId has NO owners assigned." -Status "ERROR"
            $results.Add([PSCustomObject]@{
                Category = "AppOwner"
                Item     = $appId
                Status   = "FAIL"
                Detail   = "No owners found — MGDC registration requires at least one eligible owner."
            })
            continue
        }

        foreach ($owner in $owners) {
            try {
                $user = Get-MgUser -UserId $owner.Id -Property DisplayName, UserType, Mail, AssignedLicenses -ErrorAction Stop
                $isGuest = $user.UserType -eq "Guest"
                $hasMail = -not [string]::IsNullOrWhiteSpace($user.Mail)
                $licenseCount = @($user.AssignedLicenses).Count
                $eligible = (-not $isGuest) -and $hasMail -and ($licenseCount -gt 0)

                $results.Add([PSCustomObject]@{
                    Category = "AppOwner"
                    Item     = "$appId / $($user.DisplayName)"
                    Status   = if ($eligible) { "OK" } else { "FAIL" }
                    Detail   = "UserType=$($user.UserType); HasMail=$hasMail; AssignedLicenseCount=$licenseCount (verify E5-tier manually — SKU naming varies by agreement, not checked here)"
                })
                Write-Status "  Owner $($user.DisplayName): UserType=$($user.UserType), HasMail=$hasMail, Licenses=$licenseCount" -Status $(if ($eligible) { "OK" } else { "WARN" })
            } catch {
                Write-Status "  Could not resolve owner $($owner.Id): $($_.Exception.Message)" -Status "WARN"
                $results.Add([PSCustomObject]@{ Category = "AppOwner"; Item = "$appId / $($owner.Id)"; Status = "ERROR"; Detail = $_.Exception.Message })
            }
        }
    } catch {
        Write-Status "Could not retrieve owners for app ${appId}: $($_.Exception.Message)" -Status "WARN"
        $results.Add([PSCustomObject]@{ Category = "AppOwner"; Item = $appId; Status = "ERROR"; Detail = $_.Exception.Message })
    }
}

# ------------------------------------------------------------------
# 4. Service principal storage RBAC (optional)
# ------------------------------------------------------------------
if ($ServicePrincipalObjectId -and $StorageAccountResourceId) {
    Write-Status "Checking storage RBAC for service principal $ServicePrincipalObjectId..."
    try {
        $assignments = Get-AzRoleAssignment -ObjectId $ServicePrincipalObjectId -Scope $StorageAccountResourceId -ErrorAction Stop
        $hasBlobContributor = $assignments | Where-Object { $_.RoleDefinitionName -eq "Storage Blob Data Contributor" }

        $results.Add([PSCustomObject]@{
            Category = "StorageRBAC"
            Item     = $StorageAccountResourceId
            Status   = if ($hasBlobContributor) { "OK" } else { "FAIL" }
            Detail   = "Storage Blob Data Contributor present=$([bool]$hasBlobContributor); all role assignments found: $(($assignments.RoleDefinitionName -join ', '))"
        })
        Write-Status "Storage Blob Data Contributor present: $([bool]$hasBlobContributor)" -Status $(if ($hasBlobContributor) { "OK" } else { "ERROR" })
    } catch {
        Write-Status "Could not check storage RBAC: $($_.Exception.Message)" -Status "WARN"
        $results.Add([PSCustomObject]@{ Category = "StorageRBAC"; Item = $StorageAccountResourceId; Status = "ERROR"; Detail = $_.Exception.Message })
    }

    # ------------------------------------------------------------------
    # 5. Storage account network rule posture
    # ------------------------------------------------------------------
    Write-Status "Checking storage account network rule posture..."
    try {
        $storageResource = Get-AzResource -ResourceId $StorageAccountResourceId -ErrorAction Stop
        $ruleSet = Get-AzStorageAccountNetworkRuleSet -ResourceGroupName $storageResource.ResourceGroupName -Name $storageResource.Name -ErrorAction Stop
        $ipRuleCount = @($ruleSet.IpRules).Count

        $results.Add([PSCustomObject]@{
            Category = "StorageNetwork"
            Item     = $StorageAccountResourceId
            Status   = if ($ruleSet.DefaultAction -eq "Allow") { "OK" } else { "WARN" }
            Detail   = "DefaultAction=$($ruleSet.DefaultAction); IpRuleCount=$ipRuleCount (if Deny with 0 rules, MGDC delivery will fail — see GraphDataConnect-B.md Fix 7)"
        })
        Write-Status "Storage network DefaultAction=$($ruleSet.DefaultAction), IpRuleCount=$ipRuleCount" -Status $(if ($ruleSet.DefaultAction -eq "Allow") { "OK" } else { "WARN" })
    } catch {
        Write-Status "Could not check storage network rules: $($_.Exception.Message)" -Status "WARN"
        $results.Add([PSCustomObject]@{ Category = "StorageNetwork"; Item = $StorageAccountResourceId; Status = "ERROR"; Detail = $_.Exception.Message })
    }
} else {
    Write-Status "Skipping storage RBAC/network checks — -ServicePrincipalObjectId and -StorageAccountResourceId not both supplied." -Status "WARN"
}

# ------------------------------------------------------------------
# Known Gaps — explicitly not covered by this script
# ------------------------------------------------------------------
$knownGaps = @(
    "Tenant-wide MGDC enablement toggle (M365 admin center → Org settings → Services) — no documented Graph/REST read surface."
    "Per-app consent status: Pre-consent vs. Approved vs. Expired (M365 admin center → Security & privacy → MGDC applications) — portal-only."
    "Dataset/column/user scope selected during app registration (Azure portal aka.ms/mgdcinazure) — portal-only, not exposed via Graph or Az."
    "Pipeline run history and activity-state progression (Fabric/Synapse/ADF monitor) — check directly in the orchestration engine's own monitor UI."
    "Office-to-Azure region mapping for the tenant — not queryable via a documented API; confirm manually via the tenant's known Office region."
)
foreach ($gap in $knownGaps) {
    $results.Add([PSCustomObject]@{ Category = "KnownGap"; Item = "Manual verification required"; Status = "INFO"; Detail = $gap })
}

# ------------------------------------------------------------------
# Report
# ------------------------------------------------------------------
Write-Status "=== Summary ===" -Status "INFO"
$results | Group-Object Status | ForEach-Object { Write-Status "$($_.Name): $($_.Count)" }

$exportFile = Join-Path -Path $OutputPath -ChildPath "GraphDataConnect-ReadinessAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$results | Export-Csv -Path $exportFile -NoTypeInformation
Write-Status "Full results exported to $exportFile" -Status "OK"

$results
