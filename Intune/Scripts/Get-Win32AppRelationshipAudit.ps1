<#
.SYNOPSIS
    Audits Intune Win32 app supersedence and dependency relationships tenant-wide and flags design problems.

.DESCRIPTION
    Read-only. Uses Microsoft Graph (beta) to:
      1. List all Win32 apps (win32LobApp and win32CatalogApp)
      2. Pull relationships for every app that has any (by roll-up counters, or for all apps with -ForceAllRelationships)
      3. Pull assignments for apps that supersede or are depended on
      4. Build the supersedence graphs (connected components) and dependency graphs
    Flags:
      GraphNearLimit          supersedence graph with >= -NodeWarnThreshold nodes (hard limit 11)
      GraphAtLimit            supersedence graph with >= 11 nodes
      UntargetedSuperseding   head (newest) app of a supersedence graph has no assignments, so supersedence never runs
      DependencyOnSuperseded  an app is used as a dependency AND is superseded by another app (Microsoft-documented conflict)
      ReplaceOrphansDeps      an app with dependencies is replaced by another app (its dependencies will be orphaned)
      DependencyGraphLarge    dependency graph (parent + recursive children) > 50 apps (hard limit 100)
      DetectOnlyDependency    dependency set to 'detect' (Automatically install = No), so the parent waits if the child is absent
    Output: one CSV of relationships (edges), one CSV of findings, and a console summary.

    Does NOT evaluate detection rules or device install state, and doesn't change anything.

.PARAMETER OutputPath
    Folder for CSV output. Defaults to the current directory.

.PARAMETER NodeWarnThreshold
    Supersedence graph size that raises GraphNearLimit (default 9).

.PARAMETER ForceAllRelationships
    Query /relationships for every Win32 app, not only those whose counters show relationships. Slower; use if the
    counters look wrong.

.EXAMPLE
    .\Get-Win32AppRelationshipAudit.ps1
    Audits the tenant and writes Win32Rel_Edges_<stamp>.csv and Win32Rel_Findings_<stamp>.csv.

.EXAMPLE
    .\Get-Win32AppRelationshipAudit.ps1 -NodeWarnThreshold 8 -OutputPath C:\Temp -ForceAllRelationships

.NOTES
    Requires: Microsoft.Graph.Authentication module; delegated scope DeviceManagementApps.Read.All
    (Intune Administrator / Application Manager / read-only role with Mobile apps: Read). No local admin needed.
    Safe: read-only. Companion to Intune/Troubleshooting/Win32AppRelationships-A.md / -B.md.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = (Get-Location).Path,
    [ValidateRange(2, 11)]
    [int]$NodeWarnThreshold = 9,
    [switch]$ForceAllRelationships
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-GraphAll {
    param([string]$Uri)
    $items = New-Object System.Collections.Generic.List[object]
    $next = $Uri
    while ($next) {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $next
        if ($resp.ContainsKey('value')) { foreach ($v in $resp['value']) { $items.Add($v) } }
        $next = $null
        if ($resp.ContainsKey('@odata.nextLink')) { $next = $resp['@odata.nextLink'] }
    }
    return ,$items
}

function Get-Prop {
    param($Obj, [string]$Name)
    if ($Obj -is [System.Collections.IDictionary]) { if ($Obj.Contains($Name)) { return $Obj[$Name] } else { return $null } }
    if ($Obj.PSObject.Properties.Name -contains $Name) { return $Obj.$Name }
    return $null
}

# ---------------- Preflight ----------------
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Status "Microsoft.Graph.Authentication not installed. Install-Module Microsoft.Graph.Authentication -Scope CurrentUser" "ERROR"
    return
}
Import-Module Microsoft.Graph.Authentication
$ctx = Get-MgContext
if (-not $ctx -or (@($ctx.Scopes) -notcontains 'DeviceManagementApps.Read.All' -and @($ctx.Scopes) -notcontains 'DeviceManagementApps.ReadWrite.All')) {
    Connect-MgGraph -Scopes "DeviceManagementApps.Read.All" -NoWelcome
    $ctx = Get-MgContext
}
Write-Status "Connected to tenant $($ctx.TenantId) as $($ctx.Account)" "OK"
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$base  = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps"

# ---------------- Detect ----------------
Write-Status "Retrieving Win32 apps..."
$allApps = $null
try { $allApps = Get-GraphAll -Uri "$base`?`$filter=isof('microsoft.graph.win32LobApp')" } catch { Write-Status "isof() filter rejected; falling back to client-side filtering." "WARN" }
if ($null -eq $allApps -or $allApps.Count -eq 0) {
    # Fallback: some tenants reject isof() - pull everything and filter client-side
    $allApps = Get-GraphAll -Uri $base
    $allApps = @($allApps | Where-Object { [string](Get-Prop $_ '@odata.type') -match 'win32LobApp|win32CatalogApp' })
}
Write-Status "Win32 apps found: $(@($allApps).Count)"

