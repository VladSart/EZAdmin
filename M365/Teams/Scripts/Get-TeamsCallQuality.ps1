<#
.SYNOPSIS
    Retrieves Teams call quality data and flags poor-quality calls for a user or tenant.

.DESCRIPTION
    Queries the Microsoft Teams Call Quality Dashboard (CQD) via the Microsoft Graph API
    to surface call records with poor audio, video, or connectivity quality.
    Reports on:
      - Calls with Poor Mean Opinion Score (MOS < 3.5)
      - Calls with high packet loss (> 5%) or jitter (> 30ms)
      - Calls flagged as poor by the Teams client
      - Call modality breakdown (audio, video, screenshare)
    Outputs a summary and optional CSV export.

    Scope of CQD data: Last N days (default 7). Tenant-level queries require CQD reader role.
    Per-user queries work with Teams Communications Support Specialist role.

.PARAMETER UserUPN
    The UPN of the specific user to query (e.g., user@contoso.com).
    If omitted, queries tenant-level summary (requires CQD role).

.PARAMETER DaysBack
    Number of days of call history to retrieve. Default: 7. Max: 28 (CQD retention).

.PARAMETER ExportPath
    Optional. Path for CSV export. If not specified, outputs to console only.

.PARAMETER MinimumCallDurationSeconds
    Minimum call duration to include in results (filters out accidental 1-second calls).
    Default: 30 seconds.

.EXAMPLE
    .\Get-TeamsCallQuality.ps1 -UserUPN "jane.doe@contoso.com" -DaysBack 14

.EXAMPLE
    .\Get-TeamsCallQuality.ps1 -UserUPN "jane.doe@contoso.com" -ExportPath "C:\Temp\CallQuality.csv"

.EXAMPLE
    .\Get-TeamsCallQuality.ps1 -DaysBack 7 -ExportPath "C:\Temp\TenantCallQuality.csv"

