<#
.SYNOPSIS
    Audits VSS writer state, shadow storage headroom, service health, and
    recent VSS-related event log errors.

.DESCRIPTION
    Read-only diagnostic script for the VSS-A.md and VSS-B.md runbooks.
    Run on the server where VSS/backup issues are being investigated, with
    local Administrator rights.

    Covers:
      1. VSS / COM+ Event System service state
      2. Writer inventory and state (parsed from vssadmin list writers)
      3. Shadow storage allocation vs. usage, per volume
      4. Registered VSS providers
      5. Recent VSS/writer-specific Application-log errors (including
         SQLWRITER/SQLVDI, which flag SQL Server as the likely root cause)

    Does NOT create, delete, or resize any shadow copy; does NOT restart
    any service — findings only. vssadmin output is parsed as text since
    there is no built-in PowerShell cmdlet equivalent for writer state.

.PARAMETER ShadowStorageWarnPercent
    Percentage of Maximum Shadow Copy Storage at which Used storage is
    flagged as a WARN finding. Default: 80.

.PARAMETER OutputPath
    Folder to write CSV output to. Default: current directory.

.EXAMPLE
    .\Get-VSSWriterHealth.ps1
    Runs a standard local audit with the default 80% shadow-storage threshold.

.EXAMPLE
    .\Get-VSSWriterHealth.ps1 -ShadowStorageWarnPercent 70 -OutputPath C:\VSS-Audit
    Flags shadow storage at 70%+ usage, output to C:\VSS-Audit.

.NOTES
    Requires: vssadmin.exe (built into Windows). No additional PowerShell
    module required.
    Run-as: local Administrator (vssadmin requires elevation for most
    subcommands used here).
    Safe: read-only. No shadow copies are created, deleted, or resized,
    and no services are restarted.
#>

[CmdletBinding()]
param(
    [ValidateRange(1,99)]
    [int]$ShadowStorageWarnPercent = 80,
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$findings = New-Object System.Collections.Generic.List[PSObject]
function Add-Finding {
    param([string]$Category, [string]$Item, [string]$Status, [string]$Detail)
    $findings.Add([PSCustomObject]@{
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Category  = $Category
        Item      = $Item
        Status    = $Status
        Detail    = $Detail
    })
    Write-Status "$Category | $Item — $Detail" -Status $Status
}

if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

Write-Status "=== VSS Writer & Shadow Storage Health Audit ===" -Status "INFO"

#region --- 1. Core service state ---
Write-Status "`n=== VSS Service Dependency Chain ===" -Status "INFO"
try {
    $vss = Get-Service -Name VSS -ErrorAction Stop
    # Manual start type is the EXPECTED, healthy state for VSS — it runs on demand
    Add-Finding -Category "Service" -Item "VSS" -Status "OK" -Detail "Status: $($vss.Status), StartType: $($vss.StartType) (Manual is normal — VSS runs on demand)"
} catch {
    Add-Finding -Category "Service" -Item "VSS" -Status "ERROR" -Detail "Service not found or query failed: $($_.Exception.Message)"
}

try {
    $comPlus = Get-Service -Name "COM+ Event System" -ErrorAction Stop
    if ($comPlus.Status -eq "Running") {
        Add-Finding -Category "Service" -Item "COM+ Event System" -Status "OK" -Detail "Status: Running"
    } else {
        Add-Finding -Category "Service" -Item "COM+ Event System" -Status "ERROR" -Detail "Status: $($comPlus.Status) — VSS coordination depends on this service"
    }
} catch {
    Add-Finding -Category "Service" -Item "COM+ Event System" -Status "WARN" -Detail "Service query failed: $($_.Exception.Message)"
}
#endregion

#region --- 2. Writer inventory and state (parsed from vssadmin) ---
Write-Status "`n=== VSS Writers ===" -Status "INFO"
try {
    $writerOutput = & vssadmin list writers 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $writerOutput) {
        Add-Finding -Category "Writers" -Item "(vssadmin)" -Status "ERROR" -Detail "vssadmin list writers returned no usable output — VSS/COM+ registration likely broken"
    } else {
        $text = $writerOutput -join "`n"
        # Each writer block: "Writer name: '<name>'" ... "State: [n] <state>" ... "Last error: <error>"
        $blocks = ($text -split "(?=Writer name:)") | Where-Object { $_ -match "Writer name:" }
        if (-not $blocks) {
            Add-Finding -Category "Writers" -Item "(none)" -Status "ERROR" -Detail "No writers registered — VSS/COM+ Event System registration problem, not an application-specific issue"
        }
        foreach ($block in $blocks) {
            $name  = if ($block -match "Writer name:\s*'([^']+)'") { $matches[1] } else { "(unknown)" }
            $state = if ($block -match "State:\s*\[(\d+)\]\s*([A-Za-z ]+)") { "$($matches[1]) $($matches[2])".Trim() } else { "(unparsed)" }
            $err   = if ($block -match "Last error:\s*(.+)") { $matches[1].Trim() } else { "(unparsed)" }

            if ($state -match "^1\b" -and $err -match "No error") {
                Add-Finding -Category "Writers" -Item $name -Status "OK" -Detail "State: $state, Last error: $err"
            } else {
                Add-Finding -Category "Writers" -Item $name -Status "ERROR" -Detail "State: $state, Last error: $err — restart the OWNING application service, not VSS itself"
            }
        }
    }
} catch {
    Add-Finding -Category "Writers" -Item "(error)" -Status "ERROR" -Detail "vssadmin list writers failed: $($_.Exception.Message)"
}
#endregion

