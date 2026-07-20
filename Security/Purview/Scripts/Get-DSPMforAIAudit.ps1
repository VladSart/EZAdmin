<#
.SYNOPSIS
    Audits tenant readiness and default-policy state for Microsoft Purview Data Security
    Posture Management (DSPM) / DSPM for AI — prerequisites, default one-click policies,
    and role/licensing signal.

.DESCRIPTION
    DSPM (current, unified) and its predecessors (DSPM for AI classic, DSPM classic) have
    NO dedicated PowerShell or Graph API surface of their own — the Objectives dashboard,
    AI observability, Asset explorer, and data risk assessments are all Purview-portal-only.
    This script instead audits the adjacent, cmdlet-reachable signals that gate whether DSPM
    can actually observe or protect anything, plus the presence/state of the default
    "DSPM for AI - *" / "Microsoft AI Hub - *" one-click policies DSPM creates in DLP,
    matching the Diagnosis & Validation Flow in DSPM-for-AI-B.md / DSPM-for-AI-A.md.

    Covers:
    - Unified Audit Log ingestion state — the #1 hard blocker for all Copilot/agent activity
      insight in DSPM; flags NO_AUDIT_LOG if disabled
    - Microsoft 365 Copilot license consumption — flags NO_COPILOT_LICENSE if zero consumed
      units are found, meaning there is nothing for DSPM to observe regardless of configuration
    - Default DSPM-created DLP policy inventory (matched by name pattern, since there is no
      dedicated cmdlet or tag identifying "DSPM-owned" policies) — flags NO_DEFAULT_POLICIES
      if none are found at all (a strong signal DSPM onboarding was never actually completed,
      not just that this script can't see them), and POLICY_DISABLED / POLICY_TEST_MODE per
      policy found, since DSPM's own Policies page only ever links out to these, never edits them
    - Legacy preview-era naming — flags LEGACY_AI_HUB_NAMING informationally for any policy
      still carrying the pre-launch "Microsoft AI Hub -" prefix, since Microsoft does not
      rename these retroactively and this is cosmetic, not a fault
    - Sensitivity label publication as a coarse proxy for "Prevent oversharing" readiness —
      flags NO_LABELS_PUBLISHED if zero labels are published tenant-wide, since several DSPM
      remediation actions (Restrict access by label, auto-labeling) depend on labels existing
    - Best-effort Copilot-related Insider Risk Management policy presence via
      Get-InsiderRiskPolicy, wrapped defensively since cmdlet availability/name varies by
      module version — flags CMDLET_UNAVAILABLE rather than failing the whole script

    Does NOT cover (no stable cmdlet/API surface as of this writing — confirm manually in the
    Purview portal per DSPM-for-AI-B.md's Triage section):
    - Which DSPM solution surface (current/DSPM-for-AI-classic/DSPM-classic) the tenant's
      analysts are actually using day to day
    - Data risk assessment results, schedules, or item-level scan configuration/auth state
    - The separate Entra app registrations required for Microsoft 365 item-level scanning or
      Fabric data risk assessments (this script only confirms whether ANY app registration
      exists matching a naming hint the caller supplies — it cannot confirm the correct Graph
      permission set was granted or that admin consent was completed)
    - AI observability, Asset explorer, or Activity explorer content
    - Purview Data Security AI Content Viewer / Content Explorer Content Viewer role
      assignment — the separately-gated permission controlling actual prompt/response
      visibility; Microsoft Graph does not expose Purview-scoped role assignments through the
      same directory-role cmdlets used for Entra roles, so this must be confirmed manually via
      Purview portal → Roles & scopes
    - Fabric-side configuration of any kind

.PARAMETER FabricAppNameHint
    Optional display-name substring used to do a best-effort existence check for the Fabric
    data risk assessment's Entra app registration. Does not validate permissions or consent —
    see Does NOT cover above.

.PARAMETER M365AppNameHint
    Optional display-name substring used to do a best-effort existence check for the Microsoft
    365 item-level scanning Entra app registration. Same limitations as -FabricAppNameHint.

.PARAMETER OutputPath
    Path to the folder where CSV files will be exported. Default: current directory.

.EXAMPLE
    .\Get-DSPMforAIAudit.ps1

.EXAMPLE
    .\Get-DSPMforAIAudit.ps1 -M365AppNameHint "DSPM-ItemLevel" -FabricAppNameHint "DSPM-Fabric" -OutputPath C:\Temp\DSPM

.NOTES
    Requires:
    - ExchangeOnlineManagement module (for Connect-IPPSSession) to reach Get-AdminAuditLogConfig
      and Get-DlpCompliancePolicy
    - Microsoft.Graph.Identity.DirectoryManagement / Microsoft.Graph.Applications for the
      licensing and best-effort app-registration checks — script degrades gracefully with a
      WARN, not a hard failure, if Graph isn't connected
    - Security & Compliance role sufficient to read DLP policies and (if available)
      Insider Risk Management policies; a Compliance Administrator-family role or Purview
      Security Reader is sufficient for every check this script performs

    Run-as: Does NOT require local admin. Requires M365 cloud permissions.
    Safe/Unsafe: Read-only. No changes made to policies, licensing, or role assignments.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$M365AppNameHint,

    [Parameter()]
    [string]$FabricAppNameHint,

    [Parameter()]
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

function Test-DSPMAuditPrerequisite {
    Write-Status "Checking Unified Audit Log ingestion state (hard prerequisite for all Copilot/agent activity insight in DSPM)..." "INFO"
    try {
        $config = Get-AdminAuditLogConfig -ErrorAction Stop
        if ($config.UnifiedAuditLogIngestionEnabled) {
            Write-Status "Unified Audit Log is enabled — DSPM Copilot/agent activity insight is not blocked by this factor" "OK"
        } else {
            Write-Status "NO_AUDIT_LOG: Unified Audit Log is disabled — DSPM will show zero Copilot/agent activity regardless of licensing or policy configuration, and there is no retroactive backfill once enabled" "ERROR"
        }
        return $config
    }
    catch {
        Write-Status "Failed to check audit log config: $($_.Exception.Message)" "WARN"
        return $null
    }
}

function Test-DSPMCopilotLicensing {
    Write-Status "Checking Microsoft 365 Copilot license consumption (Graph)..." "INFO"
    try {
        $skus = Get-MgSubscribedSku -ErrorAction Stop | Where-Object { $_.SkuPartNumber -match "Copilot" }
        if (-not $skus -or (($skus | Measure-Object -Property ConsumedUnits -Sum).Sum -eq 0)) {
            Write-Status "NO_COPILOT_LICENSE: No consumed Microsoft 365 Copilot license units found — DSPM has nothing to observe for Copilot/agent activity until licenses are assigned" "WARN"
        } else {
            $total = ($skus | Measure-Object -Property ConsumedUnits -Sum).Sum
            Write-Status "Found $total consumed Copilot license unit(s) across $(@($skus).Count) matching SKU(s)" "OK"
        }
        return $skus
    }
    catch {
        Write-Status "Could not check Copilot licensing — Microsoft Graph module not connected or insufficient permissions: $($_.Exception.Message)" "WARN"
        return $null
    }
}

function Get-DSPMDefaultPolicyInventory {
    Write-Status "Retrieving default DSPM-created DLP policy inventory (name-pattern match — no dedicated ownership tag exists)..." "INFO"
    $results = @()
    try {
        $allPolicies = Get-DlpCompliancePolicy -ErrorAction Stop
        $dspmPolicies = $allPolicies | Where-Object { $_.Name -like "*DSPM for AI*" -or $_.Name -like "*Microsoft AI Hub*" }

        if (-not $dspmPolicies -or @($dspmPolicies).Count -eq 0) {
            Write-Status "NO_DEFAULT_POLICIES: No policies matching 'DSPM for AI' or 'Microsoft AI Hub' naming found — DSPM one-click policy onboarding likely was never completed for this tenant (or policies were renamed, which Microsoft does not do by default)" "WARN"
        }

        foreach ($policy in $dspmPolicies) {
            $legacyNaming = $policy.Name -like "*Microsoft AI Hub*"
            if ($legacyNaming) {
                Write-Status "LEGACY_AI_HUB_NAMING (informational, cosmetic only): '$($policy.Name)' retains its pre-launch preview-era name — Microsoft does not rename these retroactively" "INFO"
            }

            if (-not $policy.Enabled) {
                Write-Status "POLICY_DISABLED: '$($policy.Name)' exists but is disabled" "WARN"
            }
            elseif ($policy.Mode -notmatch "Enable|Enforce") {
                Write-Status "POLICY_TEST_MODE: '$($policy.Name)' is in mode '$($policy.Mode)' — detecting/reporting only, not enforcing" "INFO"
            }
            else {
                Write-Status "'$($policy.Name)' is enabled and in an enforcing mode ($($policy.Mode))" "OK"
            }

            $results += [PSCustomObject]@{
                PolicyName    = $policy.Name
                Enabled       = $policy.Enabled
                Mode          = $policy.Mode
                LegacyNaming  = $legacyNaming
                Owner         = "Data Loss Prevention (DSPM never edits this directly)"
            }
        }
    }
    catch {
        Write-Status "Failed to retrieve DLP policy inventory: $($_.Exception.Message)" "WARN"
    }
    return $results
}

function Get-DSPMInsiderRiskSignal {
    Write-Status "Checking for DSPM-related Insider Risk Management policies (best-effort — cmdlet availability varies by module version)..." "INFO"
    $results = @()
    try {
        $irmPolicies = Get-InsiderRiskPolicy -ErrorAction Stop | Where-Object { $_.Name -like "*DSPM for AI*" -or $_.Name -like "*AI*" -or $_.Name -like "*Microsoft AI Hub*" }
        if (-not $irmPolicies -or @($irmPolicies).Count -eq 0) {
            Write-Status "No AI-related Insider Risk Management policies found — 'Detect risky AI usage' / 'Detect when users visit AI sites' recommendations likely not yet actioned" "INFO"
        } else {
            foreach ($p in $irmPolicies) {
                Write-Status "Found Insider Risk policy: '$($p.Name)'" "OK"
                $results += [PSCustomObject]@{ PolicyName = $p.Name }
            }
        }
    }
    catch {
        Write-Status "CMDLET_UNAVAILABLE: Get-InsiderRiskPolicy failed or is not available in this session — confirm manually in the Purview portal (Insider Risk Management → Policies). This is common; the cmdlet's availability depends on module version and does not by itself indicate a licensing problem: $($_.Exception.Message)" "INFO"
    }
    return $results
}

function Test-DSPMSensitivityLabelReadiness {
    Write-Status "Checking published sensitivity label count (coarse proxy for 'Prevent oversharing' remediation readiness)..." "INFO"
    try {
        $labels = Get-Label -ErrorAction Stop
        if (-not $labels -or @($labels).Count -eq 0) {
            Write-Status "NO_LABELS_PUBLISHED: Zero sensitivity labels found — DSPM remediation actions that depend on labels (Restrict access by label, auto-labeling) have nothing to apply until labels are created and published" "WARN"
        } else {
            Write-Status "Found $(@($labels).Count) sensitivity label(s) published" "OK"
        }
        return $labels
    }
    catch {
        Write-Status "Failed to retrieve sensitivity labels: $($_.Exception.Message)" "WARN"
        return $null
    }
}

function Test-DSPMAppRegistrationHint {
    param([string]$NameHint, [string]$Purpose)

    if (-not $NameHint) { return $null }

    Write-Status "Best-effort existence check for the $Purpose Entra app registration (name hint: '$NameHint')..." "INFO"
    try {
        $apps = Get-MgApplication -Filter "startswith(displayName,'$NameHint')" -ErrorAction Stop
        if (-not $apps -or @($apps).Count -eq 0) {
            Write-Status "No app registration found matching '$NameHint' for $Purpose — if this assessment type is failing to authenticate, this is likely why. This check CANNOT confirm the required Graph/Fabric permissions or admin consent were actually granted; verify that manually in Entra ID → App registrations" "WARN"
        } else {
            Write-Status "Found $(@($apps).Count) candidate app registration(s) for $Purpose — verify permission set and admin consent manually, this script does not validate either" "OK"
        }
        return $apps
    }
    catch {
        Write-Status "Could not check app registrations — Microsoft.Graph.Applications module not connected or insufficient permissions: $($_.Exception.Message)" "WARN"
        return $null
    }
}

# ============================================================
# Main
# ============================================================
Write-Status "=== DSPM for AI / DSPM Readiness Audit ===" "INFO"
Write-Status "Reminder: DSPM's Objectives, AI observability, Asset explorer, and data risk assessments have NO PowerShell/API surface. This audit covers only the cmdlet-reachable prerequisites and default policies described in DSPM-for-AI-A.md's Dependency Stack." "INFO"

$auditConfig     = Test-DSPMAuditPrerequisite
$copilotLicenses = Test-DSPMCopilotLicensing
$defaultPolicies = Get-DSPMDefaultPolicyInventory
$irmSignal       = Get-DSPMInsiderRiskSignal
$labels          = Test-DSPMSensitivityLabelReadiness
$m365App         = Test-DSPMAppRegistrationHint -NameHint $M365AppNameHint -Purpose "Microsoft 365 item-level scanning"
$fabricApp       = Test-DSPMAppRegistrationHint -NameHint $FabricAppNameHint -Purpose "Fabric data risk assessment"

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
$timestamp = Get-Date -Format "yyyyMMdd-HHmm"

if ($defaultPolicies) {
    $policyPath = Join-Path $OutputPath "DSPM-DefaultPolicies-$timestamp.csv"
    $defaultPolicies | Export-Csv -Path $policyPath -NoTypeInformation
    Write-Status "Exported default policy inventory to $policyPath" "OK"
}

if ($irmSignal) {
    $irmPath = Join-Path $OutputPath "DSPM-InsiderRiskSignal-$timestamp.csv"
    $irmSignal | Export-Csv -Path $irmPath -NoTypeInformation
    Write-Status "Exported Insider Risk signal to $irmPath" "OK"
}

Write-Status "=== Audit complete ===" "INFO"
Write-Status "Remember: confirm the AI Content Viewer / Content Explorer Content Viewer role assignment manually via Purview portal -> Roles & scopes -- this script cannot read Purview-scoped role assignments. Confirm data risk assessment freshness and Entra app permission/consent state manually in the portal as well." "INFO"
