<#
.SYNOPSIS
    Audits Windows 365 Link hardware devices across the tenant — enrollment/compliance state,
    SSO readiness of provisioning policies they connect to, and misapplied-policy risk.

.DESCRIPTION
    Companion to Link-A.md and Link-B.md. Windows 365 Link is a physical thin-client hardware
    device (Windows CPC OS) with a deliberately narrow Intune management surface — this script
    focuses on the checks that are unique to that narrow surface rather than duplicating the
    general Cloud PC fleet reporting already covered by Get-CloudPcFleetStatus.ps1.

    Reports:
    - Inventory of every device with Model 'Windows 365 Link': compliance/management state,
      enrollment date, last sync (used to flag likely disconnected-standby vs. genuinely stale)
    - NONCOMPLIANT_LINK_DEVICE — flags any Link device not showing ComplianceState 'compliant'.
      Since Device health (BitLocker/Secure Boot/Code Integrity) is the *only* applicable
      compliance setting for Link, a noncompliant result here is a meaningful signal, not noise
      (Link-A.md How It Works).
    - SSO_DISABLED_POLICY — flags every Windows 365 provisioning policy that does NOT have
      Microsoft Entra ID single sign-on enabled. Any Link device connecting to a Cloud PC under
      one of these policies will hit a hard, on-device connection failure (Link-B.md Fix 3) —
      this is reported regardless of whether a Link device is currently assigned, since it is a
      correctness check for a future/planned Link rollout as much as an active-incident check.
    - STALE_CHECKIN — flags Link devices whose LastSyncDateTime exceeds the supplied threshold.
      Explicitly reported as a possible-disconnected-standby signal rather than a confirmed
      fault, since Link devices legitimately stop checking in while asleep (Link-B.md Fix 7) —
      this script cannot distinguish "asleep" from "actually offline" and says so in the finding.
    - APP_POLICY_TARGETS_LINK — cross-references Win32/store app assignments against a supplied
      list of Entra ID group IDs known to back Link devices (see -LinkDeviceGroupId) and flags
      any app assignment scoped to one of those groups, since app management does not apply to
      Link at all and will report a perpetual "Pending install" (Link-B.md Fix 5). This check is
      skipped entirely if -LinkDeviceGroupId isn't supplied, since there's no reliable way to
      derive "which Entra ID groups contain Link devices" from Graph device objects alone.

    Does NOT check: Entra ID Device Settings ("Users may join devices") or MDM user scope —
    both are tenant-wide toggles with no dedicated Graph read endpoint used in this script and
    remain portal-only checks per Link-A.md's Validation Steps. Does NOT check SSO consent
    suppression / service-principal RDP authentication configuration, Autopilot profile
    assignment (no reliable device-type cross-reference via Graph), disk space usage, or
    firmware/build version against the 26100.7462 WAM-interactive threshold — all explicitly
    out of scope and called out in the summary output.

    Does NOT perform any remediation, wipe, or reset action — read-only audit only.

.PARAMETER StaleCheckinHours
    Hours since LastSyncDateTime after which a Link device is flagged STALE_CHECKIN.
    Default: 72 (3 days) — chosen to comfortably exceed a normal sleep/weekend gap while still
    surfacing devices worth a manual look.

.PARAMETER LinkDeviceGroupId
    Optional. One or more Entra ID group Object IDs known to back Link-device app/policy
    assignments. When supplied, enables the APP_POLICY_TARGETS_LINK check.

.PARAMETER ExportPath
    Directory to write CSV reports to. Default: current directory.

.EXAMPLE
    .\Get-Windows365LinkAudit.ps1
    Runs the core Link device/compliance/SSO-readiness audit and exports CSVs to the current directory.

.EXAMPLE
    .\Get-Windows365LinkAudit.ps1 -StaleCheckinHours 48 -LinkDeviceGroupId "11111111-1111-1111-1111-111111111111" -ExportPath "C:\Reports"
    Runs the full audit including the app-policy-misassignment check against a known Link device group.

.NOTES
    Requires: Microsoft.Graph.Beta module (for provisioning policy cmdlets), Microsoft.Graph.DeviceManagement.
    Requires scopes: DeviceManagementManagedDevices.Read.All, DeviceManagementConfiguration.Read.All,
    DeviceManagementApps.Read.All (only needed if -LinkDeviceGroupId is supplied).
    Run as: Any account/service principal holding the scopes above — no elevated local rights
    needed, this is a Graph-only read operation.
    Safe: Yes — entirely read-only, makes no configuration, compliance, or device changes.
    Written for Windows PowerShell 5.1 compatibility (no PS7-only syntax used).
#>

#requires -Modules Microsoft.Graph.Beta

