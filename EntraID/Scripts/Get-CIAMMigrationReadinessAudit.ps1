<#
.SYNOPSIS
    Read-only readiness/health audit for Entra External ID for customers (CIAM)
    Just-In-Time (JIT) password migration — the custom authentication extension,
    listener policy, encryption key consistency, and admin consent state.

.DESCRIPTION
    JIT password migration has no dedicated PowerShell module — its configuration
    lives in beta Microsoft Graph endpoints (customAuthenticationExtensions,
    authenticationEventListeners) reached here via Invoke-MgGraphRequest. This
    script audits only what is programmatically readable:

      1. Existence of the OnPasswordSubmit custom authentication extension
      2. Listener policy state: priority, scoped application(s), handler config
      3. Encryption key consistency on the extension app (keyId vs.
         tokenEncryptionKeyId, certificate expiry)
      4. Admin consent grant for CustomAuthenticationExtension.Receive.Payload
         on the extension app's service principal
      5. RBAC — which tenant role holders currently hold each of the three
         roles required to manage this feature (Application Administrator,
         User Administrator, Authentication Extensibility Password Administrator)
      6. disableStrongPassword current state (flagged for time-box review —
         this option carries an explicit, Microsoft-documented security trade-off)

    Does NOT read, change, or attempt to infer: per-user migration flag
    distribution across the full user base, sign-in log error-code volume/
    throttling patterns, or Azure Function-side logs — all explicitly portal/
    Application-Insights-only and out of scope for this script. This script
    performs zero write operations.

.PARAMETER ExtensionAppObjectId
    Object ID (not app/client ID) of the custom authentication extension's
    app registration, for key-consistency and admin-consent checks.

.PARAMETER ClientAppId
    Application (client) ID of the app users sign into, used to cross-check
    that a listener policy actually scopes to it.

.PARAMETER OutputPath
    Folder to write the CSV export to. Default: current directory.

.EXAMPLE
    .\Get-CIAMMigrationReadinessAudit.ps1 -ExtensionAppObjectId "11111111-2222-3333-4444-555555555555"

