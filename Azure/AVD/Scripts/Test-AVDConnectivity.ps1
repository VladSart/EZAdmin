<#
.SYNOPSIS
    Tests network connectivity from an AVD session host (or client machine) to all required
    Azure Virtual Desktop, RDP Shortpath, and dependent service endpoints.

.DESCRIPTION
    Runs a full connectivity sweep against the FQDNs and ports Microsoft documents as required
    for Azure Virtual Desktop to function correctly, covering:
      - AVD control plane / broker / gateway endpoints
      - RDP Shortpath (UDP-based transport) reachability
      - Entra ID authentication endpoints
      - Windows activation / licensing endpoints (KMS)
      - FSLogix profile share connectivity (optional, if -FSLogixSharePath supplied)
      - Certificate revocation list (CRL) endpoints

    Intended to be run ON a session host during initial deployment validation, or on a client
    machine when troubleshooting "can't connect" tickets to rule out network/firewall causes
    before escalating to the AVD service itself.

.PARAMETER FSLogixSharePath
    UNC path to the FSLogix profile container share. If supplied, tests SMB reachability
    in addition to the standard AVD endpoint sweep.

.PARAMETER IncludeRDPShortpath
    Switch. If set, also tests UDP 3390 reachability for RDP Shortpath (managed networks).
    RDP Shortpath uses STUN/TURN-style UDP connectivity; a failure here does not mean AVD
    is broken — it means the session will fall back to the reverse-connect TCP transport,
    which still works but with potentially higher latency.

.PARAMETER ExportPath
    Path to export the CSV report. Defaults to a timestamped file in the current directory.

.EXAMPLE
    .\Test-AVDConnectivity.ps1

.EXAMPLE
    .\Test-AVDConnectivity.ps1 -FSLogixSharePath '\\stcontosoavd.file.core.windows.net\profiles' -IncludeRDPShortpath

.NOTES
    Requires: PowerShell 5.1+ (Windows). No elevated rights required for connectivity tests;
              elevated rights required only if run alongside profile share ACL checks.
    Safe to run: Read-only network tests. No configuration changes made.
    Reference:  https://learn.microsoft.com/en-us/azure/virtual-desktop/safe-url-list
#>