$apps = @{}
foreach ($a in $allApps) {
    $apps[[string](Get-Prop $a 'id')] = [PSCustomObject]@{
        Id          = [string](Get-Prop $a 'id')
        Name        = [string](Get-Prop $a 'displayName')
        Version     = [string](Get-Prop $a 'displayVersion')
        Counters    = [int](Get-Prop $a 'dependentAppCount') + [int](Get-Prop $a 'supersedingAppCount') + [int](Get-Prop $a 'supersededAppCount')
        Assignments = $null
    }
}

# Relationships (edges stored once, oriented source -> target where source is the declaring/"parent" side)
$edges = @{}
$i = 0
foreach ($app in @($apps.Values)) {
    $i++
    if (-not $ForceAllRelationships -and $app.Counters -eq 0) { continue }
    Write-Progress -Activity "Reading relationships" -Status $app.Name -PercentComplete ([int](100 * $i / [Math]::Max(1, $apps.Count)))
    try {
        $rels = Get-GraphAll -Uri "$base/$($app.Id)/relationships"
    } catch {
        Write-Status "Relationships unreadable for $($app.Name): $($_.Exception.Message)" "WARN"; continue
    }
    foreach ($r in $rels) {
        $type = [string](Get-Prop $r '@odata.type')
        $tid  = [string](Get-Prop $r 'targetId')
        $dir  = [string](Get-Prop $r 'targetType')
        # child = this app is the declaring side (supersedes / depends on the target)
        if ($dir -eq 'child') { $src = $app.Id; $dst = $tid } else { $src = $tid; $dst = $app.Id }
        $kind = if ($type -match 'Supersedence') { 'Supersedes' } elseif ($type -match 'Dependency') { 'DependsOn' } else { 'Other' }
        $sub  = if ($kind -eq 'Supersedes') { [string](Get-Prop $r 'supersedenceType') } else { [string](Get-Prop $r 'dependencyType') }
        $key  = "$src|$kind|$dst"
        if (-not $edges.ContainsKey($key)) {
            $edges[$key] = [PSCustomObject]@{ SourceId=$src; Kind=$kind; SubType=$sub; TargetId=$dst }
            foreach ($id in $src, $dst) {
                if (-not $apps.ContainsKey($id)) {
                    $apps[$id] = [PSCustomObject]@{ Id=$id; Name=[string](Get-Prop $r 'targetDisplayName'); Version=[string](Get-Prop $r 'targetDisplayVersion'); Counters=1; Assignments=$null }
                }
            }
        }
    }
}
Write-Progress -Activity "Reading relationships" -Completed
$edgeList = @($edges.Values)
Write-Status "Relationships found: $($edgeList.Count) (supersedence: $(@($edgeList | Where-Object Kind -eq 'Supersedes').Count), dependency: $(@($edgeList | Where-Object Kind -eq 'DependsOn').Count))"

function Get-AppAssignmentCount {
    param([string]$Id)
    $app = $apps[$Id]
    if ($null -eq $app.Assignments) {
        try { $app.Assignments = @(Get-GraphAll -Uri "$base/$Id/assignments").Count } catch { $app.Assignments = -1 }
    }
    return $app.Assignments
}

# ---------------- Execute (analyse) ----------------
$findings = New-Object System.Collections.Generic.List[object]
function Add-Finding { param([string]$Flag, [string]$Severity, [string]$AppId, [string]$Detail)
    $n = if ($apps.ContainsKey($AppId)) { $apps[$AppId].Name } else { $AppId }
    $findings.Add([PSCustomObject]@{ Flag=$Flag; Severity=$Severity; AppName=$n; AppId=$AppId; Detail=$Detail })
}

# Supersedence components (undirected connectivity)
$sEdges = @($edgeList | Where-Object Kind -eq 'Supersedes')
$adj = @{}
foreach ($e in $sEdges) {
    foreach ($pair in @(@($e.SourceId, $e.TargetId), @($e.TargetId, $e.SourceId))) {
        if (-not $adj.ContainsKey($pair[0])) { $adj[$pair[0]] = New-Object System.Collections.Generic.HashSet[string] }
        [void]$adj[$pair[0]].Add($pair[1])
    }
}
$seen = New-Object System.Collections.Generic.HashSet[string]
$graphNo = 0
foreach ($start in @($adj.Keys)) {
    if ($seen.Contains($start)) { continue }
    $graphNo++
    $comp = New-Object System.Collections.Generic.List[string]
    $queue = New-Object System.Collections.Generic.Queue[string]
    $queue.Enqueue($start); [void]$seen.Add($start)
    while ($queue.Count -gt 0) {
        $n = $queue.Dequeue(); $comp.Add($n)
        foreach ($m in $adj[$n]) { if ($seen.Add($m)) { $queue.Enqueue($m) } }
    }
    $size = $comp.Count
    # Heads = nodes in the component that are never superseded
    $superseded = @($sEdges | Where-Object { $comp.Contains($_.TargetId) } | ForEach-Object { $_.TargetId })
    $heads = @($comp | Where-Object { $superseded -notcontains $_ })
    $headNames = ($heads | ForEach-Object { $apps[$_].Name }) -join '; '
    $headId = if ($heads.Count -gt 0) { $heads[0] } else { $comp[0] }
    if ($size -ge 11) {
        Add-Finding 'GraphAtLimit' 'High' $headId "Supersedence graph #$graphNo has $size nodes (limit 11). Heads: $headNames"
    } elseif ($size -ge $NodeWarnThreshold) {
        Add-Finding 'GraphNearLimit' 'Medium' $headId "Supersedence graph #$graphNo has $size nodes (limit 11). Heads: $headNames"
    }
    foreach ($h in $heads) {
        $cnt = Get-AppAssignmentCount $h
        if ($cnt -eq 0) { Add-Finding 'UntargetedSuperseding' 'High' $h "Head of supersedence graph #$graphNo has no assignments; supersedence will not run." }
    }
}

