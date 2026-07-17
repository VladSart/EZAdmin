<#
.SYNOPSIS
    Audits Azure Key Vault configuration, authorization grants, network posture, certificate
    auto-rotation health, and soft-delete/purge-protection state across one or all vaults in
    the current subscription.

.DESCRIPTION
    Produces a read-only report covering:
      - Authorization model (RBAC vs. legacy Access Policy) and every principal with a grant
      - Network ACL posture (public/IP-restricted/private-endpoint) and private endpoint state
      - Soft-delete and purge-protection configuration
      - Certificate inventory with days-to-expiry and whether the issuing CA supports auto-rotation
      - Diagnostic logging presence (needed for any real incident investigation)

    Does not modify anything (no role assignments, access policies, network rules, or vault
    settings are changed). Safe to run at any time.

.PARAMETER ResourceGroupName
    Resource group containing the vault(s) to audit. If omitted with -AllVaults, scans the
    entire subscription.

.PARAMETER VaultName
    Name of a single Key Vault to audit. Mutually exclusive with -AllVaults.

.PARAMETER AllVaults
    Switch. Audit every Key Vault visible in the current subscription (optionally scoped to
    -ResourceGroupName). Slower — one extra set of calls per vault.

.PARAMETER CertExpiryWarningDays
    Flag certificates expiring within this many days as WARN. Defaults to 30.

.PARAMETER ExportPath
    Path to export the CSV report. Defaults to C:\Temp\KeyVaultAudit_<timestamp>.csv.

.EXAMPLE
    .\Get-KeyVaultAccessAudit.ps1 -ResourceGroupName 'rg-security-prod' -VaultName 'kv-contoso-prod'

.EXAMPLE
    .\Get-KeyVaultAccessAudit.ps1 -AllVaults -CertExpiryWarningDays 45

.NOTES
    Requires: Az.KeyVault, Az.Resources, Az.Accounts modules
    Install:  Install-Module Az.KeyVault, Az.Resources, Az.Accounts -Scope CurrentUser
    Permissions: Reader on the vault resource(s) is sufficient for control-plane properties;
                 a data-plane grant (Key Vault Reader role, or 'list' access policy permission)
                 is needed to enumerate certificates — the script degrades gracefully and flags
                 CertificateCheckFailed rather than throwing if that grant is missing.
    Safe to run: Read-only. No role assignments, access policies, network rules, certificate
                 operations, or vault settings are changed.
#>

[CmdletBinding(DefaultParameterSetName = 'SingleVault')]
param(
    [Parameter(ParameterSetName = 'SingleVault')]
    [Parameter(ParameterSetName = 'AllVaults')]
    [string]$ResourceGroupName,

    [Parameter(Mandatory, ParameterSetName = 'SingleVault')]
    [string]$VaultName,

    [Parameter(Mandatory, ParameterSetName = 'AllVaults')]
    [switch]$AllVaults,

    [int]$CertExpiryWarningDays = 30,

    [string]$ExportPath = "C:\Temp\KeyVaultAudit_$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

#region — Preflight
Write-Status "Azure Key Vault Access & Configuration Auditor" "INFO"
Write-Status "===============================================" "INFO"

$requiredModules = @('Az.Accounts', 'Az.KeyVault', 'Az.Resources')
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Status "Module '$mod' not found. Install with: Install-Module $mod -Scope CurrentUser" "ERROR"
        throw "Missing required module: $mod"
    }
}

try {
    $ctx = Get-AzContext
    if (-not $ctx) {
        Write-Status "No Azure context — launching interactive login..." "WARN"
        Connect-AzAccount
        $ctx = Get-AzContext
    }
    Write-Status "Azure context: $($ctx.Account.Id) | $($ctx.Subscription.Name)" "OK"
} catch {
    Write-Status "Failed to get Azure context: $_" "ERROR"
    throw
}

$outDir = Split-Path $ExportPath -Parent
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
#endregion

#region — Enumerate target vaults
Write-Status "Enumerating target vault(s)..." "INFO"
try {
    if ($PSCmdlet.ParameterSetName -eq 'SingleVault') {
        $targetVaults = @(Get-AzKeyVault -VaultName $VaultName -ResourceGroupName $ResourceGroupName)
    } elseif ($ResourceGroupName) {
        $targetVaults = Get-AzKeyVault -ResourceGroupName $ResourceGroupName
    } else {
        $targetVaults = Get-AzKeyVault
    }
} catch {
    Write-Status "Failed to enumerate vaults: $_" "ERROR"
    throw
}

if (-not $targetVaults -or $targetVaults.Count -eq 0) {
    Write-Status "No vaults found matching the given scope." "WARN"
    return
}
Write-Status "Found $($targetVaults.Count) vault(s) to audit." "OK"
#endregion

