<#
.SYNOPSIS
    Audits Power Apps/Dataverse environments tenant-wide for capacity risk, stale provisioning,
    and the "Enable Dynamics 365 apps" decision state.

.DESCRIPTION
    Local diagnostic companion to PowerAutomate/PowerApps/Environment-Dataverse-A.md and -B.md.

    Enumerates every environment in the tenant and flags the conditions those runbooks identify as
    the most common root causes for environment-admin tickets: environments stuck mid-provisioning,
    Trial/Sandbox environments that are old enough to be reclaimable capacity (the runbook's #1 fix
    for "not enough capacity" errors), and a summary of which environments have a Dataverse database
    with Dynamics 365 apps enabled vs. not — since that decision is irreversible per-environment and
    worth having in one inventory view before any new-environment request.

    This script does NOT read individual user role assignments or maker-portal/flow-portal visibility
    (those are evaluated per-user by each portal independently and aren't fully exposed via the
    admin PowerShell module today — see the runbook's Validation Steps for the portal-specific manual
    checks). It also does NOT delete, modify, or provision anything — read-only reporting only.

.PARAMETER StaleThresholdDays
    Age (in days since creation) beyond which a Trial or Sandbox environment with no recent
    indication of active use is flagged as a capacity-reclaim candidate. Default: 90.

.PARAMETER OutputPath
    Folder to write the CSV report to. Default: $env:TEMP.

.EXAMPLE
    .\Get-PowerAppsEnvironmentAudit.ps1
    Runs a full tenant environment audit with default settings.

.EXAMPLE
    .\Get-PowerAppsEnvironmentAudit.ps1 -StaleThresholdDays 30 -OutputPath C:\Temp\Evidence
    Flags Trial/Sandbox environments older than 30 days as reclaim candidates.

.NOTES
    Requires: Microsoft.PowerApps.Administration.PowerShell module, connected via Add-PowerAppsAccount
              as a user with Power Platform administrator or Dynamics 365 administrator rights.
              Install-Module -Name Microsoft.PowerApps.Administration.PowerShell -Scope CurrentUser
    Safe: Read-only. No environments are created, modified, or deleted.
    Companion runbooks: PowerAutomate/PowerApps/Environment-Dataverse-A.md (deep dive),
                         PowerAutomate/PowerApps/Environment-Dataverse-B.md (hotfix triage).
#>
[CmdletBinding()]
param(
    [int]$StaleThresholdDays = 90,
    [string]$OutputPath = $env:TEMP
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Module / connection check
# ---------------------------------------------------------------------------
If (-not (Get-Module -ListAvailable -Name Microsoft.PowerApps.Administration.PowerShell)) {
    Write-Status "Microsoft.PowerApps.Administration.PowerShell module not found. Install with:" "ERROR"
    Write-Status "  Install-Module -Name Microsoft.PowerApps.Administration.PowerShell -Scope CurrentUser" "ERROR"
    return
}
Import-Module Microsoft.PowerApps.Administration.PowerShell -ErrorAction Stop

Write-Status "Enumerating environments (requires an active Add-PowerAppsAccount session)..."
Try {
    $environments = Get-AdminPowerAppEnvironment -ErrorAction Stop
} Catch {
    Write-Status "Failed to enumerate environments — confirm Add-PowerAppsAccount has been run and the account has Power Platform/Dynamics 365 admin rights." "ERROR"
    Write-Status $_.Exception.Message "ERROR"
    return
}

If (-not $environments -or $environments.Count -eq 0) {
    Write-Status "No environments returned. Confirm admin scope/connection." "WARN"
    return
}

Write-Status "Found $($environments.Count) environment(s). Building audit report..." "OK"

# ---------------------------------------------------------------------------
# Build audit rows
# ---------------------------------------------------------------------------
$now = Get-Date
$rows = @()

foreach ($e in $environments) {
    $hasDb = $false
    Try { $hasDb = ($null -ne $e.CommonDataServiceDatabaseType -and $e.CommonDataServiceDatabaseType -ne 'none') } Catch { $hasDb = $false }

    $createdTime = $null
    Try { $createdTime = $e.CreatedTime } Catch { $createdTime = $null }

    $ageDays = If ($createdTime) { [math]::Round(($now - [datetime]$createdTime).TotalDays, 1) } Else { $null }

    $isReclaimCandidate = $false
    If ($e.EnvironmentType -in @('Trial', 'Sandbox') -and $ageDays -ne $null -and $ageDays -ge $StaleThresholdDays) {
        $isReclaimCandidate = $true
    }

    $provisioningState = $null
    Try { $provisioningState = $e.ProvisioningState } Catch { $provisioningState = 'Unknown' }

    $provisioningStalled = $false
    If ($provisioningState -and $provisioningState -notin @('Succeeded', 'Ready', $null)) {
        $provisioningStalled = $true
    }

    $rows += [PSCustomObject]@{
        DisplayName          = $e.DisplayName
        EnvironmentId        = $e.EnvironmentName
        EnvironmentType       = $e.EnvironmentType
        IsDefault            = $e.IsDefault
        HasDataverseDatabase  = $hasDb
        ProvisioningState     = $provisioningState
        ProvisioningStalled   = $provisioningStalled
        CreatedTime           = $createdTime
        AgeDays              = $ageDays
        CapacityReclaimCandidate = $isReclaimCandidate
        Location             = $e.Location
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$stalled = $rows | Where-Object { $_.ProvisioningStalled }
$reclaimCandidates = $rows | Where-Object { $_.CapacityReclaimCandidate }
$withDb = $rows | Where-Object { $_.HasDataverseDatabase }
$withoutDb = $rows | Where-Object { -not $_.HasDataverseDatabase }

Write-Host ""
Write-Host "=== POWER APPS / DATAVERSE ENVIRONMENT AUDIT SUMMARY ===" -ForegroundColor Cyan
Write-Host ("{0,-45} {1}" -f "Total environments:", $rows.Count)
Write-Host ("{0,-45} {1}" -f "With Dataverse database:", $withDb.Count)
Write-Host ("{0,-45} {1}" -f "Without Dataverse database:", $withoutDb.Count)
Write-Host ("{0,-45} {1}" -f "Provisioning stalled/non-Succeeded:", $stalled.Count)
Write-Host ("{0,-45} {1}" -f "Capacity reclaim candidates (Trial/Sandbox, >=$StaleThresholdDays days):", $reclaimCandidates.Count)

If ($stalled.Count -gt 0) {
    Write-Host ""
    Write-Status "$($stalled.Count) environment(s) show a non-Succeeded provisioning state — see runbook Fix 1 (retry stalled provisioning)." "WARN"
    $stalled | Select-Object DisplayName, EnvironmentId, ProvisioningState | Format-Table -AutoSize
}

If ($reclaimCandidates.Count -gt 0) {
    Write-Host ""
    Write-Status "$($reclaimCandidates.Count) environment(s) are Trial/Sandbox and older than $StaleThresholdDays days — review for capacity reclaim (runbook Fix 4 / Playbook 2)." "WARN"
    $reclaimCandidates | Select-Object DisplayName, EnvironmentId, EnvironmentType, AgeDays | Format-Table -AutoSize
}

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
$csvPath = Join-Path $OutputPath "PowerAppsEnvironmentAudit-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
$rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Status "Full audit CSV: $csvPath" "OK"
Write-Status "Note: this script cannot see per-user maker-portal/flow-portal visibility — that's evaluated per-portal, see the runbook's Validation Steps for those manual checks." "INFO"
