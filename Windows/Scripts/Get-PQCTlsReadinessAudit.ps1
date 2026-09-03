<#
.SYNOPSIS
    Audits local (or remote) machine readiness and current configuration state for hybrid
    post-quantum TLS 1.3 key exchange (ML-KEM groups).

.DESCRIPTION
    Companion script to Windows/Troubleshooting/PostQuantumTLS-B.md and -A.md.

    Runs in one pass everything the runbooks' triage and diagnosis steps ask for:
    - OS build eligibility (Windows 11 24H2/25H2 build 26100.33158+, or Windows Server 2025
      with the equivalent cumulative update) and KB5099536-or-later hotfix presence
    - Currently enabled TLS ECC/hybrid groups and their priority order (Get-TlsEccCurve)
    - Whether a Group Policy-managed ECC Curve Order is in effect (via gpresult) that may
      override local configuration on next refresh/reboot
    - Legacy FIPS mode state (none of the three ML-KEM hybrid groups are available under
      legacy FIPS mode as of this writing)

    Supports -ComputerName for a small set of remote machines via PowerShell remoting
    (WinRM must already be configured/reachable — this script does not configure it).

    Does NOT and CANNOT do:
    - Confirm the actually-negotiated TLS group for any specific live connection — that
      requires a packet capture (Wireshark/netsh trace) of the ClientHello/ServerHello
      key_share extension, which this script does not attempt to automate
    - Modify any configuration — fully read-only by design
    - Confirm peer/remote-endpoint hybrid PQC support for outbound connections this
      machine initiates — only local readiness and configuration state is in scope

.PARAMETER ComputerName
    One or more remote computer names to audit via PowerShell remoting. Omit for local-only.

.PARAMETER ExportPath
    Path for CSV export. Default: .\PQCTlsReadinessAudit-<timestamp>.csv

.EXAMPLE
    .\Get-PQCTlsReadinessAudit.ps1
    Audits the local machine's hybrid PQC TLS readiness and configuration state.

.EXAMPLE
    .\Get-PQCTlsReadinessAudit.ps1 -ComputerName SRV01,SRV02 -ExportPath C:\Temp\pqc-audit.csv
    Audits two remote machines via PowerShell remoting and exports combined results.

.NOTES
    Requires: Windows PowerShell 5.1+; TLS PowerShell module (built in on eligible builds)
    Run-as:   Administrator recommended (FIPS registry read and full gpresult detail need
              elevation; Get-TlsEccCurve itself does not require elevation)
    Safe:     Fully read-only. No policy changes, no reboot triggered.
    Tested on: Windows 11 24H2 (build 26100) and later, Windows Server 2025. Also safe to
               run on earlier/ineligible builds or Windows Server 2022 and prior — will
               simply report ineligibility and skip downstream hybrid-group checks.
#>

