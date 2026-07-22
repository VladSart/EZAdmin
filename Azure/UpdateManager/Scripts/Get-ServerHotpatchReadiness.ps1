<#
.SYNOPSIS
    Windows Server 2025 Hotpatch (Azure Arc) readiness audit — checks all locally-verifiable
    eligibility conditions and reports which, if any, are blocking hotpatch enrollment.

.DESCRIPTION
    Collects and reports on:
      - OS edition (Standard/Datacenter/Datacenter: Azure Edition) and build (26100.1742+ requirement)
      - Virtualization-based Security runtime status (Running vs. merely policy-enabled)
      - Azure Connected Machine (Arc) agent presence and connection status — skipped entirely for
        Datacenter: Azure Edition, which does not require Arc enrollment
      - Recent installed update history for a baseline-drift sanity check
      - Presence of the October 2025 feature-licensing bug workaround artifacts (FeatureManagement
        override / cleared licensing mutex), useful evidence when escalating a stuck enrollment

    Does NOT enable/disable hotpatch, enroll or de-enroll the machine, modify VBS state, connect/
    disconnect Azure Arc, or install updates. Read-only, local-device audit. Exports a CSV suitable
    for a fleet-wide readiness rollup when run via Invoke-Command / remote collection.

    Cannot verify from the device itself: the Azure-side hotpatch license/enrollment status
    (Not enrolled / Pending / Enabled / Disabled / Canceled) or Azure Update Manager assessment
    freshness — both are Azure control-plane state. Confirm those separately in the Azure portal
    (Azure Update Manager > Machines > Recommended updates > Hotpatch) or via Az PowerShell/CLI
    against the ARM API.

.PARAMETER ExportPath
    Path for the CSV export. Default: $env:TEMP\ServerHotpatchReadiness_<timestamp>.csv

.PARAMETER SkipArcCheck
    Skip the Azure Arc agent presence/connection check — useful when auditing a
    Datacenter: Azure Edition machine, which does not require Arc, or for a faster local-only pass.
    Default: $false.

.EXAMPLE
    .\Get-ServerHotpatchReadiness.ps1
    # Full local readiness audit with CSV export

.EXAMPLE
    Invoke-Command -ComputerName (Get-Content .\servers.txt) -FilePath .\Get-ServerHotpatchReadiness.ps1
    # Fleet-wide sweep across multiple servers via remoting

.NOTES
    Requires: Local admin rights are NOT required for the read-only checks in this script (standard
              user can read Win32_DeviceGuard, registry values, and Get-HotFix in most configurations);
              admin rights recommended for consistent access to all checks.
    Run as:   Any account with local read access on the target server.
    Best run: Directly on the server being audited (or via remoting for a fleet sweep).
    Safe/Unsafe: READ-ONLY — makes no changes to VBS state, Arc connectivity, hotpatch enrollment,
                 or installed updates.
    Tested against: Windows Server 2025 Standard / Datacenter / Datacenter: Azure Edition.
#>

