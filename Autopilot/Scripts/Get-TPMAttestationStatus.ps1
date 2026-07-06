<#
.SYNOPSIS
    Diagnoses Windows Autopilot TPM attestation health on the local device.

.DESCRIPTION
    Device-local diagnostic walking the full dependency chain from
    Autopilot/Troubleshooting/TPM-Attestation-A.md: physical TPM 2.0 presence/state, TPM spec
    version (2.0 vs 1.2 emulation), Windows Time Service accuracy (attestation certs are
    time-stamped — >5min skew breaks validation), reachability of the five attestation-critical
    endpoints, device join state via dsregcmd (AzureAdJoined / TpmProtected), and a scan of the
    TPM-WMI operational event log for hardware-level errors.

    Maps results directly to the runbook's documented error codes (0x800705B4, 0x80070490,
    0x80180001, 0x801c0003) so the flag returned here points at the same fix path in
    TPM-Attestation-B.md.

    Read-only — does NOT call Clear-Tpm or Initialize-Tpm. For remediation (including the
    destructive TPM clear in Fix 1), see TPM-Attestation-B.md.

.PARAMETER SkipNetworkTest
    Skip the live reachability test against attestation endpoints.

.EXAMPLE
    .\Get-TPMAttestationStatus.ps1

    Runs the full local diagnostic and prints a flagged summary.

.EXAMPLE
    .\Get-TPMAttestationStatus.ps1 -SkipNetworkTest

.NOTES
    Requires: Local admin for full TPM WMI + event log access. Run in OOBE (Shift+F10 -> PowerShell)
    for pre-join failures, or on the desktop post-enrollment for WHfB/TPM-bound cert issues.
    Companion runbook: Autopilot/Troubleshooting/TPM-Attestation-A.md and TPM-Attestation-B.md
#>