.EXAMPLE
    .\Get-CIAMMigrationReadinessAudit.ps1 `
        -ExtensionAppObjectId "11111111-2222-3333-4444-555555555555" `
        -ClientAppId "66666666-7777-8888-9999-000000000000" `
        -OutputPath "C:\Evidence"

.NOTES
    Requires: Microsoft.Graph.Applications, Microsoft.Graph.Users,
    Microsoft.Graph.Identity.DirectoryManagement PowerShell modules; a signed-in
    Microsoft Graph session (Connect-MgGraph -Scopes "Application.Read.All",
    "Policy.Read.All","User.Read.All","RoleManagement.Read.Directory") against
    the target External ID for customers tenant, plus beta endpoint access for
    Invoke-MgGraphRequest calls (customAuthenticationExtensions,
    authenticationEventListeners have no stable v1.0 cmdlet surface yet).
    Read-only. No Set-/New-/Remove-/Update- cmdlets or beta PATCH/POST/DELETE
    calls are used anywhere in this script's executable code.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ExtensionAppObjectId,

    [Parameter(Mandatory = $false)]
    [string]$ClientAppId,

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
} catch {
    Write-Status "Not connected to Microsoft Graph. Run Connect-MgGraph -Scopes 'Application.Read.All','Policy.Read.All','User.Read.All','RoleManagement.Read.Directory' first." -Status "ERROR"
    throw
}

# ------------------------------------------------------------------
# 1. Custom authentication extension existence
# ------------------------------------------------------------------
Write-Status "Checking for an OnPasswordSubmit custom authentication extension..."
$extensions = $null
try {
    $resp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identity/customAuthenticationExtensions" -ErrorAction Stop
    $extensions = $resp.value | Where-Object { $_."@odata.type" -match "onPasswordSubmit" }

    if (-not $extensions -or @($extensions).Count -eq 0) {
        Write-Status "No onPasswordSubmit custom authentication extension found in this tenant." -Status "ERROR"
        $results.Add([PSCustomObject]@{ Category = "Extension"; Item = "OnPasswordSubmit extension"; Status = "FAIL"; Detail = "None found — JIT migration is not configured, or this is the wrong tenant." })
    } else {
        foreach ($ext in @($extensions)) {
            $disableStrong = if ($ext.PSObject.Properties.Name -contains "disableStrongPassword") { $ext.disableStrongPassword } else { $null }
            $results.Add([PSCustomObject]@{
                Category = "Extension"
                Item     = $ext.displayName
                Status   = "OK"
                Detail   = "id=$($ext.id); targetUrl=$($ext.endpointConfiguration.targetUrl); disableStrongPassword=$disableStrong; timeoutMs=$($ext.clientConfiguration.timeoutInMilliseconds); maxRetries=$($ext.clientConfiguration.maximumRetries)"
            })
            Write-Status "Found extension '$($ext.displayName)' (id=$($ext.id)); disableStrongPassword=$disableStrong" -Status "OK"

            if ($disableStrong -eq $true) {
                Write-Status "  disableStrongPassword is ENABLED — this is a time-boxed security trade-off per Microsoft's own guidance. Confirm an end date is planned." -Status "WARN"
                $results.Add([PSCustomObject]@{ Category = "Extension"; Item = "$($ext.displayName) / disableStrongPassword"; Status = "WARN"; Detail = "Enabled — verify this is still within an intentional, time-boxed coexistence window (see CIAMMigration-A.md Playbook 3)." })
            }

            $targetUrl = $ext.endpointConfiguration.targetUrl
            if ($targetUrl -match "graph\.microsoft\.com|login\.microsoftonline\.com|\.b2clogin\.com") {
                Write-Status "  targetUrl looks like it may point at Graph/Entra/a legacy sign-in endpoint — this violates the required endpoint shape." -Status "ERROR"
                $results.Add([PSCustomObject]@{ Category = "Extension"; Item = "$($ext.displayName) / targetUrl"; Status = "FAIL"; Detail = "targetUrl=$targetUrl — must be a customer-hosted HTTPS endpoint, not a Microsoft/legacy sign-in URL." })
            }
        }
    }
} catch {
    Write-Status "Could not query customAuthenticationExtensions: $($_.Exception.Message)" -Status "WARN"
    $results.Add([PSCustomObject]@{ Category = "Extension"; Item = "OnPasswordSubmit extension"; Status = "ERROR"; Detail = $_.Exception.Message })
}

# ------------------------------------------------------------------
# 2. Listener policy state
# ------------------------------------------------------------------
Write-Status "Checking onPasswordSubmitListener policies..."
try {
    $resp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identity/authenticationEventListeners" -ErrorAction Stop
    $listeners = $resp.value | Where-Object { $_."@odata.type" -match "onPasswordSubmitListener" }

    if (-not $listeners -or @($listeners).Count -eq 0) {
        Write-Status "No onPasswordSubmitListener policy found." -Status "ERROR"
        $results.Add([PSCustomObject]@{ Category = "Listener"; Item = "onPasswordSubmitListener"; Status = "FAIL"; Detail = "None found — the extension will never be invoked even if it exists." })
    } else {
        $byApp = @{}
        foreach ($l in @($listeners)) {
            $apps = @($l.conditions.applications.includeApplications | ForEach-Object { $_.appId })
            $results.Add([PSCustomObject]@{
                Category = "Listener"
                Item     = $l.id
                Status   = "OK"
                Detail   = "priority=$($l.priority); includeApplications=$($apps -join ','); migrationPropertyId=$($l.handler.migrationPropertyId); customExtensionId=$($l.handler.customExtension.id)"
            })
            foreach ($a in $apps) {
                if (-not $byApp.ContainsKey($a)) { $byApp[$a] = @() }
                $byApp[$a] += $l.id
            }
            if ($ClientAppId -and ($apps -notcontains $ClientAppId)) {
                Write-Status "  Listener $($l.id) does not include the specified ClientAppId ($ClientAppId)." -Status "WARN"
            }
        }
        foreach ($a in $byApp.Keys) {
            if ($byApp[$a].Count -gt 1) {
                Write-Status "App $a has $($byApp[$a].Count) onPasswordSubmitListener policies attached — check priority for conflicts." -Status "WARN"
                $results.Add([PSCustomObject]@{ Category = "Listener"; Item = "App $a / multiple listeners"; Status = "WARN"; Detail = "Listener IDs: $($byApp[$a] -join ', ') — verify intended priority ordering." })
            }
        }
    }
} catch {
    Write-Status "Could not query authenticationEventListeners: $($_.Exception.Message)" -Status "WARN"
    $results.Add([PSCustomObject]@{ Category = "Listener"; Item = "onPasswordSubmitListener"; Status = "ERROR"; Detail = $_.Exception.Message })
}

# ------------------------------------------------------------------
# 3. Encryption key consistency + 4. Admin consent (per extension app)
# ------------------------------------------------------------------
if ($ExtensionAppObjectId) {
    Write-Status "Checking encryption key consistency for app $ExtensionAppObjectId..."
    try {
        $app = Get-MgApplication -ApplicationId $ExtensionAppObjectId -ErrorAction Stop
        $tokenKeyId = $app.AdditionalProperties["tokenEncryptionKeyId"]
        $matchingCert = $app.KeyCredentials | Where-Object { $_.KeyId -eq $tokenKeyId }

        if (-not $tokenKeyId) {
            Write-Status "  No tokenEncryptionKeyId set on the app." -Status "ERROR"
            $results.Add([PSCustomObject]@{ Category = "EncryptionKey"; Item = $ExtensionAppObjectId; Status = "FAIL"; Detail = "tokenEncryptionKeyId is not set." })
        } elseif (-not $matchingCert) {
            Write-Status "  tokenEncryptionKeyId ($tokenKeyId) does not match any keyCredentials entry." -Status "ERROR"
            $results.Add([PSCustomObject]@{ Category = "EncryptionKey"; Item = $ExtensionAppObjectId; Status = "FAIL"; Detail = "tokenEncryptionKeyId=$tokenKeyId has no matching KeyCredentials.KeyId — decryption will fail for every call." })
        } else {
            $expired = $matchingCert.EndDateTime -lt (Get-Date)
            $results.Add([PSCustomObject]@{
                Category = "EncryptionKey"
                Item     = $ExtensionAppObjectId
                Status   = if ($expired) { "FAIL" } else { "OK" }
                Detail   = "keyId=$tokenKeyId matches a KeyCredentials entry; EndDateTime=$($matchingCert.EndDateTime); Expired=$expired"
            })
            Write-Status "  Key match OK; cert EndDateTime=$($matchingCert.EndDateTime) (Expired=$expired)" -Status $(if ($expired) { "ERROR" } else { "OK" })
        }

        Write-Status "Checking admin consent for CustomAuthenticationExtension.Receive.Payload..."
        $sp = Get-MgServicePrincipal -Filter "AppId eq '$($app.AppId)'" -ErrorAction SilentlyContinue
        if (-not $sp) {
            Write-Status "  No service principal found for this app — it may never have been consented." -Status "ERROR"
            $results.Add([PSCustomObject]@{ Category = "AdminConsent"; Item = $ExtensionAppObjectId; Status = "FAIL"; Detail = "No matching service principal (AppId=$($app.AppId))." })
        } else {
            $graphSp = Get-MgServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'" -ErrorAction Stop
            $assignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -ErrorAction SilentlyContinue
            $roleAssigned = $assignments | Where-Object { $_.ResourceId -eq $graphSp.Id }
            $hasConsent = [bool]$roleAssigned
            $results.Add([PSCustomObject]@{
                Category = "AdminConsent"
                Item     = $ExtensionAppObjectId
                Status   = if ($hasConsent) { "OK" } else { "FAIL" }
                Detail   = "Graph application permission grant present=$hasConsent (expected: CustomAuthenticationExtension.Receive.Payload)"
            })
            Write-Status "  Admin consent present: $hasConsent" -Status $(if ($hasConsent) { "OK" } else { "ERROR" })
        }
    } catch {
        Write-Status "Could not check key consistency/admin consent: $($_.Exception.Message)" -Status "WARN"
        $results.Add([PSCustomObject]@{ Category = "EncryptionKey"; Item = $ExtensionAppObjectId; Status = "ERROR"; Detail = $_.Exception.Message })
    }
} else {
    Write-Status "Skipping encryption-key and admin-consent checks — -ExtensionAppObjectId not supplied." -Status "WARN"
}

# ------------------------------------------------------------------
# 5. RBAC — role holders for the three required roles
# ------------------------------------------------------------------
Write-Status "Checking role holders for the three required admin roles..."
$requiredRoles = @(
    "Application Administrator",
    "User Administrator",
    "Authentication Extensibility Password Administrator"
)
foreach ($roleName in $requiredRoles) {
    try {
        $roleDef = Get-MgDirectoryRole -Filter "displayName eq '$roleName'" -ErrorAction SilentlyContinue
        if (-not $roleDef) {
            Write-Status "  Role '$roleName' is not activated in this tenant (no one has ever been assigned it)." -Status "WARN"
            $results.Add([PSCustomObject]@{ Category = "RBAC"; Item = $roleName; Status = "WARN"; Detail = "Role not activated — no directoryRole instance exists yet." })
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

# ------------------------------------------------------------------
# Known Gaps — explicitly not covered by this script
# ------------------------------------------------------------------
$knownGaps = @(
    "Per-user toBeMigrated flag distribution across the full user base — requires enumerating extension attributes tenant-wide; run only against a targeted user list, not attempted here."
    "Sign-in log error-code volume/throttling pattern analysis (CustomExtensionThrottlingError, CustomExtensionTimedOut) — pull from sign-in logs / Log Analytics directly."
    "Azure Function-side logs and exception traces — check Application Insights / Function App logs directly, not readable via Graph."
    "Legacy identity provider-side health/outage status — outside Entra's telemetry entirely."
    "Whether the tenant is genuinely an External ID for customers (CIAM) tenant vs. workforce — confirm via the admin center Overview blade; not reliably distinguishable via a single Graph property checked here."
)
foreach ($gap in $knownGaps) {
    $results.Add([PSCustomObject]@{ Category = "KnownGap"; Item = "Manual verification required"; Status = "INFO"; Detail = $gap })
}

# ------------------------------------------------------------------
# Report
# ------------------------------------------------------------------
Write-Status "=== Summary ===" -Status "INFO"
$results | Group-Object Status | ForEach-Object { Write-Status "$($_.Name): $($_.Count)" }

$exportFile = Join-Path -Path $OutputPath -ChildPath "CIAMMigration-ReadinessAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$results | Export-Csv -Path $exportFile -NoTypeInformation
Write-Status "Full results exported to $exportFile" -Status "OK"

$results
