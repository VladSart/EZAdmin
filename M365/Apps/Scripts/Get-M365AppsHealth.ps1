<#
.SYNOPSIS
    Local, device-scoped health check for the Microsoft 365 Apps Click-to-Run install —
    update channel authority, servicing task state, CDN reachability, and activation status.

.DESCRIPTION
    Read-only diagnostic run on a single device (not fleet-wide via Graph — update channel
    and activation state are inherently device/session-local, matching the pattern of other
    device-local diagnostics in this repo such as Get-OutlookClientHealth.ps1).

    Checks, in order:
      1. Whether this is actually a Click-to-Run install (vs. MSI/LTSC/New Outlook) — flags
         NOT_CLICK_TO_RUN and stops most further checks if so, since none of them apply.
      2. Current update channel (GUID resolved to friendly name where recognized).
      3. Which mechanism is authoritative for the channel (GPO > ODT-set value > default) —
         flags GPO_OVERRIDE_ACTIVE when a GPO channel policy is present, since this is the
         single most common "channel change didn't take" root cause per Deployment-UpdateChannels-A.md.
      4. "Office Automatic Updates 2.0" scheduled task presence/state — flags
         UPDATE_TASK_MISSING or UPDATE_TASK_DISABLED.
      5. Office CDN reachability (officecdn.microsoft.com:443) — flags CDN_UNREACHABLE.
      6. Activation status via OSPP.VBS — flags NOT_LICENSED, GRACE_PERIOD, or LICENSED.
      7. Semi-Annual Enterprise Channel detection — flags SAC_CHANNEL_POST_UNIFICATION as an
         informational note given the July 2026 SAC/MEC cadence unification, so an engineer
         doesn't mistake the new monthly cadence for a misconfiguration.

    Does NOT touch Entra ID license assignment (that's a tenant-wide Graph check, see
    M365/Licensing/Scripts/Get-LicenseReport.ps1) and does NOT attempt any repair action —
    this is diagnostics only.

