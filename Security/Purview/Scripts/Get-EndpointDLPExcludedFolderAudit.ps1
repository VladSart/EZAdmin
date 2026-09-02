<#
.SYNOPSIS
    Read-only readiness audit for Microsoft Purview Endpoint DLP protected-excluded-folder
    enforcement (Microsoft 365 Roadmap ID 562992, Message Center MC1384420, GA Sept 2026).

.DESCRIPTION
    The protected-excluded-folder feature itself (the per-path "protect during egress" flag
    under Endpoint settings > File path exclusions for Windows) is configured entirely in the
    Purview portal and has NO documented PowerShell or Microsoft Graph read/write surface as
    of this writing. This script does NOT read, create, or modify that configuration.

    Instead it audits the adjacent, scriptable prerequisites and context an engineer needs
    before recommending, enabling, or troubleshooting this feature:
      - Local (or remote, via -ComputerName) Defender anti-malware client version against the
        4.18.26051 hard-prerequisite floor
      - Intune-managed Windows device population (Endpoint DLP onboarding proxy)
      - Existing DLP policies scoped to the Devices workload, and whether their rules cover
        common egress activities (copy, print, network share, cloud upload)
      - Recent Endpoint DLP activity volume, to flag devices/users worth pilot-testing first

    Output is exported to CSV files plus a console summary. Prints an explicit portal-only
    checklist for the protected-path flag state itself, since it cannot be queried
    programmatically.

.PARAMETER ComputerName
    Optional. One or more remote computer names to check Defender client version on via
    PS remoting (WinRM). If omitted, only the local machine is checked.

.PARAMETER OutputPath
    Directory to write CSV exports to. Defaults to the current directory.

.PARAMETER LookbackDays
    Number of days of Endpoint DLP activity history to pull via Get-DlpDetailReport.
    Defaults to 7.

.EXAMPLE
    .\Get-EndpointDLPExcludedFolderAudit.ps1 -OutputPath C:\Audits -LookbackDays 14

.EXAMPLE
    .\Get-EndpointDLPExcludedFolderAudit.ps1 -ComputerName PC01,PC02,PC03

