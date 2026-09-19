<#
.SYNOPSIS
    Audits a domain-joined Windows device for exposure to the September 2026
    Machine Identity Isolation domain-trust-failure known issue (KB5124008 /
    KB5124012), and reports whether the environment is in Microsoft's supported
    configuration for the feature.

.DESCRIPTION
    Machine Identity Isolation is a Credential Guard/VBS feature that isolates a
    domain-joined device's machine account secret. Microsoft's September 2026
    cumulative updates made Windows begin honoring previously dormant
    enforcement settings for this feature (dormant since KB5055523, April 2026,
    temporarily disabled it tenant-wide), which has caused secure-channel/
    domain-trust failures on devices where the domain is below Windows Server
    2025 Domain Functional Level.

    This script performs a READ-ONLY audit of a single device:
      - Confirms whether the triggering CU is installed
      - Reads the MachineIdentityIsolation value from both possible registry
        locations (policy-provisioned and local/effective)
      - Queries the domain's functional level (requires the ActiveDirectory
        RSAT module; reported as unavailable if the module is not present)
      - Checks VBS/Credential Guard runtime health
      - Runs a non-repairing secure channel health check
      - Classifies the device as: Not Applicable / Supported-Healthy /
        Supported-Broken / Unsupported-Enforcing / Unsupported-Broken

    It makes NO configuration changes and does NOT run any repair, unjoin, or
    rejoin operation. For remediation, see the Common Fix Paths in
    MachineIdentityIsolation-B.md and the Remediation Playbooks in
    MachineIdentityIsolation-A.md.

.PARAMETER OutputPath
    Folder to write the CSV/JSON report output to. Defaults to
    C:\Temp\MII-Diagnostics.