$vaultReport = [System.Collections.Generic.List[PSCustomObject]]::new()
$grantReport = [System.Collections.Generic.List[PSCustomObject]]::new()
$certReport  = [System.Collections.Generic.List[PSCustomObject]]::new()

$partneredIssuers = @('DigiCert', 'GlobalSign', 'OneCertV2-PublicCA', 'OneCertV2-PrivateCA')

foreach ($vRef in $targetVaults) {
    $vaultName = $vRef.VaultName
    $rg = $vRef.ResourceGroupName
    Write-Status "" "INFO"
    Write-Status "--- Vault: $vaultName (RG: $rg) ---" "INFO"

    try {
        $vault = Get-AzKeyVault -VaultName $vaultName -ResourceGroupName $rg
    } catch {
        Write-Status "  Failed to retrieve vault details: $_" "ERROR"
        continue
    }

    #region — Control-plane config
    $rbacMode = $vault.EnableRbacAuthorization
    $publicAccess = $vault.PublicNetworkAccess
    $netDefault = if ($vault.NetworkAcls) { $vault.NetworkAcls.DefaultAction } else { "Unknown" }
    $netBypass  = if ($vault.NetworkAcls) { $vault.NetworkAcls.Bypass } else { "Unknown" }
    $softDelete = $vault.EnableSoftDelete
    $softDeleteRetention = $vault.SoftDeleteRetentionInDays
    $purgeProtection = $vault.EnablePurgeProtection

    Write-Status "  Authorization model: $(if ($rbacMode) { 'RBAC' } else { 'Access Policy (legacy)' })" "INFO"
    Write-Status "  Public network access: $publicAccess | Network default action: $netDefault | Bypass: $netBypass" "INFO"
    if ($softDelete -and -not $purgeProtection) {
        Write-Status "  Soft-delete: ON ($softDeleteRetention days) | Purge protection: OFF" "WARN"
    } else {
        Write-Status "  Soft-delete: $softDelete ($softDeleteRetention days) | Purge protection: $purgeProtection" "OK"
    }

    $vaultEntry = [PSCustomObject]@{
        ReportType           = "VaultConfig"
        VaultName            = $vaultName
        ResourceGroup        = $rg
        AuthorizationModel   = if ($rbacMode) { "RBAC" } else { "AccessPolicy" }
        PublicNetworkAccess  = $publicAccess
        NetworkDefaultAction = $netDefault
        NetworkBypass        = $netBypass
        SoftDeleteEnabled    = $softDelete
        SoftDeleteRetention  = $softDeleteRetention
        PurgeProtection      = $purgeProtection
        DiagnosticsConfigured = "NotChecked"
    }

    try {
        $diag = Get-AzDiagnosticSetting -ResourceId $vault.ResourceId -ErrorAction SilentlyContinue
        $vaultEntry.DiagnosticsConfigured = ($diag -and $diag.Count -gt 0)
        if (-not $vaultEntry.DiagnosticsConfigured) {
            Write-Status "  Diagnostic logging: NOT CONFIGURED — no audit trail for access events" "WARN"
        }
    } catch {
        $vaultEntry.DiagnosticsConfigured = "CheckFailed"
    }

    $vaultReport.Add($vaultEntry)
    #endregion

    #region — Private endpoint state (only meaningful if network is restricted)
    if ($netDefault -eq "Deny") {
        try {
            $peConns = Get-AzPrivateEndpointConnection -PrivateLinkResourceId $vault.ResourceId -ErrorAction SilentlyContinue
            foreach ($pe in $peConns) {
                $state = $pe.PrivateLinkServiceConnectionState.Status
                $icon = if ($state -eq "Approved") { "OK" } else { "WARN" }
                Write-Status "  Private Endpoint: $($pe.Name) | State: $state" $icon
            }
            if (-not $peConns -and $publicAccess -eq "Disabled") {
                Write-Status "  Public access disabled but no private endpoint found — vault may be unreachable" "WARN"
            }
        } catch {
            Write-Status "  Could not read private endpoint connections: $_" "WARN"
        }
    }
    #endregion

    #region — Authorization grants
    try {
        if ($rbacMode) {
            $roles = Get-AzRoleAssignment -Scope $vault.ResourceId -ErrorAction SilentlyContinue
            foreach ($r in $roles) {
                $grantReport.Add([PSCustomObject]@{
                    VaultName      = $vaultName
                    Model          = "RBAC"
                    Principal      = $r.DisplayName
                    PrincipalType  = $r.ObjectType
                    Grant          = $r.RoleDefinitionName
                    Scope          = $r.Scope
                })
            }
            Write-Status "  RBAC role assignments: $($roles.Count)" "INFO"
            $adminGrants = $roles | Where-Object { $_.RoleDefinitionName -eq "Key Vault Administrator" }
            if ($adminGrants) {
                Write-Status "  $($adminGrants.Count) principal(s) hold 'Key Vault Administrator' — confirm these are intentional" "WARN"
            }
        } else {
            foreach ($p in $vault.AccessPolicies) {
                $grantReport.Add([PSCustomObject]@{
                    VaultName      = $vaultName
                    Model          = "AccessPolicy"
                    Principal      = $p.DisplayName
                    PrincipalType  = "N/A"
                    Grant          = "Secrets:[$($p.PermissionsToSecrets -join ',')] Keys:[$($p.PermissionsToKeys -join ',')] Certs:[$($p.PermissionsToCertificates -join ',')]"
                    Scope          = $vault.ResourceId
                })
            }
            Write-Status "  Access Policy grants: $($vault.AccessPolicies.Count)" "INFO"
        }
    } catch {
        Write-Status "  Could not enumerate authorization grants: $_" "WARN"
    }
    #endregion

    #region — Certificate auto-rotation health
    try {
        $certs = Get-AzKeyVaultCertificate -VaultName $vaultName -ErrorAction SilentlyContinue
        foreach ($c in $certs) {
            try {
                $full = Get-AzKeyVaultCertificate -VaultName $vaultName -Name $c.Name
                $daysLeft = if ($full.Expires) { [math]::Round(($full.Expires - (Get-Date)).TotalDays) } else { $null }
                $issuer = $full.Policy.IssuerName
                $autoRenewCapable = $issuer -in $partneredIssuers

                $status = "OK"
                if ($daysLeft -ne $null -and $daysLeft -le $CertExpiryWarningDays -and -not $autoRenewCapable) {
                    $status = "CRITICAL"
                } elseif ($daysLeft -ne $null -and $daysLeft -le $CertExpiryWarningDays) {
                    $status = "WARN"
                }

                $certReport.Add([PSCustomObject]@{
                    VaultName        = $vaultName
                    CertificateName  = $c.Name
                    Expires          = $full.Expires
                    DaysToExpiry     = $daysLeft
                    Issuer           = $issuer
                    AutoRenewCapable = $autoRenewCapable
                    Status           = $status
                })

                if ($status -eq "CRITICAL") {
                    Write-Status "  CERT $($c.Name): expires in $daysLeft day(s), issuer '$issuer' does NOT auto-renew — manual action required" "ERROR"
                } elseif ($status -eq "WARN") {
                    Write-Status "  CERT $($c.Name): expires in $daysLeft day(s), auto-renew capable ($issuer)" "WARN"
                }
            } catch {
                $certReport.Add([PSCustomObject]@{
                    VaultName = $vaultName; CertificateName = $c.Name; Expires = "CheckFailed"
                    DaysToExpiry = $null; Issuer = "CheckFailed"; AutoRenewCapable = $false; Status = "CheckFailed"
                })
            }
        }
        if ($certs.Count -eq 0) {
            Write-Status "  No certificates in this vault." "INFO"
        }
    } catch {
        Write-Status "  Could not enumerate certificates (data-plane permission likely missing): $_" "WARN"
    }
    #endregion
}

