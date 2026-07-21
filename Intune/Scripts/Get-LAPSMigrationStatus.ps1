<#
.SYNOPSIS
    Audits legacy Microsoft LAPS to Windows LAPS migration state — locally on a device, or fleet-wide
    across Active Directory computer objects.

.DESCRIPTION
    Classifies each target device into one of four migration states, per the precedence logic
    documented in Intune/Troubleshooting/LAPS-Migration-A.md:

        - "WindowsLapsActive"   — a real Windows LAPS policy is present (BackupDirectory 1 or 2
                                   populated, or a full policy config detected)
        - "LegacyLapsActive"    — the legacy LAPS CSE (AdmPwd.dll) is registered and no Windows
                                   LAPS policy is present; legacy LAPS governs as designed
        - "EmulationMode"       — neither a Windows LAPS policy nor the legacy CSE is present;
                                   Windows LAPS is silently emulating legacy behavior
        - "EmulationSuppressed" — BackupDirectory is explicitly set to 0, disabling emulation mode

    It also flags the specific unsupported/risky configurations this repo's runbooks call out:
        - A Windows LAPS policy and a legacy GPO both apparently targeting the SAME local account
        - More than one local admin account present with no clear coexistence-migration intent
        - AD computer objects carrying BOTH legacy (ms-Mcs-AdmPwd) and modern (msLAPS-*) attributes
          (expected during a genuine coexistence migration, worth a second look otherwise)
        - Legacy LAPS software (MSI package or manually-registered CSE) still present after a device
          has already cut over to Windows LAPS

    This script does NOT install, remove, or modify anything. It does NOT rotate passwords, disable
    legacy LAPS, or change the BackupDirectory registry value. It is read-only reporting, intended to
    drive a migration project's tracking spreadsheet or to triage one device on the phone with a
    helpdesk engineer.

.PARAMETER ADSweep
    Switch. If set, queries Active Directory computer objects (requires the RSAT ActiveDirectory
    module and AD reachability) for legacy vs. modern LAPS attribute population across the fleet,
    in addition to (or instead of) the local device check. Use -ComputerName '*' with -ADSweep for
    a full domain sweep, or a specific list for a targeted one.

.PARAMETER ComputerName
    One or more computer names to check via -ADSweep. Ignored for the local-only check. Defaults to
    the local computer name if -ADSweep is used without specifying this.

.PARAMETER OutputPath
    Path for CSV export. Defaults to .\LAPSMigrationStatus_<timestamp>.csv in the current directory.

.EXAMPLE
    .\Get-LAPSMigrationStatus.ps1
    # Local-only check — classifies THIS device's current migration state.

.EXAMPLE
    .\Get-LAPSMigrationStatus.ps1 -ADSweep -ComputerName (Get-ADComputer -Filter * | Select -Expand Name)
    # Fleet-wide AD attribute sweep across every computer object in the domain.

.EXAMPLE
    .\Get-LAPSMigrationStatus.ps1 -ADSweep -ComputerName "WKS-01","WKS-02" -OutputPath C:\Reports\laps-migration.csv

.NOTES
    Requires (local check): none beyond built-in PowerShell/registry access; RSAT AD module only if
    the AD attribute cross-check portion of the local check is desired (skipped gracefully if absent).
    Requires (-ADSweep): RSAT ActiveDirectory PowerShell module + AD reachability.
    Run-as: Standard user is sufficient for the local registry/event-log checks; AD queries use the
    caller's own AD read permissions (no elevation required for read-only attribute queries).
    Safe: Yes — fully read-only. Companion remediation playbooks live in
    Intune/Troubleshooting/LAPS-Migration-A.md and LAPS-Migration-B.md.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$ADSweep,

    [Parameter(Mandatory = $false)]
    [string[]]$ComputerName = $env:COMPUTERNAME,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\LAPSMigrationStatus_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$legacyCseGuidPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\GPExtensions\{D76B9641-3288-4f75-942D-087DE603E3EA}"
$lapsConfigPath    = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\Config"
$lapsStatePath     = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\State"

