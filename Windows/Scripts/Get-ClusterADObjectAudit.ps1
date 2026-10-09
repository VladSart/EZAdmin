<#
.SYNOPSIS
    Read-only audit of a failover cluster's Active Directory objects (CNO and VCOs), OU delegation, and DNS status.

.DESCRIPTION
    For the target cluster this script:
      - Reports the administrative access point type (AD-detached clusters have no CNO).
      - Enumerates every Network Name resource and its private properties (DnsName, ObjectGUID,
        StatusDNS, StatusKerberos, StatusNetBIOS).
      - Looks up the matching AD computer object and flags: missing, disabled, ObjectGUID mismatch
        (object recreated instead of restored), stale PasswordLastSet, not protected from accidental deletion.
      - Checks whether the CNO holds Create Computer objects (CreateChild on computer class or all classes)
        on its own OU, either directly or through a group it is a member of.
      - Checks whether the CNO holds GenericAll / WriteProperty-level rights on each VCO.
      - Pulls recent network-name related events (1069, 1194, 1196, 1205, 1206, 1207, 1211, 1212, 1218, 1219, 1257).
    It does NOT change anything, does not run Repair Active Directory Object, and does not inspect DNS record ACLs
    (that needs DNS server access - see ClusterADObjects-A.md Playbook 5).

.PARAMETER ClusterName
    Cluster to audit. Defaults to the local cluster.

.PARAMETER PasswordAgeWarnDays
    Flag objects whose PasswordLastSet is older than this. Default 45 (machine password default age is 30).

.PARAMETER EventDays
    How many days of System log events to collect from each node. Default 7.

.PARAMETER OutputPath
    Folder for CSV output. Default C:\Temp.

.EXAMPLE
    .\Get-ClusterADObjectAudit.ps1
    Audits the local cluster and writes CSVs to C:\Temp.

.EXAMPLE
    .\Get-ClusterADObjectAudit.ps1 -ClusterName SQLCLU01 -EventDays 14 -OutputPath D:\Evidence

.NOTES
    Requires: FailoverClusters and ActiveDirectory (RSAT) PowerShell modules; Windows PowerShell 5.1 or PowerShell 7.
    Run as: domain user with local admin on the cluster nodes (for events). No AD write rights needed.
    Safe: read-only.
