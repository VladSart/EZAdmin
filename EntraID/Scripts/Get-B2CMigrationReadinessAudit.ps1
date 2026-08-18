<#
.SYNOPSIS
    Read-only readiness audit for an Azure AD B2C -> Microsoft Entra External ID
    migration project — approach eligibility, destination-tenant application
    registration/cutover state, identity provider parity, and RBAC for the
    Migration Policy Analyzer.

.DESCRIPTION
    This is a project-level readiness check, distinct from
    Get-CIAMMigrationReadinessAudit.ps1 (which audits the OnPasswordSubmit JIT
    extension mechanics once JIT has already been chosen as the credential-
    preservation approach). This script audits what's readable via Microsoft
    Graph about the surrounding migration project itself:

      1. Directory object count against the ~5,000,000-object High Scale
         Compatibility (HSC) mode eligibility threshold
      2. Destination-tenant application registration state for a supplied list
         of client app IDs — exists, single-tenant (HSC requirement), and
         whether redirect URIs still reference *.b2clogin.com (not cut over)
      3. Identity provider parity — which social/enterprise identity providers
         are configured natively in the destination tenant, for manual
         cross-check against the source B2C tenant's own provider list
         (Graph cannot read a *different* tenant's B2C IdP config from here,
         so this is destination-side only — see Known Gaps)
      4. Whether a JIT OnPasswordSubmit custom authentication extension exists
         at all (presence check only — full mechanics audit is
         Get-CIAMMigrationReadinessAudit.ps1's job)
      5. RBAC — role holders for B2C IEF Policy Administrator / Global
         Administrator, required to run the Migration Policy Analyzer

    Does NOT read, and cannot read via Graph: Migration Policy Analyzer report
    output (portal-only, Identity Experience Framework blade in the B2C
    tenant — no API surface), B2C custom policy XML content, per-user
    migration/credential state at scale, or client-application-side deploy
    status (whether a mobile/SPA build has actually shipped pointing at the
    new authority). This script performs zero write operations.

.PARAMETER ClientAppIds
    One or more Application (client) IDs, in the DESTINATION External ID
    tenant, to check for registration and redirect-URI cutover state.

.PARAMETER HscThreshold
    Directory object count treated as the HSC-mode eligibility floor.
    Default: 5000000. Re-verify against current Microsoft documentation before
    relying on this as a hard cutoff — Microsoft describes it as an
    approximate threshold, not a precise API-enforced limit.

.PARAMETER OutputPath
    Folder to write the CSV export to. Default: current directory.

.EXAMPLE
    .\Get-B2CMigrationReadinessAudit.ps1

.EXAMPLE
    .\Get-B2CMigrationReadinessAudit.ps1 -ClientAppIds "11111111-2222-3333-4444-555555555555","66666666-7777-8888-9999-000000000000"

.NOTES
    Requires: Microsoft.Graph.Applications, Microsoft.Graph.Identity.DirectoryManagement
    PowerShell modules; a signed-in Microsoft Graph session
    (Connect-MgGraph -Scopes "Directory.Read.All","Application.Read.All",
    "Policy.Read.All","RoleManagement.Read.Directory") against the
    DESTINATION Entra External ID tenant. Run against the source Azure AD B2C
    tenant separately if you need its directory-object count or role-holder
    state — this script does not attempt to connect to two tenants at once.
    Read-only. No Set-/New-/Remove-/Update-/Add- cmdlets or beta
    PATCH/POST/DELETE calls are used anywhere in this script's executable code.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$ClientAppIds = @(),

    [Parameter(Mandatory = $false)]
    [long]$HscThreshold = 5000000,

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
Write-Status "Verifying Microsoft Graph session..."
try {
    $mgContext = Get-MgContext
    if (-not $mgContext) { throw "No Microsoft Graph context." }
    $org = Get-MgOrganization -ErrorAction Stop
    Write-Status "Connected to tenant: $($org.DisplayName) ($($org.Id))" -Status "OK"
} catch {
    Write-Status "Not connected to Microsoft Graph. Run Connect-MgGraph -Scopes 'Directory.Read.All','Application.Read.All','Policy.Read.All','RoleManagement.Read.Directory' first, against the DESTINATION External ID tenant." -Status "ERROR"
    throw
}

# ------------------------------------------------------------------
# 1. Directory object count vs. HSC eligibility threshold
# ------------------------------------------------------------------
Write-Status "Checking directory object count against the HSC-mode eligibility threshold ($HscThreshold)..."
try {
    $count = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/directoryObjects/`$count" -Headers @{ "ConsistencyLevel" = "eventual" } -ErrorAction Stop
    $countValue = [long]$count
    $eligible = $countValue -ge $HscThreshold
    $results.Add([PSCustomObject]@{
        Category = "ScaleCheck"
        Item     = "Directory object count"
        Status   = if ($eligible) { "WARN" } else { "OK" }
        Detail   = "Count=$countValue; HscThreshold=$HscThreshold; HscEligible=$eligible. This is the tenant currently connected to — run against BOTH source B2C and destination External ID tenants if they differ."
    })
    Write-Status "  Directory object count: $countValue (HSC-eligible: $eligible)" -Status $(if ($eligible) { "WARN" } else { "OK" })
    if ($eligible) {
        Write-Status "  Tenant meets the approximate HSC-mode object threshold — confirm the migration approach decision matches (standard migration below this scale provides no benefit over HSC; above it, standard migration carries higher operational risk)." -Status "WARN"
    }
} catch {
    Write-Status "Could not read directory object count: $($_.Exception.Message)" -Status "WARN"
    $results.Add([PSCustomObject]@{ Category = "ScaleCheck"; Item = "Directory object count"; Status = "ERROR"; Detail = $_.Exception.Message })
}

# ------------------------------------------------------------------
# 2. Application registration + cutover state
# ------------------------------------------------------------------
if (@($ClientAppIds).Count -gt 0) {
    foreach ($appId in $ClientAppIds) {
        Write-Status "Checking application $appId..."
        try {
            $app = Get-MgApplication -Filter "appId eq '$appId'" -ErrorAction Stop
            if (-not $app) {
                Write-Status "  App $appId not found in this (destination) tenant." -Status "ERROR"
                $results.Add([PSCustomObject]@{ Category = "AppCutover"; Item = $appId; Status = "FAIL"; Detail = "Not registered in the destination tenant — Stage 2 (application registration) hasn't happened for this app yet." })
                continue
            }

            $audience = $app.SignInAudience
            $redirects = @()
            if ($app.Web -and $app.Web.RedirectUris) { $redirects += $app.Web.RedirectUris }
            if ($app.Spa -and $app.Spa.RedirectUris) { $redirects += $app.Spa.RedirectUris }
            $stillOnB2C = @($redirects | Where-Object { $_ -match "\.b2clogin\.com" })

            $results.Add([PSCustomObject]@{
                Category = "AppCutover"
                Item     = "$($app.DisplayName) ($appId)"
                Status   = if ($stillOnB2C.Count -gt 0) { "WARN" } else { "OK" }
                Detail   = "SignInAudience=$audience; RedirectUriCount=$(@($redirects).Count); StillReferencingB2C=$($stillOnB2C.Count -gt 0); CreatedDateTime=$($app.AdditionalProperties['createdDateTime'])"
            })
            Write-Status "  $($app.DisplayName): SignInAudience=$audience; still referencing b2clogin.com redirect URIs=$($stillOnB2C.Count -gt 0)" -Status $(if ($stillOnB2C.Count -gt 0) { "WARN" } else { "OK" })

            if ($audience -ne "AzureADMyOrg") {
                Write-Status "  SignInAudience is '$audience', not single-tenant — this is unsupported for External ID endpoints in HSC mode, and worth double-checking even in standard migration." -Status "WARN"
                $results.Add([PSCustomObject]@{ Category = "AppCutover"; Item = "$($app.DisplayName) / SignInAudience"; Status = "WARN"; Detail = "SignInAudience=$audience — HSC mode requires AzureADMyOrg (single-tenant) app registrations only." })
            }
        } catch {
            Write-Status "  Could not check app ${appId}: $($_.Exception.Message)" -Status "WARN"
            $results.Add([PSCustomObject]@{ Category = "AppCutover"; Item = $appId; Status = "ERROR"; Detail = $_.Exception.Message })
        }
    }
} else {
    Write-Status "Skipping application cutover checks — no -ClientAppIds supplied." -Status "WARN"
    $results.Add([PSCustomObject]@{ Category = "AppCutover"; Item = "N/A"; Status = "WARN"; Detail = "No -ClientAppIds supplied — pass one or more destination-tenant client app IDs to check registration/redirect-URI cutover state." })
}

# ------------------------------------------------------------------
# 3. Identity provider inventory (destination tenant)
# ------------------------------------------------------------------
Write-Status "Checking configured identity providers in the destination tenant..."
try {
    $resp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/identity/identityProviders" -ErrorAction Stop
    $idps = @($resp.value)
    if ($idps.Count -eq 0) {
        Write-Status "  No identity providers configured natively in this tenant." -Status "WARN"
        $results.Add([PSCustomObject]@{ Category = "IdentityProviders"; Item = "N/A"; Status = "WARN"; Detail = "None configured — if the source B2C tenant used social sign-in (Google/Facebook/Apple/etc.) or enterprise federation, these must be rebuilt natively; they are never carried over automatically." })
    } else {
        foreach ($idp in $idps) {
            $results.Add([PSCustomObject]@{ Category = "IdentityProviders"; Item = $idp.name; Status = "OK"; Detail = "identityProviderType=$($idp.identityProviderType)" })
        }
        Write-Status "  $($idps.Count) identity provider(s) configured natively: $(($idps | ForEach-Object { $_.name }) -join ', ')" -Status "OK"
    }
    Write-Status "  Manually cross-reference this list against the SOURCE B2C tenant's identity providers — this script cannot read a different tenant's config in one run." -Status "INFO"
} catch {
    Write-Status "Could not read identity providers: $($_.Exception.Message)" -Status "WARN"
    $results.Add([PSCustomObject]@{ Category = "IdentityProviders"; Item = "N/A"; Status = "ERROR"; Detail = $_.Exception.Message })
}

# ------------------------------------------------------------------
# 4. JIT extension presence (lightweight — full audit is a separate script)
# ------------------------------------------------------------------
Write-Status "Checking for a JIT OnPasswordSubmit custom authentication extension (presence only)..."
try {
    $resp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identity/customAuthenticationExtensions" -ErrorAction Stop
    $jitExt = @($resp.value | Where-Object { $_."@odata.type" -match "onPasswordSubmit" })
    if ($jitExt.Count -eq 0) {
        Write-Status "  No JIT extension found. If passwords are meant to be preserved via JIT, this hasn't been built yet — see CIAMMigration-A.md Playbook 1. If a different credential-preservation approach was chosen (B2C-initiated harvesting, or no preservation), this is expected." -Status "INFO"
        $results.Add([PSCustomObject]@{ Category = "CredentialPreservation"; Item = "JIT extension"; Status = "INFO"; Detail = "Not found — confirm which of the three preservation approaches (none/JIT/B2C-initiated) was actually chosen before treating this as a gap." })
    } else {
        Write-Status "  Found $($jitExt.Count) JIT extension(s) — run Get-CIAMMigrationReadinessAudit.ps1 for full mechanics validation (listener priority, key consistency, admin consent)." -Status "OK"
        $results.Add([PSCustomObject]@{ Category = "CredentialPreservation"; Item = "JIT extension"; Status = "OK"; Detail = "Found $($jitExt.Count) — for detailed validation, run Get-CIAMMigrationReadinessAudit.ps1." })
    }
} catch {
    Write-Status "Could not check for JIT extension: $($_.Exception.Message)" -Status "WARN"
    $results.Add([PSCustomObject]@{ Category = "CredentialPreservation"; Item = "JIT extension"; Status = "ERROR"; Detail = $_.Exception.Message })
}

# ------------------------------------------------------------------
# 5. RBAC — Migration Policy Analyzer role holders
# ------------------------------------------------------------------
Write-Status "Checking role holders who can run the Migration Policy Analyzer..."
$analyzerRoles = @("B2C IEF Policy Administrator", "Global Administrator")
foreach ($roleName in $analyzerRoles) {
    try {
        $roleDef = Get-MgDirectoryRole -Filter "displayName eq '$roleName'" -ErrorAction SilentlyContinue
        if (-not $roleDef) {
            Write-Status "  Role '$roleName' is not activated in this tenant." -Status "WARN"
            $results.Add([PSCustomObject]@{ Category = "RBAC"; Item = $roleName; Status = "WARN"; Detail = "Role not activated — no directoryRole instance exists yet in the tenant currently connected." })
            continue
        }
        $members = Get-MgDirectoryRoleMember -DirectoryRoleId $roleDef.Id -ErrorAction Stop
        $names = @($members | ForEach-Object { $_.AdditionalProperties["displayName"] })
        $results.Add([PSCustomObject]@{
            Category = "RBAC"
            Item     = $roleName
            Status   = if (@($members).Count -gt 0) { "OK" } else { "WARN" }
            Detail   = "Holder count=$(@($members).Count); Holders=$($names -join ', ')"
        })
        Write-Status "  ${roleName}: $(@($members).Count) holder(s)" -Status $(if (@($members).Count -gt 0) { "OK" } else { "WARN" })
    } catch {
        Write-Status "  Could not check role '$roleName': $($_.Exception.Message)" -Status "WARN"
        $results.Add([PSCustomObject]@{ Category = "RBAC"; Item = $roleName; Status = "ERROR"; Detail = $_.Exception.Message })
    }
}
Write-Status "  Note: the Migration Policy Analyzer lives in the SOURCE Azure AD B2C tenant's Identity Experience Framework blade — RBAC there is separate from the destination External ID tenant's role assignments checked above." -Status "INFO"

# ------------------------------------------------------------------
# Known Gaps — explicitly not covered by this script
# ------------------------------------------------------------------
$knownGaps = @(
    "Migration Policy Analyzer report output (feature detection, migration status per feature) — portal-only, Identity Experience Framework blade in the source B2C tenant, no Graph/API surface to read results from."
    "Source B2C tenant's own custom policy XML content and structure — this script never authenticates to the source tenant; run the analyzer there directly."
    "Client-application-side deploy status — whether a mobile app build, SPA config, or backend has actually shipped pointing at the new External ID authority. Redirect URIs checked here are the Entra-side half only."
    "Per-user credential/migration-flag state at scale — for JIT specifically, see Get-CIAMMigrationReadinessAudit.ps1's own documented scope; for B2C-initiated harvesting, check the B2C custom policy's own logging."
    "Age-gating custom-policy logic detection — no Graph-readable signal distinguishes this; confirm manually against the source B2C policy content."
    "HSC mode enablement state itself (the tenant-level toggle) — not currently exposed via a stable Graph property at time of writing; confirm in the Azure portal B2C tenant settings."
)
foreach ($gap in $knownGaps) {
    $results.Add([PSCustomObject]@{ Category = "KnownGap"; Item = "Manual verification required"; Status = "INFO"; Detail = $gap })
}

# ------------------------------------------------------------------
# Report
# ------------------------------------------------------------------
Write-Status "=== Summary ===" -Status "INFO"
$results | Group-Object Status | ForEach-Object { Write-Status "$($_.Name): $($_.Count)" }

$exportFile = Join-Path -Path $OutputPath -ChildPath "B2CMigration-ReadinessAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$results | Export-Csv -Path $exportFile -NoTypeInformation
Write-Status "Full results exported to $exportFile" -Status "OK"

$results
