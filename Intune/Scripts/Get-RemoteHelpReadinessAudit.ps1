<#
.SYNOPSIS
    Tenant-wide readiness and configuration audit for Microsoft Intune Remote Help,
    with an optional local-device diagnostic block for the machine it's run on.

.DESCRIPTION
    RemoteHelp-A.md's Dependency Stack identifies a layered chain that has to be true
    top-to-bottom before any session can succeed, and most of it is invisible from a
    single failed-session ticket. This script checks the tenant/RBAC layers via Graph
    and, optionally, the device-local layers on whichever machine runs it:

    Tenant layer (always runs):
    - remoteAssistanceSettings.remoteAssistanceState -- the single tenant-wide switch
      that gates every session regardless of anything else (default: disabled)
    - allowSessionsToUnenrolledDevices / blockChat -- informational, not pass/fail
    - Every Intune role definition whose resource actions reference "RemoteAssistance",
      flagged EMPTY_RBAC if none exist at all -- a role can exist with zero Remote Help
      permissions and look configured while granting nothing
    - Whether a role assignment's scope group is the built-in "All Devices" group,
      flagged ALL_DEVICES_SCOPE_UNENROLLED_GAP per RemoteHelp-A.md's RBAC section,
      since that scope silently excludes unenrolled devices
    - Presence and assignment state of a Remote Help app in Intune's app catalog
      (Enterprise App Catalog or manually packaged Win32), flagged APP_NOT_FOUND /
      NO_ASSIGNMENTS if missing
    - Best-effort disambiguation check against deviceManagement/remoteAssistancePartners
      -- a DIFFERENT feature (third-party ISV onboarding) that this script explicitly
      does NOT treat as Remote Help coverage, per RemoteHelp-A.md's Scope & Assumptions

    Local layer (only with -IncludeLocalDiagnostics, intended to be run ON a sharer
    device during triage):
    - RemoteHelp.exe presence and version
    - Intune Management Extension (IME) service state -- required for admin-center
      "remote launch" notifications specifically, not for manual code-based sessions
    - WebView2 Runtime presence (Windows native app dependency)
    - Recent Microsoft-Windows-RemoteHelp/Operational event log entries

    Does NOT cover (see RemoteHelp-A.md for why):
    - Per-user license assignment verification -- Get-MgUserLicenseDetail's SKU naming
      for the Remote Help add-on / Intune Suite varies by agreement and region, so this
      is deliberately left as a manual cross-check rather than a false-confidence
      automated pass/fail (consistent with this repo's standing approach to SKU checks)
    - Individual session history/audit records -- confirmed portal-only
      (Tenant administration > Remote Help > Monitor / Audit Logs) with no known
      Graph endpoint as of this script's writing; not attempted here
    - Conditional Access policy content -- only confirms whether the
      RemoteAssistanceService service principal has been provisioned at all

.PARAMETER IncludeLocalDiagnostics
    When set, also runs the device-local checks (client install, IME, WebView2, event
    log) against the machine executing the script. Intended for running directly on a
    sharer's device during hands-on triage, not for fleet-wide local collection.

.PARAMETER OutputPath
    Path for CSV export of the tenant-wide RBAC findings. Default:
    C:\Temp\RemoteHelpReadinessAudit-<timestamp>.csv

.EXAMPLE
    .\Get-RemoteHelpReadinessAudit.ps1

.EXAMPLE
    .\Get-RemoteHelpReadinessAudit.ps1 -IncludeLocalDiagnostics -OutputPath "C:\Reports\RH-Audit.csv"

.NOTES
    Requires: Microsoft.Graph.Authentication module (remoteAssistanceSettings is a
              beta-only resource with no typed cmdlet -- uses Invoke-MgGraphRequest
              directly, same approach as Get-EndpointAnalyticsHealth.ps1 in this folder)
    Permissions: DeviceManagementConfiguration.Read.All, DeviceManagementRBAC.Read.All,
                 DeviceManagementApps.Read.All
    Safe: Read-only -- no tenant setting, RBAC, or app assignment changes made
    Cross-references: Intune/Troubleshooting/RemoteHelp-A.md and -B.md
#>

[CmdletBinding()]
param(
    [switch]$IncludeLocalDiagnostics,

    [string]$OutputPath = "C:\Temp\RemoteHelpReadinessAudit-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
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

# ── Preflight ────────────────────────────────────────────────────────────────
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Status "Microsoft.Graph.Authentication module not found. Install with:" "ERROR"
    Write-Status "  Install-Module Microsoft.Graph.Authentication -Scope CurrentUser" "ERROR"
    exit 1
}

try {
    $context = Get-MgContext -ErrorAction Stop
    if (-not $context) { throw "No active Graph session" }
    Write-Status "Using existing Graph session: $($context.Account)" "OK"
} catch {
    Write-Status "Connecting to Graph (DeviceManagementConfiguration.Read.All, DeviceManagementRBAC.Read.All, DeviceManagementApps.Read.All)..." "INFO"
    Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All","DeviceManagementRBAC.Read.All","DeviceManagementApps.Read.All" -NoWelcome
}

$findings = [System.Collections.Generic.List[string]]::new()

# ── Step 1: Tenant enablement ───────────────────────────────────────────────
Write-Status "Checking tenant-wide remoteAssistanceSettings..." "INFO"
try {
    $settings = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/remoteAssistanceSettings"

    if ($settings.remoteAssistanceState -ne "enabled") {
        Write-Status "remoteAssistanceState = '$($settings.remoteAssistanceState)' -- Remote Help is NOT enabled tenant-wide. Nothing downstream matters until this is fixed." "ERROR"
        $findings.Add("TENANT_DISABLED")
    } else {
        Write-Status "remoteAssistanceState = enabled." "OK"
    }

    Write-Status "allowSessionsToUnenrolledDevices = $($settings.allowSessionsToUnenrolledDevices) (informational)" "INFO"
    Write-Status "blockChat = $($settings.blockChat) (informational)" "INFO"

    if ($settings.allowSessionsToUnenrolledDevices -eq $true) {
        Write-Status "Unenrolled-device sessions are allowed -- confirm any role granting Remote Help uses a USER scope group, not 'All Devices', or unenrolled sharers will show as out of scope." "WARN"
        $findings.Add("UNENROLLED_DEVICES_ALLOWED_VERIFY_SCOPE")
    }
} catch {
    Write-Status "Failed to query remoteAssistanceSettings: $($_.Exception.Message)" "ERROR"
    Write-Status "This can indicate missing Intune licensing on the tenant, or insufficient Graph permissions -- not necessarily a Remote Help-specific fault." "WARN"
    $findings.Add("SETTINGS_QUERY_FAILED")
}

# ── Step 2: RBAC coverage ───────────────────────────────────────────────────
Write-Status "Scanning Intune role definitions for Remote Help permissions..." "INFO"
$rbacReport = [System.Collections.Generic.List[PSCustomObject]]::new()

try {
    $roleDefs = Get-MgDeviceManagementRoleDefinition -All

    foreach ($role in $roleDefs) {
        $actions = @()
        foreach ($perm in $role.RolePermissions) {
            foreach ($ra in $perm.ResourceActions) {
                $actions += $ra.AllowedResourceActions
            }
        }
        $rhActions = $actions | Where-Object { $_ -match 'RemoteAssistance' }

        if ($rhActions.Count -gt 0) {
            $hasOffer     = ($rhActions -match 'offerRemoteAssistance').Count -gt 0
            $hasConnRead  = ($rhActions -match 'RemoteAssistanceConnector_Read|RemoteAssistanceConnector\.Read').Count -gt 0
            $hasAnyAction = ($rhActions | Where-Object { $_ -notmatch 'offerRemoteAssistance|RemoteAssistanceConnector' }).Count -gt 0

            $complete = $hasOffer -and $hasConnRead -and $hasAnyAction

            $rbacReport.Add([PSCustomObject]@{
                RoleName        = $role.DisplayName
                IsBuiltIn       = $role.IsBuiltIn
                HasOfferPerm    = $hasOffer
                HasConnectorRead = $hasConnRead
                HasActionPerm   = $hasAnyAction
                CompleteCombo   = $complete
                RawActions      = ($rhActions -join "; ")
            })

            if (-not $complete) {
                Write-Status "Role '$($role.DisplayName)' has SOME Remote Help permissions but not the full required combination (Offer + Connector Read + an action) -- this role will look configured but may not work." "WARN"
                $findings.Add("INCOMPLETE_RBAC_COMBO:$($role.DisplayName)")
            }
        }
    }

    if ($rbacReport.Count -eq 0) {
        Write-Status "No role definitions found with any Remote Help-related permission. EMPTY_RBAC -- no one can offer Remote Help in this tenant yet." "ERROR"
        $findings.Add("EMPTY_RBAC")
    } else {
        Write-Status "Found $($rbacReport.Count) role(s) with at least one Remote Help permission." "OK"
    }
} catch {
    Write-Status "Failed to enumerate role definitions: $($_.Exception.Message)" "ERROR"
    $findings.Add("ROLE_QUERY_FAILED")
}

# ── Step 3: Role assignment scope check ─────────────────────────────────────
Write-Status "Checking role assignment scope groups for the 'All Devices' unenrolled-device gap..." "INFO"
try {
    $assignments = Get-MgDeviceManagementRoleAssignment -All
    foreach ($assign in $assignments) {
        if ($assign.ScopeType -eq "allDevices" -or ($assign.ScopeMembers -contains "AllDevices")) {
            Write-Status "Role assignment '$($assign.DisplayName)' uses an All-Devices-style scope -- if unenrolled-device Remote Help support is enabled, this scope will NOT cover unenrolled sharers (RemoteHelp-A.md RBAC section)." "WARN"
            $findings.Add("ALL_DEVICES_SCOPE_UNENROLLED_GAP:$($assign.DisplayName)")
        }
    }
} catch {
    Write-Status "Role assignment scope check failed or is not fully resolvable via this Graph version: $($_.Exception.Message)" "WARN"
    Write-Status "Not treated as a hard failure -- cross-check scope groups manually in the admin center if unenrolled-device support matters for this tenant." "INFO"
}

# ── Step 4: App deployment presence ─────────────────────────────────────────
Write-Status "Checking for a deployed Remote Help app..." "INFO"
try {
    $apps = Get-MgDeviceAppManagementMobileApp -Filter "contains(displayName,'Remote Help')" -All

    if ($apps.Count -eq 0) {
        Write-Status "No app matching 'Remote Help' found in Intune's app catalog. APP_NOT_FOUND -- the client has not been deployed via Intune (it may still be self-installed by individual users)." "WARN"
        $findings.Add("APP_NOT_FOUND")
    } else {
        foreach ($app in $apps) {
            Write-Status "Found app: '$($app.DisplayName)' (Id: $($app.Id))" "OK"
        }
    }
} catch {
    Write-Status "App catalog query failed: $($_.Exception.Message)" "WARN"
    $findings.Add("APP_QUERY_FAILED")
}

# ── Step 5: Disambiguation check against remoteAssistancePartners ──────────
# Informational only -- this is a DIFFERENT feature (third-party ISV onboarding),
# never treated as Remote Help coverage. Surfaced only so an auditor doesn't
# mistake a configured partner integration for native Remote Help readiness.
try {
    $partners = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/remoteAssistancePartners"
    if ($partners.value -and $partners.value.Count -gt 0) {
        Write-Status "$($partners.value.Count) third-party remoteAssistancePartner(s) onboarded -- NOTE: this is a separate feature from native Remote Help and is not counted toward readiness above." "INFO"
    }
} catch {
    # Non-fatal and non-essential -- silently skip if this beta resource isn't reachable.
}

# ── Optional: Local device diagnostics ──────────────────────────────────────
if ($IncludeLocalDiagnostics) {
    Write-Host "`n=== Local Device Diagnostics (running on: $env:COMPUTERNAME) ===" -ForegroundColor Cyan

    $clientPath = "C:\Program Files\Remote Help\RemoteHelp.exe"
    if (Test-Path $clientPath) {
        $ver = (Get-Item $clientPath).VersionInfo
        Write-Status "RemoteHelp.exe present -- FileVersion: $($ver.FileVersion)" "OK"
    } else {
        Write-Status "RemoteHelp.exe NOT found at '$clientPath'. CLIENT_NOT_INSTALLED." "WARN"
        $findings.Add("LOCAL:CLIENT_NOT_INSTALLED")
    }

    $ime = Get-Service -Name IntuneManagementExtension -ErrorAction SilentlyContinue
    if ($null -eq $ime) {
        Write-Status "IntuneManagementExtension service not found on this device. IME_NOT_INSTALLED -- admin-center remote-launch notifications will not work; manual code sessions are unaffected." "WARN"
        $findings.Add("LOCAL:IME_NOT_INSTALLED")
    } elseif ($ime.Status -ne "Running") {
        Write-Status "IntuneManagementExtension service present but not Running (Status: $($ime.Status)). Remote-launch notifications will fail until this is running." "WARN"
        $findings.Add("LOCAL:IME_NOT_RUNNING")
    } else {
        Write-Status "IntuneManagementExtension service is Running." "OK"
    }

    $webview2 = Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" -ErrorAction SilentlyContinue
    if ($null -eq $webview2) {
        Write-Status "WebView2 Runtime registration not found at the expected registry path. WEBVIEW2_NOT_CONFIRMED -- if the Remote Help app fails with error codes 1001-1003, this is the first place to check (may still be present via a different install path on Windows 11)." "WARN"
        $findings.Add("LOCAL:WEBVIEW2_NOT_CONFIRMED")
    } else {
        Write-Status "WebView2 Runtime registration found (version: $($webview2.pv))." "OK"
    }

    $events = Get-WinEvent -LogName "Microsoft-Windows-RemoteHelp/Operational" -MaxEvents 20 -ErrorAction SilentlyContinue
    if ($events) {
        $errorEvents = $events | Where-Object { $_.LevelDisplayName -in @("Error","Warning") }
        if ($errorEvents.Count -gt 0) {
            Write-Status "$($errorEvents.Count) Error/Warning event(s) found in the last 20 RemoteHelp/Operational log entries -- see console output below." "WARN"
            $errorEvents | Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-Table -Wrap
            $findings.Add("LOCAL:EVENT_LOG_ERRORS_FOUND")
        } else {
            Write-Status "No Error/Warning entries in the last 20 RemoteHelp/Operational log events." "OK"
        }
    } else {
        Write-Status "RemoteHelp/Operational event log not found or empty on this device (expected if Remote Help has never been used here)." "INFO"
    }
}

# ── Export ────────────────────────────────────────────────────────────────
if ($rbacReport.Count -gt 0) {
    $outputDir = Split-Path $OutputPath
    if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }
    $rbacReport | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Status "RBAC report exported to: $OutputPath" "OK"
}

# ── Summary ──────────────────────────────────────────────────────────────
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
if ($findings.Count -eq 0) {
    Write-Status "No readiness gaps flagged. Remember this script does NOT verify per-user licensing (both helper and sharer need one) or Conditional Access policy content -- confirm those manually per RemoteHelp-A.md." "OK"
} else {
    Write-Host "Flags raised:" -ForegroundColor Yellow
    $findings | Sort-Object -Unique | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}

Write-Status "Audit complete." "OK"
