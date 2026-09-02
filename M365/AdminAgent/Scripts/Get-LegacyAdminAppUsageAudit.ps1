<#
.SYNOPSIS
    Read-only audit for the retiring Teams/Outlook/Microsoft365.com "Admin" app (MC1462922).

.DESCRIPTION
    Reports the current rollout phase relative to the documented MC1462922 retirement
    timeline (Stage 1 mid-Aug 2026: no longer pre-pinned for new very-small-business admins;
    Stage 2 mid-Oct 2026: fully retired/unsupported across Teams, Outlook, and Microsoft365.com),
    searches the Teams App Catalog for an app matching the retiring first-party app so it isn't
    confused with an unrelated tenant-custom app of the same name, and checks current Teams
    App Setup Policy pin state.

    No dedicated PowerShell/Graph API surface exists for this app specifically — it is (and
    always was) governed entirely through standard Teams App Catalog / App Setup Policy cmdlets.
    This script does not and cannot confirm whether any specific admin currently sees the app
    pinned in their own client; it reports tenant-wide policy configuration only.

.PARAMETER PolicyIdentity
    The Teams App Setup Policy to check. Defaults to "Global".

.EXAMPLE
    .\Get-LegacyAdminAppUsageAudit.ps1
    Runs against the Global Teams App Setup Policy and reports rollout phase + app catalog match.

.EXAMPLE
    .\Get-LegacyAdminAppUsageAudit.ps1 -PolicyIdentity "Tag:VSBClients"
    Checks a specific custom policy instead of Global.

.NOTES
    Requires: MicrosoftTeams PowerShell module, connected via Connect-MicrosoftTeams.
    Read-only — makes no configuration changes. Run as any account with Teams admin read access
    (Teams Administrator or Global Reader is sufficient; full Global Administrator not required).
#>
#Requires -Modules MicrosoftTeams
[CmdletBinding()]
param(
    [string]$PolicyIdentity = "Global"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# --- Preflight ---------------------------------------------------------------
try {
    $null = Get-CsTenant -ErrorAction Stop
}
catch {
    Write-Status "Not connected to Microsoft Teams PowerShell. Run Connect-MicrosoftTeams first." "ERROR"
    throw
}

# --- Rollout phase determination ---------------------------------------------
$stage1Start = Get-Date "2026-08-15"
$stage2Start = Get-Date "2026-10-15"
$today       = Get-Date

$phase = if ($today -lt $stage1Start) {
    "Pre-rollout — Admin app still fully pre-pinned for new VSB admins"
}
elseif ($today -lt $stage2Start) {
    "Stage 1 (in progress) — no longer pre-pinned for NEW very-small-business admins; existing installs still function"
}
else {
    "Stage 2 (complete) — Admin app fully retired; unsupported in Teams, Outlook, and Microsoft365.com regardless of prior install"
}

Write-Status "Evidence date: $($today.ToString('yyyy-MM-dd'))" "INFO"
Write-Status "Rollout phase per MC1462922: $phase" "INFO"

# --- Teams App Catalog search --------------------------------------------------
Write-Status "Searching Teams App Catalog for apps matching 'Admin'..." "INFO"
$candidateApps = @()
try {
    $candidateApps = Get-CsTeamsApp -ErrorAction Stop |
        Where-Object { $_.DisplayName -match "Admin" }
}
catch {
    Write-Status "Could not query Teams App Catalog: $($_.Exception.Message)" "WARN"
}

if ($candidateApps.Count -eq 0) {
    Write-Status "No apps matching 'Admin' found in the catalog — nothing pinned/available to audit." "OK"
}
else {
    foreach ($app in $candidateApps) {
        $isFirstParty = $app.DistributionMethod -eq "store"
        $flag = if ($isFirstParty) { "WARN" } else { "INFO" }
        Write-Status "Found: '$($app.DisplayName)' (Id=$($app.Id), DistributionMethod=$($app.DistributionMethod)) — $(if ($isFirstParty) { 'possible match for the retiring first-party app; verify in-tenant, Microsoft has not published a fixed AppId for this app' } else { 'tenant-custom/sideloaded app, NOT the retiring first-party app' })" $flag
    }
}

# --- App Setup Policy pin check -------------------------------------------------
Write-Status "Checking Teams App Setup Policy '$PolicyIdentity' for pinned Admin-matching apps..." "INFO"
try {
    $policy = Get-CsTeamsAppSetupPolicy -Identity $PolicyIdentity -ErrorAction Stop
    $pinnedMatches = $policy.PinnedAppBarApps | Where-Object { $_.Id -in $candidateApps.Id }
    if ($pinnedMatches) {
        Write-Status "Policy '$PolicyIdentity' currently pins $($pinnedMatches.Count) app(s) matching 'Admin' — review before Stage 2 (mid-Oct 2026) to avoid a client-facing surprise." "WARN"
    }
    else {
        Write-Status "Policy '$PolicyIdentity' does not currently pin any app matching 'Admin'." "OK"
    }
}
catch {
    Write-Status "Could not retrieve policy '$PolicyIdentity': $($_.Exception.Message)" "WARN"
}

# --- Export -----------------------------------------------------------------
$exportPath = Join-Path -Path (Get-Location) -ChildPath "LegacyAdminAppAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$candidateApps |
    Select-Object @{N='EvidenceDate';E={$today}}, @{N='RolloutPhase';E={$phase}},
                  DisplayName, Id, DistributionMethod, ExternalId |
    Export-Csv -Path $exportPath -NoTypeInformation

Write-Status "Report exported to $exportPath" "OK"
Write-Status "Reminder: this script reports tenant-wide POLICY configuration only. It cannot confirm what any individual admin currently sees pinned in their own Teams/Outlook/Microsoft365.com client." "INFO"
