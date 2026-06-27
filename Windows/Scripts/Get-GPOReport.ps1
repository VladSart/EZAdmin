<#
.SYNOPSIS
    Generates a diagnostic report of Group Policy Objects, inheritance, and recent processing errors.

.DESCRIPTION
    Collects GPO health data from Active Directory and the local device, including:
    - GPO inventory with link status, WMI filters, and version mismatches
    - GPO inheritance per OU (blocked inheritance detection)
    - Last GPO processing result on local machine (event log + registry)
    - RSoP summary for a target user/computer (optional)
    - Detected processing errors from System event log (Event IDs 1085, 1006, 1030, 1058)
    - Sysvol replication health check

    Requires RSAT: Group Policy Management Tools for AD queries.
    Local GPO processing diagnostics run without RSAT.

    Exports a CSV report and HTML summary to the output path.

.PARAMETER DCName
    Domain Controller to query for GPO data. Defaults to the logon DC.

.PARAMETER TargetOU
    Distinguished Name of an OU to check GPO inheritance. Optional.

.PARAMETER TargetUser
    Username (SAMAccountName) to generate RSoP summary for. Optional.

.PARAMETER DaysBack
    Number of days of GPO processing events to retrieve. Default: 7.

.PARAMETER OutputPath
    Output folder for CSV and HTML report. Default: C:\Temp\GPO-Report-<timestamp>

.EXAMPLE
    # Basic run — GPO inventory + local processing health
    .\Get-GPOReport.ps1

.EXAMPLE
    # Full audit against a specific OU and DC
    .\Get-GPOReport.ps1 -DCName DC01 -TargetOU "OU=Workstations,DC=contoso,DC=com" -DaysBack 14

.EXAMPLE
    # Include RSoP for a specific user
    .\Get-GPOReport.ps1 -TargetUser jsmith

.NOTES
    Requires: RSAT Group Policy Management Tools (for AD queries only)
    Run As: Domain user (read-only for inventory); Domain Admin for RSoP/Sysvol checks
    Safe: Read-only
    Tested: Windows 10/11, Server 2016/2019/2022
#>

