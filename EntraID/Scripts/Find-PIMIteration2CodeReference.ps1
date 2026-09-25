<#
.SYNOPSIS
    Statically scans scripts, IaC and exported flow/Logic App definitions for calls to the
    Microsoft Entra PIM Iteration 2 beta APIs that stop returning data on 2026-10-28.

.DESCRIPTION
    Get-PIMIteration2APIUsageAudit.ps1 finds service principals that hold the legacy
    PrivilegedAccess.* Graph permissions. This script covers the other half: the source-code,
    flow-definition and config grep that PIMIteration2Retirement-B.md Triage step 2 describes.

    It recursively searches the given path(s) for:
      Iteration2Endpoint      /beta/privilegedAccess/aadRoles|azureResources|aadGroups
      Iteration2ResourceType  governanceRoleAssignmentRequest, governanceRoleAssignment,
                              governanceRoleDefinition, governanceRoleSetting,
                              governanceResource, governanceSubject
      Iteration2Permission    PrivilegedAccess.Read|ReadWrite.AzureAD|AzureResources|AzureADGroup
      Iteration3 (info only)  unifiedRoleEligibilityScheduleRequest / ...AssignmentScheduleRequest,
                              roleEligibilityScheduleRequests (ARM), identityGovernance/privilegedAccess/group

    The Iteration 3 Groups path (identityGovernance/privilegedAccess/group) contains the string
    "privilegedAccess" but is NOT legacy. The endpoint regex is anchored on "/beta/privilegedAccess/"
    followed by an Iteration 2 segment, so it doesn't produce false positives on it.

    Default file types: .ps1 .psm1 .psd1 .py .js .ts .cs .json .yaml .yml .bicep .tf .kql .md .txt .xml .config
    Power Automate: export the solution / flow package (zip), extract it, and point -Path at the
    extracted folder (flow definitions are JSON under Workflows/).
    Logic Apps: export with  Get-AzLogicApp -ResourceGroupName <rg> -Name <app> | Select-Object -ExpandProperty Definition | ConvertTo-Json -Depth 50 | Out-File <file>.json

    Doesn't: read Graph activity logs (use the KQL in PIMIteration2Retirement-A.md), open zip
    files, or modify anything.

.PARAMETER Path
    One or more folders or files to scan.

.PARAMETER Include
    File extensions to scan (with leading dot). Default list above.

.PARAMETER OutputPath
    Folder for the CSV. Default: current directory.

.PARAMETER MaxFileSizeMB
    Skip files larger than this. Default 20.

.EXAMPLE
    .\Find-PIMIteration2CodeReference.ps1 -Path C:\Repos
    Scans all repos under C:\Repos and writes PIMIteration2CodeRefs-<timestamp>.csv.

.EXAMPLE
    .\Find-PIMIteration2CodeReference.ps1 -Path C:\Repos,D:\FlowExports -OutputPath C:\Temp -MaxFileSizeMB 50

.NOTES
    Requires : PowerShell 5.1 or 7.x. No modules, no network access, no admin rights.
    Safety   : Read-only. Safe to run anywhere.
    Related  : EntraID/Troubleshooting/PIMIteration2Retirement-A.md / -B.md
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Path,
    [string[]]$Include = @('.ps1', '.psm1', '.psd1', '.py', '.js', '.ts', '.cs', '.json', '.yaml', '.yml',
                           '.bicep', '.tf', '.kql', '.md', '.txt', '.xml', '.config'),
    [string]$OutputPath = (Get-Location).Path,
    [int]$MaxFileSizeMB = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------- Patterns ----------------
$patterns = @(
    [pscustomobject]@{ Category = 'Iteration2Endpoint';     Severity = 'HIGH'; Provider = '';
        Regex = '(?i)/beta/privilegedAccess/(aadRoles|azureResources|aadGroups)\b' }
    [pscustomobject]@{ Category = 'Iteration2ResourceType'; Severity = 'HIGH'; Provider = '';
        Regex = '(?i)\bgovernance(RoleAssignmentRequest|RoleAssignment|RoleDefinition|RoleSetting|Resource|Subject)s?\b' }
    [pscustomobject]@{ Category = 'Iteration2Permission';   Severity = 'MEDIUM'; Provider = '';
        Regex = '(?i)\bPrivilegedAccess\.(Read|ReadWrite)\.(AzureADGroup|AzureAD|AzureResources)\b' }
    [pscustomobject]@{ Category = 'Iteration3';             Severity = 'INFO'; Provider = 'EntraRoles';
        Regex = '(?i)\bunifiedRole(Eligibility|Assignment)Schedule(Request|Instance)?\b|/roleManagement/directory/role(Eligibility|Assignment)Schedule' }
    [pscustomobject]@{ Category = 'Iteration3';             Severity = 'INFO'; Provider = 'AzureResources';
        Regex = '(?i)Microsoft\.Authorization/role(Eligibility|Assignment)Schedule(Requests|Instances)|\b(New|Get)-AzRole(Eligibility|Assignment)Schedule' }
    [pscustomobject]@{ Category = 'Iteration3';             Severity = 'INFO'; Provider = 'Groups';
        Regex = '(?i)identityGovernance/privilegedAccess/group/|\bprivilegedAccessGroup(Eligibility|Assignment)Schedule' }
)
foreach ($p in $patterns) { $p | Add-Member -NotePropertyName Compiled -NotePropertyValue ([regex]::new($p.Regex)) }

