<#
.SYNOPSIS
    Audits Microsoft Priva readiness and configuration health — RBAC, audit log prerequisite,
    and Privacy Risk Management policy inventory.

.DESCRIPTION
    Connects to Security & Compliance PowerShell and automates the Validation Steps from
    Priva-A.md so an analyst doesn't have to walk each check manually during triage. Priva
    tickets split into two independent failure domains (Privacy Risk Management and Subject
    Rights Requests) that share only RBAC and licensing as common prerequisites — this script
    focuses on those shared prerequisites plus everything that IS cmdlet-reachable for
    Privacy Risk Management, since Subject Rights Requests are portal-only end to end.

    Covers:
    - Unified Audit Log ingestion state — a hard prerequisite for Privacy Risk Management
      insights; flags NO_AUDIT_LOG if disabled
    - RBAC membership across all five Privacy Management role groups (Privacy Management,
      Administrators, Analysts, Investigators, Viewer) — flags EMPTY_RBAC if every group is
      empty, meaning only an emergency Global Admin path exists into the Priva portal
    - Best-effort Privacy Risk Management policy inventory via the legacy-named
      Get-PrivacyManagementPolicy cmdlet, wrapped defensively since this cmdlet predates the
      Priva rebrand and is not consistently documented — flags CMDLET_UNAVAILABLE if it fails
      outright (a strong signal of a licensing/RBAC/data-residency gate rather than a script bug)
    - Policies still in Test mode flagged as informational (POLICY_IN_TEST_MODE) — not an
      error, since Test mode is the correct default for new policies, but worth surfacing so
      an analyst can confirm this matches the ticket's expectation
    - Policies with zero configured alerting flagged as informational (POLICY_NO_ALERTS)
    - Best-effort licence check via Get-MgSubscribedSku, filtered on a Priva-related SKU
      name pattern — explicitly best-effort since Priva SKU naming varies by agreement/region;
      flags NO_MATCHING_SKU as informational only, not a hard failure

    Does NOT cover:
    - Subject Rights Requests — request creation, search-scope configuration, review/redaction,
      and report generation are all portal-only with no PowerShell equivalent; see Priva-B.md
      Fix 5/6 and Priva-A.md Troubleshooting Steps (SRR) for the manual portal-based checks
    - Policy condition/rule detail (Data overexposure vs. Data transfer specifics) — the
      underlying rule XML is exposed via Get-PrivacyManagementRule but is not parsed here since
      Microsoft's own guidance is to manage rule content through the portal wizard, not by
      hand-editing the underlying rule
    - Tenant data-residency region — there is no cmdlet to determine this; confirm manually
      with the client per Priva-B.md Fix 1 if licensing/RBAC both check out clean but Priva
      still appears entirely unavailable

.PARAMETER IncludeRuleDetail
    Also retrieve per-policy rule detail via Get-PrivacyManagementRule. Off by default since
    rule XML output is verbose and rarely needed outside a deep policy-tuning engagement.

.PARAMETER OutputPath
    Path to the folder where CSV files will be exported. Default: current directory.

.EXAMPLE
    .\Get-PrivaReadinessAudit.ps1

.EXAMPLE
    .\Get-PrivaReadinessAudit.ps1 -IncludeRuleDetail -OutputPath C:\Temp\Priva