#region — Export and summary
Write-Status "" "INFO"
Write-Status "=== SUMMARY ===" "INFO"
Write-Status "Vaults audited: $($vaultReport.Count) | Grants found: $($grantReport.Count) | Certificates checked: $($certReport.Count)" "INFO"

$noPurgeProtection = $vaultReport | Where-Object { $_.SoftDeleteEnabled -and -not $_.PurgeProtection }
if ($noPurgeProtection) {
    Write-Status "Vaults with soft-delete but no purge protection (confirm intentional):" "WARN"
    $noPurgeProtection | Select-Object VaultName, ResourceGroup | Format-Table -AutoSize
}

$criticalCerts = $certReport | Where-Object { $_.Status -eq "CRITICAL" }
if ($criticalCerts) {
    Write-Status "Certificates expiring soon with NO auto-renewal — needs manual remediation:" "ERROR"
    $criticalCerts | Select-Object VaultName, CertificateName, DaysToExpiry, Issuer | Format-Table -AutoSize
}

$noDiagnostics = $vaultReport | Where-Object { $_.DiagnosticsConfigured -eq $false }
if ($noDiagnostics) {
    Write-Status "Vaults with no diagnostic logging configured:" "WARN"
    $noDiagnostics | Select-Object VaultName, ResourceGroup | Format-Table -AutoSize
}

$combined = @()
$combined += $vaultReport
$combined += $grantReport | ForEach-Object { $_ | Add-Member -NotePropertyName ReportType -NotePropertyValue "Grant" -PassThru }
$combined += $certReport  | ForEach-Object { $_ | Add-Member -NotePropertyName ReportType -NotePropertyValue "Certificate" -PassThru }

$combined | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Report exported: $ExportPath" "OK"
#endregion
