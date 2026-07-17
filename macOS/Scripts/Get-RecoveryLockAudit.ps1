<#
.SYNOPSIS
    Reports macOS Recovery Lock policy configuration, assignment targets, and fleet-wide device
    eligibility (chip supervision + check-in freshness) to speed up triage per RecoveryLock-B.md.

.DESCRIPTION
    Companion script to macOS/Troubleshooting/RecoveryLock-A.md and RecoveryLock-B.md.
    Recovery Lock's actual passcode value is never exposed via the general Graph device-management
    APIs used here — retrieving/rotating the passcode itself requires the "Remote tasks / View" and
    "Remote tasks / Rotate" RBAC permissions and is a per-device portal/action operation, not a
    bulk-queryable property (see RecoveryLock-A.md's RBAC section for why this is a deliberate
    security boundary, not a script limitation). This script instead answers the two questions that
    resolve the large majority of Recovery Lock tickets before you ever need to touch a passcode:

    1. FLEET ELIGIBILITY — for every enrolled macOS device, reports IsSupervised and LastSyncDateTime.
       An unsupervised device can NEVER receive a Recovery Lock policy (see RecoveryLock-B.md Fix 2) —
       flagging this up front prevents wasted troubleshooting on devices that were never eligible.
       Chip architecture (Apple Silicon vs. Intel) is NOT a reliably structured Graph property on
       managedDevice — this script reports the Model string so it can be cross-referenced manually
       against Apple's Apple-Silicon model identifier list; it does not attempt to parse/guess chip
       type from the model string, since a wrong guess here is worse than no guess.

    2. POLICY INVENTORY — lists every macOS Settings Catalog configuration policy whose display name
       matches "*Recovery Lock*" (case-insensitive), along with its assignment targets (group IDs).
       Matching is by display name because the underlying Settings Catalog setting-definition ID for
       this feature is not treated here as a stable, script-safe constant to filter on directly —
       policies should be named consistently (e.g. containing "Recovery Lock") for this to find them;
       if your tenant's naming convention differs, pass -PolicyNameFilter to override the match string.

    Read-only. Does not create, modify, assign, rotate, or view any Recovery Lock passcode, and does
    not modify any policy or assignment.

.PARAMETER PolicyNameFilter
    Substring to match Settings Catalog policy display names against (case-insensitive).
    Default: "Recovery Lock"

.PARAMETER StaleSyncDays
    Number of days since last successful check-in before a macOS device is flagged SYNC_STALE.
    Relevant because both scheduled rotation and policy-unassignment clearing are check-in-gated
    (RecoveryLock-A.md's "Check-in-gated rotation" section) — a stale device may be holding a Recovery
    Lock passcode that no longer matches what Intune's portal shows as current. Default 14.

.PARAMETER OutputPath
    Base path (without extension) to export two CSV reports:
    "<OutputPath>-Devices.csv" and "<OutputPath>-Policies.csv"
    Default: $env:TEMP\RecoveryLockAudit-<date>

.EXAMPLE
    .\Get-RecoveryLockAudit.ps1

.EXAMPLE
    .\Get-RecoveryLockAudit.ps1 -PolicyNameFilter "Recovery" -StaleSyncDays 7

.NOTES
    Requires: Microsoft.Graph.Beta.DeviceManagement, Microsoft.Graph.Beta.DeviceManagement.Actions
              modules, Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All",
              "DeviceManagementManagedDevices.Read.All"
    Run as:   Any account with Intune device configuration + managed device read rights
              (does NOT require the Recovery Lock "Remote tasks" View/Rotate permissions, since this
              script never touches the passcode value itself)
    Safe to run repeatedly — read-only, no changes made.
    Companion runbooks: macOS/Troubleshooting/RecoveryLock-A.md, RecoveryLock-B.md
    Related but distinct: FileVault Secure Token/Bootstrap Token eligibility follows the identical
    supervision prerequisite — see Scripts/Get-FileVaultStatus.sh for the device-local counterpart.
#>

[CmdletBinding()]
param(
    [string]$PolicyNameFilter = "Recovery Lock",
    [int]$StaleSyncDays = 14,
    [string]$OutputPath = "$env:TEMP\RecoveryLockAudit-$(Get-Date -Format 'yyyyMMdd-HHmm')"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

Write-Status "macOS Recovery Lock audit started — $(Get-Date)" "INFO"

# ─── Preflight ──────────────────────────────────────────────────────────────────

try {
    $ctx = Get-MgContext -ErrorAction Stop
    if (-not $ctx) { throw "No Graph context." }
    $requiredScopes = @("DeviceManagementConfiguration.Read.All", "DeviceManagementManagedDevices.Read.All")
    $missing = $requiredScopes | Where-Object { $ctx.Scopes -notcontains $_ }
    if ($missing) {
        Write-Status "Current Graph session is missing scope(s): $($missing -join ', ') — connecting again." "WARN"
        Connect-MgGraph -Scopes $requiredScopes -NoWelcome
    }
} catch {
    Write-Status "Not connected to Microsoft Graph. Connecting now..." "WARN"
    Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All","DeviceManagementManagedDevices.Read.All" -NoWelcome
}

foreach ($mod in @("Microsoft.Graph.Beta.DeviceManagement", "Microsoft.Graph.Beta.DeviceManagement.Actions")) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Status "$mod module not found. Install with:" "ERROR"
        Write-Status "  Install-Module $mod -Scope CurrentUser" "ERROR"
        exit 1
    }
}

