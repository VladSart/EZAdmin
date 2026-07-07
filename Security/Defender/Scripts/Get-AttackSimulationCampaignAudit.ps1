<#
.SYNOPSIS
    Tenant-wide, read-only audit of Attack Simulation Training campaigns, flagging the
    conditions most likely to cause a support ticket (stuck/stale simulations, licensing
    or audit-logging gaps, and transport-rule interference with reported-phish routing).

.DESCRIPTION
    Attack Simulation Training has no dedicated PowerShell module — Microsoft Graph is the
    only programmatic surface (permission: AttackSimulation.Read.All). This script:

    1. Pulls recent simulation campaigns via GET /security/attackSimulation/simulations
       (confirmed schema: id, displayName, description, attackType, attackTechnique, status,
       createdDateTime, createdBy, lastModifiedDateTime, lastModifiedBy, launchDateTime,
       completionDateTime, isAutomated, automationId, payloadDeliveryPlatform).
    2. Flags campaigns stuck in "scheduled" well past their launchDateTime (target
       resolution/expansion likely stalled or every recipient failed validation).
    3. Flags campaigns stuck in "inProgress" far beyond a configurable staleness window.
    4. Optionally checks whether unified audit logging is enabled (-CheckAuditLog) — this is
       the single highest-value tenant-wide health check for this workload, since it gates
       BOTH reporting data AND training assignment. Requires an active Exchange Online
       PowerShell session (Connect-ExchangeOnline); degrades gracefully with a warning if
       not connected, consistent with this repo's established graceful-degradation pattern.
    5. Optionally scans enabled transport rules for anything broad enough to catch mail to
       the four documented reported-phish submission addresses (-CheckTransportRuleBlock)
       — also requires Exchange Online PowerShell; degrades gracefully if unavailable.
    6. Optionally checks a specific list of users for E5 / Defender for Office 365 Plan 2
       licensing (-CheckUserLicensing) — the most common cause of empty per-user activity
       details in simulation reports.

    This script does NOT create, edit, launch, or cancel any simulation, payload, or policy.
    It does not attempt per-user click/compromise forensics (EmailLinkClicked_IP/Timestamp
    analysis) — that data lives only in the exported per-simulation Users tab report and is
    explicitly out of scope for a tenant-wide Graph audit; see AttackSimulationTraining-A.md
    Diagnosis Step 5 / Troubleshooting Phase 3 for that workflow.

.PARAMETER Top
    Maximum number of most-recently-created simulations to pull and evaluate. Default: 50.

.PARAMETER ScheduledStaleHours
    Flag a simulation as SCHEDULED_STALE if its status is still "scheduled" more than this
    many hours after its launchDateTime. Default: 4.

.PARAMETER InProgressStaleDays
    Flag a simulation as IN_PROGRESS_STALE if its status is still "inProgress" more than this
    many days after its launchDateTime with no completionDateTime set. Default: 14.

.PARAMETER CheckAuditLog
    Switch. Also checks UnifiedAuditLogIngestionEnabled via Exchange Online PowerShell.

.PARAMETER CheckTransportRuleBlock
    Switch. Also scans enabled transport rules for interference with reported-phish routing
    addresses via Exchange Online PowerShell.

.PARAMETER CheckUserLicensing
    Optional array of UPNs to check for E5/Defender for Office 365 Plan 2 licensing.

.PARAMETER ExportPath
    Full path for CSV export of the simulation audit. Defaults to
    $env:TEMP\AttackSimAudit-<date>.csv.

.EXAMPLE
    # Basic tenant-wide simulation health sweep
    .\Get-AttackSimulationCampaignAudit.ps1

.EXAMPLE
    # Full sweep including audit-log and transport-rule checks (requires EXO connection)
    Connect-ExchangeOnline
    .\Get-AttackSimulationCampaignAudit.ps1 -CheckAuditLog -CheckTransportRuleBlock

.EXAMPLE
    # Also check specific users for licensing gaps
    .\Get-AttackSimulationCampaignAudit.ps1 -CheckUserLicensing "user1@contoso.com","user2@contoso.com"

.NOTES
    Requires: Microsoft.Graph.Authentication PowerShell SDK (Install-Module Microsoft.Graph.Authentication)
    Permissions needed (Graph): AttackSimulation.Read.All (delegated or application)
    Optional:  ExchangeOnlineManagement module + an active Connect-ExchangeOnline session
               for -CheckAuditLog and -CheckTransportRuleBlock
    Optional:  Microsoft.Graph.Users PowerShell SDK for -CheckUserLicensing
    Read-only throughout. No New-/Update-/Remove- Graph calls, no Set-AdminAuditLogConfig,
    no transport rule changes.
#>

