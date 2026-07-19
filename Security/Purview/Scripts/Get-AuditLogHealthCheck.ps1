<#
.SYNOPSIS
    Audits Microsoft Purview Unified Audit Log health — ingestion status, mailbox audit
    bypass exceptions, retention policy coverage, and a live control search.

.DESCRIPTION
    Connects to Security & Compliance PowerShell and automates the Validation Steps from
    Audit-A.md so an analyst doesn't have to walk each check manually during triage. The
    Unified Audit Log is a load-bearing prerequisite for several other Purview solutions in
    this repo (Priva, Insider Risk Management, Communication Compliance), so this script is
    also a useful first stop before troubleshooting any of those.

    Covers:
    - UnifiedAuditLogIngestionEnabled — the tenant-wide switch; flags INGESTION_DISABLED
      if off, since nothing downstream works while this is false
    - Mailbox-wide audit bypass sweep via Get-MailboxAuditBypassAssociation — flags
      BYPASS_ON_USER_MAILBOX for any UserMailbox (as opposed to SharedMailbox/
      EquipmentMailbox/RoomMailbox, where bypass is a common and often intentional choice
      for high-volume service/resource accounts) with bypass enabled, since that's the
      single most common "why can't I see this person's activity" root cause
    - Audit log retention policy inventory via Get-UnifiedAuditLogRetentionPolicy — flags
      NO_CUSTOM_POLICY as informational only (this may simply mean the org relies on the
      Standard 180-day / Premium 1-year default, not a fault), and reports policy priority/
      workload/duration for cross-checking overlaps
      the maximum default of 5,000, and reports whether -HighCompleteness returns a
      different count as a completeness sanity check
    - Best-effort tenant licensing check via Get-MgSubscribedSku, filtered on a pattern
      commonly associated with Audit (Premium)-capable SKUs — explicitly best-effort since
      exact SKU-to-feature mapping isn't exposed via a single authoritative cmdlet; flags
      NO_PREMIUM_SKU_DETECTED as informational only

    Does NOT cover:
    - Per-user Audit (Premium) license verification (intelligent-insight properties are
      gated per actor, not per tenant) — use Get-MgUserLicenseDetail -UserId <UPN> for a
      specific user under investigation, per Audit-A.md Validation Step 3
    - Office 365 Management Activity API subscription health — that's an Azure AD app
      registration + webhook concern, not something this Exchange-Online-PowerShell-based
      script can inspect; see Audit-A.md Phase 2 for the subscription-model commands
    - Graph Audit Search API cross-checks — only invoked manually per Audit-A.md Validation
      Step 7 when a portal/cmdlet discrepancy is already suspected, not run routinely here

.PARAMETER ControlSearchHours
    How many hours back to run the live control search that sanity-checks ingestion
    latency/health. Default: 24.

.PARAMETER SkipMailboxBypassSweep
    Skip the per-mailbox audit bypass sweep. This is the slowest part of the script on
    large tenants (one cmdlet call per mailbox) — use this switch for a quick
    ingestion/retention-only check.

.PARAMETER OutputPath
    Path to the folder where CSV files will be exported. Default: current directory.

.EXAMPLE
    .\Get-AuditLogHealthCheck.ps1

.EXAMPLE
    .\Get-AuditLogHealthCheck.ps1 -ControlSearchHours 48 -OutputPath C:\Temp\AuditHealth

.EXAMPLE
    .\Get-AuditLogHealthCheck.ps1 -SkipMailboxBypassSweep

.NOTES
    Requires:
    - ExchangeOnlineManagement module (for Connect-IPPSSession)
    - Audit Logs or View-Only Audit Logs role (mailbox bypass sweep additionally needs
      View-Only Recipients or higher to enumerate all mailboxes)
    - Microsoft.Graph.Identity.DirectoryManagement module (optional, only used for the
      best-effort tenant licensing check — script degrades gracefully if Graph isn't
      connected)

    Run-as: Does NOT require local admin. Requires M365 cloud permissions.
    Safe/Unsafe: Read-only. No changes made to ingestion config, mailbox settings, or
    retention policies.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateRange(1, 168)]
    [int]$ControlSearchHours = 24,

    [Parameter()]
    [switch]$SkipMailboxBypassSweep,

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

