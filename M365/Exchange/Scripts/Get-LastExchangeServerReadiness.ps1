<#
.SYNOPSIS
    Read-only readiness check before shutting down the last on-prem Exchange server and moving to Management Tools only.

.DESCRIPTION
    Run in the Exchange Management Shell on the last Exchange server while it is still running.
    Checks Microsoft's published eligibility criteria plus common hidden dependencies and flags:
      - MULTIPLE_EXCHANGE_SERVERS : more than one Exchange server in the org (HIGH)
      - ONPREM_MAILBOXES          : user/shared/room/equipment/linked mailboxes still on-prem (HIGH)
      - BUILTIN_ADMIN_MAILBOX     : likely built-in admin mailbox (disable before proceeding) (MEDIUM)
      - PUBLIC_FOLDER_MAILBOXES   : on-prem public folder mailboxes (HIGH)
      - SMTP_RELAY_TRAFFIC        : SMTP receives from non-EXO client IPs in message tracking (HIGH)
      - CUSTOM_RECEIVE_CONNECTOR  : non-default receive connectors exist (review) (MEDIUM)
      - NO_TARGET_DELIVERY_DOMAIN : no remote domain *.mail.onmicrosoft.com with TargetDeliveryDomain (MEDIUM)
      - MX_NOT_EXO                : accepted-domain MX not pointing at *.mail.protection.outlook.com (HIGH)
      - AUTODISCOVER_SCP_SET      : AutoDiscoverServiceInternalUri populated (clear before shutdown) (MEDIUM)
      - SCRIPTING_AGENT_ENABLED   : copy ScriptingAgentConfig.xml to the tools box (LOW)
      - SCHEMA_BELOW_CU12         : ms-Exch-Schema-Version-Pt rangeUpper < 17003 (tools install will extend schema) (LOW)
      - FEDERATION_TRUST_PRESENT  : remove as part of permanent shutdown (INFO)
      - HYBRID_CONFIG_PRESENT     : run hybrid cleanup before permanent shutdown (INFO)
      - EMT_GROUP_MISSING         : 'Recipient Management EMT' group not created yet (INFO)

    Does NOT change anything. Does not run CleanupActiveDirectoryEMT.ps1, does not check EXO side.

.PARAMETER TrackingDays
    Days of message tracking logs to scan for relay traffic. Default 7.

.PARAMETER SkipMessageTracking
    Skip the relay scan (large orgs / no tracking logs).

.PARAMETER SkipDns
    Skip MX lookups (no external DNS from the server).

.PARAMETER OutputPath
    Folder for the CSV report. Default: $env:TEMP

.EXAMPLE
    .\Get-LastExchangeServerReadiness.ps1 -TrackingDays 14

.NOTES
    Requires: Exchange Management Shell (Exchange 2016/2019/SE) on the last server; ActiveDirectory module optional (schema/group checks).
    Run as: Organization Management (read) + Domain User. Safe: read-only.
    The EXO IP heuristic treats ClientIp in 40.92.0.0/15, 40.107.0.0/16, 52.100.0.0/14, 104.47.0.0/17 as Exchange Online; anything else is reported.