[CmdletBinding()]
param(
    [int]$StaleCheckinHours = 72,
    [string[]]$LinkDeviceGroupId,
    [string]$ExportPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Verifying Graph connection and scopes..."
$context = Get-MgContext
if (-not $context) {
    Write-Status "Not connected to Microsoft Graph. Run Connect-MgGraph first with scopes: DeviceManagementManagedDevices.Read.All, DeviceManagementConfiguration.Read.All" "ERROR"
    throw "Not connected to Microsoft Graph."
}

$requiredScopes = @("DeviceManagementManagedDevices.Read.All", "DeviceManagementConfiguration.Read.All")
if ($LinkDeviceGroupId) { $requiredScopes += "DeviceManagementApps.Read.All" }
$missingScopes = $requiredScopes | Where-Object { $_ -notin $context.Scopes -and "$_".Replace('.Read.','.ReadWrite.') -notin $context.Scopes }
if ($missingScopes) {
    Write-Status "Missing recommended scopes: $($missingScopes -join ', '). Some checks may fail or return partial data." "WARN"
}

if (-not (Test-Path $ExportPath)) {
    New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null
}
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$findings = [System.Collections.Generic.List[object]]::new()

# ---------------------------------------------------------------------------
# Detect: Windows 365 Link device inventory
# ---------------------------------------------------------------------------
Write-Status "Enumerating Windows 365 Link devices (Model eq 'Windows 365 Link')..."
$linkDevices = Get-MgDeviceManagementManagedDevice -Filter "model eq 'Windows 365 Link'" -All

if (-not $linkDevices -or $linkDevices.Count -eq 0) {
    Write-Status "No Windows 365 Link devices found in this tenant. Nothing further to audit." "WARN"
    return
}
Write-Status "Found $($linkDevices.Count) Windows 365 Link device(s)." "OK"

# ---------------------------------------------------------------------------
# Execute: compliance and stale-checkin checks
# ---------------------------------------------------------------------------
$deviceReport = [System.Collections.Generic.List[object]]::new()
$staleThreshold = (Get-Date).AddHours(-$StaleCheckinHours)

foreach ($device in $linkDevices) {

    $isNonCompliant = $device.ComplianceState -ne "compliant"
    $isStale = $null -ne $device.LastSyncDateTime -and $device.LastSyncDateTime -lt $staleThreshold

    if ($isNonCompliant) {
        $findings.Add([PSCustomObject]@{
            Finding    = "NONCOMPLIANT_LINK_DEVICE"
            DeviceName = $device.DeviceName
            SerialNumber = $device.SerialNumber
            DeviceId   = $device.Id
            Detail     = "ComplianceState is '$($device.ComplianceState)'. Device health (BitLocker/Secure Boot/Code Integrity) is the ONLY compliance setting evaluated for Link — this is a meaningful finding, not policy noise (Link-A.md)."
        })
    }

    if ($isStale) {
        $findings.Add([PSCustomObject]@{
            Finding    = "STALE_CHECKIN"
            DeviceName = $device.DeviceName
            SerialNumber = $device.SerialNumber
            DeviceId   = $device.Id
            Detail     = "LastSyncDateTime ($($device.LastSyncDateTime)) exceeds the $StaleCheckinHours-hour threshold. Could be disconnected standby (normal) or a genuinely offline/broken device — this script cannot distinguish the two. Do not treat as a confirmed fault without a follow-up wake attempt (Link-B.md Fix 7)."
        })
    }

    $deviceReport.Add([PSCustomObject]@{
        DeviceName       = $device.DeviceName
        SerialNumber     = $device.SerialNumber
        DeviceId         = $device.Id
        ComplianceState  = $device.ComplianceState
        ManagementState  = $device.ManagementState
        EnrolledDateTime = $device.EnrolledDateTime
        LastSyncDateTime = $device.LastSyncDateTime
        NonCompliant     = $isNonCompliant
        LikelyStale      = $isStale
    })
}

# ---------------------------------------------------------------------------
# Execute: SSO readiness of provisioning policies (tenant-wide correctness check)
# ---------------------------------------------------------------------------
Write-Status "Enumerating provisioning policies and checking Entra ID SSO status..."
try {
    $policies = Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -All -ErrorAction Stop
} catch {
    Write-Status "Could not enumerate provisioning policies (Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy failed) — confirm Microsoft.Graph.Beta module and CloudPC/DeviceManagementConfiguration scopes." "WARN"
    $policies = @()
}

$policyReport = [System.Collections.Generic.List[object]]::new()
foreach ($policy in $policies) {
    $ssoStatus = $policy.MicrosoftEntraSingleSignOnStatus
    $ssoDisabled = $ssoStatus -ne "enabled"

    if ($ssoDisabled) {
        $findings.Add([PSCustomObject]@{
            Finding    = "SSO_DISABLED_POLICY"
            DeviceName = $null
            SerialNumber = $null
            DeviceId   = $policy.Id
            Detail     = "Provisioning policy '$($policy.DisplayName)' has MicrosoftEntraSingleSignOnStatus = '$ssoStatus'. Any Windows 365 Link device connecting to a Cloud PC provisioned under this policy will receive a hard, on-device 'doesn't support Entra ID single sign-on' error with no fallback (Link-B.md Fix 3). Verify this is intentional (policy not used for Link-connected users) before dismissing."
        })
    }

    $policyReport.Add([PSCustomObject]@{
        PolicyName = $policy.DisplayName
        PolicyId   = $policy.Id
        SsoStatus  = $ssoStatus
        SsoDisabled = $ssoDisabled
    })
}

# ---------------------------------------------------------------------------
# Execute (optional): app policy misassignment against known Link device groups
# ---------------------------------------------------------------------------
$appFindingsCount = 0
if ($LinkDeviceGroupId) {
    Write-Status "Cross-referencing app assignments against supplied Link device group(s)..."
    try {
        $mobileApps = Get-MgDeviceAppManagementMobileApp -All -ErrorAction Stop
        foreach ($app in $mobileApps) {
            try {
                $assignments = Get-MgDeviceAppManagementMobileAppAssignment -MobileAppId $app.Id -ErrorAction Stop
            } catch {
                continue
            }
            foreach ($assignment in $assignments) {
                $targetGroupId = $assignment.Target.AdditionalProperties["groupId"]
                if ($targetGroupId -and $targetGroupId -in $LinkDeviceGroupId) {
                    $appFindingsCount++
                    $findings.Add([PSCustomObject]@{
                        Finding    = "APP_POLICY_TARGETS_LINK"
                        DeviceName = $null
                        SerialNumber = $null
                        DeviceId   = $app.Id
                        Detail     = "App '$($app.DisplayName)' is assigned to group '$targetGroupId', which was supplied as a known Link-device group. App management does not apply to Windows 365 Link — this assignment will report perpetual 'Pending install' and should be excluded via an Intune device filter (Model eq 'Windows 365 Link') instead (Link-B.md Fix 5)."
                    })
                }
            }
        }
    } catch {
        Write-Status "Could not enumerate mobile app assignments (DeviceManagementApps.Read.All may be missing). Skipping APP_POLICY_TARGETS_LINK check." "WARN"
    }
} else {
    Write-Status "No -LinkDeviceGroupId supplied — skipping APP_POLICY_TARGETS_LINK check (cannot reliably derive Link-backing groups from device objects alone)." "WARN"
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Status "`n=== SUMMARY ===" "OK"
Write-Status "Windows 365 Link devices: $($linkDevices.Count)"
Write-Status "Noncompliant Link devices: $(($deviceReport | Where-Object NonCompliant).Count)"
Write-Status "Devices with stale check-in (>$StaleCheckinHours h): $(($deviceReport | Where-Object LikelyStale).Count)"
Write-Status "Provisioning policies checked: $($policyReport.Count)"
Write-Status "Policies with SSO disabled: $(($policyReport | Where-Object SsoDisabled).Count)"
if ($LinkDeviceGroupId) { Write-Status "App assignments flagged against known Link groups: $appFindingsCount" }
Write-Status "Total findings: $($findings.Count)" $(if ($findings.Count -gt 0) { "WARN" } else { "OK" })

if ($findings.Count -gt 0) {
    Write-Status "`n=== FINDINGS ===" "WARN"
    $findings | Format-Table -AutoSize -Wrap
}

Write-Status "`nNOTE: Entra ID Device Settings ('Users may join devices'), MDM user scope, SSO consent" "WARN"
Write-Status "suppression (service-principal RDP auth configuration), Autopilot profile assignment," "WARN"
Write-Status "disk space usage, and firmware/build version are NOT checked by this script — all" "WARN"
Write-Status "remain portal-only or unreliable-to-cross-reference surfaces as of this writing. Verify" "WARN"
Write-Status "manually per Link-A.md's Validation Steps before treating this audit as complete." "WARN"

$deviceReportPath = Join-Path $ExportPath "Windows365Link_DeviceReport_$timestamp.csv"
$policyReportPath = Join-Path $ExportPath "Windows365Link_PolicySsoReport_$timestamp.csv"
$findingsPath = Join-Path $ExportPath "Windows365Link_Findings_$timestamp.csv"

$deviceReport | Export-Csv -Path $deviceReportPath -NoTypeInformation
$policyReport | Export-Csv -Path $policyReportPath -NoTypeInformation
$findings | Export-Csv -Path $findingsPath -NoTypeInformation

Write-Status "`nReports written to:" "OK"
Write-Status "  $deviceReportPath"
Write-Status "  $policyReportPath"
Write-Status "  $findingsPath"
