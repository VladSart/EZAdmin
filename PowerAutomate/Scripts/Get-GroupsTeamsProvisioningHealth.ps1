<#
.SYNOPSIS
    Audits M365 Group/Teams self-service provisioning flows for the async-race and governance
    failure modes described in Groups-Teams-Provisioning-A.md / -B.md.

.DESCRIPTION
    Checks either a single named group or every M365 Group created within a recent time window,
    and flags the specific failure signatures the runbooks identify as most common:

    - RACE_CONDITION_SUSPECTED: group exists in Entra ID but the Team object and/or SharePoint
      site backing store haven't finished provisioning yet — the #1 defect in flows that chain
      "Create a team" directly after "Create a group" with no wait/retry step.
    - NO_OWNER: group has members but zero owners — self-management is impossible until an
      admin manually adds one (Playbook 3 in the -A runbook).
    - LICENSE_PENDING / LICENSE_ERROR: group-based licensing is still processing, or failed
      outright (commonly insufficient license units in the pool).
    - Naming policy snapshot (PrefixSuffixNamingRequirement, CustomBlockedWordsList) so a
      "wrong name" ticket can be triaged as policy-driven vs. a flow bug without a separate lookup.

    Groups younger than a configurable grace period are given a pass on RACE_CONDITION flags
    since provisioning latency of a few minutes is normal, not a fault.

    Read-only. Makes no changes to any group, Team, or licensing configuration.

.PARAMETER GroupDisplayName
    Check a single group by exact display name. Mutually exclusive with -RecentHours.

.PARAMETER RecentHours
    Fleet mode: scan every M365 Group created within this many hours. Default: 24.
    Useful for a daily sweep to catch provisioning flow defects before they become tickets.

.PARAMETER GraceMinutes
    Groups younger than this are not flagged for RACE_CONDITION_SUSPECTED even if the Team/site
    isn't visible yet — normal async provisioning latency. Default: 15.

.PARAMETER OutputPath
    Path to export CSV reports. Default: C:\Temp\GroupsTeamsProvisioning-<timestamp>

.EXAMPLE
    .\Get-GroupsTeamsProvisioningHealth.ps1 -GroupDisplayName "GRP-Marketing-Q3"

.EXAMPLE
    # Daily sweep for anything provisioned in the last day
    .\Get-GroupsTeamsProvisioningHealth.ps1 -RecentHours 24

.NOTES
    Requires: Microsoft.Graph.Groups, Microsoft.Graph.Users, ExchangeOnlineManagement modules
    Auth:     Connect-MgGraph -Scopes "Group.Read.All","Directory.Read.All"
              Connect-ExchangeOnline
    Permissions: Groups Administrator (read) or Global Reader
    Safe to run repeatedly — read-only.
    Companion runbooks: PowerAutomate/Groups-Teams/Groups-Teams-Provisioning-A.md and -B.md
#>

[CmdletBinding(DefaultParameterSetName = "Recent")]
param(
    [Parameter(Mandatory, ParameterSetName = "Single")]
    [string]$GroupDisplayName,

    [Parameter(ParameterSetName = "Recent")]
    [int]$RecentHours = 24,

    [Parameter()]
    [int]$GraceMinutes = 15,

    [Parameter()]
    [string]$OutputPath = "C:\Temp\GroupsTeamsProvisioning-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $Colour = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $Colour
}

# ─── Preflight ────────────────────────────────────────────────────────────────

foreach ($Mod in @("Microsoft.Graph.Groups", "Microsoft.Graph.Users", "ExchangeOnlineManagement")) {
    if (-not (Get-Module -ListAvailable -Name $Mod)) {
        Write-Status "$Mod not found. Installing..." "WARN"
        Install-Module $Mod -Scope CurrentUser -Force -AllowClobber
    }
}
Import-Module Microsoft.Graph.Groups -ErrorAction Stop
Import-Module Microsoft.Graph.Users -ErrorAction Stop
Import-Module ExchangeOnlineManagement -ErrorAction Stop

Write-Status "Connecting to Microsoft Graph..."
try {
    Connect-MgGraph -Scopes "Group.Read.All", "Directory.Read.All" -NoWelcome -ErrorAction Stop
} catch {
    Write-Status "Graph auth failed: $_" "ERROR"
    exit 1
}

