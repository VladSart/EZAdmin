<#
.SYNOPSIS
    Audits Entra tenant restrictions v2 (TRv2) cloud policy and, optionally, the local Windows client signal.

.DESCRIPTION
    Read-only. Two sections:

    1. Cloud (Graph): reads /policies/crossTenantAccessPolicy/default and /partners (beta, matching
       Microsoft's TRv2 documentation), reports whether a TRv2 default policy exists, its policy ID
       (the value that must appear in every client signal), the default Users/Apps access types, and
       every partner entry that overrides tenant restrictions — flagging over-broad allows
       (AllUsers + AllApplications) and the Microsoft account (MSA) tenant entry.

    2. Local (optional, -IncludeLocalDevice, Windows only): reads the ADMX-backed client payload at
       HKLM:\SOFTWARE\Policies\Microsoft\Windows\TenantRestrictions\Payload, checks whether the cloud
       tenant ID and default policy ID appear in it, counts recent TenantRestrictions/Operational
       events, and reports the WinHTTP proxy.

    It does NOT change any policy, cannot see proxy header injection, and cannot evaluate Global
    Secure Access universal tenant restrictions. Registry value NAMES under Payload aren't documented
    by Microsoft, so the script matches IDs across all values rather than assuming names.

.PARAMETER IncludeLocalDevice
    Also run the local Windows client checks on this machine.

.PARAMETER SkipGraph
    Skip the Graph section (local-only run; implies -IncludeLocalDevice).

.PARAMETER ExportPath
    CSV path. Default: $env:TEMP\TRv2-Audit-<yyyyMMdd-HHmm>.csv

.EXAMPLE
    Connect-MgGraph -Scopes Policy.Read.All
    .\Get-TenantRestrictionsV2Audit.ps1 -IncludeLocalDevice

.EXAMPLE
    .\Get-TenantRestrictionsV2Audit.ps1 -SkipGraph
    Local client check only (e.g. via RMM on an affected device).

.NOTES
    Requires Microsoft.Graph.Authentication (Invoke-MgGraphRequest) and an existing Connect-MgGraph
    session with Policy.Read.All for the Graph section. The script does not call Connect-MgGraph.
    Local section reads HKLM and event logs; run elevated for complete event log access.
    Safe: read-only.
#>
[CmdletBinding()]
param(
    [switch]$IncludeLocalDevice,
    [switch]$SkipGraph,
    [string]$ExportPath = (Join-Path $env:TEMP ("TRv2-Audit-{0:yyyyMMdd-HHmm}.csv" -f (Get-Date)))
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-Prop {
    # StrictMode-safe property read for hashtables / PSObjects returned by Invoke-MgGraphRequest
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] } else { return $null }
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value } else { return $null }
}

function Get-TargetSummary {
    param($Block)
    if ($null -eq $Block) { return @{ Access = ''; Targets = '' } }
    $access  = Get-Prop $Block 'accessType'
    $targets = @(Get-Prop $Block 'targets') | Where-Object { $_ } | ForEach-Object { Get-Prop $_ 'target' }
    return @{ Access = [string]$access; Targets = ($targets -join ';') }
}

$MsaTenantId = '9188040d-6c67-4c5b-b112-36a304b66dad'
$results = [System.Collections.Generic.List[object]]::new()
$tenantId = $null; $defaultPolicyId = $null

if ($SkipGraph) { $IncludeLocalDevice = $true }

# ---------------- Preflight ----------------
if (-not $SkipGraph) {
    if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
        Write-Status "Microsoft.Graph.Authentication not available. Install-Module Microsoft.Graph.Authentication, or use -SkipGraph." "ERROR"; return
    }
    $ctx = Get-MgContext
    if (-not $ctx) { Write-Status "No Graph session. Run: Connect-MgGraph -Scopes Policy.Read.All" "ERROR"; return }
    $tenantId = $ctx.TenantId
    Write-Status "Graph connected to tenant $tenantId as $($ctx.Account)"
}