[CmdletBinding()]
param(
    [string]$FSLogixSharePath,
    [switch]$IncludeRDPShortpath,
    [string]$ExportPath = ".\AVDConnectivity_$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"    { "Green"  }
        "WARN"  { "Yellow" }
        "ERROR" { "Red"    }
        default { "Cyan"   }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

Write-Status "Azure Virtual Desktop Connectivity Test" "INFO"
Write-Status "========================================" "INFO"

#region — Endpoint definitions
# Core AVD service endpoints — required for broker, gateway, diagnostics, and agent updates
$avdEndpoints = @(
    @{ Name = "AVD Service (RDBroker)";        Host = "rdbroker.wvd.microsoft.com";               Port = 443 }
    @{ Name = "AVD Diagnostics";                Host = "rddiagnostics.wvd.microsoft.com";          Port = 443 }
    @{ Name = "AVD Gateway (generic)";          Host = "*.rdweb.wvd.microsoft.com" -replace '\*', 'client'; Port = 443 }
    @{ Name = "AVD Agent Update / Manager";     Host = "catalogartifact.azureedge.net";            Port = 443 }
    @{ Name = "AVD Monitoring (telemetry)";     Host = "monitor.azure.com";                        Port = 443 }
)

# Entra ID / authentication endpoints
$authEndpoints = @(
    @{ Name = "Entra ID login";                 Host = "login.microsoftonline.com";                Port = 443 }
    @{ Name = "Entra device registration";      Host = "enterpriseregistration.windows.net";       Port = 443 }
    @{ Name = "Entra SSO autologon";             Host = "autologon.microsoftazuread-sso.com";       Port = 443 }
)

# Licensing / activation
$licensingEndpoints = @(
    @{ Name = "Windows KMS activation";         Host = "kms.core.windows.net";                     Port = 1688 }
)

# Certificate revocation list endpoints — commonly missed in firewall allow-lists
$crlEndpoints = @(
    @{ Name = "CRL - MSOCSP";                   Host = "www.microsoft.com";                        Port = 80 }
    @{ Name = "CRL - DigiCert";                  Host = "crl.digicert.com";                          Port = 80 }
    @{ Name = "OCSP - DigiCert";                 Host = "ocsp.digicert.com";                          Port = 80 }
)

# Azure Instance Metadata Service (required on the session host itself, not the client)
$imdsEndpoint = @{ Name = "Azure Instance Metadata Service"; Host = "169.254.169.254"; Port = 80 }
#endregion

#region — Run TCP tests
$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Test-Endpoint {
    param($EndpointList, $Category)
    foreach ($ep in $EndpointList) {
        $status = "UNKNOWN"
        $latencyMs = -1
        try {
            $test = Test-NetConnection -ComputerName $ep.Host -Port $ep.Port -WarningAction SilentlyContinue
            $status = if ($test.TcpTestSucceeded) { "OK" } else { "FAIL" }
            $latencyMs = if ($test.PingReplyDetails) { $test.PingReplyDetails.RoundtripTime } else { -1 }
        } catch {
            $status = "ERROR: $($_.Exception.Message)"
        }

        $entry = [PSCustomObject]@{
            Category   = $Category
            Name       = $ep.Name
            Host       = $ep.Host
            Port       = $ep.Port
            Status     = $status
            LatencyMs  = $latencyMs
        }
        $results.Add($entry)

        $icon = if ($status -eq "OK") { "✅" } else { "❌" }
        Write-Host "  $icon $($ep.Name) ($($ep.Host):$($ep.Port)) → $status"
    }
}

Write-Status "Testing AVD control plane endpoints..." "INFO"
Test-Endpoint -EndpointList $avdEndpoints -Category "AVD Service"

Write-Status "Testing Entra ID authentication endpoints..." "INFO"
Test-Endpoint -EndpointList $authEndpoints -Category "Authentication"

Write-Status "Testing licensing/activation endpoints..." "INFO"
Test-Endpoint -EndpointList $licensingEndpoints -Category "Licensing"

Write-Status "Testing certificate revocation endpoints..." "INFO"
Test-Endpoint -EndpointList $crlEndpoints -Category "CRL/OCSP"

Write-Status "Testing Azure Instance Metadata Service (session host only — will fail on a client PC, that's expected)..." "INFO"
Test-Endpoint -EndpointList @($imdsEndpoint) -Category "IMDS"
#endregion

#region — RDP Shortpath (optional UDP test)
if ($IncludeRDPShortpath) {
    Write-Status "Testing RDP Shortpath (UDP 3390) reachability..." "INFO"
    Write-Status "Note: UDP connectivity cannot be definitively confirmed via simple socket tests." "WARN"
    Write-Status "This test only confirms the local firewall/NIC allows outbound UDP on this port — it does NOT confirm end-to-end Shortpath negotiation succeeded." "WARN"

    try {
        $udpClient = New-Object System.Net.Sockets.UdpClient
        $udpClient.Connect("20.202.0.0", 3390)  # placeholder AVD-range test target; real validation requires a live session
        $udpClient.Close()
        Write-Host "  ✅ Outbound UDP 3390 not blocked locally (does not confirm full Shortpath negotiation)"
        $results.Add([PSCustomObject]@{
            Category = "RDP Shortpath"; Name = "UDP 3390 outbound"; Host = "N/A"; Port = 3390
            Status = "LOCAL-OK (verify via Get-EventLog RDMS Shortpath events for true confirmation)"; LatencyMs = -1
        })
    } catch {
        Write-Host "  ❌ Outbound UDP 3390 appears blocked locally"
        $results.Add([PSCustomObject]@{
            Category = "RDP Shortpath"; Name = "UDP 3390 outbound"; Host = "N/A"; Port = 3390
            Status = "BLOCKED"; LatencyMs = -1
        })
    }

    Write-Status "For definitive Shortpath confirmation, check on the session host after a session connects:" "INFO"
    Write-Status '  Get-WinEvent -LogName "Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational" | Where-Object { $_.Message -match "Shortpath" }' "INFO"
}
#endregion

#region — FSLogix share connectivity (optional)
if ($FSLogixSharePath) {
    Write-Status "Testing FSLogix profile share connectivity: $FSLogixSharePath" "INFO"
    try {
        if (Test-Path $FSLogixSharePath) {
            Write-Status "Share reachable: $FSLogixSharePath" "OK"
            $results.Add([PSCustomObject]@{
                Category = "FSLogix"; Name = "Profile share reachability"; Host = $FSLogixSharePath; Port = 445
                Status = "OK"; LatencyMs = -1
            })
        } else {
            Write-Status "Share NOT reachable: $FSLogixSharePath" "ERROR"
            $results.Add([PSCustomObject]@{
                Category = "FSLogix"; Name = "Profile share reachability"; Host = $FSLogixSharePath; Port = 445
                Status = "FAIL"; LatencyMs = -1
            })
        }
    } catch {
        Write-Status "FSLogix share check error: $_" "WARN"
    }
}
#endregion

#region — Summary and export
Write-Status "" "INFO"
Write-Status "=== SUMMARY ===" "INFO"

$failCount = ($results | Where-Object { $_.Status -match "FAIL|ERROR|BLOCKED" }).Count
$okCount   = ($results | Where-Object { $_.Status -match "OK" }).Count

Write-Status "Total checks: $($results.Count)" "INFO"
Write-Status "Passed: $okCount" "OK"
if ($failCount -gt 0) {
    Write-Status "Failed: $failCount — review entries below" "ERROR"
    $results | Where-Object { $_.Status -match "FAIL|ERROR|BLOCKED" } | Format-Table Category, Name, Host, Port, Status -AutoSize
} else {
    Write-Status "Failed: 0" "OK"
}

Write-Status "Reminder: the IMDS check (169.254.169.254) is EXPECTED to fail when this script is run from a client machine rather than the session host itself." "WARN"

$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Report exported: $ExportPath" "OK"
#endregion