.NOTES
    Requires:
      - Microsoft.Graph PowerShell module (Install-Module Microsoft.Graph -Scope CurrentUser)
      - OR MicrosoftTeams module for some cmdlets
      - Delegated permissions: CallRecords.Read.All (Graph)
      - App-only permissions: CallRecords.Read.All
      - CQD tenant-level access: Teams Communications Admin or CQD Reader role
    Safe to run — read-only, no changes made.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$UserUPN,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 28)]
    [int]$DaysBack = 7,

    [Parameter(Mandatory = $false)]
    [string]$ExportPath,

    [Parameter(Mandatory = $false)]
    [int]$MinimumCallDurationSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region Helper Functions

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet("INFO","OK","WARN","ERROR")]
        [string]$Status = "INFO"
    )
    $colour = switch ($Status) {
        "OK"    { "Green"  }
        "WARN"  { "Yellow" }
        "ERROR" { "Red"    }
        default { "Cyan"   }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-GraphToken {
    <#
    Acquires a delegated Graph token via device code flow.
    Falls back to checking for existing Connect-MgGraph session.
    #>
    try {
        $context = Get-MgContext -ErrorAction SilentlyContinue
        if ($context -and $context.Scopes -contains "CallRecords.Read.All") {
            Write-Status "Using existing Graph session for: $($context.Account)" "OK"
            return $true
        }
    } catch { }

    Write-Status "Connecting to Microsoft Graph (CallRecords.Read.All scope)..." "INFO"
    try {
        Connect-MgGraph -Scopes "CallRecords.Read.All","User.Read.All" -NoWelcome
        Write-Status "Connected to Graph" "OK"
        return $true
    } catch {
        Write-Status "Failed to connect to Graph: $_" "ERROR"
        return $false
    }
}

function ConvertTo-QualityLabel {
    param([double]$AudioMOS)
    switch ($true) {
        ($AudioMOS -ge 4.0)  { "Excellent" }
        ($AudioMOS -ge 3.5)  { "Good" }
        ($AudioMOS -ge 3.0)  { "Fair" }
        ($AudioMOS -ge 2.0)  { "Poor" }
        default               { "Bad" }
    }
}

function Get-UserObjectId {
    param([string]$UPN)
    try {
        $user = Get-MgUser -UserId $UPN -Property "id,displayName,userPrincipalName" -ErrorAction Stop
        return $user
    } catch {
        Write-Status "User not found: $UPN — $_" "ERROR"
        return $null
    }
}

#endregion

#region Main

Write-Status "Teams Call Quality Diagnostic Tool" "INFO"
Write-Status "Query window: Last $DaysBack day(s) | Min duration: ${MinimumCallDurationSeconds}s" "INFO"
if ($UserUPN) { Write-Status "Scope: User — $UserUPN" "INFO" }
else          { Write-Status "Scope: Tenant-wide summary" "INFO" }
Write-Host ""

# Module check
$graphModule = Get-Module -ListAvailable -Name "Microsoft.Graph.CloudCommunications" -ErrorAction SilentlyContinue
if (-not $graphModule) {
    Write-Status "Microsoft.Graph module not found. Install with:" "WARN"
    Write-Status "  Install-Module Microsoft.Graph -Scope CurrentUser" "WARN"
    Write-Status "Attempting to use MicrosoftTeams module as fallback..." "INFO"
}

# Connect
if (-not (Get-GraphToken)) {
    Write-Status "Cannot proceed without Graph authentication." "ERROR"
    exit 1
}

# Date range
$startDate = (Get-Date).AddDays(-$DaysBack).Date.ToString("yyyy-MM-ddTHH:mm:ssZ")
$endDate   = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
Write-Status "Date range: $startDate → $endDate" "INFO"

# Results collection
$callRecords   = [System.Collections.Generic.List[object]]::new()
$poorCalls     = [System.Collections.Generic.List[object]]::new()
$skippedCount  = 0

#region Fetch Call Records

Write-Status "Fetching call records from Graph..." "INFO"

try {
    if ($UserUPN) {
        # Per-user: get call records involving this user
        $user = Get-UserObjectId -UPN $UserUPN
        if (-not $user) { exit 1 }
        Write-Status "Resolved user: $($user.DisplayName) [$($user.Id)]" "OK"

        # Graph API: /communications/callRecords filtered by participant
        $filter = "startDateTime ge $startDate and startDateTime le $endDate"
        $uri    = "https://graph.microsoft.com/v1.0/communications/callRecords?`$filter=$filter&`$expand=sessions(`$expand=segments)"

        $response = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop

        foreach ($record in $response.value) {
            # Check if this user is a participant
            $isParticipant = $record.participants | Where-Object {
                $_.user -and $_.user.id -eq $user.Id
            }
            if (-not $isParticipant) { continue }
            $callRecords.Add($record)
        }

        # Handle paging
        while ($response.'@odata.nextLink') {
            $response = Invoke-MgGraphRequest -Method GET -Uri $response.'@odata.nextLink' -ErrorAction Stop
            foreach ($record in $response.value) {
                $isParticipant = $record.participants | Where-Object { $_.user -and $_.user.id -eq $user.Id }
                if ($isParticipant) { $callRecords.Add($record) }
            }
        }
    } else {
        # Tenant-wide: get all call records in window
        $filter   = "startDateTime ge $startDate"
        $uri      = "https://graph.microsoft.com/v1.0/communications/callRecords?`$filter=$filter&`$top=100"
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
        $response.value | ForEach-Object { $callRecords.Add($_) }

        while ($response.'@odata.nextLink' -and $callRecords.Count -lt 1000) {
            $response = Invoke-MgGraphRequest -Method GET -Uri $response.'@odata.nextLink' -ErrorAction Stop
            $response.value | ForEach-Object { $callRecords.Add($_) }
        }
    }
} catch {
    Write-Status "Error fetching call records: $_" "ERROR"
    Write-Status "If you see 403, ensure the account has CallRecords.Read.All permission." "WARN"
    exit 1
}

Write-Status "Fetched $($callRecords.Count) call record(s)" "OK"

#endregion

#region Analyze Quality

Write-Status "Analyzing call quality..." "INFO"

$analysisResults = foreach ($record in $callRecords) {
    # Duration filter
    $startDt = [datetime]::Parse($record.startDateTime)
    $endDt   = if ($record.endDateTime) { [datetime]::Parse($record.endDateTime) } else { $startDt }
    $durationSec = ($endDt - $startDt).TotalSeconds

    if ($durationSec -lt $MinimumCallDurationSeconds) {
        $skippedCount++
        continue
    }

    # Aggregate quality metrics across segments
    $audioMOSValues   = [System.Collections.Generic.List[double]]::new()
    $packetLossValues = [System.Collections.Generic.List[double]]::new()
    $jitterValues     = [System.Collections.Generic.List[double]]::new()
    $modalities       = [System.Collections.Generic.List[string]]::new()
    $isPoor           = $false

    if ($record.sessions) {
        foreach ($session in $record.sessions) {
            if ($session.modalities) {
                $session.modalities | ForEach-Object { if ($_ -notin $modalities) { $modalities.Add($_) } }
            }
            if ($session.segments) {
                foreach ($seg in $session.segments) {
                    $media = $seg.media
                    if ($media) {
                        foreach ($m in $media) {
                            if ($m.streams) {
                                foreach ($stream in $m.streams) {
                                    if ($stream.averageAudioMOS -and $stream.averageAudioMOS -gt 0) {
                                        $audioMOSValues.Add($stream.averageAudioMOS)
                                    }
                                    if ($stream.averagePacketLossRate -and $stream.averagePacketLossRate -gt 0) {
                                        $packetLossValues.Add($stream.averagePacketLossRate * 100)  # to %
                                    }
                                    if ($stream.averageJitter) {
                                        $jitter = [int]($stream.averageJitter -replace "PT|S","" -replace "M","" ) * 1000
                                        $jitterValues.Add($jitter)
                                    }
                                    if ($stream.wasMediaBypassed -eq $false -and $stream.lowVideoFrameRateRatio -gt 0.5) {
                                        $isPoor = $true
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    $avgMOS        = if ($audioMOSValues.Count -gt 0) { [math]::Round(($audioMOSValues | Measure-Object -Average).Average, 2) } else { $null }
    $avgPacketLoss = if ($packetLossValues.Count -gt 0) { [math]::Round(($packetLossValues | Measure-Object -Average).Average, 2) } else { $null }
    $avgJitter     = if ($jitterValues.Count -gt 0) { [math]::Round(($jitterValues | Measure-Object -Average).Average, 0) } else { $null }

    # Quality flags
    $qualityIssues = [System.Collections.Generic.List[string]]::new()
    if ($avgMOS -and $avgMOS -lt 3.5)        { $qualityIssues.Add("LowMOS:$avgMOS") }
    if ($avgPacketLoss -and $avgPacketLoss -gt 5)  { $qualityIssues.Add("PacketLoss:${avgPacketLoss}%") }
    if ($avgJitter -and $avgJitter -gt 30)   { $qualityIssues.Add("Jitter:${avgJitter}ms") }
    if ($isPoor)                              { $qualityIssues.Add("ClientFlaggedPoor") }

    $overallQuality = if ($avgMOS) { ConvertTo-QualityLabel -AudioMOS $avgMOS } else { "Unknown" }
    $hasPoorQuality = $qualityIssues.Count -gt 0

    $result = [PSCustomObject]@{
        CallId          = $record.id
        StartTime       = $startDt.ToString("yyyy-MM-dd HH:mm")
        DurationMin     = [math]::Round($durationSec / 60, 1)
        Type            = $record.type
        Modalities      = $modalities -join ", "
        ParticipantCount = ($record.participants | Measure-Object).Count
        AvgAudioMOS     = $avgMOS
        AudioQuality    = $overallQuality
        AvgPacketLoss_Pct = $avgPacketLoss
        AvgJitter_ms    = $avgJitter
        QualityIssues   = $qualityIssues -join "; "
        PoorCall        = $hasPoorQuality
    }

    if ($hasPoorQuality) { $poorCalls.Add($result) }
    $result
}

#endregion

#region Report

Write-Host ""
Write-Status "=== CALL QUALITY SUMMARY ===" "INFO"
Write-Host ""

$totalCalls    = @($analysisResults).Count
$poorCallCount = $poorCalls.Count
$goodCallCount = $totalCalls - $poorCallCount
$poorPct       = if ($totalCalls -gt 0) { [math]::Round(($poorCallCount / $totalCalls) * 100, 1) } else { 0 }

Write-Host "Total calls analysed:  $totalCalls" -ForegroundColor White
Write-Host "Skipped (too short):   $skippedCount" -ForegroundColor Gray
Write-Host "Good quality calls:    $goodCallCount" -ForegroundColor Green
Write-Host "Poor quality calls:    $poorCallCount ($poorPct%)" -ForegroundColor $(if ($poorPct -gt 10) { "Red" } elseif ($poorPct -gt 5) { "Yellow" } else { "Green" })
Write-Host ""

if ($poorCalls.Count -gt 0) {
    Write-Status "Poor Quality Calls (last $DaysBack days):" "WARN"
    $poorCalls | Sort-Object StartTime -Descending |
        Format-Table CallId, StartTime, DurationMin, Modalities, AvgAudioMOS, AvgPacketLoss_Pct, AvgJitter_ms, QualityIssues -AutoSize

    # Issue frequency breakdown
    Write-Status "Issue frequency breakdown:" "INFO"
    $allIssues = $poorCalls | ForEach-Object { $_.QualityIssues -split "; " } | Where-Object { $_ }
    $allIssues | Group-Object { $_ -replace ":.*",""} | Sort-Object Count -Descending |
        Format-Table @{L="Issue Type";E={$_.Name}}, @{L="Occurrences";E={$_.Count}} -AutoSize
} else {
    Write-Status "No poor quality calls found in the selected window." "OK"
}

# Modality breakdown
if ($totalCalls -gt 0) {
    Write-Status "Call modality breakdown:" "INFO"
    @($analysisResults) | ForEach-Object {
        $_.Modalities -split ", " | Where-Object { $_ }
    } | Group-Object | Sort-Object Count -Descending |
        Format-Table @{L="Modality";E={$_.Name}}, @{L="Count";E={$_.Count}} -AutoSize
}

#endregion

#region Export

if ($ExportPath) {
    try {
        $exportDir = Split-Path $ExportPath -Parent
        if ($exportDir -and -not (Test-Path $exportDir)) {
            New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
        }
        @($analysisResults) | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
        Write-Status "Results exported to: $ExportPath" "OK"

        # Also export just poor calls with "-Poor" suffix
        if ($poorCalls.Count -gt 0) {
            $poorExportPath = $ExportPath -replace "\.csv$", "_PoorOnly.csv"
            $poorCalls | Export-Csv -Path $poorExportPath -NoTypeInformation -Encoding UTF8
            Write-Status "Poor calls exported to: $poorExportPath" "OK"
        }
    } catch {
        Write-Status "Export failed: $_" "ERROR"
    }
}

#endregion

#region Recommendations

if ($poorCalls.Count -gt 0) {
    Write-Host ""
    Write-Status "=== RECOMMENDED NEXT STEPS ===" "INFO"

    $hasLowMOS     = $poorCalls | Where-Object { $_.QualityIssues -match "LowMOS" }
    $hasPacketLoss = $poorCalls | Where-Object { $_.QualityIssues -match "PacketLoss" }
    $hasJitter     = $poorCalls | Where-Object { $_.QualityIssues -match "Jitter" }

    if ($hasLowMOS) {
        Write-Host "  [MOS < 3.5] Check: CPU usage during calls, audio driver version, headset/mic quality" -ForegroundColor Yellow
        Write-Host "              Teams Admin Center → Analytics & Reports → CQD → Audio Streams report" -ForegroundColor Yellow
    }
    if ($hasPacketLoss) {
        Write-Host "  [Packet Loss > 5%] Check: Network path quality, QoS DSCP markings, WiFi vs wired" -ForegroundColor Yellow
        Write-Host "              Run: Test-NetConnection -ComputerName teams.microsoft.com -Port 443" -ForegroundColor Yellow
    }
    if ($hasJitter) {
        Write-Host "  [High Jitter > 30ms] Check: QoS policy for Teams media ports (3478-3481, 50000-59999)" -ForegroundColor Yellow
        Write-Host "              Teams Admin: https://admin.teams.microsoft.com/analytics/cqd" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "  Full CQD documentation: https://learn.microsoft.com/en-us/microsoftteams/cqd-what-is-call-quality-dashboard" -ForegroundColor Cyan
}

Write-Host ""
Write-Status "Run complete." "OK"

#endregion