[CmdletBinding()]
param(
    [int]$Top = 50,
    [int]$ScheduledStaleHours = 4,
    [int]$InProgressStaleDays = 14,
    [switch]$CheckAuditLog,
    [switch]$CheckTransportRuleBlock,
    [string[]]$CheckUserLicensing,
    [string]$ExportPath = "$env:TEMP\AttackSimAudit-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ------------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------------
Write-Status "Attack Simulation Training campaign audit starting..." "INFO"

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Status "Microsoft.Graph.Authentication module not found. Install with: Install-Module Microsoft.Graph.Authentication" "ERROR"
    return
}

$mgContext = Get-MgContext -ErrorAction SilentlyContinue
if (-not $mgContext) {
    Write-Status "Not connected to Microsoft Graph. Connecting with AttackSimulation.Read.All..." "WARN"
    Connect-MgGraph -Scopes "AttackSimulation.Read.All" -NoWelcome
    $mgContext = Get-MgContext -ErrorAction SilentlyContinue
}
if (-not $mgContext) {
    Write-Status "Graph connection failed — cannot continue." "ERROR"
    return
}
Write-Status "Connected to Graph as $($mgContext.Account) (tenant $($mgContext.TenantId))" "OK"

# ------------------------------------------------------------------------------------
# Detect — pull recent simulations
# ------------------------------------------------------------------------------------
Write-Status "Pulling $Top most recent simulations..." "INFO"

$findings = New-Object System.Collections.Generic.List[object]
$simulations = @()

try {
    $uri = "https://graph.microsoft.com/v1.0/security/attackSimulation/simulations?`$top=$Top&`$orderby=createdDateTime desc"
    $response = Invoke-MgGraphRequest -Method GET -Uri $uri
    $simulations = $response.value

    # Follow pagination up to the requested Top count, in case the service pages sooner
    while ($response.'@odata.nextLink' -and $simulations.Count -lt $Top) {
        $response = Invoke-MgGraphRequest -Method GET -Uri $response.'@odata.nextLink'
        $simulations += $response.value
    }
} catch {
    Write-Status "Failed to retrieve simulations: $($_.Exception.Message)" "ERROR"
    return
}

Write-Status "Retrieved $($simulations.Count) simulation(s)." "OK"

$now = Get-Date

foreach ($sim in $simulations) {
    $flags = New-Object System.Collections.Generic.List[string]

    $launch = $null
    if ($sim.launchDateTime) {
        try { $launch = [datetime]$sim.launchDateTime } catch { $launch = $null }
    }
    $completion = $null
    if ($sim.completionDateTime) {
        try { $completion = [datetime]$sim.completionDateTime } catch { $completion = $null }
    }

    switch ($sim.status) {
        "scheduled" {
            if ($launch -and (($now - $launch).TotalHours -gt $ScheduledStaleHours)) {
                $flags.Add("SCHEDULED_STALE")
            }
        }
        "inProgress" {
            if ($launch -and (($now - $launch).TotalDays -gt $InProgressStaleDays) -and -not $completion) {
                $flags.Add("IN_PROGRESS_STALE")
            }
        }
        "completed" {
            if ($launch -and $completion -and (($completion - $launch).TotalMinutes -lt 5)) {
                $flags.Add("COMPLETED_UNUSUALLY_FAST")  # possible mass target-validation failure
            }
        }
    }

    if (-not $sim.status) {
        $flags.Add("STATUS_UNKNOWN")
    }

    $findings.Add([PSCustomObject]@{
        SimulationId       = $sim.id
        DisplayName        = $sim.displayName
        Status             = $sim.status
        AttackType         = $sim.attackType
        AttackTechnique    = $sim.attackTechnique
        IsAutomated        = $sim.isAutomated
        PayloadDeliveryPlatform = $sim.payloadDeliveryPlatform
        CreatedDateTime    = $sim.createdDateTime
        CreatedBy          = $sim.createdBy.displayName
        LaunchDateTime     = $sim.launchDateTime
        CompletionDateTime = $sim.completionDateTime
        Flags              = ($flags -join ";")
    })
}

$staleCount = ($findings | Where-Object { $_.Flags }).Count
if ($staleCount -gt 0) {
    Write-Status "$staleCount simulation(s) flagged for review." "WARN"
} else {
    Write-Status "No simulation-level issues found in the sample pulled." "OK"
}

