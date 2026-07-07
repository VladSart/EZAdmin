<#
.SYNOPSIS
    One-shot Group Policy processing and SYSVOL/GPO replication health check.

.DESCRIPTION
    Collects client-side Group Policy processing state and (optionally) SYSVOL/GPO
    replication health from the domain side. Covers:
      - gpresult summary (applied/denied/filtered GPOs) for the local machine
      - Group Policy Operational log errors/warnings (last N events)
      - DFS client service state (SYSVOL access dependency)
      - DC locator / current logon server reachability
      - Time sync offset to the logon server (Kerberos dependency)
      - Optional: GPC (AD) vs GPT (SYSVOL) version comparison for one or more named GPOs
      - Optional: DFSR SYSVOL replication backlog summary (requires DC-side rights and RSAT-DFSR)

    Does not modify any Group Policy objects, links, or client state. Read-only diagnostic.
    Not a substitute for `gpresult /h` in a browser when doing deep, setting-level analysis —
    this script is for fast triage and evidence-pack collection.

.PARAMETER GpoNames
    One or more GPO display names to check GPC/GPT version agreement for. Optional.

.PARAMETER CheckDfsrBacklog
    Switch. If set, attempts a DFSR SYSVOL backlog check via dfsrdiag. Requires the
    RSAT DFS Management tools and appropriate rights on the domain controllers involved.

.PARAMETER OutputPath
    Folder to write the CSV/evidence output to. Defaults to $env:TEMP.

.EXAMPLE
    .\Get-GroupPolicyHealth.ps1
    Runs local client-side triage only (gpresult, event log, DFS client, time sync).

.EXAMPLE
    .\Get-GroupPolicyHealth.ps1 -GpoNames "Default Domain Policy","Baseline-Workstation" -CheckDfsrBacklog
    Also checks GPC/GPT version agreement for the two named GPOs and pulls DFSR SYSVOL backlog.

.NOTES
    Requires: RSAT Group Policy Management tools (Get-GPO cmdlet) for -GpoNames checks.
    Requires: RSAT DFS Management tools for -CheckDfsrBacklog.
    Run-as: standard user is sufficient for local-only checks; GPO/DFSR checks need
            read rights in AD and on the domain controllers queried.
    Safe: read-only, makes no configuration changes.
