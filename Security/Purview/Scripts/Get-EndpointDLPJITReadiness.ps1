<#
.SYNOPSIS
    Read-only readiness and policy-prerequisite audit for Microsoft Purview Endpoint DLP
    just-in-time (JIT) protection.

.DESCRIPTION
    JIT protection requires a Defender antimalware client version floor of 4.18.23080
    (4.18.25080+ for the improved in-progress/evaluation-complete toast UX) and depends
    entirely on an existing, active Endpoint DLP policy with a Block or Block-with-override
    rule — JIT has no independent detection logic of its own.

    This script does NOT enable, disable, or modify JIT settings, Endpoint DLP policies, or
    any exclusion list — JIT's own enable/scope/fallback/fine-tuning settings live only in
    the Purview portal (Settings > Data Loss Prevention > Just-in-time protection) and have
    no documented cmdlet surface as of this writing.

    It performs two READ-ONLY checks:
      1. Whether at least one active Endpoint DLP policy has a Block/Block-with-override
         rule (the prerequisite JIT depends on).
      2. A local, single-device antimalware client version check against the two documented
         JIT version floors (run this on/against the device in question — it does not
         perform a fleet-wide Advanced Hunting query, which requires the Defender/Security
         portal instead).

.PARAMETER OutputPath
    Directory to write CSV exports to. Defaults to the current directory.

.PARAMETER ComputerName
    Optional remote computer name to check the antimalware client version on. Defaults to
    the local computer. Requires WinRM/remoting access to the target.

.EXAMPLE
    .\Get-EndpointDLPJITReadiness.ps1 -OutputPath C:\Audits

.EXAMPLE
    .\Get-EndpointDLPJITReadiness.ps1 -ComputerName WKS-042 -OutputPath C:\Audits

.NOTES
    Requires: Connect-IPPSSession (Security & Compliance PowerShell) for the policy check.
    The antimalware-client-version check requires local admin rights on the target machine
    (reads via Get-MpComputerStatus, part of the Defender PowerShell module).
    Safe/read-only: issues no writes, changes no JIT settings, modifies no DLP policy.
    Does not and cannot confirm the live JIT enable/scope/fallback state in the Purview
    portal — that has no cmdlet surface and must be checked manually.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = ".",
    [string]$ComputerName = $env:COMPUTERNAME
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Status "Starting Endpoint DLP JIT protection readiness audit" "INFO"

# --- Version floors, per Microsoft Learn (endpoint-dlp-get-started-jit) ---
$MinimumJitVersion = [version]"4.18.23080"
$LatestUxVersion = [version]"4.18.25080"

# --- Step 1: Underlying Block-capable Endpoint DLP policy check ---
Write-Status "Checking for active Endpoint DLP policies with Block/Block-with-override rules (JIT's own prerequisite)..." "INFO"
$policyCheckOk = $true
try {
    $endpointPolicies = Get-DlpCompliancePolicy | Where-Object { $_.Workload -match "Endpoint" -and $_.Enabled -eq $true }
    $endpointPolicies | Select-Object Name, Enabled, Mode, Workload |
        Export-Csv (Join-Path $OutputPath "EndpointDlpPolicies.csv") -NoTypeInformation

    $blockRules = Get-DlpComplianceRule | Where-Object {
        ($_.BlockAccess -eq $true -or $_.BlockAccessScope) -and
        $_.ParentPolicyName -in $endpointPolicies.Name
    }
    $blockRules | Select-Object Name, ParentPolicyName, BlockAccess, BlockAccessScope, Disabled |
        Export-Csv (Join-Path $OutputPath "EndpointDlpBlockRules.csv") -NoTypeInformation

    if ($blockRules.Count -eq 0) {
        Write-Status "No active Endpoint DLP Block/Block-with-override rules found. JIT has nothing to enforce ahead of, even if JIT itself is enabled in the portal." "WARN"
        $policyCheckOk = $false
    }
    else {
        Write-Status "Found $($blockRules.Count) active Block/Block-with-override rule(s) across $($endpointPolicies.Count) enabled Endpoint DLP policy(ies)." "OK"
    }
}
catch {
    Write-Status "Could not query DLP policies/rules. Run Connect-IPPSSession first. Error: $($_.Exception.Message)" "ERROR"
    $policyCheckOk = $false
}

# --- Step 2: Antimalware client version check (local or remote) ---
Write-Status "Checking Defender antimalware client version on '$ComputerName'..." "INFO"
$versionResult = [PSCustomObject]@{
    ComputerName        = $ComputerName
    AntiMalwareVersion  = $null
    MeetsMinimumFloor   = $false
    MeetsLatestUxFloor  = $false
    CheckSucceeded      = $false
}
try {
    if ($ComputerName -eq $env:COMPUTERNAME) {
        $mpStatus = Get-MpComputerStatus
    }
    else {
        $mpStatus = Invoke-Command -ComputerName $ComputerName -ScriptBlock { Get-MpComputerStatus }
    }
    $rawVersion = $mpStatus.AMProductVersion
    $parsedVersion = [version]$rawVersion
    $versionResult.AntiMalwareVersion = $rawVersion
    $versionResult.MeetsMinimumFloor = ($parsedVersion -ge $MinimumJitVersion)
    $versionResult.MeetsLatestUxFloor = ($parsedVersion -ge $LatestUxVersion)
    $versionResult.CheckSucceeded = $true

    if (-not $versionResult.MeetsMinimumFloor) {
        Write-Status "Antimalware client $rawVersion is BELOW the JIT minimum floor ($MinimumJitVersion). JIT is inactive on this device regardless of portal configuration." "WARN"
    }
    elseif (-not $versionResult.MeetsLatestUxFloor) {
        Write-Status "Antimalware client $rawVersion meets the JIT minimum floor but not the improved-UX floor ($LatestUxVersion). JIT functions but without in-progress/evaluation-complete toast notifications." "WARN"
    }
    else {
        Write-Status "Antimalware client $rawVersion meets both the JIT minimum and improved-UX floors." "OK"
    }
}
catch {
    Write-Status "Could not read antimalware client version on '$ComputerName': $($_.Exception.Message)" "WARN"
    Write-Status "For a fleet-wide check, use the Advanced Hunting query documented in EndpointDLP-JIT-A.md / -B.md against DeviceRegistryEvents (MsMpEng.exe) in the Defender/Security portal instead." "INFO"
}
$versionResult | Export-Csv (Join-Path $OutputPath "JitAntimalwareVersionCheck.csv") -NoTypeInformation

# --- Summary ---
Write-Host ""
Write-Status "=== Summary ===" "INFO"
if ($policyCheckOk) {
    Write-Status "Prerequisite Endpoint DLP Block-capable policy: present" "OK"
}
else {
    Write-Status "Prerequisite Endpoint DLP Block-capable policy: MISSING or could not be confirmed" "WARN"
}
if ($versionResult.CheckSucceeded -and $versionResult.MeetsMinimumFloor) {
    Write-Status "Antimalware client version floor: met on $ComputerName" "OK"
}
else {
    Write-Status "Antimalware client version floor: NOT confirmed met on $ComputerName" "WARN"
}
Write-Status "This script cannot read JIT's own enable/scope/fallback-action/fine-tuning settings -- those exist only in the Purview portal (Settings > Data Loss Prevention > Just-in-time protection) with no documented cmdlet surface. Confirm those manually." "WARN"
Write-Status "Evidence exported to $OutputPath" "OK"
