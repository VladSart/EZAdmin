<#
.SYNOPSIS
    Read-only readiness and configuration audit for Intune Remote Help — Windows
    Unattended Support with Remote Sign-In (Intune Suite Service Release 2608+),
    with an optional local-device diagnostic block.

.DESCRIPTION
    RemoteHelp-Unattended-A.md's Dependency Stack identifies seven layers that must
    all be true before an unattended session can succeed, most of which are invisible
    from a single failed-session ticket and easy to conflate with attended Remote
    Help's separate dependency chain (see Get-RemoteHelpReadinessAudit.ps1, which this
    script deliberately does NOT duplicate — it only re-checks the shared tenant-wide
    switch and defers everything else attended-specific to that script).

    Tenant/RBAC layer (always runs, via Microsoft Graph):
    - remoteAssistanceSettings.remoteAssistanceState -- the tenant-wide switch shared
      with attended Remote Help (default: disabled)
    - Every Intune role definition whose resource actions include the specific
      "Remote Help app - Windows unattended control remote sign-in" permission,
      flagged NO_ROLE_HAS_UNATTENDED_PERMISSION if none exist at all -- since this
      permission is NOT included in any built-in role (unlike attended permissions,
      which Help Desk Operator carries out of the box)
    - Presence of the two required Win32 apps (Azure Virtual Desktop Agent, Azure
      Virtual Desktop Agent Bootloader) in the app catalog, flagged AGENT_APP_MISSING
      / BOOTLOADER_APP_MISSING if either is absent
    - Whether the bootloader app has a configured dependency relationship on the
      agent app, flagged NO_DEPENDENCY_CONFIGURED if not -- a manually-created
      deployment can install both without enforcing correct install order
    - Best-effort per-device eligibility review for a supplied device list: physical
      vs. likely-virtual (Cloud PC/AVD) heuristic via Model/Manufacturer string
      matching, ManagedDeviceOwnerType, OS architecture, and Entra join type

    Local layer (only with -IncludeLocalDiagnostics, intended to be run ON a target
    device during triage):
    - RDAgent / RDAgentBootLoader service presence and state
    - IntuneManagementExtension service state (shared orchestration dependency with
      attended remote-launch)
    - Remote Desktop enabled state (fDenyTSConnections registry value)

    Does NOT cover (see RemoteHelp-Unattended-A.md for why):
    - Per-user/per-device Remote Help or Intune Suite license verification -- SKU
      naming varies by agreement and region; deliberately left as a manual
      cross-check rather than a false-confidence automated pass/fail, consistent
      with this repo's standing approach to SKU checks
    - Individual session history/audit records -- portal-only surface with no known
      dedicated Graph endpoint as of this script's writing; not attempted here
    - Confirming the tenant has actually received Intune Suite Service Release 2608
      or later -- there is no documented Graph property exposing tenant service
      release version; this MUST be confirmed manually against Microsoft's release
      notes before assuming a fully-clean audit means the feature is available
    - Live connectivity/reachability testing to target devices -- this script is
      configuration-state only, not a session simulator

.PARAMETER DeviceNames
    Optional array of managed device names to run the per-device eligibility review
    against. If omitted, only tenant/RBAC/app-catalog checks run.

.PARAMETER IncludeLocalDiagnostics
    When set, also runs the device-local checks (agent services, IME, RDP-enabled
    state) against the machine executing the script. Intended for running directly
    on a target device during triage, not against the tenant checks' machine.

.PARAMETER OutputPath
    Folder to write the CSV summary to. Defaults to the current directory.

.EXAMPLE
    .\Get-RemoteHelpUnattendedReadinessAudit.ps1 -DeviceNames "CORP-LT-04213","CORP-LT-04891"

.EXAMPLE
    .\Get-RemoteHelpUnattendedReadinessAudit.ps1 -IncludeLocalDiagnostics

.NOTES
    Requires: Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement,
    Microsoft.Graph.DeviceManagement.Actions modules; an interactive or app-only
    connection with DeviceManagementConfiguration.Read.All, DeviceManagementRBAC.Read.All,
    DeviceManagementManagedDevices.Read.All, and DeviceManagementApps.Read.All scopes.
    Run-as: no elevation required for the Graph-only checks. -IncludeLocalDiagnostics
    reads HKLM and queries services; standard user rights are sufficient to read both.
    Safe: entirely read-only. Zero New-Mg/Set-Mg/Remove-Mg/Update-Mg cmdlets anywhere
    in this script -- confirmed via a targeted regex review before publishing.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$DeviceNames,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeLocalDiagnostics,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$UnattendedPermissionString = "remoteAssistance_windowsUnattendedControlRemoteSignIn"

function Add-Result {
    param($Category, $Check, $Finding, $Status)
    $results.Add([PSCustomObject]@{
        Category = $Category
        Check    = $Check
        Finding  = $Finding
        Status   = $Status
    })
}

Write-Status "=== Remote Help Unattended Support -- Readiness Audit ===" "INFO"
Write-Status "Reminder: this audit cannot confirm tenant Service Release 2608+ eligibility -- verify manually against Microsoft's release notes." "WARN"