#>
[CmdletBinding()]
param(
    [string[]]$GpoNames,
    [switch]$CheckDfsrBacklog,
    [string]$OutputPath = $env:TEMP
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# --- Preflight ---------------------------------------------------------
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$reportFolder = Join-Path $OutputPath "GPHealth-$timestamp"
New-Item -Path $reportFolder -ItemType Directory -Force | Out-Null
Write-Status "Report folder: $reportFolder"

$results = [ordered]@{}

# --- 1. gpresult summary -------------------------------------------------
Write-Status "Collecting gpresult summary..."
try {
    $gpResultHtml = Join-Path $reportFolder "gpresult.html"
    gpresult /h $gpResultHtml /f 2>&1 | Out-Null
    if (Test-Path $gpResultHtml) {
        Write-Status "gpresult HTML report saved: $gpResultHtml" "OK"
        $results["GpResultReport"] = $gpResultHtml
    } else {
        Write-Status "gpresult did not produce a report" "WARN"
    }

    $gpResultText = gpresult /r 2>&1
    $gpResultText | Out-File (Join-Path $reportFolder "gpresult-summary.txt")

    $deniedCount = ($gpResultText | Select-String -Pattern "Denied|Filtered" -SimpleMatch:$false).Count
    if ($deniedCount -gt 0) {
        Write-Status "Found $deniedCount line(s) referencing Denied/Filtered GPOs — review gpresult-summary.txt" "WARN"
    } else {
        Write-Status "No obvious Denied/Filtered references in gpresult text summary" "OK"
    }
    $results["DeniedOrFilteredReferences"] = $deniedCount
} catch {
    Write-Status "gpresult collection failed: $($_.Exception.Message)" "ERROR"
    $results["DeniedOrFilteredReferences"] = "ERROR"
}

# --- 2. Group Policy Operational log -------------------------------------
Write-Status "Scanning Group Policy Operational log for errors/warnings..."
try {
    $gpEvents = Get-WinEvent -LogName "Microsoft-Windows-GroupPolicy/Operational" -MaxEvents 500 -ErrorAction Stop |
        Where-Object { $_.LevelDisplayName -in 'Error', 'Warning' }

    $criticalIds = 1058, 1030, 1096, 1129
    $criticalEvents = $gpEvents | Where-Object { $_.Id -in $criticalIds }

    $gpEvents | Select-Object TimeCreated, Id, LevelDisplayName, Message |
        Export-Csv (Join-Path $reportFolder "gpo-operational-log.csv") -NoTypeInformation

    if ($criticalEvents.Count -gt 0) {
        Write-Status "Found $($criticalEvents.Count) known-critical event(s) (1058/1030/1096/1129) — see CSV" "WARN"
    } else {
        Write-Status "No 1058/1030/1096/1129 events in last 500 log entries" "OK"
    }
    $results["CriticalEventCount"] = $criticalEvents.Count
    $results["TotalErrorWarningEvents"] = $gpEvents.Count
} catch {
    Write-Status "Could not read Group Policy Operational log: $($_.Exception.Message)" "ERROR"
    $results["CriticalEventCount"] = "ERROR"
}

# --- 3. DFS client service (SYSVOL access dependency) --------------------
Write-Status "Checking DFS client service state..."
try {
    $dfsSvc = Get-Service -Name DFS -ErrorAction Stop
    if ($dfsSvc.Status -eq 'Running') {
        Write-Status "DFS client service running" "OK"
    } else {
        Write-Status "DFS client service status: $($dfsSvc.Status) — SYSVOL access may fail" "WARN"
    }
    $results["DfsClientStatus"] = $dfsSvc.Status
} catch {
    Write-Status "Could not query DFS service: $($_.Exception.Message)" "ERROR"
    $results["DfsClientStatus"] = "ERROR"
}

# --- 4. DC locator / reachability ----------------------------------------
Write-Status "Checking DC locator..."
try {
    $domain = $env:USERDNSDOMAIN
    if (-not $domain) { throw "USERDNSDOMAIN environment variable not set — machine may not be domain-joined" }
    $dsGetDc = nltest /dsgetdc:$domain 2>&1
    $dsGetDc | Out-File (Join-Path $reportFolder "dc-locator.txt")
    $dcLine = $dsGetDc | Select-String -Pattern "DC:" | Select-Object -First 1
    if ($dcLine) {
        Write-Status "Located DC: $($dcLine.ToString().Trim())" "OK"
        $results["LocatedDC"] = $dcLine.ToString().Trim()
    } else {
        Write-Status "nltest did not return a clear DC record — see dc-locator.txt" "WARN"
        $results["LocatedDC"] = "UNKNOWN"
    }
} catch {
    Write-Status "DC locator check failed: $($_.Exception.Message)" "ERROR"
    $results["LocatedDC"] = "ERROR"
}

# --- 5. Time sync offset (Kerberos dependency) ----------------------------
Write-Status "Checking time sync offset to logon server..."
try {
    $logonServer = $env:LOGONSERVER -replace '\\', ''
    if ($logonServer) {
        $timeCheck = w32tm /stripchart /computer:$logonServer /samples:2 /dataonly 2>&1
        $timeCheck | Out-File (Join-Path $reportFolder "time-sync.txt")
        Write-Status "Time sync check against $logonServer written to time-sync.txt — review for offset magnitude" "OK"
        $results["TimeSyncTarget"] = $logonServer
    } else {
        Write-Status "No LOGONSERVER environment variable available — skipping time sync check" "WARN"
        $results["TimeSyncTarget"] = "SKIPPED"
    }
} catch {
    Write-Status "Time sync check failed: $($_.Exception.Message)" "ERROR"
    $results["TimeSyncTarget"] = "ERROR"
}

# --- 6. Optional: GPC (AD) vs GPT (SYSVOL) version comparison ------------
if ($GpoNames) {
    Write-Status "Checking GPC/GPT version agreement for $($GpoNames.Count) named GPO(s)..."
    $gpoVersionResults = foreach ($name in $GpoNames) {
        try {
            $gpo = Get-GPO -Name $name -ErrorAction Stop
            $gptPath = "\\$env:USERDNSDOMAIN\SysVol\$env:USERDNSDOMAIN\Policies\{$($gpo.Id)}\gpt.ini"
            $gptContent = Get-Content $gptPath -ErrorAction SilentlyContinue
            $gptVersionLine = $gptContent | Select-String -Pattern "^Version="

            [pscustomobject]@{
                GpoName        = $name
                GpoId          = $gpo.Id
                AdUserVersion  = $gpo.User.DSVersion
                AdCompVersion  = $gpo.Computer.DSVersion
                GptVersionLine = if ($gptVersionLine) { $gptVersionLine.ToString() } else { "NOT FOUND" }
                Mismatch       = if (-not $gptVersionLine) { "UNKNOWN - GPT unreadable" } else { "Manual comparison required" }
            }
        } catch {
            [pscustomobject]@{
                GpoName        = $name
                GpoId          = "ERROR"
                AdUserVersion  = "ERROR"
                AdCompVersion  = "ERROR"
                GptVersionLine = "ERROR"
                Mismatch       = $_.Exception.Message
            }
        }
    }
    $gpoVersionResults | Export-Csv (Join-Path $reportFolder "gpo-version-check.csv") -NoTypeInformation
    Write-Status "GPO version check written to gpo-version-check.csv — compare AdUserVersion/AdCompVersion against GptVersionLine manually" "OK"
} else {
    Write-Status "No -GpoNames supplied — skipping GPC/GPT version comparison" "INFO"
}

# --- 7. Optional: DFSR SYSVOL backlog ------------------------------------
if ($CheckDfsrBacklog) {
    Write-Status "Checking DFSR SYSVOL replication state..."
    try {
        $dfsrState = dfsrdiag replicationstate 2>&1
        $dfsrState | Out-File (Join-Path $reportFolder "dfsr-replicationstate.txt")
        Write-Status "DFSR replication state written to dfsr-replicationstate.txt" "OK"
        $results["DfsrBacklogChecked"] = $true
    } catch {
        Write-Status "dfsrdiag not available or failed: $($_.Exception.Message) — requires RSAT DFS Management tools" "WARN"
        $results["DfsrBacklogChecked"] = "UNAVAILABLE"
    }
} else {
    Write-Status "Skipping DFSR backlog check (-CheckDfsrBacklog not specified)" "INFO"
}

# --- Report ---------------------------------------------------------------
$summary = [pscustomobject]$results
$summary | Export-Csv (Join-Path $reportFolder "summary.csv") -NoTypeInformation

Write-Status "----------------------------------------"
Write-Status "Group Policy health check complete."
Write-Status "Full report folder: $reportFolder" "OK"
$summary | Format-List