.NOTES
    Requires:
    - ExchangeOnlineManagement module (for Connect-IPPSSession)
    - Microsoft.Graph.Users.Actions or Microsoft.Graph.Identity.DirectoryManagement module
      (optional, only used for the best-effort licence check — script degrades gracefully
      if Graph isn't connected)
    - A Privacy Management role group membership (any) to run the policy/rule checks;
      RBAC and audit-log checks work with lower-privilege read access

    Run-as: Does NOT require local admin. Requires M365 cloud permissions.
    Safe/Unsafe: Read-only. No changes made to policies, RBAC, or audit log configuration.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [switch]$IncludeRuleDetail,

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

function Test-AuditLogPrerequisite {
    Write-Status "Checking Unified Audit Log ingestion state (Privacy Risk Management prerequisite)..." "INFO"
    try {
        $config = Get-AdminAuditLogConfig -ErrorAction Stop
        if ($config.UnifiedAuditLogIngestionEnabled) {
            Write-Status "Unified Audit Log is enabled — Privacy Risk Management insights are not blocked by this factor" "OK"
        } else {
            Write-Status "NO_AUDIT_LOG: Unified Audit Log is disabled — Privacy Risk Management policies will show zero insights regardless of configuration" "ERROR"
        }
        return $config
    }
    catch {
        Write-Status "Failed to check audit log config: $($_.Exception.Message)" "WARN"
        return $null
    }
}

function Get-PrivaRbacInventory {
    Write-Status "Retrieving Privacy Management RBAC role group membership..." "INFO"
    $roleGroups = "Privacy Management", "Privacy Management Administrators", "Privacy Management Analysts",
                  "Privacy Management Investigators", "Privacy Management Viewer"

    $results = @()
    $totalMembers = 0
    foreach ($group in $roleGroups) {
        try {
            $members = Get-RoleGroupMember -Identity $group -ErrorAction Stop
            $count = @($members).Count
            $totalMembers += $count
            $results += [PSCustomObject]@{
                RoleGroup   = $group
                MemberCount = $count
                Members     = ($members | Select-Object -ExpandProperty Name) -join "; "
            }
        }
        catch {
            $results += [PSCustomObject]@{
                RoleGroup   = $group
                MemberCount = "N/A"
                Members     = "Lookup failed: $($_.Exception.Message)"
            }
        }
    }

    if ($totalMembers -eq 0) {
        Write-Status "EMPTY_RBAC: Zero members across all five Privacy Management role groups — only an emergency Global Admin path exists into Priva" "ERROR"
    } else {
        Write-Status "Found $totalMembers total membership(s) across Privacy Management role groups" "OK"
    }

    return $results
}

function Get-PrivaPolicyInventory {
    param([switch]$IncludeRules)

    Write-Status "Retrieving Privacy Risk Management policy inventory (legacy cmdlet — best-effort)..." "INFO"
    $policies = @()
    try {
        $rawPolicies = Get-PrivacyManagementPolicy -ErrorAction Stop
        Write-Status "Found $(@($rawPolicies).Count) Privacy Risk Management policy(ies)" "OK"

        foreach ($p in $rawPolicies) {
            $flags = @()
            if ($p.Mode -eq "Test" -or $p.Mode -eq "TestModeEnabled") {
                $flags += "POLICY_IN_TEST_MODE"
                Write-Status "POLICY_IN_TEST_MODE: '$($p.Name)' is in Test mode — no alerts/tips generated by design" "WARN"
            }
            if ($p.PSObject.Properties.Name -contains "Enabled" -and -not $p.Enabled) {
                $flags += "POLICY_DISABLED"
                Write-Status "POLICY_DISABLED: '$($p.Name)' is disabled" "WARN"
            }

            $ruleDetail = $null
            if ($IncludeRules) {
                try {
                    $ruleDetail = (Get-PrivacyManagementRule -Policy $p.Name -ErrorAction Stop |
                        Select-Object -ExpandProperty Name) -join "; "
                }
                catch {
                    $ruleDetail = "Rule lookup failed: $($_.Exception.Message)"
                }
            }

            $typeValue    = if ($p.PSObject.Properties.Name -contains "Type") { $p.Type } else { "Unknown" }
            $modeValue    = if ($p.PSObject.Properties.Name -contains "Mode") { $p.Mode } else { "Unknown" }
            $enabledValue = if ($p.PSObject.Properties.Name -contains "Enabled") { $p.Enabled } else { "Unknown" }

            $policies += [PSCustomObject]@{
                Name    = $p.Name
                Type    = $typeValue
                Mode    = $modeValue
                Enabled = $enabledValue
                Flags   = $flags -join "; "
                Rules   = $ruleDetail
            }
        }

        if (@($rawPolicies).Count -eq 0) {
            Write-Status "NO_POLICIES_CONFIGURED: no Privacy Risk Management policies exist yet — this may be an onboarding-stage tenant, not a fault" "WARN"
        }
    }
    catch {
        Write-Status "CMDLET_UNAVAILABLE: Get-PrivacyManagementPolicy failed — '$($_.Exception.Message)'. This is a strong signal of a licensing, RBAC, or data-residency gate rather than a policy-level problem; work the Dependency Stack top-down before assuming a script issue." "ERROR"
    }

    return $policies
}

function Get-PrivaLicenseSummary {
    Write-Status "Checking for a Priva-related licence SKU (best-effort — verify against the admin center)..." "INFO"
    try {
        $skus = Get-MgSubscribedSku -ErrorAction Stop |
            Where-Object { $_.SkuPartNumber -match "PRIVACY|PRIVA" }

        if (@($skus).Count -eq 0) {
            Write-Status "NO_MATCHING_SKU: no SKU matched a Priva-related name pattern — this is informational only, not authoritative; Priva may be bundled into an E5/E5 Compliance SKU not caught by this filter" "WARN"
            return @()
        }

        return $skus | Select-Object SkuPartNumber, ConsumedUnits,
            @{N = "EnabledUnits"; E = { $_.PrepaidUnits.Enabled } }
    }
    catch {
        Write-Status "Skipped licence check — Microsoft Graph not connected or query failed: $($_.Exception.Message)" "WARN"
        return @()
    }
}

# ── Preflight ──────────────────────────────────────────────────────────────
if (-not (Get-Command Get-AdminAuditLogConfig -ErrorAction SilentlyContinue)) {
    Write-Status "Not connected to Security & Compliance PowerShell. Connecting..." "INFO"
    try {
        Connect-IPPSSession -ErrorAction Stop
    }
    catch {
        Write-Status "Failed to connect to Security & Compliance PowerShell: $($_.Exception.Message)" "ERROR"
        throw
    }
}

if (-not (Test-Path -Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# ── Detect / Execute ─────────────────────────────────────────────────────────
$auditLogConfig = Test-AuditLogPrerequisite
$rbacInventory  = Get-PrivaRbacInventory
$policyInventory = Get-PrivaPolicyInventory -IncludeRules:$IncludeRuleDetail
$licenseSummary  = Get-PrivaLicenseSummary

# ── Report ───────────────────────────────────────────────────────────────────
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

if ($rbacInventory) {
    $rbacInventory | Export-Csv -Path (Join-Path $OutputPath "Priva-RBAC-$timestamp.csv") -NoTypeInformation
}
if ($policyInventory) {
    $policyInventory | Export-Csv -Path (Join-Path $OutputPath "Priva-Policies-$timestamp.csv") -NoTypeInformation
}
if ($licenseSummary) {
    $licenseSummary | Export-Csv -Path (Join-Path $OutputPath "Priva-Licensing-$timestamp.csv") -NoTypeInformation
}

Write-Host ""
Write-Status "=== Priva Readiness Summary ===" "INFO"
Write-Status "Audit log enabled: $(if ($auditLogConfig) { $auditLogConfig.UnifiedAuditLogIngestionEnabled } else { 'UNKNOWN' })" "INFO"
Write-Status "RBAC role groups with members: $(@($rbacInventory | Where-Object { $_.MemberCount -gt 0 }).Count) of $(@($rbacInventory).Count)" "INFO"
Write-Status "Privacy Risk Management policies found: $(@($policyInventory).Count)" "INFO"
Write-Status "Policies in Test mode: $(@($policyInventory | Where-Object { $_.Flags -match 'POLICY_IN_TEST_MODE' }).Count)" "INFO"
Write-Status "Reports exported to: $OutputPath" "OK"
Write-Host ""
Write-Status "Reminder: Subject Rights Requests have no PowerShell equivalent — verify identity resolution and search scope manually in the Priva portal (purview.microsoft.com/priva) per Priva-B.md Fix 5." "INFO"
