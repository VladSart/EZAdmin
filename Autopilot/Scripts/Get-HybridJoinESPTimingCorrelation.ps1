<#
.SYNOPSIS
    Correlates Hybrid Azure AD Join registration timing against the Enrollment Status
    Page (ESP) timeout budget and the Entra Connect delta sync interval, to answer the
    single question both HybridJoin-Autopilot-A/B.md and ESP-Stuck-A.md flag as the
    hardest-to-diagnose HAADJ Autopilot failure: "did ESP time out because the device
    never got far enough into the sync window, or because the sync window itself is
    longer than the ESP timeout?"

.DESCRIPTION
    Run on the affected device AFTER Autopilot ESP has completed, failed, or is still
    stuck (in which case run from an admin cmd/PowerShell window per ESP-Stuck-A.md
    Fix 1's guidance on reaching a shell during ESP).

    What it does:
      1. Reads dsregcmd /status to establish current join state (DomainJoined /
         AzureAdJoined / EnterpriseJoined).
      2. Reads the "Automatic-Device-Join" scheduled task (HybridJoin-Autopilot-A.md
         Phase 3 Step 5) — this task is what performs Hybrid Join registration and
         retries on a short interval until the AD computer object becomes visible in
         Entra ID. Its run history is used as a proxy timeline for how long the device
         waited on Entra Connect sync, since Windows does not expose that wait
         directly.
      3. Scans the "Microsoft-Windows-User Device Registration/Admin" event log for
         event ID 304 (join succeeded) and 335 (join failed) per
         HybridJoin-Autopilot-B.md Step 5 / Symptom-Cause Map, to find the timestamp of
         the first attempt and the timestamp of eventual success (or ongoing failure).
      4. Scans the ESP/Autopilot diagnostic event logs (ESP-Stuck-A.md Validation Step
         1) to establish an approximate ESP start time.
      5. Computes: (a) how long Hybrid Join registration took to succeed after first
         attempted, and (b) how much of the configured ESP timeout budget that
         consumed.
      6. OPTIONAL — if -EntraConnectServer is supplied and reachable via
         Invoke-Command, queries the real configured delta sync interval via
         Get-ADSyncScheduler on that server (ADSync module) instead of assuming the
         30-minute product default that both runbooks cite.
      7. Flags risk conditions so an engineer can decide whether to fix the ESP
         timeout, the sync interval, or neither.

    Flags raised:
      JOIN_NOT_YET_SUCCEEDED         - No event ID 304 found; device may still be
                                        mid-registration or stuck (HybridJoin-Autopilot-B.md
                                        Fix 4 candidate).
      JOIN_TASK_MISSING              - Automatic-Device-Join scheduled task not found;
                                        device may not be domain-joined yet or task was
                                        removed/corrupted.
      HIGH_RETRY_COUNT               - Task ran more times than -RetryWarningThreshold
                                        before success, indicating the device sat close
                                        to the ESP timeout waiting on sync.
      REGISTRATION_WAIT_NEAR_TIMEOUT - Measured wait between first join attempt and
                                        success consumed more than
                                        -TimeoutBudgetWarningPercent of EspTimeoutMinutes.
      SYNC_INTERVAL_EXCEEDS_BUDGET   - The (measured or assumed/remote) Entra Connect
                                        sync interval alone is larger than the ESP
                                        timeout minus a configurable app-install
                                        allowance, meaning ESP is structurally likely to
                                        time out regardless of retries. Matches
                                        ESP-Stuck-A.md's "Hybrid Join ESP has a timing
                                        dependency on Entra Connect" Learning Pointer.
      SYNC_INTERVAL_NOT_OPTIMIZED    - Remote check confirms the Entra Connect server
                                        is still on the 30-min default rather than a
                                        faster provisioning-window interval.

    This script does not remediate anything — it is a diagnostic/evidence tool. It does
    not require AD or Graph modules for its core (device-local) checks; the Entra
    Connect remote check is best-effort and skipped cleanly if unreachable.

.PARAMETER EspTimeoutMinutes
    The configured ESP timeout (Device Phase + User Phase combined, whichever applies)
    from Intune > Devices > Enrollment > Enrollment Status Page > Profile. Default 60,
    matching the Intune default. Supply the real configured value for an accurate
    budget calculation.

.PARAMETER RetryWarningThreshold
    Number of Automatic-Device-Join task runs before HIGH_RETRY_COUNT is flagged.
    Default 3.

.PARAMETER TimeoutBudgetWarningPercent
    Percentage of EspTimeoutMinutes that, if consumed by the join wait alone, raises
    REGISTRATION_WAIT_NEAR_TIMEOUT. Default 50.

.PARAMETER AppInstallAllowanceMinutes
    Minutes reserved for app/policy installation within the ESP budget (ESP-Stuck-A.md
    notes Office 365 alone can take 45-90 min). Used to compute the remaining budget
    available for the Hybrid Join wait when checking SYNC_INTERVAL_EXCEEDS_BUDGET.
    Default 20.

.PARAMETER EntraConnectServer
    Optional. Hostname of the Entra Connect (Azure AD Connect) server. If reachable via
    WinRM, queries the real configured sync interval via Get-ADSyncScheduler instead of
    assuming the 30-minute default. Requires the caller to have remoting rights on that
    server.

.PARAMETER AssumedSyncIntervalMinutes
    Fallback sync interval used when -EntraConnectServer is not supplied or not
    reachable. Default 30, matching the documented Entra Connect delta sync default.

.PARAMETER OutputPath
    Folder to write the CSV summary and raw evidence files to. Defaults to a
    timestamped folder under $env:TEMP.

.EXAMPLE
    .\Get-HybridJoinESPTimingCorrelation.ps1
    Run on the device with all defaults (60-min ESP timeout, 30-min assumed sync
    interval, no remote Entra Connect check).

.EXAMPLE
    .\Get-HybridJoinESPTimingCorrelation.ps1 -EspTimeoutMinutes 90 -EntraConnectServer "AADC01"
    Run with a known 90-minute ESP timeout and a live check of AADC01's actual
    configured sync interval.

.NOTES
    Run as: Local administrator on the affected device (required to read the
            DeviceManagement-Enterprise-Diagnostics-Provider and User Device
            Registration event logs).
    Safe/unsafe: Fully read-only. No configuration is changed on the device or on the
                 Entra Connect server.
    Companion docs: Autopilot/Troubleshooting/HybridJoin-Autopilot-A.md,
                    Autopilot/Troubleshooting/HybridJoin-Autopilot-B.md,
                    Autopilot/Troubleshooting/ESP-Stuck-A.md
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [int]$EspTimeoutMinutes = 60,
    [int]$RetryWarningThreshold = 3,
    [int]$TimeoutBudgetWarningPercent = 50,
    [int]$AppInstallAllowanceMinutes = 20,
    [string]$EntraConnectServer = "",
    [int]$AssumedSyncIntervalMinutes = 30,
    [string]$OutputPath = "$env:TEMP\HybridJoinESPTiming-$(Get-Date -Format yyyyMMdd-HHmmss)"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$flags = New-Object System.Collections.Generic.List[string]
$findings = @{}

# ---------------------------------------------------------------------------
# PREFLIGHT
# ---------------------------------------------------------------------------
Write-Status "Preflight: confirming device join state via dsregcmd" "INFO"
$dsregRaw = & dsregcmd /status 2>&1
$dsregRaw | Out-File "$OutputPath\dsregcmd-status.txt"

function Get-DsregValue {
    param([string]$Name)
    $line = $dsregRaw | Where-Object { $_ -match "^\s*$Name\s*:\s*(.+)$" } | Select-Object -First 1
    if ($line -match "^\s*$Name\s*:\s*(.+)$") { return $Matches[1].Trim() }
    return $null
}

$domainJoined  = Get-DsregValue "DomainJoined"
$azureAdJoined = Get-DsregValue "AzureAdJoined"
$tenantId      = Get-DsregValue "TenantId"

$findings["DomainJoined"]  = $domainJoined
$findings["AzureAdJoined"] = $azureAdJoined
$findings["TenantId"]      = $tenantId

Write-Status "DomainJoined=$domainJoined  AzureAdJoined=$azureAdJoined" "INFO"

if ($domainJoined -ne "YES") {
    Write-Status "Device is not domain-joined yet — timing correlation not meaningful until domain join completes (see HybridJoin-Autopilot-A.md Phase 1/2)." "WARN"
}

# ---------------------------------------------------------------------------
# DETECT — Automatic-Device-Join scheduled task history (proxy for sync wait)
# ---------------------------------------------------------------------------
Write-Status "Checking Automatic-Device-Join scheduled task" "INFO"

$taskPath = "\Microsoft\Windows\Workplace Join\"
$taskName = "Automatic-Device-Join"
$task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue

$taskRunTimestamps = @()
if (-not $task) {
    Write-Status "Automatic-Device-Join task not found." "WARN"
    $flags.Add("JOIN_TASK_MISSING")
} else {
    $taskInfo = Get-ScheduledTaskInfo -TaskPath $taskPath -TaskName $taskName
    $findings["TaskLastRunTime"]    = $taskInfo.LastRunTime
    $findings["TaskLastResult"]     = $taskInfo.LastTaskResult
    $findings["TaskNextRunTime"]    = $taskInfo.NextRunTime
    Write-Status "Task last ran: $($taskInfo.LastRunTime)  LastTaskResult: $($taskInfo.LastTaskResult)" "INFO"

    # Pull actual run history from Task Scheduler operational log (event ID 200/201 = task started/completed)
    try {
        $taskEvents = Get-WinEvent -LogName "Microsoft-Windows-TaskScheduler/Operational" -ErrorAction Stop |
            Where-Object { $_.Message -match [regex]::Escape($taskName) -and $_.Id -in 100, 102, 200, 201 } |
            Sort-Object TimeCreated
        $taskRunTimestamps = $taskEvents | Select-Object -ExpandProperty TimeCreated
        $taskEvents | Select-Object TimeCreated, Id, Message |
            Export-Csv "$OutputPath\TaskScheduler-AutomaticDeviceJoin.csv" -NoTypeInformation
        Write-Status "Found $($taskRunTimestamps.Count) task run events in Task Scheduler log." "INFO"
    } catch {
        Write-Status "Could not read Task Scheduler operational log (may need to be enabled): $($_.Exception.Message)" "WARN"
    }
}

# ---------------------------------------------------------------------------
# DETECT — User Device Registration event log (304 = success, 335 = failure)
# ---------------------------------------------------------------------------
Write-Status "Scanning Microsoft-Windows-User Device Registration/Admin for join events" "INFO"

$joinEvents = @()
try {
    $joinEvents = Get-WinEvent -LogName "Microsoft-Windows-User Device Registration/Admin" -MaxEvents 200 -ErrorAction Stop |
        Sort-Object TimeCreated
    $joinEvents | Select-Object TimeCreated, Id, LevelDisplayName, Message |
        Export-Csv "$OutputPath\UserDeviceRegistration-Events.csv" -NoTypeInformation
} catch {
    Write-Status "Could not read User Device Registration/Admin log: $($_.Exception.Message)" "WARN"
}

$firstAttempt  = $joinEvents | Where-Object { $_.Id -in 304, 335, 300, 301 } | Select-Object -First 1
$successEvent  = $joinEvents | Where-Object { $_.Id -eq 304 } | Select-Object -Last 1
$failureEvents = $joinEvents | Where-Object { $_.Id -eq 335 }

if (-not $successEvent) {
    Write-Status "No event ID 304 (join succeeded) found — device has not completed Hybrid Join registration." "WARN"
    $flags.Add("JOIN_NOT_YET_SUCCEEDED")
} else {
    Write-Status "Join succeeded at $($successEvent.TimeCreated)" "OK"
}

if ($failureEvents.Count -gt 0) {
    Write-Status "$($failureEvents.Count) event ID 335 (join failed) entries found prior to success/current state." "WARN"
}

# ---------------------------------------------------------------------------
# DETECT — ESP start time (approximate, from Autopilot diagnostic log)
# ---------------------------------------------------------------------------
Write-Status "Approximating ESP start time from Autopilot diagnostic events" "INFO"

$espStart = $null
try {
    $espEvents = Get-WinEvent -LogName "Microsoft-Windows-ModernDeployment-Diagnostics-Provider/AutoPilot" -MaxEvents 100 -ErrorAction Stop |
        Sort-Object TimeCreated
    if ($espEvents) {
        $espStart = $espEvents[0].TimeCreated
        $espEvents | Select-Object TimeCreated, Id, LevelDisplayName, Message |
            Export-Csv "$OutputPath\AutopilotDiagnostic-Events.csv" -NoTypeInformation
        Write-Status "Earliest ESP/Autopilot diagnostic event: $espStart" "INFO"
    }
} catch {
    Write-Status "Could not read Autopilot diagnostic log: $($_.Exception.Message)" "WARN"
}

# Fall back to the earliest task-join event as a proxy ESP start if the diagnostic log is unavailable
if (-not $espStart -and $firstAttempt) {
    $espStart = $firstAttempt.TimeCreated
    Write-Status "Using first join attempt event as ESP-start proxy: $espStart" "WARN"
}

# ---------------------------------------------------------------------------
# CALCULATE — registration wait vs. ESP budget
# ---------------------------------------------------------------------------
$registrationWaitMinutes = $null
if ($firstAttempt -and $successEvent) {
    $registrationWaitMinutes = [math]::Round((New-TimeSpan -Start $firstAttempt.TimeCreated -End $successEvent.TimeCreated).TotalMinutes, 1)
    $findings["RegistrationWaitMinutes"] = $registrationWaitMinutes
    Write-Status "Registration wait (first attempt to success): $registrationWaitMinutes minutes" "INFO"

    $budgetPercentUsed = [math]::Round(($registrationWaitMinutes / $EspTimeoutMinutes) * 100, 1)
    $findings["ESPBudgetPercentUsedByJoinWait"] = $budgetPercentUsed
    Write-Status "That consumed $budgetPercentUsed% of the $EspTimeoutMinutes-minute ESP timeout budget." "INFO"

    if ($budgetPercentUsed -ge $TimeoutBudgetWarningPercent) {
        $flags.Add("REGISTRATION_WAIT_NEAR_TIMEOUT")
    }
}

if ($taskRunTimestamps.Count -ge $RetryWarningThreshold) {
    $flags.Add("HIGH_RETRY_COUNT")
    Write-Status "Automatic-Device-Join ran $($taskRunTimestamps.Count) times (threshold $RetryWarningThreshold) — device retried repeatedly waiting on sync." "WARN"
}

# ---------------------------------------------------------------------------
# OPTIONAL — real Entra Connect sync interval via remote check
# ---------------------------------------------------------------------------
$syncIntervalMinutes = $AssumedSyncIntervalMinutes
$syncSource = "assumed default"

if ($EntraConnectServer -ne "") {
    Write-Status "Attempting remote check of Entra Connect scheduler on $EntraConnectServer" "INFO"
    try {
        $schedulerInfo = Invoke-Command -ComputerName $EntraConnectServer -ScriptBlock {
            Import-Module ADSync -ErrorAction Stop
            Get-ADSyncScheduler | Select-Object CustomizedSyncCycleInterval, NextSyncCyclePolicyType, LastSyncCycleResult
        } -ErrorAction Stop

        if ($schedulerInfo.CustomizedSyncCycleInterval) {
            $syncIntervalMinutes = [TimeSpan]::Parse($schedulerInfo.CustomizedSyncCycleInterval).TotalMinutes
            $syncSource = "live from $EntraConnectServer"
        } else {
            $syncIntervalMinutes = 30
            $syncSource = "live from $EntraConnectServer (default, not customized)"
        }
        $findings["EntraConnectLastSyncResult"] = $schedulerInfo.LastSyncCycleResult
        Write-Status "Entra Connect sync interval: $syncIntervalMinutes min ($syncSource). Last sync result: $($schedulerInfo.LastSyncCycleResult)" "INFO"
    } catch {
        Write-Status "Could not reach $EntraConnectServer or ADSync module unavailable — falling back to assumed $AssumedSyncIntervalMinutes-min interval. ($($_.Exception.Message))" "WARN"
    }
}

$findings["SyncIntervalMinutes"] = $syncIntervalMinutes
$findings["SyncIntervalSource"]  = $syncSource

if ($syncIntervalMinutes -eq 30 -and $syncSource -like "live from*") {
    $flags.Add("SYNC_INTERVAL_NOT_OPTIMIZED")
}

# ---------------------------------------------------------------------------
# VALIDATE — is the ESP timeout structurally sufficient for this sync interval?
# ---------------------------------------------------------------------------
$availableBudgetForJoinWait = $EspTimeoutMinutes - $AppInstallAllowanceMinutes
$findings["AvailableBudgetForJoinWaitMinutes"] = $availableBudgetForJoinWait

Write-Status "ESP budget available for Hybrid Join wait (after $AppInstallAllowanceMinutes-min app-install allowance): $availableBudgetForJoinWait minutes" "INFO"

if ($syncIntervalMinutes -ge $availableBudgetForJoinWait) {
    $flags.Add("SYNC_INTERVAL_EXCEEDS_BUDGET")
    Write-Status "Sync interval ($syncIntervalMinutes min) meets/exceeds the available ESP budget ($availableBudgetForJoinWait min) — ESP is structurally likely to time out for HAADJ regardless of retries. Per ESP-Stuck-A.md: increase ESP timeout or reduce Entra Connect sync interval." "ERROR"
} else {
    Write-Status "Sync interval fits within available ESP budget with $([math]::Round($availableBudgetForJoinWait - $syncIntervalMinutes,1)) minutes of margin." "OK"
}

# ---------------------------------------------------------------------------
# REPORT
# ---------------------------------------------------------------------------
$summary = [PSCustomObject]@{
    Timestamp                          = Get-Date
    DomainJoined                       = $domainJoined
    AzureAdJoined                      = $azureAdJoined
    TenantId                           = $tenantId
    ESPTimeoutMinutes                  = $EspTimeoutMinutes
    AppInstallAllowanceMinutes         = $AppInstallAllowanceMinutes
    AvailableBudgetForJoinWaitMinutes  = $availableBudgetForJoinWait
    JoinTaskRunCount                   = $taskRunTimestamps.Count
    FirstJoinAttempt                   = if ($firstAttempt) { $firstAttempt.TimeCreated } else { $null }
    JoinSucceededAt                    = if ($successEvent) { $successEvent.TimeCreated } else { $null }
    RegistrationWaitMinutes            = $registrationWaitMinutes
    ESPBudgetPercentUsedByJoinWait      = $findings["ESPBudgetPercentUsedByJoinWait"]
    SyncIntervalMinutes                = $syncIntervalMinutes
    SyncIntervalSource                 = $syncSource
    JoinFailureEventCount               = $failureEvents.Count
    Flags                              = ($flags -join "; ")
}

$summary | Format-List
$summary | Export-Csv "$OutputPath\HybridJoinESPTiming-Summary.csv" -NoTypeInformation

Write-Status "Full evidence and summary written to: $OutputPath" "OK"
if ($flags.Count -eq 0) {
    Write-Status "No timing risk flags raised." "OK"
} else {
    Write-Status "Flags raised: $($flags -join ', ')" "WARN"
}