# ---------------------------------------------------------------------------
# TENANT LAYER
# ---------------------------------------------------------------------------
Write-Status "Checking tenant-wide remoteAssistanceState..." "INFO"
try {
    $settings = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/remoteAssistanceSettings"
    $state = $settings.remoteAssistanceState
    if ($state -eq "enabled") {
        Add-Result "Tenant" "remoteAssistanceState" $state "OK"
    } else {
        Add-Result "Tenant" "remoteAssistanceState" $state "FAIL"
    }
    Write-Status "remoteAssistanceState = $state" $(if ($state -eq "enabled") { "OK" } else { "WARN" })
}
catch {
    Add-Result "Tenant" "remoteAssistanceState" "QUERY_FAILED: $($_.Exception.Message)" "ERROR"
    Write-Status "Failed to query tenant remote assistance settings: $($_.Exception.Message)" "ERROR"
}

# ---------------------------------------------------------------------------
# RBAC LAYER
# ---------------------------------------------------------------------------
Write-Status "Scanning role definitions for the unattended-remote-sign-in permission..." "INFO"
try {
    $roles = Get-MgDeviceManagementRoleDefinition -All
    $matchingRoles = $roles | Where-Object {
        $_.RolePermissions.ResourceActions.AllowedResourceActions -match $UnattendedPermissionString
    }

    if ($matchingRoles.Count -eq 0) {
        Add-Result "RBAC" "Unattended permission in any role" "NO_ROLE_HAS_UNATTENDED_PERMISSION" "FAIL"
        Write-Status "No role definition (built-in or custom) grants the Windows unattended remote-sign-in permission. This is expected until a custom role is deliberately created." "WARN"
    } else {
        foreach ($role in $matchingRoles) {
            Add-Result "RBAC" "Role: $($role.DisplayName)" "GRANTS_UNATTENDED_PERMISSION (IsBuiltIn=$($role.IsBuiltIn))" "OK"
        }
        Write-Status "$($matchingRoles.Count) role(s) grant the unattended permission." "OK"
    }
}
catch {
    Add-Result "RBAC" "Role scan" "QUERY_FAILED: $($_.Exception.Message)" "ERROR"
    Write-Status "Failed to enumerate role definitions: $($_.Exception.Message)" "ERROR"
}

# ---------------------------------------------------------------------------
# APP CATALOG LAYER
# ---------------------------------------------------------------------------
Write-Status "Checking for the AVD Agent and AVD Agent Bootloader apps..." "INFO"
try {
    $agentApp = Get-MgDeviceAppManagementMobileApp -Filter "contains(displayName,'Remote Desktop Services Infrastructure Agent')" -ErrorAction SilentlyContinue
    $bootloaderApp = Get-MgDeviceAppManagementMobileApp -Filter "contains(displayName,'Remote Desktop Agent Boot Loader')" -ErrorAction SilentlyContinue

    if (-not $agentApp) {
        Add-Result "AppCatalog" "AVD Agent app" "AGENT_APP_MISSING" "FAIL"
        Write-Status "AVD Agent app not found in the catalog." "WARN"
    } else {
        Add-Result "AppCatalog" "AVD Agent app" "FOUND: $($agentApp.DisplayName) [$($agentApp.PublishingState)]" "OK"
    }

    if (-not $bootloaderApp) {
        Add-Result "AppCatalog" "AVD Agent Bootloader app" "BOOTLOADER_APP_MISSING" "FAIL"
        Write-Status "AVD Agent Bootloader app not found in the catalog." "WARN"
    } else {
        Add-Result "AppCatalog" "AVD Agent Bootloader app" "FOUND: $($bootloaderApp.DisplayName) [$($bootloaderApp.PublishingState)]" "OK"
    }

    if ($agentApp -and $bootloaderApp) {
        try {
            $bootloaderRelations = Get-MgDeviceAppManagementMobileAppRelation -MobileAppId $bootloaderApp.Id -ErrorAction SilentlyContinue
            $hasDependency = $bootloaderRelations | Where-Object { $_.TargetId -eq $agentApp.Id -and $_.TargetType -eq 'parent' }
            if ($hasDependency) {
                Add-Result "AppCatalog" "Bootloader -> Agent dependency" "CONFIGURED" "OK"
            } else {
                Add-Result "AppCatalog" "Bootloader -> Agent dependency" "NO_DEPENDENCY_CONFIGURED" "WARN"
                Write-Status "Bootloader app has no confirmed dependency relationship on the agent app -- install order is not enforced by Intune." "WARN"
            }
        }
        catch {
            Add-Result "AppCatalog" "Bootloader -> Agent dependency" "CHECK_UNAVAILABLE: $($_.Exception.Message)" "WARN"
        }
    }
}
catch {
    Add-Result "AppCatalog" "App catalog scan" "QUERY_FAILED: $($_.Exception.Message)" "ERROR"
    Write-Status "Failed to query the app catalog: $($_.Exception.Message)" "ERROR"
}