.PARAMETER SkipDomainModeCheck
    Switch. Skips the Get-ADDomain call (useful on a device without the
    ActiveDirectory RSAT module installed, or when running at scale via an
    RMM/Intune Remediation script where that module isn't available).

.EXAMPLE
    .\Get-MachineIdentityIsolationAudit.ps1

.EXAMPLE
    .\Get-MachineIdentityIsolationAudit.ps1 -OutputPath 'D:\Reports\MII' -SkipDomainModeCheck

.NOTES
    Run from an elevated PowerShell session on the target device.
    Requires: local admin (to query HKLM registry paths and Device Guard CIM
    class); ActiveDirectory RSAT module for the domain functional level check
    (optional — skip with -SkipDomainModeCheck if unavailable).
    Safe/Read-only: makes no configuration, repair, or domain membership changes.
    Suitable for deployment as an Intune Remediation "detection" script or a
    scheduled RMM job across a fleet.
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$OutputPath = 'C:\Temp\MII-Diagnostics',
    [switch]$SkipDomainModeCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    param([string]$Message, [string]$Status = 'INFO')
    $colour = switch ($Status) { 'OK' {'Green'} 'WARN' {'Yellow'} 'ERROR' {'Red'} default {'Cyan'} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    Write-Status "Created output directory: $OutputPath"
}

Write-Status "Starting Machine Identity Isolation audit on $($env:COMPUTERNAME)"

# --- Preflight ---
$result = [ordered]@{
    ComputerName            = $env:COMPUTERNAME
    ScanTimeUtc             = (Get-Date).ToUniversalTime().ToString('o')
    OSVersion                = $null
    OSBuild                  = $null
    TriggerCUInstalled       = $false
    TriggerCUDetail          = @()
    PolicyValue              = $null
    LocalValue                = $null
    EffectiveEnforcement      = $false
    DomainFunctionalLevel     = $null
    DomainModeCheckSkipped    = [bool]$SkipDomainModeCheck
    VBSRunning                = $null
    CredentialGuardRunning    = $null
    SecureChannelHealthy      = $null
    Classification             = 'Unknown'
    Notes                      = @()
}

# --- Detect: OS version/build ---
try {
    $osInfo = Get-ComputerInfo -Property OsVersion, OsBuildNumber
    $result.OSVersion = $osInfo.OsVersion
    $result.OSBuild = $osInfo.OsBuildNumber
    Write-Status "OS build: $($result.OSBuild)"
} catch {
    $result.Notes += "Could not read OS version/build: $($_.Exception.Message)"
    Write-Status "Could not read OS version/build" -Status WARN
}

# --- Detect: triggering CU ---
try {
    $hotfixes = Get-HotFix -Id KB5124008, KB5124012 -ErrorAction SilentlyContinue
    if ($hotfixes) {
        $result.TriggerCUInstalled = $true
        $result.TriggerCUDetail = $hotfixes | ForEach-Object { "$($_.HotFixID) (installed $($_.InstalledOn))" }
        Write-Status "Trigger CU present: $($result.TriggerCUDetail -join '; ')" -Status WARN
    } else {
        Write-Status "Trigger CU (KB5124008/KB5124012) not found — device likely not exposed to this issue" -Status OK
    }
} catch {
    $result.Notes += "Could not query hotfixes: $($_.Exception.Message)"
    Write-Status "Could not query installed hotfixes" -Status WARN
}

# --- Detect: MachineIdentityIsolation registry values ---
try {
    $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard'
    $localPath  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'

    $policyVal = (Get-ItemProperty -Path $policyPath -Name MachineIdentityIsolation -ErrorAction SilentlyContinue).MachineIdentityIsolation
    $localVal  = (Get-ItemProperty -Path $localPath -Name MachineIdentityIsolation -ErrorAction SilentlyContinue).MachineIdentityIsolation

    $result.PolicyValue = $policyVal
    $result.LocalValue = $localVal
    $result.EffectiveEnforcement = ($policyVal -eq 2) -or ($localVal -eq 2)

    Write-Status "MachineIdentityIsolation — policy path: $(if ($null -ne $policyVal) { $policyVal } else { 'not set' }); local path: $(if ($null -ne $localVal) { $localVal } else { 'not set' })"
} catch {
    $result.Notes += "Could not read MachineIdentityIsolation registry values: $($_.Exception.Message)"
    Write-Status "Could not read MachineIdentityIsolation registry values" -Status WARN
}

# --- Detect: domain functional level ---
if (-not $SkipDomainModeCheck) {
    try {
        if (Get-Module -ListAvailable -Name ActiveDirectory) {
            Import-Module ActiveDirectory -ErrorAction Stop
            $result.DomainFunctionalLevel = (Get-ADDomain -ErrorAction Stop).DomainMode.ToString()
            Write-Status "Domain functional level: $($result.DomainFunctionalLevel)"
        } else {
            $result.Notes += 'ActiveDirectory RSAT module not available on this device — domain functional level not checked. Run this check separately from a domain controller or a management workstation with RSAT installed.'
            Write-Status 'ActiveDirectory RSAT module not available — skipping domain functional level check' -Status WARN
        }
    } catch {
        $result.Notes += "Could not query domain functional level: $($_.Exception.Message)"
        Write-Status "Could not query domain functional level" -Status WARN
    }
} else {
    $result.Notes += 'Domain functional level check skipped by -SkipDomainModeCheck.'
}

# --- Detect: VBS / Credential Guard runtime health ---
try {
    $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction SilentlyContinue
    if ($dg) {
        $result.VBSRunning = ($dg.VirtualizationBasedSecurityStatus -eq 2)
        $result.CredentialGuardRunning = [bool]($dg.SecurityServicesRunning -contains 1)
        Write-Status "VBS running: $($result.VBSRunning); Credential Guard running: $($result.CredentialGuardRunning)"
    } else {
        $result.Notes += 'Win32_DeviceGuard CIM class returned no data — VBS/Credential Guard status unknown.'
        Write-Status 'Could not read Win32_DeviceGuard CIM data' -Status WARN
    }
} catch {
    $result.Notes += "Could not query VBS/Credential Guard status: $($_.Exception.Message)"
    Write-Status "Could not query VBS/Credential Guard status" -Status WARN
}

# --- Detect: secure channel health (non-repairing) ---
try {
    $result.SecureChannelHealthy = Test-ComputerSecureChannel
    Write-Status "Secure channel healthy: $($result.SecureChannelHealthy)" -Status $(if ($result.SecureChannelHealthy) { 'OK' } else { 'ERROR' })
} catch {
    $result.Notes += "Could not run Test-ComputerSecureChannel: $($_.Exception.Message)"
    Write-Status "Could not run Test-ComputerSecureChannel" -Status WARN
}

# --- Classify ---
if (-not $result.EffectiveEnforcement) {
    $result.Classification = 'NotApplicable-NotEnforcing'
} elseif ($result.DomainFunctionalLevel -match '2025') {
    $result.Classification = if ($result.SecureChannelHealthy) { 'Supported-Healthy' } else { 'Supported-Broken-NeedsRepair' }
} elseif ($null -eq $result.DomainFunctionalLevel) {
    $result.Classification = 'Enforcing-DFLUnknown-VerifyManually'
} else {
    $result.Classification = if ($result.SecureChannelHealthy) { 'Unsupported-Enforcing-NotYetBroken' } else { 'Unsupported-Broken-DisableRequired' }
}

Write-Status "Classification: $($result.Classification)" -Status $(
    switch -Wildcard ($result.Classification) {
        'Supported-Healthy'        { 'OK' }
        'NotApplicable*'           { 'OK' }
        '*Broken*'                 { 'ERROR' }
        default                    { 'WARN' }
    }
)

# --- Export ---
$csvPath = Join-Path $OutputPath "MII-Audit-$($env:COMPUTERNAME)-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$jsonPath = $csvPath -replace '\.csv$', '.json'

[pscustomobject]$result | Export-Csv -Path $csvPath -NoTypeInformation -Force
$result | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Force

Write-Status "Report written to: $csvPath" -Status OK
Write-Status "Report written to: $jsonPath" -Status OK
Write-Status "Audit complete. This script made no configuration changes." -Status OK