# Dependency on superseded app
$dEdges = @($edgeList | Where-Object Kind -eq 'DependsOn')
$supersededIds = @($sEdges | ForEach-Object { $_.TargetId } | Select-Object -Unique)
foreach ($d in $dEdges) {
    if ($supersededIds -contains $d.TargetId) {
        $by = ($sEdges | Where-Object TargetId -eq $d.TargetId | ForEach-Object { $apps[$_.SourceId].Name }) -join '; '
        Add-Finding 'DependencyOnSuperseded' 'High' $d.SourceId "Depends on '$($apps[$d.TargetId].Name)' which is superseded by '$by' (documented conflict). Repoint the dependency to the new version."
    }
    if ($d.SubType -eq 'detect') {
        Add-Finding 'DetectOnlyDependency' 'Low' $d.SourceId "Dependency on '$($apps[$d.TargetId].Name)' is detect-only (Automatically install = No)."
    }
}

# Replace of an app that has dependencies -> orphans
foreach ($s in ($sEdges | Where-Object SubType -eq 'replace')) {
    $deps = @($dEdges | Where-Object SourceId -eq $s.TargetId)
    if ($deps.Count -gt 0) {
        $names = ($deps | ForEach-Object { $apps[$_.TargetId].Name }) -join '; '
        Add-Finding 'ReplaceOrphansDeps' 'Medium' $s.TargetId "Replaced by '$($apps[$s.SourceId].Name)'; its dependencies ($names) will be left on devices."
    }
}

# Dependency graph size (recursive children per root parent)
$parents = @($dEdges | ForEach-Object { $_.SourceId } | Select-Object -Unique)
$children = @($dEdges | ForEach-Object { $_.TargetId } | Select-Object -Unique)
foreach ($root in ($parents | Where-Object { $children -notcontains $_ })) {
    $visited = New-Object System.Collections.Generic.HashSet[string]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $n = $stack.Pop()
        if (-not $visited.Add($n)) { continue }
        foreach ($c in ($dEdges | Where-Object SourceId -eq $n)) { $stack.Push($c.TargetId) }
    }
    if ($visited.Count -gt 50) { Add-Finding 'DependencyGraphLarge' 'Medium' $root "Dependency graph has $($visited.Count) apps (limit 100)." }
}

# ---------------- Validate / Report ----------------
$edgeOut = $edgeList | ForEach-Object {
    [PSCustomObject]@{
        SourceApp     = $apps[$_.SourceId].Name
        SourceVersion = $apps[$_.SourceId].Version
        Relationship  = $_.Kind
        SubType       = $_.SubType
        TargetApp     = $apps[$_.TargetId].Name
        TargetVersion = $apps[$_.TargetId].Version
        SourceId      = $_.SourceId
        TargetId      = $_.TargetId
    }
}
$edgeFile = Join-Path $OutputPath "Win32Rel_Edges_$stamp.csv"
$findFile = Join-Path $OutputPath "Win32Rel_Findings_$stamp.csv"
@($edgeOut) | Export-Csv -Path $edgeFile -NoTypeInformation -Encoding UTF8
@($findings) | Export-Csv -Path $findFile -NoTypeInformation -Encoding UTF8

Write-Host ""
if ($findings.Count -eq 0) {
    Write-Status "No relationship design problems found." "OK"
} else {
    $findings | Group-Object Flag | Sort-Object Count -Descending | Select-Object Name, Count | Format-Table -AutoSize
    foreach ($f in ($findings | Where-Object Severity -eq 'High')) { Write-Status "$($f.Flag): $($f.AppName) - $($f.Detail)" "WARN" }
}
Write-Status "Supersedence graphs: $graphNo | Edges: $edgeFile" "OK"
Write-Status "Findings: $findFile" "OK"
