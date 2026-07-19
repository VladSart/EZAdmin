<#
.SYNOPSIS
    Audits the tenant-wide Microsoft Secure Score (security.microsoft.com/securescore)
    — score trend, category rollup, stale manual overrides, and quick-win candidates.

.DESCRIPTION
    This is the M365 tenant-wide Secure Score (Identity/Device/Apps/Data), NOT
    Defender for Cloud's Azure-resource CSPM Secure Score (see
    Get-DefenderForCloudPostureAudit.ps1 / Az.Security module for that one) and
    NOT a single device's TVM exposure score (see Get-DefenderVulnMgmtStatus.ps1).

    Pulls the latest secureScore snapshot plus a configurable history window via
    Microsoft Graph, joins the per-tenant controlScores against the full
    secureScoreControlProfiles catalog, and flags:

    - SCORE_REGRESSED             — currentScore dropped vs. the prior snapshot
    - CATEGORY_REGRESSED          — a specific category (Identity/Device/Apps/Data)
                                     lost points even if the overall score is flat
                                     or improved (one category's drop offset by
                                     another's gain — invisible at the top-line
                                     number alone)
    - ENABLEDSERVICES_LICENSE_GAP — a workload appears licensed via
                                     Get-MgSubscribedSku but is absent from
                                     EnabledServices (provisioning gap or the
                                     documented 24-48h propagation delay)
    - STALE_MANUAL_OVERRIDE       — a control has a non-Default ControlStateUpdates
                                     state older than -StaleOverrideDays, worth a
                                     "is this mitigation still actually in place"
                                     check per SecureScore-A.md Playbook 2
    - QUICK_WIN_CANDIDATE         — MaxScore > 0, CurrentScore = 0 (or partial),
                                     ImplementationCost = "Low", UserImpact = "Low",
                                     sorted by points-remaining — a ready-made
                                     prioritized list for a client improvement plan
    - DEVICE_CATEGORY_INFO        — informational flag on every Device-category
                                     control, reminding the reader that status
                                     changes route through Defender Vulnerability
                                     Management, not this script or the Secure
                                     Score UI directly (see SecureScore-B.md Fix 5)

    This script is entirely READ-ONLY. It never calls a write cmdlet against
    Secure Score, never changes a ControlStateUpdates status, and never touches
    the underlying product configuration a recommendation points at. Status
    reconciliation (Playbook 2 in SecureScore-A.md) is a portal-only action as
    of this writing — there is no documented stable-API write path for
    ControlStateUpdates, so this script deliberately does not attempt one.

.PARAMETER HistoryDepth
    Number of historical secureScore snapshots to pull for trend/regression
    analysis. Default: 30 (roughly a month of daily syncs).

.PARAMETER StaleOverrideDays
    A manual ControlStateUpdates override older than this many days is flagged
    STALE_MANUAL_OVERRIDE for a "is this still true" recheck. Default: 180.

.PARAMETER QuickWinMax
    Maximum number of quick-win candidates to list in the console summary
    (the full list is still written to CSV). Default: 15.

.PARAMETER OutputPath
    Directory for CSV/JSON exports. Default: C:\Temp\SecureScore-Report-<timestamp>

.EXAMPLE
    .\Get-SecureScoreReport.ps1

.EXAMPLE
    .\Get-SecureScoreReport.ps1 -HistoryDepth 90 -StaleOverrideDays 90 -QuickWinMax 25

.NOTES
    Requires: Microsoft.Graph.Security module (Get-MgSecuritySecureScore,
              Get-MgSecuritySecureScoreControlProfile), Microsoft.Graph.Users
              (Get-MgSubscribedSku lives in Microsoft.Graph.Identity.DirectoryManagement)
    Run As:   An account/app with SecurityEvents.Read.All. NOTE: as of this
              writing, Graph API access to Secure Score is gated by LEGACY
              Entra global roles (e.g. Security Reader), not yet by Defender
              XDR Unified RBAC custom roles — see SecureScore-B.md Fix 6 if
              this script 403s for a user who has full portal access.
    Safe:     Read-only — no ControlStateUpdates writes, no policy/config changes.
    Cross-references: Security/Defender/SecureScore-B.md and -A.md
#>

[CmdletBinding()]
param(
    [int]$HistoryDepth = 30,
    [int]$StaleOverrideDays = 180,
    [int]$QuickWinMax = 15,
    [string]$OutputPath = "C:\Temp\SecureScore-Report-$(Get-Date -Format 'yyyyMMdd-HHmm')"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
$requiredModules = "Microsoft.Graph.Security", "Microsoft.Graph.Identity.DirectoryManagement"
foreach ($m in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        Write-Status "Module '$m' not found. Install with: Install-Module $m -Scope CurrentUser" "ERROR"
        return
    }
}

