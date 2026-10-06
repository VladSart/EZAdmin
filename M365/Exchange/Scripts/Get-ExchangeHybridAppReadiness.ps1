<#
.SYNOPSIS
    Read-only readiness audit for the Exchange dedicated hybrid app, the Graph rich-coexistence flow and the Exchange Online EWS allow list.

.DESCRIPTION
    Run in an elevated Exchange Management Shell (on-premises). Checks:
      - Every Mailbox server's exact ExSetup build against the dedicated-app (EWS flow) and Graph-flow minimum builds
      - Presence and scope of the ExchangeOnpremAsThirdPartyAppId and RouteThroughMSGraph Setting Overrides
      - evoSTS Auth Server ApplicationIdentifier / DomainName / GraphBaseUrl
      - Auth Certificate current/next thumbprints and expiry
      - Optional Test-OAuthConnectivity token test and the appId actually used
      - Optional: Exchange Online EwsEnabled / EwsAllowedAppIDs membership of the dedicated appId
        (requires Connect-ExchangeOnline -Prefix <prefix> in the same session, to avoid cmdlet collisions)
      - Optional: outbound 443 to login.microsoftonline.com and graph.microsoft.com from this server
    Makes NO changes. Does not query Entra ID (use Get-MgApplication separately) and does not inspect cloud-to-on-prem lookups.

.PARAMETER OnPremMailbox
    On-premises mailbox used for Test-OAuthConnectivity. Omit to skip the token test.

.PARAMETER ExoPrefix
    The -Prefix used with Connect-ExchangeOnline in this session (e.g. EXO). Omit to skip the tenant EWS check.

.PARAMETER SkipNetworkTest
    Skip the outbound connectivity tests.

.PARAMETER OutputPath
    Folder for the CSV report. Default: current directory.

.EXAMPLE
    Connect-ExchangeOnline -Prefix EXO -ShowBanner:$false
    .\Get-ExchangeHybridAppReadiness.ps1 -OnPremMailbox onprem.user@contoso.com -ExoPrefix EXO

.NOTES
    Requires: Exchange Management Shell (Exchange 2016 CU23 / 2019 / SE), View-Only Organization Management or higher.
    Remote build collection uses Invoke-Command (WinRM) to each Mailbox server; unreachable servers fall back to AdminDisplayVersion.
    Build thresholds per Microsoft Learn "Deploy dedicated Exchange hybrid app" (updated 2026-05-07).
    Safe: read-only.
#>
[CmdletBinding()]
param(
    [string]$OnPremMailbox,
    [string]$ExoPrefix,
    [switch]$SkipNetworkTest,
    [string]$OutputPath = (Get-Location).Path
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Area, [string]$Item, [string]$Value, [string]$Status, [string]$Note = "")
    $results.Add([pscustomobject]@{ Area = $Area; Item = $Item; Value = $Value; Status = $Status; Note = $Note })
    Write-Status "$Area | $Item = $Value $(if ($Note) { "- $Note" })" $Status
}

function Get-BuildVerdict {
    param([version]$V)
    # Returns @(DedicatedAppCapable, GraphCapable)
    $graph = ($V -ge [version]'15.2.2562.41')
    $ded = $false
    if ($V.Major -eq 15 -and $V.Minor -eq 1) {
        $ded = ($V.Build -gt 2507) -or ($V.Build -eq 2507 -and $V.Revision -ge 55)
    } elseif ($V.Major -eq 15 -and $V.Minor -eq 2) {
        if     ($V.Build -gt 2562)  { $ded = $true }
        elseif ($V.Build -eq 2562)  { $ded = ($V.Revision -ge 17) }
        elseif ($V.Build -eq 1748)  { $ded = ($V.Revision -ge 24) }
        elseif ($V.Build -eq 1544)  { $ded = ($V.Revision -ge 25) }
        else                        { $ded = $false }
    }
    return @($ded, $graph)
}

# ---------------- Preflight ----------------
Write-Status "Preflight"
foreach ($c in 'Get-ExchangeServer','Get-SettingOverride','Get-AuthServer','Get-AuthConfig') {
    if (-not (Get-Command $c -ErrorAction SilentlyContinue)) {
        Write-Status "$c not found - run this in the Exchange Management Shell." "ERROR"
        return
    }
}
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

