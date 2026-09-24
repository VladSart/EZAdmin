<#
.SYNOPSIS
    Publisher retirement readiness: detects Publisher install type, inventories .pub files
    (local/UNC and optionally SharePoint/OneDrive), and optionally bulk-converts them to PDF/DOCX.

.DESCRIPTION
    Microsoft Publisher leaves Microsoft 365 on 1 October 2026 (subscribers can no longer open
    .pub files in Publisher). Perpetual Publisher support ends 13 October 2026 with Office LTSC
    2021. No Microsoft 365 app opens .pub files, so conversion must happen on a machine that
    still has a working, licensed Publisher.

    Stages:
      1. Preflight   — PowerShell edition (COM conversion requires Windows PowerShell 5.1),
                       Publisher binary + install type (subscription C2R vs perpetual), COM test.
      2. Detect      — recursive .pub inventory for each -Path; optional Microsoft Search
                       (Graph /search/query, driveItem, filetype:pub) for SharePoint/OneDrive.
      3. Execute     — only with -Convert: Publisher COM ExportAsFixedFormat -> PDF next to the
                       original (skips if target exists); -AlsoWord opens the PDF in Word and
                       saves .docx. Originals are never modified or deleted.
      4. Validate    — confirms each output file exists and is non-empty.
      5. Report      — inventory CSV + conversion log CSV.

    Does NOT convert SharePoint/OneDrive-only results directly (sync the library locally and
    run against the synced path). Microsoft Search returns only items the signed-in account can
    access and that are indexed — it is a broad sweep, not an exhaustive one.

.PARAMETER Path
    One or more local or UNC folders to scan recursively for *.pub.

.PARAMETER IncludeM365Search
    Also query Microsoft Search via Microsoft Graph for .pub driveItems (delegated
    Files.Read.All + Sites.Read.All; uses an existing Connect-MgGraph session or prompts).

.PARAMETER MaxSearchResults
    Cap for Microsoft Search results. Default 1000.

.PARAMETER Convert
    Convert each local/UNC .pub to PDF in the same folder. Without this switch the script is read-only.

.PARAMETER AlsoWord
    With -Convert, also produce .docx from the PDF via Word (layout fidelity not guaranteed).

.PARAMETER OutputPath
    Folder for CSV output. Default: current directory.

.EXAMPLE
    .\Get-PublisherRetirementReadiness.ps1 -Path 'D:\Shares','\\fs01\Marketing'
    Read-only: install detection + inventory CSV.

.EXAMPLE
    .\Get-PublisherRetirementReadiness.ps1 -Path 'D:\Shares' -IncludeM365Search
    Adds SharePoint/OneDrive hits from Microsoft Search to the inventory.

.EXAMPLE
    powershell.exe -File .\Get-PublisherRetirementReadiness.ps1 -Path '\\fs01\Marketing' -Convert -AlsoWord
    Converts every .pub under the share to PDF and DOCX (Windows PowerShell 5.1 + Publisher + Word required).

.NOTES
    Requires: Windows; Windows PowerShell 5.1 for -Convert; Microsoft.Graph.Authentication for -IncludeM365Search.
    Run as: a user with read (and, for -Convert, write) access to the scanned paths. Elevation not required.
    Safe: default mode is read-only. -Convert is additive (writes new files, never deletes).
    Reference: https://support.microsoft.com/en-us/publisher/microsoft-publisher-will-no-longer-be-supported-after-october-2026
