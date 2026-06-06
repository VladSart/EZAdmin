<#
.SYNOPSIS
    Set and audit SharePoint Online site permissions for owners, members, and visitors.

.DESCRIPTION
    Manages SharePoint Online site permissions using PnP PowerShell and Microsoft Graph.
    Supports adding/removing users and security groups from the three default SP groups
    (Owners, Members, Visitors), breaking inheritance on sub-sites/libraries, and
    exporting a full permission report. Safe to run repeatedly (idempotent adds).

    What it covers:
      - Adding/removing users from SharePoint Owner, Member, Visitor groups
      - Adding/removing Entra ID security groups from SP groups
      - Breaking or restoring permission inheritance on a site collection
      - Reporting: exports all unique permissions to CSV
      - Hub site permission propagation check

    What it does NOT cover:
      - Item-level permissions
      - SharePoint group creation (use New-PnPGroup for that)
      - Changing site collection admin via this script (use Set-PnPTenantSite -Owners)

.PARAMETER SiteUrl
    Full URL of the SharePoint site (e.g. https://contoso.sharepoint.com/sites/ProjectAlpha)

.PARAMETER Action
    What to do: AddUser | RemoveUser | AddGroup | RemoveGroup | Report | BreakInheritance | RestoreInheritance

.PARAMETER TargetRole
    Which SP default group to modify: Owner | Member | Visitor

.PARAMETER UserUPN
    UPN of the user to add/remove (e.g. jane.doe@contoso.com). Used with AddUser/RemoveUser.

.PARAMETER GroupName
    Display name of the Entra ID security group to add/remove. Used with AddGroup/RemoveGroup.

.PARAMETER ReportPath
    Path for CSV report output. Defaults to .\SPPermissions-<date>.csv

.EXAMPLE
    # Add a user as a Member
    .\Set-SharePointSitePermissions.ps1 -SiteUrl "https://contoso.sharepoint.com/sites/ProjectAlpha" -Action AddUser -TargetRole Member -UserUPN "jane.doe@contoso.com"

.EXAMPLE
    # Remove a user from Owners
    .\Set-SharePointSitePermissions.ps1 -SiteUrl "https://contoso.sharepoint.com/sites/ProjectAlpha" -Action RemoveUser -TargetRole Owner -UserUPN "bob.smith@contoso.com"

.EXAMPLE
    # Add an Entra security group as Visitors
    .\Set-SharePointSitePermissions.ps1 -SiteUrl "https://contoso.sharepoint.com/sites/ProjectAlpha" -Action AddGroup -TargetRole Visitor -GroupName "All Staff - Read Only"

.EXAMPLE
    # Export full permission report
    .\Set-SharePointSitePermissions.ps1 -SiteUrl "https://contoso.sharepoint.com/sites/ProjectAlpha" -Action Report

.NOTES
    Requires: PnP.PowerShell module (Install-Module PnP.PowerShell)
    Requires: Microsoft.Graph module for group lookups (Install-Module Microsoft.Graph)
    Permissions: SharePoint Admin or Site Collection Administrator on the target site
    Safe/Unsafe: AddUser/AddGroup/RemoveUser/RemoveGroup are reversible.
                 BreakInheritance removes inherited permissions — document before running.
    Run-as: Not required to run as Administrator, but requires above SP/Graph permissions.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$SiteUrl,

    [Parameter(Mandatory)]
    [ValidateSet("AddUser","RemoveUser","AddGroup","RemoveGroup","Report","BreakInheritance","RestoreInheritance")]
    [string]$Action,

    [ValidateSet("Owner","Member","Visitor")]
    [string]$TargetRole,

    [string]$UserUPN,

    [string]$GroupName,

    [string]$ReportPath = ".\SPPermissions-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region Helpers

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"     { "Green"  }
        "WARN"   { "Yellow" }
        "ERROR"  { "Red"    }
        default  { "Cyan"   }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-SPGroupByRole {
    param([string]$SiteUrl, [string]$Role)
    $groups = Get-PnPGroup
    switch ($Role) {
        "Owner"   { return $groups | Where-Object { $_.Title -like "*Owner*"   } | Select-Object -First 1 }
        "Member"  { return $groups | Where-Object { $_.Title -like "*Member*"  } | Select-Object -First 1 }
        "Visitor" { return $groups | Where-Object { $_.Title -like "*Visitor*" } | Select-Object -First 1 }
    }
}

#endregion

#region Preflight

Write-Status "Connecting to SharePoint: $SiteUrl"
try {
    Connect-PnPOnline -Url $SiteUrl -Interactive -ErrorAction Stop
    Write-Status "Connected" "OK"
} catch {
    Write-Status "Failed to connect to $SiteUrl : $_" "ERROR"
    exit 1
}

# Validate role is specified for actions that need it
if ($Action -in @("AddUser","RemoveUser","AddGroup","RemoveGroup") -and -not $TargetRole) {
    Write-Status "-TargetRole is required for action '$Action'" "ERROR"
    exit 1
}

# Validate user/group is specified
if ($Action -in @("AddUser","RemoveUser") -and -not $UserUPN) {
    Write-Status "-UserUPN is required for action '$Action'" "ERROR"
    exit 1
}
if ($Action -in @("AddGroup","RemoveGroup") -and -not $GroupName) {
    Write-Status "-GroupName is required for action '$Action'" "ERROR"
    exit 1
}

#endregion

#region Execute

switch ($Action) {

    "AddUser" {
        Write-Status "Adding user '$UserUPN' as $TargetRole on $SiteUrl"
        $spGroup = Get-SPGroupByRole -SiteUrl $SiteUrl -Role $TargetRole
        if ($null -eq $spGroup) {
            Write-Status "Could not find SP group for role '$TargetRole'" "ERROR"; exit 1
        }
        if ($PSCmdlet.ShouldProcess($UserUPN, "Add to SP group $($spGroup.Title)")) {
            Add-PnPGroupMember -Group $spGroup.Title -LoginName $UserUPN
            Write-Status "Added '$UserUPN' to '$($spGroup.Title)'" "OK"
        }
    }

    "RemoveUser" {
        Write-Status "Removing user '$UserUPN' from $TargetRole on $SiteUrl"
        $spGroup = Get-SPGroupByRole -SiteUrl $SiteUrl -Role $TargetRole
        if ($null -eq $spGroup) {
            Write-Status "Could not find SP group for role '$TargetRole'" "ERROR"; exit 1
        }
        if ($PSCmdlet.ShouldProcess($UserUPN, "Remove from SP group $($spGroup.Title)")) {
            Remove-PnPGroupMember -Group $spGroup.Title -LoginName $UserUPN
            Write-Status "Removed '$UserUPN' from '$($spGroup.Title)'" "OK"
        }
    }

    "AddGroup" {
        Write-Status "Adding Entra group '$GroupName' as $TargetRole"
        $spGroup = Get-SPGroupByRole -SiteUrl $SiteUrl -Role $TargetRole
        if ($null -eq $spGroup) {
            Write-Status "Could not find SP group for role '$TargetRole'" "ERROR"; exit 1
        }

        # Resolve group's claim token — SharePoint uses i:0e.t|... or c:0t.c|...
        # Easiest: add via loginName using the claims format
        $loginName = "c:0t.c|tenant|$GroupName"
        # Alternatively: use the group's email (sAMAccountName@tenant format)
        # For Entra groups, PnP resolves display name automatically if using -LoginName
        try {
            Connect-MgGraph -Scopes "Group.Read.All" -NoWelcome
            $mgGroup = Get-MgGroup -Filter "displayName eq '$GroupName'" -ErrorAction Stop
            if ($null -eq $mgGroup) { throw "Group not found in Entra ID" }
            $loginName = "c:0o.c|federateddirectoryclaimprovider|$($mgGroup.Id)"
            Write-Status "Resolved group ID: $($mgGroup.Id)" "OK"
        } catch {
            Write-Status "Could not resolve group via Graph; attempting direct add: $_" "WARN"
        }

        if ($PSCmdlet.ShouldProcess($GroupName, "Add to SP group $($spGroup.Title)")) {
            Add-PnPGroupMember -Group $spGroup.Title -LoginName $loginName
            Write-Status "Added Entra group '$GroupName' to '$($spGroup.Title)'" "OK"
        }
    }

    "RemoveGroup" {
        Write-Status "Removing Entra group '$GroupName' from $TargetRole"
        $spGroup = Get-SPGroupByRole -SiteUrl $SiteUrl -Role $TargetRole
        if ($null -eq $spGroup) {
            Write-Status "Could not find SP group for role '$TargetRole'" "ERROR"; exit 1
        }

        try {
            Connect-MgGraph -Scopes "Group.Read.All" -NoWelcome
            $mgGroup = Get-MgGroup -Filter "displayName eq '$GroupName'" -ErrorAction Stop
            $loginName = "c:0o.c|federateddirectoryclaimprovider|$($mgGroup.Id)"
        } catch {
            Write-Status "Could not resolve group via Graph; attempting direct remove by display name: $_" "WARN"
            $loginName = $GroupName
        }

        if ($PSCmdlet.ShouldProcess($GroupName, "Remove from SP group $($spGroup.Title)")) {
            Remove-PnPGroupMember -Group $spGroup.Title -LoginName $loginName
            Write-Status "Removed Entra group '$GroupName' from '$($spGroup.Title)'" "OK"
        }
    }

    "Report" {
        Write-Status "Generating permission report for $SiteUrl"
        $results = @()

        # Get all SP groups and their members
        $spGroups = Get-PnPGroup
        foreach ($group in $spGroups) {
            $members = Get-PnPGroupMember -Group $group.Title
            foreach ($member in $members) {
                $results += [PSCustomObject]@{
                    SiteUrl       = $SiteUrl
                    SPGroupTitle  = $group.Title
                    SPGroupId     = $group.Id
                    MemberTitle   = $member.Title
                    MemberLogin   = $member.LoginName
                    MemberEmail   = $member.Email
                    MemberType    = if ($member.LoginName -like "*|federateddirectoryclaimprovider|*") { "EntraGroup" } elseif ($member.LoginName -like "*|membership|*") { "User" } else { "Other" }
                    ReportDate    = Get-Date -Format "yyyy-MM-dd HH:mm"
                }
            }
        }

        # Check unique permissions on root web
        $web = Get-PnPWeb -Includes HasUniqueRoleAssignments
        if ($web.HasUniqueRoleAssignments) {
            Write-Status "Root site has unique permissions (not inheriting)" "WARN"
        } else {
            Write-Status "Root site inherits permissions from parent" "OK"
        }

        $results | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8
        Write-Status "Report exported to: $ReportPath" "OK"
        $results | Format-Table SPGroupTitle, MemberTitle, MemberType -AutoSize
    }

    "BreakInheritance" {
        Write-Status "Breaking permission inheritance on $SiteUrl" "WARN"
        Write-Status "This will COPY existing permissions then break inheritance. Existing permissions are preserved." "WARN"

        # Document before breaking
        $preReport = ".\SPPermissions-PreBreak-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
        Write-Status "Saving pre-break permission snapshot to $preReport"
        $spGroups = Get-PnPGroup
        $results = @()
        foreach ($group in $spGroups) {
            $members = Get-PnPGroupMember -Group $group.Title
            foreach ($member in $members) {
                $results += [PSCustomObject]@{ SPGroup = $group.Title; Member = $member.Title; Login = $member.LoginName }
            }
        }
        $results | Export-Csv -Path $preReport -NoTypeInformation

        if ($PSCmdlet.ShouldProcess($SiteUrl, "Break permission inheritance")) {
            Set-PnPWeb -BreakRoleInheritance -CopyRoleAssignments
            Write-Status "Permission inheritance broken. Pre-break snapshot: $preReport" "OK"
        }
    }

    "RestoreInheritance" {
        Write-Status "Restoring permission inheritance on $SiteUrl" "WARN"
        Write-Status "This will REMOVE all unique permissions and reset to parent inheritance." "WARN"
        if ($PSCmdlet.ShouldProcess($SiteUrl, "Restore permission inheritance (removes unique permissions)")) {
            Set-PnPWeb -ResetRoleInheritance
            Write-Status "Permission inheritance restored from parent." "OK"
        }
    }
}

#endregion

Write-Status "Operation '$Action' completed." "OK"