# ─── Part 1: Policy inventory ───────────────────────────────────────────────────

Write-Status "Searching Settings Catalog policies matching '*$PolicyNameFilter*'..." "INFO"

try {
    $allPolicies = Get-MgBetaDeviceManagementConfigurationPolicy -All -ErrorAction Stop
} catch {
    Write-Status "Failed to query configuration policies: $($_.Exception.Message)" "ERROR"
    exit 1
}

$rlPolicies = $allPolicies | Where-Object { $_.Name -like "*$PolicyNameFilter*" }

$PolicyResults = [System.Collections.Generic.List[PSObject]]::new()

if (-not $rlPolicies -or $rlPolicies.Count -eq 0) {
    Write-Status "No Settings Catalog policies matched '*$PolicyNameFilter*'. If a Recovery Lock policy exists under a different name, re-run with -PolicyNameFilter." "WARN"
} else {
    foreach ($p in $rlPolicies) {
        $assignments = @()
        try {
            $assignments = Get-MgBetaDeviceManagementConfigurationPolicyAssignment -DeviceManagementConfigurationPolicyId $p.Id -ErrorAction Stop
        } catch {
            Write-Status "  Could not read assignments for policy '$($p.Name)': $($_.Exception.Message)" "WARN"
        }

        $targets = if ($assignments) {
            ($assignments | ForEach-Object {
                if ($_.Target.AdditionalProperties['groupId']) { $_.Target.AdditionalProperties['groupId'] }
                else { $_.Target.AdditionalProperties['@odata.type'] }
            }) -join "; "
        } else { "UNASSIGNED" }

        Write-Status "[$($p.Name)] platforms=$($p.Platforms) assignments=$targets" $(if ($targets -eq "UNASSIGNED") { "WARN" } else { "OK" })

        $PolicyResults.Add([PSCustomObject]@{
            PolicyId       = $p.Id
            PolicyName     = $p.Name
            Platforms      = $p.Platforms
            Technologies   = $p.Technologies
            AssignmentTargets = $targets
            LastModified   = $p.LastModifiedDateTime
        })
    }
}

# ─── Part 2: macOS fleet eligibility (supervision + sync freshness) ────────────

Write-Status "`nPulling macOS managed devices for eligibility check..." "INFO"

try {
    $macDevices = Get-MgBetaDeviceManagementManagedDevice -Filter "operatingSystem eq 'macOS'" -All -ErrorAction Stop
} catch {
    Write-Status "Failed to query managed devices: $($_.Exception.Message)" "ERROR"
    exit 1
}

if (-not $macDevices -or $macDevices.Count -eq 0) {
    Write-Status "No macOS managed devices found. Nothing further to report." "WARN"
    exit 0
}

Write-Status "Found $($macDevices.Count) macOS device(s) to evaluate." "INFO"
Write-Host ""

$now = Get-Date
$DeviceResults = [System.Collections.Generic.List[PSObject]]::new()

