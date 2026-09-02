<#
.SYNOPSIS    Read-only health/evidence audit for the Global Secure Access (GSA)
             client on Windows.

.DESCRIPTION Collects the installed GSA client version, the running state of
             both core Windows services (Global Secure Access Engine Service
             and Global Secure Access Forwarding Profile Service, using their
             CURRENT names -- earlier client versions used different service
             names, see the Windows GSA client runbooks for the rename
             history), NRPT DNS policy rule count, Hyper-V virtual switch
             types present on the host (relevant to a documented GSA support
             boundary), Entra join/registration state via dsregcmd, and
             whether the installed version meets the documented eligibility
             floor for automatic Windows Update-delivered upgrades
             (2.31.125 on x64, 2.32.294 on Windows on Arm, effective
             November 2026).

             Makes NO configuration changes -- does not install, upgrade,
             restart services, or modify any setting. Intended for planning,
             fleet auditing, or ticket-escalation evidence collection.

.PARAMETER OutputPath
             Directory to write the CSV report to. Defaults to the current
             directory.

.EXAMPLE
             .\Get-GSAWindowsClientHealth.ps1
             .\Get-GSAWindowsClientHealth.ps1 -OutputPath C:\Reports

.NOTES       Run locally as an administrator for full service and NRPT
             visibility. Hyper-V switch enumeration requires the Hyper-V
             PowerShell module (silently skipped if not present/not a
             Hyper-V host). Safe/unsafe: fully read-only, safe to run at
             any time.
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" {"Green"} "WARN" {"Yellow"} "ERROR" {"Red"} default {"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$x64Floor = [version]"2.31.125"
$armFloor = [version]"2.32.294"

$results = [ordered]@{
    ComputerName                       = $env:COMPUTERNAME
    ClientVersion                      = $null
    ArchitectureIsArm                  = $false
    MeetsWindowsUpdateDeliveryFloor    = $false
    EngineServiceStatus                = $null
    ForwardingProfileServiceStatus     = $null
    NRPTRuleCount                      = $null
    HyperVSwitchTypes                  = $null
    EntraJoinState                     = $null
    CollectedAt                        = Get-Date
}

# ---- Detect: architecture ----
try {
    $arch = (Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1).Architecture
    # Win32_Processor Architecture: 9 = x64, 5 = ARM, 12 = ARM64
    $results.ArchitectureIsArm = ($arch -eq 5 -or $arch -eq 12)
}
catch {
    Write-Status "Could not determine processor architecture -- assuming x64 for floor comparison." "WARN"
}

# ---- Detect: client version ----
try {
    $clientInfo = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match "Global Secure Access" } |
        Select-Object -First 1 DisplayName, DisplayVersion

    if ($clientInfo) {
        $results.ClientVersion = $clientInfo.DisplayVersion
        Write-Status "GSA client found: $($clientInfo.DisplayName) version $($clientInfo.DisplayVersion)" "OK"

        try {
            $parsedVersion = [version]$clientInfo.DisplayVersion
            $floor = if ($results.ArchitectureIsArm) { $armFloor } else { $x64Floor }
            $results.MeetsWindowsUpdateDeliveryFloor = $parsedVersion -ge $floor
            if ($results.MeetsWindowsUpdateDeliveryFloor) {
                Write-Status "Client version meets the Windows Update automatic-delivery floor ($floor) -- eligible for automatic upgrades starting November 2026 (unless installed with EnableWindowsUpdates=0)." "OK"
            }
            else {
                Write-Status "Client version is BELOW the Windows Update automatic-delivery floor ($floor for this architecture) -- will remain on manual/MDM upgrade path until upgraded across that floor." "WARN"
            }
        }
        catch {
            Write-Status "Could not parse client version '$($clientInfo.DisplayVersion)' as [version] -- verify manually against the release history." "WARN"
        }
    }
    else {
        Write-Status "Global Secure Access client not found in installed-programs registry on this host." "WARN"
    }
}
catch {
    Write-Status "Error reading client version: $($_.Exception.Message)" "ERROR"
}

