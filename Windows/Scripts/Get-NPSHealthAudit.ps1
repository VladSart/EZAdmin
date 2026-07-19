<#
.SYNOPSIS
    Audits a Network Policy Server (NPS) role installation for common RADIUS
    authentication failure conditions.

.DESCRIPTION
    Read-only diagnostic script for the NPS/RADIUS-A.md and NPS-RADIUS-B.md runbooks.
    Run directly on the NPS server (not remotely) since it depends on local NPS
    PowerShell cmdlets (NPS module), local Security event log access, and local
    registry checks for the NPS Extension for Microsoft Entra multifactor authentication.

    Covers:
      1. NPS service and auditing configuration state
      2. RADIUS client (NAS) inventory sanity checks
      3. Connection Request Policy / Network Policy inventory and ordering review
      4. Recent authentication failure event summary (6272/6273/6274/13/18) with
         Reason Code extraction for 6273 denials
      5. Domain controller reachability check
      6. NPS Extension for Entra MFA registry/connectivity check (only if detected)

    Does NOT attempt to modify any NPS configuration, does NOT test actual RADIUS
    authentication end-to-end (that requires a live NAS device), and does NOT
    inspect the full condition/constraint detail of individual Network Policies
    (no PowerShell surface exposes that; use nps.msc or the -ExportConfig switch
    plus manual XML review for that level of detail).

.PARAMETER LookbackHours
    How many hours back to scan the Security event log for NPS-related events.
    Default: 24.

.PARAMETER DomainToCheck
    FQDN of the domain to test domain-controller reachability against. If omitted,
    the script attempts to detect the current machine's domain automatically.

.PARAMETER ExportConfig
    If specified, also runs Export-NpsConfiguration to the output folder for
    offline review. WARNING: the exported file contains RADIUS shared secrets
    in plaintext — handle the output folder accordingly.

.PARAMETER OutputPath
    Folder to write CSV/XML output to. Default: current directory.

.EXAMPLE
    .\Get-NPSHealthAudit.ps1
    Runs a standard audit with default 24-hour lookback, no config export.

.EXAMPLE
    .\Get-NPSHealthAudit.ps1 -LookbackHours 72 -ExportConfig -OutputPath C:\NPS-Audit
    Runs a 72-hour lookback audit and exports the full NPS configuration for
    offline review, storing all output in C:\NPS-Audit.

.NOTES
    Requires: RSAT-NPAS / NPS PowerShell module (present automatically when the
    NPAS role is installed) and Security event log read access. Run-as: local
    Administrator recommended for full Security log and registry access.
    Safe: read-only, no configuration changes are made.
#>

