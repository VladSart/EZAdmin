<#
.SYNOPSIS
    Finds retired Office 365 Connector webhook URLs (and current Workflows URLs) in files, and optionally test-posts to a Workflows webhook.

.DESCRIPTION
    Office 365 Connectors in Microsoft Teams were permanently disabled 18-22 May 2026 (MC1181996).
    Any sender still posting to *.webhook.office.com / outlook.office.com/webhook fails silently.
    Because the Connectors service is gone, you can no longer enumerate connectors from Teams —
    the only way to find unmigrated senders is to look where their URLs are stored.

    SCAN MODE (-Path): recursively scans text files (scripts, configs, IaC, env files) for:
      - Legacy   : https://<tenant>.webhook.office.com/webhookb2/...  and  https://outlook.office(365).com/webhook/...
      - Workflows: https://*.logic.azure.com/workflows/...  and  https://*.environment.api.powerplatform.com/.../workflows/...
    Output never contains the full URL: host + path prefix only, query string redacted (URLs are secrets).
    Workflows findings also report whether a 'sig=' parameter is present (missing sig -> likely 401).

    TEST MODE (-TestWebhookUrl): sends ONE minimal Adaptive Card (Workflows 'message' envelope) to the URL.
      THIS POSTS A REAL MESSAGE to the target channel/chat. Returns the HTTP status (202 = trigger accepted;
      delivery still depends on the flow run — check run history if nothing appears).

    Does NOT: modify files, create/modify flows, or call Teams/Graph/Power Platform admin APIs.

.PARAMETER Path
    One or more folders or files to scan (local or UNC).

.PARAMETER Include
    File name patterns to scan. Default covers common script/config/IaC types.

.PARAMETER MaxFileSizeMB
    Skip files larger than this. Default 5.

.PARAMETER TestWebhookUrl
    A Workflows webhook URL to test-post to. Posts a real card.

.PARAMETER TestMessage
    Text for the test card. Default 'EZAdmin webhook test <timestamp>'.

.PARAMETER OutputPath
    CSV path for scan findings. Default .\TeamsWebhook-Scan-<timestamp>.csv

.EXAMPLE
    .\Find-LegacyTeamsWebhookUrl.ps1 -Path '\\fs01\Scripts','C:\ProgramData\Zabbix'

.EXAMPLE
    .\Find-LegacyTeamsWebhookUrl.ps1 -TestWebhookUrl '<workflows-url>'

.NOTES
    Requires : Windows PowerShell 5.1 or PowerShell 7. No modules.
    Run-as   : Any account with read access to the scanned paths; no admin rights needed.
    Safety   : Scan mode is read-only. Test mode sends one message (explicit opt-in via -TestWebhookUrl).
    Related  : M365/Teams/ConnectorsToWorkflows-B.md, M365/Teams/ConnectorsToWorkflows-A.md