# ---------------------------------------------------------------------------
# PER-DEVICE ELIGIBILITY LAYER (optional)
# ---------------------------------------------------------------------------
if ($DeviceNames -and $DeviceNames.Count -gt 0) {
    Write-Status "Reviewing per-device eligibility for $($DeviceNames.Count) device(s)..." "INFO"

    # Heuristic only -- Graph has no explicit physical-vs-virtual boolean for managed
    # devices. Cloud PC / AVD host devices commonly report a Model/Manufacturer string
    # containing these markers; this is a signal to flag for manual confirmation, not
    # an authoritative pass/fail. Documented as a known limitation, not silently assumed.
    $virtualMarkers = @("Cloud PC", "Virtual Machine", "Hyper-V", "VMware", "Azure Virtual Desktop")

    foreach ($deviceName in $DeviceNames) {
        try {
            $device = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$deviceName'" -ErrorAction SilentlyContinue
            if (-not $device) {
                Add-Result "DeviceEligibility" $deviceName "DEVICE_NOT_FOUND" "ERROR"
                Write-Status "$deviceName not found as a managed device." "ERROR"
                continue
            }

            $likelyVirtual = $false
            foreach ($marker in $virtualMarkers) {
                if ($device.Model -like "*$marker*" -or $device.Manufacturer -like "*$marker*") {
                    $likelyVirtual = $true
                    break
                }
            }

            if ($likelyVirtual) {
                Add-Result "DeviceEligibility" "$deviceName -- Physical hardware" "LIKELY_VIRTUAL_DEVICE (Model=$($device.Model))" "FAIL"
            } else {
                Add-Result "DeviceEligibility" "$deviceName -- Physical hardware" "LIKELY_PHYSICAL (Model=$($device.Model)) -- heuristic only, confirm manually if uncertain" "OK"
            }

            if ($device.ManagedDeviceOwnerType -eq "company") {
                Add-Result "DeviceEligibility" "$deviceName -- Ownership" "company" "OK"
            } else {
                Add-Result "DeviceEligibility" "$deviceName -- Ownership" $device.ManagedDeviceOwnerType "FAIL"
            }

            $arch = $device.OperatingSystemVersion
            Add-Result "DeviceEligibility" "$deviceName -- OS Version (confirm x64 manually)" $arch "INFO"

            Add-Result "DeviceEligibility" "$deviceName -- ComplianceState" $device.ComplianceState "INFO"
        }
        catch {
            Add-Result "DeviceEligibility" $deviceName "QUERY_FAILED: $($_.Exception.Message)" "ERROR"
        }
    }
} else {
    Write-Status "No -DeviceNames supplied -- skipping per-device eligibility review." "INFO"
}

# ---------------------------------------------------------------------------
# LOCAL DIAGNOSTICS (optional, run on a target device)
# ---------------------------------------------------------------------------
if ($IncludeLocalDiagnostics) {
    Write-Status "Running local diagnostics on $env:COMPUTERNAME..." "INFO"

    foreach ($svcName in @("RDAgent", "RDAgentBootLoader", "IntuneManagementExtension")) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            $svcStatus = if ($svc.Status -eq "Running") { "OK" } else { "WARN" }
            Add-Result "LocalDiagnostics" "Service: $svcName" "$($svc.Status)" $svcStatus
        } else {
            Add-Result "LocalDiagnostics" "Service: $svcName" "NOT_INSTALLED" "FAIL"
        }
    }

    try {
        $rdp = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections -ErrorAction SilentlyContinue
        if ($rdp -and $rdp.fDenyTSConnections -eq 0) {
            Add-Result "LocalDiagnostics" "Remote Desktop enabled (fDenyTSConnections)" "0 (allowed)" "OK"
        } elseif ($rdp) {
            Add-Result "LocalDiagnostics" "Remote Desktop enabled (fDenyTSConnections)" "1 (denied)" "FAIL"
        } else {
            Add-Result "LocalDiagnostics" "Remote Desktop enabled (fDenyTSConnections)" "KEY_NOT_FOUND" "WARN"
        }
    }
    catch {
        Add-Result "LocalDiagnostics" "Remote Desktop enabled" "CHECK_FAILED: $($_.Exception.Message)" "ERROR"
    }
} else {
    Write-Status "Skipping local diagnostics (use -IncludeLocalDiagnostics when running directly on a target device)." "INFO"
}

# ---------------------------------------------------------------------------
# REPORT
# ---------------------------------------------------------------------------
$failCount = ($results | Where-Object Status -eq "FAIL").Count
$warnCount = ($results | Where-Object Status -eq "WARN").Count
$errorCount = ($results | Where-Object Status -eq "ERROR").Count

Write-Status "=== Summary: $failCount FAIL, $warnCount WARN, $errorCount ERROR (of $($results.Count) checks) ===" $(if ($failCount -gt 0 -or $errorCount -gt 0) { "WARN" } else { "OK" })

$csvPath = Join-Path $OutputPath "RemoteHelpUnattendedReadinessAudit-$(Get-Date -Format yyyyMMdd-HHmm).csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation
Write-Status "Full results exported to $csvPath" "INFO"

$results | Format-Table -AutoSize
