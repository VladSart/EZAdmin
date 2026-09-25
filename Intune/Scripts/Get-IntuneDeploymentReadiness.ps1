<#
.SYNOPSIS
    Pre-flight readiness check for an Intune Deployments (ring-based rollout, preview)
    payload and its planned ring groups.

.DESCRIPTION
    Intune Deployments (Devices > Manage devices > Deployments) roll a single payload
    out in timed rings by ADDING ring groups to the payload's own Required assignments.
    Most failures are predictable from the payload and group state before the
    deployment is created. See Intune/Troubleshooting/DeploymentPlans-A.md / -B.md.

    For each payload (a Settings catalog / Endpoint security configurationPolicy, or a
    Win32 / Enterprise App Catalog mobileApp) this script checks:
      - Platform / type is supported in preview (Windows 10+; configurationPolicy,
        win32LobApp, win32CatalogApp)
      - App assignments with Available / Uninstall intent (deployments drive Required only)
      - Existing assignment to All users / All devices (a virtual-group final ring
        would REPLACE Required includes; an existing virtual assignment also makes
        the rollout pointless)
      - COLLISIONS: any planned ring group already present in the payload's assignments
        (Intune blocks creation / errors-and-pauses at ring activation)
      - Planned ring groups that are soft-deleted or not found (deployment error states)
      - Planned ring groups that are not security-enabled (informational)

    It does NOT read or modify deployment / deployment-plan objects: Microsoft has not
    documented a Graph surface for them during preview. It does NOT evaluate Multi Admin
    Approval policies, assignment filters, or scope tags. Read-only.

.PARAMETER PolicyId
    One or more configurationPolicy IDs (Settings catalog / Endpoint security).

.PARAMETER AppId
    One or more mobileApp IDs (Win32 / Enterprise App Catalog).

.PARAMETER PlannedRingGroupIds
    Entra group object IDs you intend to use in the deployment's rings (all rings).
    Optional; without it, collision and group-state checks are skipped.

.PARAMETER ExportPath
    CSV path. Defaults to $env:TEMP\IntuneDeploymentReadiness-<timestamp>.csv.

.EXAMPLE
    Connect-MgGraph -Scopes DeviceManagementConfiguration.Read.All,DeviceManagementApps.Read.All,Group.Read.All
    .\Get-IntuneDeploymentReadiness.ps1 -PolicyId 'aaaa-...' -PlannedRingGroupIds 'g1-...','g2-...'

.EXAMPLE
    .\Get-IntuneDeploymentReadiness.ps1 -AppId 'bbbb-...','cccc-...' -PlannedRingGroupIds (Get-MgGroup -Filter "startswith(displayName,'SG-Ring')").Id

.NOTES
    Requires Microsoft.Graph.Authentication and Microsoft.Graph.Groups (and
    Microsoft.Graph.Identity.DirectoryManagement for deleted-item lookup).
    Uses Graph beta for Intune reads (configurationPolicies is beta-only).
    Does not call Connect-MgGraph. Safe: read-only. PowerShell 5.1+ / 7+.
#>
[CmdletBinding()]
param(
    [string[]]$PolicyId = @(),
    [string[]]$AppId = @(),
    [string[]]$PlannedRingGroupIds = @(),
    [string]$ExportPath = "$env:TEMP\IntuneDeploymentReadiness-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-GraphAll {
    param([string]$Uri)
    $items = New-Object System.Collections.Generic.List[object]
    $next = $Uri
    while ($next) {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $next
        if ($resp.ContainsKey('value')) { foreach ($v in $resp['value']) { $items.Add($v) } }
        $next = if ($resp.ContainsKey('@odata.nextLink')) { $resp['@odata.nextLink'] } else { $null }
    }
    return ,$items
}

function Get-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } else { return $null } }
    if ($Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $null
}

$results = New-Object System.Collections.Generic.List[object]
function Add-Finding {
    param([string]$PayloadKind, [string]$PayloadId, [string]$PayloadName, [string]$Check, [string]$Severity, [string]$Detail)
    $results.Add([pscustomobject]@{
        PayloadKind = $PayloadKind; PayloadId = $PayloadId; PayloadName = $PayloadName
        Check = $Check; Severity = $Severity; Detail = $Detail
    })
    $st = switch ($Severity) { 'BLOCKER' { 'ERROR' } 'WARN' { 'WARN' } 'OK' { 'OK' } default { 'INFO' } }
    Write-Status "[$PayloadName] $Check - $Detail" $st
}