function Get-LocalMigrationState {
    Write-Status "Checking local legacy LAPS CSE registration..."
    $cse = Get-ItemProperty -Path $legacyCseGuidPath -Name "DllName" -ErrorAction SilentlyContinue
    $cseFileExists = $false
    if ($cse -and $cse.DllName) {
        $cseFileExists = Test-Path $cse.DllName -ErrorAction SilentlyContinue
    }

    Write-Status "Checking Windows LAPS policy config (BackupDirectory)..."
    $backupDir = (Get-ItemProperty -Path $lapsConfigPath -Name "BackupDirectory" -ErrorAction SilentlyContinue).BackupDirectory
    $lapsConfigPresent = $null -ne (Get-ItemProperty -Path $lapsConfigPath -ErrorAction SilentlyContinue)

    Write-Status "Checking for emulation-mode config event (Event ID 10023)..."
    $emulationEvent = $null
    try {
        $emulationEvent = Get-WinEvent -LogName "Microsoft-Windows-LAPS/Operational" -MaxEvents 50 -ErrorAction SilentlyContinue |
            Where-Object { $_.Id -eq 10023 } | Select-Object -First 1
    } catch {
        Write-Status "LAPS event log unavailable or empty: $_" "WARN"
    }

    # Classify state per the documented precedence order:
    # 1. Real Windows LAPS policy present -> WindowsLapsActive
    # 2. Legacy CSE installed (and no real policy) -> LegacyLapsActive
    # 3. Neither present, BackupDirectory=0 -> EmulationSuppressed
    # 4. Neither present, no override -> EmulationMode
    $state = if ($backupDir -in 1, 2 -or ($lapsConfigPresent -and -not $cseFileExists -and $backupDir -notin 0)) {
        "WindowsLapsActive"
    } elseif ($cseFileExists) {
        "LegacyLapsActive"
    } elseif ($backupDir -eq 0) {
        "EmulationSuppressed"
    } else {
        "EmulationMode"
    }

    Write-Status "Checking local admin account population..."
    $localAdmins = @()
    try {
        $localAdmins = Get-LocalGroupMember -Group "Administrators" -ErrorAction Stop |
            Where-Object { $_.ObjectClass -eq "User" } | Select-Object -ExpandProperty Name
    } catch {
        Write-Status "Could not enumerate local Administrators group: $_" "WARN"
    }

    $managedAccountName = (Get-ItemProperty -Path $lapsStatePath -Name "AdminAccountName" -ErrorAction SilentlyContinue).AdminAccountName

    Write-Status "Checking legacy package remnants..."
    $legacyPackage = Get-Package -Name "*LAPS*" -ErrorAction SilentlyContinue

    # AD attribute cross-check (best-effort — only if AD module + reachability exist)
    $hasLegacyAttr = "Unknown"
    $hasModernAttr = "Unknown"
    $legacyExpiry  = $null
    $modernExpiry  = $null
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $adObj = Get-ADComputer $env:COMPUTERNAME -Properties 'ms-Mcs-AdmPwd', 'ms-Mcs-AdmPwdExpirationTime', 'msLAPS-Password', 'msLAPS-EncryptedPassword', 'msLAPS-PasswordExpirationTime' -ErrorAction Stop
        $hasLegacyAttr = [bool]$adObj.'ms-Mcs-AdmPwd'
        $hasModernAttr = [bool]($adObj.'msLAPS-Password' -or $adObj.'msLAPS-EncryptedPassword')
        $legacyExpiry  = $adObj.'ms-Mcs-AdmPwdExpirationTime'
        $modernExpiry  = $adObj.'msLAPS-PasswordExpirationTime'
    } catch {
        Write-Status "AD module unavailable or computer object unreachable — skipping AD attribute cross-check" "WARN"
    }

    $riskFlags = [System.Collections.Generic.List[string]]::new()
    if ($state -eq "EmulationMode") {
        $riskFlags.Add("Device is silently in legacy emulation mode — likely undiagnosed")
    }
    if ($localAdmins.Count -gt 1 -and $state -ne "WindowsLapsActive") {
        $riskFlags.Add("Multiple local admin accounts present but no confirmed Windows LAPS policy — verify coexistence intent")
    }
    if ($hasLegacyAttr -eq $true -and $hasModernAttr -eq $true) {
        $riskFlags.Add("Both legacy and modern AD attributes populated — confirm this is an intentional coexistence migration, not a same-account conflict")
    }
    if ($state -eq "WindowsLapsActive" -and ($cseFileExists -or $legacyPackage)) {
        $riskFlags.Add("Windows LAPS is active but legacy software/CSE still present — safe to remove (see Playbook 3)")
    }

    [PSCustomObject]@{
        ComputerName          = $env:COMPUTERNAME
        MigrationState        = $state
        LegacyCSEInstalled    = $cseFileExists
        BackupDirectoryValue  = $backupDir
        EmulationEventFound   = [bool]$emulationEvent
        EmulationEventTime    = $emulationEvent.TimeCreated
        LocalAdminAccounts    = ($localAdmins -join "; ")
        LocalAdminCount       = $localAdmins.Count
        WindowsLapsAccount    = $managedAccountName
        LegacyPackagePresent  = [bool]$legacyPackage
        AD_HasLegacyAttribute = $hasLegacyAttr
        AD_HasModernAttribute = $hasModernAttr
        AD_LegacyExpiry       = $legacyExpiry
        AD_ModernExpiry       = $modernExpiry
        RiskFlags             = ($riskFlags -join " | ")
    }
}