function Get-ProviderFromMatch([string]$Text) {
    if ($Text -match '(?i)aadRoles|AzureAD(?!Group)') { return 'EntraRoles' }
    if ($Text -match '(?i)azureResources')            { return 'AzureResources' }
    if ($Text -match '(?i)aadGroups|AzureADGroup')    { return 'Groups' }
    return 'Unknown'
}

# ---------------- Preflight ----------------
if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$includeSet = @($Include | ForEach-Object { $_.ToLowerInvariant() })
$maxBytes   = [int64]$MaxFileSizeMB * 1MB

$files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
foreach ($p in $Path) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Status "Path not found, skipped: $p" "WARN"; continue }
    $item = Get-Item -LiteralPath $p
    if ($item.PSIsContainer) {
        Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $includeSet -contains $_.Extension.ToLowerInvariant() -and $_.FullName -notmatch '[\\/](\.git|node_modules)[\\/]' } |
            ForEach-Object { $files.Add($_) }
    } else {
        $files.Add($item)
    }
}
Write-Status "Files to scan: $($files.Count)"
if ($files.Count -eq 0) { Write-Status "Nothing to scan." "WARN"; return }

# ---------------- Detect ----------------
$hits = New-Object System.Collections.Generic.List[object]
$skipped = 0
$i = 0
foreach ($f in $files) {
    $i++
    if ($i % 500 -eq 0) { Write-Status "Scanned $i / $($files.Count)" }
    if ($f.Length -gt $maxBytes) { $skipped++; continue }
    try {
        $lines = [System.IO.File]::ReadAllLines($f.FullName)
    } catch {
        $skipped++; continue
    }
    for ($n = 0; $n -lt $lines.Length; $n++) {
        $line = $lines[$n]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        foreach ($p in $patterns) {
            $m = $p.Compiled.Match($line)
            if ($m.Success) {
                $provider = if ($p.Provider) { $p.Provider } else { Get-ProviderFromMatch $m.Value }
                $snippet  = $line.Trim()
                if ($snippet.Length -gt 240) { $snippet = $snippet.Substring(0, 240) + '...' }
                $hits.Add([pscustomobject]@{
                    Severity   = $p.Severity
                    Category   = $p.Category
                    Provider   = $provider
                    Match      = $m.Value
                    File       = $f.FullName
                    Line       = $n + 1
                    Snippet    = $snippet
                })
            }
        }
    }
}

# ---------------- Report ----------------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$csv   = Join-Path $OutputPath "PIMIteration2CodeRefs-$stamp.csv"
$hits | Sort-Object @{e={ switch ($_.Severity) { 'HIGH' {0} 'MEDIUM' {1} default {2} } }}, File, Line |
    Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8

$legacy     = @($hits | Where-Object { $_.Category -like 'Iteration2*' })
$legacyFile = @($legacy | Select-Object -ExpandProperty File -Unique)
$it3        = @($hits | Where-Object Category -eq 'Iteration3')
$it3Files   = @($it3 | ForEach-Object { $_.File } | Select-Object -Unique)

Write-Host ""
if ($legacy.Count -gt 0) {
    Write-Status "Iteration 2 references: $($legacy.Count) in $($legacyFile.Count) file(s). These stop working on 2026-10-28." "WARN"
    $legacy | Group-Object Provider | ForEach-Object { Write-Status ("  {0,-15} {1}" -f $_.Name, $_.Count) "WARN" }
    $mixed = @($legacyFile | Where-Object { $it3Files -contains $_ })
    if ($mixed.Count -gt 0) { Write-Status "Files mixing Iteration 2 and 3 (partial migration): $($mixed.Count)" "WARN" }
} else {
    Write-Status "No Iteration 2 references found." "OK"
}
Write-Status "Iteration 3 references (info): $($it3.Count)"
if ($skipped -gt 0) { Write-Status "Skipped (too large or unreadable): $skipped" "WARN" }
Write-Status "CSV: $csv" "OK"
Write-Status "Static scans can't see callers you don't have the source for. Also run the MicrosoftGraphActivityLogs KQL in PIMIteration2Retirement-A.md." "INFO"