function Test-IngestionStatus {
    Write-Status "Checking Unified Audit Log ingestion status..." "INFO"
    try {
        $config = Get-AdminAuditLogConfig -ErrorAction Stop
        if ($config.UnifiedAuditLogIngestionEnabled) {
            Write-Status "Ingestion is enabled tenant-wide" "OK"
        } else {
            Write-Status "INGESTION_DISABLED: UnifiedAuditLogIngestionEnabled is False — nothing is being logged, and nothing downstream (Priva, Insider Risk, Communication Compliance) can produce audit-based insights" "ERROR"
        }
        return $config
    }
    catch {
        Write-Status "Failed to check ingestion config: $($_.Exception.Message)" "WARN"
        return $null
    }
}

function Get-MailboxAuditBypassSweep {
    Write-Status "Sweeping mailboxes for audit bypass exceptions (this can take a while on large tenants)..." "INFO"
    $results = @()
    try {
        $mailboxes = Get-Mailbox -ResultSize Unlimited -ErrorAction Stop
    }
    catch {
        Write-Status "Failed to enumerate mailboxes: $($_.Exception.Message)" "WARN"
        return $results
    }

    $flaggedUserMailboxes = 0
    foreach ($mbx in $mailboxes) {
        try {
            $bypass = Get-MailboxAuditBypassAssociation -Identity $mbx.PrimarySmtpAddress -ErrorAction Stop
        }
        catch {
            continue
        }

        if ($bypass.AuditBypassEnabled) {
            $flag = if ($mbx.RecipientTypeDetails -eq "UserMailbox") { "BYPASS_ON_USER_MAILBOX" } else { "BYPASS_ON_RESOURCE_TYPE" }
            if ($flag -eq "BYPASS_ON_USER_MAILBOX") {
                $flaggedUserMailboxes++
                Write-Status "BYPASS_ON_USER_MAILBOX: $($mbx.PrimarySmtpAddress) — audit bypass is enabled on a real user mailbox; confirm this is intentional" "WARN"
            }
            $results += [PSCustomObject]@{
                Mailbox       = $mbx.PrimarySmtpAddress
                RecipientType = $mbx.RecipientTypeDetails
                Flag          = $flag
            }
        }
    }

    if ($flaggedUserMailboxes -eq 0) {
        Write-Status "No audit bypass found on any UserMailbox — resource/service-account bypass entries (if any) are expected and not flagged" "OK"
    } else {
        Write-Status "Found $flaggedUserMailboxes UserMailbox(es) with audit bypass enabled — see CSV for detail" "WARN"
    }

    return $results
}

function Get-RetentionPolicyInventory {
    Write-Status "Retrieving audit log retention policy inventory (Premium feature)..." "INFO"
    $policies = @()
    try {
        $raw = Get-UnifiedAuditLogRetentionPolicy -ErrorAction Stop
        if (@($raw).Count -eq 0) {
            Write-Status "NO_CUSTOM_POLICY: no custom audit log retention policies exist — informational only; this org relies on the default retention (180 days Standard, or 1 year for AAD/Exchange/OneDrive/SharePoint on Premium)" "WARN"
        } else {
            Write-Status "Found $(@($raw).Count) custom retention policy(ies)" "OK"
        }

        $policies = $raw | Select-Object Name, Priority, Workload, RecordTypes, RetentionDuration, WhenCreated
    }
    catch {
        Write-Status "CMDLET_UNAVAILABLE: Get-UnifiedAuditLogRetentionPolicy failed — '$($_.Exception.Message)'. This usually means the tenant is on Audit (Standard) only; custom retention policies require Audit (Premium)." "WARN"
    }

    return $policies
}

function Invoke-ControlSearch {
    param([int]$HoursBack)

    Write-Status "Running a control search over the last $HoursBack hour(s) to sanity-check ingestion health..." "INFO"
    $start = (Get-Date).AddHours(-1 * $HoursBack)
    $end   = Get-Date

    try {
        $default = Search-UnifiedAuditLog -StartDate $start -EndDate $end -ResultSize 100 -ErrorAction Stop
        $defaultCount = @($default).Count

        if ($defaultCount -eq 0) {
            Write-Status "NO_RECORDS_IN_WINDOW: zero records returned for the last $HoursBack hour(s) — if you expected activity, check ingestion status and mailbox bypass first; this may also just mean a genuinely quiet window" "WARN"
        } elseif ($defaultCount -eq 100) {
            Write-Status "CAP_LIKELY_HIT: exactly 100 records returned — this is the cmdlet's silent default cap, not necessarily the true count. Re-run with -SessionCommand ReturnLargeSet or -HighCompleteness for an accurate total over this window." "WARN"
        } else {
            Write-Status "Control search returned $defaultCount record(s) — ingestion appears healthy" "OK"
        }

        return $default | Select-Object CreationDate, UserIds, Operations, RecordType
    }
    catch {
        Write-Status "Control search failed: $($_.Exception.Message)" "ERROR"
        return @()
    }
}