# ---------------- Preflight ----------------
$ctx = $null
try { $ctx = Get-MgContext } catch { $ctx = $null }
if (-not $ctx) {
    Write-Status "No Microsoft Graph connection. Run Connect-MgGraph -Scopes DeviceManagementConfiguration.Read.All,DeviceManagementApps.Read.All,Group.Read.All" "ERROR"
    return
}
if (($PolicyId.Count + $AppId.Count) -eq 0) {
    Write-Status "Specify at least one -PolicyId or -AppId." "ERROR"
    return
}
$beta = 'https://graph.microsoft.com/beta'
$virtualTypes = @('#microsoft.graph.allDevicesAssignmentTarget', '#microsoft.graph.allLicensedUsersAssignmentTarget')

# ---------------- Planned ring group state ----------------
$groupState = @{}
foreach ($gid in ($PlannedRingGroupIds | Select-Object -Unique)) {
    $state = 'Live'; $name = $null; $secEnabled = $null
    try {
        $g = Get-MgGroup -GroupId $gid -Property Id, DisplayName, SecurityEnabled
        $name = $g.DisplayName; $secEnabled = $g.SecurityEnabled
    }
    catch {
        try {
            $d = Get-MgDirectoryDeletedItemAsGroup -DirectoryObjectId $gid
            $name = $d.DisplayName; $state = 'SoftDeleted'
        }
        catch { $state = 'NotFound' }
    }
    $groupState[$gid] = [pscustomobject]@{ Name = $name; State = $state; SecurityEnabled = $secEnabled }
}

function Test-PlannedGroups {
    param([string]$Kind, [string]$Id, [string]$Name, [string[]]$AssignedGroupIds)
    if ($PlannedRingGroupIds.Count -eq 0) {
        Add-Finding $Kind $Id $Name 'Collision check' 'INFO' 'Skipped - no -PlannedRingGroupIds supplied'
        return
    }
    foreach ($gid in $groupState.Keys) {
        $gs = $groupState[$gid]
        $label = if ($gs.Name) { "$($gs.Name) ($gid)" } else { $gid }
        if ($AssignedGroupIds -contains $gid) {
            Add-Finding $Kind $Id $Name 'Collision' 'BLOCKER' "Ring group $label is already assigned on the payload - remove it from payload or ring"
        }
        switch ($gs.State) {
            'SoftDeleted' { Add-Finding $Kind $Id $Name 'Ring group state' 'BLOCKER' "$label is soft-deleted - restore (30-day window) before use" }
            'NotFound'    { Add-Finding $Kind $Id $Name 'Ring group state' 'BLOCKER' "$label not found (permanently deleted or wrong ID)" }
            default {
                if ($gs.SecurityEnabled -eq $false) {
                    Add-Finding $Kind $Id $Name 'Ring group type' 'INFO' "$label is not security-enabled (M365 group) - confirm it is selectable in the ring picker"
                }
            }
        }
    }
    $collisions = @($results | Where-Object { $_.PayloadId -eq $Id -and $_.Check -eq 'Collision' })
    if ($collisions.Count -eq 0) { Add-Finding $Kind $Id $Name 'Collision' 'OK' 'No planned ring group is already assigned on the payload' }
}

