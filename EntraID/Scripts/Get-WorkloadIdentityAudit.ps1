<#
.SYNOPSIS
    Tenant-wide audit of Workload Identity Federation (federated credentials)
    and Conditional Access coverage for service principals — the two systems
    covered in WorkloadIdentity-A.md and WorkloadIdentity-B.md.

.DESCRIPTION
    Enumerates every Application object with at least one Federated Identity
    Credential and, for each one:
    - Inventories every federated credential's issuer/subject/audience
    - Flags SUSPECT_AUDIENCE for any credential whose audience isn't the
      standard "api://AzureADTokenExchange" (a common typo source per
      WorkloadIdentity-B.md Fix 3)
    - Cross-checks the corresponding Service Principal for AccountEnabled
      state and whether any Conditional Access policy currently targets it
      directly (by Object ID or via the tenant-wide
      "ServicePrincipalsInMyTenant" catch-all) — flags CA_TARGETED so an
      engineer investigating a sudden auth failure knows to check
      Conditional Access before re-verifying federation config
    - Separately reports on Workload Identities Premium license consumption,
      since WorkloadIdentity-A.md's Learning Pointers flag that a lapsed
      license disables EDITING existing CA policies for workload identities
      but does not disable their ENFORCEMENT — a common source of confusion
      mid-incident

    Read-only. Makes no changes to any federated credential, Conditional
    Access policy, or Service Principal. Exports a full CSV plus a filtered
    "needs review" CSV.

    Does NOT cover:
    - Client secret/certificate expiry — see the companion
      Get-AppRegistrationCredentialAudit.ps1 for that
    - Live sign-in failure correlation (AADSTS error codes) — this is a
      proactive/preventive audit; see WorkloadIdentity-B.md Triage for
      live-incident diagnosis
    - Identity Protection risk detections (leaked credential / anomalous
      token) for workload identities — these require the
      IdentityRiskyServicePrincipal.Read.All scope and are reviewed directly
      in the portal's "Risky workload identities" report per
      WorkloadIdentity-A.md Validation Step 5 / Playbook 3

.PARAMETER OutputPath
    Folder where CSV reports are written. Defaults to
    $env:TEMP\WorkloadIdentityAudit-<timestamp>.

.PARAMETER IncludeAppsWithoutFederation
    If specified, also reports on apps with a Service Principal but zero
    federated credentials (useful for finding migration candidates per
    WorkloadIdentity-A.md Remediation Playbook 1). Normally excluded since
    an app with no federation configured has nothing to audit for THIS
    script's purpose.

.EXAMPLE
    .\Get-WorkloadIdentityAudit.ps1

    Full tenant audit of all apps with federated credentials configured.

.EXAMPLE
    .\Get-WorkloadIdentityAudit.ps1 -IncludeAppsWithoutFederation -OutputPath C:\Reports\WLI

    Also lists secret/cert-only apps as migration candidates, custom output folder.

.NOTES
    Requires: Microsoft.Graph.Applications, Microsoft.Graph.Identity.SignIns,
              Microsoft.Graph.Authentication
    Scopes needed: Application.Read.All, Policy.Read.All,
                   Organization.Read.All (for license SKU check)
    Run As: Any account with Global Reader, Application Administrator, or
            Security Reader role (Security Reader covers Conditional Access
            policy read access)
    Safe: Fully read-only — no federated credentials, Conditional Access
          policies, or Service Principals are modified, added, or removed
    Cross-references: EntraID/Troubleshooting/WorkloadIdentity-B.md (Triage
                       Steps 1-3, Fix 1, Fix 3) and WorkloadIdentity-A.md
                       (Validation Steps 1, 3, 4)
#>

[CmdletBinding()]
param(
    [string]$OutputPath = "$env:TEMP\WorkloadIdentityAudit-$(Get-Date -Format 'yyyyMMdd-HHmm')",

    [switch]$IncludeAppsWithoutFederation
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

$expectedAudience = "api://AzureADTokenExchange"

# ---- Preflight ----
foreach ($mod in @("Microsoft.Graph.Applications", "Microsoft.Graph.Identity.SignIns")) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Status "$mod module not found. Install with: Install-Module $mod" "ERROR"
        return
    }
}

