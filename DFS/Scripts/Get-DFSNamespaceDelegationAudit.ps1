<#
.SYNOPSIS
    Read-only audit of who can manage DFS Namespaces (management-plane delegation) in a domain.

.DESCRIPTION
    For every domain-based namespace (msDFS-Namespacev2 and legacy fTDfs objects) under
    CN=Dfs-Configuration,CN=System,<domainDN>, and for the container itself, reports every
    Allow ACE that grants write-type rights (GenericAll, GenericWrite, WriteProperty, CreateChild,
    DeleteChild, WriteDacl, WriteOwner), flagging:
      - OrphanedSid      : identity did not resolve (deleted account)
      - BroadGroup       : Domain Users / Authenticated Users / Everyone / Domain Computers with write
      - IndividualUser   : delegation to a user account instead of a group
      - InheritedWriter  : write right inherited from the container (affects every namespace)
      - DenyAce          : explicit Deny entries (often explain "delegated but denied")
    Optional -IncludeStandalone also inspects standalone namespaces on the given servers (registry ACL).
    Optional -CheckLocalAdmins lists local Administrators on each namespace (root target) server.

    Does NOT change anything. Does not audit Access-Based Enumeration folder ACLs (plane 2 -
    see Get-DFSABEAudit.ps1) or share/NTFS permissions.

.PARAMETER Domain
    DNS name of the domain to audit. Default: current user's domain.

.PARAMETER IncludeStandalone
    Array of server names hosting standalone namespaces to inspect via Invoke-Command.

.PARAMETER CheckLocalAdmins
    Query local Administrators membership on every root target server (requires WinRM).

.PARAMETER OutputPath
    Folder for the CSV report. Default: $env:TEMP.

.EXAMPLE
    .\Get-DFSNamespaceDelegationAudit.ps1
    Audit all domain-based namespaces in the current domain.

.EXAMPLE
    .\Get-DFSNamespaceDelegationAudit.ps1 -Domain contoso.com -CheckLocalAdmins -IncludeStandalone FS01,FS02
    Full audit including local admin membership and two standalone namespace servers.

.NOTES
    Requires: RSAT ActiveDirectory module; DFSN module for -CheckLocalAdmins root target discovery;
              WinRM to servers for -CheckLocalAdmins / -IncludeStandalone.
    Run as:   any domain user can read the AD ACLs; local admin queries need rights on the servers.
    Safety:   read-only.
