<#
.SYNOPSIS
    Audits Power Automate flows in an environment for throttle and retry-cascade risk signals.

.DESCRIPTION
    Combines two data sources that, per Throttling-Limits-A.md, are undiagnosable by eye:
    recent run history (for confirmed 429/throttle errors) and the flow's own definition JSON
    (for the retry-policy and loop-concurrency settings that determine whether a throttle
    event turns into a retry cascade).

    For every flow in the target environment, flags:
    - FLOW_THROTTLED           — a run in the lookback window failed with a 429 / "Too Many Requests"
                                  error (Throttling-Limits-B.md Triage Step 1)
    - RETRY_CASCADE_RISK       — the flow both hit a 429 recently AND has an Apply-to-each/Do-Until
                                  loop with no explicit concurrency control, the exact combination
                                  Throttling-Limits-A.md's "Retry Cascade Problem" describes as
                                  capable of burning 5-100x the normal request quota per run
    - NO_CONCURRENCY_LIMIT     — a loop exists with no runtimeConfiguration.concurrency setting,
                                  i.e. still on the implicit/unbounded default (Fix 5 / Playbook 2)
    - AGGRESSIVE_DEFAULT_RETRY — an action inside a loop has no explicit retry policy override,
                                  meaning it inherits the platform default (4x exponential) which
                                  compounds quota burn under sustained throttle (Learning Pointers)
    - HIGH_FREQUENCY_RECURRENCE — a recurrence trigger is configured to run more often than a
                                  configurable threshold (default 5 minutes) — the shared-quota
                                  burst pattern called out in Fix 3

    Read-only. Does not change any flow, retry policy, or concurrency setting.

.PARAMETER EnvironmentName
    The Power Platform environment name (GUID). Retrieve via Get-AdminPowerAppEnvironment.

.PARAMETER FlowDisplayName
    Optional. Only audit flows whose display name matches this pattern (partial match).

.PARAMETER DaysBack
    Number of days of run history to scan for 429/throttle errors. Default: 7. Max: 28 (API limit).

.PARAMETER MinRecurrenceMinutes
    Recurrence interval (in minutes) below which a trigger is flagged HIGH_FREQUENCY_RECURRENCE.
    Default: 5.

.PARAMETER OutputPath
    Path to export CSV report. Default: C:\Temp\ThrottlingDiagnostics-<timestamp>.csv

.EXAMPLE
    .\Get-ThrottlingLimitDiagnostics.ps1 -EnvironmentName "Default-<tenantId>"

.EXAMPLE
    # Narrow to a specific flow that's reporting failures, with a 14-day lookback
    .\Get-ThrottlingLimitDiagnostics.ps1 -EnvironmentName "Default-<tenantId>" -FlowDisplayName "Invoice Sync" -DaysBack 14

.NOTES
    Requires: Microsoft.PowerApps.Administration.PowerShell module
    Install:  Install-Module Microsoft.PowerApps.Administration.PowerShell -Scope CurrentUser
    Auth:     Add-PowerAppsAccount (prompts for credentials)
    Permissions: Power Platform Service Admin, Environment Admin, or Global Admin
    Not covered: Layer-1 per-user/per-flow daily request entitlement consumption — that metric is
    portal-only (Power Platform Admin Center → Capacity) as of 2026 and has no cmdlet equivalent,
    per Throttling-Limits-A.md Validation Step 2. This script covers everything that IS
    programmatically observable: confirmed 429s, retry policy, and loop concurrency.
    Companion runbooks: PowerAutomate/Troubleshooting/Throttling-Limits-A.md and Throttling-Limits-B.md
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentName,
    [Parameter()][string]$FlowDisplayName,
    [Parameter()][ValidateRange(1,28)][int]$DaysBack = 7,
    [Parameter()][int]$MinRecurrenceMinutes = 5,
    [Parameter()][string]$OutputPath = "C:\Temp\ThrottlingDiagnostics-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $Colour = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $Colour
}

# ─── Preflight ────────────────────────────────────────────────────────────────

Write-Status "Checking for Microsoft.PowerApps.Administration.PowerShell module..."
if (-not (Get-Module -ListAvailable -Name "Microsoft.PowerApps.Administration.PowerShell")) {
    Write-Status "Module not found. Installing..." "WARN"
    Install-Module Microsoft.PowerApps.Administration.PowerShell -Scope CurrentUser -Force -AllowClobber
}
Import-Module Microsoft.PowerApps.Administration.PowerShell -ErrorAction Stop

