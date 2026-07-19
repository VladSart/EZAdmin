<#
.SYNOPSIS
    Audits BitLocker Network Unlock readiness on a client or a WDS/Network Unlock server.

.DESCRIPTION
    Companion diagnostic to Windows/Troubleshooting/BitLocker/NetworkUnlock-A.md and -B.md.
    Auto-detects whether it's running on a client or on a server hosting the WDS role, and
    reports the relevant half of the dependency stack:

    CLIENT checks: baseline TPM+PIN protector present, FVE_NKP certificate delivered via GPO,
    Network (Certificate Based) protector actually created on the volume, native UEFI/Secure
    Boot mode (Legacy/CSM cannot support Network Unlock at all), and network adapter enumeration
    order (Network Unlock only ever tries the first-enumerated, DHCP-capable adapter).

    SERVER checks: WDS-Deployment and BitLocker-NetworkUnlock Windows features installed, WDSServer
    service running, active Network Unlock certificate thumbprint and expiry (NotAfter), and
    presence/contents of an optional bde-network-unlock.ini subnet policy file.

    This script is read-only / reporting only. It does not deploy certificates, modify Group
    Policy, or create/remove key protectors. Use the runbook's Remediation Playbooks for actual
    remediation steps.

.PARAMETER OutputPath
    Folder to write the CSV/summary report to. Default: $env:TEMP.

.PARAMETER Role
    Force the audit to run as 'Client', 'Server', or 'Auto' (default — detects based on whether
    the WDS-Deployment Windows feature is present).

.EXAMPLE
    .\Get-NetworkUnlockReadinessAudit.ps1
    Auto-detects role and runs the appropriate readiness checks.

.EXAMPLE
    .\Get-NetworkUnlockReadinessAudit.ps1 -Role Server -OutputPath C:\Temp\Evidence
    Forces server-side checks and writes the report to a custom folder.

.NOTES
    Requires: Run as Administrator (registry, WMI, and Windows Feature queries need elevation).
    Safe: Read-only. No configuration changes are made.
    Companion runbooks: Windows/Troubleshooting/BitLocker/NetworkUnlock-A.md (deep dive),
                         Windows/Troubleshooting/BitLocker/NetworkUnlock-B.md (hotfix triage).
#>
[CmdletBinding()]
param(
    [string]$OutputPath = $env:TEMP,
    [ValidateSet("Auto", "Client", "Server")]
    [string]$Role = "Auto"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Status "Not running as Administrator — Windows Feature, registry, and cert store checks may fail or return incomplete data." "WARN"
}

$results = [System.Collections.Generic.List[pscustomobject]]::new()
function Add-Result {
    param($Check, $Value, $Status)
    $results.Add([pscustomobject]@{ Check = $Check; Value = $Value; Status = $Status })
}

# ============================================================
# ROLE DETECTION
# ============================================================
$detectedRole = "Client"
try {
    $wdsFeature = Get-WindowsFeature -Name WDS-Deployment -ErrorAction SilentlyContinue
    if ($wdsFeature -and $wdsFeature.InstallState -eq "Installed") { $detectedRole = "Server" }
} catch {
    # Get-WindowsFeature only exists on Windows Server — absence implies client OS
    $detectedRole = "Client"
}

$effectiveRole = if ($Role -eq "Auto") { $detectedRole } else { $Role }
Write-Status "Running Network Unlock readiness audit as: $effectiveRole (detected: $detectedRole)" "INFO"