try {
    $ctx = Get-MgContext
    if (-not $ctx) { throw "Not connected" }
    if ($ctx.Scopes -notcontains "SecurityEvents.Read.All" -and $ctx.Scopes -notcontains "SecurityEvents.ReadWrite.All") {
        Write-Status "Connected, but SecurityEvents.Read.All scope not present. Reconnect with: Connect-MgGraph -Scopes 'SecurityEvents.Read.All'" "WARN"
    }
} catch {
    Write-Status "Not connected to Microsoft Graph. Run: Connect-MgGraph -Scopes 'SecurityEvents.Read.All'" "ERROR"
    return
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
Write-Status "Output directory: $OutputPath" "INFO"

# ---------------------------------------------------------------------------
# Detect — pull score history, control catalog, and license SKUs
# ---------------------------------------------------------------------------
Write-Status "Pulling secure score history (depth: $HistoryDepth)..." "INFO"
try {
    $history = Get-MgSecuritySecureScore -Top $HistoryDepth -ErrorAction Stop | Sort-Object CreatedDateTime
} catch {
    Write-Status "Failed to pull secure score history: $_" "ERROR"
    Write-Status "If this is a 403 despite portal access working fine, see SecureScore-B.md Fix 6 — Graph API access is legacy-role-gated, not Unified-RBAC-gated, as of this writing." "WARN"
    return
}

if (-not $history -or $history.Count -eq 0) {
    Write-Status "No secure score data returned. Tenant may be too new, or no products are yet enrolled." "WARN"
    return
}

$latest = $history[-1]
$previous = if ($history.Count -ge 2) { $history[-2] } else { $null }

Write-Status "Pulling full secureScoreControlProfiles catalog..." "INFO"
$controls = Get-MgSecuritySecureScoreControlProfile -All -ErrorAction SilentlyContinue

Write-Status "Pulling licensed SKUs for EnabledServices cross-check..." "INFO"
$skus = Get-MgSubscribedSku -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Analyze — top-line score and regression
# ---------------------------------------------------------------------------
$pct = if ($latest.MaxScore -gt 0) { [math]::Round(($latest.CurrentScore / $latest.MaxScore) * 100, 1) } else { 0 }
Write-Status "Current score: $($latest.CurrentScore) / $($latest.MaxScore) ($pct%) as of $($latest.CreatedDateTime)" "INFO"

$findings = [System.Collections.Generic.List[object]]::new()

if ($previous) {
    $delta = $latest.CurrentScore - $previous.CurrentScore
    if ($delta -lt 0) {
        $findings.Add([pscustomobject]@{
            Flag = "SCORE_REGRESSED"; Severity = "WARN"
            Detail = "Score dropped $delta points between $($previous.CreatedDateTime) and $($latest.CreatedDateTime)"
        })
        Write-Status "SCORE_REGRESSED: $delta points since last snapshot" "WARN"
    } elseif ($delta -gt 0) {
        Write-Status "Score improved by $delta points since last snapshot" "OK"
    }

    # Per-category regression — can be masked by an overall flat/positive delta
    $prevByCat = $previous.ControlScores | Group-Object ControlCategory |
        ForEach-Object { @{ $_.Name = ($_.Group.Score | Measure-Object -Sum).Sum } }
    $currByCat = $latest.ControlScores | Group-Object ControlCategory |
        ForEach-Object { @{ $_.Name = ($_.Group.Score | Measure-Object -Sum).Sum } }

    $categories = @("Identity", "Device", "Apps", "Data")
    foreach ($cat in $categories) {
        $prevSum = ($previous.ControlScores | Where-Object ControlCategory -eq $cat | Measure-Object Score -Sum).Sum
        $currSum = ($latest.ControlScores | Where-Object ControlCategory -eq $cat | Measure-Object Score -Sum).Sum
        if ($prevSum -and $currSum -and ($currSum -lt $prevSum)) {
            $catDelta = $currSum - $prevSum
            $findings.Add([pscustomobject]@{
                Flag = "CATEGORY_REGRESSED"; Severity = "WARN"
                Detail = "$cat category dropped $catDelta points (may be masked by overall score if other categories improved)"
            })
            Write-Status "CATEGORY_REGRESSED: $cat ($catDelta pts)" "WARN"
        }
    }
}

# ---------------------------------------------------------------------------
# Analyze — EnabledServices vs. licensed SKUs (best-effort heuristic match)
# ---------------------------------------------------------------------------
if ($skus) {
    $licenseHints = @{
        "Exchange"   = "EXCHANGE|ENTERPRISEPACK|SPE_|O365"
        "SharePoint" = "SHAREPOINT|SPE_|O365"
        "Teams"      = "TEAMS|SPE_|O365"
        "AzureAD"    = "AAD_PREMIUM|SPE_"
    }
    $activeSkuNames = ($skus | Where-Object ConsumedUnits -gt 0).SkuPartNumber -join "|"
    foreach ($hint in $licenseHints.GetEnumerator()) {
        if ($activeSkuNames -match $hint.Value -and $latest.EnabledServices -notcontains $hint.Key) {
            $findings.Add([pscustomobject]@{
                Flag = "ENABLEDSERVICES_LICENSE_GAP"; Severity = "WARN"
                Detail = "SKU pattern for '$($hint.Key)' is actively consumed but not reflected in EnabledServices — check provisioning or allow up to 48h propagation"
            })
            Write-Status "ENABLEDSERVICES_LICENSE_GAP: $($hint.Key) licensed but not in EnabledServices" "WARN"
        }
    }
} else {
    Write-Status "Could not pull subscribed SKUs — skipping license/EnabledServices cross-check." "WARN"
}

# ---------------------------------------------------------------------------
# Analyze — stale manual overrides
# ---------------------------------------------------------------------------
$overrides = @()
if ($controls) {
    $cutoff = (Get-Date).AddDays(-$StaleOverrideDays)
    foreach ($c in $controls) {
        $lastUpdate = $c.ControlStateUpdates | Select-Object -Last 1
        if ($lastUpdate -and $lastUpdate.State -and $lastUpdate.State -ne "Default") {
            $overrides += [pscustomobject]@{
                Control = $c.Title; Category = $c.ControlCategory; State = $lastUpdate.State
                UpdatedBy = $lastUpdate.UpdatedBy; UpdatedDateTime = $lastUpdate.UpdatedDateTime
            }
            if ($lastUpdate.UpdatedDateTime -and [datetime]$lastUpdate.UpdatedDateTime -lt $cutoff) {
                $findings.Add([pscustomobject]@{
                    Flag = "STALE_MANUAL_OVERRIDE"; Severity = "WARN"
                    Detail = "'$($c.Title)' has been '$($lastUpdate.State)' since $($lastUpdate.UpdatedDateTime) (> $StaleOverrideDays days) — confirm the mitigation is still actually in place"
                })
            }
        }
    }
    Write-Status "Manual overrides found: $($overrides.Count) (stale > $StaleOverrideDays days: $((($findings | Where-Object Flag -eq 'STALE_MANUAL_OVERRIDE')).Count))" "INFO"
}

# ---------------------------------------------------------------------------
# Analyze — quick-win candidates and device-category informational flags
# ---------------------------------------------------------------------------
$quickWins = @()
$deviceControls = @()
if ($controls) {
    foreach ($cs in $latest.ControlScores) {
        $profile = $controls | Where-Object Id -eq $cs.ControlName | Select-Object -First 1
        if (-not $profile) { continue }

        $pointsRemaining = $profile.MaxScore - $cs.Score
        if ($cs.ControlCategory -eq "Device") {
            $deviceControls += [pscustomobject]@{
                Control = $profile.Title; Current = $cs.Score; Max = $profile.MaxScore
                Note = "Device category — status changes route through Defender Vulnerability Management, not Secure Score directly. See SecureScore-B.md Fix 5."
            }
        }

        if ($pointsRemaining -gt 0 -and $profile.ImplementationCost -eq "Low" -and $profile.UserImpact -eq "Low") {
            $quickWins += [pscustomobject]@{
                Control = $profile.Title; Category = $cs.ControlCategory
                PointsRemaining = $pointsRemaining; Rank = $profile.Rank
                ActionUrl = $profile.ActionUrl
            }
        }
    }

    if ($quickWins.Count -gt 0) {
        $findings.Add([pscustomobject]@{
            Flag = "QUICK_WIN_CANDIDATE"; Severity = "INFO"
            Detail = "$($quickWins.Count) low-cost/low-impact controls with points remaining — see quick_wins.csv"
        })
        Write-Status "QUICK_WIN_CANDIDATE: $($quickWins.Count) low-cost/low-impact controls found" "OK"
    }

    if ($deviceControls.Count -gt 0) {
        Write-Status "DEVICE_CATEGORY_INFO: $($deviceControls.Count) Device-category controls present — remember these route through TVM for status changes" "INFO"
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Status "=== Category Rollup ===" "INFO"
$latest.ControlScores | Group-Object ControlCategory | ForEach-Object {
    $sum = ($_.Group.Score | Measure-Object -Sum).Sum
    Write-Host ("  {0,-10}: {1} pts" -f $_.Name, $sum)
}

Write-Status "=== Top $QuickWinMax Quick-Win Candidates (by points remaining) ===" "INFO"
$quickWins | Sort-Object PointsRemaining -Descending | Select-Object -First $QuickWinMax |
    Format-Table Control, Category, PointsRemaining, Rank -AutoSize

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
$latest | ConvertTo-Json -Depth 6 | Out-File "$OutputPath\current_snapshot.json"
$history | Select-Object CreatedDateTime, CurrentScore, MaxScore |
    Export-Csv "$OutputPath\score_history.csv" -NoTypeInformation
$findings | Export-Csv "$OutputPath\findings.csv" -NoTypeInformation
$overrides | Export-Csv "$OutputPath\manual_overrides.csv" -NoTypeInformation
$quickWins | Sort-Object PointsRemaining -Descending | Export-Csv "$OutputPath\quick_wins.csv" -NoTypeInformation
$deviceControls | Export-Csv "$OutputPath\device_category_controls.csv" -NoTypeInformation

if ($latest.AverageComparativeScores) {
    $latest.AverageComparativeScores | Select-Object Basis, AverageScore |
        Export-Csv "$OutputPath\peer_comparison.csv" -NoTypeInformation
}

Write-Status "Report complete. Findings: $($findings.Count). Files written to $OutputPath" "OK"
