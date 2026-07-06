<#
.SYNOPSIS
    Audits Microsoft Teams meeting policy assignments, group policy rank conflicts, and lobby
    security posture tenant-wide.

.DESCRIPTION
    Automates the Validation Steps and Phase 1/3/5 troubleshooting flows from Meeting-Policies-A.md
    so an admin can see the effective policy landscape in one pass instead of resolving policy
    inheritance user-by-user.

    Covers:
    - Every meeting policy in the tenant with its key security-relevant settings
      (AutoAdmittedUsers, AllowAnonymousUsersToJoinMeeting, AllowCloudRecording, AllowTranscription)
    - PERMISSIVE_LOBBY flag on any policy where AutoAdmittedUsers is "Everyone" — the runbook's
      Learning Pointers call this out as appropriate only for public webinars, a risk for
      anything else
    - Group policy assignment rank table, with a RANK_CONFLICT flag when a group's assignment
      rank is tied with another group's rank for the same policy type (an ambiguous-priority
      condition the runbook doesn't call out by name, but which produces the same symptom
      as "User getting different policy than expected")
    - Optional per-user effective-policy resolution: given a list of UPNs, resolves direct vs.
      group assignment and reports the winning policy — automating Meeting-Policies-A.md
      Phase 1 and Phase 5 for a batch of users instead of one at a time
    - Audio Conferencing coverage check for the same optional user list, since dial-in numbers
      missing from invites is one of the most common "policy looks right but feature is missing"
      tickets (licensing, not policy)

    Does NOT cover:
    - Live event policies (separate `Get-CsTeamsLiveEventPolicy` object; out of scope here)
    - Teams Premium feature availability beyond the licence SKU check (Intelligent Recap
      rendering itself is a client-side concern)

.PARAMETER UserUPNs
    Optional array of user UPNs to resolve effective policy and Audio Conferencing status for.
    If omitted, only the tenant-wide policy and group-assignment audit runs.

.PARAMETER OutputPath
    Path to the folder where CSV files will be exported. Default: current directory.

.EXAMPLE
    .\Get-TeamsMeetingPolicyAudit.ps1 -OutputPath C:\Temp\TeamsAudit

.EXAMPLE
    .\Get-TeamsMeetingPolicyAudit.ps1 -UserUPNs "alice@contoso.com","bob@contoso.com"

.NOTES
    Requires:
    - MicrosoftTeams module (Connect-MicrosoftTeams)
    - Microsoft.Graph module (for group name resolution and Teams Premium licence check)
    - Teams Administrator or Teams Communications Administrator role

    Run-as: Does NOT require local admin. Requires M365 cloud permissions.
    Safe/Unsafe: Read-only. No changes made to policies or assignments.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string[]]$UserUPNs = @(),

    [Parameter()]
    [string]$OutputPath = (Get-Location).Path
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

function Get-MeetingPolicyAudit {
    Write-Status "Retrieving all Teams meeting policies..." "INFO"
    $policies = Get-CsTeamsMeetingPolicy -ErrorAction Stop

    $report = foreach ($p in $policies) {
        $flags = [System.Collections.Generic.List[string]]::new()

        if ($p.AutoAdmittedUsers -eq "Everyone") { $flags.Add("PERMISSIVE_LOBBY") }
        if ($p.AllowAnonymousUsersToJoinMeeting) { $flags.Add("ANONYMOUS_JOIN_ALLOWED") }
        if (-not $p.AllowPstnUsersToBypassLobby -eq $false -and $p.AllowPstnUsersToBypassLobby) {
            $flags.Add("PSTN_BYPASSES_LOBBY")
        }

        [PSCustomObject]@{
            PolicyIdentity              = $p.Identity
            AutoAdmittedUsers           = $p.AutoAdmittedUsers
            AllowAnonymousUsersToJoin   = $p.AllowAnonymousUsersToJoinMeeting
            AllowPstnUsersToBypassLobby = $p.AllowPstnUsersToBypassLobby
            AllowCloudRecording         = $p.AllowCloudRecording
            AllowTranscription          = $p.AllowTranscription
            MeetingChatEnabledType      = $p.MeetingChatEnabledType
            DesignatedPresenterRoleMode = $p.DesignatedPresenterRoleMode
            Flags                       = ($flags -join "; ")
        }
    }

    Write-Status "Audited $($report.Count) meeting policies" "OK"
    return $report
}