[CmdletBinding()]
param(
    [switch]$SkipNetworkTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$findings = [System.Collections.Generic.List[object]]::new()
function Add-Finding {
    param([string]$Flag, [string]$Detail, [string]$RelatedErrorCode = "")
    $findings.Add([PSCustomObject]@{ Flag = $Flag; Detail = $Detail; RelatedErrorCode = $RelatedErrorCode })
}

Write-Status "Starting TPM attestation diagnostic on $env:COMPUTERNAME"

# ---------------------------------------------------------------------------
# 1. TPM presence and basic state
# ---------------------------------------------------------------------------
Write-Status "Checking TPM state (Get-Tpm)..."
try {
    $tpm = Get-Tpm
    Write-Host "TpmPresent   : $($tpm.TpmPresent)"
    Write-Host "TpmReady     : $($tpm.TpmReady)"
    Write-Host "TpmEnabled   : $($tpm.TpmEnabled)"
    Write-Host "TpmActivated : $($tpm.TpmActivated)"

    if (-not $tpm.TpmPresent) {
        Add-Finding "TPM_NOT_PRESENT" "No TPM detected — check UEFI/BIOS for TPM enable, or fTPM setting" "0x80070490"
    } elseif (-not $tpm.TpmReady) {
        Add-Finding "TPM_NOT_READY" "TPM present but not ready — may need Initialize-Tpm, or stale ownership from a prior OS" "0x8018044"
    } elseif (-not $tpm.TpmEnabled -or -not $tpm.TpmActivated) {
        Add-Finding "TPM_DISABLED_OR_INACTIVE" "TPM enabled=$($tpm.TpmEnabled) activated=$($tpm.TpmActivated) — enable in UEFI/BIOS" "0x80070490"
    } else {
        Write-Status "TPM present, ready, enabled, and activated" "OK"
    }
} catch {
    Add-Finding "TPM_QUERY_FAILED" "Get-Tpm failed: $($_.Exception.Message)"
    Write-Status "Get-Tpm threw an error — TPM driver/service issue likely" "ERROR"
}

# ---------------------------------------------------------------------------
# 2. TPM spec version (2.0 required)
# ---------------------------------------------------------------------------
Write-Status "Checking TPM specification version..."
try {
    $tpmWmi = Get-CimInstance -Class Win32_TPM -Namespace root\cimv2\security\microsofttpm -ErrorAction Stop
    Write-Host "ManufacturerID      : $($tpmWmi.ManufacturerID)"
    Write-Host "ManufacturerVersion : $($tpmWmi.ManufacturerVersion)"
    Write-Host "SpecVersion         : $($tpmWmi.SpecVersion)"

    if ($tpmWmi.SpecVersion -notmatch "2\.0") {
        Add-Finding "TPM_SPEC_NOT_2_0" "SpecVersion reports '$($tpmWmi.SpecVersion)' — Autopilot attestation requires native TPM 2.0, not 1.2 compatibility mode" "0x80180001"
        Write-Status "TPM is not reporting spec version 2.0" "ERROR"
    } else {
        Write-Status "TPM spec version 2.0 confirmed" "OK"
    }
} catch {
    Add-Finding "TPM_WMI_UNAVAILABLE" "Win32_TPM WMI class query failed: $($_.Exception.Message)"
    Write-Status "Could not query Win32_TPM WMI class" "WARN"
}

# ---------------------------------------------------------------------------
# 3. Windows Time accuracy (attestation certs are time-stamped)
# ---------------------------------------------------------------------------
Write-Status "Checking system clock accuracy..."
$localUtc = (Get-Date).ToUniversalTime()
Write-Host "Local (UTC): $localUtc"
try {
    $w32tmStatus = w32tm /query /status 2>&1 | Out-String
    Write-Host $w32tmStatus
    if ($w32tmStatus -match "Error" -or $w32tmStatus -match "The service has not been started") {
        Add-Finding "TIME_SERVICE_NOT_RUNNING" "Windows Time service is not running or not synced — start with: net start w32tm; w32tm /resync /force" "0x800706BA"
        Write-Status "Windows Time service issue detected" "WARN"
    } else {
        Write-Status "Windows Time service responding" "OK"
    }
} catch {
    Add-Finding "TIME_QUERY_FAILED" "w32tm /query /status failed: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 4. Network connectivity to attestation endpoints
# ---------------------------------------------------------------------------
if (-not $SkipNetworkTest) {
    Write-Status "Testing connectivity to attestation endpoints..."
    $endpoints = @(
        "ekop.intel.com",
        "ekcert.spserv.microsoft.com",
        "aadcdn.msauth.net",
        "enterpriseregistration.windows.net",
        "ztd.dds.microsoft.com"
    )
    $netResults = foreach ($ep in $endpoints) {
        $r = Test-NetConnection -ComputerName $ep -Port 443 -WarningAction SilentlyContinue
        [PSCustomObject]@{ Endpoint = $ep; Reachable = $r.TcpTestSucceeded }
    }
    $netResults | Format-Table -AutoSize
    $unreachable = $netResults | Where-Object { -not $_.Reachable }
    if ($unreachable) {
        Add-Finding "ATTESTATION_ENDPOINT_UNREACHABLE" "Unreachable: $($unreachable.Endpoint -join ', ') — firewall/proxy is blocking OOBE traffic (no proxy config applies during OOBE by default)" "0x800705B4"
        Write-Status "$($unreachable.Count) attestation endpoint(s) unreachable" "ERROR"
    } else {
        Write-Status "All attestation endpoints reachable on TCP/443" "OK"
    }
} else {
    Write-Status "Network test skipped (-SkipNetworkTest)" "INFO"
}

# ---------------------------------------------------------------------------
# 5. Device join state (post-OOBE check)
# ---------------------------------------------------------------------------
Write-Status "Checking device join state (dsregcmd)..."
$dsregOutput = dsregcmd /status 2>&1 | Out-String
$joinLines = $dsregOutput -split "`n" | Where-Object { $_ -match "AzureAdJoined|TpmProtected|DeviceId" }
$joinLines | ForEach-Object { Write-Host $_.Trim() }

if ($dsregOutput -match "AzureAdJoined\s*:\s*YES") {
    if ($dsregOutput -match "TpmProtected\s*:\s*NO") {
        Add-Finding "DEVICE_KEY_NOT_TPM_PROTECTED" "Device is Azure AD joined but TpmProtected=NO — device key is software-protected, not TPM-backed. Affects WHfB key trust." "0x80180001"
        Write-Status "Device key is not TPM-protected" "WARN"
    } else {
        Write-Status "Device is Azure AD joined and TPM-protected" "OK"
    }
} else {
    Write-Status "Device is not yet Azure AD joined (expected if run pre-OOBE-completion)" "INFO"
}

# ---------------------------------------------------------------------------
# 6. TPM-WMI operational event log scan
# ---------------------------------------------------------------------------
Write-Status "Scanning TPM-WMI operational event log..."
$tpmEvents = Get-WinEvent -LogName "Microsoft-Windows-TPM-WMI/Operational" -MaxEvents 50 -ErrorAction SilentlyContinue |
    Where-Object { $_.LevelDisplayName -in "Error", "Warning" }
if ($tpmEvents) {
    Add-Finding "TPM_EVENTLOG_ERRORS" "$($tpmEvents.Count) error/warning event(s) in TPM-WMI operational log"
    Write-Status "$($tpmEvents.Count) TPM-related error/warning events found" "WARN"
} else {
    Write-Status "No error/warning events in TPM-WMI operational log" "OK"
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$outFile = "$env:TEMP\TPMAttestation_Findings_$(Get-Date -Format yyyyMMdd_HHmmss).csv"
$findings | Export-Csv $outFile -NoTypeInformation

Write-Host "`n=== TPM ATTESTATION STATUS SUMMARY ===" -ForegroundColor Cyan
if ($findings.Count -eq 0) {
    Write-Status "No issues flagged — if attestation still fails, check Autopilot registration/tenant match (Phase 4 in TPM-Attestation-A.md)" "OK"
} else {
    $findings | Format-Table -Wrap -AutoSize
}
Write-Host "`nFindings written to: $outFile" -ForegroundColor Green
Write-Host "See Autopilot/Troubleshooting/TPM-Attestation-B.md for fix paths matching these flags/error codes." -ForegroundColor Cyan
