<#
.SYNOPSIS
    Audits Windows Defender Application Control (WDAC) policy status across one or more devices.

.DESCRIPTION
    Queries the local device or remote devices for WDAC policy deployment status,
    active policy details, enforcement mode, and any blocked events in the last N days.
    Exports findings to CSV and outputs a colour-coded summary to the console.

    Covers:
    - Active policy GUIDs and their enforcement mode (Audit vs Enforce)
    - Policy version and friendly name (if resolvable from registry)
    - Recent WDAC block/audit events (Event ID 3076/3077 from Microsoft-Windows-CodeIntegrity/Operational)
    - WDAC-related MDM CSP policy state
    - Whether Secure Boot and HVCI are active (prerequisites for full WDAC value)

    Does NOT cover:
    - AppLocker (separate log/CSP)
    - Smart App Control (consumer feature, different registry key)
    - Policy deployment — use Intune or GPO for that

.PARAMETER ComputerName
    One or more remote computer names. Defaults to the local machine if omitted.

.PARAMETER DaysBack
    Number of days of WDAC block/audit events to retrieve. Default: 7.

.PARAMETER OutputPath
    Path for the CSV export. Default: C:\Temp\WDAC-Status-<timestamp>.csv

.PARAMETER Credential
    Optional PSCredential for remote connections.

.EXAMPLE
    # Run locally
    .\Get-WDACPolicyStatus.ps1

.EXAMPLE
    # Run against remote devices
    .\Get-WDACPolicyStatus.ps1 -ComputerName PC001,PC002,PC003 -DaysBack 14

.EXAMPLE
    # Export to a specific path
    .\Get-WDACPolicyStatus.ps1 -OutputPath "C:\Reports\WDAC-Audit.csv"

.NOTES
    Requires: Windows 10/11 or Server 2016+
    Run As: Local admin for local; domain admin or equivalent for remote
    Remote: WinRM must be enabled on target devices
    Safe: Read-only — no policy changes made
    WDAC Policy GUIDs stored in: HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline)]
    [string[]]$ComputerName = @($env:COMPUTERNAME),

    [int]$DaysBack = 7,

    [string]$OutputPath = "C:\Temp\WDAC-Status-$(Get-Date -Format 'yyyyMMdd-HHmm').csv",

    [PSCredential]$Credential
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

function Get-WDACStatusLocal {
    param([string]$Computer)

    $result = [PSCustomObject]@{
        ComputerName        = $Computer
        CollectedAt         = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        SecureBootEnabled   = "Unknown"
        HVCIEnabled         = "Unknown"
        ActivePolicies      = "None"
        PolicyGUIDs         = "None"
        EnforcementModes    = "Unknown"
        BlockEventsCount    = 0
        AuditEventsCount    = 0
        RecentBlocks        = "None"
        MDMPolicyCIStatus   = "Unknown"
        Errors              = ""
    }

    try {
        # --- Secure Boot ---
        $secureBoot = Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
        $result.SecureBootEnabled = if ($secureBoot) { "Enabled" } else { "Disabled/Not Supported" }
    } catch {
        $result.SecureBootEnabled = "Not Supported"
    }

    try {
        # --- HVCI (Hypervisor-Protected Code Integrity) ---
        $hvciKey = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"
        if (Test-Path $hvciKey) {
            $hvciEnabled = (Get-ItemProperty $hvciKey -ErrorAction SilentlyContinue).Enabled
            $result.HVCIEnabled = if ($hvciEnabled -eq 1) { "Enabled" } else { "Disabled" }
        } else {
            $result.HVCIEnabled = "Not Configured"
        }
    } catch {
        $result.HVCIEnabled = "Error reading HVCI key"
    }

    try {
        # --- Active WDAC Policies ---
        $policyBase = "HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy"
        $policyActiveKey = "HKLM:\SYSTEM\CurrentControlSet\Control\CI\ActivePolicies"

        $policyGuids = @()
        $enforceModes = @()
        $policyNames = @()

        # Method 1: Active policies key (Windows 11 / Server 2022+)
        if (Test-Path $policyActiveKey) {
            $activePolicies = Get-ChildItem $policyActiveKey -ErrorAction SilentlyContinue
            foreach ($policy in $activePolicies) {
                $guid = $policy.PSChildName
                $policyGuids += $guid

                $policyProps = Get-ItemProperty $policy.PSPath -ErrorAction SilentlyContinue
                $friendlyName = if ($policyProps.FriendlyName) { $policyProps.FriendlyName } else { "Unknown" }
                $enforceMode = switch ($policyProps.PolicyOptions) {
                    0       { "Unsigned/Enforce" }
                    1       { "Audit" }
                    4       { "Unsigned/Audit" }
                    default { "Mode:$($policyProps.PolicyOptions)" }
                }
                $policyNames += "$friendlyName"
                $enforceModes += $enforceMode
            }
        }

        # Method 2: CI\Policy key (older Windows 10 builds)
        elseif (Test-Path $policyBase) {
            $policyFile = (Get-ItemProperty $policyBase -ErrorAction SilentlyContinue).PolicyFilePath
            if ($policyFile) { $policyNames += "Legacy policy: $policyFile" }
            $enforceModes += "Check CI\Policy registry"
        }
        else {
            $policyNames += "No WDAC policy registry keys found"
        }

        $result.ActivePolicies  = if ($policyNames.Count) { $policyNames -join " | " } else { "None detected" }
        $result.PolicyGUIDs     = if ($policyGuids.Count) { $policyGuids -join " | " } else { "N/A" }
        $result.EnforcementModes = if ($enforceModes.Count) { $enforceModes -join " | " } else { "Unknown" }

    } catch {
        $result.Errors += "Policy read error: $($_.Exception.Message); "
    }

    try {
        # --- Code Integrity Event Log ---
        $cutoff = (Get-Date).AddDays(-$DaysBack)
        $logName = "Microsoft-Windows-CodeIntegrity/Operational"

        # 3076 = Audit mode block (would have blocked)
        # 3077 = Enforce mode block (actually blocked)
        # 3089 = Signing info (informational)

        $allEvents = Get-WinEvent -LogName $logName -ErrorAction SilentlyContinue |
            Where-Object { $_.TimeCreated -ge $cutoff -and $_.Id -in @(3076, 3077) }

        $blockEvents  = $allEvents | Where-Object { $_.Id -eq 3077 }
        $auditEvents  = $allEvents | Where-Object { $_.Id -eq 3076 }

        $result.BlockEventsCount = ($blockEvents | Measure-Object).Count
        $result.AuditEventsCount = ($auditEvents | Measure-Object).Count

        # Summarise recent blocks (top 5)
        $recentBlocks = $allEvents | Sort-Object TimeCreated -Descending | Select-Object -First 5 |
            ForEach-Object {
                "$($_.TimeCreated.ToString('MM/dd HH:mm')) ID:$($_.Id) — $($_.Message -replace '[\r\n]+',' ' | Select-Object -First 1 -ExpandProperty $_)"
            }

        # Simpler extraction
        $recentBlocks = $allEvents | Sort-Object TimeCreated -Descending | Select-Object -First 5 |
            ForEach-Object {
                $msg = $_.Message -split "`n" | Select-Object -First 1
                "[$($_.Id)] $($_.TimeCreated.ToString('yyyy-MM-dd HH:mm')) — $msg"
            }

        $result.RecentBlocks = if ($recentBlocks) { $recentBlocks -join " ;; " } else { "None in last $DaysBack days" }

    } catch {
        $result.Errors += "Event log error: $($_.Exception.Message); "
    }

    try {
        # --- MDM WDAC policy state (if device is Intune-managed) ---
        $mdmKey = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\ApplicationManagement"
        if (Test-Path $mdmKey) {
            $appCtrlPolicy = (Get-ItemProperty $mdmKey -ErrorAction SilentlyContinue).ApplicationControl
            $result.MDMPolicyCIStatus = if ($appCtrlPolicy) { "MDM policy present: $appCtrlPolicy" } else { "No MDM ApplicationControl policy" }
        } else {
            $result.MDMPolicyCIStatus = "PolicyManager key not found (not MDM enrolled or key absent)"
        }
    } catch {
        $result.MDMPolicyCIStatus = "Error: $($_.Exception.Message)"
    }

    return $result
}