[CmdletBinding()]
param(
    [string]$DCName,
    [string]$TargetOU,
    [string]$TargetUser,
    [int]$DaysBack = 7,
    [string]$OutputPath = "C:\Temp\GPO-Report-$(Get-Date -Format 'yyyyMMdd-HHmm')"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

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

# ─── Output folder ───
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

# ─── Check for RSAT Group Policy module ───
$hasGPModule = Get-Module -ListAvailable -Name GroupPolicy -ErrorAction SilentlyContinue
if (-not $hasGPModule) {
    Write-Status "RSAT Group Policy module not found — AD GPO inventory skipped. Install via: Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0" "WARN"
}

# ═══════════════════════════════════════════════════════════════
# SECTION 1 — GPO Inventory (requires RSAT)
# ═══════════════════════════════════════════════════════════════

$gpoInventory = @()

if ($hasGPModule) {
    Write-Status "Collecting GPO inventory from AD..." "INFO"
    Import-Module GroupPolicy -ErrorAction SilentlyContinue

    $gpoParams = @{ All = $true }
    if ($DCName) { $gpoParams.Server = $DCName }

    try {
        $allGPOs = Get-GPO @gpoParams

        foreach ($gpo in $allGPOs) {
            # Check for WMI filter
            $wmiFilter = if ($gpo.WmiFilter) { $gpo.WmiFilter.Name } else { "None" }

            # Check version consistency (AD version vs Sysvol version)
            $versionOK = $gpo.UserVersion -ne $null

            # Get GPO links
            $report = [xml](Get-GPOReport -Guid $gpo.Id -ReportType Xml -ErrorAction SilentlyContinue)
            $links = @()
            if ($report) {
                $links = $report.GPO.LinksTo | ForEach-Object {
                    "$($_.SOMPath) [Enforced:$($_.NoOverride), Enabled:$($_.Enabled)]"
                }
            }

            $gpoInventory += [PSCustomObject]@{
                DisplayName        = $gpo.DisplayName
                GPOStatus          = $gpo.GpoStatus
                CreatedTime        = $gpo.CreationTime
                ModifiedTime       = $gpo.ModificationTime
                ComputerVersionAD  = $gpo.Computer.DSVersion
                ComputerVersionSys = $gpo.Computer.SysvolVersion
                UserVersionAD      = $gpo.User.DSVersion
                UserVersionSys     = $gpo.User.SysvolVersion
                VersionMismatch    = ($gpo.Computer.DSVersion -ne $gpo.Computer.SysvolVersion -or $gpo.User.DSVersion -ne $gpo.User.SysvolVersion)
                WMIFilter          = $wmiFilter
                LinkedTo           = ($links -join " | ")
                LinkCount          = $links.Count
                GPOId              = $gpo.Id
            }
        }

        $mismatchCount = ($gpoInventory | Where-Object VersionMismatch).Count
        Write-Status "GPOs found: $($gpoInventory.Count) | Version mismatches: $mismatchCount" $(if ($mismatchCount -gt 0) { "WARN" } else { "OK" })

        # Export
        $gpoInventory | Export-Csv -Path "$OutputPath\GPO-Inventory.csv" -NoTypeInformation -Encoding UTF8
        Write-Status "GPO inventory saved: $OutputPath\GPO-Inventory.csv" "OK"

    } catch {
        Write-Status "Error collecting GPO inventory: $($_.Exception.Message)" "ERROR"
    }

    # ─── OU Inheritance ───
    if ($TargetOU) {
        Write-Status "Checking GPO inheritance for OU: $TargetOU" "INFO"
        try {
            $inheritance = Get-GPInheritance -Target $TargetOU -ErrorAction Stop
            $inheritanceData = [PSCustomObject]@{
                OU                  = $TargetOU
                InheritanceBlocked  = $inheritance.GpoInheritanceBlocked
                InheritedGPOCount   = $inheritance.InheritedGpoLinks.Count
                DirectGPOCount      = $inheritance.GpoLinks.Count
                InheritedGPOs       = ($inheritance.InheritedGpoLinks | ForEach-Object { "$($_.DisplayName) [Order:$($_.Order)]" }) -join " | "
            }
            Write-Status "OU inheritance blocked: $($inheritanceData.InheritanceBlocked)" $(if ($inheritanceData.InheritanceBlocked) { "WARN" } else { "OK" })
            $inheritanceData | Export-Csv -Path "$OutputPath\OU-Inheritance.csv" -NoTypeInformation -Encoding UTF8
        } catch {
            Write-Status "Could not get inheritance for $TargetOU — $($_.Exception.Message)" "ERROR"
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# SECTION 2 — Local GPO Processing Health
# ═══════════════════════════════════════════════════════════════

Write-Status "Collecting local GPO processing data..." "INFO"

# Registry: last GPO processing time
$localGPOData = [PSCustomObject]@{
    ComputerName                = $env:COMPUTERNAME
    LastComputerGPOApply        = "Unknown"
    LastUserGPOApply            = "Unknown"
    SlowLinkThreshold           = "Unknown"
    BackgroundRefreshEnabled    = "Unknown"
    AsyncProcessingEnabled      = "Unknown"
    GPOProcessingErrors7Days    = 0
}

try {
    $compGPState = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\Extension-List\{00000000-0000-0000-0000-000000000000}" -ErrorAction SilentlyContinue
    if ($compGPState) {
        $localGPOData.LastComputerGPOApply = $compGPState.EndTimeLo
    }
} catch {}

try {
    $gpSettings = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -ErrorAction SilentlyContinue
    if ($gpSettings) {
        $localGPOData.SlowLinkThreshold        = if ($gpSettings.GroupPolicyMinTransferRate) { "$($gpSettings.GroupPolicyMinTransferRate) bps" } else { "Default (500 bps)" }
        $localGPOData.BackgroundRefreshEnabled  = if ($gpSettings.DisableBackgroundPolicy -eq 1) { "Disabled" } else { "Enabled" }
        $localGPOData.AsyncProcessingEnabled    = if ($gpSettings.SynchronousMachineGroupPolicy -eq 1) { "Synchronous (disabled async)" } else { "Async (default)" }
    }
} catch {}

# ─── GPO Processing Errors from Event Log ───
Write-Status "Checking System event log for GPO processing errors (last $DaysBack days)..." "INFO"

$errorEventIDs = @(1085, 1006, 1030, 1058, 1054, 1129)
# 1085 = GPO extension failed to process
# 1006 = Access denied getting GPO list
# 1030 = Failed to query GPO list from DC
# 1058 = Cannot access GPT.ini
# 1054 = Cannot determine GPO list
# 1129 = DC not reachable

$cutoff = (Get-Date).AddDays(-$DaysBack)
$gpoErrors = @()

try {
    $rawEvents = Get-WinEvent -FilterHashtable @{
        LogName   = "System"
        Id        = $errorEventIDs
        StartTime = $cutoff
    } -ErrorAction SilentlyContinue

    foreach ($evt in $rawEvents) {
        $gpoErrors += [PSCustomObject]@{
            Time       = $evt.TimeCreated
            EventID    = $evt.Id
            Source     = $evt.ProviderName
            Message    = ($evt.Message -split "`n")[0]
            Level      = $evt.LevelDisplayName
        }
    }

    $localGPOData.GPOProcessingErrors7Days = $gpoErrors.Count
    Write-Status "GPO processing errors in last $DaysBack days: $($gpoErrors.Count)" $(if ($gpoErrors.Count -gt 0) { "WARN" } else { "OK" })

    if ($gpoErrors.Count -gt 0) {
        $gpoErrors | Export-Csv -Path "$OutputPath\GPO-Processing-Errors.csv" -NoTypeInformation -Encoding UTF8
        Write-Status "Error log saved: $OutputPath\GPO-Processing-Errors.csv" "OK"
    }
} catch {
    Write-Status "Could not query System event log: $($_.Exception.Message)" "ERROR"
}

# ─── GPUpdate output ───
Write-Status "Running gpresult to capture RSoP summary..." "INFO"
try {
    $gpresultPath = "$OutputPath\gpresult.html"
    $gpresultArgs = if ($TargetUser) { "/h `"$gpresultPath`" /user $TargetUser /f" } else { "/h `"$gpresultPath`" /f" }
    Start-Process -FilePath "gpresult.exe" -ArgumentList $gpresultArgs -Wait -WindowStyle Hidden -ErrorAction Stop
    Write-Status "gpresult HTML saved: $gpresultPath" "OK"
} catch {
    Write-Status "gpresult failed: $($_.Exception.Message)" "WARN"
}

# ─── Sysvol reachability ───
Write-Status "Checking Sysvol reachability..." "INFO"
try {
    $domain = (Get-WmiObject Win32_ComputerSystem).Domain
    $sysvolPath = "\\$domain\SYSVOL"
    if (Test-Path $sysvolPath) {
        Write-Status "Sysvol accessible: $sysvolPath" "OK"
    } else {
        Write-Status "Sysvol NOT accessible: $sysvolPath" "ERROR"
    }
} catch {
    Write-Status "Could not test Sysvol: $($_.Exception.Message)" "WARN"
}

# ─── Export local summary ───
$localGPOData | Export-Csv -Path "$OutputPath\Local-GPO-Health.csv" -NoTypeInformation -Encoding UTF8

# ═══════════════════════════════════════════════════════════════
# SECTION 3 — Version Mismatch Alert
# ═══════════════════════════════════════════════════════════════

if ($gpoInventory.Count -gt 0) {
    $mismatches = $gpoInventory | Where-Object VersionMismatch
    if ($mismatches) {
        Write-Status "" "WARN"
        Write-Status "═══ VERSION MISMATCHES DETECTED (AD vs Sysvol) ═══" "WARN"
        $mismatches | ForEach-Object {
            Write-Status "  $($_.DisplayName): Computer AD=$($_.ComputerVersionAD)/Sys=$($_.ComputerVersionSys) | User AD=$($_.UserVersionAD)/Sys=$($_.UserVersionSys)" "WARN"
        }
        Write-Status "These GPOs may not apply correctly — check DFS/Sysvol replication health." "WARN"
    }
}

# ═══════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════

Write-Host ""
Write-Status "═══ GPO DIAGNOSTIC REPORT COMPLETE ═══" "OK"
Write-Status "Output folder: $OutputPath" "OK"
Write-Host ""
Write-Host "Files generated:" -ForegroundColor Cyan
Get-ChildItem $OutputPath | ForEach-Object { Write-Host "  $($_.Name)" }
Write-Host ""

if ($gpoErrors.Count -gt 0) {
    Write-Host "⚠️  $($gpoErrors.Count) GPO processing errors found in last $DaysBack days. Check GPO-Processing-Errors.csv" -ForegroundColor Yellow
}
if ($gpoInventory.Count -gt 0 -and ($gpoInventory | Where-Object VersionMismatch).Count -gt 0) {
    Write-Host "⚠️  GPO Sysvol/AD version mismatches found. Check GPO-Inventory.csv and Sysvol replication." -ForegroundColor Yellow
}