Write-Status "Authenticating to Power Platform..."
try {
    Add-PowerAppsAccount
} catch {
    Write-Status "Authentication failed: $_" "ERROR"
    exit 1
}

# ─── Detect: enumerate flows ──────────────────────────────────────────────────

Write-Status "Retrieving flows from environment: $EnvironmentName"
$Flows = Get-AdminFlow -EnvironmentName $EnvironmentName -ErrorAction SilentlyContinue
if ($FlowDisplayName) {
    $Flows = $Flows | Where-Object { $_.DisplayName -like "*$FlowDisplayName*" }
}

if (-not $Flows -or $Flows.Count -eq 0) {
    Write-Status "No flows found matching criteria." "WARN"
    exit 0
}

Write-Status "Found $($Flows.Count) flow(s) to audit." "OK"

$Since = (Get-Date).AddDays(-$DaysBack)
$Findings = [System.Collections.Generic.List[PSCustomObject]]::new()

# ─── Execute: run history + definition inspection per flow ───────────────────

foreach ($Flow in $Flows) {
    $FlowName    = $Flow.FlowName
    $DisplayName = $Flow.DisplayName
    Write-Status "Auditing: $DisplayName ($FlowName)..."

    $Flags = [System.Collections.Generic.List[string]]::new()
    $ThrottledRunCount = 0
    $LastThrottleTime = $null

    # --- Run history: confirmed 429s ---
    try {
        $Runs = Get-AdminFlowRun -FlowName $FlowName -EnvironmentName $EnvironmentName -ErrorAction SilentlyContinue |
            Where-Object { [datetime]$_.StartTime -ge $Since }

        foreach ($Run in $Runs) {
            if ($Run.Status -eq "Failed" -and $Run.Error) {
                $ErrCode = "$($Run.Error.code)"
                $ErrMsg  = "$($Run.Error.message)"
                if ($ErrCode -match "429" -or $ErrMsg -match "(?i)too many requests|throttl") {
                    $ThrottledRunCount++
                    $RunTime = [datetime]$Run.StartTime
                    if (-not $LastThrottleTime -or $RunTime -gt $LastThrottleTime) { $LastThrottleTime = $RunTime }
                }
            }
        }
    } catch {
        Write-Status "  Could not retrieve run history: $_" "WARN"
    }

    if ($ThrottledRunCount -gt 0) {
        $Flags.Add("FLOW_THROTTLED")
    }

    # --- Definition inspection: loops, concurrency, retry policy ---
    $HasLoop = $false
    $LoopHasConcurrency = $false
    $ActionMissingRetryPolicy = $false
    $HasHighFrequencyRecurrence = $false
    $RecurrenceIntervalMinutes = $null

    try {
        $FlowDetail = Get-AdminFlow -FlowName $FlowName -EnvironmentName $EnvironmentName -ErrorAction SilentlyContinue
        $Definition = $FlowDetail.Internal.properties.definition

        if ($Definition) {
            # Triggers — recurrence frequency check
            if ($Definition.triggers) {
                foreach ($TriggerProp in $Definition.triggers.PSObject.Properties) {
                    $Trigger = $TriggerProp.Value
                    if ($Trigger.type -eq "Recurrence" -and $Trigger.recurrence) {
                        $Freq = $Trigger.recurrence.frequency
                        $Interval = [int]$Trigger.recurrence.interval
                        $Minutes = switch ($Freq) {
                            "Second" { $Interval / 60 }
                            "Minute" { $Interval }
                            "Hour"   { $Interval * 60 }
                            "Day"    { $Interval * 1440 }
                            default  { $null }
                        }
                        if ($Minutes) {
                            $RecurrenceIntervalMinutes = $Minutes
                            if ($Minutes -lt $MinRecurrenceMinutes) { $HasHighFrequencyRecurrence = $true }
                        }
                    }
                }
            }

            # Actions — loop + concurrency + retry policy inspection (recursive across nested scopes)
            function Test-Actions {
                param($ActionsObj)
                if (-not $ActionsObj) { return }
                foreach ($ActionProp in $ActionsObj.PSObject.Properties) {
                    $Action = $ActionProp.Value
                    if ($Action.type -in @("Foreach","Until")) {
                        $script:HasLoop = $true
                        $Concurrency = $Action.runtimeConfiguration.concurrency
                        if ($Concurrency -and ($Concurrency.repetitions -or $Concurrency.PSObject.Properties.Name -contains 'repetitions')) {
                            $script:LoopHasConcurrency = $true
                        }
                        if ($Action.actions) { Test-Actions -ActionsObj $Action.actions }
                    }
                    if ($Action.type -in @("Http","ApiConnection","OpenApiConnection")) {
                        $RetryPolicy = $Action.runtimeConfiguration.retryPolicy -or $Action.inputs.retryPolicy
                        if (-not $RetryPolicy) { $script:ActionMissingRetryPolicy = $true }
                    }
                    if ($Action.actions) { Test-Actions -ActionsObj $Action.actions }
                    if ($Action.else.actions) { Test-Actions -ActionsObj $Action.else.actions }
                }
            }
            Test-Actions -ActionsObj $Definition.actions
        }
    } catch {
        Write-Status "  Could not parse flow definition: $_" "WARN"
    }

    if ($HasLoop -and -not $LoopHasConcurrency) {
        $Flags.Add("NO_CONCURRENCY_LIMIT")
    }
    if ($HasLoop -and $ActionMissingRetryPolicy) {
        $Flags.Add("AGGRESSIVE_DEFAULT_RETRY")
    }
    if ($HasHighFrequencyRecurrence) {
        $Flags.Add("HIGH_FREQUENCY_RECURRENCE")
    }
    # The compound signature Throttling-Limits-A.md calls the "Retry Cascade Problem":
    # confirmed throttling + no concurrency control on the loop that's presumably driving it.
    if ($ThrottledRunCount -gt 0 -and $HasLoop -and -not $LoopHasConcurrency) {
        $Flags.Add("RETRY_CASCADE_RISK")
    }

    $Findings.Add([PSCustomObject]@{
        FlowDisplayName            = $DisplayName
        FlowId                     = $FlowName
        Environment                = $EnvironmentName
        ThrottledRunsInWindow      = $ThrottledRunCount
        LastThrottleTime           = if ($LastThrottleTime) { $LastThrottleTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "" }
        HasLoop                    = $HasLoop
        LoopHasConcurrencyControl  = $LoopHasConcurrency
        RecurrenceIntervalMinutes  = $RecurrenceIntervalMinutes
        Flags                      = ($Flags -join "; ")
    })
}