# ============================================================
# CLIENT-SIDE CHECKS
# ============================================================
if ($effectiveRole -eq "Client") {

    Write-Status "Checking baseline BitLocker key protectors..." "INFO"
    try {
        $vol = Get-BitLockerVolume -MountPoint "C:" -ErrorAction Stop
        $protectorTypes = $vol.KeyProtector | Select-Object -ExpandProperty KeyProtectorType
        $hasPin = $protectorTypes -contains "TpmPin"
        $hasNku = $protectorTypes -contains "TpmNetworkKey" -or ($vol.KeyProtector | Where-Object { $_.KeyProtectorType -like "*Certificate*" })
        Add-Result "TPM+PIN baseline protector present" $hasPin (if ($hasPin) { "OK" } else { "FAIL — Network Unlock has no PIN to bypass" })
        Add-Result "Network (Certificate Based) protector present" ([bool]$hasNku) (if ($hasNku) { "OK" } else { "WARN — see cert/reboot check below" })
        Add-Result "All key protector types on C:" ($protectorTypes -join ", ") "INFO"
    } catch {
        Add-Result "BitLocker volume query" "ERROR: $($_.Exception.Message)" "ERROR"
    }

    Write-Status "Checking FVE_NKP certificate delivery..." "INFO"
    $nkpPath = "HKLM:\Software\Policies\Microsoft\SystemCertificates\FVE_NKP\Certificates"
    if (Test-Path $nkpPath) {
        $certs = Get-ChildItem $nkpPath -ErrorAction SilentlyContinue
        if ($certs) {
            Add-Result "FVE_NKP certificate delivered via GPO" $true "OK"
            Add-Result "FVE_NKP certificate thumbprint(s)" (($certs | Select-Object -ExpandProperty PSChildName) -join ", ") "INFO"
        } else {
            Add-Result "FVE_NKP certificate delivered via GPO" $false "FAIL — GPO not reaching device, or no reboot since policy link"
        }
    } else {
        Add-Result "FVE_NKP certificate delivered via GPO" $false "FAIL — registry path does not exist, GPO never applied"
    }

    Write-Status "Checking Secure Boot / native UEFI mode..." "INFO"
    try {
        $sb = Confirm-SecureBootUEFI
        Add-Result "Native UEFI / Secure Boot capable" $sb (if ($sb) { "OK" } else { "FAIL — Network Unlock impossible in Legacy/CSM mode" })
    } catch {
        Add-Result "Native UEFI / Secure Boot capable" "ERROR" "FAIL — likely Legacy/CSM BIOS mode: $($_.Exception.Message)"
    }

    Write-Status "Checking network adapter enumeration order..." "INFO"
    try {
        $adapters = Get-NetAdapter | Sort-Object ifIndex
        $firstAdapter = $adapters | Select-Object -First 1
        foreach ($a in $adapters) {
            $flag = if ($a.ifIndex -eq $firstAdapter.ifIndex) { " <-- first enumerated (only one Network Unlock tries)" } else { "" }
            Add-Result "Adapter [$($a.ifIndex)] $($a.Name)" "$($a.MediaType) / $($a.Status)$flag" "INFO"
        }
        if ($firstAdapter.MediaType -notmatch "802.3|Ethernet") {
            Add-Result "First-enumerated adapter is wired Ethernet" $false "WARN — Network Unlock requires the first-enumerated adapter to be wired/DHCP-capable"
        } else {
            Add-Result "First-enumerated adapter is wired Ethernet" $true "OK"
        }
    } catch {
        Add-Result "Network adapter enumeration" "ERROR: $($_.Exception.Message)" "ERROR"
    }

    Write-Status "Checking domain join state (Network Unlock requires on-prem AD DS join, not Entra-only)..." "INFO"
    try {
        $cs = Get-CimInstance Win32_ComputerSystem
        $domainJoined = $cs.PartOfDomain
        Add-Result "Domain-joined (AD DS)" $domainJoined (if ($domainJoined) { "OK" } else { "FAIL — Network Unlock has no Entra-only equivalent" })
    } catch {
        Add-Result "Domain-joined (AD DS)" "ERROR: $($_.Exception.Message)" "ERROR"
    }
}

