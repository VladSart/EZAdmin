<#
.SYNOPSIS
    Runs an Exchange Online message trace and exports results to CSV.

.DESCRIPTION
    Performs an Exchange Online message trace for a given sender, recipient,
    subject, or message ID over a configurable lookback window (up to 10 days
    for standard traces, 90 days via Historical Search).

    Handles pagination automatically — message traces cap at 5,000 results per
    page; this script loops until all pages are retrieved.

    Outputs:
    - Console summary (delivery status breakdown)
    - CSV export with all trace fields
    - Optional: detailed per-message event dump

    Modes:
    1. Standard trace  — last 10 days, near-real-time (1-5 min latency)
    2. Historical search — up to 90 days, submitted as an async job (hours to complete)

.PARAMETER SenderAddress
    SMTP address of the sender to trace. Accepts wildcards (*@contoso.com).

.PARAMETER RecipientAddress
    SMTP address of the recipient. Accepts wildcards.

.PARAMETER Subject
    Subject line text to filter on (partial match). Cannot be combined with MessageId.

.PARAMETER MessageId
    Full Internet Message ID (e.g. <abc123@mail.protection.outlook.com>).
    Most specific filter — use when available.

.PARAMETER StartDate
    Start of the trace window. Max 10 days ago for standard, 90 days for historical.
    Defaults to 48 hours ago.

.PARAMETER EndDate
    End of the trace window. Defaults to now.

.PARAMETER HistoricalSearch
    Switch to submit as a Historical Search job (required for > 10 days).
    Note: results are not immediate — check via Get-HistoricalSearch.

.PARAMETER OutputPath
    Directory to write CSV exports. Defaults to current directory.

.PARAMETER DetailedEvents
    Switch to also retrieve per-message event detail (slower — one call per message).

.EXAMPLE
    # Trace all messages from a sender in the last 48 hours
    .\Get-MessageTrace.ps1 -SenderAddress "john.doe@contoso.com"

.EXAMPLE
    # Trace a specific message by ID with full event detail
    .\Get-MessageTrace.ps1 -MessageId "<abc123@mail.protection.outlook.com>" -DetailedEvents

.EXAMPLE
    # Trace all failed deliveries to a recipient over 7 days
    .\Get-MessageTrace.ps1 -RecipientAddress "helpdesk@contoso.com" `
        -StartDate (Get-Date).AddDays(-7) -EndDate (Get-Date) `
        -OutputPath "C:\Temp\Traces"

.NOTES
    Requires:    ExchangeOnlineManagement module v3+
    Permissions: Message Tracking role OR Global Admin / Exchange Admin
    Run-as:      Standard user is sufficient (no elevation required)
    Safe:        Read-only — no changes made to any mailbox or message
#>

[CmdletBinding(DefaultParameterSetName = "ByAddress")]
param(
    [Parameter(ParameterSetName = "ByAddress")]
    [string]$SenderAddress,

    [Parameter(ParameterSetName = "ByAddress")]
    [string]$RecipientAddress,

    [Parameter(ParameterSetName = "ByAddress")]
    [string]$Subject,

    [Parameter(ParameterSetName = "ByMessageId")]
    [string]$MessageId,

    [datetime]$StartDate  = (Get-Date).AddHours(-48),
    [datetime]$EndDate    = (Get-Date),

    [switch]$HistoricalSearch,
    [switch]$DetailedEvents,

    [string]$OutputPath   = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Helpers ────────────────────────────────────────────────────────────────────

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"    { "Green"  }
        "WARN"  { "Yellow" }
        "ERROR" { "Red"    }
        default { "Cyan"   }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Assert-EXOConnected {
    try {
        $null = Get-OrganizationConfig -ErrorAction Stop
        Write-Status "EXO session confirmed" "OK"
    }
    catch {
        Write-Status "Not connected to Exchange Online. Connecting..." "WARN"
        Connect-ExchangeOnline -ShowBanner:$false
    }
}

# ── Preflight ──────────────────────────────────────────────────────────────────

Write-Status "Starting message trace | Range: $($StartDate.ToString('yyyy-MM-dd HH:mm')) → $($EndDate.ToString('yyyy-MM-dd HH:mm'))"

if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Write-Status "ExchangeOnlineManagement module not found. Install with: Install-Module ExchangeOnlineManagement" "ERROR"
    exit 1
}

Import-Module ExchangeOnlineManagement -ErrorAction SilentlyContinue
Assert-EXOConnected

# Validate date range
$maxDays = if ($HistoricalSearch) { 90 } else { 10 }
if (($EndDate - $StartDate).TotalDays -gt $maxDays) {
    Write-Status "Date range exceeds $maxDays days for this trace type. Use -HistoricalSearch for ranges > 10 days." "ERROR"
    exit 1
}

# Ensure output directory exists
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
$timestamp  = Get-Date -Format "yyyyMMdd-HHmm"
$csvPath    = Join-Path $OutputPath "MessageTrace-$timestamp.csv"
$detailPath = Join-Path $OutputPath "MessageTrace-Detail-$timestamp.csv"

# ── Build trace parameters ──────────────────────────────────────────────────────

$traceParams = @{
    StartDate = $StartDate
    EndDate   = $EndDate
    PageSize  = 5000
}

if ($MessageId)        { $traceParams["MessageId"]        = $MessageId }
if ($SenderAddress)    { $traceParams["SenderAddress"]    = $SenderAddress }
if ($RecipientAddress) { $traceParams["RecipientAddress"] = $RecipientAddress }
if ($Subject)          { $traceParams["Subject"]          = $Subject }

# ── Historical Search path ──────────────────────────────────────────────────────

