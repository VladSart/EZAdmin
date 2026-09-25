<#
.SYNOPSIS
    Read-only audit of RemoteApp programs published in RDS session collections.

.DESCRIPTION
    Companion to Windows/Troubleshooting/RemoteApp-A.md / -B.md.
    Collects, without changing anything:
      - Every RemoteApp in every session collection (or one named collection)
      - Per app, per session host: does the published FilePath (env vars expanded on the host)
        exist? Flags any (app, host) pair where it does not - the #1 cause of
        "not in the list of authorized programs" on some launches only
      - CommandLineSetting / RequiredCommandLine, flags Allow (security review) and
        Require-with-FTA (file path will be discarded)
      - IconPath presence, ShowInWebAccess, UserGroups (empty = all collection users)
      - FilePath pointing at per-user or mapped-drive locations
      - Published file-type associations per app and whether the collection allows drive
        redirection (FTAs need it)
      - Duplicate DisplayNames across collections (users see two icons, launch the wrong one)
    Does NOT: check RD Web visibility (use Get-RDWebAccessDiagnostics.ps1), host drain/LB
    (Get-RDSessionHostHealth.ps1), broker HA (Get-RDConnectionBrokerDiagnostics.ps1), GPO
    time limits (use gpresult), or launch the apps.

.PARAMETER ConnectionBroker
    FQDN of a Connection Broker (the active management server in HA). Default: local FQDN.

.PARAMETER CollectionName
    Limit to one session collection. Default: all session collections.

.PARAMETER SkipHostChecks
    Do not contact session hosts (no per-host path test). Useful when WinRM is blocked.

.PARAMETER OutputPath
    Folder for the CSV report. Default: C:\Temp.

.EXAMPLE
    .\Get-RemoteAppPublishingAudit.ps1 -ConnectionBroker rdcb01.contoso.com

.EXAMPLE
    .\Get-RemoteAppPublishingAudit.ps1 -CollectionName 'LOB Apps' -OutputPath D:\Reports

.NOTES
    Requires: Windows PowerShell 5.1, RemoteDesktop module, admin rights on the deployment,
    WinRM to each session host (unless -SkipHostChecks). Safe: read-only.
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$ConnectionBroker = ([System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName),
    [string]$CollectionName,
    [switch]$SkipHostChecks,
    [string]$OutputPath = 'C:\Temp'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    param([string]$Message, [string]$Status = 'INFO')
    $colour = switch ($Status) { 'OK' {'Green'} 'WARN' {'Yellow'} 'ERROR' {'Red'} default {'Cyan'} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Collection, [string]$Alias, [string]$Target, [string]$Check, [string]$Status, [string]$Detail)
    $results.Add([pscustomobject]@{
        Collection = $Collection; Alias = $Alias; Target = $Target
        Check = $Check; Status = $Status; Detail = $Detail
    })
    $label = if ($Alias) { "$Collection/$Alias" } else { $Collection }
    Write-Status -Message ("{0} [{1}] {2}: {3}" -f $label, $Target, $Check, $Detail) -Status $Status
}

# ---------------- Preflight ----------------
Write-Status "RemoteApp publishing audit - broker $ConnectionBroker"
try { Import-Module RemoteDesktop -ErrorAction Stop }
catch { Write-Status 'RemoteDesktop module not available - run on a Connection Broker or an RSAT-RDS machine.' 'ERROR'; throw }

if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

# ---------------- Detect ----------------
$collections = @(Get-RDSessionCollection -ConnectionBroker $ConnectionBroker)
if ($CollectionName) { $collections = @($collections | Where-Object { $_.CollectionName -eq $CollectionName }) }
if ($collections.Count -eq 0) { Write-Status 'No matching session collections found.' 'ERROR'; return }

$allApps = New-Object System.Collections.Generic.List[object]

