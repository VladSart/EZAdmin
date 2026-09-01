<#
.SYNOPSIS
    Audits a Windows 10 device's Extended Security Updates (ESU) eligibility and licensing
    state — build/version, prerequisite KBs, activation endpoint reachability, current
    license status, and the free-ESU Windows 365 endpoint flag — in a single read-only pass.

.DESCRIPTION
    Since October 15, 2025, Microsoft no longer provides centralized, tenant-wide ESU
    enrollment/reporting through its own admin tooling — organizations (and MSPs managing
    them) must build and maintain their own device-level ESU tracking. This script automates
    the client-side Validation Steps from ESU-A.md into one pass so an engineer, Intune
    Remediation, or RMM job can determine at a glance whether a given Windows 10 device is:
      - eligible for ESU at all (build/version, prerequisite KBs),
      - able to reach the activation infrastructure it will need,
      - currently licensed for ESU (via a read-only slmgr.vbs /dlv query), and
      - configured for the free Windows 365-connected-endpoint ESU entitlement, if applicable.

    It does NOT install a MAK, run slmgr.vbs /ipk or /ato, or make any other activation or
    configuration change — this is strictly an audit/reporting script. For remediation (MAK
    install/activation, endpoint allowlisting, Intune policy deployment), see the Common Fix
    Paths in ESU-B.md and the Remediation Playbooks in ESU-A.md.

.PARAMETER OutputPath
    Folder to write the CSV/report output to. Defaults to C:\Temp\ESU-Diagnostics.

.PARAMETER SkipNetworkTest
    Switch. Skips the activation-endpoint reachability sweep (useful for a quick local-only
    pass, or on a device with no expected network path where the test would just add delay).

.EXAMPLE
    .\Get-ESUActivationStatus.ps1

.EXAMPLE
    .\Get-ESUActivationStatus.ps1 -OutputPath "D:\Reports\ESU" -SkipNetworkTest

.NOTES
    Run from an elevated PowerShell session on the target Windows 10 device.
    Requires: local admin (to query HotFix inventory, HKLM registry, and run slmgr.vbs /dlv).
    Safe/Read-only: makes no licensing, activation, or configuration changes.
    Suitable for deployment as an Intune Remediation "detection" script or a scheduled RMM job
    across a Windows 10 fleet to build the fleet-wide ESU coverage inventory Microsoft's own
    admin center no longer provides.
#>