# ---------------- Builds ----------------
Write-Status "Collecting Mailbox server builds"
$allGraph = $true; $allDed = $true
$servers = @(Get-ExchangeServer | Where-Object { $_.IsMailboxServer })
foreach ($s in $servers) {
    $raw = $null; $src = "ExSetup"
    try {
        if ($s.Name -eq $env:COMPUTERNAME) {
            $raw = (Get-Command ExSetup.exe).FileVersionInfo.ProductVersion
        } else {
            $raw = Invoke-Command -ComputerName $s.Fqdn -ScriptBlock { (Get-Command ExSetup.exe).FileVersionInfo.ProductVersion } -ErrorAction Stop
        }
    } catch {
        $src = "AdminDisplayVersion (ExSetup unreachable)"
        $m = [regex]::Match("$($s.AdminDisplayVersion)", 'Version (\d+)\.(\d+) \(Build (\d+)\.(\d+)\)')
        if ($m.Success) { $raw = "{0}.{1}.{2}.{3}" -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value, $m.Groups[4].Value }
    }
    if (-not $raw) { Add-Result "Build" $s.Name "unknown" "WARN" "Could not determine build"; $allGraph = $false; $allDed = $false; continue }
    $parts = @(("$raw".Trim() -split '\.') | ForEach-Object { [int]$_ })
    while (@($parts).Count -lt 4) { $parts += 0 }
    $v = [version]::new($parts[0], $parts[1], $parts[2], $parts[3])
    $verdict = Get-BuildVerdict $v
    $status = if ($verdict[1]) { "OK" } elseif ($verdict[0]) { "WARN" } else { "ERROR" }
    $note = if ($verdict[1]) { "Graph flow capable" } elseif ($verdict[0]) { "Dedicated app EWS flow only (dies 1 Apr 2027)" } else { "Below supported build - no rich coexistence" }
    if ($src -ne "ExSetup") { $note = "$note; source: $src (HU revision may be inaccurate)" }
    Add-Result "Build" $s.Name $v.ToString() $status $note
    if (-not $verdict[1]) { $allGraph = $false }
    if (-not $verdict[0]) { $allDed = $false }
}

# ---------------- Setting overrides ----------------
Write-Status "Checking Setting Overrides"
$overrides = @(Get-SettingOverride)
$ded = @($overrides | Where-Object { $_.SectionName -eq 'ExchangeOnpremAsThirdPartyAppId' })
$gr  = @($overrides | Where-Object { $_.SectionName -eq 'RouteThroughMSGraph' })
if ($ded.Count -eq 0) {
    Add-Result "Override" "ExchangeOnpremAsThirdPartyAppId" "absent" "ERROR" "Dedicated app not in use (HCW does not create this)"
} else {
    foreach ($o in $ded) {
        $scope = if (@($o.Server).Count -gt 0 -and "$($o.Server)") { "servers: $($o.Server -join ',')" } else { "org-wide" }
        $st = if ("$($o.Parameters)" -match 'Enabled=true') { "OK" } else { "WARN" }
        Add-Result "Override" $o.Name "$($o.Parameters)" $st $scope
    }
}
if ($gr.Count -eq 0) {
    $st = if ($allGraph) { "WARN" } else { "INFO" }
    Add-Result "Override" "RouteThroughMSGraph" "absent" $st "Hybrid uses EWS flow; appId must be on EXO EwsAllowedAppIDs"
} else {
    foreach ($o in $gr) {
        $st = if ($allGraph) { "OK" } else { "WARN" }
        $n = if ($allGraph) { "Graph flow enabled" } else { "Graph flow enabled but not all servers are >= 15.2.2562.41" }
        Add-Result "Override" $o.Name "$($o.Parameters)" $st $n
    }
}

# ---------------- Auth Server ----------------
Write-Status "Checking evoSTS Auth Server"
$hybridAppIds = @()
$as = @(Get-AuthServer | Where-Object { $_.Name -like '*evoSTS*' })
if ($as.Count -eq 0) {
    Add-Result "AuthServer" "evoSTS" "absent" "ERROR" "No OAuth Auth Server - hybrid OAuth not configured (re-run HCW)"
}
foreach ($a in $as) {
    $appId = "$($a.ApplicationIdentifier)"
    if ([string]::IsNullOrWhiteSpace($appId)) {
        Add-Result "AuthServer" "$($a.Name) ApplicationIdentifier" "empty" "ERROR" "Still on shared principal (blocked since 31 Oct 2025)"
    } else {
        $hybridAppIds += $appId
        Add-Result "AuthServer" "$($a.Name) ApplicationIdentifier" $appId "OK" "Realm $($a.Realm)"
    }
    Add-Result "AuthServer" "$($a.Name) DomainName" "$($a.DomainName -join ',')" "INFO"
    $gbu = if ($a.PSObject.Properties['GraphBaseUrl']) { "$($a.GraphBaseUrl)" } else { "n/a (property not on this build)" }
    Add-Result "AuthServer" "$($a.Name) GraphBaseUrl" $gbu "INFO"
}

# ---------------- Auth certificate ----------------
Write-Status "Checking Auth Certificate"
$ac = Get-AuthConfig
foreach ($pair in @(@('Current', $ac.CurrentCertificateThumbprint), @('Next', $ac.NextCertificateThumbprint))) {
    $label = $pair[0]; $tp = "$($pair[1])"
    if ([string]::IsNullOrWhiteSpace($tp)) {
        if ($label -eq 'Current') { Add-Result "AuthCert" $label "none" "ERROR" } else { Add-Result "AuthCert" $label "none" "INFO" "No next certificate staged" }
        continue
    }
    $cert = Get-ChildItem -Path "Cert:\LocalMachine\My\$tp" -ErrorAction SilentlyContinue
    if (-not $cert) {
        Add-Result "AuthCert" $label $tp "WARN" "Not in this server's LocalMachine\My store"
    } else {
        $days = [int]($cert.NotAfter - (Get-Date)).TotalDays
        $st = if ($days -lt 0) { "ERROR" } elseif ($days -lt 60) { "WARN" } else { "OK" }
        Add-Result "AuthCert" $label $tp $st "Expires $($cert.NotAfter.ToString('yyyy-MM-dd')) ($days d) - re-upload with -UpdateCertificate after any change"
    }
}