foreach ($c in $collections) {
    $cn = [string]$c.CollectionName
    $apps = @()
    try { $apps = @(Get-RDRemoteApp -CollectionName $cn -ConnectionBroker $ConnectionBroker -ErrorAction Stop) }
    catch { Add-Result $cn '' 'Broker' 'Get-RDRemoteApp' 'ERROR' $_.Exception.Message; continue }

    if ($apps.Count -eq 0) { Add-Result $cn '' 'Broker' 'RemoteApps' 'INFO' 'No RemoteApps published (desktop collection)'; continue }
    Add-Result $cn '' 'Broker' 'RemoteApps' 'INFO' ("{0} RemoteApp(s) published" -f $apps.Count)

    # Collection client redirection (for FTAs)
    $driveRedirect = $null
    try {
        $clientCfg = Get-RDSessionCollectionConfiguration -CollectionName $cn -ConnectionBroker $ConnectionBroker -Client
        $opts = [string](Get-Prop $clientCfg 'ClientDeviceRedirectionOptions')
        $driveRedirect = ($opts -match 'Drive')
        Add-Result $cn '' 'Broker' 'DriveRedirection' 'INFO' ("ClientDeviceRedirectionOptions = {0}" -f $opts)
    } catch { Add-Result $cn '' 'Broker' 'DriveRedirection' 'WARN' ("Could not read client config: {0}" -f $_.Exception.Message) }

    $hosts = @()
    try { $hosts = @(Get-RDSessionHost -CollectionName $cn -ConnectionBroker $ConnectionBroker | ForEach-Object { [string]$_.SessionHost }) }
    catch { Add-Result $cn '' 'Broker' 'Get-RDSessionHost' 'ERROR' $_.Exception.Message }

    foreach ($a in $apps) {
        $alias    = [string](Get-Prop $a 'Alias')
        $display  = [string](Get-Prop $a 'DisplayName')
        $path     = [string](Get-Prop $a 'FilePath')
        $cls      = [string](Get-Prop $a 'CommandLineSetting')
        $reqCl    = [string](Get-Prop $a 'RequiredCommandLine')
        $iconPath = [string](Get-Prop $a 'IconPath')
        $showWeb  = Get-Prop $a 'ShowInWebAccess'
        $groups   = @(Get-Prop $a 'UserGroups') | Where-Object { $_ }
        $allApps.Add([pscustomobject]@{ Collection = $cn; Alias = $alias; DisplayName = $display })

        # Path sanity
        if ([string]::IsNullOrWhiteSpace($path)) { Add-Result $cn $alias 'Broker' 'FilePath' 'ERROR' 'FilePath is empty' }
        elseif ($path -match '%(LOCALAPPDATA|APPDATA|USERPROFILE)%' -or $path -match '\\Users\\') {
            Add-Result $cn $alias 'Broker' 'FilePath' 'WARN' ("Per-user location: {0} - will differ per user/host" -f $path)
        }
        elseif ($path -match '^[A-Za-z]:\\' -and $path -notmatch '^[Cc]:\\') {
            Add-Result $cn $alias 'Broker' 'FilePath' 'INFO' ("Non-system drive path {0} - confirm drive letter exists on every host (not a mapped drive)" -f $path)
        }
        elseif ($path -match '^\\\\') {
            Add-Result $cn $alias 'Broker' 'FilePath' 'WARN' ("UNC path {0} - launch depends on share availability and user rights" -f $path)
        }
        else { Add-Result $cn $alias 'Broker' 'FilePath' 'OK' $path }

        # Command-line policy
        switch -Regex ($cls) {
            '^Allow$'     { Add-Result $cn $alias 'Broker' 'CommandLine' 'INFO' 'Allow - client arguments passed to the exe (review for admin/script-capable apps)' }
            '^Require$'   { Add-Result $cn $alias 'Broker' 'CommandLine' 'INFO' ("Require - fixed args: {0}" -f $reqCl) }
            '^DoNotAllow$'{ Add-Result $cn $alias 'Broker' 'CommandLine' 'OK' 'DoNotAllow' }
            default       { Add-Result $cn $alias 'Broker' 'CommandLine' 'INFO' ("CommandLineSetting = '{0}'" -f $cls) }
        }

        # Visibility / icon
        if ($showWeb -eq $false) { Add-Result $cn $alias 'Broker' 'ShowInWebAccess' 'WARN' 'Hidden from RD Web/feed - only reachable via distributed .rdp' }
        if (@($groups).Count -eq 0) { Add-Result $cn $alias 'Broker' 'UserGroups' 'INFO' 'Empty - visible to all collection users' }
        else { Add-Result $cn $alias 'Broker' 'UserGroups' 'INFO' ($groups -join '; ') }
        if ([string]::IsNullOrWhiteSpace($iconPath)) { Add-Result $cn $alias 'Broker' 'Icon' 'WARN' 'No IconPath - generic icon likely' }

        # FTAs
        try {
            $ftas = @(Get-RDFileTypeAssociation -CollectionName $cn -AppAlias $alias -ConnectionBroker $ConnectionBroker -ErrorAction Stop)
            $published = @($ftas | Where-Object { (Get-Prop $_ 'IsPublished') -eq $true } | ForEach-Object { [string](Get-Prop $_ 'FileExtension') })
            if ($published.Count -gt 0) {
                Add-Result $cn $alias 'Broker' 'FTA' 'INFO' ("Published: {0}" -f ($published -join ', '))
                if ($cls -ne 'Allow') { Add-Result $cn $alias 'Broker' 'FTA' 'WARN' ("FTAs published but CommandLineSetting = {0} - the file path will not reach the app" -f $cls) }
                if ($driveRedirect -eq $false) { Add-Result $cn $alias 'Broker' 'FTA' 'WARN' 'FTAs published but collection does not redirect drives - local files cannot be opened' }
            }
        } catch { Add-Result $cn $alias 'Broker' 'FTA' 'INFO' ("Could not read FTAs: {0}" -f $_.Exception.Message) }

        # Per-host path existence
        if (-not $SkipHostChecks -and -not [string]::IsNullOrWhiteSpace($path)) {
            foreach ($h in $hosts) {
                try {
                    $r = Invoke-Command -ComputerName $h -ArgumentList $path -ErrorAction Stop -ScriptBlock {
                        param($p)
                        $e = [Environment]::ExpandEnvironmentVariables($p)
                        [pscustomobject]@{ Expanded = $e; Exists = (Test-Path -LiteralPath $e -PathType Leaf) }
                    }
                    if ($r.Exists) { Add-Result $cn $alias $h 'PathOnHost' 'OK' $r.Expanded }
                    else { Add-Result $cn $alias $h 'PathOnHost' 'ERROR' ("MISSING: {0} - users routed here cannot launch this app" -f $r.Expanded) }
                } catch { Add-Result $cn $alias $h 'PathOnHost' 'WARN' ("Host check failed (WinRM?): {0}" -f $_.Exception.Message) }
            }
        }
    }
}

# ---------------- Cross-collection checks ----------------
$dupes = $allApps | Group-Object DisplayName | Where-Object { $_.Count -gt 1 }
foreach ($d in $dupes) {
    $where = ($d.Group | ForEach-Object { "{0}/{1}" -f $_.Collection, $_.Alias }) -join ', '
    Add-Result 'ALL' '' 'Broker' 'DuplicateDisplayName' 'WARN' ("'{0}' published {1} times: {2}" -f $d.Name, $d.Count, $where)
}

# ---------------- Report ----------------
$csv = Join-Path $OutputPath ("RemoteAppAudit_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
$err  = @($results | Where-Object { $_.Status -eq 'ERROR' }).Count
$warn = @($results | Where-Object { $_.Status -eq 'WARN' }).Count
Write-Status ("Done. {0} checks, {1} ERROR, {2} WARN. Report: {3}" -f $results.Count, $err, $warn, $csv) $(if ($err) {'ERROR'} elseif ($warn) {'WARN'} else {'OK'})