foreach ($d in $macDevices) {

    $lastSync = $d.LastSyncDateTime
    $daysSinceSync = if ($lastSync) { [math]::Round(($now - $lastSync).TotalDays, 1) } else { $null }

    $flags = [System.Collections.Generic.List[string]]::new()

    if (-not $d.IsSupervised) {
        $flags.Add("NOT_SUPERVISED_INELIGIBLE")
    }

    if ($null -eq $lastSync) {
        $flags.Add("NEVER_SYNCED")
    } elseif ($daysSinceSync -ge $StaleSyncDays) {
        $flags.Add("SYNC_STALE")
    }

    $status = if ($flags.Contains("NOT_SUPERVISED_INELIGIBLE")) {
        "WARN"
    } elseif ($flags.Contains("SYNC_STALE") -or $flags.Contains("NEVER_SYNCED")) {
        "WARN"
    } else {
        "OK"
    }

    Write-Status "[$($d.DeviceName)] model=$($d.Model) supervised=$($d.IsSupervised) lastSync=$lastSync ($daysSinceSync days ago)" $status
    if ($flags.Count -gt 0) {
        Write-Status "    Flags: $($flags -join ', ')" $status
    }

    $DeviceResults.Add([PSCustomObject]@{
        DeviceName        = $d.DeviceName
        SerialNumber      = $d.SerialNumber
        Model             = $d.Model
        OSVersion         = $d.OsVersion
        IsSupervised      = $d.IsSupervised
        EnrollmentType    = $d.DeviceEnrollmentType
        LastSyncDateTime  = $lastSync
        DaysSinceLastSync = $daysSinceSync
        Flags             = ($flags -join "; ")
        Status            = $status
    })
}

# ─── Summary ─────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== SUMMARY ===" -ForegroundColor Magenta

$notSupervised = $DeviceResults | Where-Object { $_.Flags -match "NOT_SUPERVISED_INELIGIBLE" }
$stale         = $DeviceResults | Where-Object { $_.Flags -match "SYNC_STALE|NEVER_SYNCED" }
$unassignedPol = $PolicyResults | Where-Object { $_.AssignmentTargets -eq "UNASSIGNED" }

Write-Status "Recovery Lock policies found:      $($PolicyResults.Count)"
Write-Status "  ...unassigned:                   $($unassignedPol.Count)" $(if ($unassignedPol.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "macOS devices evaluated:           $($DeviceResults.Count)"
Write-Status "  ...not supervised (ineligible):  $($notSupervised.Count)" $(if ($notSupervised.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "  ...stale/never synced (>=$StaleSyncDays days): $($stale.Count)" $(if ($stale.Count -gt 0) { "WARN" } else { "OK" })

if ($notSupervised.Count -gt 0) {
    Write-Host ""
    Write-Host "Devices flagged NOT_SUPERVISED_INELIGIBLE can NEVER receive Recovery Lock without a" -ForegroundColor Yellow
    Write-Host "wipe + re-enrollment through Apple Business Manager / ADE. See RecoveryLock-B.md Fix 2." -ForegroundColor Yellow
}

if ($stale.Count -gt 0) {
    Write-Host ""
    Write-Host "Stale devices may be holding an out-of-date Recovery Lock passcode if a rotation or" -ForegroundColor Yellow
    Write-Host "unassignment was issued since their last check-in — this is expected (check-in-gated" -ForegroundColor Yellow
    Write-Host "by design), not a fault. See RecoveryLock-A.md 'Check-in-gated rotation'." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Chip architecture (Apple Silicon vs Intel) is NOT reported above as a structured flag —" -ForegroundColor Yellow
Write-Host "cross-reference the Model column manually. This script cannot see the actual Recovery Lock" -ForegroundColor Yellow
Write-Host "passcode value; use Intune > device > Passwords and keys (requires View RBAC permission)." -ForegroundColor Yellow

# ─── Export ──────────────────────────────────────────────────────────────────────

$DeviceResults | Export-Csv -Path "$OutputPath-Devices.csv" -NoTypeInformation
$PolicyResults | Export-Csv -Path "$OutputPath-Policies.csv" -NoTypeInformation
Write-Status "`nDevice report:  $OutputPath-Devices.csv" "INFO"
Write-Status "Policy report:  $OutputPath-Policies.csv" "INFO"
Write-Status "Done." "OK"
