<#
.SYNOPSIS
    Read-only readiness audit for the Exchange Online EWS retirement (EWSEnabled + EWSAllowedAppIDs).

.DESCRIPTION
    Reports, without changing anything:
      - Org-level EwsEnabled and EwsAllowedAppIDs (read with -RetrieveEwsOperationAccessPolicy),
        classified against Microsoft's behaviour matrix (flags the "True + empty list = block-all
        after 1 Oct 2026" trap and the "unset = subject to rollout" state).
      - The older user-agent policy (EwsApplicationAccessPolicy / EwsAllowList / EwsBlockList),
        which is a second, independent gate an app must also pass.
      - Optionally, mailboxes with CASMailbox EwsEnabled = False (-IncludeMailboxOverrides).
      - Optionally, a diff between an exported M365 admin center EWS usage report CSV
        (Reports > Usage > Exchange > EWS usage > Export) and the allow list (-UsageReportCsv):
        active App IDs NOT on the list (will break) and listed App IDs with no usage (review).
      - Optionally (-IncludeGraphPermissionAudit, requires a connected Microsoft Graph session with
        Application.Read.All + DelegatedPermissionGrant.Read.All), every service principal holding
        full_access_as_app (application) or EWS.AccessAsUser.All (delegated) on Office 365 Exchange
        Online, resolved to display names and cross-checked against the allow list.

    Does NOT: set EwsEnabled, change the allow list, edit mailboxes, or remove permissions.
    Does NOT: download the usage report (there is no supported cmdlet for it; export it manually).

.PARAMETER UsageReportCsv
    Path to the CSV exported from the EWS usage report. The column containing App IDs is detected
    by name (any header matching 'Application ID' / 'AppId' / 'Application Id').

.PARAMETER IncludeMailboxOverrides
    Enumerate all mailboxes and report those with EwsEnabled = False. Slow in large tenants.

.PARAMETER IncludeGraphPermissionAudit
    Audit Entra grants of full_access_as_app / EWS.AccessAsUser.All. Requires Connect-MgGraph first.

.PARAMETER OutputPath
    CSV output path. Default: .\EWS-Retirement-Readiness-<timestamp>.csv

.EXAMPLE
    Connect-ExchangeOnline; .\Get-EWSRetirementReadiness.ps1

.EXAMPLE
    Connect-ExchangeOnline
    Connect-MgGraph -Scopes Application.Read.All,DelegatedPermissionGrant.Read.All
    .\Get-EWSRetirementReadiness.ps1 -UsageReportCsv .\EWSUsage90d.csv -IncludeGraphPermissionAudit -IncludeMailboxOverrides

.NOTES
    Requires : ExchangeOnlineManagement v3 (connected). Microsoft.Graph.Applications and
               Microsoft.Graph.Identity.SignIns for -IncludeGraphPermissionAudit.
    Roles    : View-Only Organization Management or Global Reader (EXO); Graph read scopes above.
    Safety   : Read-only. Safe to run in production.
    Related  : M365/Exchange/EWSRetirement-B.md, M365/Exchange/EWSRetirement-A.md