function Get-GroupAssignmentAudit {
    Write-Status "Retrieving group policy assignments (TeamsMeetingPolicy)..." "INFO"
    try {
        $assignments = Get-CsGroupPolicyAssignment -PolicyType TeamsMeetingPolicy -ErrorAction Stop
    }
    catch {
        Write-Status "Failed to retrieve group policy assignments: $($_.Exception.Message)" "WARN"
        return @()
    }

    # Detect rank ties: two+ groups sharing the same rank produce ambiguous priority
    $rankGroups = $assignments | Group-Object Rank | Where-Object { $_.Count -gt 1 }
    $tiedRanks  = $rankGroups.Name

    $report = foreach ($a in $assignments) {
        $groupName = $a.GroupId
        try {
            $g = Get-MgGroup -GroupId $a.GroupId -ErrorAction SilentlyContinue
            if ($g) { $groupName = $g.DisplayName }
        } catch { }

        [PSCustomObject]@{
            GroupId    = $a.GroupId
            GroupName  = $groupName
            PolicyName = $a.PolicyName
            Rank       = $a.Rank
            Flag       = if ($a.Rank -in $tiedRanks) { "RANK_CONFLICT" } else { "OK" }
        }
    }

    Write-Status "Audited $($report.Count) group policy assignments" "OK"
    if ($tiedRanks.Count -gt 0) {
        Write-Status "Found rank conflicts at rank(s): $($tiedRanks -join ', ')" "WARN"
    }
    return $report
}

function Get-UserEffectivePolicyAudit {
    param([string[]]$Upns)

    if ($Upns.Count -eq 0) { return @() }

    Write-Status "Resolving effective meeting policy for $($Upns.Count) user(s)..." "INFO"
    $teamsPremiumSku = "1fec84c7-0432-4cc6-9cda-ef8b2267e61c"  # verify current at aka.ms/m365licensingguide

    $report = foreach ($upn in $Upns) {
        $directAssignment = $null
        $effective        = $null
        $dialIn           = $null
        $premiumLicensed  = $false

        try {
            $directAssignment = Get-CsUserPolicyAssignment -Identity $upn -ErrorAction Stop |
                Where-Object { $_.PolicyType -eq "TeamsMeetingPolicy" }
        } catch {
            Write-Status "  Could not resolve policy assignment for $upn : $($_.Exception.Message)" "WARN"
        }

        try {
            $effective = Get-CsEffectivePolicy -Identity $upn -PolicyType TeamsMeetingPolicy -ErrorAction Stop
        } catch {
            Write-Status "  Get-CsEffectivePolicy unavailable for $upn (older Teams module) — reporting assignment only" "WARN"
        }

        try {
            $dialIn = Get-CsOnlineDialInConferencingUserInfo -Identity $upn -ErrorAction SilentlyContinue
        } catch { }

        try {
            $user = Get-MgUser -UserId $upn -Property AssignedLicenses -ErrorAction SilentlyContinue
            if ($user -and $user.AssignedLicenses.SkuId -contains $teamsPremiumSku) { $premiumLicensed = $true }
        } catch { }

        [PSCustomObject]@{
            UserUPN                 = $upn
            AssignmentSource        = if ($directAssignment -and $directAssignment.PolicyName) { "Direct" }
                                       elseif ($effective) { "Group or Global" }
                                       else { "Unknown" }
            AssignedPolicyName      = $directAssignment.PolicyName
            EffectiveAllowRecording = $effective.AllowCloudRecording
            EffectiveAutoAdmitted   = $effective.AutoAdmittedUsers
            AudioConferencingProvider = $dialIn.ConferencingProvider
            AudioConferencingTollNumber = $dialIn.TollNumber
            TeamsPremiumLicensed    = $premiumLicensed
        }
    }

    return $report
}