# ---- Detect: core services ----
try {
    $engineService = Get-Service -Name "*Global Secure Access Engine*" -ErrorAction SilentlyContinue
    $profileService = Get-Service -Name "*Global Secure Access Forwarding Profile*" -ErrorAction SilentlyContinue

    $results.EngineServiceStatus = if ($engineService) { $engineService.Status } else { "NotFound" }
    $results.ForwardingProfileServiceStatus = if ($profileService) { $profileService.Status } else { "NotFound" }

    if ($results.EngineServiceStatus -eq "Running") {
        Write-Status "Global Secure Access Engine Service: Running" "OK"
    }
    else {
        Write-Status "Global Secure Access Engine Service: $($results.EngineServiceStatus) -- if 'NotFound', check for an older service name (Global Secure Access Management Service, pre-v2.8.45) or an incomplete install." "WARN"
    }

    if ($results.ForwardingProfileServiceStatus -eq "Running") {
        Write-Status "Global Secure Access Forwarding Profile Service: Running" "OK"
    }
    else {
        Write-Status "Global Secure Access Forwarding Profile Service: $($results.ForwardingProfileServiceStatus) -- if 'NotFound', check for an older service name (Global Secure Access Policy Retriever Service / Auto Upgrade Service) or an incomplete install." "WARN"
    }
}
catch {
    Write-Status "Error reading service state: $($_.Exception.Message)" "ERROR"
}

# ---- Detect: NRPT rules ----
try {
    $nrptRules = Get-DnsClientNrptPolicy -ErrorAction SilentlyContinue
    $results.NRPTRuleCount = ($nrptRules | Measure-Object).Count
    Write-Status "NRPT policy rule count: $($results.NRPTRuleCount)" "INFO"
}
catch {
    Write-Status "Could not read NRPT policy: $($_.Exception.Message)" "WARN"
}

# ---- Detect: Hyper-V virtual switches (if applicable) ----
try {
    if (Get-Command Get-VMSwitch -ErrorAction SilentlyContinue) {
        $switches = Get-VMSwitch -ErrorAction SilentlyContinue
        if ($switches) {
            $results.HyperVSwitchTypes = ($switches | ForEach-Object { "$($_.Name):$($_.SwitchType)" }) -join "; "
            if ($switches.SwitchType -contains "External") {
                Write-Status "External Hyper-V virtual switch detected -- GSA client does NOT support host-level bypass for external switches. Confirm the client is installed inside guest VMs needing coverage, not relying on host-only install." "WARN"
            }
            else {
                Write-Status "Hyper-V virtual switch(es) present, none External -- host-level internal-switch bypass behavior applies." "OK"
            }
        }
        else {
            $results.HyperVSwitchTypes = "None"
        }
    }
    else {
        $results.HyperVSwitchTypes = "Hyper-V module not present"
    }
}
catch {
    Write-Status "Could not enumerate Hyper-V switches: $($_.Exception.Message)" "WARN"
}

# ---- Detect: Entra join state ----
try {
    $dsregOutput = & dsregcmd /status 2>$null
    $azureAdJoined = ($dsregOutput | Select-String "AzureAdJoined\s*:\s*YES") -ne $null
    $domainJoined  = ($dsregOutput | Select-String "DomainJoined\s*:\s*YES") -ne $null
    $enterpriseJoined = ($dsregOutput | Select-String "EnterpriseJoined\s*:\s*YES") -ne $null

    if ($azureAdJoined -and $domainJoined) {
        $results.EntraJoinState = "HybridJoined"
    }
    elseif ($azureAdJoined) {
        $results.EntraJoinState = "EntraJoined"
    }
    elseif ($enterpriseJoined) {
        $results.EntraJoinState = "EntraRegistered"
    }
    else {
        $results.EntraJoinState = "None"
        Write-Status "No Entra join/registration state detected -- GSA requires Entra-joined, hybrid-joined, or Entra-registered (BYOD preview). Confirm enrollment before troubleshooting further." "WARN"
    }
    Write-Status "Entra join state: $($results.EntraJoinState)" "INFO"
}
catch {
    Write-Status "Could not read dsregcmd status: $($_.Exception.Message)" "WARN"
}

# ---- Report ----
$reportObject = [PSCustomObject]$results
$reportObject | Format-List

$csvPath = Join-Path -Path $OutputPath -ChildPath "GSAWindowsClientHealth_$($env:COMPUTERNAME)_$(Get-Date -Format yyyyMMdd_HHmmss).csv"
$reportObject | Export-Csv -Path $csvPath -NoTypeInformation
Write-Status "Report exported to $csvPath" "OK"
