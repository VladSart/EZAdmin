<#
.SYNOPSIS
    Read-only fleet-wide health sweep of Azure Automation accounts — identity/authentication
    state, module provisioning, Hybrid Runbook Worker heartbeat, and webhook expiry.

.DESCRIPTION
    Azure Automation failures are disproportionately caused by three silent, easy-to-miss
    conditions rather than by runbook logic bugs: an account with no managed identity at all
    (a leftover from the 30-September-2023 Run As account retirement), a Hybrid Runbook Worker
    that has stopped heartbeating (jobs queue forever with no error, rather than failing
    loudly), and a webhook that is about to pass its non-renewable expiry. This script sweeps
    one or more Automation accounts and flags all three, plus module provisioning problems and
    recently failed/suspended jobs, in a single CSV suitable for an MSP onboarding audit or a
    recurring fleet health check.

    Checks performed per Automation account:

      1. IDENTITY — flags NO_MANAGED_IDENTITY if the account has neither a system- nor a
         user-assigned identity. Per AzureAutomation-A.md Layer 0, this means every runbook in
         the account either already fails on any Connect-AzAccount -Identity call, or is still
         relying on a Run As account that cannot be renewed. This is the single highest-value
         flag in this script.

      2. MODULES — flags any module with ProvisioningState other than "Succeeded" as
         MODULE_NOT_READY (Creating for over the -ModuleImportGraceMinutes threshold, default
         10, or Failed outright).

      3. HYBRID RUNBOOK WORKERS — for every Hybrid Runbook Worker Group and its member workers,
         flags STALE_HEARTBEAT for any worker whose LastSeenDateTime is older than
         -StaleHeartbeatMinutes (default 5 — well beyond the documented ~30-second poll cycle)
         and NEAR_PURGE_THRESHOLD for any worker approaching the 30-day automatic-purge window
         Microsoft applies to non-heartbeating workers.

      4. WEBHOOKS — flags EXPIRED for any webhook whose ExpiryTime has already passed (cannot
         be renewed, must be recreated per AzureAutomation-B.md Fix 5) and
         EXPIRING_SOON for any webhook expiring within -WebhookExpiryWarningDays (default 30).

      5. RECENT JOBS — pulls jobs from the last -JobLookbackDays (default 7) and flags any
         account with a Failed or Suspended rate above -FailureRateWarningPercent (default 20)
         as JOB_FAILURE_RATE_HIGH, surfacing the most common exception text seen, so a fleet
         sweep can prioritize which account to investigate first rather than reading every job
         individually.

    Deliberately does NOT touch runbook source code (grepping for retired Run As patterns is a
    separate, heavier operation — see AzureAutomation-A.md Validation Step 3) and does NOT
    modify, create, or remove any resource — this script only reads and reports.

.PARAMETER ResourceGroupName
    Resource group containing the Automation account(s) to audit. If omitted, attempts to
    enumerate every Automation account in the current subscription context.

.PARAMETER AutomationAccountName
    Optional. Scopes the audit to a single named Automation account. Requires
    -ResourceGroupName. If omitted, audits every Automation account found in scope.

.PARAMETER SubscriptionId
    Optional. Switches subscription context before running (requires prior authentication to
    that subscription). If omitted, uses the current Az context.

.PARAMETER ModuleImportGraceMinutes
    Minutes a module is allowed to sit in "Creating" state before being flagged
    MODULE_NOT_READY. Default 10, matching Microsoft's documented typical import time.

.PARAMETER StaleHeartbeatMinutes
    Minutes since a Hybrid Runbook Worker's last heartbeat before it's flagged
    STALE_HEARTBEAT. Default 5 (10x the documented ~30-second poll cycle, to avoid false
    positives from normal poll jitter).

.PARAMETER WebhookExpiryWarningDays
    Days-until-expiry threshold for flagging a webhook EXPIRING_SOON. Default 30.

.PARAMETER JobLookbackDays
    How many days of job history to pull for the failure-rate check. Default 7.

.PARAMETER FailureRateWarningPercent
    Percentage of Failed+Suspended jobs (of total jobs in the lookback window) that triggers
    JOB_FAILURE_RATE_HIGH for an account. Default 20.