[CmdletBinding()]
param(
    [string] $ExportPath = "$env:TEMP\ServerHotpatchReadiness_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv",
    [switch] $SkipArcCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"     { "Green"  }
        "WARN"   { "Yellow" }
        "ERROR"  { "Red"    }
        "HEADER" { "Cyan"   }
        default  { "White"  }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

#region --- Preflight ---

Write-Status "Windows Server 2025 Hotpatch (Azure Arc) Readiness Audit" -Status "HEADER"
Write-Status "Server: $env:COMPUTERNAME  |  Run time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Status "INFO"

$findings = [System.Collections.Generic.List[string]]::new()

#endregion

#region --- Condition 1: OS edition + build eligibility ---

Write-Status "Checking OS edition and build..." -Status "INFO"
$osEligible = $null
$isAzureEdition = $false
try {
    $osKey = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    $editionId = $osKey.EditionID
    $currentBuild = [int]$osKey.CurrentBuild
    $ubr = [int]$osKey.UBR

    $isAzureEdition = ($editionId -eq 'ServerAzureEdition')
    $editionEligible = $editionId -in @('ServerStandard', 'ServerDatacenter', 'ServerAzureEdition')

    # Build 26100.1742+ required; treat build number below floor, or UBR below floor at build 26100, as ineligible
    $buildEligible = ($currentBuild -gt 26100) -or ($currentBuild -eq 26100 -and $ubr -ge 1742)

    $osEligible = $editionEligible -and $buildEligible

    if (-not $editionEligible) {
        $findings.Add("Edition '$editionId' is not hotpatch-eligible. Requires Server 2025 Standard, Datacenter, or Datacenter: Azure Edition (Essentials and other editions are not supported).")
    }
    if (-not $buildEligible) {
        $findings.Add("OS build $currentBuild.$ubr is below the required floor (26100.1742) — device is ineligible for hotpatch until updated to a qualifying build.")
    }
} catch {
    $findings.Add("Could not determine OS edition/build: $_")
}

#endregion

#region --- Condition 2: VBS runtime status ---

Write-Status "Checking Virtualization-based Security runtime status..." -Status "INFO"
$vbsRunning = $null
try {
    $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop
    # VirtualizationBasedSecurityStatus: 0 = Not enabled, 1 = Enabled but not running, 2 = Running
    $vbsRunning = ($dg.VirtualizationBasedSecurityStatus -eq 2)
    if (-not $vbsRunning) {
        $stateDesc = switch ($dg.VirtualizationBasedSecurityStatus) {
            0       { "Not enabled" }
            1       { "Enabled but NOT running (needs a reboot, or a firmware/hypervisor-level gap such as missing Secure Boot or a Gen1 VM)" }
            default { "Unknown state ($($dg.VirtualizationBasedSecurityStatus))" }
        }
        $findings.Add("VBS status: $stateDesc. Hotpatch requires VBS to be actually Running, not just policy-enabled.")
    }
} catch {
    $findings.Add("Could not query VBS status via Win32_DeviceGuard: $_")
}

#endregion

#region --- Condition 3: Azure Arc agent presence and connection ---

$arcInstalled = $null
$arcConnected = $null
$arcRawStatus = $null

if (-not $SkipArcCheck -and -not $isAzureEdition) {
    Write-Status "Checking Azure Arc Connected Machine agent..." -Status "INFO"
    $azcmagentPath = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
    $arcInstalled = Test-Path $azcmagentPath

    if ($arcInstalled) {
        try {
            $arcRawStatus = & $azcmagentPath show 2>&1 | Out-String
            $arcConnected = $arcRawStatus -match 'Agent Status\s*:\s*Connected'
            if (-not $arcConnected) {
                $findings.Add("Azure Arc agent is installed but not reporting Connected status — hotpatch enrollment and delivery cannot function until Arc connectivity is restored.")
            }
        } catch {
            $findings.Add("Could not query Arc agent status via azcmagent show: $_")
        }
    } else {
        $findings.Add("Azure Arc Connected Machine agent not found at expected path — machine is not Arc-enabled. Required for hotpatch on this edition (not required for Datacenter: Azure Edition).")
    }
} elseif ($isAzureEdition) {
    Write-Status "Datacenter: Azure Edition detected — Arc enrollment is not required for this SKU, skipping Arc check." -Status "INFO"
} else {
    Write-Status "Arc check skipped (-SkipArcCheck)." -Status "INFO"
}

#endregion

#region --- Condition 4: Recent update history (baseline-drift sanity check) ---

Write-Status "Checking recent update history for baseline-drift signal..." -Status "INFO"
$mostRecentHotfixDate = $null
$recentHotfixId = $null
try {
    $recentHotfix = Get-HotFix -ErrorAction Stop | Sort-Object InstalledOn -Descending | Select-Object -First 1
    $mostRecentHotfixDate = $recentHotfix.InstalledOn
    $recentHotfixId = $recentHotfix.HotFixID

    if ($mostRecentHotfixDate) {
        $daysSinceLastUpdate = (New-TimeSpan -Start $mostRecentHotfixDate -End (Get-Date)).Days
        if ($daysSinceLastUpdate -gt 95) {
            $findings.Add("Most recent installed update ($recentHotfixId) was $daysSinceLastUpdate days ago ($mostRecentHotfixDate) — verify against the currently published quarterly baseline KB in the Hotpatch release notes; this machine may have drifted off the hotpatch track.")
        }
    } else {
        $findings.Add("No hotfix install history returned — could not assess baseline currency.")
    }
} catch {
    $findings.Add("Could not query hotfix history: $_")
}

#endregion

#region --- Condition 5: October 2025 feature-licensing bug workaround artifacts ---

Write-Status "Checking for feature-licensing bug workaround artifacts..." -Status "INFO"
$featureOverridePresent = $false
$licensingMutexPresent = $false
try {
    $overrideValue = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides' -Name '4264695439' -ErrorAction SilentlyContinue
    $featureOverridePresent = [bool]$overrideValue

    $mutexValue = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Subscriptions' -Name 'DeviceLicensingServiceCommandMutex' -ErrorAction SilentlyContinue
    $licensingMutexPresent = [bool]$mutexValue

    if ($licensingMutexPresent) {
        $findings.Add("DeviceLicensingServiceCommandMutex registry value is still present — if this machine was running KB5066835 or later and hit the October 2025 feature-licensing bug, the workaround has not been fully applied (this value should be absent after remediation).")
    }
} catch {
    $findings.Add("Could not check feature-licensing workaround registry state: $_")
}

#endregion

#region --- Report ---

Write-Status "" -Status "INFO"
Write-Status "=== Summary ===" -Status "HEADER"

$overallLocallyEligible = ($osEligible -eq $true) -and ($vbsRunning -eq $true) -and ($isAzureEdition -or $SkipArcCheck -or $arcConnected -eq $true)

if ($overallLocallyEligible) {
    Write-Status "Server appears eligible for hotpatch based on locally-checkable conditions (OS edition/build, VBS runtime, Arc connectivity if applicable)." -Status "OK"
    Write-Status "Note: Azure-side hotpatch license/enrollment status and Update Manager assessment freshness cannot be verified from the device itself — confirm in Azure Update Manager > Machines > Recommended updates > Hotpatch." -Status "INFO"
} else {
    Write-Status "Server has one or more findings blocking hotpatch eligibility:" -Status "WARN"
    foreach ($f in $findings) { Write-Status "  $f" -Status "WARN" }
}

$exportRow = [pscustomobject]@{
    ComputerName              = $env:COMPUTERNAME
    RunTime                   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    OSEditionBuildEligible    = $osEligible
    IsAzureEdition            = $isAzureEdition
    VBSRunning                = $vbsRunning
    ArcAgentInstalled         = $arcInstalled
    ArcAgentConnected         = $arcConnected
    MostRecentHotfixID        = $recentHotfixId
    MostRecentHotfixDate      = $mostRecentHotfixDate
    FeatureOverridePresent    = $featureOverridePresent
    LicensingMutexStillPresent= $licensingMutexPresent
    OverallLocallyEligible    = $overallLocallyEligible
    FindingsCount             = $findings.Count
    Findings                  = ($findings -join " | ")
}

$exportRow | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Report exported: $ExportPath" -Status "OK"

#endregion