function Write-SummaryReport {
    param(
        [object[]]$PolicyReport,
        [object[]]$GroupAssignmentReport,
        [object[]]$UserReport
    )

    $separator = "=" * 60
    Write-Host ""
    Write-Host $separator -ForegroundColor Cyan
    Write-Host "  TEAMS MEETING POLICY AUDIT" -ForegroundColor Cyan
    Write-Host "  Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
    Write-Host $separator -ForegroundColor Cyan
    Write-Host ""

    Write-Host "[ POLICY SECURITY POSTURE ]" -ForegroundColor Yellow
    $permissive = $PolicyReport | Where-Object { $_.Flags -like "*PERMISSIVE_LOBBY*" }
    Write-Status "  Policies with PERMISSIVE_LOBBY (AutoAdmittedUsers = Everyone): $($permissive.Count)" $(if ($permissive.Count -gt 0) { "WARN" } else { "OK" })
    if ($permissive.Count -gt 0) {
        $permissive | Select-Object PolicyIdentity, AutoAdmittedUsers, AllowAnonymousUsersToJoin | Format-Table -AutoSize
    }
    Write-Host ""

    Write-Host "[ GROUP ASSIGNMENT RANK CONFLICTS ]" -ForegroundColor Yellow
    $conflicts = $GroupAssignmentReport | Where-Object { $_.Flag -eq "RANK_CONFLICT" }
    if ($conflicts.Count -gt 0) {
        Write-Status "  Found $($conflicts.Count) group assignment(s) sharing a tied rank — priority is ambiguous" "WARN"
        $conflicts | Select-Object GroupName, PolicyName, Rank | Format-Table -AutoSize
    } else {
        Write-Status "  No rank conflicts found" "OK"
    }
    Write-Host ""

    if ($UserReport.Count -gt 0) {
        Write-Host "[ PER-USER EFFECTIVE POLICY ]" -ForegroundColor Yellow
        $UserReport | Select-Object UserUPN, AssignmentSource, AssignedPolicyName,
            EffectiveAllowRecording, EffectiveAutoAdmitted, AudioConferencingTollNumber, TeamsPremiumLicensed |
            Format-Table -AutoSize
    }
}

# ==========================================
# MAIN SCRIPT
# ==========================================

Write-Status "Starting Teams Meeting Policy Audit..." "INFO"

if (-not (Get-Module -Name MicrosoftTeams -ListAvailable)) {
    Write-Status "MicrosoftTeams module not found. Install with: Install-Module MicrosoftTeams" "ERROR"
    exit 1
}

if (-not (Test-Path -Path $OutputPath)) {
    Write-Status "Output path does not exist: $OutputPath — creating..." "WARN"
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Status "Connecting to Microsoft Teams..." "INFO"
try {
    Connect-MicrosoftTeams -ErrorAction Stop | Out-Null
    Write-Status "Connected to Microsoft Teams" "OK"
}
catch {
    Write-Status "Failed to connect to Microsoft Teams: $($_.Exception.Message)" "ERROR"
    exit 1
}

if ($UserUPNs.Count -gt 0 -or $true) {
    Write-Status "Connecting to Microsoft Graph (group name + licence resolution)..." "INFO"
    try {
        Connect-MgGraph -Scopes "Group.Read.All", "User.Read.All" -ErrorAction Stop -NoWelcome
        Write-Status "Connected to Microsoft Graph" "OK"
    }
    catch {
        Write-Status "Failed to connect to Microsoft Graph — group names/licence checks will be skipped: $($_.Exception.Message)" "WARN"
    }
}

$policyReport = Get-MeetingPolicyAudit
$groupReport  = Get-GroupAssignmentAudit
$userReport   = Get-UserEffectivePolicyAudit -Upns $UserUPNs

Write-SummaryReport -PolicyReport $policyReport -GroupAssignmentReport $groupReport -UserReport $userReport

$stamp = Get-Date -Format 'yyyyMMdd'

if ($policyReport.Count -gt 0) {
    $policyFile = Join-Path $OutputPath "TeamsMeetingPolicy-Audit-$stamp.csv"
    $policyReport | Export-Csv -Path $policyFile -NoTypeInformation -Encoding UTF8
    Write-Status "Policy audit exported to: $policyFile" "OK"
}

if ($groupReport.Count -gt 0) {
    $groupFile = Join-Path $OutputPath "TeamsMeetingPolicy-GroupAssignments-$stamp.csv"
    $groupReport | Export-Csv -Path $groupFile -NoTypeInformation -Encoding UTF8
    Write-Status "Group assignment audit exported to: $groupFile" "OK"
}

if ($userReport.Count -gt 0) {
    $userFile = Join-Path $OutputPath "TeamsMeetingPolicy-UserResolution-$stamp.csv"
    $userReport | Export-Csv -Path $userFile -NoTypeInformation -Encoding UTF8
    Write-Status "Per-user resolution exported to: $userFile" "OK"
}

Write-Status "Teams meeting policy audit complete. Files written to: $OutputPath" "OK"
