<#
.SYNOPSIS
    Audits Attack Surface Reduction (ASR) rule configuration, effective state, and recent
    block/audit events across one or more devices.

.DESCRIPTION
    Queries the local device or remote devices for:
    - Configured ASR rule IDs and their action (Off/Block/Audit/Warn)
    - Policy source precedence check (Intune MDM vs GPO vs local Set-MpPreference)
    - Recent ASR events from Microsoft-Windows-Windows Defender/Operational
      (1121 = blocked, 1122 = audited, 1123 = Controlled Folder Access block)
    - Current ASR-only exclusions
    - Defender AV run mode (Active/Passive/EDR Block) since ASR behaviour depends on it

    Maps common rule GUIDs to friendly names so output doesn't require a lookup table.
    Exports results to CSV and prints a colour-coded console summary.

    Does NOT cover:
    - Controlled Folder Access allow-list management (separate preference set)
    - Exploit Protection / AppLocker / WDAC (different logs and CSPs — see their own scripts)
    - Pushing or changing Intune ASR policy — this script is read-only

.PARAMETER ComputerName
    One or more remote computer names. Defaults to the local machine if omitted.

.PARAMETER DaysBack
    Number of days of ASR event history to retrieve. Default: 7.

.PARAMETER OutputPath
    Path for the CSV export. Default: C:\Temp\ASR-Status-<timestamp>.csv

.PARAMETER Credential
    Optional PSCredential for remote connections.

.EXAMPLE
    .\Get-ASRRuleStatus.ps1

.EXAMPLE
    .\Get-ASRRuleStatus.ps1 -ComputerName PC001,PC002 -DaysBack 14

.EXAMPLE
    .\Get-ASRRuleStatus.ps1 -OutputPath "C:\Reports\ASR-Audit.csv"

.NOTES
    Requires: Windows 10 1709+/Windows 11, Defender AV, MDE P1/P2 or M365 E3/E5 for full rule set
    Run As: Local admin for local; equivalent rights for remote (WinRM required)
    Safe: Read-only — no policy or exclusion changes made
    Cross-references: Security/Defender/ASR-Rules-B.md (Fix 1-5) and ASR-Rules-A.md
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline)]
    [string[]]$ComputerName = @($env:COMPUTERNAME),

    [int]$DaysBack = 7,

    [string]$OutputPath = "C:\Temp\ASR-Status-$(Get-Date -Format 'yyyyMMdd-HHmm').csv",

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

# Rule GUID -> friendly name (per MS Docs ASR rules reference)
$script:RuleNameMap = @{
    "d4f940ab-401b-4efc-aadc-ad5f3c50688a" = "Block Office apps from creating child processes"
    "3b576869-a4ec-4529-8536-b80a7769e899" = "Block Office apps from creating executable content"
    "75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84" = "Block Office apps from injecting code into other processes"
    "be9ba2d9-53ea-4cdc-84e5-9b1eeee46550" = "Block executable content from email/webmail"
    "b2b3f03d-6a65-4f7b-a9c7-1c7ef74a9ba4" = "Block untrusted/unsigned processes from USB"
    "92e97fa1-2edf-4476-bdd6-9dd0b4dddc7b" = "Block Win32 API calls from Office macros"
    "5beb7efe-fd9a-4556-801d-275e5ffc04cc" = "Block execution of potentially obfuscated scripts"
    "e6db77e5-3df2-4cf1-b95a-636979351e5b" = "Block persistence through WMI event subscription"
    "9e6c4e1f-7d60-472f-ba1a-a39ef669e4b3" = "Block credential stealing from LSASS"
    "d3e037e1-3eb8-44c8-a917-57927947596d" = "Block JavaScript/VBScript from launching downloaded content"
    "26190899-1602-49e8-8b27-eb1d0a1ce869" = "Block Office communication apps from creating child processes"
    "7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c" = "Block Adobe Reader from creating child processes"
    "56a863a9-875e-4185-98a7-b882c64b5ce5" = "Block abuse of exploited vulnerable signed drivers"
}