Write-Status "Connecting to Exchange Online (for SharePointSiteUrl lookups)..."
try {
    Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
} catch {
    Write-Status "Exchange Online auth failed: $_" "ERROR"
    exit 1
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# ─── Naming policy snapshot (once, not per-group) ─────────────────────────────

Write-Status "Reading tenant group naming policy..."
$NamingPolicy = [PSCustomObject]@{ PrefixSuffix = $null; BlockedWords = $null }
try {
    $Template = Get-MgDirectorySettingTemplate | Where-Object { $_.DisplayName -eq "Group.Unified" }
    $Setting  = Get-MgDirectorySetting | Where-Object { $_.TemplateId -eq $Template.Id }
    if ($Setting) {
        $NamingPolicy.PrefixSuffix  = ($Setting.Values | Where-Object Name -eq "PrefixSuffixNamingRequirement").Value
        $NamingPolicy.BlockedWords  = ($Setting.Values | Where-Object Name -eq "CustomBlockedWordsList").Value
    }
} catch {
    Write-Status "Could not read Group.Unified directory setting — tenant may be using default policy (no override object exists)." "WARN"
}
Write-Status "Naming policy — Prefix/Suffix: '$($NamingPolicy.PrefixSuffix)' | Blocked words configured: $([bool]$NamingPolicy.BlockedWords)"

# ─── Collect target groups ─────────────────────────────────────────────────────

$TargetGroups = [System.Collections.Generic.List[object]]::new()

if ($PSCmdlet.ParameterSetName -eq "Single") {
    Write-Status "Looking up group: $GroupDisplayName"
    $g = Get-MgGroup -Filter "displayName eq '$GroupDisplayName'" -Property "id,displayName,mail,mailNickname,createdDateTime,groupTypes,assignedLicenses,licenseProcessingState"
    if (-not $g) {
        Write-Status "No group found matching '$GroupDisplayName'." "ERROR"
        exit 1
    }
    $TargetGroups.Add($g)
} else {
    Write-Status "Scanning groups created in the last $RecentHours hour(s)..."
    $Cutoff = (Get-Date).ToUniversalTime().AddHours(-$RecentHours).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $All = Get-MgGroup -Filter "groupTypes/any(g:g eq 'Unified') and createdDateTime ge $Cutoff" `
        -Property "id,displayName,mail,mailNickname,createdDateTime,groupTypes,assignedLicenses,licenseProcessingState" -All
    foreach ($g in $All) { $TargetGroups.Add($g) }
    Write-Status "Found $($TargetGroups.Count) group(s) created since $Cutoff." "OK"
}

if ($TargetGroups.Count -eq 0) {
    Write-Status "Nothing to check." "OK"
    exit 0
}

# ─── Per-group provisioning checks ────────────────────────────────────────────

$Report = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($g in $TargetGroups) {

    $AgeMinutes = [int]((Get-Date) - [datetime]$g.CreatedDateTime).TotalMinutes
    $Flags = [System.Collections.Generic.List[string]]::new()

    # SharePoint / Exchange backing store
    $SpoUrl = $null
    try {
        $ug = Get-UnifiedGroup -Identity $g.Mail -ErrorAction Stop
        $SpoUrl = $ug.SharePointSiteUrl
    } catch {
        # Still provisioning or lookup failed — not necessarily an error
    }

    # Team object
    $TeamExists = $false
    try {
        $null = Get-MgTeam -TeamId $g.Id -ErrorAction Stop
        $TeamExists = $true
    } catch {
        $TeamExists = $false
    }

    if ($AgeMinutes -gt $GraceMinutes) {
        if (-not $SpoUrl) { $Flags.Add("RACE_CONDITION_SUSPECTED: SharePoint site not provisioned past grace period") }
        if (-not $TeamExists) { $Flags.Add("RACE_CONDITION_SUSPECTED: Team object missing past grace period") }
    }

    # Owners vs members
    $OwnerCount = 0
    $MemberCount = 0
    try { $OwnerCount = @(Get-MgGroupOwner -GroupId $g.Id -All).Count } catch {}
    try { $MemberCount = @(Get-MgGroupMember -GroupId $g.Id -All).Count } catch {}
    if ($OwnerCount -eq 0 -and $MemberCount -gt 0) {
        $Flags.Add("NO_OWNER: group has members but zero owners — cannot be self-managed")
    }

    # Licensing (only meaningful if the group has assigned licenses configured)
    if ($g.AssignedLicenses -and $g.AssignedLicenses.Count -gt 0) {
        $LicState = $g.LicenseProcessingState.State
        if ($LicState -eq "PendingProcessing" -and $AgeMinutes -gt $GraceMinutes) {
            $Flags.Add("LICENSE_PENDING: still processing past grace period")
        } elseif ($LicState -notin @("Success", "PendingProcessing", $null)) {
            $Flags.Add("LICENSE_ERROR: state = $LicState — check for exhausted license pool")
        }
    }

    $Status = if ($Flags.Count -gt 0) { "WARN" } else { "OK" }

    $Report.Add([PSCustomObject]@{
        DisplayName      = $g.DisplayName
        GroupId          = $g.Id
        CreatedDateTime  = $g.CreatedDateTime
        AgeMinutes       = $AgeMinutes
        SharePointSiteUrl = $SpoUrl
        TeamProvisioned  = $TeamExists
        OwnerCount       = $OwnerCount
        MemberCount      = $MemberCount
        LicenseState     = $g.LicenseProcessingState.State
        Flags            = ($Flags -join "; ")
        Status           = $Status
    })
}

# ─── Report ────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== GROUPS/TEAMS PROVISIONING HEALTH ===" -ForegroundColor Magenta
Write-Status "Groups checked: $($Report.Count)"

$Flagged = $Report | Where-Object Status -eq "WARN"
if ($Flagged.Count -gt 0) {
    Write-Status "`nGroups with provisioning issues: $($Flagged.Count)" "WARN"
    $Flagged | Format-Table DisplayName, AgeMinutes, TeamProvisioned, OwnerCount, Flags -AutoSize -Wrap
} else {
    Write-Status "No provisioning issues detected." "OK"
}

# ─── Export ────────────────────────────────────────────────────────────────────

$Report | Export-Csv "$OutputPath\provisioning-health.csv" -NoTypeInformation -Encoding UTF8
[PSCustomObject]@{
    PrefixSuffixNamingRequirement = $NamingPolicy.PrefixSuffix
    CustomBlockedWordsList        = ($NamingPolicy.BlockedWords -join ", ")
} | Export-Csv "$OutputPath\naming-policy-snapshot.csv" -NoTypeInformation -Encoding UTF8

Write-Status "`nReports exported to: $OutputPath" "OK"
Write-Status "Done." "OK"