# ---------------- Cloud policy ----------------
if (-not $SkipGraph) {
    try {
        $default = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/default'
    } catch {
        Write-Status "Failed to read default cross-tenant policy: $($_.Exception.Message)" "ERROR"; return
    }
    $defaultPolicyId = Get-Prop $default 'id'
    $tr = Get-Prop $default 'tenantRestrictions'
    $ug = Get-TargetSummary (Get-Prop $tr 'usersAndGroups')
    $ap = Get-TargetSummary (Get-Prop $tr 'applications')

    if (-not $tr -or (-not $ug.Access -and -not $ap.Access)) {
        Write-Status "No TRv2 default policy configured (tenantRestrictions empty). Create it under Cross-tenant access settings > Default settings." "WARN"
        $defFinding = 'NoDefaultPolicy'
    } else {
        Write-Status ("Default TRv2: users/groups={0} apps={1} ({2})" -f $ug.Access, $ap.Access, $ap.Targets) "OK"
        $defFinding = if ($ug.Access -eq 'allowed' -and $ap.Access -eq 'allowed') { 'DefaultAllowsEverything' } else { 'OK' }
        if ($defFinding -ne 'OK') { Write-Status "Default allows all external identities to all external apps — TRv2 has no effect unless partners block." "WARN" }
    }
    Write-Status "Signal value to deploy: sec-Restrict-Tenant-Access-Policy: ${tenantId}:$defaultPolicyId"

    $results.Add([pscustomobject]@{
        Section='Cloud'; Item='Default'; TenantId=$tenantId; PolicyId=$defaultPolicyId
        UsersAccess=$ug.Access; UsersTargets=$ug.Targets; AppsAccess=$ap.Access; AppsTargets=$ap.Targets; Finding=$defFinding })

    try {
        $partners = @()
        $uri = 'https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners'
        while ($uri) {
            $page = Invoke-MgGraphRequest -Method GET -Uri $uri
            $partners += @(Get-Prop $page 'value')
            $uri = Get-Prop $page '@odata.nextLink'
        }
    } catch {
        Write-Status "Failed to read partner policies: $($_.Exception.Message)" "ERROR"; $partners = @()
    }

    $trPartners = @($partners | Where-Object { $_ -and (Get-Prop $_ 'tenantRestrictions') })
    Write-Status ("{0} partner entr(y/ies) total; {1} override tenant restrictions" -f $partners.Count, $trPartners.Count)
    foreach ($p in $trPartners) {
        $ptr = Get-Prop $p 'tenantRestrictions'
        $pug = Get-TargetSummary (Get-Prop $ptr 'usersAndGroups')
        $pap = Get-TargetSummary (Get-Prop $ptr 'applications')
        $ptid = Get-Prop $p 'tenantId'
        $finding = 'OK'
        if ($pug.Access -eq 'allowed' -and $pug.Targets -match 'AllUsers' -and $pap.Access -eq 'allowed' -and $pap.Targets -match 'AllApplications') {
            $finding = 'BroadAllow-AllUsersAllApps'
        }
        if ($ptid -eq $MsaTenantId) { $finding = "MSA-Tenant;$finding" }
        $status = if ($finding -match 'BroadAllow') { 'WARN' } else { 'INFO' }
        Write-Status ("Partner {0}: users={1}[{2}] apps={3}[{4}] -> {5}" -f $ptid, $pug.Access, $pug.Targets, $pap.Access, $pap.Targets, $finding) $status
        $results.Add([pscustomobject]@{
            Section='Cloud'; Item='Partner'; TenantId=$ptid; PolicyId=$defaultPolicyId
            UsersAccess=$pug.Access; UsersTargets=$pug.Targets; AppsAccess=$pap.Access; AppsTargets=$pap.Targets; Finding=$finding })
    }
}

# ---------------- Local Windows client ----------------
if ($IncludeLocalDevice) {
    if ($env:OS -ne 'Windows_NT') {
        Write-Status "Local checks require Windows." "WARN"
    } else {
        $os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $build = "{0}.{1}" -f $os.CurrentBuild, $os.UBR
        Write-Status "Local OS build $build"

        $payloadPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\TenantRestrictions\Payload'
        $payloadText = ''
        $payloadFinding = 'NoPayload'
        if (Test-Path $payloadPath) {
            $item = Get-ItemProperty $payloadPath
            $vals = $item.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }
            $payloadText = ($vals | ForEach-Object { "{0}={1}" -f $_.Name, $_.Value }) -join ' | '
            $payloadFinding = 'PayloadPresent'
            if ($tenantId -and $defaultPolicyId) {
                $hasT = $payloadText -match [regex]::Escape($tenantId)
                $hasP = $payloadText -match [regex]::Escape($defaultPolicyId)
                $payloadFinding = if ($hasT -and $hasP) { 'MatchesCloud' } elseif ($hasT) { 'TenantMatch-PolicyIdMismatch' } else { 'IdsDoNotMatchCloud' }
            }
            $st = if ($payloadFinding -in 'MatchesCloud','PayloadPresent') { 'OK' } else { 'WARN' }
            Write-Status "Client payload: $payloadFinding ($payloadText)" $st
        } else {
            Write-Status "No TRv2 client payload (GPO/CSP 'Cloud Policy Details' not applied)." "WARN"
        }

        $evtCount = 0; $lastEvt = ''
        try {
            $ev = @(Get-WinEvent -LogName 'Microsoft-Windows-TenantRestrictions/Operational' -MaxEvents 200 -ErrorAction Stop)
            $evtCount = $ev.Count
            if ($evtCount -gt 0) { $lastEvt = $ev[0].TimeCreated.ToString('s') }
            Write-Status "TenantRestrictions/Operational: $evtCount recent event(s), newest $lastEvt"
        } catch {
            Write-Status "TenantRestrictions/Operational log unavailable or empty: $($_.Exception.Message)" "WARN"
        }

        $proxy = (netsh winhttp show proxy | Out-String).Trim() -replace '\s+', ' '
        $results.Add([pscustomobject]@{
            Section='Local'; Item=$env:COMPUTERNAME; TenantId=$tenantId; PolicyId=$defaultPolicyId
            UsersAccess=''; UsersTargets="Build $build; Events=$evtCount; Newest=$lastEvt"
            AppsAccess=''; AppsTargets="Payload: $payloadText; WinHTTP: $proxy"; Finding=$payloadFinding })
    }
}

# ---------------- Report ----------------
if ($results.Count -gt 0) {
    $results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
    Write-Status "Exported $($results.Count) row(s) to $ExportPath" "OK"
    $results | Format-Table Section, Item, UsersAccess, AppsAccess, Finding -AutoSize
} else {
    Write-Status "Nothing to report." "WARN"
}