[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [string]$ExportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

if (-not $ExportPath) {
    $ExportPath = ".\PQCTlsReadinessAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
}

$MinBuild = 26100
$MinUBR   = 33158
$RequiredHotfix = "KB5099536"
$HybridGroups = @("x25519_mlkem768","secp256r1_mlkem768","secp384r1_mlkem1024")

$auditScript = {
    param($MinBuild, $MinUBR, $RequiredHotfix, $HybridGroups)

    $result = [PSCustomObject]@{
        ComputerName        = $env:COMPUTERNAME
        OSBuild             = $null
        UBR                 = $null
        Eligible            = $false
        HotfixPresent       = $false
        EnabledHybridGroups = ""
        AllEnabledGroups    = ""
        GPOManagedCurveOrder = $false
        FipsModeEnabled     = $false
        ReadyForHybridPQC   = $false
        Notes               = ""
        Timestamp           = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }

    try {
        $os = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction Stop
        $result.OSBuild = $os.CurrentBuild
        $result.UBR = $os.UBR
        $buildNum = [int]$os.CurrentBuild
        $ubrNum = [int]$os.UBR
        $result.Eligible = ($buildNum -gt $MinBuild) -or ($buildNum -eq $MinBuild -and $ubrNum -ge $MinUBR)
    } catch {
        $result.Notes += "Could not read OS build info. "
    }

    try {
        $hotfix = Get-HotFix -Id $RequiredHotfix -ErrorAction SilentlyContinue
        $result.HotfixPresent = [bool]$hotfix
    } catch {
        $result.Notes += "Get-HotFix check failed (may need elevation). "
    }

    try {
        if (Get-Command Get-TlsEccCurve -ErrorAction SilentlyContinue) {
            $curves = Get-TlsEccCurve -ErrorAction Stop
            $result.AllEnabledGroups = ($curves | Sort-Object Position | ForEach-Object { $_.Name }) -join ", "
            $enabledHybrid = $curves | Where-Object { $_.Name -in $HybridGroups }
            $result.EnabledHybridGroups = ($enabledHybrid | ForEach-Object { $_.Name }) -join ", "
        } else {
            $result.Notes += "Get-TlsEccCurve cmdlet not found on this build/PowerShell version. "
        }
    } catch {
        $result.Notes += "Get-TlsEccCurve failed: $($_.Exception.Message). "
    }

    try {
        $gpResult = gpresult /r /scope:computer 2>&1 | Out-String
        if ($gpResult -match "SSL Configuration") {
            $result.GPOManagedCurveOrder = $true
        }
    } catch {
        $result.Notes += "gpresult check failed. "
    }

    try {
        $fips = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\FipsAlgorithmPolicy" -Name Enabled -ErrorAction SilentlyContinue
        if ($fips -and $fips.Enabled -eq 1) { $result.FipsModeEnabled = $true }
    } catch {
        $result.Notes += "FIPS mode registry check failed. "
    }

    $result.ReadyForHybridPQC = $result.Eligible -and (-not $result.FipsModeEnabled) -and ($result.EnabledHybridGroups -ne "")

    if ($result.Eligible -and $result.EnabledHybridGroups -eq "") {
        $result.Notes += "Eligible but no hybrid group enabled (expected default state — nothing to fix unless PQC is desired here). "
    }
    if ($result.GPOManagedCurveOrder) {
        $result.Notes += "A GPO manages SSL Configuration Settings — confirm it includes the hybrid group strings before relying on local Enable-TlsEccCurve changes surviving a policy refresh. "
    }

    return $result
}

$allResults = New-Object System.Collections.Generic.List[Object]

if ($ComputerName) {
    foreach ($cn in $ComputerName) {
        Write-Status "Auditing $cn ..." "INFO"
        try {
            $r = Invoke-Command -ComputerName $cn -ScriptBlock $auditScript -ArgumentList $MinBuild, $MinUBR, $RequiredHotfix, $HybridGroups -ErrorAction Stop
            $allResults.Add($r)
        } catch {
            Write-Status "Failed to audit $cn : $($_.Exception.Message)" "ERROR"
        }
    }
} else {
    Write-Status "Auditing local machine ..." "INFO"
    $allResults.Add((& $auditScript $MinBuild $MinUBR $RequiredHotfix $HybridGroups))
}

$allResults | Export-Csv -Path $ExportPath -NoTypeInformation

Write-Host ""
foreach ($r in $allResults) {
    Write-Host "=== $($r.ComputerName) ===" -ForegroundColor Cyan
    Write-Status "Build: $($r.OSBuild).$($r.UBR)  Eligible: $($r.Eligible)  Hotfix $RequiredHotfix present: $($r.HotfixPresent)" $(if ($r.Eligible) {"OK"} else {"WARN"})
    Write-Status "Enabled hybrid groups: $(if ($r.EnabledHybridGroups) {$r.EnabledHybridGroups} else {'(none)'})" $(if ($r.EnabledHybridGroups) {"OK"} else {"WARN"})
    Write-Status "GPO-managed curve order detected: $($r.GPOManagedCurveOrder)" "INFO"
    Write-Status "FIPS mode enabled: $($r.FipsModeEnabled)" $(if ($r.FipsModeEnabled) {"WARN"} else {"OK"})
    Write-Status "Ready for hybrid PQC right now: $($r.ReadyForHybridPQC)" $(if ($r.ReadyForHybridPQC) {"OK"} else {"WARN"})
    if ($r.Notes) { Write-Status "Notes: $($r.Notes)" "INFO" }
    Write-Host ""
}

Write-Status "Full report: $ExportPath" "OK"
Write-Status "Reminder: this script cannot confirm the actually-negotiated group for any live connection, and cannot assess peer/remote-endpoint support. Enabling hybrid PQC on this machine alone does not guarantee it is used — the peer must independently support and enable a matching group. Use a packet capture for authoritative handshake-level proof." "INFO"