# ───────────────────────────────────────────────────────────────
# MAIN
# ───────────────────────────────────────────────────────────────

$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($computer in $ComputerName) {
    Write-Status "Checking WDAC status on: $computer" "INFO"

    if ($computer -eq $env:COMPUTERNAME) {
        # Local execution
        $res = Get-WDACStatusLocal -Computer $computer
    } else {
        # Remote execution
        try {
            $invokeParams = @{
                ComputerName = $computer
                ScriptBlock  = ${function:Get-WDACStatusLocal}
                ArgumentList = $computer
                ErrorAction  = "Stop"
            }
            if ($Credential) { $invokeParams.Credential = $Credential }

            $res = Invoke-Command @invokeParams
            $res.PSObject.Properties.Remove("PSComputerName")
            $res.PSObject.Properties.Remove("RunspaceId")
        } catch {
            Write-Status "Cannot connect to $computer — $($_.Exception.Message)" "ERROR"
            $res = [PSCustomObject]@{
                ComputerName        = $computer
                CollectedAt         = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                SecureBootEnabled   = "N/A (connection failed)"
                HVCIEnabled         = "N/A"
                ActivePolicies      = "N/A"
                PolicyGUIDs         = "N/A"
                EnforcementModes    = "N/A"
                BlockEventsCount    = 0
                AuditEventsCount    = 0
                RecentBlocks        = "N/A"
                MDMPolicyCIStatus   = "N/A"
                Errors              = "Connection failed: $($_.Exception.Message)"
            }
        }
    }

    $allResults.Add($res)

    # Console summary per device
    $modeFlag = if ($res.EnforcementModes -match "Audit") { "WARN" } elseif ($res.EnforcementModes -match "Enforce") { "OK" } else { "WARN" }
    Write-Status "  Secure Boot: $($res.SecureBootEnabled) | HVCI: $($res.HVCIEnabled)" "INFO"
    Write-Status "  Policies: $($res.ActivePolicies)" $modeFlag
    Write-Status "  Mode: $($res.EnforcementModes)" $modeFlag

    if ($res.BlockEventsCount -gt 0) {
        Write-Status "  ENFORCE blocks (last $DaysBack days): $($res.BlockEventsCount)" "WARN"
    }
    if ($res.AuditEventsCount -gt 0) {
        Write-Status "  AUDIT events (last $DaysBack days): $($res.AuditEventsCount)" "INFO"
    }
    if ($res.Errors) {
        Write-Status "  Errors: $($res.Errors)" "ERROR"
    }
}

# ─── Export ───
$outputDir = Split-Path $OutputPath
if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$allResults | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "Results exported to: $OutputPath" "OK"

# ─── Summary table ───
Write-Host "`n=== WDAC Status Summary ===" -ForegroundColor Cyan
$allResults | Format-Table ComputerName, SecureBootEnabled, HVCIEnabled, EnforcementModes, BlockEventsCount, AuditEventsCount -AutoSize