.NOTES
    Requires: Connect-IPPSSession (Security & Compliance PowerShell) for the DLP policy/report
    cmdlets, and Microsoft.Graph (Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All")
    for the Intune device inventory query. Remote Defender version checks require WinRM/PS
    remoting enabled on target devices and appropriate local admin rights.
    Safe/read-only: issues no writes, flags no paths, creates no policies, blocks nothing.
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [string]$OutputPath = ".",
    [int]$LookbackDays = 7
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$MinClientVersion = [version]"4.18.26051.0"

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Status "Starting Endpoint DLP protected-excluded-folder readiness audit" "INFO"

# ---------------------------------------------------------------------------
# 1. Preflight — confirm required sessions are connected (does not connect itself,
#    only checks and warns, to avoid prompting for credentials mid-script)
# ---------------------------------------------------------------------------
$ippsConnected = $false
try {
    $null = Get-DlpCompliancePolicy -ErrorAction Stop
    $ippsConnected = $true
    Write-Status "Security & Compliance PowerShell session detected" "OK"
} catch {
    Write-Status "Not connected to Security & Compliance PowerShell. Run Connect-IPPSSession first. Policy/report sections will be skipped." "WARN"
}

$graphConnected = $false
try {
    $null = Get-MgContext -ErrorAction Stop
    if ($null -ne (Get-MgContext)) { $graphConnected = $true }
} catch { }
if ($graphConnected) {
    Write-Status "Microsoft Graph session detected" "OK"
} else {
    Write-Status "Not connected to Microsoft Graph. Run Connect-MgGraph -Scopes 'DeviceManagementManagedDevices.Read.All' first. Device inventory section will be skipped." "WARN"
}

# ---------------------------------------------------------------------------
# 2. Defender anti-malware client version — local + optional remote
# ---------------------------------------------------------------------------
$clientResults = @()

try {
    $localStatus = Get-MpComputerStatus
    $localVersion = [version]$localStatus.AMProductVersion
    $clientResults += [pscustomobject]@{
        ComputerName    = $env:COMPUTERNAME
        AMProductVersion = $localStatus.AMProductVersion
        MeetsFloor      = $localVersion -ge $MinClientVersion
        Source          = "Local"
    }
} catch {
    Write-Status "Could not read local Get-MpComputerStatus: $($_.Exception.Message)" "WARN"
}

if ($ComputerName) {
    foreach ($cn in $ComputerName) {
        try {
            $remoteStatus = Invoke-Command -ComputerName $cn -ScriptBlock {
                Get-MpComputerStatus | Select-Object AMProductVersion
            } -ErrorAction Stop
            $remoteVersion = [version]$remoteStatus.AMProductVersion
            $clientResults += [pscustomobject]@{
                ComputerName     = $cn
                AMProductVersion = $remoteStatus.AMProductVersion
                MeetsFloor       = $remoteVersion -ge $MinClientVersion
                Source           = "Remote"
            }
        } catch {
            Write-Status "Could not reach $cn via PS remoting: $($_.Exception.Message)" "WARN"
            $clientResults += [pscustomobject]@{
                ComputerName     = $cn
                AMProductVersion = "UNREACHABLE"
                MeetsFloor       = $false
                Source           = "Remote"
            }
        }
    }
}

$clientResults | Export-Csv (Join-Path $OutputPath "DefenderClientVersionAudit.csv") -NoTypeInformation
$belowFloor = $clientResults | Where-Object { $_.MeetsFloor -eq $false }
if ($belowFloor) {
    Write-Status "$($belowFloor.Count) checked device(s) are BELOW the 4.18.26051 floor and will NOT enforce protected-folder policy." "WARN"
} else {
    Write-Status "All checked devices meet the 4.18.26051 client version floor" "OK"
}

# ---------------------------------------------------------------------------
# 3. Intune-managed Windows device population (onboarding proxy)
# ---------------------------------------------------------------------------
if ($graphConnected) {
    try {
        $winDevices = Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'Windows'" -All |
            Select-Object DeviceName, OSVersion, LastSyncDateTime, ComplianceState
        $winDevices | Export-Csv (Join-Path $OutputPath "IntuneWindowsDevices.csv") -NoTypeInformation
        Write-Status "Exported $($winDevices.Count) Intune-managed Windows device records" "OK"
    } catch {
        Write-Status "Graph device inventory query failed: $($_.Exception.Message)" "WARN"
    }
}

# ---------------------------------------------------------------------------
# 4. Devices-scoped DLP policies and rule activity coverage
# ---------------------------------------------------------------------------
if ($ippsConnected) {
    try {
        $devicePolicies = Get-DlpCompliancePolicy | Where-Object { $_.Workload -match "EndpointDevices" }
        $policySummary = foreach ($p in $devicePolicies) {
            $rules = Get-DlpComplianceRule -Policy $p.Name -ErrorAction SilentlyContinue
            foreach ($r in $rules) {
                [pscustomobject]@{
                    PolicyName    = $p.Name
                    PolicyMode    = $p.Mode
                    PolicyEnabled = $p.Enabled
                    RuleName      = $r.Name
                    BlockAccess   = $r.BlockAccess
                    GenerateAlert = $r.GenerateAlert
                }
            }
        }
        $policySummary | Export-Csv (Join-Path $OutputPath "DevicesScopedPolicyRules.csv") -NoTypeInformation
        if (-not $devicePolicies) {
            Write-Status "No DLP policy scoped to the Devices workload was found — protected-folder flags will have nothing to enforce against." "WARN"
        } else {
            Write-Status "Found $($devicePolicies.Count) Devices-scoped polic(y/ies) with $($policySummary.Count) rule(s) total" "OK"
        }
    } catch {
        Write-Status "DLP policy query failed: $($_.Exception.Message)" "WARN"
    }

    # ---------------------------------------------------------------------
    # 5. Recent Endpoint DLP activity volume
    # ---------------------------------------------------------------------
    try {
        $activity = Get-DlpDetailReport -StartDate (Get-Date).AddDays(-$LookbackDays) -EndDate (Get-Date) -PageSize 200 |
            Where-Object { $_.Workload -eq "EndpointDevices" }
        $activity | Export-Csv (Join-Path $OutputPath "RecentEndpointDlpActivity.csv") -NoTypeInformation
        Write-Status "Exported $($activity.Count) Endpoint DLP activity record(s) from the last $LookbackDays day(s)" "OK"
    } catch {
        Write-Status "Get-DlpDetailReport query failed: $($_.Exception.Message)" "WARN"
    }
}

# ---------------------------------------------------------------------------
# 6. Portal-only checklist — cannot be queried programmatically
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Portal-only items this script CANNOT check ===" -ForegroundColor Yellow
Write-Host "  [ ] Whether the tenant has received the MC1384420 GA rollout (feature visibility)"
Write-Host "  [ ] Per-path 'protected during egress' flag state for AppData/Roaming, AppData/Local, or custom paths"
Write-Host "  [ ] Exact exclusion path syntax as configured (trailing \, \*, subfolder-depth (n))"
Write-Host "  Verify all three at: Purview portal > Data loss prevention > Overview >"
Write-Host "  Data loss prevention settings > Endpoint settings > File path exclusions for Windows"
Write-Host ""
Write-Status "Audit complete. CSV exports written to $OutputPath" "OK"