#>
[CmdletBinding()]
param(
    [string]$Domain,
    [string[]]$IncludeStandalone,
    [switch]$CheckLocalAdmins,
    [string]$OutputPath = $env:TEMP
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$WriteRights = 'GenericAll|GenericWrite|WriteProperty|CreateChild|DeleteChild|WriteDacl|WriteOwner'
$BroadPattern = '\\(Domain Users|Domain Computers)$|^NT AUTHORITY\\Authenticated Users$|^Everyone$|^BUILTIN\\Users$'
$Tier0Pattern = '\\(Domain Admins|Enterprise Admins|Schema Admins)$|^NT AUTHORITY\\SYSTEM$|^BUILTIN\\Administrators$|^NT AUTHORITY\\ENTERPRISE DOMAIN CONTROLLERS$|\\Domain Controllers$|^CREATOR OWNER$'

$results = New-Object System.Collections.Generic.List[object]
function Add-Row {
    param([string]$Scope, [string]$Store, [string]$Identity, [string]$Rights, [string]$AceType, [bool]$Inherited, [string]$Finding, [string]$Status)
    $results.Add([pscustomobject]@{
        Scope = $Scope; Store = $Store; Identity = $Identity; Rights = $Rights; AceType = $AceType
        Inherited = $Inherited; Finding = $Finding; Status = $Status
    })
}

# ---------------- Preflight ----------------
try { Import-Module ActiveDirectory -ErrorAction Stop } catch { Write-Status "ActiveDirectory module not available: $($_.Exception.Message)" "ERROR"; return }
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
$adDomain = if ($Domain) { Get-ADDomain -Identity $Domain } else { Get-ADDomain }
$server = $adDomain.PDCEmulator
$cfgDn = "CN=Dfs-Configuration,CN=System,$($adDomain.DistinguishedName)"
Write-Status "Domain $($adDomain.DNSRoot); reading from PDC emulator $server"

# Make sure an AD: drive bound to this domain exists
$driveName = 'DFSNAUDIT'
if (-not (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue)) {
    New-PSDrive -Name $driveName -PSProvider ActiveDirectory -Root '//RootDSE/' -Server $server | Out-Null
}

function Get-UserClassMap {
    param([string[]]$Names)
    $map = @{}
    foreach ($n in $Names) {
        if ($n -notmatch '\\') { continue }
        $sam = ($n -split '\\', 2)[1]
        try {
            $o = Get-ADObject -Server $server -Filter "sAMAccountName -eq '$sam'" -Properties objectClass -ErrorAction Stop | Select-Object -First 1
            if ($o) { $map[$n] = [string]$o.ObjectClass }
        } catch { }
    }
    return $map
}

function Test-Acl {
    param([string]$Scope, [string]$Dn)
    try {
        $acl = Get-Acl -Path "$($driveName):\$Dn"
    } catch {
        Write-Status "Cannot read ACL for $Scope : $($_.Exception.Message)" "ERROR"
        Add-Row $Scope $Dn '' '' '' $false 'AclUnreadable' 'ERROR'
        return
    }
    $aces = @($acl.Access | Where-Object { ([string]$_.ActiveDirectoryRights) -match $WriteRights -or $_.AccessControlType -eq 'Deny' })
    $classMap = Get-UserClassMap -Names @($aces | ForEach-Object { [string]$_.IdentityReference.Value } | Select-Object -Unique)
    $writerCount = 0
    foreach ($a in $aces) {
        $id = [string]$a.IdentityReference.Value
        $rights = [string]$a.ActiveDirectoryRights
        $findings = @()
        if ($a.AccessControlType -eq 'Deny') { $findings += 'DenyAce' }
        else {
            if ($id -match '^S-1-5-21-') { $findings += 'OrphanedSid' }
            if ($id -match $BroadPattern) {
                # Authenticated Users normally only has read; any write here is a finding
                $findings += 'BroadGroup'
            }
            if ($classMap.ContainsKey($id) -and $classMap[$id] -eq 'user') { $findings += 'IndividualUser' }
            if ($a.IsInherited -and $id -notmatch $Tier0Pattern) { $findings += 'InheritedWriter' }
            if ($id -notmatch $Tier0Pattern) { $writerCount++ }
        }
        $status = if ($findings -contains 'OrphanedSid' -or $findings -contains 'BroadGroup') { 'ERROR' }
                  elseif ($findings.Count -gt 0) { 'WARN' }
                  elseif ($id -match $Tier0Pattern) { 'OK' }
                  else { 'INFO' }
        $finding = if ($findings.Count) { $findings -join ';' } elseif ($id -match $Tier0Pattern) { 'Tier0Default' } else { 'DelegatedWriter' }
        Add-Row $Scope $Dn $id $rights ([string]$a.AccessControlType) ([bool]$a.IsInherited) $finding $status
        if ($status -ne 'OK') { Write-Status "$Scope | $id | $rights | $finding" $status }
    }
    Write-Status "$Scope : $writerCount non-Tier-0 write ACE(s)" $(if ($writerCount) { 'INFO' } else { 'OK' })
}

# ---------------- Detect + audit domain namespaces ----------------
try {
    $null = Get-ADObject -Server $server -Identity $cfgDn
} catch {
    Write-Status "No Dfs-Configuration container found ($cfgDn) - no domain-based namespaces?" "WARN"
    $cfgDn = $null
}
$nsObjects = @()
if ($cfgDn) {
    Test-Acl -Scope 'CONTAINER Dfs-Configuration' -Dn $cfgDn
    $nsObjects = @(Get-ADObject -Server $server -SearchBase $cfgDn -SearchScope OneLevel -Filter "objectClass -eq 'msDFS-Namespacev2' -or objectClass -eq 'fTDfs'" -Properties objectClass)
    Write-Status "Found $($nsObjects.Count) domain-based namespace object(s)"
    foreach ($ns in $nsObjects) {
        $type = if ($ns.ObjectClass -eq 'fTDfs') { 'V1' } else { 'V2' }
        Test-Acl -Scope "NS \\$($adDomain.DNSRoot)\$($ns.Name) ($type)" -Dn $ns.DistinguishedName
        if ($type -eq 'V1') {
            Add-Row "NS \\$($adDomain.DNSRoot)\$($ns.Name) (V1)" $ns.DistinguishedName '' '' '' $false 'LegacyV1Namespace' 'WARN'
        }
    }
}

# ---------------- Standalone ----------------
foreach ($s in @($IncludeStandalone | Where-Object { $_ })) {
    try {
        $rows = Invoke-Command -ComputerName $s -ErrorAction Stop -ScriptBlock {
            $base = 'HKLM:\SOFTWARE\Microsoft\Dfs\Standalone'
            if (-not (Test-Path $base)) { return @() }
            foreach ($k in Get-ChildItem $base) {
                foreach ($a in (Get-Acl $k.PSPath).Access) {
                    [pscustomobject]@{ Root = $k.PSChildName; Identity = [string]$a.IdentityReference.Value
                        Rights = [string]$a.RegistryRights; AceType = [string]$a.AccessControlType; Inherited = [bool]$a.IsInherited }
                }
            }
        }
        if (@($rows).Count -eq 0) { Write-Status "$s : no standalone namespaces" "INFO" }
        foreach ($r in @($rows)) {
            if ($r.Rights -notmatch 'FullControl|SetValue|CreateSubKey|Delete|ChangePermissions|TakeOwnership|WriteKey') { continue }
            $f = if ($r.Identity -match '^S-1-5-21-') { 'OrphanedSid' } elseif ($r.Identity -match $BroadPattern) { 'BroadGroup' } elseif ($r.Identity -match $Tier0Pattern) { 'Tier0Default' } else { 'DelegatedWriter' }
            $st = switch ($f) { 'OrphanedSid' {'ERROR'} 'BroadGroup' {'ERROR'} 'Tier0Default' {'OK'} default {'INFO'} }
            Add-Row "SA \\$s\$($r.Root)" "HKLM\SOFTWARE\Microsoft\Dfs\Standalone\$($r.Root)" $r.Identity $r.Rights $r.AceType $r.Inherited $f $st
        }
    } catch {
        Write-Status "$s : standalone check failed - $($_.Exception.Message)" "ERROR"
        Add-Row "SA \\$s" '' '' '' '' $false 'Unreachable' 'ERROR'
    }
}

# ---------------- Local admins on root target servers ----------------
if ($CheckLocalAdmins -and $nsObjects.Count -gt 0) {
    try { Import-Module DFSN -ErrorAction Stop } catch { Write-Status "DFSN module not available; skipping local admin check" "WARN" }
    if (Get-Module DFSN) {
        $servers = New-Object System.Collections.Generic.HashSet[string]
        foreach ($ns in $nsObjects) {
            try {
                foreach ($t in Get-DfsnRootTarget -Path "\\$($adDomain.DNSRoot)\$($ns.Name)" -ErrorAction Stop) {
                    [void]$servers.Add((([string]$t.TargetPath) -split '\\')[2])
                }
            } catch { Write-Status "Root targets for $($ns.Name): $($_.Exception.Message)" "WARN" }
        }
        foreach ($srv in $servers) {
            try {
                $members = Invoke-Command -ComputerName $srv -ErrorAction Stop -ScriptBlock {
                    Get-LocalGroupMember -Group Administrators | ForEach-Object { [string]$_.Name }
                }
                foreach ($m in @($members)) {
                    $f = if ($m -match '^S-1-5-21-') { 'OrphanedSid' } elseif ($m -match $BroadPattern) { 'BroadGroup' } else { 'LocalAdmin' }
                    $st = if ($f -eq 'LocalAdmin') { 'INFO' } else { 'ERROR' }
                    Add-Row "SERVER $srv" 'Local Administrators' $m 'LocalAdmin' 'Allow' $false $f $st
                }
                Write-Status "$srv : $(@($members).Count) local admin member(s)" "INFO"
            } catch {
                Write-Status "$srv : local admin query failed - $($_.Exception.Message)" "WARN"
                Add-Row "SERVER $srv" 'Local Administrators' '' '' '' $false 'Unreachable' 'WARN'
            }
        }
    }
}

# ---------------- Report ----------------
Remove-PSDrive -Name $driveName -ErrorAction SilentlyContinue
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$csv = Join-Path $OutputPath "DFSNDelegationAudit_$($adDomain.DNSRoot)_$stamp.csv"
$results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
$errs = @($results | Where-Object Status -eq 'ERROR').Count
$warns = @($results | Where-Object Status -eq 'WARN').Count
Write-Status "Done. $($results.Count) row(s), $errs error(s), $warns warning(s). Report: $csv" $(if ($errs) { 'ERROR' } elseif ($warns) { 'WARN' } else { 'OK' })