[CmdletBinding()]
param(
    [string]$OutputPath = "C:\Temp\ESU-Diagnostics",
    [switch]$SkipNetworkTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$findings = [System.Collections.Generic.List[object]]::new()

function Add-Finding {
    param([string]$Check, [string]$Result, [string]$Status)
    $findings.Add([PSCustomObject]@{ Check = $Check; Result = $Result; Status = $Status })
}

# --- 1. Build / version eligibility ---
Write-Status "Checking Windows 10 build/version eligibility..."
try {
    $ci = Get-ComputerInfo -ErrorAction Stop
    $version = $ci.WindowsVersion
    $build = $ci.OsBuildNumber
    $domain = $ci.CsDomain
    if ($version -eq "22H2") {
        Add-Finding "Windows Version" "22H2 (build $build) — ESU-eligible" "OK"
    } else {
        Add-Finding "Windows Version" "$version (build $build) — NOT 22H2, not ESU-eligible until upgraded" "ERROR"
    }
    Add-Finding "Domain/Join Context" "$domain" "INFO"
} catch {
    Add-Finding "Windows Version" "Could not determine via Get-ComputerInfo: $($_.Exception.Message)" "ERROR"
}

# --- 2. Prerequisite KBs, in order ---
Write-Status "Checking prerequisite KBs (KB5066791 then KB5072653)..."
$prereqKBs = Get-HotFix -Id KB5066791, KB5072653 -ErrorAction SilentlyContinue
$kb1 = $prereqKBs | Where-Object { $_.HotFixID -eq "KB5066791" } | Select-Object -First 1
$kb2 = $prereqKBs | Where-Object { $_.HotFixID -eq "KB5072653" } | Select-Object -First 1

if (-not $kb1) {
    Add-Finding "KB5066791 (or later CU)" "Not found" "ERROR"
} else {
    Add-Finding "KB5066791" "Installed $($kb1.InstalledOn)" "OK"
}

if (-not $kb2) {
    Add-Finding "KB5072653 (ESU Licensing Prep Package)" "Not found" "ERROR"
} elseif ($kb1 -and $kb2.InstalledOn -lt $kb1.InstalledOn) {
    Add-Finding "KB5072653 install order" "Installed $($kb2.InstalledOn) — BEFORE KB5066791 ($($kb1.InstalledOn)); order requirement violated" "WARN"
} else {
    Add-Finding "KB5072653" "Installed $($kb2.InstalledOn)" "OK"
}

# --- 3. Current licensing status (read-only slmgr query) ---
Write-Status "Querying current licensing status (read-only, no changes made)..."
try {
    $slmgrPath = Join-Path $env:WINDIR "System32\slmgr.vbs"
    if (Test-Path $slmgrPath) {
        $dlvOutput = cscript //nologo $slmgrPath /dlv 2>&1 | Out-String
        $dlvOutput | Out-File (Join-Path $OutputPath "slmgr-dlv-$ts.txt")

        if ($dlvOutput -match "ESU") {
            $esuLicensed = $dlvOutput -match "ESU[\s\S]{0,300}?License Status:\s*Licensed"
            if ($esuLicensed) {
                Add-Finding "ESU License Status" "An ESU program entry was found with License Status: Licensed" "OK"
            } else {
                Add-Finding "ESU License Status" "ESU program entry found but NOT confirmed Licensed — review slmgr-dlv-$ts.txt" "WARN"
            }
        } else {
            Add-Finding "ESU License Status" "No ESU program entry found in current license detail — device not yet activated for ESU" "WARN"
        }
    } else {
        Add-Finding "ESU License Status" "slmgr.vbs not found at expected path — cannot query" "ERROR"
    }
} catch {
    Add-Finding "ESU License Status" "Query failed: $($_.Exception.Message)" "ERROR"
}

# --- 4. Activation endpoint reachability ---
if (-not $SkipNetworkTest) {
    Write-Status "Testing reachability to Microsoft ESU activation endpoints..."
    $esuEndpoints = @(
        "go.microsoft.com","login.live.com","crl.microsoft.com",
        "activation.sls.microsoft.com","validation.sls.microsoft.com",
        "activation-v2.sls.microsoft.com","validation-v2.sls.microsoft.com",
        "displaycatalog.mp.microsoft.com","licensing.mp.microsoft.com","purchase.mp.microsoft.com",
        "displaycatalog.md.mp.microsoft.com","licensing.md.mp.microsoft.com","purchase.md.mp.microsoft.com"
    )
    $endpointResults = foreach ($ep in $esuEndpoints) {
        try {
            $test = Test-NetConnection -ComputerName $ep -Port 443 -WarningAction SilentlyContinue -ErrorAction Stop
            [PSCustomObject]@{ Endpoint = $ep; Reachable = $test.TcpTestSucceeded }
        } catch {
            [PSCustomObject]@{ Endpoint = $ep; Reachable = $false }
        }
    }
    $endpointResults | Export-Csv (Join-Path $OutputPath "endpoint-reachability-$ts.csv") -NoTypeInformation
    $unreachable = $endpointResults | Where-Object { -not $_.Reachable }
    if ($unreachable) {
        Add-Finding "Activation Endpoint Reachability" "$($unreachable.Count) of $($esuEndpoints.Count) endpoint(s) unreachable — see endpoint-reachability-$ts.csv" "ERROR"
    } else {
        Add-Finding "Activation Endpoint Reachability" "All $($esuEndpoints.Count) endpoints reachable on TCP 443" "OK"
    }
} else {
    Add-Finding "Activation Endpoint Reachability" "Skipped (-SkipNetworkTest specified)" "INFO"
}

# --- 5. Free-ESU (Windows 365-connected endpoint) flag ---
Write-Status "Checking free-ESU Windows 365 endpoint subscription-check flag..."
try {
    $esuRegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform\ESU"
    $flag = Get-ItemProperty -Path $esuRegPath -Name EnableESUSubscriptionCheck -ErrorAction SilentlyContinue
    if ($null -eq $flag) {
        Add-Finding "Free-ESU (W365 endpoint) Flag" "EnableESUSubscriptionCheck not present — not configured for the free W365-connected-endpoint path (expected if this device uses the commercial MAK path instead)" "INFO"
    } elseif ($flag.EnableESUSubscriptionCheck -eq 1) {
        Add-Finding "Free-ESU (W365 endpoint) Flag" "EnableESUSubscriptionCheck = 1 (configured)" "OK"
    } else {
        Add-Finding "Free-ESU (W365 endpoint) Flag" "EnableESUSubscriptionCheck present but not set to 1 (value: $($flag.EnableESUSubscriptionCheck))" "WARN"
    }
} catch {
    Add-Finding "Free-ESU (W365 endpoint) Flag" "Query failed: $($_.Exception.Message)" "WARN"
}

# --- Summary ---
Write-Host ""
Write-Status "=== WINDOWS 10 ESU DIAGNOSTIC SUMMARY ===" "INFO"
$findings | Format-Table Check, Result, Status -AutoSize

$errorCount = ($findings | Where-Object { $_.Status -eq "ERROR" }).Count
$warnCount = ($findings | Where-Object { $_.Status -eq "WARN" }).Count

if ($errorCount -gt 0) {
    Write-Status "$errorCount critical finding(s) — see ESU-A.md Symptom -> Cause Map / Troubleshooting phases." "ERROR"
} elseif ($warnCount -gt 0) {
    Write-Status "$warnCount warning(s) — review before assuming this device is ESU-covered." "WARN"
} else {
    Write-Status "No issues found — device appears ESU-eligible and/or currently licensed." "OK"
}

$reportPath = Join-Path $OutputPath "ESU-Diagnostics-Summary-$ts.csv"
$findings | Export-Csv -Path $reportPath -NoTypeInformation
Write-Status "Full summary exported to: $reportPath" "OK"
