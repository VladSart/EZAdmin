<#
.SYNOPSIS
    Audits tenant-wide Conditional Access Token Protection configuration for the design and
    scoping gaps TokenProtection-A/B.md flag as the recurring causes of unexpected blocking.

.DESCRIPTION
    Runs a single-pass, read-only audit across every Conditional Access policy that has the
    Token Protection session control (Graph property SessionControls.SecureSignInSession)
    enabled, and flags:

    - BROWSER_CLIENT_APP_RISK — the policy's Client App Types condition either isn't configured
      at all, includes "browser", or includes "all" — meaning MSAL.js browser apps (e.g. Teams
      Web) can be silently blocked, since Token Protection can never be satisfied by a browser
      session (TokenProtection-A.md's Layer 3 / Playbook 3).
    - OFFICE365_APPGROUP_TARGET — the policy targets the broad "Office 365" application group
      instead of individually-selected resources, an explicit documented exception flagged in
      the deployment guide as a cause of unintended failures (TokenProtection-A.md Playbook 3).
    - NO_DEVICE_FILTER_EXCLUSIONS — the policy has no device filter configured at all, meaning
      permanently-unsupported device registration types (Entra-joined AVD session hosts, Entra-
      joined Windows 365 Cloud PCs, bulk-enrolled devices, Autopilot self-deploy, Entra-joined
      Power Automate hosted machine groups, Entra-joined Azure VM sign-in-extension hosts) have
      no exclusion path and will simply fail with statusCode 1003 (TokenProtection-A/B.md Fix 1
      / Playbook 2).
    - NON_WINDOWS_PLATFORM_GAP — tenant-wide check (not per-policy): looks for whether a
      complementary "block unknown platform" / "require compliant device for all platforms"
      style policy exists, since Token Protection itself cannot cover non-Windows/non-Apple
      platforms (TokenProtection-A/B.md Playbook 4 / Fix 5).
    - STILL_REPORT_ONLY_STALE — policy has been in report-only state longer than a configurable
      threshold with no apparent progression, which may indicate a stalled pilot rather than an
      intentional long-term report-only policy.

    This script does NOT query sign-in logs (statusCode-level diagnosis requires Log Analytics
    KQL — see the Evidence Pack query in TokenProtection-A.md) — it audits policy DESIGN only.
    Read-only throughout. Makes no changes to any policy.

.PARAMETER StaleReportOnlyDays
    Number of days a policy can remain in report-only state before being flagged as
    STILL_REPORT_ONLY_STALE. Default: 30.

.PARAMETER KnownDeviceFilterExclusionPatterns
    Array of substrings that, if found in a policy's device filter rule, are treated as
    evidence the policy already accounts for at least one documented unsupported device type.
    Default covers the five documented exclusion patterns from the deployment guide.

.PARAMETER OutputPath
    Path to export CSV reports. Default: C:\Temp\TokenProtectionCoverageAudit-<timestamp>

.EXAMPLE
    .\Get-TokenProtectionCoverageAudit.ps1

.EXAMPLE
    # Treat anything still in report-only after 2 weeks as stale
    .\Get-TokenProtectionCoverageAudit.ps1 -StaleReportOnlyDays 14

.NOTES
    Requires: Microsoft.Graph.Identity.SignIns module
    Install:  Install-Module Microsoft.Graph -Scope CurrentUser
    Auth:     Connect-MgGraph -Scopes "Policy.Read.All","Directory.Read.All"
    Permissions: Conditional Access Administrator (read) or Global Reader
    Companion runbooks: Security/ConditionalAccess/TokenProtection-A.md and TokenProtection-B.md
#>

[CmdletBinding()]
param(
    [Parameter()][int]$StaleReportOnlyDays = 30,
    [Parameter()][string[]]$KnownDeviceFilterExclusionPatterns = @(
        "CloudPC",
        "AzureVirtualDesktop",
        "MicrosoftPowerAutomate",
        "enrollmentProfileName",
        "SecureVM"
    ),
    [Parameter()][string]$OutputPath = "C:\Temp\TokenProtectionCoverageAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
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

Write-Status "Checking for required Microsoft Graph module..."
if (-not (Get-Module -ListAvailable -Name "Microsoft.Graph.Identity.SignIns")) {
    Write-Status "Microsoft.Graph.Identity.SignIns not found. Installing..." "WARN"
    Install-Module Microsoft.Graph.Identity.SignIns -Scope CurrentUser -Force -AllowClobber
}

Write-Status "Connecting to Microsoft Graph..."
Connect-MgGraph -Scopes "Policy.Read.All","Directory.Read.All" -NoWelcome

if (-not (Get-MgContext)) {
    Write-Status "Graph connection failed." "ERROR"
    exit 1
}

# ─── Detect: pull every CA policy, filter to Token Protection ────────────────

Write-Status "Retrieving all Conditional Access policies..."
$AllPolicies = Get-MgIdentityConditionalAccessPolicy -All

$TokenProtectionPolicies = $AllPolicies | Where-Object {
    $_.SessionControls -and
    $_.SessionControls.SecureSignInSession -and
    $_.SessionControls.SecureSignInSession.IsEnabled -eq $true
}

Write-Status "Found $($AllPolicies.Count) total policies; $($TokenProtectionPolicies.Count) require Token Protection." "OK"

if ($TokenProtectionPolicies.Count -eq 0) {
    Write-Status "No policies with Token Protection configured — nothing further to audit. Exiting." "WARN"
    Disconnect-MgGraph | Out-Null
    exit 0
}

$Findings = [System.Collections.Generic.List[PSCustomObject]]::new()
$StaleCutoff = (Get-Date).ToUniversalTime().AddDays(-$StaleReportOnlyDays)

# ─── Execute: per-policy checks ────────────────────────────────────────────────

foreach ($Policy in $TokenProtectionPolicies) {
    $Flags = [System.Collections.Generic.List[string]]::new()

    $ClientAppTypes = @($Policy.Conditions.ClientAppTypes)
    $IncludeApps    = @($Policy.Conditions.Applications.IncludeApplications)
    $DeviceFilterRule = $Policy.Conditions.Devices.DeviceFilter.Rule
    $DeviceFilterMode = $Policy.Conditions.Devices.DeviceFilter.Mode

    # --- BROWSER_CLIENT_APP_RISK ---
    $ConfiguredNarrowly = ($ClientAppTypes.Count -gt 0) -and
                          ($ClientAppTypes -notcontains "all") -and
                          ($ClientAppTypes -notcontains "browser")
    if (-not $ConfiguredNarrowly) {
        $Flags.Add("BROWSER_CLIENT_APP_RISK")
    }

    # --- OFFICE365_APPGROUP_TARGET ---
    # The Office 365 app group is represented by a well-known GUID in Graph
    # (Office365 all-apps group ID: 00000006-0000-0ff1-ce00-000000000000-style constants vary by
    # tenant export tooling — the safer signal is IncludeApplications containing "Office365" or
    # the "All" catch-all combined with a non-empty ExcludeApplications, which is how the app
    # group typically surfaces via Graph). Flag conservatively on either signal.
    $LooksLikeAppGroup = ($IncludeApps -contains "Office365") -or
                          ($IncludeApps -contains "All" -and $Policy.Conditions.Applications.ExcludeApplications.Count -eq 0 -and $IncludeApps.Count -eq 1)
    if ($LooksLikeAppGroup) {
        $Flags.Add("OFFICE365_APPGROUP_TARGET")
    }

    # --- NO_DEVICE_FILTER_EXCLUSIONS ---
    $HasAnyKnownExclusion = $false
    if ($DeviceFilterRule) {
        foreach ($Pattern in $KnownDeviceFilterExclusionPatterns) {
            if ($DeviceFilterRule -match [regex]::Escape($Pattern)) {
                $HasAnyKnownExclusion = $true
                break
            }
        }
    }
    if (-not $DeviceFilterRule -or ($DeviceFilterMode -ne "exclude" -and -not $HasAnyKnownExclusion)) {
        $Flags.Add("NO_DEVICE_FILTER_EXCLUSIONS")
    }

    # --- STILL_REPORT_ONLY_STALE ---
    if ($Policy.State -eq "enabledForReportingButNotEnforced") {
        $LastTouched = @($Policy.CreatedDateTime, $Policy.ModifiedDateTime) | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1
        if ($LastTouched -and [datetime]$LastTouched -le $StaleCutoff) {
            $Flags.Add("STILL_REPORT_ONLY_STALE")
        }
    }

    $Findings.Add([PSCustomObject]@{
        DisplayName       = $Policy.DisplayName
        PolicyId          = $Policy.Id
        State             = $Policy.State
        CreatedDateTime   = $Policy.CreatedDateTime
        ModifiedDateTime  = $Policy.ModifiedDateTime
        ClientAppTypes    = ($ClientAppTypes -join ", ")
        IncludeApplications = ($IncludeApps -join ", ")
        DeviceFilterMode  = $DeviceFilterMode
        DeviceFilterRule  = $DeviceFilterRule
        Flags             = ($Flags -join "; ")
    })
}

# --- NON_WINDOWS_PLATFORM_GAP (tenant-wide, not per Token Protection policy) ---
$CompensatingPolicies = $AllPolicies | Where-Object {
    $_.State -in @("enabled","enabledForReportingButNotEnforced") -and
    (
        ($_.GrantControls.BuiltInControls -contains "block" -and
         @($_.Conditions.Platforms.IncludePlatforms) -contains "all" -and
         @($_.Conditions.Platforms.ExcludePlatforms).Count -gt 0)
        -or
        ($_.GrantControls.BuiltInControls -contains "compliantDevice")
    )
}
$HasCompensatingControl = $CompensatingPolicies.Count -gt 0

# ─── Report ────────────────────────────────────────────────────────────────────

Write-Status "`n═══════════════════════════════════════════════" "OK"
Write-Status "TOKEN PROTECTION COVERAGE AUDIT SUMMARY" "OK"
Write-Status "Policies with Token Protection enabled: $($TokenProtectionPolicies.Count)"

$BrowserRisk   = $Findings | Where-Object { $_.Flags -match "BROWSER_CLIENT_APP_RISK" }
$AppGroupRisk  = $Findings | Where-Object { $_.Flags -match "OFFICE365_APPGROUP_TARGET" }
$NoDeviceFilter = $Findings | Where-Object { $_.Flags -match "NO_DEVICE_FILTER_EXCLUSIONS" }
$StaleReportOnly = $Findings | Where-Object { $_.Flags -match "STILL_REPORT_ONLY_STALE" }

Write-Status "BROWSER_CLIENT_APP_RISK      : $($BrowserRisk.Count)" $(if ($BrowserRisk.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "OFFICE365_APPGROUP_TARGET    : $($AppGroupRisk.Count)" $(if ($AppGroupRisk.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "NO_DEVICE_FILTER_EXCLUSIONS  : $($NoDeviceFilter.Count)" $(if ($NoDeviceFilter.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "STILL_REPORT_ONLY_STALE      : $($StaleReportOnly.Count)" $(if ($StaleReportOnly.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "NON_WINDOWS_PLATFORM_GAP     : $(if ($HasCompensatingControl) { 'No compensating-control gap detected' } else { 'GAP — no Block-unknown-platform or Require-compliant-device policy found' })" $(if ($HasCompensatingControl) { "OK" } else { "WARN" })

if ($BrowserRisk.Count -gt 0) {
    Write-Status "`nPolicies at risk of silently blocking browser apps (e.g. Teams Web):" "WARN"
    $BrowserRisk | ForEach-Object { Write-Host "  - $($_.DisplayName)" -ForegroundColor Yellow }
}

if ($NoDeviceFilter.Count -gt 0) {
    Write-Status "`nPolicies with no device filter exclusions — permanently-unsupported device types will hard-fail (statusCode 1003):" "WARN"
    $NoDeviceFilter | ForEach-Object { Write-Host "  - $($_.DisplayName)" -ForegroundColor Yellow }
}

$Findings | Sort-Object Flags -Descending | Export-Csv -Path "$OutputPath-Policies.csv" -NoTypeInformation
Write-Status "`nReports exported to: $OutputPath-Policies.csv" "OK"

Write-Status "`nNOTE: This script audits policy DESIGN only. For per-sign-in statusCode diagnosis (1002/1003/1005/1006/1008), run the Log Analytics KQL query in TokenProtection-A.md's Evidence Pack against a workspace ingesting AADNonInteractiveUserSignInLogs." "INFO"

Disconnect-MgGraph | Out-Null