.PARAMETER ExportPath
    Path to export the CSV report. Defaults to C:\Temp\AzureAutomationHealth_<timestamp>.csv.

.EXAMPLE
    .\Get-AzureAutomationHealth.ps1 -ResourceGroupName 'rg-automation'

.EXAMPLE
    .\Get-AzureAutomationHealth.ps1 -ResourceGroupName 'rg-automation' -AutomationAccountName 'aa-client01' `
        -StaleHeartbeatMinutes 10 -WebhookExpiryWarningDays 60
    Audits one named account with looser heartbeat tolerance and a longer webhook expiry warning window.

.NOTES
    Requires: Az.Automation, Az.Accounts, Az.Resources modules
    Install:  Install-Module Az.Automation, Az.Accounts, Az.Resources -Scope CurrentUser
    Permissions: Reader on the Automation account(s) is sufficient for checks 1, 2, 3, and 4.
                 Reading role assignments for a deeper identity-permission check is intentionally
                 out of scope here (see AzureAutomation-A.md Validation Step 2 for that manual
                 follow-up) — this script reports whether an identity EXISTS, not whether its
                 role assignments are correct, keeping the permission bar low for a fleet sweep.
                 Individual checks degrade to a CheckFailed status rather than throwing if the
                 caller lacks permission for that specific check.
    Safe to run: Read-only. No accounts, identities, modules, workers, webhooks, or jobs are
                 created, modified, or removed.
#>
#Requires -Modules Az.Automation, Az.Accounts

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$AutomationAccountName,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [int]$ModuleImportGraceMinutes = 10,

    [Parameter(Mandatory = $false)]
    [int]$StaleHeartbeatMinutes = 5,

    [Parameter(Mandatory = $false)]
    [int]$WebhookExpiryWarningDays = 30,

    [Parameter(Mandatory = $false)]
    [int]$JobLookbackDays = 7,

    [Parameter(Mandatory = $false)]
    [int]$FailureRateWarningPercent = 20,

    [Parameter(Mandatory = $false)]
    [string]$ExportPath = "C:\Temp\AzureAutomationHealth_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Starting Azure Automation health sweep..." "INFO"

if (-not (Get-AzContext)) {
    Write-Status "No active Az context found. Run Connect-AzAccount first." "ERROR"
    throw "Not authenticated to Azure."
}

if ($SubscriptionId) {
    Write-Status "Switching to subscription $SubscriptionId..." "INFO"
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

$currentContext = Get-AzContext
Write-Status "Running against subscription: $($currentContext.Subscription.Name) ($($currentContext.Subscription.Id))" "INFO"

$results = New-Object System.Collections.Generic.List[Object]

# ---------------------------------------------------------------------------
# Detect — gather Automation account(s) in scope
# ---------------------------------------------------------------------------
try {
    if ($AutomationAccountName -and $ResourceGroupName) {
        $accounts = @(Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName)
    }
    elseif ($ResourceGroupName) {
        $accounts = @(Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName)
    }
    else {
        $accounts = @(Get-AzAutomationAccount)
    }
}
catch {
    Write-Status "Failed to enumerate Automation accounts: $($_.Exception.Message)" "ERROR"
    throw
}

if ($accounts.Count -eq 0) {
    Write-Status "No Automation accounts found in scope." "WARN"
    return
}

Write-Status "Found $($accounts.Count) Automation account(s) to audit." "INFO"

# ---------------------------------------------------------------------------
# Execute — per account: identity, modules, hybrid workers, webhooks, jobs
# ---------------------------------------------------------------------------
foreach ($aa in $accounts) {

    Write-Status "Auditing Automation account: $($aa.AutomationAccountName) (RG: $($aa.ResourceGroupName))" "INFO"

    # --- 1. Identity ---
    $identityType = "None"
    try {
        if ($aa.PSObject.Properties['Identity'] -and $aa.Identity -and $aa.Identity.PrincipalId) {
            $identityType = if ($aa.Identity.Type) { $aa.Identity.Type } else { "Unknown" }
        }
    }
    catch { $identityType = "Unknown" }

    $identityFlags = New-Object System.Collections.Generic.List[string]
    if ($identityType -eq "None") { $identityFlags.Add("NO_MANAGED_IDENTITY") }

    $results.Add([PSCustomObject]@{
        CheckType              = "Identity"
        AutomationAccountName  = $aa.AutomationAccountName
        ResourceGroupName      = $aa.ResourceGroupName
        ItemName               = $aa.AutomationAccountName
        Detail                 = "IdentityType=$identityType"
        Flags                  = if ($identityFlags.Count -gt 0) { $identityFlags -join ";" } else { "OK" }
    })

    # --- 2. Modules ---
    try {
        $modules = @(Get-AzAutomationModule -ResourceGroupName $aa.ResourceGroupName -AutomationAccountName $aa.AutomationAccountName -ErrorAction Stop)
        foreach ($mod in $modules) {
            $moduleFlags = New-Object System.Collections.Generic.List[string]
            if ($mod.ProvisioningState -eq "Failed") {
                $moduleFlags.Add("MODULE_NOT_READY")
            }
            elseif ($mod.ProvisioningState -ne "Succeeded") {
                $ageMinutes = if ($mod.PSObject.Properties['LastModifiedTime'] -and $mod.LastModifiedTime) {
                    [math]::Round(((Get-Date) - $mod.LastModifiedTime.DateTime).TotalMinutes, 1)
                } else { -1 }
                if ($ageMinutes -eq -1 -or $ageMinutes -gt $ModuleImportGraceMinutes) {
                    $moduleFlags.Add("MODULE_NOT_READY")
                }
            }

            $results.Add([PSCustomObject]@{
                CheckType              = "Module"
                AutomationAccountName  = $aa.AutomationAccountName
                ResourceGroupName      = $aa.ResourceGroupName
                ItemName               = $mod.Name
                Detail                 = "ProvisioningState=$($mod.ProvisioningState); Version=$($mod.Version)"
                Flags                  = if ($moduleFlags.Count -gt 0) { $moduleFlags -join ";" } else { "OK" }
            })
        }
    }
    catch {
        Write-Status "Failed to enumerate modules for $($aa.AutomationAccountName): $($_.Exception.Message)" "WARN"
        $results.Add([PSCustomObject]@{
            CheckType              = "Module"
            AutomationAccountName  = $aa.AutomationAccountName
            ResourceGroupName      = $aa.ResourceGroupName
            ItemName               = ""
            Detail                 = ""
            Flags                  = "CheckFailed: $($_.Exception.Message)"
        })
    }

    # --- 3. Hybrid Runbook Worker Groups + Workers ---
    try {
        $groups = @(Get-AzAutomationHybridWorkerGroup -ResourceGroupName $aa.ResourceGroupName -AutomationAccountName $aa.AutomationAccountName -ErrorAction Stop)
        foreach ($group in $groups) {
            try {
                $workers = @(Get-AzAutomationHybridRunbookWorker -ResourceGroupName $aa.ResourceGroupName -AutomationAccountName $aa.AutomationAccountName -HybridRunbookWorkerGroupName $group.Name -ErrorAction Stop)
            }
            catch {
                Write-Status "Failed to enumerate workers in group $($group.Name): $($_.Exception.Message)" "WARN"
                $workers = @()
                $results.Add([PSCustomObject]@{
                    CheckType              = "HybridWorkerGroup"
                    AutomationAccountName  = $aa.AutomationAccountName
                    ResourceGroupName      = $aa.ResourceGroupName
                    ItemName               = $group.Name
                    Detail                 = ""
                    Flags                  = "CheckFailed: $($_.Exception.Message)"
                })
            }

            if ($workers.Count -eq 0) {
                $results.Add([PSCustomObject]@{
                    CheckType              = "HybridWorkerGroup"
                    AutomationAccountName  = $aa.AutomationAccountName
                    ResourceGroupName      = $aa.ResourceGroupName
                    ItemName               = $group.Name
                    Detail                 = "WorkerCount=0"
                    Flags                  = "EMPTY_GROUP"
                })
                continue
            }

            foreach ($worker in $workers) {
                $workerFlags = New-Object System.Collections.Generic.List[string]
                $lastSeen = $null
                try { if ($worker.PSObject.Properties['LastSeenDateTime']) { $lastSeen = $worker.LastSeenDateTime } } catch { }

                if ($null -eq $lastSeen) {
                    $workerFlags.Add("NO_HEARTBEAT_DATA")
                }
                else {
                    $minutesSinceSeen = [math]::Round(((Get-Date).ToUniversalTime() - $lastSeen.ToUniversalTime()).TotalMinutes, 1)
                    $daysSinceSeen = [math]::Round($minutesSinceSeen / 1440, 1)
                    if ($minutesSinceSeen -gt $StaleHeartbeatMinutes) { $workerFlags.Add("STALE_HEARTBEAT") }
                    if ($daysSinceSeen -ge 25) { $workerFlags.Add("NEAR_PURGE_THRESHOLD") }
                }

                $results.Add([PSCustomObject]@{
                    CheckType              = "HybridWorker"
                    AutomationAccountName  = $aa.AutomationAccountName
                    ResourceGroupName      = $aa.ResourceGroupName
                    ItemName               = "$($group.Name)/$($worker.Name)"
                    Detail                 = "WorkerType=$($worker.WorkerType); LastSeenDateTime=$lastSeen"
                    Flags                  = if ($workerFlags.Count -gt 0) { $workerFlags -join ";" } else { "OK" }
                })
            }
        }
    }
    catch {
        Write-Status "Failed to enumerate hybrid worker groups for $($aa.AutomationAccountName): $($_.Exception.Message)" "WARN"
        $results.Add([PSCustomObject]@{
            CheckType              = "HybridWorkerGroup"
            AutomationAccountName  = $aa.AutomationAccountName
            ResourceGroupName      = $aa.ResourceGroupName
            ItemName               = ""
            Detail                 = ""
            Flags                  = "CheckFailed: $($_.Exception.Message)"
        })
    }

    # --- 4. Webhooks ---
    try {
        $webhooks = @(Get-AzAutomationWebhook -ResourceGroupName $aa.ResourceGroupName -AutomationAccountName $aa.AutomationAccountName -ErrorAction Stop)
        foreach ($hook in $webhooks) {
            $hookFlags = New-Object System.Collections.Generic.List[string]
            if (-not $hook.IsEnabled) { $hookFlags.Add("DISABLED") }
            if ($hook.ExpiryTime) {
                $daysToExpiry = [math]::Round(($hook.ExpiryTime.DateTime - (Get-Date)).TotalDays, 1)
                if ($daysToExpiry -lt 0) { $hookFlags.Add("EXPIRED") }
                elseif ($daysToExpiry -le $WebhookExpiryWarningDays) { $hookFlags.Add("EXPIRING_SOON") }
            }

            $results.Add([PSCustomObject]@{
                CheckType              = "Webhook"
                AutomationAccountName  = $aa.AutomationAccountName
                ResourceGroupName      = $aa.ResourceGroupName
                ItemName               = "$($hook.RunbookName)/$($hook.Name)"
                Detail                 = "IsEnabled=$($hook.IsEnabled); ExpiryTime=$($hook.ExpiryTime)"
                Flags                  = if ($hookFlags.Count -gt 0) { $hookFlags -join ";" } else { "OK" }
            })
        }
    }
    catch {
        Write-Status "Failed to enumerate webhooks for $($aa.AutomationAccountName): $($_.Exception.Message)" "WARN"
        $results.Add([PSCustomObject]@{
            CheckType              = "Webhook"
            AutomationAccountName  = $aa.AutomationAccountName
            ResourceGroupName      = $aa.ResourceGroupName
            ItemName               = ""
            Detail                 = ""
            Flags                  = "CheckFailed: $($_.Exception.Message)"
        })
    }

    # --- 5. Recent job failure rate ---
    try {
        $jobs = @(Get-AzAutomationJob -ResourceGroupName $aa.ResourceGroupName -AutomationAccountName $aa.AutomationAccountName `
            -StartTime (Get-Date).AddDays(-1 * $JobLookbackDays) -ErrorAction Stop)

        if ($jobs.Count -gt 0) {
            $badJobs = @($jobs | Where-Object { $_.Status -in @("Failed", "Suspended") })
            $failureRate = [math]::Round(($badJobs.Count / $jobs.Count) * 100, 1)

            $topException = ""
            if ($badJobs.Count -gt 0) {
                $topException = ($badJobs | Where-Object { $_.Exception } | Select-Object -First 1 -ExpandProperty Exception)
            }

            $jobFlags = New-Object System.Collections.Generic.List[string]
            if ($failureRate -ge $FailureRateWarningPercent) { $jobFlags.Add("JOB_FAILURE_RATE_HIGH") }

            $results.Add([PSCustomObject]@{
                CheckType              = "JobHistory"
                AutomationAccountName  = $aa.AutomationAccountName
                ResourceGroupName      = $aa.ResourceGroupName
                ItemName               = "(last $JobLookbackDays days)"
                Detail                 = "TotalJobs=$($jobs.Count); Failed+Suspended=$($badJobs.Count); FailureRate=$failureRate%; SampleException=$topException"
                Flags                  = if ($jobFlags.Count -gt 0) { $jobFlags -join ";" } else { "OK" }
            })
        }
        else {
            $results.Add([PSCustomObject]@{
                CheckType              = "JobHistory"
                AutomationAccountName  = $aa.AutomationAccountName
                ResourceGroupName      = $aa.ResourceGroupName
                ItemName               = "(last $JobLookbackDays days)"
                Detail                 = "TotalJobs=0"
                Flags                  = "NO_RECENT_JOBS"
            })
        }
    }
    catch {
        Write-Status "Failed to enumerate recent jobs for $($aa.AutomationAccountName): $($_.Exception.Message)" "WARN"
        $results.Add([PSCustomObject]@{
            CheckType              = "JobHistory"
            AutomationAccountName  = $aa.AutomationAccountName
            ResourceGroupName      = $aa.ResourceGroupName
            ItemName               = ""
            Detail                 = ""
            Flags                  = "CheckFailed: $($_.Exception.Message)"
        })
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$noIdentityCount      = ($results | Where-Object { $_.Flags -like "*NO_MANAGED_IDENTITY*" }).Count
$moduleNotReadyCount  = ($results | Where-Object { $_.Flags -like "*MODULE_NOT_READY*" }).Count
$staleWorkerCount     = ($results | Where-Object { $_.Flags -like "*STALE_HEARTBEAT*" }).Count
$nearPurgeCount       = ($results | Where-Object { $_.Flags -like "*NEAR_PURGE_THRESHOLD*" }).Count
$expiredWebhookCount  = ($results | Where-Object { $_.Flags -like "*EXPIRED*" }).Count
$expiringWebhookCount = ($results | Where-Object { $_.Flags -like "*EXPIRING_SOON*" }).Count
$highFailureRateCount = ($results | Where-Object { $_.Flags -like "*JOB_FAILURE_RATE_HIGH*" }).Count

Write-Status "Audit complete." "OK"
Write-Status "  Accounts with no managed identity at all: $noIdentityCount" "INFO"
Write-Status "  Modules not ready (Creating past grace period, or Failed): $moduleNotReadyCount" "INFO"
Write-Status "  Hybrid Workers with a stale heartbeat: $staleWorkerCount" "INFO"
Write-Status "  Hybrid Workers nearing 30-day auto-purge: $nearPurgeCount" "INFO"
Write-Status "  Expired webhooks: $expiredWebhookCount" "INFO"
Write-Status "  Webhooks expiring soon: $expiringWebhookCount" "INFO"
Write-Status "  Accounts with a high recent job failure rate: $highFailureRateCount" "INFO"

if ($noIdentityCount -gt 0) {
    Write-Status "  $noIdentityCount account(s) have NO managed identity — every runbook there either already fails or relies on a Run As account that cannot be renewed. See AzureAutomation-B.md Fix 1." "WARN"
}
if ($staleWorkerCount -gt 0) {
    Write-Status "  $staleWorkerCount Hybrid Worker(s) have a stale heartbeat — jobs will queue silently rather than fail loudly. See AzureAutomation-B.md Fix 4." "WARN"
}
if ($expiredWebhookCount -gt 0) {
    Write-Status "  $expiredWebhookCount webhook(s) are past expiry and cannot be renewed — must be recreated. See AzureAutomation-B.md Fix 5." "WARN"
}

$exportDir = Split-Path $ExportPath -Parent
if ($exportDir -and -not (Test-Path $exportDir)) {
    New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
}

$results | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Report exported to: $ExportPath" "OK"

return $results