$context = Get-MgContext
if (-not $context) {
    Write-Status "Not connected to Graph. Connecting with Application.Read.All, Policy.Read.All, Organization.Read.All..." "INFO"
    try {
        Connect-MgGraph -Scopes "Application.Read.All", "Policy.Read.All", "Organization.Read.All" -NoWelcome -ErrorAction Stop
    }
    catch {
        Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
        return
    }
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# ---- Detect: Workload Identities Premium licensing ----
Write-Status "Checking Workload Identities Premium licensing..." "INFO"
$wliSkus = @()
try {
    $wliSkus = Get-MgSubscribedSku -All -ErrorAction Stop | Where-Object { $_.SkuPartNumber -like "*WORKLOAD*" }
    if ($wliSkus) {
        foreach ($sku in $wliSkus) {
            $total = $sku.PrepaidUnits.Enabled
            $used  = $sku.ConsumedUnits
            $status = if ($used -ge $total) { "WARN" } else { "OK" }
            Write-Status "SKU $($sku.SkuPartNumber): $used / $total consumed." $status
        }
    }
    else {
        Write-Status "No Workload Identities Premium SKU found. Existing CA policies scoped to service principals keep enforcing, but cannot be created or modified until licensed." "WARN"
    }
}
catch {
    Write-Status "Could not read subscribed SKUs (needs Organization.Read.All): $($_.Exception.Message)" "WARN"
}

# ---- Detect: Conditional Access policies scoped to workload identities ----
Write-Status "Enumerating Conditional Access policies scoped to workload identities..." "INFO"
$wliPolicies = @()
try {
    $allPolicies = Get-MgIdentityConditionalAccessPolicy -All -ErrorAction Stop
    $wliPolicies = $allPolicies | Where-Object {
        $_.Conditions.ClientApplications -and (
            $_.Conditions.ClientApplications.IncludeServicePrincipals.Count -gt 0 -or
            $_.Conditions.ClientApplications.ExcludeServicePrincipals.Count -gt 0
        )
    }
    Write-Status "Found $($wliPolicies.Count) CA polic(y/ies) scoped to workload identities." "INFO"
}
catch {
    Write-Status "Could not enumerate Conditional Access policies (needs Policy.Read.All): $($_.Exception.Message)" "WARN"
}

$tenantWideWliPolicy = $wliPolicies | Where-Object {
    $_.Conditions.ClientApplications.IncludeServicePrincipals -contains "ServicePrincipalsInMyTenant" -and $_.State -eq "enabled"
}
if ($tenantWideWliPolicy) {
    Write-Status "$($tenantWideWliPolicy.Count) polic(y/ies) target ALL service principals tenant-wide (ServicePrincipalsInMyTenant) and are ENABLED — every federated app below is in scope of these regardless of individual listing." "WARN"
}

# ---- Detect: enumerate every Application object with federated credentials ----
Write-Status "Enumerating App Registrations and federated credentials..." "INFO"
try {
    $apps = Get-MgApplication -All -Property Id, AppId, DisplayName, FederatedIdentityCredentials -ErrorAction Stop
    Write-Status "Found $($apps.Count) App Registration(s) total. Auditing federation config..." "INFO"
}
catch {
    Write-Status "Failed to enumerate Application objects: $($_.Exception.Message)" "ERROR"
    return
}

$results = [System.Collections.Generic.List[object]]::new()
$i = 0

foreach ($app in $apps) {
    $i++
    if ($i % 50 -eq 0) { Write-Status "Processed $i of $($apps.Count)..." "INFO" }

    $fedCreds = @()
    try {
        $fedCreds = Get-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id -ErrorAction Stop
    }
    catch {
        # Some tenants restrict this call per-app; fall back to the property already fetched
        $fedCreds = $app.FederatedIdentityCredentials
    }

    if (($null -eq $fedCreds -or $fedCreds.Count -eq 0) -and -not $IncludeAppsWithoutFederation) {
        continue
    }

    # Corresponding Service Principal
    $spExists = $false
    $spEnabled = $null
    $spId = $null
    try {
        $sp = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'" -ErrorAction Stop
        if ($sp) {
            $spExists = $true
            $spEnabled = $sp.AccountEnabled
            $spId = $sp.Id
        }
    }
    catch { }

    # Does any CA policy target this SP directly (by Object ID)?
    $caTargeted = $false
    $caPolicyNames = @()
    if ($spId -and $wliPolicies.Count -gt 0) {
        $matches = $wliPolicies | Where-Object {
            $_.Conditions.ClientApplications.IncludeServicePrincipals -contains $spId -or
            $_.Conditions.ClientApplications.ExcludeServicePrincipals -contains $spId
        }
        if ($matches) {
            $caTargeted = $true
            $caPolicyNames = $matches | ForEach-Object { "$($_.DisplayName) [$($_.State)]" }
        }
    }
    if ($tenantWideWliPolicy) { $caTargeted = $true; $caPolicyNames += ($tenantWideWliPolicy | ForEach-Object { "$($_.DisplayName) [tenant-wide]" }) }

    $fedCredSummary = @()
    $suspectAudience = $false
    foreach ($fc in $fedCreds) {
        $audOk = ($fc.Audiences -contains $expectedAudience)
        if (-not $audOk) { $suspectAudience = $true }
        $fedCredSummary += "$($fc.Name): iss=$($fc.Issuer) sub=$($fc.Subject) aud=$($fc.Audiences -join ',')$(if (-not $audOk) { ' [NON-STANDARD AUDIENCE]' })"
    }

    # ---- Flags ----
    $flags = [System.Collections.Generic.List[string]]::new()
    if (-not $fedCreds -or $fedCreds.Count -eq 0) { $flags.Add("NO_FEDERATION_MIGRATION_CANDIDATE") }
    if ($suspectAudience)                         { $flags.Add("SUSPECT_AUDIENCE") }
    if (-not $spExists -and $fedCreds.Count -gt 0) { $flags.Add("NO_SERVICE_PRINCIPAL") }
    if ($spExists -and $spEnabled -eq $false)      { $flags.Add("SP_DISABLED") }
    if ($caTargeted)                               { $flags.Add("CA_TARGETED") }

    $results.Add([PSCustomObject]@{
        DisplayName        = $app.DisplayName
        AppId              = $app.AppId
        ServicePrincipalId = $spId
        ServicePrincipalExists  = $spExists
        ServicePrincipalEnabled = $spEnabled
        FederatedCredentialCount = $fedCreds.Count
        FederatedCredentials     = ($fedCredSummary -join " ;; ")
        ConditionalAccessTargeted = $caTargeted
        MatchingCAPolicies        = ($caPolicyNames -join " ;; ")
        Flags              = ($flags -join ";")
    })
}

# ---- Report ----
Write-Host ""
Write-Host "=== Workload Identity Federation & Conditional Access Audit Summary ===" -ForegroundColor Cyan
Write-Status "$($results.Count) app(s) evaluated (with federated credentials, unless -IncludeAppsWithoutFederation was used)." "INFO"

$needsReview = $results | Where-Object { $_.Flags -match "SUSPECT_AUDIENCE|NO_SERVICE_PRINCIPAL|SP_DISABLED" }
Write-Status "$($needsReview.Count) app(s) flagged for review (non-standard audience, missing Service Principal, or disabled Service Principal)." $(if ($needsReview.Count -gt 0) { "WARN" } else { "OK" })

$caTargetedCount = ($results | Where-Object { $_.ConditionalAccessTargeted }).Count
Write-Status "$caTargetedCount app(s) are directly targeted by a Conditional Access policy scoped to workload identities — check these first on any sudden 'pipeline can't auth' ticket before re-verifying federation config." "INFO"

if ($needsReview.Count -gt 0) {
    Write-Host ""
    Write-Host "--- Needs review ---" -ForegroundColor Yellow
    $needsReview | Select-Object DisplayName, AppId, FederatedCredentialCount, Flags | Format-Table -AutoSize -Wrap
}

$exportPath = Join-Path $OutputPath "WorkloadIdentityAudit.csv"
$results | Export-Csv -Path $exportPath -NoTypeInformation -Encoding UTF8

$reviewPath = Join-Path $OutputPath "NeedsReview.csv"
$needsReview | Export-Csv -Path $reviewPath -NoTypeInformation -Encoding UTF8

Write-Status "Full results exported to $exportPath" "OK"
Write-Status "Filtered needs-review list exported to $reviewPath" "OK"