# ------------------------------------------------------------------------------------
# Optional — unified audit logging check (gates BOTH reporting and training assignment)
# ------------------------------------------------------------------------------------
if ($CheckAuditLog) {
    Write-Status "Checking unified audit logging state (requires Exchange Online PowerShell)..." "INFO"
    if (Get-Command Get-AdminAuditLogConfig -ErrorAction SilentlyContinue) {
        try {
            $auditConfig = Get-AdminAuditLogConfig
            if ($auditConfig.UnifiedAuditLogIngestionEnabled) {
                Write-Status "Unified audit logging is ENABLED." "OK"
            } else {
                Write-Status "Unified audit logging is DISABLED — this blanks ALL Attack Simulation Training reporting AND blocks training assignment tenant-wide. See AttackSimulationTraining-B.md Fix 1." "ERROR"
            }
        } catch {
            Write-Status "Get-AdminAuditLogConfig failed: $($_.Exception.Message)" "WARN"
        }
    } else {
        Write-Status "Get-AdminAuditLogConfig not available — connect with Connect-ExchangeOnline first. Skipping audit log check." "WARN"
    }
}

# ------------------------------------------------------------------------------------
# Optional — transport rule interference with reported-phish routing
# ------------------------------------------------------------------------------------
if ($CheckTransportRuleBlock) {
    Write-Status "Scanning enabled transport rules for reported-phish routing interference (requires Exchange Online PowerShell)..." "INFO"
    $watchAddresses = @(
        "junk@office365.microsoft.com",
        "abuse@messaging.microsoft.com",
        "phish@office365.microsoft.com",
        "not_junk@office365.microsoft.com"
    )
    if (Get-Command Get-TransportRule -ErrorAction SilentlyContinue) {
        try {
            $rules = Get-TransportRule | Where-Object { $_.State -eq "Enabled" }
            $suspectRules = foreach ($rule in $rules) {
                $ruleText = ($rule | Out-String)
                $matchedAddress = $watchAddresses | Where-Object { $ruleText -match [regex]::Escape($_) }
                if ($matchedAddress -or $rule.RejectMessageReasonText -or $rule.DeleteMessage -or $rule.BlockedSenders) {
                    [PSCustomObject]@{
                        RuleName          = $rule.Name
                        Priority          = $rule.Priority
                        PossibleWatchHit  = ($matchedAddress -join ",")
                        HasRejectAction   = [bool]$rule.RejectMessageReasonText
                        HasDeleteAction   = [bool]$rule.DeleteMessage
                    }
                }
            }
            if ($suspectRules) {
                Write-Status "$($suspectRules.Count) enabled rule(s) with reject/delete/block actions found — manually confirm none scope-match the 4 watch addresses above." "WARN"
                $suspectRules | Format-Table -AutoSize
            } else {
                Write-Status "No enabled transport rules with reject/delete/block actions found." "OK"
            }
        } catch {
            Write-Status "Get-TransportRule failed: $($_.Exception.Message)" "WARN"
        }
    } else {
        Write-Status "Get-TransportRule not available — connect with Connect-ExchangeOnline first. Skipping transport rule scan." "WARN"
    }
}

# ------------------------------------------------------------------------------------
# Optional — per-user E5 / Defender for Office 365 Plan 2 licensing check
# ------------------------------------------------------------------------------------
if ($CheckUserLicensing -and $CheckUserLicensing.Count -gt 0) {
    Write-Status "Checking licensing for $($CheckUserLicensing.Count) user(s)..." "INFO"
    if (Get-Command Get-MgUserLicenseDetail -ErrorAction SilentlyContinue) {
        $e5Skus = @("SPE_E5", "ENTERPRISEPREMIUM", "SPE_F5_SECCOMP", "THREAT_INTELLIGENCE")
        foreach ($upn in $CheckUserLicensing) {
            try {
                $licenses = Get-MgUserLicenseDetail -UserId $upn | Select-Object -ExpandProperty SkuPartNumber
                $hasE5Class = $licenses | Where-Object { $e5Skus -contains $_ }
                if ($hasE5Class) {
                    Write-Status "$upn -> licensed ($($licenses -join ', '))" "OK"
                } else {
                    Write-Status "$upn -> NO E5/Defender for Office 365 Plan 2 class SKU found ($($licenses -join ', ')) — expect empty activity details for this user." "WARN"
                }
            } catch {
                Write-Status "$upn -> license lookup failed: $($_.Exception.Message)" "WARN"
            }
        }
    } else {
        Write-Status "Get-MgUserLicenseDetail not available — install/import Microsoft.Graph.Users. Skipping licensing check." "WARN"
    }
}

# ------------------------------------------------------------------------------------
# Report
# ------------------------------------------------------------------------------------
$findings | Sort-Object CreatedDateTime -Descending | Format-Table -AutoSize -Property DisplayName, Status, AttackTechnique, LaunchDateTime, Flags

$findings | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Full simulation audit exported to: $ExportPath" "OK"
Write-Status "Audit complete. This script makes no changes — flagged items require manual review per AttackSimulationTraining-A.md / -B.md." "INFO"
