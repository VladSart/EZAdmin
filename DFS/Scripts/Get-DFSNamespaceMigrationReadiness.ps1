<#
.SYNOPSIS
    Read-only readiness audit for DFS Namespace migrations (UNC->namespace, DomainV1->DomainV2, Standalone->Domain).

.DESCRIPTION
    Collects and flags:
      - Every domain-based root and its Type (DomainV1 / DomainV2), state, folder count, root targets
      - Stand-alone roots on servers named in -StandaloneServer
      - ROOT_V1                : root still in Windows 2000 mode
      - ROOT_V1_LARGE          : DomainV1 root with more than 5000 folders
      - ROOT_SINGLE_TARGET     : root served by only one namespace server
      - ROOT_TARGET_OFFLINE    : root target not Online
      - STANDALONE_ROOT        : stand-alone root (single point of failure, path tied to server)
      - DFL_TOO_LOW            : domain functional level below Windows2008Domain (blocks DomainV2)
      - GPO_LEGACY_PATH        : GPO report XML contains \\<LegacyServer>\ (drive maps, FR, scripts)
      - AD_HOMEDIR_LEGACY      : user homeDirectory points at a legacy server
      - AD_PROFILE_LEGACY      : user profilePath points at a legacy server
      - NETLOGON_LEGACY_PATH   : logon script in NETLOGON references a legacy server
    Optionally tests every folder target path (FOLDER_TARGET_UNREACHABLE).

    Does NOT change anything. Does not inspect shortcuts, Office MRU, Offline Files caches or app configs.

.PARAMETER Domain
    AD DNS domain name. Default: current user's DNS domain.

.PARAMETER LegacyServer
    One or more server names (NetBIOS and/or FQDN) whose UNC paths you are migrating away from.

.PARAMETER StandaloneServer
    Servers to check for stand-alone roots.

.PARAMETER TestFolderTargets
    Test-Path every folder target (slow on large namespaces).

.PARAMETER SkipGpoScan
    Skip the Get-GPOReport scan (needs GroupPolicy module).

.PARAMETER OutputPath
    Folder for CSV output. Default: $env:TEMP

.EXAMPLE
    .\Get-DFSNamespaceMigrationReadiness.ps1 -LegacyServer FS01,fs01.contoso.com -StandaloneServer FS01 -TestFolderTargets

.NOTES
    Requires: DFSN, ActiveDirectory modules (RSAT); GroupPolicy module for GPO scan.
    Run as: domain user with read access to AD/SYSVOL; namespace read rights. No admin needed for read-only queries.
    Safe: read-only.