#>
[CmdletBinding()]
param(
    [string]$ClusterName = '.',
    [int]$PasswordAgeWarnDays = 45,
    [int]$EventDays = 7,
    [string]$OutputPath = 'C:\Temp'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    param([string]$Message, [string]$Status = 'INFO')
    $colour = switch ($Status) { 'OK' {'Green'} 'WARN' {'Yellow'} 'ERROR' {'Red'} default {'Cyan'} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-ParamValue {
    param($Params, [string]$Name)
    $hit = @($Params | Where-Object { $_.Name -eq $Name })
    if ($hit.Count -gt 0) { return $hit[0].Value }
    return $null
}

# ---------------- Preflight ----------------
foreach ($m in 'FailoverClusters', 'ActiveDirectory') {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        Write-Status "Module $m not available. Install RSAT ($m) and rerun." 'ERROR'
        return
    }
    Import-Module $m -ErrorAction Stop
}
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd_HHmm'

$cluster = Get-Cluster -Name $ClusterName
Write-Status "Cluster: $($cluster.Name)  Domain: $($cluster.Domain)"

$aap = $null
if ($cluster.PSObject.Properties.Name -contains 'AdministrativeAccessPoint') { $aap = [string]$cluster.AdministrativeAccessPoint }
if ($aap -and $aap -ne 'ActiveDirectoryAndDns') {
    Write-Status "AdministrativeAccessPoint = $aap - cluster has no AD-backed CNO by design. VCO checks may still apply." 'WARN'
}

$computerClassGuid = [Guid]'bf967a86-0de6-11d0-a285-00aa003049e2'
$allGuid           = [Guid]::Empty

# ---------------- Detect: CNO ----------------
$cno = $null
try {
    $cno = Get-ADComputer -Identity $cluster.Name -Properties Enabled, DistinguishedName, ObjectGUID, PasswordLastSet, ProtectedFromAccidentalDeletion, SID
    Write-Status "CNO found: $($cno.DistinguishedName)" 'OK'
} catch {
    Write-Status "CNO '$($cluster.Name)' not found in AD: $($_.Exception.Message)" 'ERROR'
}

$cnoSids = @()
$cnoCanCreate = $null
$cnoOu = $null
if ($cno) {
    $cnoSids += $cno.SID.Value
    try {
        $cnoSids += @(Get-ADPrincipalGroupMembership -Identity $cno | ForEach-Object { $_.SID.Value })
    } catch {
        Write-Status "Could not enumerate CNO group membership: $($_.Exception.Message)" 'WARN'
    }
    $cnoOu = ($cno.DistinguishedName -split ',', 2)[1]
    try {
        $acl = Get-Acl -Path ("AD:\" + $cnoOu)
        $cnoCanCreate = $false
        foreach ($ace in $acl.Access) {
            if ($ace.AccessControlType -ne 'Allow') { continue }
            $sid = $null
            try { $sid = $ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { continue }
            if ($cnoSids -notcontains $sid) { continue }
            $rights = [string]$ace.ActiveDirectoryRights
            $isCreate = ($rights -match 'CreateChild' -and ($ace.ObjectType -eq $computerClassGuid -or $ace.ObjectType -eq $allGuid)) -or ($rights -match 'GenericAll')
            if ($isCreate) { $cnoCanCreate = $true }
        }
        if ($cnoCanCreate) { Write-Status "CNO can create computer objects in $cnoOu" 'OK' }
        else { Write-Status "CNO has NO Create Computer objects right on $cnoOu (new roles/listeners will hit Event 1194 unless VCOs are prestaged)" 'WARN' }
    } catch {
        Write-Status "Could not read ACL on ${cnoOu}: $($_.Exception.Message)" 'WARN'
    }
}

# ---------------- Detect: network names ----------------
$results = New-Object System.Collections.Generic.List[object]
$netNames = @(Get-ClusterResource -Cluster $cluster.Name | Where-Object { $_.ResourceType.Name -in 'Network Name', 'Distributed Network Name' })
Write-Status "Network name resources: $($netNames.Count)"

foreach ($r in $netNames) {
    $p = @($r | Get-ClusterParameter)
    $dnsName = [string](Get-ParamValue $p 'DnsName')
    if (-not $dnsName) { $dnsName = [string](Get-ParamValue $p 'Name') }
    $resGuid = [string](Get-ParamValue $p 'ObjectGUID')
    $issues = New-Object System.Collections.Generic.List[string]

    $ad = $null
    if ($dnsName) {
        try {
            $ad = Get-ADComputer -Identity $dnsName -Properties Enabled, DistinguishedName, ObjectGUID, PasswordLastSet, ProtectedFromAccidentalDeletion, nTSecurityDescriptor
        } catch { $issues.Add('AD object not found') }
    }

    $guidMatch = $null; $enabled = $null; $pwdAge = $null; $protected = $null; $dn = $null; $cnoHasRights = $null
    if ($ad) {
        $dn = $ad.DistinguishedName
        $enabled = $ad.Enabled
        $protected = $ad.ProtectedFromAccidentalDeletion
        if (-not $enabled) { $issues.Add('AD object disabled') }
        if (-not $protected) { $issues.Add('not protected from accidental deletion') }
        if ($ad.PasswordLastSet) {
            $pwdAge = [int]((Get-Date) - $ad.PasswordLastSet).TotalDays
            if ($pwdAge -gt $PasswordAgeWarnDays) { $issues.Add("password age $pwdAge days") }
        }
        if ($resGuid) {
            $clean = $resGuid -replace '[{}-]', ''
            $adClean = $ad.ObjectGUID.ToString('N')
            $guidMatch = ($clean -ieq $adClean)
            if (-not $guidMatch) { $issues.Add('ObjectGUID mismatch (object recreated?)') }
        }
        if ($cno -and $ad.ObjectGUID -ne $cno.ObjectGUID) {
            $cnoHasRights = $false
            foreach ($ace in $ad.nTSecurityDescriptor.Access) {
                if ($ace.AccessControlType -ne 'Allow') { continue }
                $sid = $null
                try { $sid = $ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { continue }
                if ($cnoSids -contains $sid -and ([string]$ace.ActiveDirectoryRights -match 'GenericAll|WriteProperty')) { $cnoHasRights = $true }
            }
            if (-not $cnoHasRights) { $issues.Add('CNO lacks Full Control/Write on VCO') }
        }
    }

    foreach ($s in 'StatusDNS', 'StatusKerberos', 'StatusNetBIOS') {
        $v = Get-ParamValue $p $s
        if ($null -ne $v -and [string]$v -ne '0') { $issues.Add("$s=$v") }
    }
    if ([string]$r.State -ne 'Online') { $issues.Add("resource state $($r.State)") }

    $isCno = ($cno -and $ad -and $ad.ObjectGUID -eq $cno.ObjectGUID)
    $results.Add([pscustomobject]@{
        Resource          = $r.Name
        Type              = $r.ResourceType.Name
        Role              = [string]$r.OwnerGroup
        State             = [string]$r.State
        DnsName           = $dnsName
        IsCNO             = [bool]$isCno
        ADDistinguishedName = $dn
        Enabled           = $enabled
        GuidMatch         = $guidMatch
        PasswordAgeDays   = $pwdAge
        Protected         = $protected
        CnoHasRightsOnVCO = $cnoHasRights
        StatusDNS         = Get-ParamValue $p 'StatusDNS'
        StatusKerberos    = Get-ParamValue $p 'StatusKerberos'
        CnoCanCreateComputers = $cnoCanCreate
        Issues            = ($issues -join '; ')
    })
}

# ---------------- Detect: events ----------------
$eventIds = 1069, 1194, 1196, 1205, 1206, 1207, 1211, 1212, 1218, 1219, 1257
$events = New-Object System.Collections.Generic.List[object]
foreach ($node in @(Get-ClusterNode -Cluster $cluster.Name)) {
    try {
        $ev = @(Get-WinEvent -ComputerName $node.Name -FilterHashtable @{
                LogName = 'System'; ProviderName = 'Microsoft-Windows-FailoverClustering'
                Id = $eventIds; StartTime = (Get-Date).AddDays(-$EventDays) } -ErrorAction Stop)
        foreach ($e in $ev) {
            $events.Add([pscustomobject]@{ Node = $node.Name; TimeCreated = $e.TimeCreated; Id = $e.Id
                Message = ($e.Message -replace '\s+', ' ') })
        }
    } catch {
        if ($_.Exception.Message -notmatch 'No events were found') {
            Write-Status "Events from $($node.Name): $($_.Exception.Message)" 'WARN'
        }
    }
}

# ---------------- Report ----------------
$resCsv = Join-Path $OutputPath "ClusterADObjects_$($cluster.Name)_$stamp.csv"
$evCsv  = Join-Path $OutputPath "ClusterADEvents_$($cluster.Name)_$stamp.csv"
$results | Export-Csv -Path $resCsv -NoTypeInformation
$events  | Export-Csv -Path $evCsv -NoTypeInformation

$results | Format-Table Resource, DnsName, IsCNO, State, Enabled, GuidMatch, Issues -AutoSize -Wrap
$bad = @($results | Where-Object { $_.Issues })
if ($bad.Count -eq 0 -and $cnoCanCreate -ne $false) { Write-Status 'No CNO/VCO issues detected.' 'OK' }
else { Write-Status "$($bad.Count) name resource(s) with issues - see ClusterADObjects-B.md triage table." 'WARN' }
if ($events.Count -gt 0) {
    Write-Status "$($events.Count) network-name event(s) in last $EventDays day(s):" 'WARN'
    $events | Group-Object Id | Sort-Object Name | ForEach-Object { Write-Host ("   Event {0}: {1}" -f $_.Name, $_.Count) }
}
Write-Status "Results: $resCsv"
Write-Status "Events:  $evCsv"