.PARAMETER SkipActivationCheck
    Skip the OSPP.VBS activation check (useful if running as a non-interactive/SYSTEM context
    where activation state isn't meaningful for the current session).

.EXAMPLE
    .\Get-M365AppsHealth.ps1
    Runs the full local health check as the current interactive user.

.EXAMPLE
    .\Get-M365AppsHealth.ps1 -SkipActivationCheck
    Runs channel/update/CDN checks only, skipping the user-context activation check.

.NOTES
    Run-as: standard user is sufficient for all checks except reading HKLM policy keys,
    which are readable by any authenticated user by design (GPO registry values aren't ACL'd
    to admins-only).
    Read-only — makes no configuration changes, no repairs, no channel changes.
#>

[CmdletBinding()]
param(
    [switch]$SkipActivationCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$findings = [System.Collections.Generic.List[pscustomobject]]::new()

# Known UpdateChannel GUID -> friendly name map (Microsoft-published channel URLs)
$channelMap = @{
    "492350f6-3a01-4f97-b9c0-c7c6ddf67d60" = "Current Channel"
    "64256afe-f5d9-4f86-8936-8840a6a4f5be" = "Current Channel (Preview)"
    "7ffbc6bf-bc32-4f92-8982-f9dd17fd3114" = "Semi-Annual Enterprise Channel (Preview)"
    "b8f9b850-328d-4355-9145-c59439a0c4cf" = "Semi-Annual Enterprise Channel"
    "5440fd1f-7ecb-4221-8110-145efaa6372f" = "Beta Channel (Insider)"
    "55336b82-a18d-4dd6-b5f6-9e5095c314a6" = "Monthly Enterprise Channel"
}

# ---------------------------------------------------------------------------
# 1. Confirm Click-to-Run install
# ---------------------------------------------------------------------------
Write-Status "Checking installation type..." "INFO"
$c2rKeyPath = "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration"
$isClickToRun = Test-Path $c2rKeyPath

if (-not $isClickToRun) {
    $findings.Add([pscustomobject]@{
        Check = "InstallationType"; Flag = "NOT_CLICK_TO_RUN"
        Detail = "No ClickToRun\Configuration registry key found. This device is either running MSI/volume-licensed Office (LTSC/2019/2021), New Outlook (WebView2, separate architecture entirely), or Office isn't installed. Most checks in this script don't apply — see Outlook-Client-A.md for New Outlook, or the volume-licensing update model for MSI installs."
    })
    Write-Status "Not a Click-to-Run install — most subsequent checks are not applicable." "WARN"
}
else {
    $c2rConfig = Get-ItemProperty -Path $c2rKeyPath -ErrorAction SilentlyContinue
    $channelGuid = $c2rConfig.UpdateChannel -replace ".*/", ""  # UpdateChannel value is often a full URL; extract trailing GUID
    $channelName = if ($channelMap.ContainsKey($channelGuid)) { $channelMap[$channelGuid] } else { "Unknown/unmapped ($channelGuid)" }

    Write-Status "Click-to-Run confirmed. Version: $($c2rConfig.VersionToReport) | Channel: $channelName" "OK"

    $findings.Add([pscustomobject]@{
        Check = "UpdateChannel"; Flag = "INFO"
        Detail = "Version=$($c2rConfig.VersionToReport); Channel=$channelName; Platform=$($c2rConfig.Platform)"
    })

    if ($channelName -match "Semi-Annual Enterprise Channel$") {
        $findings.Add([pscustomobject]@{
            Check = "UpdateChannel"; Flag = "SAC_CHANNEL_POST_UNIFICATION"
            Detail = "Device is on Semi-Annual Enterprise Channel. As of the July 2026 SAC/MEC cadence unification, this channel now receives monthly feature+security updates (not twice-yearly) with an effective ~3-month support window. Behavior changes seen after this point are expected platform changes, not misconfigurations — see Deployment-UpdateChannels-A.md Learning Pointers."
        })
    }

    # -----------------------------------------------------------------------
    # 2. Channel authority — GPO override check
    # -----------------------------------------------------------------------
    Write-Status "Checking for GPO-enforced update channel policy..." "INFO"
    $gpoKeyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\OfficeUpdate"
    $gpoConfig = Get-ItemProperty -Path $gpoKeyPath -ErrorAction SilentlyContinue

    if ($gpoConfig -and $gpoConfig.updatebranch) {
        $findings.Add([pscustomobject]@{
            Check = "ChannelAuthority"; Flag = "GPO_OVERRIDE_ACTIVE"
            Detail = "GPO OfficeUpdate policy present (updatebranch='$($gpoConfig.updatebranch)'). This overrides ODT/admin-center channel settings unconditionally. Any channel change must be made via this GPO, not ODT or the admin center."
        })
        Write-Status "GPO channel policy is ACTIVE and authoritative — updatebranch=$($gpoConfig.updatebranch)" "WARN"
    }
    else {
        Write-Status "No GPO channel override detected — ODT/admin-center settings are authoritative." "OK"
    }

    # -----------------------------------------------------------------------
    # 3. Update task health
    # -----------------------------------------------------------------------
    Write-Status "Checking Office Automatic Updates 2.0 scheduled task..." "INFO"
    $task = Get-ScheduledTask -TaskName "Office Automatic Updates 2.0" -ErrorAction SilentlyContinue

    if (-not $task) {
        $findings.Add([pscustomobject]@{
            Check = "UpdateTask"; Flag = "UPDATE_TASK_MISSING"
            Detail = "Scheduled task 'Office Automatic Updates 2.0' not found. Updates will silently never apply. Run a Quick Repair to recreate Click-to-Run's scheduled tasks."
        })
    }
    elseif ($task.State -eq "Disabled") {
        $findings.Add([pscustomobject]@{
            Check = "UpdateTask"; Flag = "UPDATE_TASK_DISABLED"
            Detail = "Task exists but is Disabled. Re-enable with: Enable-ScheduledTask -TaskName 'Office Automatic Updates 2.0'"
        })
    }
    else {
        $taskInfo = Get-ScheduledTaskInfo -TaskName "Office Automatic Updates 2.0" -ErrorAction SilentlyContinue
        $findings.Add([pscustomobject]@{
            Check = "UpdateTask"; Flag = "OK"
            Detail = "Task state: $($task.State); Last run: $($taskInfo.LastRunTime); Last result: $($taskInfo.LastTaskResult)"
        })
    }

    # -----------------------------------------------------------------------
    # 4. CDN reachability
    # -----------------------------------------------------------------------
    Write-Status "Checking Office CDN reachability..." "INFO"
    try {
        $cdnTest = Test-NetConnection -ComputerName "officecdn.microsoft.com" -Port 443 -WarningAction SilentlyContinue
        if (-not $cdnTest.TcpTestSucceeded) {
            $findings.Add([pscustomobject]@{
                Check = "CDNConnectivity"; Flag = "CDN_UNREACHABLE"
                Detail = "TCP 443 to officecdn.microsoft.com failed. Updates cannot be downloaded. Check proxy/firewall egress rules for this endpoint."
            })
        }
        else {
            $findings.Add([pscustomobject]@{ Check = "CDNConnectivity"; Flag = "OK"; Detail = "officecdn.microsoft.com:443 reachable." })
        }
    }
    catch {
        $findings.Add([pscustomobject]@{
            Check = "CDNConnectivity"; Flag = "CDN_CHECK_FAILED"
            Detail = "Could not test CDN connectivity: $($_.Exception.Message)"
        })
    }
}

# ---------------------------------------------------------------------------
# 5. Activation status (independent of Click-to-Run check — applies broadly)
# ---------------------------------------------------------------------------
if (-not $SkipActivationCheck) {
    Write-Status "Checking activation status..." "INFO"
    $osppPath = "$env:ProgramFiles\Microsoft Office\Office16\OSPP.VBS"
    if (-not (Test-Path $osppPath)) {
        $osppPath = "${env:ProgramFiles(x86)}\Microsoft Office\Office16\OSPP.VBS"
    }

    if (Test-Path $osppPath) {
        try {
            $osppOutput = & cscript //nologo $osppPath /dstatus 2>&1 | Out-String
            if ($osppOutput -match "LICENSE STATUS:\s*-+LICENSED-+") {
                $findings.Add([pscustomobject]@{ Check = "Activation"; Flag = "LICENSED"; Detail = "Product reports LICENSED status." })
            }
            elseif ($osppOutput -match "GRACE") {
                $findings.Add([pscustomobject]@{
                    Check = "Activation"; Flag = "GRACE_PERIOD"
                    Detail = "Product is in a grace period (OOB_GRACE/OOT_GRACE) — licensing token issue, not an update-channel issue. Check Entra license assignment and local licensing cache."
                })
            }
            else {
                $findings.Add([pscustomobject]@{
                    Check = "Activation"; Flag = "NOT_LICENSED"
                    Detail = "Product does not report LICENSED status. Raw OSPP output captured in evidence pack — check Entra assignment and local licensing token cache (OneAuth)."
                })
            }
        }
        catch {
            $findings.Add([pscustomobject]@{ Check = "Activation"; Flag = "ACTIVATION_CHECK_FAILED"; Detail = "OSPP.VBS execution failed: $($_.Exception.Message)" })
        }
    }
    else {
        $findings.Add([pscustomobject]@{ Check = "Activation"; Flag = "OSPP_NOT_FOUND"; Detail = "OSPP.VBS not found at expected paths — activation status could not be checked." })
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Microsoft 365 Apps Health Summary ===" -ForegroundColor Cyan
Write-Host "Device: $env:COMPUTERNAME | User: $env:USERNAME"
Write-Host "Total findings: $($findings.Count)"
Write-Host ""
$findings | Format-Table -AutoSize -Wrap

$csvPath = "$env:USERPROFILE\Desktop\M365AppsHealth_$(Get-Date -Format yyyyMMdd_HHmmss).csv"
$findings | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Status "Full results exported to: $csvPath" "OK"
