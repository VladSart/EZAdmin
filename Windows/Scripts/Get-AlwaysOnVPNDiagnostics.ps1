<#
.SYNOPSIS
    Runs a full Always On VPN (Device Tunnel / User Tunnel) client-side health check —
    services, WAN Miniport adapters, certificates, live ProfileXML, and recent connection
    events — condensed into a single pass/fail-style report.

.DESCRIPTION
    Always On VPN failures span several independent layers (service dependency chain, WAN
    Miniport driver state, machine/user certificates, the ProfileXML blob delivered via the
    MDM/WMI bridge, and NPS/RADIUS authentication) that each fail with distinct, specific error
    codes. This script automates the client-side Validation Steps from AlwaysOnVPN-A.md into
    one pass so an engineer can triage in under a minute instead of running each check by hand.

    It does NOT reach across the network to the RRAS gateway or NPS server — those require
    separate access and are covered by AlwaysOnVPN-A.md Playbook 4 (NPS diagnostic collection)
    and the Evidence Pack in that runbook for full escalation bundles.

.PARAMETER ProfileName
    Optional. The VPN profile name to focus the report on (used for gateway reachability
    testing). If omitted, the script inspects all profiles found and skips the gateway
    reachability test.

.PARAMETER OutputPath
    Folder to write the CSV/report output to. Defaults to C:\Temp\AOVPN-Diagnostics.

.EXAMPLE
    .\Get-AlwaysOnVPNDiagnostics.ps1

.EXAMPLE
    .\Get-AlwaysOnVPNDiagnostics.ps1 -ProfileName "Contoso-AOVPN" -OutputPath "D:\Reports\VPN"

.NOTES
    Run from an elevated PowerShell session on the affected Windows client.
    Requires: local admin (to query services, LocalMachine cert store, and event logs).
    Safe/Read-only: makes no configuration changes. For remediation, see the four Playbooks in
    Windows/Troubleshooting/AlwaysOnVPN-A.md (ProfileXML rebuild, NAT-T fix, cert re-enrolment,
    NPS diagnostic collection).
#>