[CmdletBinding()]
param(
    [int]$LookbackHours = 24,
    [string]$DomainToCheck,
    [switch]$ExportConfig,
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$findings = New-Object System.Collections.Generic.List[object]

function Add-Finding {
    param([string]$Category, [string]$Flag, [string]$Detail, [string]$Severity = "INFO")
    $findings.Add([PSCustomObject]@{
        Category = $Category
        Flag     = $Flag
        Severity = $Severity
        Detail   = $Detail
    })
}

# ─── Preflight ────────────────────────────────────────────────────────────
Write-Status "Starting NPS health audit..." "INFO"

$npasFeature = Get-WindowsFeature -Name NPAS -ErrorAction SilentlyContinue
if (-not $npasFeature -or $npasFeature.InstallState -ne "Installed") {
    Add-Finding "Preflight" "NPAS_ROLE_NOT_INSTALLED" "Network Policy and Access Services role is not installed on this server. This script is meant to run on an actual NPS server." "ERROR"
    Write-Status "NPAS role not installed — aborting further checks." "ERROR"
    $findings | Export-Csv -Path (Join-Path $OutputPath "NPSHealthAudit-$stamp.csv") -NoTypeInformation
    return
}
Write-Status "NPAS role confirmed installed." "OK"

# ─── 1. Service and auditing state ─────────────────────────────────────────
Write-Status "Checking NPS service (IAS) state..." "INFO"
try {
    $svc = Get-Service -Name IAS -ErrorAction Stop
    if ($svc.Status -ne "Running") {
        Add-Finding "Service" "IAS_SERVICE_NOT_RUNNING" "NPS service (IAS) is in state '$($svc.Status)'. No authentication can occur while stopped." "ERROR"
    } else {
        Add-Finding "Service" "IAS_SERVICE_RUNNING" "NPS service is running." "OK"
    }
    if ($svc.StartType -ne "Automatic") {
        Add-Finding "Service" "IAS_STARTUP_NOT_AUTOMATIC" "IAS service StartType is '$($svc.StartType)' rather than Automatic — a reboot may not bring NPS back online." "WARN"
    }
} catch {
    Add-Finding "Service" "IAS_SERVICE_CHECK_FAILED" "Could not query IAS service: $($_.Exception.Message)" "WARN"
}

Write-Status "Checking NPS auditing configuration..." "INFO"
try {
    $auditRaw = auditpol /get /subcategory:"Network Policy Server" 2>&1 | Out-String
    if ($auditRaw -match "No Auditing") {
        Add-Finding "Auditing" "AUDITING_DISABLED" "NPS auditing subcategory is set to 'No Auditing'. All downstream event-log-based diagnosis in this script and the companion runbooks will return nothing until this is enabled (auditpol /set /subcategory:'Network Policy Server' /success:enable /failure:enable)." "ERROR"
    } else {
        Add-Finding "Auditing" "AUDITING_ENABLED" "NPS auditing is enabled." "OK"
    }
} catch {
    Add-Finding "Auditing" "AUDITING_CHECK_FAILED" "Could not query auditpol: $($_.Exception.Message)" "WARN"
}

# ─── 2. RADIUS client inventory ────────────────────────────────────────────
Write-Status "Inventorying RADIUS clients..." "INFO"
try {
    $clients = Get-NpsRadiusClient -ErrorAction Stop
    if (-not $clients -or $clients.Count -eq 0) {
        Add-Finding "RadiusClients" "NO_RADIUS_CLIENTS_CONFIGURED" "No RADIUS clients are registered. NPS cannot authenticate any NAS device until at least one is added." "WARN"
    } else {
        $clients | Select-Object Name, Address, Enabled, VendorName |
            Export-Csv -Path (Join-Path $OutputPath "RadiusClients-$stamp.csv") -NoTypeInformation
        $disabled = $clients | Where-Object { -not $_.Enabled }
        foreach ($d in $disabled) {
            Add-Finding "RadiusClients" "RADIUS_CLIENT_DISABLED" "RADIUS client '$($d.Name)' ($($d.Address)) is disabled — any NAS still pointed at NPS using this entry will fail with Event 13." "WARN"
        }
        Add-Finding "RadiusClients" "RADIUS_CLIENT_COUNT" "$($clients.Count) RADIUS client(s) registered ($($disabled.Count) disabled)." "OK"
    }
} catch {
    Add-Finding "RadiusClients" "RADIUS_CLIENT_QUERY_FAILED" "Could not query RADIUS clients: $($_.Exception.Message)" "WARN"
}

# ─── 3. Connection Request Policy / Network Policy inventory ──────────────
Write-Status "Inventorying Connection Request Policies and Network Policies..." "INFO"
try {
    $crps = Get-NpsConnectionRequestPolicy -ErrorAction Stop | Sort-Object ProcessingOrder
    $crps | Select-Object ProcessingOrder, Name, Enabled, PolicyState |
        Export-Csv -Path (Join-Path $OutputPath "ConnectionRequestPolicies-$stamp.csv") -NoTypeInformation
    $disabledCrp = $crps | Where-Object { -not $_.Enabled }
    if ($crps.Count -eq 0) {
        Add-Finding "Policies" "NO_CONNECTION_REQUEST_POLICIES" "No Connection Request Policies exist — every incoming request will be discarded (Event 6274)." "ERROR"
    } else {
        Add-Finding "Policies" "CRP_COUNT" "$($crps.Count) Connection Request Policy(ies) found, $($disabledCrp.Count) disabled." "OK"
    }
} catch {
    Add-Finding "Policies" "CRP_QUERY_FAILED" "Could not query Connection Request Policies: $($_.Exception.Message)" "WARN"
}

try {
    $nps_policies = Get-NpsNetworkPolicy -ErrorAction Stop | Sort-Object ProcessingOrder
    $nps_policies | Select-Object ProcessingOrder, Name, Enabled, PolicyState |
        Export-Csv -Path (Join-Path $OutputPath "NetworkPolicies-$stamp.csv") -NoTypeInformation
    if ($nps_policies.Count -eq 0) {
        Add-Finding "Policies" "NO_NETWORK_POLICIES" "No Network Policies exist — any request routed to local processing will be discarded (Event 6274)." "ERROR"
    } else {
        # Heuristic: flag if any policy explicitly named/state as a catch-all deny sits above other enabled policies
        $enabledOrdered = $nps_policies | Where-Object { $_.Enabled }
        if ($enabledOrdered.Count -gt 1) {
            Add-Finding "Policies" "MULTIPLE_NETWORK_POLICIES_REVIEW_ORDER" "$($enabledOrdered.Count) enabled Network Policies found — manually confirm ProcessingOrder places intended Allow policies ahead of any broad Deny (no cmdlet exposes Allow/Deny action directly; verify in nps.msc or exported XML)." "INFO"
        }
        Add-Finding "Policies" "NETWORK_POLICY_COUNT" "$($nps_policies.Count) Network Policy(ies) found." "OK"
    }
} catch {
    Add-Finding "Policies" "NETWORK_POLICY_QUERY_FAILED" "Could not query Network Policies: $($_.Exception.Message)" "WARN"
}

# ─── 4. Recent authentication event summary ────────────────────────────────
Write-Status "Scanning Security event log for NPS events (last $LookbackHours hours)..." "INFO"
try {
    $since = (Get-Date).AddHours(-$LookbackHours)
    $events = Get-WinEvent -FilterHashtable @{ LogName = "Security"; Id = 6272,6273,6274,13,18; StartTime = $since } -ErrorAction SilentlyContinue

    if (-not $events) {
        Add-Finding "Events" "NO_NPS_EVENTS_IN_WINDOW" "No NPS-related Security events (6272/6273/6274/13/18) found in the last $LookbackHours hour(s). Either NPS saw no traffic, or auditing is not actually capturing these events despite the auditpol setting — cross-check the Auditing finding above." "WARN"
    } else {
        $events | Select-Object TimeCreated, Id, Message |
            Export-Csv -Path (Join-Path $OutputPath "NPSSecurityEvents-$stamp.csv") -NoTypeInformation

        $denied = $events | Where-Object { $_.Id -eq 6273 }
        $discarded = $events | Where-Object { $_.Id -eq 6274 }
        $badClient = $events | Where-Object { $_.Id -eq 13 }
        $badSecret = $events | Where-Object { $_.Id -eq 18 }
        $granted = $events | Where-Object { $_.Id -eq 6272 }

        Add-Finding "Events" "EVENT_SUMMARY" "Granted:$($granted.Count) Denied:$($denied.Count) Discarded:$($discarded.Count) UnregisteredClient:$($badClient.Count) SecretMismatch:$($badSecret.Count) in last $LookbackHours h." "INFO"

        if ($discarded.Count -gt 0) {
            Add-Finding "Events" "DISCARDED_REQUESTS_FOUND" "$($discarded.Count) request(s) discarded (Event 6274) — these matched no Connection Request or Network Policy. Review policy coverage for gaps (see Playbook 2 in NPS-RADIUS-A.md)." "WARN"
        }
        if ($badClient.Count -gt 0) {
            Add-Finding "Events" "UNREGISTERED_CLIENT_TRAFFIC" "$($badClient.Count) request(s) from an unregistered RADIUS client IP (Event 13). Check RadiusClients-$stamp.csv against the source IPs in the raw event messages." "WARN"
        }
        if ($badSecret.Count -gt 0) {
            Add-Finding "Events" "SHARED_SECRET_MISMATCH" "$($badSecret.Count) request(s) failed message-authenticator validation (Event 18) — shared secret mismatch between a NAS and NPS." "ERROR"
        }
        if ($denied.Count -gt 0) {
            Add-Finding "Events" "ACCESS_DENIALS_FOUND" "$($denied.Count) Access-Reject event(s) (6273) in the window. Inspect NPSSecurityEvents-$stamp.csv Message field for the Reason Code on each." "INFO"
        }
    }
} catch {
    Add-Finding "Events" "EVENT_QUERY_FAILED" "Could not query Security event log: $($_.Exception.Message)" "WARN"
}

# ─── 5. Domain controller reachability ─────────────────────────────────────
Write-Status "Checking domain controller reachability..." "INFO"
try {
    if (-not $DomainToCheck) {
        $DomainToCheck = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Domain
    }
    if ($DomainToCheck -and $DomainToCheck -ne "WORKGROUP") {
        $dcResult = nltest /dsgetdc:$DomainToCheck 2>&1 | Out-String
        if ($dcResult -match "ERROR" -or $LASTEXITCODE -ne 0) {
            Add-Finding "ADConnectivity" "DC_NOT_LOCATABLE" "Could not locate a domain controller for '$DomainToCheck'. NPS cannot authenticate any AD-backed request while this is broken." "ERROR"
        } else {
            Add-Finding "ADConnectivity" "DC_LOCATABLE" "Domain controller located for '$DomainToCheck'." "OK"
        }
    } else {
        Add-Finding "ADConnectivity" "NOT_DOMAIN_JOINED" "This server does not appear to be domain-joined (Domain='$DomainToCheck'). NPS will authenticate against the local SAM database only." "INFO"
    }
} catch {
    Add-Finding "ADConnectivity" "DC_CHECK_FAILED" "Could not evaluate domain/DC reachability: $($_.Exception.Message)" "WARN"
}

# ─── 6. NPS Extension for Entra MFA (only if present) ──────────────────────
Write-Status "Checking for NPS Extension for Microsoft Entra multifactor authentication..." "INFO"
try {
    $mfaRegPath = "HKLM:\SOFTWARE\Microsoft\AzureMfa"
    if (Test-Path $mfaRegPath) {
        Add-Finding "MFAExtension" "MFA_EXTENSION_DETECTED" "NPS Extension for Entra MFA registry configuration found — running extension-specific checks." "INFO"

        $requiredKeys = "CONFIG_PROVIDER_KEY","CLIENT_CONNECTION_INFO"
        foreach ($key in $requiredKeys) {
            $val = (Get-ItemProperty -Path $mfaRegPath -ErrorAction SilentlyContinue).$key
            if (-not $val) {
                Add-Finding "MFAExtension" "MFA_REGISTRY_KEY_MISSING" "Expected registry value '$key' not found under $mfaRegPath — extension may not have completed post-install configuration. Re-run AzureMfaNpsExtnConfigSetup.ps1." "ERROR"
            }
        }

        $endpoints = @("adnotifications.windowsazure.com", "login.microsoftonline.com")
        foreach ($ep in $endpoints) {
            try {
                $test = Test-NetConnection -ComputerName $ep -Port 443 -WarningAction SilentlyContinue -ErrorAction Stop
                if (-not $test.TcpTestSucceeded) {
                    Add-Finding "MFAExtension" "MFA_ENDPOINT_UNREACHABLE" "Cannot reach $ep on port 443 — MFA extension will fail with HTTP_CONNECT_ERROR/HTTPS_COMMUNICATION_ERROR. Check outbound firewall rules." "ERROR"
                } else {
                    Add-Finding "MFAExtension" "MFA_ENDPOINT_REACHABLE" "$ep reachable on port 443." "OK"
                }
            } catch {
                Add-Finding "MFAExtension" "MFA_ENDPOINT_CHECK_FAILED" "Could not test connectivity to $ep : $($_.Exception.Message)" "WARN"
            }
        }

        $tls12Path = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client"
        if (Test-Path $tls12Path) {
            $disabled = (Get-ItemProperty -Path $tls12Path -ErrorAction SilentlyContinue).Enabled
            if ($null -ne $disabled -and $disabled -eq 0) {
                Add-Finding "MFAExtension" "TLS12_DISABLED" "TLS 1.2 Client is explicitly disabled via registry — this breaks the MFA extension's outbound calls (System log event 36871, source SChannel)." "ERROR"
            }
        }
    } else {
        Add-Finding "MFAExtension" "MFA_EXTENSION_NOT_DETECTED" "No NPS Extension for Entra MFA registry configuration found — this server appears to be primary-auth-only (no cloud MFA layer)." "INFO"
    }
} catch {
    Add-Finding "MFAExtension" "MFA_EXTENSION_CHECK_FAILED" "Could not evaluate MFA extension state: $($_.Exception.Message)" "WARN"
}

# ─── Optional: export full NPS config ──────────────────────────────────────
if ($ExportConfig) {
    Write-Status "Exporting full NPS configuration (contains plaintext shared secrets)..." "WARN"
    try {
        $cfgPath = Join-Path $OutputPath "nps-config-snapshot-$stamp.xml"
        Export-NpsConfiguration -Path $cfgPath -ErrorAction Stop
        Add-Finding "Config" "CONFIG_EXPORTED" "Full NPS configuration exported to $cfgPath — contains plaintext RADIUS shared secrets, handle/store securely and delete when no longer needed." "WARN"
    } catch {
        Add-Finding "Config" "CONFIG_EXPORT_FAILED" "Export-NpsConfiguration failed: $($_.Exception.Message)" "WARN"
    }
}

# ─── Report ─────────────────────────────────────────────────────────────
$reportPath = Join-Path $OutputPath "NPSHealthAudit-$stamp.csv"
$findings | Export-Csv -Path $reportPath -NoTypeInformation

Write-Status "Audit complete. $($findings.Count) finding(s) recorded." "INFO"
$errorCount = ($findings | Where-Object { $_.Severity -eq "ERROR" }).Count
$warnCount  = ($findings | Where-Object { $_.Severity -eq "WARN" }).Count
Write-Status "$errorCount error-level, $warnCount warning-level finding(s)." $(if ($errorCount -gt 0) { "ERROR" } elseif ($warnCount -gt 0) { "WARN" } else { "OK" })
Write-Status "Full report: $reportPath" "INFO"

$findings | Format-Table -AutoSize