if ($HistoricalSearch) {
    Write-Status "Submitting Historical Search job (async — results may take hours)" "WARN"

    $jobName = "MsgTrace-$timestamp"
    $searchParams = $traceParams.Clone()
    $searchParams.Remove("PageSize")
    $searchParams["ReportTitle"]      = $jobName
    $searchParams["ReportType"]       = "MessageTrace"
    $searchParams["NotifyAddress"]    = (Get-EXOMailbox -ResultSize 1).PrimarySmtpAddress  # admin mailbox

    Start-HistoricalSearch @searchParams | Out-Null

    Write-Status "Job '$jobName' submitted. Check status with:" "OK"
    Write-Status "  Get-HistoricalSearch -JobId <id>" "INFO"
    Write-Status "  Results emailed to your mailbox when complete." "INFO"
    exit 0
}

# ── Standard trace — paginated retrieval ───────────────────────────────────────

Write-Status "Running standard trace (paged)..."
$allResults = [System.Collections.Generic.List[object]]::new()
$page       = 1

do {
    Write-Status "  Fetching page $page..." "INFO"
    $traceParams["Page"] = $page
    $batch = Get-MessageTrace @traceParams

    if ($batch) {
        $allResults.AddRange([object[]]$batch)
        Write-Status "  Page $page: $($batch.Count) records (total: $($allResults.Count))" "OK"
    }

    $page++
} while ($batch -and $batch.Count -eq 5000)

Write-Status "Trace complete. Total messages: $($allResults.Count)" "OK"

if ($allResults.Count -eq 0) {
    Write-Status "No messages found matching the criteria." "WARN"
    exit 0
}

# ── Summarise ──────────────────────────────────────────────────────────────────

$summary = $allResults | Group-Object -Property Status | Sort-Object Count -Descending
Write-Host ""
Write-Host "=== Delivery Status Breakdown ===" -ForegroundColor Cyan
$summary | ForEach-Object {
    $colour = switch ($_.Name) {
        "Delivered"  { "Green"  }
        "Failed"     { "Red"    }
        "Pending"    { "Yellow" }
        "Quarantined"{ "Yellow" }
        "FilteredAsSpam" { "Magenta" }
        default      { "White"  }
    }
    Write-Host ("  {0,-20} {1,6}" -f $_.Name, $_.Count) -ForegroundColor $colour
}
Write-Host ""

# Failed messages detail
$failed = $allResults | Where-Object { $_.Status -eq "Failed" }
if ($failed) {
    Write-Status "$($failed.Count) FAILED message(s) — review in CSV" "WARN"
    $failed | ForEach-Object {
        Write-Host "  FAILED: $($_.SenderAddress) → $($_.RecipientAddress) | $($_.Subject) | $($_.ToIP)" -ForegroundColor Red
    }
    Write-Host ""
}

# ── Export main CSV ────────────────────────────────────────────────────────────

$allResults | Select-Object `
    Received, SenderAddress, RecipientAddress, Subject, Status,
    ToIP, FromIP, Size, MessageId, MessageTraceId `
  | Export-Csv -Path $csvPath -NoTypeInformation

Write-Status "Exported $($allResults.Count) records → $csvPath" "OK"

# ── Optional: per-message event detail ─────────────────────────────────────────

if ($DetailedEvents) {
    Write-Status "Fetching per-message event detail (this may take a while for large result sets)..." "WARN"
    $detailResults = [System.Collections.Generic.List[object]]::new()
    $i = 0

    foreach ($msg in $allResults) {
        $i++
        if ($i % 50 -eq 0) { Write-Status "  Detail progress: $i / $($allResults.Count)" "INFO" }

        try {
            $events = Get-MessageTraceDetail `
                -MessageTraceId $msg.MessageTraceId `
                -RecipientAddress $msg.RecipientAddress

            foreach ($evt in $events) {
                $detailResults.Add([PSCustomObject]@{
                    MessageTraceId  = $msg.MessageTraceId
                    Sender          = $msg.SenderAddress
                    Recipient       = $msg.RecipientAddress
                    Subject         = $msg.Subject
                    EventDate       = $evt.Date
                    Event           = $evt.Event
                    Action          = $evt.Action
                    Detail          = $evt.Detail
                })
            }
        }
        catch {
            Write-Status "  Could not retrieve detail for $($msg.MessageTraceId): $_" "WARN"
        }
    }

    $detailResults | Export-Csv -Path $detailPath -NoTypeInformation
    Write-Status "Event detail exported ($($detailResults.Count) events) → $detailPath" "OK"
}

# ── Final report ───────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== Trace Summary ===" -ForegroundColor Cyan
Write-Host "  Messages traced : $($allResults.Count)"
Write-Host "  Date range      : $($StartDate.ToString('yyyy-MM-dd HH:mm')) → $($EndDate.ToString('yyyy-MM-dd HH:mm'))"
Write-Host "  Main CSV        : $csvPath"
if ($DetailedEvents) { Write-Host "  Event detail    : $detailPath" }

# Top senders
Write-Host ""
Write-Host "  Top 5 senders:" -ForegroundColor Cyan
$allResults | Group-Object SenderAddress | Sort-Object Count -Descending |
    Select-Object -First 5 |
    ForEach-Object { Write-Host ("    {0,-40} {1,5}" -f $_.Name, $_.Count) }

# Top recipients
Write-Host ""
Write-Host "  Top 5 recipients:" -ForegroundColor Cyan
$allResults | Group-Object RecipientAddress | Sort-Object Count -Descending |
    Select-Object -First 5 |
    ForEach-Object { Write-Host ("    {0,-40} {1,5}" -f $_.Name, $_.Count) }

Write-Host ""
Write-Status "Done." "OK"