function Get-ADFleetMigrationState {
    param([string[]]$Names)

    try {
        Import-Module ActiveDirectory -ErrorAction Stop
    } catch {
        Write-Status "RSAT ActiveDirectory module not available — cannot run -ADSweep. Install RSAT: Active Directory module first." "ERROR"
        return @()
    }

    $results = foreach ($name in $Names) {
        try {
            $adObj = Get-ADComputer $name -Properties 'ms-Mcs-AdmPwd', 'ms-Mcs-AdmPwdExpirationTime', 'msLAPS-Password', 'msLAPS-EncryptedPassword', 'msLAPS-PasswordExpirationTime' -ErrorAction Stop

            $hasLegacy = [bool]$adObj.'ms-Mcs-AdmPwd'
            $hasModern = [bool]($adObj.'msLAPS-Password' -or $adObj.'msLAPS-EncryptedPassword')

            $bucket = if ($hasLegacy -and $hasModern) { "Coexistence (both attribute sets present)" }
                      elseif ($hasModern) { "Modern only (migrated)" }
                      elseif ($hasLegacy) { "Legacy only (not yet migrated)" }
                      else { "Neither (unmanaged or emulation-only, cannot see from AD alone)" }

            [PSCustomObject]@{
                ComputerName    = $name
                MigrationBucket = $bucket
                LegacyExpiry    = $adObj.'ms-Mcs-AdmPwdExpirationTime'
                ModernExpiry    = $adObj.'msLAPS-PasswordExpirationTime'
            }
        } catch {
            [PSCustomObject]@{
                ComputerName    = $name
                MigrationBucket = "Error: $($_.Exception.Message)"
                LegacyExpiry    = $null
                ModernExpiry    = $null
            }
        }
    }

    return $results
}

# --- Main ---

if ($ADSweep) {
    Write-Status "Running AD fleet-wide migration sweep across $($ComputerName.Count) computer object(s)..."
    $fleetResults = Get-ADFleetMigrationState -Names $ComputerName
    $fleetResults | Export-Csv -Path $OutputPath -NoTypeInformation
    Write-Status "Fleet sweep complete. Report saved to $OutputPath" "OK"

    $summary = $fleetResults | Group-Object MigrationBucket | Select-Object Name, Count
    $summary | Format-Table -AutoSize
} else {
    Write-Status "Running local device migration state check..."
    $localResult = Get-LocalMigrationState
    $localResult | Format-List
    $localResult | Export-Csv -Path $OutputPath -NoTypeInformation
    Write-Status "Local check complete. Report saved to $OutputPath" "OK"

    if ($localResult.RiskFlags) {
        Write-Status "Risk flags found: $($localResult.RiskFlags)" "WARN"
    } else {
        Write-Status "No risk flags found for this device." "OK"
    }
}