#>
[CmdletBinding()]
param(
    [string]$UsageReportCsv,
    [switch]$IncludeMailboxOverrides,
    [switch]$IncludeGraphPermissionAudit,
    [string]$OutputPath = (Join-Path $PWD ("EWS-Retirement-Readiness-{0}.csv" -f (Get-Date -Format yyyyMMdd-HHmm)))
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$results = New-Object System.Collections.Generic.List[object]
function Add-Finding {
    param([string]$Area, [string]$Item, [string]$Value, [string]$Status, [string]$Note)
    $results.Add([pscustomobject]@{ Area = $Area; Item = $Item; Value = $Value; Status = $Status; Note = $Note })
    Write-Status "$Area | $Item | $Value $(if ($Note) { "— $Note" })" $Status
}

function ConvertTo-AppIdList {
    param($Raw)
    if ($null -eq $Raw) { return @() }
    @(@($Raw) | ForEach-Object { "$_" -split '[,;\s]+' } | ForEach-Object { $_.Trim().ToLowerInvariant() } |
        Where-Object { $_ -match '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$' } | Sort-Object -Unique)
}

# ---------------- Preflight ----------------
if (-not (Get-Command Get-OrganizationConfig -ErrorAction SilentlyContinue)) {
    throw "Get-OrganizationConfig not available. Run Connect-ExchangeOnline first (ExchangeOnlineManagement v3)."
}
$now = Get-Date
$enforcementDate = Get-Date '2026-10-01'
$shutdownDate    = Get-Date '2027-04-01'
Add-Finding 'Timeline' 'Today' ($now.ToString('yyyy-MM-dd')) $(if ($now -ge $shutdownDate) {'ERROR'} elseif ($now -ge $enforcementDate) {'WARN'} else {'INFO'}) `
    $(if ($now -ge $shutdownDate) {'EWS in EXO permanently retired — no setting restores it'} elseif ($now -ge $enforcementDate) {'Enforcement phase: EWS works only for allow-listed App IDs'} else {'Pre-enforcement'})

# ---------------- Detect: org EWS gate ----------------
$cfg = Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy
$ewsEnabled = $cfg.EwsEnabled
$allowList  = @(ConvertTo-AppIdList $cfg.EwsAllowedAppIDs)

$enabledText = if ($null -eq $ewsEnabled) { '<unset>' } else { "$ewsEnabled" }
Add-Finding 'Org' 'EwsEnabled' $enabledText 'INFO' ''
Add-Finding 'Org' 'EwsAllowedAppIDs count' "$($allowList.Count)" 'INFO' ''
foreach ($id in $allowList) { Add-Finding 'AllowList' 'AppId' $id 'INFO' '' }

$state =
    if ($ewsEnabled -eq $false) { @('ERROR', 'EWS blocked tenant-wide (all apps).') }
    elseif ($null -eq $ewsEnabled) { @('WARN', 'Unset: subject to Microsoft rollout setting it to False from 1 Oct 2026. Configure explicitly if EWS is still needed.') }
    elseif ($allowList.Count -eq 0) { @('ERROR', 'True + EMPTY allow list = BLOCK-ALL once enforcement reaches the tenant.') }
    else { @('OK', 'True + populated allow list: only listed App IDs may use EWS.') }
Add-Finding 'Org' 'Effective state' "EwsEnabled=$enabledText; List=$($allowList.Count)" $state[0] $state[1]

# ---------------- Detect: legacy UA gate ----------------
$uaPolicy = "$($cfg.EwsApplicationAccessPolicy)"
$uaAllow  = @($cfg.EwsAllowList | Where-Object { $_ })
$uaBlock  = @($cfg.EwsBlockList | Where-Object { $_ })
$uaStatus = if ($uaPolicy -eq 'EnforceAllowList') { 'WARN' } elseif ($uaBlock.Count -gt 0) { 'WARN' } else { 'OK' }
$uaNote   = if ($uaPolicy -eq 'EnforceAllowList') { 'Every allowed App ID must ALSO match a UA pattern in EwsAllowList (also applies to REST).' }
            elseif ($uaBlock.Count -gt 0) { 'UA block list active — check listed apps are not matched.' } else { 'UA gate not restricting.' }
Add-Finding 'Org' 'EwsApplicationAccessPolicy' $(if ($uaPolicy) { $uaPolicy } else { '<blank>' }) $uaStatus $uaNote
if ($uaAllow.Count) { Add-Finding 'Org' 'EwsAllowList (UA)' ($uaAllow -join '; ') 'INFO' '' }
if ($uaBlock.Count) { Add-Finding 'Org' 'EwsBlockList (UA)' ($uaBlock -join '; ') 'INFO' '' }
Add-Finding 'Org' 'EwsAllowMacOutlook' "$($cfg.EwsAllowMacOutlook)" 'INFO' 'Legacy Outlook for Mac is EWS-only — see macOS/Troubleshooting/OutlookMac-B.md'

# ---------------- Detect: mailbox overrides ----------------
if ($IncludeMailboxOverrides) {
    Write-Status "Enumerating CAS mailboxes (may take a while)..."
    $blocked = @(Get-EXOCASMailbox -ResultSize Unlimited -Properties EwsEnabled | Where-Object { $_.EwsEnabled -eq $false })
    Add-Finding 'Mailbox' 'CASMailbox EwsEnabled=False count' "$($blocked.Count)" $(if ($blocked.Count) {'WARN'} else {'OK'}) 'Per-mailbox blocks (check service accounts/targets of approved apps)'
    foreach ($m in $blocked) { Add-Finding 'Mailbox' 'EwsEnabled=False' "$($m.PrimarySmtpAddress)" 'INFO' '' }
}

# ---------------- Detect: usage report diff ----------------
$usageIds = @()
if ($UsageReportCsv) {
    if (-not (Test-Path $UsageReportCsv)) { throw "UsageReportCsv not found: $UsageReportCsv" }
    $rows = @(Import-Csv $UsageReportCsv)
    if ($rows.Count -eq 0) {
        Add-Finding 'Usage' 'Report rows' '0' 'WARN' 'Empty export — widen to 90 days (data lags up to 10 days)'
    } else {
        $col = $rows[0].PSObject.Properties.Name | Where-Object { $_ -match '^(Application ?I[dD]|App ?I[dD])$' } | Select-Object -First 1
        if (-not $col) { throw "Could not find an Application ID column in $UsageReportCsv. Headers: $($rows[0].PSObject.Properties.Name -join ', ')" }
        $usageIds = @(ConvertTo-AppIdList ($rows | ForEach-Object { $_.$col }))
        Add-Finding 'Usage' 'Distinct App IDs in report' "$($usageIds.Count)" 'INFO' "Column '$col'"
        foreach ($id in $usageIds) {
            if ($allowList -notcontains $id) { Add-Finding 'Usage' 'ACTIVE but NOT allow-listed' $id 'ERROR' 'Will be blocked under enforcement unless added (or migrated to Graph)' }
        }
        foreach ($id in $allowList) {
            if ($usageIds -notcontains $id) { Add-Finding 'Usage' 'Allow-listed but NO usage in report' $id 'WARN' 'Confirm owner/need (report window max 90 days)' }
        }
    }
}

# ---------------- Detect: Entra permission surface ----------------
if ($IncludeGraphPermissionAudit) {
    if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue) -or -not (Get-MgContext)) {
        Add-Finding 'Graph' 'Permission audit' 'skipped' 'WARN' 'Connect-MgGraph -Scopes Application.Read.All,DelegatedPermissionGrant.Read.All first'
    } else {
        $exo = Get-MgServicePrincipal -Filter "appId eq '00000002-0000-0ff1-ce00-000000000000'"
        $role = $exo.AppRoles | Where-Object { $_.Value -eq 'full_access_as_app' }
        $spCache = @{}
        function Resolve-Sp([string]$ObjectId) {
            if (-not $spCache.ContainsKey($ObjectId)) {
                try { $spCache[$ObjectId] = Get-MgServicePrincipal -ServicePrincipalId $ObjectId } catch { $spCache[$ObjectId] = $null }
            }
            $spCache[$ObjectId]
        }
        if ($role) {
            $assignments = @(Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $exo.Id -All | Where-Object { $_.AppRoleId -eq $role.Id })
            Add-Finding 'Graph' 'full_access_as_app holders' "$($assignments.Count)" 'INFO' 'App-only EWS to ALL mailboxes unless scoped'
            foreach ($a in $assignments) {
                $sp = Resolve-Sp $a.PrincipalId
                $appId = if ($sp) { "$($sp.AppId)".ToLowerInvariant() } else { '<unresolved>' }
                $listed = $allowList -contains $appId
                $used   = $usageIds -contains $appId
                $status = if ($listed) { 'OK' } else { 'WARN' }
                $note   = "Allow-listed=$listed" + $(if ($UsageReportCsv) { "; SeenInUsage=$used" } else { '' }) +
                          $(if (-not $listed -and $UsageReportCsv -and -not $used) { '; dormant grant — candidate for removal' } else { '' })
                Add-Finding 'Graph' "full_access_as_app: $($a.PrincipalDisplayName)" $appId $status $note
            }
        } else {
            Add-Finding 'Graph' 'full_access_as_app role' 'not found on EXO SP' 'WARN' 'Unexpected — check Graph connection/tenant'
        }
        $grants = @(Get-MgOauth2PermissionGrant -Filter "resourceId eq '$($exo.Id)'" -All | Where-Object { $_.Scope -match 'EWS\.AccessAsUser\.All' })
        Add-Finding 'Graph' 'EWS.AccessAsUser.All grants' "$($grants.Count)" 'INFO' 'Delegated EWS'
        foreach ($g in ($grants | Group-Object ClientId)) {
            $sp = Resolve-Sp $g.Name
            $appId = if ($sp) { "$($sp.AppId)".ToLowerInvariant() } else { '<unresolved>' }
            $name  = if ($sp) { $sp.DisplayName } else { $g.Name }
            $listed = $allowList -contains $appId
            Add-Finding 'Graph' "EWS.AccessAsUser.All: $name" $appId $(if ($listed) {'OK'} else {'WARN'}) "Allow-listed=$listed; grants=$($g.Count)"
        }
    }
}

# ---------------- Validate / Report ----------------
$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
$err  = @($results | Where-Object Status -eq 'ERROR').Count
$warn = @($results | Where-Object Status -eq 'WARN').Count
Write-Status "Done. ERROR=$err WARN=$warn. CSV: $OutputPath" $(if ($err) {'ERROR'} elseif ($warn) {'WARN'} else {'OK'})