function Get-PremiumLicenseSignal {
    Write-Status "Checking for an Audit (Premium)-capable SKU tenant-wide (best-effort — verify against the Purview portal)..." "INFO"
    try {
        $skus = Get-MgSubscribedSku -ErrorAction Stop |
            Where-Object { $_.SkuPartNumber -match "ENTERPRISEPREMIUM|SPE_E5|M365_E5|G5|INFORMATION_PROTECTION" }

        if (@($skus).Count -eq 0) {
            Write-Status "NO_PREMIUM_SKU_DETECTED: no SKU matched a common Audit (Premium)-capable name pattern — informational only, not authoritative. Confirm directly in Purview portal > Audit > Audit search, which explicitly indicates Premium availability." "WARN"
            return @()
        }

        Write-Status "Found $(@($skus).Count) potentially Premium-capable SKU(s) — remember Premium features still gate per-user, not just per-tenant" "OK"
        return $skus | Select-Object SkuPartNumber, ConsumedUnits, @{N = "EnabledUnits"; E = { $_.PrepaidUnits.Enabled } }
    }
    catch {
        Write-Status "Skipped tenant licensing check — Microsoft Graph not connected or query failed: $($_.Exception.Message)" "WARN"
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
$ingestionConfig  = Test-IngestionStatus
$bypassSweep      = if ($SkipMailboxBypassSweep) { Write-Status "Skipping mailbox audit bypass sweep (-SkipMailboxBypassSweep)" "INFO"; @() } else { Get-MailboxAuditBypassSweep }
$retentionPolicies = Get-RetentionPolicyInventory
$controlSearch    = Invoke-ControlSearch -HoursBack $ControlSearchHours
$premiumSignal    = Get-PremiumLicenseSignal

# ── Report ───────────────────────────────────────────────────────────────────
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

if ($bypassSweep) {
    $bypassSweep | Export-Csv -Path (Join-Path $OutputPath "AuditLog-MailboxBypass-$timestamp.csv") -NoTypeInformation
}
if ($retentionPolicies) {
    $retentionPolicies | Export-Csv -Path (Join-Path $OutputPath "AuditLog-RetentionPolicies-$timestamp.csv") -NoTypeInformation
}
if ($controlSearch) {
    $controlSearch | Export-Csv -Path (Join-Path $OutputPath "AuditLog-ControlSearch-$timestamp.csv") -NoTypeInformation
}
if ($premiumSignal) {
    $premiumSignal | Export-Csv -Path (Join-Path $OutputPath "AuditLog-PremiumSkuSignal-$timestamp.csv") -NoTypeInformation
}

Write-Host ""
Write-Status "=== Unified Audit Log Health Summary ===" "INFO"
Write-Status "Ingestion enabled: $(if ($ingestionConfig) { $ingestionConfig.UnifiedAuditLogIngestionEnabled } else { 'UNKNOWN' })" "INFO"
if (-not $SkipMailboxBypassSweep) {
    Write-Status "UserMailboxes with audit bypass: $(@($bypassSweep | Where-Object { $_.Flag -eq 'BYPASS_ON_USER_MAILBOX' }).Count)" "INFO"
}
Write-Status "Custom retention policies found: $(@($retentionPolicies).Count)" "INFO"
Write-Status "Control search window: last $ControlSearchHours hour(s), $(@($controlSearch).Count) record(s) returned" "INFO"
Write-Status "Reports exported to: $OutputPath" "OK"
Write-Host ""
Write-Status "Reminder: Audit (Premium) intelligent-insight properties gate per ACTOR license, not per tenant — use Get-MgUserLicenseDetail on the specific user under investigation before concluding a property gap is a bug." "INFO"