# ---------------- Policies ----------------
foreach ($polId in $PolicyId) {
    $name = $polId
    try {
        $p = Invoke-MgGraphRequest -Method GET -Uri "$beta/deviceManagement/configurationPolicies/$($polId)?`$select=id,name,platforms,technologies,templateReference"
    }
    catch {
        Add-Finding 'Policy' $polId $name 'Lookup' 'BLOCKER' "configurationPolicy not found or no access: $($_.Exception.Message)"
        continue
    }
    $name = [string](Get-Prop $p 'name')
    $platforms = [string](Get-Prop $p 'platforms')
    $tref = Get-Prop $p 'templateReference'
    $family = [string](Get-Prop $tref 'templateFamily')
    $kindLabel = if ($family -and $family -ne 'none') { "Endpoint security/template ($family)" } else { 'Settings catalog' }

    if ($platforms -match 'windows10') { Add-Finding 'Policy' $polId $name 'Platform' 'OK' "$kindLabel, platform $platforms" }
    else { Add-Finding 'Policy' $polId $name 'Platform' 'BLOCKER' "Platform '$platforms' not supported in preview (Windows 10 and later only)" }

    $assign = Get-GraphAll "$beta/deviceManagement/configurationPolicies/$polId/assignments"
    $assignedGroups = New-Object System.Collections.Generic.List[string]
    foreach ($a in $assign) {
        $t = Get-Prop $a 'target'
        $type = [string](Get-Prop $t '@odata.type')
        $g = [string](Get-Prop $t 'groupId')
        if ($g) { $assignedGroups.Add($g) }
        if ($virtualTypes -contains $type) {
            Add-Finding 'Policy' $polId $name 'Existing virtual assignment' 'WARN' "Payload already targets $type - a staged rollout adds nothing; remove it first if you want rings to control reach"
        }
    }
    Add-Finding 'Policy' $polId $name 'Existing assignments' 'INFO' "$($assign.Count) assignment(s) currently on payload"
    Test-PlannedGroups 'Policy' $polId $name $assignedGroups.ToArray()
}

# ---------------- Apps ----------------
foreach ($aid in $AppId) {
    $name = $aid
    try { $app = Invoke-MgGraphRequest -Method GET -Uri "$beta/deviceAppManagement/mobileApps/$aid" }
    catch {
        Add-Finding 'App' $aid $name 'Lookup' 'BLOCKER' "mobileApp not found or no access: $($_.Exception.Message)"
        continue
    }
    $name = [string](Get-Prop $app 'displayName')
    $type = [string](Get-Prop $app '@odata.type')
    switch ($type) {
        '#microsoft.graph.win32LobApp'     { Add-Finding 'App' $aid $name 'Type' 'OK' 'Win32 app (supported)' }
        '#microsoft.graph.win32CatalogApp' { Add-Finding 'App' $aid $name 'Type' 'OK' 'Enterprise App Catalog app (supported; Automatically update is NOT supported with deployments - use supersedence)' }
        default                            { Add-Finding 'App' $aid $name 'Type' 'BLOCKER' "App type '$type' not supported in preview (Win32 / Enterprise App Catalog only)" }
    }

    $assign = Get-GraphAll "$beta/deviceAppManagement/mobileApps/$aid/assignments"
    $assignedGroups = New-Object System.Collections.Generic.List[string]
    foreach ($a in $assign) {
        $intent = [string](Get-Prop $a 'intent')
        $t = Get-Prop $a 'target'
        $ttype = [string](Get-Prop $t '@odata.type')
        $g = [string](Get-Prop $t 'groupId')
        if ($g) { $assignedGroups.Add($g) }
        if ($intent -and $intent -ne 'required') {
            Add-Finding 'App' $aid $name 'Intent' 'WARN' "Assignment with intent '$intent' ($ttype $g) - deployments drive Required only; this stays outside ring control"
        }
        if ($virtualTypes -contains $ttype -and $intent -eq 'required') {
            Add-Finding 'App' $aid $name 'Existing virtual assignment' 'WARN' "Already Required to $ttype - staged rollout adds nothing"
        }
    }
    Add-Finding 'App' $aid $name 'Existing assignments' 'INFO' "$($assign.Count) assignment(s) currently on payload"
    Test-PlannedGroups 'App' $aid $name $assignedGroups.ToArray()
}

# ---------------- Report ----------------
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
$blockers = @($results | Where-Object Severity -eq 'BLOCKER').Count
$warns = @($results | Where-Object Severity -eq 'WARN').Count
Write-Host ""
if ($blockers -gt 0) { Write-Status "$blockers blocker(s), $warns warning(s). Resolve blockers before creating the deployment." "ERROR" }
elseif ($warns -gt 0) { Write-Status "No blockers, $warns warning(s) to review." "WARN" }
else { Write-Status "Ready: no blockers or warnings found." "OK" }
Write-Status "Report exported to $ExportPath" "INFO"
Write-Status "Not checked: Multi Admin Approval policies, assignment filters, scope tags, 'another active deployment already uses this payload' (portal only)." "INFO"