[CmdletBinding()]
param(
    [string]$ProfileName,
    [string]$OutputPath = "C:\Temp\AOVPN-Diagnostics"
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

# --- 1. VPN profiles ---
Write-Status "Checking VPN profiles..."
$allUserProfiles = Get-VpnConnection -AllUserConnection -ErrorAction SilentlyContinue
$perUserProfiles = Get-VpnConnection -ErrorAction SilentlyContinue
$profileCount = @($allUserProfiles).Count + @($perUserProfiles).Count

if ($profileCount -eq 0) {
    Add-Finding "VPN Profile Presence" "No VPN profiles found (all-user or per-user)" "ERROR"
} else {
    Add-Finding "VPN Profile Presence" "$profileCount profile(s) found" "OK"
    ($allUserProfiles + $perUserProfiles) | Select-Object Name, ServerAddress, TunnelType, ConnectionStatus |
        Export-Csv (Join-Path $OutputPath "profiles-$ts.csv") -NoTypeInformation
}

# --- 2. WAN Miniport adapters ---
Write-Status "Checking WAN Miniport adapters..."
$miniports = Get-NetAdapter | Where-Object { $_.InterfaceDescription -like "*WAN Miniport*" }
$missing = $miniports | Where-Object { $_.Status -eq "Not Present" }
if ($missing) {
    Add-Finding "WAN Miniport Adapters" "$($missing.Count) adapter(s) in 'Not Present' state" "ERROR"
} elseif ($miniports.Count -eq 0) {
    Add-Finding "WAN Miniport Adapters" "No WAN Miniport adapters found at all" "ERROR"
} else {
    Add-Finding "WAN Miniport Adapters" "$($miniports.Count) adapter(s) present, none in error state" "OK"
}

# --- 3. Required services ---
Write-Status "Checking service dependency chain (BFE -> IKEEXT -> RasMan -> RasAuto)..."
$services = Get-Service BFE, IKEEXT, RasMan, RasAuto -ErrorAction SilentlyContinue
foreach ($svc in $services) {
    $status = if ($svc.Status -eq "Running") { "OK" } else { "ERROR" }
    Add-Finding "Service: $($svc.Name)" "$($svc.Status) (StartType: $($svc.StartType))" $status
}

# --- 4. Machine certificate (Device Tunnel) ---
Write-Status "Checking machine certificates (Device Tunnel)..."
$machineCerts = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object {
    $_.EnhancedKeyUsageList.FriendlyName -contains "Client Authentication" -and $_.NotAfter -gt (Get-Date)
}
if ($machineCerts) {
    $soonExpiring = $machineCerts | Where-Object { $_.NotAfter -lt (Get-Date).AddDays(30) }
    if ($soonExpiring) {
        Add-Finding "Machine Certificate (Device Tunnel)" "$($machineCerts.Count) valid, but $($soonExpiring.Count) expiring within 30 days" "WARN"
    } else {
        Add-Finding "Machine Certificate (Device Tunnel)" "$($machineCerts.Count) valid Client Authentication cert(s) found" "OK"
    }
} else {
    Add-Finding "Machine Certificate (Device Tunnel)" "No valid Client Authentication certificate found in LocalMachine\My" "WARN"
}

# --- 5. User certificate (User Tunnel EAP-TLS) ---
Write-Status "Checking user certificates (User Tunnel, EAP-TLS)..."
$userCerts = Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue | Where-Object {
    $_.EnhancedKeyUsageList.FriendlyName -contains "Client Authentication" -and $_.NotAfter -gt (Get-Date)
}
if ($userCerts) {
    Add-Finding "User Certificate (User Tunnel)" "$($userCerts.Count) valid Client Authentication cert(s) found" "OK"
} else {
    Add-Finding "User Certificate (User Tunnel)" "None found — expected only if this profile uses EAP-MSCHAPv2/PEAP instead of EAP-TLS" "INFO"
}

# --- 6. Live ProfileXML from WMI ---
Write-Status "Reading live ProfileXML from WMI bridge..."
try {
    $wmiProfiles = Get-CimInstance -Namespace root\cimv2\mdm\dmmap -ClassName MDM_VPNv2_01 -ErrorAction Stop
    if ($wmiProfiles) {
        Add-Finding "ProfileXML (WMI bridge)" "$(@($wmiProfiles).Count) profile instance(s) present" "OK"
        foreach ($p in $wmiProfiles) {
            [xml]$xml = $p.ProfileXML
            Write-Status "  Profile: $($p.InstanceID) | Server: $($xml.VPNProfile.NativeProfile.Servers) | AlwaysOn: $($xml.VPNProfile.AlwaysOn)" "INFO"
        }
    } else {
        Add-Finding "ProfileXML (WMI bridge)" "No MDM_VPNv2_01 instances found — profile has not landed via MDM" "ERROR"
    }
} catch {
    Add-Finding "ProfileXML (WMI bridge)" "Query failed: $($_.Exception.Message)" "ERROR"
}

# --- 7. Recent VPN client events ---
Write-Status "Checking recent VPN-Client/Operational events..."
try {
    $events = Get-WinEvent -LogName "Microsoft-Windows-VPN-Client/Operational" -MaxEvents 20 -ErrorAction Stop
    $failures = $events | Where-Object { $_.Id -in @(20225, 20227) }
    if ($failures) {
        Add-Finding "Recent VPN Events" "$($failures.Count) disconnect/failure event(s) in last 20 log entries" "WARN"
    } else {
        Add-Finding "Recent VPN Events" "No recent disconnect/failure events in last 20 log entries" "OK"
    }
    $events | Select-Object TimeCreated, Id, Message | Export-Csv (Join-Path $OutputPath "events-$ts.csv") -NoTypeInformation
} catch {
    Add-Finding "Recent VPN Events" "Could not read event log: $($_.Exception.Message)" "WARN"
}

# --- 8. Gateway reachability (if ProfileName given) ---
if ($ProfileName) {
    Write-Status "Testing gateway reachability for profile '$ProfileName'..."
    $conn = Get-VpnConnection -AllUserConnection -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $ProfileName }
    if (-not $conn) { $conn = Get-VpnConnection -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $ProfileName } }
    if ($conn -and $conn.ServerAddress) {
        $test = Test-NetConnection -ComputerName $conn.ServerAddress -Port 443 -WarningAction SilentlyContinue
        $status = if ($test.TcpTestSucceeded) { "OK" } else { "WARN" }
        Add-Finding "Gateway Reachability (TCP 443)" "$($conn.ServerAddress): TcpTestSucceeded=$($test.TcpTestSucceeded)" $status
    } else {
        Add-Finding "Gateway Reachability" "Profile '$ProfileName' not found among all-user or per-user connections" "WARN"
    }
}

# --- NAT-T registry setting ---
$natT = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\PolicyAgent" -ErrorAction SilentlyContinue).AssumeUDPEncapsulationContextOnSendRule
Add-Finding "NAT-T Registry (AssumeUDPEncapsulationContextOnSendRule)" "Value: $natT (0=default, 1=server behind NAT, 2=both behind NAT)" "INFO"

# --- Summary ---
Write-Host ""
Write-Status "=== ALWAYS ON VPN DIAGNOSTIC SUMMARY ===" "INFO"
$findings | Format-Table Check, Result, Status -AutoSize

$errorCount = ($findings | Where-Object { $_.Status -eq "ERROR" }).Count
$warnCount = ($findings | Where-Object { $_.Status -eq "WARN" }).Count

if ($errorCount -gt 0) {
    Write-Status "$errorCount critical finding(s) — see AlwaysOnVPN-A.md Symptom -> Cause Map / Troubleshooting phases." "ERROR"
} elseif ($warnCount -gt 0) {
    Write-Status "$warnCount warning(s) — review before escalating." "WARN"
} else {
    Write-Status "No issues found at the client layer. If VPN still fails, escalate to NPS/gateway-side diagnostics (Playbook 4)." "OK"
}

$reportPath = Join-Path $OutputPath "AOVPN-Diagnostics-Summary-$ts.csv"
$findings | Export-Csv -Path $reportPath -NoTypeInformation
Write-Status "Full summary exported to: $reportPath" "OK"