#>
[CmdletBinding()]
param(
    [string[]]$Path,
    [switch]$IncludeM365Search,
    [int]$MaxSearchResults = 1000,
    [switch]$Convert,
    [switch]$AlsoWord,
    [string]$OutputPath = (Get-Location).Path
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

if (-not $Path -and -not $IncludeM365Search) {
    throw "Specify -Path and/or -IncludeM365Search."
}
if ($AlsoWord -and -not $Convert) { throw "-AlsoWord requires -Convert." }
if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

# ---------------- Preflight: Publisher install ----------------
$installType = 'NotInstalled'
$mspub = $null
foreach ($candidate in @(
        (Join-Path $env:ProgramFiles 'Microsoft Office\root\Office16\MSPUB.EXE'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Office\root\Office16\MSPUB.EXE'),
        (Join-Path $env:ProgramFiles 'Microsoft Office\Office16\MSPUB.EXE'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Office\Office16\MSPUB.EXE'))) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) { $mspub = $candidate; break }
}
$c2r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
$productIds = ''
if ($c2r -and ($c2r.PSObject.Properties.Name -contains 'ProductReleaseIds')) { $productIds = [string]$c2r.ProductReleaseIds }

if ($mspub) {
    if ($productIds -match 'O365|M365|Microsoft365') { $installType = 'Subscription (C2R)' }
    elseif ($productIds -match '20(16|19|21)|Volume|Retail') { $installType = 'Perpetual (C2R)' }
    else { $installType = 'Perpetual (MSI or unknown)' }
}
Write-Status "Publisher binary: $(if ($mspub) { $mspub } else { 'not found' })"
Write-Status "Install type: $installType  (ProductReleaseIds: $(if ($productIds) { $productIds } else { 'n/a' }))"

$today = Get-Date
if ($installType -eq 'Subscription (C2R)' -and $today -ge [datetime]'2026-10-01') {
    Write-Status "Subscription Publisher is retired as of 1 Oct 2026 — conversion may fail here; use a perpetual-Publisher machine." "WARN"
} elseif ($installType -eq 'Subscription (C2R)') {
    Write-Status "Subscription Publisher works until 30 Sept 2026 — convert now." "WARN"
}

$comOk = $false
if ($Convert) {
    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        throw "-Convert requires Windows PowerShell 5.1 (powershell.exe). Office COM interop is unreliable in PowerShell 7."
    }
    if (-not $mspub) { throw "-Convert requires Microsoft Publisher on this machine." }
    try {
        $pubApp = New-Object -ComObject Publisher.Application
        Write-Status "Publisher COM OK (version $($pubApp.Version))" "OK"
        $comOk = $true
    } catch {
        throw "Publisher COM automation failed: $($_.Exception.Message)"
    }
    $wordApp = $null
    if ($AlsoWord) {
        try {
            $wordApp = New-Object -ComObject Word.Application
            $wordApp.Visible = $false
            $wordApp.DisplayAlerts = 0   # wdAlertsNone — suppress PDF reflow prompt
        } catch {
            $pubApp.Quit()
            throw "Word COM automation failed: $($_.Exception.Message)"
        }
    }
}

# ---------------- Detect ----------------
$inventory = New-Object System.Collections.Generic.List[object]

foreach ($p in @($Path | Where-Object { $_ })) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Status "Path not found, skipping: $p" "WARN"; continue }
    Write-Status "Scanning $p"
    Get-ChildItem -LiteralPath $p -Filter '*.pub' -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $owner = 'Unknown'
        try { $owner = (Get-Acl -LiteralPath $_.FullName).Owner } catch { }
        $pdf = [System.IO.Path]::ChangeExtension($_.FullName, '.pdf')
        $inventory.Add([pscustomobject]@{
            Source       = 'FileSystem'
            FileName     = $_.Name
            FullPath     = $_.FullName
            SizeKB       = [math]::Round($_.Length / 1KB, 1)
            Modified     = $_.LastWriteTime
            Owner        = $owner
            PdfExists    = (Test-Path -LiteralPath $pdf)
            WebUrl       = ''
        })
    }
}

if ($IncludeM365Search) {
    if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
        Write-Status "Microsoft.Graph.Authentication not installed — skipping M365 search (Install-Module Microsoft.Graph.Authentication)." "WARN"
    } else {
        if (-not (Get-MgContext)) { Connect-MgGraph -Scopes 'Files.Read.All','Sites.Read.All' -NoWelcome | Out-Null }
        $from = 0; $size = 25
        while ($from -lt $MaxSearchResults) {
            $body = @{ requests = @(@{
                entityTypes = @('driveItem'); query = @{ queryString = 'filetype:pub' }; from = $from; size = $size
            }) } | ConvertTo-Json -Depth 6
            try {
                $resp = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/search/query' -Body $body -ContentType 'application/json'
            } catch { Write-Status "Graph search failed: $($_.Exception.Message)" "ERROR"; break }
            $container = $resp.value[0].hitsContainers[0]
            $hits = @()
            if ($container.ContainsKey('hits') -and $container.hits) { $hits = @($container.hits) }
            if ($hits.Count -eq 0) { break }
            foreach ($h in $hits) {
                $r = $h.resource
                $inventory.Add([pscustomobject]@{
                    Source    = 'M365Search'
                    FileName  = $r.name
                    FullPath  = ''
                    SizeKB    = $(if ($r.ContainsKey('size') -and $r.size) { [math]::Round($r.size / 1KB, 1) } else { $null })
                    Modified  = $r.lastModifiedDateTime
                    Owner     = $(try { $r.lastModifiedBy.user.displayName } catch { '' })
                    PdfExists = $null
                    WebUrl    = $r.webUrl
                })
            }
            if (-not $container.moreResultsAvailable) { break }
            $from += $size
        }
    }
}