function Get-ASRStatusLocal {
    param([string]$Computer)

    $result = [PSCustomObject]@{
        ComputerName     = $Computer
        CollectedAt      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        AVRunMode        = "Unknown"
        RealTimeProtOn   = "Unknown"
        RuleCount        = 0
        RulesSummary     = "None"
        PolicySource     = "Unknown"
        ExclusionCount   = 0
        Exclusions       = "None"
        BlockEvents1121  = 0
        AuditEvents1122  = 0
        CFAEvents1123    = 0
        RecentBlocks     = "None"
        Errors           = ""
    }

    try {
        $mpStatus = Get-MpComputerStatus -ErrorAction Stop
        $result.RealTimeProtOn = $mpStatus.RealTimeProtectionEnabled
        $result.AVRunMode = if ($mpStatus.AMRunningMode) { $mpStatus.AMRunningMode } else { "Active" }
    } catch {
        $result.Errors += "Get-MpComputerStatus failed: $($_.Exception.Message); "
    }

    try {
        $pref = Get-MpPreference -ErrorAction Stop
        $ids    = $pref.AttackSurfaceReductionRules_Ids
        $states = $pref.AttackSurfaceReductionRules_Actions

        if ($ids -and $ids.Count -gt 0) {
            $result.RuleCount = $ids.Count
            $summary = for ($i = 0; $i -lt $ids.Count; $i++) {
                $stateName = switch ($states[$i]) { 0 {"Off"} 1 {"Block"} 2 {"Audit"} 6 {"Warn"} default {"Unknown($($states[$i]))"} }
                $friendly = if ($script:RuleNameMap.ContainsKey($ids[$i])) { $script:RuleNameMap[$ids[$i]] } else { $ids[$i] }
                "$friendly = $stateName"
            }
            $result.RulesSummary = $summary -join " | "
        } else {
            $result.RulesSummary = "No ASR rules configured"
        }

        $exclusions = $pref.AttackSurfaceReductionOnlyExclusions
        $result.ExclusionCount = if ($exclusions) { $exclusions.Count } else { 0 }
        $result.Exclusions = if ($exclusions) { $exclusions -join " | " } else { "None" }

    } catch {
        $result.Errors += "Get-MpPreference failed: $($_.Exception.Message); "
    }

    try {
        # Precedence check: MDM wins over GPO wins over local
        $mdmPath = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Defender"
        $gpoPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Windows Defender Exploit Guard\ASR\Rules"

        $mdmHasASR = (Test-Path $mdmPath) -and ((Get-ItemProperty $mdmPath -EA SilentlyContinue).PSObject.Properties.Name -match "ASR")
        $gpoHasASR = Test-Path $gpoPath

        if ($mdmHasASR) {
            $result.PolicySource = "Intune MDM (authoritative)"
        } elseif ($gpoHasASR) {
            $result.PolicySource = "GPO"
        } else {
            $result.PolicySource = "Local / Not managed"
        }
    } catch {
        $result.Errors += "Policy source check failed: $($_.Exception.Message); "
    }

    try {
        $cutoff = (Get-Date).AddDays(-$DaysBack)
        $events = Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -ErrorAction SilentlyContinue |
            Where-Object { $_.TimeCreated -ge $cutoff -and $_.Id -in @(1121, 1122, 1123) }

        $result.BlockEvents1121 = ($events | Where-Object Id -eq 1121 | Measure-Object).Count
        $result.AuditEvents1122 = ($events | Where-Object Id -eq 1122 | Measure-Object).Count
        $result.CFAEvents1123   = ($events | Where-Object Id -eq 1123 | Measure-Object).Count

        $recent = $events | Sort-Object TimeCreated -Descending | Select-Object -First 5 |
            ForEach-Object {
                $process = $_.Properties[5].Value
                $ruleId  = if ($_.Properties.Count -gt 7) { $_.Properties[7].Value } else { "N/A" }
                "[$($_.Id)] $($_.TimeCreated.ToString('yyyy-MM-dd HH:mm')) Process=$process Rule=$ruleId"
            }
        $result.RecentBlocks = if ($recent) { $recent -join " ;; " } else { "None in last $DaysBack days" }

    } catch {
        $result.Errors += "Event log read failed: $($_.Exception.Message); "
    }

    return $result
}

# ───────────────────────────────────────────────────────────────
# MAIN
# ───────────────────────────────────────────────────────────────

$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($computer in $ComputerName) {
    Write-Status "Checking ASR status on: $computer" "INFO"

    if ($computer -eq $env:COMPUTERNAME) {
        $res = Get-ASRStatusLocal -Computer $computer
    } else {
        try {
            $invokeParams = @{
                ComputerName = $computer
                ScriptBlock  = ${function:Get-ASRStatusLocal}
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
                ComputerName    = $computer
                CollectedAt     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                AVRunMode       = "N/A"
                RealTimeProtOn  = "N/A"
                RuleCount       = 0
                RulesSummary    = "N/A"
                PolicySource    = "N/A"
                ExclusionCount  = 0
                Exclusions      = "N/A"
                BlockEvents1121 = 0
                AuditEvents1122 = 0
                CFAEvents1123   = 0
                RecentBlocks    = "N/A"
                Errors          = "Connection failed: $($_.Exception.Message)"
            }
        }
    }

    $allResults.Add($res)

    Write-Status "  AV Mode: $($res.AVRunMode) | Real-Time: $($res.RealTimeProtOn) | Policy Source: $($res.PolicySource)" "INFO"
    Write-Status "  Rules configured: $($res.RuleCount) | Exclusions: $($res.ExclusionCount)" "INFO"

    if ($res.BlockEvents1121 -gt 0) {
        Write-Status "  Block events (ID 1121) in last $DaysBack days: $($res.BlockEvents1121)" "WARN"
    }
    if ($res.CFAEvents1123 -gt 0) {
        Write-Status "  Controlled Folder Access blocks (ID 1123): $($res.CFAEvents1123)" "WARN"
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

Write-Host "`n=== ASR Rule Status Summary ===" -ForegroundColor Cyan
$allResults | Format-Table ComputerName, AVRunMode, PolicySource, RuleCount, ExclusionCount, BlockEvents1121, AuditEvents1122 -AutoSize