#region --- 3. Shadow storage headroom ---
Write-Status "`n=== Shadow Storage ===" -Status "INFO"
try {
    $storageOutput = & vssadmin list shadowstorage 2>&1
    $text = $storageOutput -join "`n"
    $blocks = ($text -split "(?=Shadow Copy Storage volume:)") | Where-Object { $_ -match "Shadow Copy Storage volume:" }
    if (-not $blocks) {
        Add-Finding -Category "ShadowStorage" -Item "(none)" -Status "WARN" -Detail "No shadow storage associations found — shadow copies may never have been created on this host"
    }
    foreach ($block in $blocks) {
        $vol = if ($block -match "Used Shadow Copy Storage space:.*\(On (\S+)\)") { $matches[1] } else { "(unknown volume)" }
        $usedPct = if ($block -match "Used Shadow Copy Storage space:.*\((\d+)%\)") { [int]$matches[1] } else { $null }
        $maxLine = if ($block -match "Maximum Shadow Copy Storage space:\s*(.+)") { $matches[1].Trim() } else { "(unparsed)" }

        if ($null -eq $usedPct) {
            Add-Finding -Category "ShadowStorage" -Item $vol -Status "WARN" -Detail "Could not parse usage percentage — review raw vssadmin output. Maximum: $maxLine"
        } elseif ($usedPct -ge $ShadowStorageWarnPercent) {
            Add-Finding -Category "ShadowStorage" -Item $vol -Status "WARN" -Detail "Used: $usedPct% of maximum — oldest shadow copies may be purging; consider resizing. Maximum: $maxLine"
        } else {
            Add-Finding -Category "ShadowStorage" -Item $vol -Status "OK" -Detail "Used: $usedPct% of maximum. Maximum: $maxLine"
        }
    }
} catch {
    Add-Finding -Category "ShadowStorage" -Item "(error)" -Status "WARN" -Detail "vssadmin list shadowstorage failed: $($_.Exception.Message)"
}
#endregion

#region --- 4. Registered providers ---
Write-Status "`n=== VSS Providers ===" -Status "INFO"
try {
    $providerOutput = & vssadmin list providers 2>&1
    $text = $providerOutput -join "`n"
    $names = [regex]::Matches($text, "Provider name:\s*'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
    if (-not $names) {
        Add-Finding -Category "Providers" -Item "(none)" -Status "WARN" -Detail "No providers listed — unexpected, even the System Provider should normally appear"
    } else {
        foreach ($n in $names) {
            Add-Finding -Category "Providers" -Item $n -Status "OK" -Detail "Registered"
        }
    }
} catch {
    Add-Finding -Category "Providers" -Item "(error)" -Status "WARN" -Detail "vssadmin list providers failed: $($_.Exception.Message)"
}
#endregion

#region --- 5. Recent VSS/writer-specific Application-log errors ---
Write-Status "`n=== Recent VSS-Related Application Log Errors ===" -Status "INFO"
try {
    $events = Get-WinEvent -LogName Application -MaxEvents 300 -ErrorAction Stop |
        Where-Object { $_.ProviderName -match "^(VSS|VolSnap|SQLWRITER|SQLVDI)$" -and $_.LevelDisplayName -eq "Error" }
    if ($events) {
        foreach ($e in $events | Select-Object -First 25) {
            $flag = if ($e.ProviderName -in @("SQLWRITER","SQLVDI")) { " [SQL Server VSS Writer implicated — see VSS-B.md Fix 3]" } else { "" }
            Add-Finding -Category "EventLog" -Item "$($e.ProviderName) / EventID $($e.Id)" -Status "WARN" -Detail "$($e.TimeCreated) — $($e.Message.Split("`n")[0])$flag"
        }
    } else {
        Add-Finding -Category "EventLog" -Item "VSS/writer sources" -Status "OK" -Detail "No matching Error events in the most recent 300 Application log entries"
    }
} catch {
    Add-Finding -Category "EventLog" -Item "(error)" -Status "WARN" -Detail "Get-WinEvent failed: $($_.Exception.Message)"
}
#endregion

#region --- Summary and export ---
$errorCount = ($findings | Where-Object Status -eq "ERROR").Count
$warnCount  = ($findings | Where-Object Status -eq "WARN").Count
Write-Status "`n=== Summary: $errorCount ERROR, $warnCount WARN out of $($findings.Count) checks ===" -Status $(if ($errorCount -gt 0) { "ERROR" } elseif ($warnCount -gt 0) { "WARN" } else { "OK" })

$csvPath = Join-Path $OutputPath "VSSWriterHealth_$(Get-Date -Format yyyyMMdd-HHmm).csv"
$findings | Export-Csv -Path $csvPath -NoTypeInformation
Write-Status "Findings exported to $csvPath" -Status "INFO"
#endregion