# ============================================================
# SERVER-SIDE CHECKS
# ============================================================
if ($effectiveRole -eq "Server") {

    Write-Status "Checking WDS-Deployment and BitLocker-NetworkUnlock Windows Features..." "INFO"
    try {
        $wds = Get-WindowsFeature -Name WDS-Deployment
        $nku = Get-WindowsFeature -Name BitLocker-NetworkUnlock
        Add-Result "WDS-Deployment feature" $wds.InstallState (if ($wds.InstallState -eq "Installed") { "OK" } else { "FAIL" })
        Add-Result "BitLocker-NetworkUnlock feature" $nku.InstallState (if ($nku.InstallState -eq "Installed") { "OK" } else { "FAIL — WDS role alone is not sufficient" })
    } catch {
        Add-Result "Windows Feature query" "ERROR: $($_.Exception.Message)" "ERROR"
    }

    Write-Status "Checking WDSServer service..." "INFO"
    try {
        $svc = Get-Service -Name WDSServer -ErrorAction Stop
        Add-Result "WDSServer service status" $svc.Status (if ($svc.Status -eq "Running") { "OK" } else { "FAIL" })
    } catch {
        Add-Result "WDSServer service status" "NOT FOUND" "FAIL — service does not exist, role likely not installed"
    }

    Write-Status "Checking active Network Unlock certificate..." "INFO"
    try {
        $nkuCerts = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
            Where-Object { $_.EnhancedKeyUsageList -match "1.3.6.1.4.1.311.67.1.1" }
        if ($nkuCerts) {
            foreach ($c in $nkuCerts) {
                $daysLeft = ($c.NotAfter - (Get-Date)).Days
                $status = if ($daysLeft -lt 0) { "FAIL — EXPIRED" } elseif ($daysLeft -lt 30) { "WARN — expires in $daysLeft days" } else { "OK" }
                Add-Result "Network Unlock cert ($($c.Thumbprint))" "NotAfter: $($c.NotAfter)" $status
            }
            if ($nkuCerts.Count -gt 1) {
                Add-Result "Multiple Network Unlock certs present locally" $nkuCerts.Count "WARN — only one is deliverable via GPO at a time; confirm which is actually referenced by policy"
            }
        } else {
            Add-Result "Network Unlock certificate present" $false "FAIL — no cert with Network Unlock EKU found in LocalMachine\My"
        }
    } catch {
        Add-Result "Network Unlock certificate query" "ERROR: $($_.Exception.Message)" "ERROR"
    }

    Write-Status "Checking for optional subnet policy file (bde-network-unlock.ini)..." "INFO"
    $iniPath = Join-Path $env:windir "System32\bde-network-unlock.ini"
    if (Test-Path $iniPath) {
        $iniContent = Get-Content $iniPath -Raw
        Add-Result "bde-network-unlock.ini present" $true "INFO — subnet restrictions are in effect, review contents"
        Add-Result "bde-network-unlock.ini raw contents" ($iniContent -replace "`r`n", " | ") "INFO"
    } else {
        Add-Result "bde-network-unlock.ini present" $false "OK — no subnet restrictions configured (all subnets permitted for all certs)"
    }

    Write-Status "Checking Nkpprov.dll provider is present..." "INFO"
    $providerPath = Join-Path $env:windir "System32\Nkpprov.dll"
    Add-Result "Nkpprov.dll provider present" (Test-Path $providerPath) (if (Test-Path $providerPath) { "OK" } else { "FAIL — BitLocker-NetworkUnlock feature likely not actually installed" })
}

# ============================================================
# REPORT
# ============================================================
Write-Host "`n=== NETWORK UNLOCK READINESS SUMMARY ($effectiveRole) ===" -ForegroundColor Cyan
$results | Format-Table -AutoSize -Wrap

$failCount = ($results | Where-Object { $_.Status -like "FAIL*" }).Count
$warnCount = ($results | Where-Object { $_.Status -like "WARN*" }).Count
Write-Status "$failCount FAIL, $warnCount WARN out of $($results.Count) checks." (if ($failCount -gt 0) { "ERROR" } elseif ($warnCount -gt 0) { "WARN" } else { "OK" })

$csvPath = Join-Path $OutputPath "NetworkUnlockReadiness-$effectiveRole-$env:COMPUTERNAME-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation
Write-Status "Report exported to: $csvPath" "OK"