# ─── Validate / Report ────────────────────────────────────────────────────────

Write-Status "`n═══════════════════════════════════════════════" "OK"
Write-Status "POWER AUTOMATE THROTTLING DIAGNOSTICS SUMMARY" "OK"
Write-Status "Environment    : $EnvironmentName"
Write-Status "Lookback       : $DaysBack day(s)"
Write-Status "Flows audited  : $($Findings.Count)"

$Throttled     = $Findings | Where-Object { $_.Flags -match "FLOW_THROTTLED" }
$CascadeRisk   = $Findings | Where-Object { $_.Flags -match "RETRY_CASCADE_RISK" }
$NoConcurrency = $Findings | Where-Object { $_.Flags -match "NO_CONCURRENCY_LIMIT" }
$HighFreq      = $Findings | Where-Object { $_.Flags -match "HIGH_FREQUENCY_RECURRENCE" }

Write-Status "`nFlows with confirmed 429/throttle errors : $($Throttled.Count)" $(if ($Throttled.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "Flows at RETRY_CASCADE_RISK               : $($CascadeRisk.Count)" $(if ($CascadeRisk.Count -gt 0) { "ERROR" } else { "OK" })
Write-Status "Loops with no concurrency control          : $($NoConcurrency.Count)" $(if ($NoConcurrency.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "High-frequency recurrence triggers          : $($HighFreq.Count)" $(if ($HighFreq.Count -gt 0) { "WARN" } else { "OK" })

if ($CascadeRisk.Count -gt 0) {
    Write-Status "`nHighest priority — RETRY_CASCADE_RISK flows (fix these first, per Fix 5 / Playbook 2):" "ERROR"
    $CascadeRisk | ForEach-Object { Write-Host "  - $($_.FlowDisplayName) (throttled $($_.ThrottledRunsInWindow)x, last: $($_.LastThrottleTime))" -ForegroundColor Red }
}

$Findings | Sort-Object ThrottledRunsInWindow -Descending | Export-Csv -Path $OutputPath -NoTypeInformation
Write-Status "`nFull report exported to: $OutputPath" "OK"
