<#
.SYNOPSIS
    Finds Intune assignment filters still using the deprecated osVersion property and drafts
    operatingSystemVersion translations.

.DESCRIPTION
    Companion to Intune/Troubleshooting/FilterOSVersionMigration-B.md and -A.md.

    Intune service release 2608 (Aug 2026) made operatingSystemVersion GA and deprecated osVersion.
    Existing osVersion filters keep working; this script prepares a controlled migration:

      1. Pulls every assignment filter (beta Graph: deviceManagement/assignmentFilters, paged).
      2. Classifies each by property usage: OsVersionOnly / Mixed / AlreadyMigrated / NoVersionProperty.
      3. For filters using osVersion, parses each simple clause
            (device|app).osVersion -<op> <value>
         and proposes an operatingSystemVersion equivalent:
            -eq / -ne              -> same operator, unquoted numeric version literal
            -in / -notIn           -> OR'd -eq / AND'd -ne chain
            -startsWith "a.b.c"    -> half-open range  -ge a.b.c.0  and  -lt a.b.(c+1).0   [Review]
            -contains/-notContains -> Manual (no version equivalent)
         Non-numeric literals (Apple "(build)" suffixes, SPV letters) are stripped where safe and marked Review.
      4. Flags mobile platforms (iOS / Android / AOSP) with KeepOnOsVersionIfAvailableApp because of the
         documented known issue: operatingSystemVersion on Available app assignments evaluates inconclusive.
      5. Optionally (-IncludeAssignments) lists what each filter is attached to via the beta 'payloads'
         navigation. Best-effort: if the endpoint is unavailable the column says so.

    It does NOT create, modify or delete filters, and does not evaluate rules against devices (use the
    portal's filter Preview for that - the translation must be verified there before use).

.PARAMETER TenantId
    Optional tenant ID/domain to connect to (MSP / GDAP use). Omit to use the current/default context.

.PARAMETER IncludeAssignments
    Resolve filter usage via GET .../assignmentFilters/{id}/payloads (beta, best-effort).

.PARAMETER OutputPath
    Folder for CSV output. Default: current directory.

.EXAMPLE
    .\Get-OSVersionFilterMigrationAudit.ps1 -OutputPath C:\Temp\FilterMig

.EXAMPLE
    .\Get-OSVersionFilterMigrationAudit.ps1 -TenantId contoso.onmicrosoft.com -IncludeAssignments -OutputPath C:\Temp\FilterMig\Contoso

.NOTES
    Requires : Microsoft.Graph.Authentication (Connect-MgGraph / Invoke-MgGraphRequest)
    Scope    : DeviceManagementConfiguration.Read.All
    Safe     : Read-only. Proposed rules are drafts - review every 'Review' / 'Manual' row and compare
               old vs new filter Preview counts before swapping assignments.
    Output   : OSVersionFilters.csv (one row per filter), OSVersionClauses.csv (one row per clause), Summary.csv
#>
[CmdletBinding()]
param(
    [string]$TenantId,
    [switch]$IncludeAssignments,
    [string]$OutputPath = '.'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    param([string]$Message, [string]$Status = 'INFO')
    $colour = switch ($Status) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Cyan' } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-GraphPaged {
    param([string]$Uri)
    $items = New-Object System.Collections.Generic.List[object]
    $next = $Uri
    while ($next) {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject
        if ($resp.PSObject.Properties['value']) { foreach ($v in @($resp.value)) { $items.Add($v) } }
        $next = $null
        if ($resp.PSObject.Properties['@odata.nextLink']) { $next = [string]$resp.'@odata.nextLink' }
    }
    return , $items.ToArray()
}

function ConvertTo-VersionLiteral {
    # Returns @{ Value = '<numeric version>'; Clean = $true|$false } or $null if not convertible.
    param([string]$Raw)
    $v = $Raw.Trim().Trim('"').Trim("'").Trim()
    if ($v -match '^\d+(\.\d+){0,3}$') { return @{ Value = $v; Clean = $true } }
    # Apple: "10.15.3 (19D2064)" or SPV "14.1.2a"
    if ($v -match '^(\d+(\.\d+){0,3})(\s*\(.*\)|[a-z])$') { return @{ Value = $Matches[1]; Clean = $false } }
    return $null
}

function Convert-OsVersionClause {
    # Input: entity (device|app), operator, raw value text. Output: pscustomobject with Proposed + Status + Note
    param([string]$Entity, [string]$Op, [string]$RawValue)
    $prop = "$Entity.operatingSystemVersion"
    $opL = $Op.ToLowerInvariant()
    switch ($opL) {
        { $_ -in 'eq', 'ne' } {
            $lit = ConvertTo-VersionLiteral $RawValue
            if (-not $lit) { return [pscustomobject]@{ Proposed = ''; Status = 'Manual'; Note = "Non-numeric literal $RawValue" } }
            $st = if ($lit.Clean) { 'Translated' } else { 'Review' }
            $note = if ($lit.Clean) { 'Check component count matches stored value (Windows = 4 parts)' } else { "Stripped suffix from $RawValue" }
            if ($opL -eq 'eq' -and $lit.Value.Split('.').Count -lt 4 -and $Entity -eq 'device') {
                $note = 'Partial version with -eq: will not match a 4-part Windows value; consider a -ge/-lt range'
                $st = 'Review'
            }
            return [pscustomobject]@{ Proposed = "($prop -$opL $($lit.Value))"; Status = $st; Note = $note }
        }
        { $_ -in 'in', 'notin' } {
            $inner = $RawValue.Trim().TrimStart('[').TrimEnd(']')
            $vals = @($inner -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $parts = @(); $status = 'Translated'; $notes = @()
            foreach ($x in $vals) {
                $lit = ConvertTo-VersionLiteral $x
                if (-not $lit) { return [pscustomobject]@{ Proposed = ''; Status = 'Manual'; Note = "Non-numeric list item $x" } }
                if (-not $lit.Clean) { $status = 'Review'; $notes += "stripped $x" }
                $cmp = if ($opL -eq 'in') { 'eq' } else { 'ne' }
                $parts += "($prop -$cmp $($lit.Value))"
            }
            $joiner = if ($opL -eq 'in') { ' or ' } else { ' and ' }
            $prop2 = '(' + ($parts -join $joiner) + ')'
            $notes += 'List converted to chain; check component counts'
            return [pscustomobject]@{ Proposed = $prop2; Status = $status; Note = ($notes -join '; ') }
        }
        'startswith' {
            $v = $RawValue.Trim().Trim('"').Trim("'").TrimEnd('.')
            if ($v -notmatch '^\d+(\.\d+){0,2}$') {
                return [pscustomobject]@{ Proposed = ''; Status = 'Manual'; Note = "Prefix $RawValue not a whole-component numeric prefix" }
            }
            $c = @($v.Split('.'))
            $upperParts = @($c)
            $upperParts[$upperParts.Count - 1] = [string]([int64]$upperParts[$upperParts.Count - 1] + 1)
            $lower = (@($c) + @('0')) -join '.'
            $upper = (@($upperParts) + @('0')) -join '.'
            $note = "String prefix treated as whole components. Old rule also matched longer numbers starting with '$($c[-1])' in that position (e.g. '10.0.2' matched 10.0.22000) - confirm intent"
            return [pscustomobject]@{ Proposed = "(($prop -ge $lower) and ($prop -lt $upper))"; Status = 'Review'; Note = $note }
        }
        default {
            return [pscustomobject]@{ Proposed = ''; Status = 'Manual'; Note = "Operator -$Op has no operatingSystemVersion equivalent" }
        }
    }
}

# ---------------------------------------------------------------- Preflight
if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
    throw 'Microsoft.Graph.Authentication is required: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
}
$ctx = Get-MgContext
$needConnect = (-not $ctx) -or ($TenantId -and $ctx.TenantId -ne $TenantId)
if ($needConnect) {
    $p = @{ Scopes = 'DeviceManagementConfiguration.Read.All'; NoWelcome = $true }
    if ($TenantId) { $p['TenantId'] = $TenantId }
    Connect-MgGraph @p
    $ctx = Get-MgContext
}
Write-Status "Connected to tenant $($ctx.TenantId) as $($ctx.Account)" 'OK'
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

# ---------------------------------------------------------------- Detect
$filters = Get-GraphPaged 'https://graph.microsoft.com/beta/deviceManagement/assignmentFilters'
Write-Status "Retrieved $($filters.Count) assignment filter(s)"

$clauseRegex = '(?i)\b(device|app)\.osVersion\s+-?(eq|ne|in|notIn|startsWith|contains|notContains)\s+("[^"]*"|\[[^\]]*\]|[^\s\)]+)'
$mobile = @('iOS', 'android', 'androidForWork', 'androidAOSP', 'androidMobileApplicationManagement', 'iOSMobileApplicationManagement')

$filterRows = New-Object System.Collections.Generic.List[object]
$clauseRows = New-Object System.Collections.Generic.List[object]

foreach ($f in $filters) {
    $rule = [string]$f.rule
    $usesOld = $rule -match '(?i)\b(device|app)\.osVersion\b'
    $usesNew = $rule -match '(?i)\b(device|app)\.operatingSystemVersion\b'
    $class = if ($usesOld -and $usesNew) { 'Mixed' } elseif ($usesOld) { 'OsVersionOnly' } elseif ($usesNew) { 'AlreadyMigrated' } else { 'NoVersionProperty' }
    if ($class -eq 'NoVersionProperty') { continue }

    $platform = [string]$f.platform
    $mgmtType = if ($f.PSObject.Properties['assignmentFilterManagementType']) { [string]$f.assignmentFilterManagementType } else { '' }
    $proposed = $rule
    $worst = if ($class -eq 'AlreadyMigrated') { 'AlreadyMigrated' } else { 'Translated' }
    $notes = New-Object System.Collections.Generic.List[string]

    if ($usesOld) {
        $ms = [regex]::Matches($rule, $clauseRegex)
        if ($ms.Count -eq 0) { $worst = 'Manual'; $notes.Add('osVersion present but no parsable clause') }
        foreach ($m in $ms) {
            $res = Convert-OsVersionClause -Entity $m.Groups[1].Value.ToLowerInvariant() -Op $m.Groups[2].Value -RawValue $m.Groups[3].Value
            $clauseRows.Add([pscustomobject]@{
                FilterId       = $f.id
                FilterName     = $f.displayName
                OriginalClause = $m.Value
                ProposedClause = $res.Proposed
                Status         = $res.Status
                Note           = $res.Note
            })
            if ($res.Status -eq 'Manual') { $worst = 'Manual' }
            elseif ($res.Status -eq 'Review' -and $worst -ne 'Manual') { $worst = 'Review' }
            if ($res.Proposed) {
                # The regex match excludes the clause's own parentheses, e.g. device.osVersion -eq "x".
                # Strip exactly one outer layer from the proposal so the original parentheses wrap it:
                #   (device.osVersion -startsWith "a.b")  ->  ((p -ge a.b.0) and (p -lt a.c.0))
                $inner = $res.Proposed.Substring(1, $res.Proposed.Length - 2)
                $proposed = $proposed.Replace($m.Value, $inner)
            }
            if ($res.Note) { $notes.Add($res.Note) }
        }
    }

    $mobileFlag = ($platform -in $mobile)
    if ($mobileFlag -and $usesOld) { $notes.Add('Mobile platform: keep osVersion on AVAILABLE app assignments (Learn known issue - inconclusive evaluation)') }

    $assignInfo = ''
    if ($IncludeAssignments) {
        try {
            $payloads = Get-GraphPaged ("https://graph.microsoft.com/beta/deviceManagement/assignmentFilters/{0}/payloads" -f $f.id)
            $assignInfo = if ($payloads.Count -eq 0) { 'None' } else {
                (@($payloads | ForEach-Object {
                    $pt = if ($_.PSObject.Properties['payloadType']) { $_.payloadType } else { '?' }
                    $pid2 = if ($_.PSObject.Properties['payloadId']) { $_.payloadId } else { '?' }
                    $ft = if ($_.PSObject.Properties['assignmentFilterType']) { $_.assignmentFilterType } else { '?' }
                    '{0}:{1}({2})' -f $pt, $pid2, $ft
                }) -join '; ')
            }
        } catch { $assignInfo = "Unavailable: $($_.Exception.Message)" }
    }

    $filterRows.Add([pscustomobject]@{
        FilterId          = $f.id
        FilterName        = $f.displayName
        Platform          = $platform
        ManagementType    = $mgmtType
        Classification    = $class
        Migration         = $worst
        MobileAvailableAppRisk = $mobileFlag
        OriginalRule      = $rule
        ProposedRule      = $(if ($class -eq 'AlreadyMigrated' -or $worst -eq 'Manual') { '' } else { $proposed })
        Notes             = ($notes -join ' | ')
        Assignments       = $assignInfo
        LastModified      = $(if ($f.PSObject.Properties['lastModifiedDateTime']) { $f.lastModifiedDateTime } else { '' })
    })
}

# ---------------------------------------------------------------- Report
$filterRows | Export-Csv (Join-Path $OutputPath 'OSVersionFilters.csv') -NoTypeInformation
$clauseRows | Export-Csv (Join-Path $OutputPath 'OSVersionClauses.csv') -NoTypeInformation

$summary = @(
    [pscustomobject]@{ Metric = 'TotalFilters'; Value = $filters.Count }
    [pscustomobject]@{ Metric = 'UsingOsVersion'; Value = @($filterRows | Where-Object { $_.Classification -in 'OsVersionOnly', 'Mixed' }).Count }
    [pscustomobject]@{ Metric = 'AlreadyMigrated'; Value = @($filterRows | Where-Object Classification -eq 'AlreadyMigrated').Count }
    [pscustomobject]@{ Metric = 'Translated'; Value = @($filterRows | Where-Object Migration -eq 'Translated').Count }
    [pscustomobject]@{ Metric = 'NeedsReview'; Value = @($filterRows | Where-Object Migration -eq 'Review').Count }
    [pscustomobject]@{ Metric = 'Manual'; Value = @($filterRows | Where-Object Migration -eq 'Manual').Count }
    [pscustomobject]@{ Metric = 'MobileKeepCandidates'; Value = @($filterRows | Where-Object { $_.MobileAvailableAppRisk -and $_.Classification -ne 'AlreadyMigrated' }).Count }
)
$summary | Export-Csv (Join-Path $OutputPath 'Summary.csv') -NoTypeInformation
$summary | Format-Table -AutoSize | Out-String | Write-Host

$pending = @($filterRows | Where-Object { $_.Classification -in 'OsVersionOnly', 'Mixed' }).Count
if ($pending -eq 0) { Write-Status 'No filters use osVersion.' 'OK' }
else { Write-Status "$pending filter(s) still use osVersion. Review OSVersionFilters.csv; verify every ProposedRule with portal Preview before use." 'WARN' }
