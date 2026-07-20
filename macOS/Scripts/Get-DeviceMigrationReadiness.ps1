<#
.SYNOPSIS
    Audits an Intune tenant's readiness for Apple Device Management Migration and Managed Migration Assistant (macOS 26+).

.DESCRIPTION
    Read-only, Graph-based fleet sweep that answers the pre-migration planning questions covered in
    DeviceMigration-A.md Playbook 4 (fleet-wide MSP audit sweep) before an admin ever opens Apple Business
    Manager / Apple School Manager to trigger a migration.

    Part 1 — checks the Apple MDM Push (APNs) certificate and every ABM/ASM (DEP) token for expiry, since
             both underlie ALL MDM communication and are a hard prerequisite for either migration mechanism.
    Part 2 — enumerates every managed macOS device and classifies each one:
               READY_BOTH                  - macOS 26.4+, eligible for both mechanisms
               READY_MDM_MIGRATION_ONLY    - macOS 26.0-26.3, eligible for Device Management Migration only
                                              (below the Managed Migration Assistant destination floor)
               NOT_READY                   - below macOS 26.0, not eligible for either mechanism
    Part 3 — flags devices with no signed-in user (device-based / shared-license enrollment) as
             DEVICE_BASED_NO_USER, informational only: the default migration approval flow is user-driven,
             so these devices need a deliberately-planned deadline-enforced (unattended) migration path
             rather than relying on self-service user approval.
    Part 4 — searches assigned Settings Catalog policies for anything matching the Migration Assistant /
             System Migration configuration category, to confirm whether Managed Migration Assistant has
             actually been configured anywhere in the tenant (setting-definition-ID substring match, since
             Graph does not expose a single reliable "isMigrationAssistantPolicy" boolean at the policy level
             — the same pattern already used by this repo's WiFi-8021x and Gatekeeper audit scripts).

    Deliberately does NOT touch Apple Business Manager / Apple School Manager itself (pending migrations,
    Activity log, MDM server token status) — none of that is exposed via Microsoft Graph. Those checks stay
    manual in the ABM/ASM console per DeviceMigration-A.md's Validation Steps 2 and 4. Does NOT trigger,
    approve, or cancel any migration — read-only inventory and readiness classification only.

.PARAMETER MinDeviceThreshold
    Minimum number of eligible macOS devices before the summary flags the tenant as too small for a
    meaningful fleet-wide migration rollout signal. Default 1 (informational only, does not block output).

.PARAMETER TokenExpiryWarningDays
    Number of days before APNs/ABM-ASM token expiry to flag as WARN rather than OK. Default 30.

.EXAMPLE
    .\Get-DeviceMigrationReadiness.ps1
    Runs a full tenant sweep and writes DeviceMigrationReadiness-<timestamp>.csv to the current directory.

.EXAMPLE
    .\Get-DeviceMigrationReadiness.ps1 -TokenExpiryWarningDays 60
    Same sweep, with token-expiry warnings raised 60 days out instead of the default 30.

.NOTES
    Requires: Microsoft.Graph.Authentication module, Graph scopes DeviceManagementServiceConfig.Read.All,
    DeviceManagementManagedDevices.Read.All, DeviceManagementConfiguration.Read.All.
    Run-as: any account with Intune read access to the above scopes — no write/administrative permission needed.
    Safe: fully read-only. No devices are modified, no migrations are triggered, cancelled, or altered.
#>

[CmdletBinding()]
param(
    [int]$MinDeviceThreshold = 1,
    [int]$TokenExpiryWarningDays = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-OSVersionSafe {
    param([string]$RawVersion)
    # osVersion from Graph is sometimes a bare build-style string; strip anything after the numeric dotted portion
    $clean = ($RawVersion -replace '[^\d.].*$', '').TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($clean)) { return $null }
    try { return [version]$clean } catch { return $null }
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Starting Apple Device Migration readiness sweep..." "INFO"

try {
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
} catch {
    Write-Status "Microsoft.Graph.Authentication module not found. Install with: Install-Module Microsoft.Graph -Scope CurrentUser" "ERROR"
    throw
}

try {
    Connect-MgGraph -Scopes "DeviceManagementServiceConfig.Read.All","DeviceManagementManagedDevices.Read.All","DeviceManagementConfiguration.Read.All" -NoWelcome -ErrorAction Stop
    Write-Status "Connected to Microsoft Graph." "OK"
} catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    throw
}

$results = [ordered]@{
    ApnsCertificate      = $null
    DepTokens            = @()
    MacOSDevices         = @()
    MigrationPolicies    = @()
}

# ---------------------------------------------------------------------------
# Part 1 — APNs certificate + ABM/ASM (DEP) token health
# ---------------------------------------------------------------------------
Write-Status "Part 1: Checking APNs certificate and ABM/ASM token expiry..." "INFO"

try {
    $push = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceManagement/applePushNotificationCertificate"
    $expiry = $null
    if ($push.expirationDateTime) { $expiry = [datetime]$push.expirationDateTime }
    $daysLeft = if ($expiry) { ($expiry - (Get-Date)).Days } else { $null }
    $status = if ($null -eq $daysLeft) { "CheckFailed" } elseif ($daysLeft -lt 0) { "EXPIRED" } elseif ($daysLeft -le $TokenExpiryWarningDays) { "EXPIRING_SOON" } else { "OK" }

    $results.ApnsCertificate = [PSCustomObject]@{
        AppleIdentifier    = $push.appleIdentifier
        ExpirationDateTime = $expiry
        DaysUntilExpiry    = $daysLeft
        Status             = $status
    }

    if ($status -eq "EXPIRED") { Write-Status "APNs certificate is EXPIRED — all MDM communication is broken, both migration mechanisms are blocked." "ERROR" }
    elseif ($status -eq "EXPIRING_SOON") { Write-Status "APNs certificate expires in $daysLeft day(s) — renew before planning any migration." "WARN" }
    else { Write-Status "APNs certificate OK ($daysLeft day(s) remaining)." "OK" }
} catch {
    Write-Status "Could not retrieve APNs certificate — caller may lack permission or no cert configured. $($_.Exception.Message)" "WARN"
    $results.ApnsCertificate = [PSCustomObject]@{ Status = "CheckFailed"; Error = $_.Exception.Message }
}

try {
    $dep = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceManagement/depOnboardingSettings"
    foreach ($token in $dep.value) {
        $expiry = $null
        if ($token.tokenExpirationDateTime) { $expiry = [datetime]$token.tokenExpirationDateTime }
        $daysLeft = if ($expiry) { ($expiry - (Get-Date)).Days } else { $null }
        $status = if ($null -eq $daysLeft) { "CheckFailed" } elseif ($daysLeft -lt 0) { "EXPIRED" } elseif ($daysLeft -le $TokenExpiryWarningDays) { "EXPIRING_SOON" } else { "OK" }

        $results.DepTokens += [PSCustomObject]@{
            TokenName          = $token.tokenName
            AppleIdentifier    = $token.appleIdentifier
            ExpirationDateTime = $expiry
            DaysUntilExpiry    = $daysLeft
            Status             = $status
        }

        if ($status -eq "EXPIRED") { Write-Status "ABM/ASM token '$($token.tokenName)' is EXPIRED." "ERROR" }
        elseif ($status -eq "EXPIRING_SOON") { Write-Status "ABM/ASM token '$($token.tokenName)' expires in $daysLeft day(s)." "WARN" }
    }
    Write-Status "Found $($results.DepTokens.Count) ABM/ASM token(s)." "OK"
} catch {
    Write-Status "Could not retrieve ABM/ASM tokens: $($_.Exception.Message)" "WARN"
}

# ---------------------------------------------------------------------------
# Part 2 & 3 — macOS fleet OS-version readiness + device-based/no-user flag
# ---------------------------------------------------------------------------
Write-Status "Part 2/3: Enumerating managed macOS devices for migration readiness..." "INFO"

$mdmMigrationFloor = [version]"26.0"
$mmaFloor           = [version]"26.4"

try {
    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=operatingSystem eq 'macOS'"
    $allDevices = @()
    while ($uri) {
        $page = Invoke-MgGraphRequest -Method GET -Uri $uri
        $allDevices += $page.value
        $uri = $page.'@odata.nextLink'
    }

    foreach ($d in $allDevices) {
        $ver = Get-OSVersionSafe -RawVersion $d.osVersion
        $readiness = if ($null -eq $ver) {
            "UNKNOWN_OS_VERSION"
        } elseif ($ver -ge $mmaFloor) {
            "READY_BOTH"
        } elseif ($ver -ge $mdmMigrationFloor) {
            "READY_MDM_MIGRATION_ONLY"
        } else {
            "NOT_READY"
        }

        $noUser = [string]::IsNullOrWhiteSpace($d.userPrincipalName)

        $results.MacOSDevices += [PSCustomObject]@{
            DeviceName       = $d.deviceName
            SerialNumber     = $d.serialNumber
            OSVersion        = $d.osVersion
            EnrollmentType   = $d.enrollmentType
            UserPrincipalName = $d.userPrincipalName
            Readiness        = $readiness
            DeviceBasedNoUser = if ($noUser) { "DEVICE_BASED_NO_USER" } else { "" }
            LastSyncDateTime = $d.lastSyncDateTime
        }
    }

    $summary = $results.MacOSDevices | Group-Object Readiness | Select-Object Name, Count
    Write-Status "macOS fleet: $($results.MacOSDevices.Count) device(s) total." "OK"
    $summary | ForEach-Object { Write-Status "  $($_.Name): $($_.Count)" "INFO" }

    $noUserCount = ($results.MacOSDevices | Where-Object { $_.DeviceBasedNoUser -eq "DEVICE_BASED_NO_USER" }).Count
    if ($noUserCount -gt 0) {
        Write-Status "$noUserCount device(s) have no signed-in user — plan a deadline-enforced migration path for these, self-service approval won't apply." "WARN"
    }

    if ($results.MacOSDevices.Count -lt $MinDeviceThreshold) {
        Write-Status "Fleet size ($($results.MacOSDevices.Count)) is below the informational threshold ($MinDeviceThreshold) — treat readiness numbers as directional only." "WARN"
    }
} catch {
    Write-Status "Could not enumerate managed macOS devices: $($_.Exception.Message)" "ERROR"
}

# ---------------------------------------------------------------------------
# Part 4 — Migration Assistant declarative policy presence (best-effort)
# ---------------------------------------------------------------------------
Write-Status "Part 4: Checking for a configured Managed Migration Assistant policy..." "INFO"

try {
    $uri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?`$filter=technologies has 'appleRemoteManagement'"
    $policies = @()
    while ($uri) {
        $page = Invoke-MgGraphRequest -Method GET -Uri $uri
        $policies += $page.value
        $uri = $page.'@odata.nextLink'
    }

    $migrationPolicies = $policies | Where-Object { $_.name -match "[Mm]igrat" }
    $results.MigrationPolicies = $migrationPolicies | Select-Object id, name, lastModifiedDateTime

    if ($migrationPolicies.Count -eq 0) {
        Write-Status "No Settings Catalog policy matching 'Migration' found by name — this is a best-effort name match, not a guaranteed absence. Confirm manually in the Intune portal (Devices > macOS > Configuration) if Managed Migration Assistant is expected to be in use." "WARN"
    } else {
        Write-Status "Found $($migrationPolicies.Count) candidate Migration Assistant polic(y/ies) by name — verify assignment scope in the Intune portal." "OK"
    }
} catch {
    Write-Status "Could not check Settings Catalog policies (may require DeviceManagementConfiguration.Read.All, or the beta endpoint may be unavailable): $($_.Exception.Message)" "WARN"
    $results.MigrationPolicies = @([PSCustomObject]@{ Status = "CheckFailed"; Error = $_.Exception.Message })
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$csvPath = ".\DeviceMigrationReadiness-$timestamp.csv"

Write-Status "Writing device readiness detail to $csvPath ..." "INFO"
$results.MacOSDevices | Export-Csv -Path $csvPath -NoTypeInformation

Write-Status "Sweep complete." "OK"
Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "APNs certificate:     $($results.ApnsCertificate.Status)"
Write-Host "ABM/ASM tokens:       $($results.DepTokens.Count) checked"
Write-Host "macOS devices:        $($results.MacOSDevices.Count) total"
Write-Host "Migration policies:   $($results.MigrationPolicies.Count) candidate(s) found"
Write-Host "Detail CSV:           $csvPath"
Write-Host ""
Write-Host "Reminder: pending migrations, the ABM/ASM Activity log, and destination MDM server token status are" -ForegroundColor DarkGray
Write-Host "NOT exposed via Graph and must be checked directly in Apple Business Manager / Apple School Manager." -ForegroundColor DarkGray