$invCsv = Join-Path $OutputPath "PublisherInventory_$stamp.csv"
$inventory | Sort-Object Source, FullPath, WebUrl | Export-Csv -Path $invCsv -NoTypeInformation -Encoding UTF8
$fsCount = @($inventory | Where-Object Source -eq 'FileSystem').Count
$m365Count = @($inventory | Where-Object Source -eq 'M365Search').Count
Write-Status "Inventory: $fsCount file-system + $m365Count M365 search hit(s) -> $invCsv" $(if ($inventory.Count) { 'WARN' } else { 'OK' })

# ---------------- Execute ----------------
if ($Convert -and $comOk) {
    $log = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($inventory | Where-Object Source -eq 'FileSystem')) {
        $pdf  = [System.IO.Path]::ChangeExtension($item.FullPath, '.pdf')
        $docx = [System.IO.Path]::ChangeExtension($item.FullPath, '.docx')
        $entry = [pscustomobject]@{ FullPath = $item.FullPath; Pdf = ''; Docx = ''; Status = 'Failed'; Error = '' }
        try {
            if (Test-Path -LiteralPath $pdf) {
                $entry.Pdf = $pdf; $entry.Status = 'SkippedPdfExists'
            } else {
                $doc = $pubApp.Open($item.FullPath, $true)      # ReadOnly
                try { $doc.ExportAsFixedFormat(2, $pdf) }        # 2 = pbFixedFormatTypePDF
                finally { $doc.Close() }
                $entry.Pdf = $pdf; $entry.Status = 'ConvertedPdf'
            }
            if ($AlsoWord -and -not (Test-Path -LiteralPath $docx)) {
                $wDoc = $wordApp.Documents.Open($pdf, $false, $true)   # ConfirmConversions=false, ReadOnly=true
                try { $wDoc.SaveAs2($docx, 16) }                       # 16 = wdFormatDocumentDefault (.docx)
                finally { $wDoc.Close(0) }                             # wdDoNotSaveChanges
                $entry.Docx = $docx
                $entry.Status = "$($entry.Status)+Docx"
            }
            # Validate
            foreach ($f in @($entry.Pdf, $entry.Docx) | Where-Object { $_ }) {
                if (-not (Test-Path -LiteralPath $f) -or (Get-Item -LiteralPath $f).Length -eq 0) {
                    throw "Output missing or empty: $f"
                }
            }
            Write-Status "$($entry.Status): $($item.FullPath)" "OK"
        } catch {
            $entry.Status = 'Failed'; $entry.Error = $_.Exception.Message
            Write-Status "Failed: $($item.FullPath) — $($entry.Error)" "ERROR"
        }
        $log.Add($entry)
    }
    try { $pubApp.Quit() } catch { }
    if ($wordApp) { try { $wordApp.Quit() } catch { } }
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($pubApp)

    $logCsv = Join-Path $OutputPath "PublisherConversionLog_$stamp.csv"
    $log | Export-Csv -Path $logCsv -NoTypeInformation -Encoding UTF8
    $failed = @($log | Where-Object Status -eq 'Failed').Count
    Write-Status "Conversion: $($log.Count - $failed) ok / $failed failed -> $logCsv" $(if ($failed) { 'WARN' } else { 'OK' })
}

# ---------------- Report ----------------
[pscustomobject]@{
    Computer          = $env:COMPUTERNAME
    PublisherInstall  = $installType
    PublisherPath     = $mspub
    FileSystemPubs    = $fsCount
    M365SearchPubs    = $m365Count
    WithoutPdfCopy    = @($inventory | Where-Object { $_.Source -eq 'FileSystem' -and -not $_.PdfExists }).Count
    InventoryCsv      = $invCsv
}