# ---------------- Token test ----------------
if ($OnPremMailbox) {
    Write-Status "Running Test-OAuthConnectivity"
    try {
        $r = Test-OAuthConnectivity -Service EWS -TargetUri https://outlook.office365.com -Mailbox $OnPremMailbox -ErrorAction Stop
        $used = "not found"
        if ("$($r.Detail.FullId)" -match 'L:(?<g>[0-9a-fA-F-]{36})-AS:') { $used = $Matches['g'] }
        $st = if ("$($r.ResultType)" -eq 'Success' -and $hybridAppIds -contains $used) { "OK" } elseif ("$($r.ResultType)" -eq 'Success') { "WARN" } else { "ERROR" }
        Add-Result "Token" "Test-OAuthConnectivity" "$($r.ResultType)" $st "appId used: $used (tests THIS server's identity only)"
    } catch {
        Add-Result "Token" "Test-OAuthConnectivity" "exception" "ERROR" $_.Exception.Message
    }
} else {
    Add-Result "Token" "Test-OAuthConnectivity" "skipped" "INFO" "Pass -OnPremMailbox to run"
}

# ---------------- Network ----------------
if (-not $SkipNetworkTest) {
    Write-Status "Testing outbound 443"
    foreach ($h in 'login.microsoftonline.com','graph.microsoft.com','outlook.office365.com') {
        try {
            $t = Test-NetConnection -ComputerName $h -Port 443 -WarningAction SilentlyContinue
            $st = if ($t.TcpTestSucceeded) { "OK" } else { "ERROR" }
            Add-Result "Network" $h "$($t.TcpTestSucceeded)" $st "From $env:COMPUTERNAME (direct; proxy paths not tested)"
        } catch {
            Add-Result "Network" $h "exception" "WARN" $_.Exception.Message
        }
    }
}

# ---------------- Exchange Online EWS gate ----------------
if ($ExoPrefix) {
    Write-Status "Checking Exchange Online EWS allow list"
    $cmd = "Get-{0}OrganizationConfig" -f $ExoPrefix
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Add-Result "EXO" $cmd "not found" "WARN" "Run Connect-ExchangeOnline -Prefix $ExoPrefix first"
    } else {
        try {
            $oc = & $cmd -RetrieveEwsOperationAccessPolicy
            $enabled = if ($null -eq $oc.EwsEnabled) { '$null (unset)' } else { "$($oc.EwsEnabled)" }
            $list = @()
            if ($oc.EwsAllowedAppIDs) { $list = @("$($oc.EwsAllowedAppIDs)" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
            $st = if ($enabled -eq 'True') { "OK" } elseif ($enabled -eq 'False') { "ERROR" } else { "WARN" }
            Add-Result "EXO" "EwsEnabled" $enabled $st "False/unset = hybrid EWS calls blocked (now or by phased rollout)"
            Add-Result "EXO" "EwsAllowedAppIDs count" "$($list.Count)" $(if ($list.Count -gt 0) { "INFO" } else { "WARN" }) "Empty + True = block-all from enforcement (10 Oct 2026 Worldwide)"
            foreach ($id in $hybridAppIds) {
                $in = $list -contains $id
                $st = if ($in) { "OK" } elseif ($gr.Count -gt 0) { "WARN" } else { "ERROR" }
                $n = if ($in) { "listed" } elseif ($gr.Count -gt 0) { "Not listed - Graph flow on, but cloud archive / non-OOF MailTips still use EWS" } else { "Not listed - hybrid EWS flow will be rejected" }
                Add-Result "EXO" "Hybrid appId $id in EwsAllowedAppIDs" "$in" $st $n
            }
        } catch {
            Add-Result "EXO" $cmd "exception" "ERROR" $_.Exception.Message
        }
    }
} else {
    Add-Result "EXO" "EwsAllowedAppIDs" "skipped" "INFO" "Connect-ExchangeOnline -Prefix EXO, then pass -ExoPrefix EXO"
}

# ---------------- Report ----------------
$file = Join-Path $OutputPath ("ExchangeHybridAppReadiness_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$results | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
$err  = @($results | Where-Object Status -eq 'ERROR').Count
$warn = @($results | Where-Object Status -eq 'WARN').Count
Write-Status "Summary: $err error(s), $warn warning(s). All servers dedicated-app capable: $allDed. All servers Graph capable: $allGraph." $(if ($err) { "ERROR" } elseif ($warn) { "WARN" } else { "OK" })
Write-Status "Report: $file"