#>
[CmdletBinding()]
param(
    [ValidateRange(1,30)][int]$TrackingDays = 7,
    [switch]$SkipMessageTracking,
    [switch]$SkipDns,
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

function Test-ExoIp {
    param([string]$Ip)
    $prefixes = @('40.92.','40.93.','40.107.','52.100.','52.101.','52.102.','52.103.')
    foreach ($p in $prefixes) { if ($Ip.StartsWith($p)) { return $true } }
    if ($Ip -match '^104\.47\.(\d+)\.' -and [int]$Matches[1] -le 127) { return $true }
    return $false
}

# ---------- Preflight ----------
if (-not (Get-Command Get-ExchangeServer -ErrorAction SilentlyContinue)) {
    throw "Exchange cmdlets not loaded. Run this in the Exchange Management Shell on the last Exchange server."
}
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
Set-AdServerSettings -ViewEntireForest $true
$haveAd = [bool](Get-Module -ListAvailable -Name ActiveDirectory)
if ($haveAd) { Import-Module ActiveDirectory }

# ---------- Servers ----------
$servers = @(Get-ExchangeServer)
Write-Status "Exchange servers: $($servers.Count) ($(($servers | ForEach-Object { "$($_.Name) $($_.AdminDisplayVersion)" }) -join '; '))"
if ($servers.Count -gt 1) { Add-Finding 'MULTIPLE_EXCHANGE_SERVERS' 'HIGH' 'Org' "$($servers.Count) servers - decommission all but one first" }

# ---------- Mailboxes ----------
$mbx = @(Get-Mailbox -ResultSize Unlimited -ErrorAction SilentlyContinue)
$userTypes = 'UserMailbox','SharedMailbox','RoomMailbox','EquipmentMailbox','LinkedMailbox','SchedulingMailbox'
$real = @($mbx | Where-Object { $userTypes -contains [string]$_.RecipientTypeDetails })
foreach ($m in $real) {
    if ([string]$m.Name -match '^(Administrator|Admin)$' -or [string]$m.SamAccountName -eq 'Administrator') {
        Add-Finding 'BUILTIN_ADMIN_MAILBOX' 'MEDIUM' $m.PrimarySmtpAddress 'Built-in admin mailbox - not synced; Disable-Mailbox before proceeding'
    } else {
        Add-Finding 'ONPREM_MAILBOXES' 'HIGH' $m.PrimarySmtpAddress "Type=$($m.RecipientTypeDetails) DB=$($m.Database)"
    }
}
Write-Status "On-prem user-type mailboxes: $($real.Count)" $(if ($real.Count -eq 0) { 'OK' } else { 'WARN' })

try {
    $pf = @(Get-Mailbox -PublicFolder -ResultSize Unlimited -ErrorAction Stop)
    if ($pf.Count -gt 0) { Add-Finding 'PUBLIC_FOLDER_MAILBOXES' 'HIGH' 'Org' "$($pf.Count) PF mailbox(es) on-prem" }
    Write-Status "Public folder mailboxes: $($pf.Count)" $(if ($pf.Count -eq 0) { 'OK' } else { 'WARN' })
} catch { Write-Status "PF mailbox query failed: $($_.Exception.Message)" "WARN" }

# ---------- Receive connectors ----------
$defaultRx = '^(Default|Client Proxy|Client Frontend|Outbound Proxy Frontend)'
foreach ($rc in @(Get-ReceiveConnector)) {
    if ([string]$rc.Name -notmatch $defaultRx) {
        Add-Finding 'CUSTOM_RECEIVE_CONNECTOR' 'MEDIUM' ([string]$rc.Identity) ("Bindings=" + ($rc.Bindings -join ',') + " RemoteIPRanges=" + ($rc.RemoteIPRanges -join ','))
    }
}

# ---------- Relay traffic ----------
if (-not $SkipMessageTracking) {
    try {
        $start = (Get-Date).AddDays(-$TrackingDays)
        $rx = @(Get-MessageTrackingLog -Start $start -EventId RECEIVE -ResultSize Unlimited -ErrorAction Stop |
                Where-Object { [string]$_.Source -eq 'SMTP' -and $_.ClientIp })
        $groups = $rx | Group-Object { [string]$_.ClientIp }
        foreach ($g in $groups) {
            $ip = [string]$g.Name
            if ($ip -eq '127.0.0.1' -or $ip -eq '::1') { continue }
            if (Test-ExoIp $ip) { continue }
            $snd = (($g.Group | Select-Object -First 3 | ForEach-Object { [string]$_.Sender }) -join ', ')
            Add-Finding 'SMTP_RELAY_TRAFFIC' 'HIGH' $ip "$($g.Count) message(s) in $TrackingDays d; senders e.g. $snd"
        }
        Write-Status "Scanned $($rx.Count) SMTP RECEIVE events over $TrackingDays day(s)" "OK"
    } catch { Write-Status "Message tracking scan failed: $($_.Exception.Message)" "WARN" }
}

# ---------- Remote domain ----------
$tdd = @(Get-RemoteDomain | Where-Object { $_.TargetDeliveryDomain -and ([string]$_.DomainName -like '*.mail.onmicrosoft.com') })
if ($tdd.Count -eq 0) { Add-Finding 'NO_TARGET_DELIVERY_DOMAIN' 'MEDIUM' 'Org' 'Create/set remote domain <tenant>.mail.onmicrosoft.com with TargetDeliveryDomain $true' }
else { Write-Status "Target delivery domain: $(($tdd | ForEach-Object { $_.DomainName }) -join ', ')" "OK" }

# ---------- MX ----------
if (-not $SkipDns) {
    foreach ($ad in @(Get-AcceptedDomain)) {
        $dn = [string]$ad.DomainName
        if ($dn -like '*.onmicrosoft.com' -or $dn -like '*.local') { continue }
        try {
            $mx = @(Resolve-DnsName -Name $dn -Type MX -ErrorAction Stop | Where-Object { $_.Type -eq 'MX' })
            $bad = @($mx | Where-Object { [string]$_.NameExchange -notlike '*.mail.protection.outlook.com' })
            if ($mx.Count -gt 0 -and $bad.Count -gt 0) {
                Add-Finding 'MX_NOT_EXO' 'HIGH' $dn ("MX: " + (($mx | ForEach-Object { $_.NameExchange }) -join ', '))
            }
        } catch { Write-Status "MX lookup failed for ${dn}: $($_.Exception.Message)" "WARN" }
    }
}

# ---------- Autodiscover SCP ----------
foreach ($cas in @(Get-ClientAccessService -ErrorAction SilentlyContinue)) {
    if ($cas.AutoDiscoverServiceInternalUri) {
        Add-Finding 'AUTODISCOVER_SCP_SET' 'MEDIUM' $cas.Name "AutoDiscoverServiceInternalUri=$($cas.AutoDiscoverServiceInternalUri)"
    }
}

# ---------- Scripting agent ----------
try {
    $sa = Get-CmdletExtensionAgent -Identity 'Scripting Agent' -ErrorAction Stop
    if ($sa.Enabled) { Add-Finding 'SCRIPTING_AGENT_ENABLED' 'LOW' 'Scripting Agent' 'Copy ScriptingAgentConfig.xml to the tools box' }
} catch { }

# ---------- Federation / hybrid ----------
try { if (@(Get-FederationTrust -ErrorAction Stop).Count -gt 0) { Add-Finding 'FEDERATION_TRUST_PRESENT' 'INFO' 'Org' 'Remove-FederationTrust during permanent shutdown' } } catch { }
try { if (Get-HybridConfiguration -ErrorAction Stop) { Add-Finding 'HYBRID_CONFIG_PRESENT' 'INFO' 'Org' 'Run decommission Scenario 2 hybrid cleanup before permanent shutdown' } } catch { }

# ---------- AD: schema + EMT group ----------
if ($haveAd) {
    try {
        $schemaNc = (Get-ADRootDSE).schemaNamingContext
        $ru = [int](Get-ADObject -Identity "CN=ms-Exch-Schema-Version-Pt,$schemaNc" -Properties rangeUpper).rangeUpper
        if ($ru -lt 17003) { Add-Finding 'SCHEMA_BELOW_CU12' 'LOW' 'Schema' "rangeUpper=$ru; installing 2019 CU12+ tools will extend schema" }
        else { Write-Status "Exchange schema rangeUpper: $ru" "OK" }
    } catch { Write-Status "Schema version check failed: $($_.Exception.Message)" "WARN" }
    try {
        $emt = @(Get-ADGroup -Filter "Name -eq 'Recipient Management EMT'" -ErrorAction Stop)
        if ($emt.Count -eq 0) { Add-Finding 'EMT_GROUP_MISSING' 'INFO' 'AD' 'Run Add-PermissionForEMT.ps1 on the tools box' }
    } catch { }
} else { Write-Status "ActiveDirectory module not present - schema and EMT group checks skipped" "WARN" }

# ---------- Report ----------
$csv = Join-Path $OutputPath ("LastExchangeServerReadiness-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$findings | Export-Csv -Path $csv -NoTypeInformation
Write-Host ""
$high = @($findings | Where-Object Severity -eq 'HIGH')
if ($findings.Count -eq 0) { Write-Status "No findings - environment matches the tools-only eligibility criteria" "OK" }
else {
    $findings | Group-Object Code | Sort-Object Count -Descending | ForEach-Object {
        $sev = ($_.Group | Select-Object -First 1).Severity
        Write-Status ("{0} [{1}]: {2}" -f $_.Name, $sev, $_.Count) $(if ($sev -eq 'HIGH') { 'ERROR' } else { 'WARN' })
    }
}
if ($high.Count -gt 0) { Write-Status "NOT READY: $($high.Count) HIGH finding(s). Do not shut down the last Exchange server." "ERROR" }
else { Write-Status "No blockers. Next: test the snap-in with the server running, then shut down (never uninstall)." "OK" }
Write-Status "Report: $csv"