#>
[CmdletBinding()]
param(
    [string]$Domain = $env:USERDNSDOMAIN,
    [string[]]$LegacyServer = @(),
    [string[]]$StandaloneServer = @(),
    [switch]$TestFolderTargets,
    [switch]$SkipGpoScan,
    [string]$OutputPath = $env:TEMP
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$findings = New-Object System.Collections.Generic.List[object]
function Add-Finding {
    param([string]$Code, [string]$Severity, [string]$Object, [string]$Detail)
    $findings.Add([pscustomobject]@{ Code = $Code; Severity = $Severity; Object = $Object; Detail = $Detail })
}

# ---------- Preflight ----------
if (-not $Domain) { throw "No -Domain supplied and USERDNSDOMAIN is empty." }
foreach ($m in 'DFSN','ActiveDirectory') {
    if (-not (Get-Module -ListAvailable -Name $m)) { throw "Module $m not found. Install RSAT ($m)." }
    Import-Module $m -ErrorAction Stop
}
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
$legacyRx = $null
if ($LegacyServer.Count -gt 0) {
    $legacyRx = '\\\\(' + (($LegacyServer | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\\'
}
Write-Status "Domain: $Domain  Legacy servers: $($LegacyServer -join ', ')"

# ---------- Domain functional level ----------
try {
    $dfl = [string](Get-ADDomain -Identity $Domain).DomainMode
    $old = @('Windows2000Domain','Windows2003InterimDomain','Windows2003Domain')
    if ($old -contains $dfl) { Add-Finding 'DFL_TOO_LOW' 'HIGH' $Domain "DomainMode=$dfl; DomainV2 roots need Windows2008Domain+" ; Write-Status "DFL $dfl blocks DomainV2" "WARN" }
    else { Write-Status "Domain functional level: $dfl" "OK" }
} catch { Write-Status "Could not read domain functional level: $($_.Exception.Message)" "WARN" }

# ---------- Domain roots ----------
$rootRows = New-Object System.Collections.Generic.List[object]
$roots = @()
try { $roots = @(Get-DfsnRoot -Domain $Domain -ErrorAction Stop) } catch { Write-Status "Get-DfsnRoot -Domain failed: $($_.Exception.Message)" "WARN" }
Write-Status "Domain-based roots found: $($roots.Count)"

$allRoots = @($roots)
foreach ($s in $StandaloneServer) {
    try {
        $sr = @(Get-DfsnRoot -ComputerName $s -ErrorAction Stop | Where-Object { [string]$_.Type -eq 'Standalone' })
        $allRoots += $sr
        Write-Status "Stand-alone roots on ${s}: $($sr.Count)"
    } catch { Write-Status "Get-DfsnRoot -ComputerName $s failed: $($_.Exception.Message)" "WARN" }
}

foreach ($r in $allRoots) {
    $path = [string]$r.Path
    $type = [string]$r.Type
    $targets = @()
    $folders = @()
    try { $targets = @(Get-DfsnRootTarget -Path $path -ErrorAction Stop) } catch { Write-Status "Root targets for $path failed: $($_.Exception.Message)" "WARN" }
    try { $folders = @(Get-DfsnFolder -Path "$path\*" -ErrorAction Stop) } catch { $folders = @() }

    if ($type -eq 'DomainV1') {
        Add-Finding 'ROOT_V1' 'MEDIUM' $path 'Windows 2000 mode: no namespace ABE, whole-namespace AD blob'
        if ($folders.Count -gt 5000) { Add-Finding 'ROOT_V1_LARGE' 'HIGH' $path "$($folders.Count) folders in DomainV1 root" }
    }
    if ($type -eq 'Standalone') { Add-Finding 'STANDALONE_ROOT' 'MEDIUM' $path 'Path tied to server; HA only via failover cluster' }
    if ($type -ne 'Standalone' -and $targets.Count -lt 2) { Add-Finding 'ROOT_SINGLE_TARGET' 'MEDIUM' $path "Root targets: $($targets.Count)" }
    foreach ($t in $targets) {
        if ([string]$t.State -ne 'Online') { Add-Finding 'ROOT_TARGET_OFFLINE' 'HIGH' $path "$($t.TargetPath) State=$($t.State)" }
    }

    $unreach = 0
    if ($TestFolderTargets) {
        foreach ($f in $folders) {
            try {
                foreach ($ft in @(Get-DfsnFolderTarget -Path $f.Path -ErrorAction Stop)) {
                    if (-not (Test-Path -LiteralPath $ft.TargetPath)) {
                        $unreach++
                        Add-Finding 'FOLDER_TARGET_UNREACHABLE' 'HIGH' $f.Path "$($ft.TargetPath) State=$($ft.State)"
                    }
                }
            } catch { Write-Status "Folder targets for $($f.Path) failed: $($_.Exception.Message)" "WARN" }
        }
    }

    $rootRows.Add([pscustomobject]@{
        Path = $path; Type = $type; State = [string]$r.State; FolderCount = $folders.Count
        RootTargets = (($targets | ForEach-Object { "$($_.TargetPath)[$($_.State)]" }) -join '; ')
        UnreachableFolderTargets = $(if ($TestFolderTargets) { $unreach } else { 'not tested' })
    })
}

# ---------- Legacy path references ----------
if ($legacyRx) {
    # AD user attributes
    try {
        $users = @(Get-ADUser -Filter * -Server $Domain -Properties homeDirectory, profilePath, scriptPath)
        foreach ($u in $users) {
            if ($u.homeDirectory -and ($u.homeDirectory -match $legacyRx)) { Add-Finding 'AD_HOMEDIR_LEGACY' 'MEDIUM' $u.SamAccountName $u.homeDirectory }
            if ($u.profilePath   -and ($u.profilePath   -match $legacyRx)) { Add-Finding 'AD_PROFILE_LEGACY' 'MEDIUM' $u.SamAccountName $u.profilePath }
        }
        Write-Status "Scanned $($users.Count) users for legacy home/profile paths" "OK"
    } catch { Write-Status "AD user scan failed: $($_.Exception.Message)" "WARN" }

    # GPOs
    if (-not $SkipGpoScan) {
        if (Get-Module -ListAvailable -Name GroupPolicy) {
            Import-Module GroupPolicy
            try {
                foreach ($g in @(Get-GPO -All -Domain $Domain)) {
                    try {
                        [string]$xml = Get-GPOReport -Guid $g.Id -ReportType Xml -Domain $Domain
                        $hits = [regex]::Matches($xml, $legacyRx + '[^<"]*')
                        if ($hits.Count -gt 0) {
                            $sample = (($hits | Select-Object -First 3 | ForEach-Object { $_.Value }) -join ' | ')
                            Add-Finding 'GPO_LEGACY_PATH' 'MEDIUM' $g.DisplayName "$($hits.Count) hit(s): $sample"
                        }
                    } catch { Write-Status "GPO report failed for $($g.DisplayName): $($_.Exception.Message)" "WARN" }
                }
                Write-Status "GPO scan complete" "OK"
            } catch { Write-Status "Get-GPO failed: $($_.Exception.Message)" "WARN" }
        } else { Write-Status "GroupPolicy module not available - GPO scan skipped" "WARN" }
    }

    # NETLOGON scripts
    $netlogon = "\\$Domain\NETLOGON"
    if (Test-Path $netlogon) {
        foreach ($file in @(Get-ChildItem -Path $netlogon -Recurse -File -Include *.bat,*.cmd,*.vbs,*.ps1,*.kix -ErrorAction SilentlyContinue)) {
            try {
                $c = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
                if ($c -and ($c -match $legacyRx)) { Add-Finding 'NETLOGON_LEGACY_PATH' 'MEDIUM' $file.FullName 'References legacy server' }
            } catch { }
        }
    } else { Write-Status "$netlogon not reachable - logon script scan skipped" "WARN" }
} else {
    Write-Status "No -LegacyServer given - path reference scan skipped" "INFO"
}

# ---------- Report ----------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$rootCsv = Join-Path $OutputPath "DfsnMigration-Roots-$stamp.csv"
$findCsv = Join-Path $OutputPath "DfsnMigration-Findings-$stamp.csv"
$rootRows | Export-Csv -Path $rootCsv -NoTypeInformation
$findings | Export-Csv -Path $findCsv -NoTypeInformation

Write-Host ""
$rootRows | Format-Table Path, Type, State, FolderCount, RootTargets -AutoSize
if ($findings.Count -eq 0) { Write-Status "No migration blockers found" "OK" }
else {
    $findings | Group-Object Code | Sort-Object Count -Descending | ForEach-Object { Write-Status "$($_.Name): $($_.Count)" "WARN" }
}
Write-Status "Roots CSV:    $rootCsv"
Write-Status "Findings CSV: $findCsv"