#>
[CmdletBinding(DefaultParameterSetName = 'Scan')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Scan')]
    [string[]]$Path,
    [Parameter(ParameterSetName = 'Scan')]
    [string[]]$Include = @('*.ps1','*.psm1','*.psd1','*.py','*.sh','*.bat','*.cmd','*.js','*.ts','*.cs','*.json','*.yml','*.yaml',
                          '*.xml','*.config','*.ini','*.conf','*.cfg','*.env','*.properties','*.tf','*.tfvars','*.txt'),
    [Parameter(ParameterSetName = 'Scan')]
    [int]$MaxFileSizeMB = 5,
    [Parameter(ParameterSetName = 'Scan')]
    [string]$OutputPath = (Join-Path $PWD ("TeamsWebhook-Scan-{0}.csv" -f (Get-Date -Format yyyyMMdd-HHmm))),
    [Parameter(Mandatory, ParameterSetName = 'Test')]
    [string]$TestWebhookUrl,
    [Parameter(ParameterSetName = 'Test')]
    [string]$TestMessage = ("EZAdmin webhook test {0}" -f (Get-Date -Format s))
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-MaskedUrl {
    param([string]$Url)
    try {
        $u = [Uri]$Url
        $segments = $u.AbsolutePath.Trim('/').Split('/')
        $prefix = ($segments | Select-Object -First 2) -join '/'
        return ('{0}://{1}/{2}/...' -f $u.Scheme, $u.Host, $prefix)
    } catch { return '<unparseable URL>' }
}

function Get-UrlKind {
    param([string]$Url)
    if ($Url -match '(?i)\.webhook\.office\.com/' -or $Url -match '(?i)outlook\.office(365)?\.com/webhook') { return 'Legacy' }
    if ($Url -match '(?i)\.logic\.azure\.com(:\d+)?/workflows/') { return 'Workflows-LogicApps' }
    if ($Url -match '(?i)\.environment\.api\.powerplatform\.com(:\d+)?/.*workflows/') { return 'Workflows-PowerPlatform' }
    return 'Other'
}

# ================= TEST MODE =================
if ($PSCmdlet.ParameterSetName -eq 'Test') {
    $kind = Get-UrlKind -Url $TestWebhookUrl
    Write-Status ("Target: {0} ({1})" -f (Get-MaskedUrl $TestWebhookUrl), $kind)
    if ($kind -eq 'Legacy') {
        Write-Status "This is a retired Office 365 Connector URL (disabled 18-22 May 2026). Create a Workflows webhook instead - see ConnectorsToWorkflows-B.md Fix 1." "ERROR"
        return
    }
    if ($kind -like 'Workflows*' -and $TestWebhookUrl -notmatch '(?i)[?&]sig=') {
        Write-Status "No 'sig=' parameter in the URL - expect 401 unless the trigger uses tenant/OAuth auth or the URL was truncated." "WARN"
    }
    $payload = @{
        type        = 'message'
        attachments = @(@{
            contentType = 'application/vnd.microsoft.card.adaptive'
            contentUrl  = $null
            content     = @{
                '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
                type      = 'AdaptiveCard'
                version   = '1.4'
                body      = @(@{ type = 'TextBlock'; text = $TestMessage; wrap = $true })
            }
        })
    } | ConvertTo-Json -Depth 10

    $status = $null; $detail = ''
    try {
        $r = Invoke-WebRequest -Uri $TestWebhookUrl -Method Post -ContentType 'application/json' -Body $payload -UseBasicParsing
        $status = [int]$r.StatusCode
    } catch {
        $resp = $null
        if ($_.Exception.PSObject.Properties.Name -contains 'Response') { $resp = $_.Exception.Response }
        if ($resp) { $status = [int]$resp.StatusCode }
        $detail = $_.Exception.Message
    }
    switch ($status) {
        202     { Write-Status "202 Accepted - trigger fired. If no card appears within ~1 min, open the flow's run history." "OK" }
        200     { Write-Status "200 OK - request accepted." "OK" }
        401     { Write-Status "401 Unauthorized - trigger not set to 'Anyone' or URL missing its sig. See B runbook Fix 3." "ERROR" }
        404     { Write-Status "404 Not Found - flow deleted or URL regenerated. Recopy/recreate (Fix 1)." "ERROR" }
        default { Write-Status ("Status {0}. {1}" -f $status, $detail) "ERROR" }
    }
    [pscustomobject]@{ Target = (Get-MaskedUrl $TestWebhookUrl); Kind = $kind; StatusCode = $status; Detail = $detail }
    return
}

# ================= SCAN MODE =================
# Host may have any number of sub-labels (tenant.webhook.office.com, prod-12.westus.logic.azure.com) or none (outlook.office.com)
$urlRegex = [regex]'(?i)https://(?:[a-z0-9\-]+\.)*(?:webhook\.office\.com|outlook\.office(?:365)?\.com|logic\.azure\.com|environment\.api\.powerplatform\.com)(?::\d+)?/[^\s"''<>\)\]]+'
$maxBytes = [int64]$MaxFileSizeMB * 1MB
$findings = [System.Collections.Generic.List[object]]::new()
$scanned = 0; $skipped = 0

foreach ($root in $Path) {
    if (-not (Test-Path -LiteralPath $root)) { Write-Status "Path not found: $root" "WARN"; continue }
    Write-Status "Scanning $root ..."
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Include $Include -ErrorAction SilentlyContinue)
    if ((Get-Item -LiteralPath $root) -is [System.IO.FileInfo]) { $files = @(Get-Item -LiteralPath $root) }
    foreach ($f in $files) {
        if ($f.Length -gt $maxBytes) { $skipped++; continue }
        $scanned++
        $lineNo = 0
        try {
            foreach ($line in [System.IO.File]::ReadLines($f.FullName)) {
                $lineNo++
                if ($line.IndexOf('https://', [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
                foreach ($m in $urlRegex.Matches($line)) {
                    $kind = Get-UrlKind -Url $m.Value
                    if ($kind -eq 'Other') { continue }
                    $hasSig = if ($kind -like 'Workflows*') { [bool]($m.Value -match '(?i)[?&]sig=') } else { $null }
                    $findings.Add([pscustomobject]@{
                        Kind       = $kind
                        File       = $f.FullName
                        Line       = $lineNo
                        MaskedUrl  = Get-MaskedUrl $m.Value
                        HasSig     = $hasSig
                        LastWrite  = $f.LastWriteTime
                        Action     = switch ($kind) { 'Legacy' { 'MIGRATE: retired connector URL' } default { 'OK: Workflows URL (secret - consider vaulting)' } }
                    })
                }
            }
        } catch { $skipped++; Write-Verbose ("Unreadable: {0} ({1})" -f $f.FullName, $_.Exception.Message) }
    }
}

$findings | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
$legacy = @($findings | Where-Object Kind -eq 'Legacy').Count
$wf     = @($findings | Where-Object Kind -like 'Workflows*').Count
$noSig  = @($findings | Where-Object { $_.Kind -like 'Workflows*' -and $_.HasSig -eq $false }).Count
Write-Status ("Scanned {0} files ({1} skipped). Legacy: {2}  Workflows: {3}  Workflows without sig: {4}" -f $scanned, $skipped, $legacy, $wf, $noSig) $(if ($legacy) { 'WARN' } else { 'OK' })
if ($legacy) { Write-Status "Legacy URLs found - these senders have not posted since May 2026. See ConnectorsToWorkflows-B.md Fix 1." "WARN" }
Write-Status "CSV: $OutputPath"
