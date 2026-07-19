<#
.SYNOPSIS
    Audits Microsoft Purview Adaptive Protection end-to-end wiring: licensing, the
    Conditional Access arm, the DLP arm (best-effort), the upstream IRM signal source,
    and orphaned policy detection.

.DESCRIPTION
    Adaptive Protection has no single portal blade or cmdlet that reports end-to-end
    health across all three enforcement arms (DLP, Conditional Access, Data Lifecycle
    Management) plus the upstream Insider Risk Management (IRM) signal source. This
    script assembles that view from the pieces that ARE scriptable, per the companion
    runbooks AdaptiveProtection-A.md / AdaptiveProtection-B.md:

    1. Licensing — confirms Entra ID P2 (required for the CA arm) and E5/E5 Compliance
       (required for IRM/DLP/DLM) SKUs are present in the tenant.
    2. Conditional Access arm — finds every CA policy referencing the Insider risk
       condition (Graph property conditions.insiderRiskLevels) and flags CA_REPORT_ONLY
       for any still in enabledForReportingButNotEnforced state, since that is the
       single most common "Adaptive Protection isn't blocking anyone" root cause.
       Also flags CA_WRONG_RISK_SIGNAL as a heuristic check for policies that look
       Insider-Risk-related by name but only reference userRiskLevels/signInRiskLevels
       (Entra ID Protection's unrelated risk engine) — automating the AdaptiveProtection-B.md
       Fix 7 gotcha.
    3. DLP arm (best-effort) — Security & Compliance PowerShell has no dedicated
       parameter that cleanly surfaces the "Insider risk level for Adaptive Protection
       is" condition; this script pulls every DLP rule's serialized definition and
       text-searches it for the condition's known internal token. This is documented
       as best-effort and may miss rules if Microsoft changes the internal schema —
       always cross-check flagged policies against the Purview portal DLP policy list.
    4. IRM signal source — lists policies and enabled state (does not duplicate the
       full IRM health check in Insider-Risk-A.md's own evidence-pack script).
    5. Orphan detection — cross-references CA policies referencing insider risk against
       whether Adaptive Protection currently shows healthy upstream signal (an active,
       enabled IRM policy). A live CA/DLP policy referencing insider risk while no IRM
       policy is enabled is flagged ORPHANED_CA_POLICY / not something DLM covers since
       DLM's own sub-toggle deletes its policy automatically on disable.

    Does NOT cover:
    - The Adaptive Protection master on/off toggle or the DLM opt-in sub-toggle state
      (both portal-only, no read cmdlet exists) — reported as a manual-check reminder.
    - Insider risk level definitions/criteria/thresholds (portal-only).
    - Full IRM policy health, alert volume, or HRMS connector status — see
      Insider-Risk-A.md's own validation steps and evidence pack for that.

.PARAMETER OutputPath
    Folder where CSV reports are written. Default: $env:TEMP\AdaptiveProtectionAudit-<date>

.PARAMETER SkipDlpCheck
    Switch. Skips the best-effort DLP rule text-search pass (faster on tenants with a
    large number of DLP rules where only the CA/licensing/IRM checks are needed).

.EXAMPLE
    .\Get-AdaptiveProtectionAudit.ps1

.EXAMPLE
    .\Get-AdaptiveProtectionAudit.ps1 -OutputPath C:\Temp\APAudit -SkipDlpCheck

.NOTES
    Requires: Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Identity.DirectoryManagement
              (licensing, CA policy read), ExchangeOnlineManagement + Connect-IPPSSession
              (IRM policy read, DLP rule read).
    Run as:   A user with Global Reader or equivalent read access across Entra ID and
              Purview compliance (Conditional Access Administrator/Security Reader +
              Compliance Administrator/View-Only DLP Compliance Management are sufficient
              read-only combinations).
    Safe to run repeatedly — entirely read-only, makes no policy, licence, or config changes.
    Companion runbooks: Security/Purview/AdaptiveProtection-A.md, AdaptiveProtection-B.md
#>

[CmdletBinding()]
param(
    [string]$OutputPath = "$env:TEMP\AdaptiveProtectionAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss')",
    [switch]$SkipDlpCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
Write-Status "Output folder: $OutputPath"

$findings = New-Object System.Collections.Generic.List[Object]
function Add-Finding {
    param([string]$Category, [string]$Object, [string]$Flag, [string]$Detail)
    $findings.Add([PSCustomObject]@{
        Category = $Category
        Object   = $Object
        Flag     = $Flag
        Detail   = $Detail
    })
}

# ============================================================
# PART 1 — Licensing
# ============================================================
Write-Status "Part 1: Checking licensing (Entra ID P2, E5/E5 Compliance)..."
try {
    if (-not (Get-MgContext)) {
        Connect-MgGraph -Scopes "Organization.Read.All" -NoWelcome
    }
    $skus = Get-MgSubscribedSku
    $skus | Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits |
        Export-Csv "$OutputPath\Licensing.csv" -NoTypeInformation

    $p2 = $skus | Where-Object { $_.SkuPartNumber -match "AAD_PREMIUM_P2" }
    $e5 = $skus | Where-Object { $_.SkuPartNumber -match "SPE_E5|M365_E5|ENTERPRISEPREMIUM|IDENTITY_THREAT_PROTECTION" }

    if (-not $p2) {
        Add-Finding "Licensing" "Tenant" "MISSING_ENTRA_P2" "No Entra ID P2 SKU found. The Conditional Access arm of Adaptive Protection cannot function without it, even if the Purview side shows Adaptive Protection as On."
        Write-Status "Entra ID P2 not found" "WARN"
    } else {
        Write-Status "Entra ID P2 present" "OK"
    }
    if (-not $e5) {
        Add-Finding "Licensing" "Tenant" "MISSING_E5_COMPLIANCE" "No E5 / E5 Compliance SKU found. IRM, DLP, and DLM all require this — Adaptive Protection has nothing to route without it."
        Write-Status "E5 / E5 Compliance not found" "WARN"
    } else {
        Write-Status "E5 / E5 Compliance present" "OK"
    }
}
catch {
    Add-Finding "Licensing" "Tenant" "CHECK_FAILED" "Graph licensing check failed: $($_.Exception.Message)"
    Write-Status "Licensing check failed: $($_.Exception.Message)" "ERROR"
}

# ============================================================
# PART 2 — Conditional Access arm
# ============================================================
Write-Status "Part 2: Checking Conditional Access policies for the Insider risk condition..."
$caInsiderPolicies = @()
try {
    $allCaPolicies = Get-MgIdentityConditionalAccessPolicy -All

    foreach ($pol in $allCaPolicies) {
        $hasInsiderRisk = $null -ne $pol.Conditions.InsiderRiskLevels -and $pol.Conditions.InsiderRiskLevels.Count -gt 0
        $hasIdentityProtectionRisk = ($pol.Conditions.UserRiskLevels -and $pol.Conditions.UserRiskLevels.Count -gt 0) -or
                                     ($pol.Conditions.SignInRiskLevels -and $pol.Conditions.SignInRiskLevels.Count -gt 0)
        $nameLooksInsiderRisk = $pol.DisplayName -match "(?i)insider.?risk|adaptive.?protection"

        if ($hasInsiderRisk) {
            $caInsiderPolicies += $pol
            $stateFlag = if ($pol.State -eq "enabledForReportingButNotEnforced") { "CA_REPORT_ONLY" } else { "OK" }
            if ($stateFlag -eq "CA_REPORT_ONLY") {
                Add-Finding "ConditionalAccess" $pol.DisplayName "CA_REPORT_ONLY" "Policy references the Insider risk condition but is in Report-only state — will never block/require anything until promoted to 'enabled'."
            }
        }

        # Heuristic gotcha check: name suggests insider risk / Adaptive Protection,
        # but the policy only carries Entra ID Protection's unrelated risk conditions.
        if ($nameLooksInsiderRisk -and -not $hasInsiderRisk -and $hasIdentityProtectionRisk) {
            Add-Finding "ConditionalAccess" $pol.DisplayName "CA_WRONG_RISK_SIGNAL" "Policy name suggests Insider Risk / Adaptive Protection, but it only uses userRiskLevels/signInRiskLevels (Entra ID Protection's unrelated risk engine), not conditions.insiderRiskLevels. Likely a naming/config mismatch worth confirming with whoever built it."
        }
    }

    $caInsiderPolicies | Select-Object DisplayName, State, Id, CreatedDateTime, ModifiedDateTime |
        Export-Csv "$OutputPath\CA-InsiderRisk-Policies.csv" -NoTypeInformation

    if ($caInsiderPolicies.Count -eq 0) {
        Add-Finding "ConditionalAccess" "Tenant" "NO_CA_POLICY_FOUND" "No Conditional Access policy references the Insider risk condition. If Adaptive Protection is believed to be configured for CA enforcement, this arm has not actually been built yet (or was deleted)."
        Write-Status "No CA policy references Insider risk condition" "WARN"
    } else {
        Write-Status "$($caInsiderPolicies.Count) CA policy(ies) reference Insider risk condition" "OK"
    }
}
catch {
    Add-Finding "ConditionalAccess" "Tenant" "CHECK_FAILED" "CA policy check failed: $($_.Exception.Message)"
    Write-Status "CA policy check failed: $($_.Exception.Message)" "ERROR"
}

# ============================================================
# PART 3 — DLP arm (best-effort)
# ============================================================
if (-not $SkipDlpCheck) {
    Write-Status "Part 3: Checking DLP rules for the Adaptive Protection condition (best-effort text search)..."
    try {
        if (-not (Get-ConnectionInformation -ErrorAction SilentlyContinue)) {
            Connect-IPPSSession -ShowBanner:$false
        }
        $dlpPolicies = Get-DlpCompliancePolicy
        $dlpFindings = @()

        foreach ($dlpPol in $dlpPolicies) {
            $rules = Get-DlpComplianceRule -Policy $dlpPol.Identity -ErrorAction SilentlyContinue
            foreach ($rule in $rules) {
                # Best-effort: serialize the rule and text-search for known internal
                # tokens associated with the Adaptive Protection condition. Microsoft
                # does not publish a stable, documented parameter name for this
                # condition as of this writing — treat matches as a strong signal,
                # not a guaranteed-complete inventory.
                $ruleJson = $rule | ConvertTo-Json -Depth 12 -Compress -ErrorAction SilentlyContinue
                if ($ruleJson -match "(?i)InsiderRisk|AdaptiveProtection") {
                    $modeFlag = if ($dlpPol.Mode -match "(?i)TestWithNotifications|TestWithoutNotifications|Test") { "DLP_SIMULATION_MODE" } else { "OK" }
                    $dlpFindings += [PSCustomObject]@{
                        PolicyName = $dlpPol.Name
                        RuleName   = $rule.Name
                        PolicyMode = $dlpPol.Mode
                        Flag       = $modeFlag
                    }
                    if ($modeFlag -eq "DLP_SIMULATION_MODE") {
                        Add-Finding "DLP" "$($dlpPol.Name) / $($rule.Name)" "DLP_SIMULATION_MODE" "Rule appears to reference the Adaptive Protection insider-risk condition but the policy Mode is $($dlpPol.Mode) — simulation/test mode, will not enforce actions against real traffic."
                    }
                }
            }
        }

        $dlpFindings | Export-Csv "$OutputPath\DLP-AdaptiveProtection-Rules.csv" -NoTypeInformation

        if ($dlpFindings.Count -eq 0) {
            Add-Finding "DLP" "Tenant" "NO_DLP_RULE_FOUND" "No DLP rule text-matched the Adaptive Protection condition tokens. Either the DLP arm has not been built, or the internal schema has changed since this script was written — cross-check the Purview portal DLP policy list before concluding the arm is unconfigured."
            Write-Status "No DLP rule matched Adaptive Protection tokens (best-effort — verify in portal)" "WARN"
        } else {
            Write-Status "$($dlpFindings.Count) DLP rule(s) matched Adaptive Protection tokens" "OK"
        }
    }
    catch {
        Add-Finding "DLP" "Tenant" "CHECK_FAILED" "DLP rule check failed: $($_.Exception.Message)"
        Write-Status "DLP rule check failed: $($_.Exception.Message)" "ERROR"
    }
}
else {
    Write-Status "Part 3: Skipped (-SkipDlpCheck)" "WARN"
}

# ============================================================
# PART 4 — Upstream IRM signal source
# ============================================================
Write-Status "Part 4: Checking upstream Insider Risk Management policy state..."
$irmEnabledCount = 0
try {
    if (-not (Get-ConnectionInformation -ErrorAction SilentlyContinue)) {
        Connect-IPPSSession -ShowBanner:$false
    }
    $irmPolicies = Get-InsiderRiskPolicy
    $irmPolicies | Select-Object Name, IsEnabled, CreatedDateTime, ModifiedDateTime |
        Export-Csv "$OutputPath\IRM-Policies.csv" -NoTypeInformation

    $irmEnabledCount = ($irmPolicies | Where-Object { $_.IsEnabled }).Count
    if ($irmEnabledCount -eq 0) {
        Add-Finding "IRM" "Tenant" "NO_ENABLED_IRM_POLICY" "No enabled Insider Risk Management policy found. Adaptive Protection has no upstream signal — any downstream CA/DLP wiring found above is currently inert regardless of its own state. See Insider-Risk-B.md for upstream triage."
        Write-Status "No enabled IRM policy found — Adaptive Protection has no signal source" "WARN"
    } else {
        Write-Status "$irmEnabledCount enabled IRM policy(ies) found" "OK"
    }
}
catch {
    Add-Finding "IRM" "Tenant" "CHECK_FAILED" "IRM policy check failed: $($_.Exception.Message)"
    Write-Status "IRM policy check failed: $($_.Exception.Message)" "ERROR"
}

# ============================================================
# PART 5 — Orphan detection (CA policies with no live upstream signal)
# ============================================================
Write-Status "Part 5: Cross-referencing CA arm against upstream IRM signal health..."
if ($caInsiderPolicies.Count -gt 0 -and $irmEnabledCount -eq 0) {
    foreach ($pol in $caInsiderPolicies) {
        Add-Finding "Orphan" $pol.DisplayName "ORPHANED_CA_POLICY" "CA policy references insider risk levels but no IRM policy is currently enabled — this policy will never see a matching user. Likely leftover from a paused/decommissioned Adaptive Protection deployment; confirm before deleting since disabling AP does not auto-remove CA policies."
    }
    Write-Status "$($caInsiderPolicies.Count) CA policy(ies) flagged as possibly orphaned" "WARN"
} else {
    Write-Status "No orphan signal detected from available data" "OK"
}

# ============================================================
# Manual-check reminder (no read cmdlet exists for these)
# ============================================================
$manualNote = @"
The following Adaptive Protection state has NO PowerShell/Graph read cmdlet as of
this writing and must be confirmed manually in the Purview portal:

  - Adaptive Protection master on/off toggle
      Purview > Insider Risk Management > Adaptive protection > Adaptive Protection settings

  - Insider risk level definitions/criteria/thresholds (Elevated/Moderate/Minor)
      Purview > Adaptive protection > Insider risk levels

  - Data Lifecycle Management opt-in sub-toggle
      Purview > Data lifecycle management > Adaptive protection in Data Lifecycle Management

  - Per-user assigned insider risk level and its source policy
      Purview > Adaptive protection > Users assigned insider risk levels > [user] >
      Adaptive protection summary tab
"@
$manualNote | Out-File "$OutputPath\MANUAL-CHECKS-REQUIRED.txt"
Write-Status "Manual-check reminder written to MANUAL-CHECKS-REQUIRED.txt" "INFO"

# ============================================================
# Summary
# ============================================================
$findings | Export-Csv "$OutputPath\Findings-Summary.csv" -NoTypeInformation

Write-Host "`n=== Adaptive Protection Audit Summary ===" -ForegroundColor Cyan
if ($findings.Count -eq 0) {
    Write-Status "No issues flagged across all checked areas." "OK"
} else {
    $findings | Group-Object Flag | Sort-Object Count -Descending |
        ForEach-Object { Write-Status "$($_.Name): $($_.Count)" "WARN" }
}
Write-Host "`nFull report saved to: $OutputPath" -ForegroundColor Green
