<#
.SYNOPSIS
    Device-local diagnostic for Hybrid Azure AD Join (HAADJ) — walks the full
    registration dependency chain from on-prem domain join through SCP discovery,
    DRS endpoint reachability, and the Automatic-Device-Join scheduled task, and
    optionally cross-references the device's state in Entra ID via Graph.

.DESCRIPTION
    Run ON the affected device (as local admin). Checks, in dependency order:
      1. On-prem AD domain join and secure channel health
      2. dsregcmd /status — AzureAdJoined, DomainJoined, AzureAdPrt, TenantId
      3. Service Connection Point (SCP) presence and tenant ID match
      4. DRS endpoint reachability (login.microsoftonline.com,
         device.login.microsoftonline.com, enterpriseregistration.windows.net)
      5. Automatic-Device-Join scheduled task last run result
      6. Device Registration/Admin event log — last 20 events, flags known
         failure event IDs (204, 301)
      7. Device certificate presence in LocalMachine\My (MS-Organization issuer)
      8. Optional: queries Microsoft Graph for this device's object state in
         Entra (TrustType, Pending vs. Registered, IsManaged) — requires
         Device.Read.All and an interactive/delegated Graph sign-in

    This is intentionally NOT a fleet-wide script — HAADJ failures are almost
    always device-specific (network path, cached cert, stuck scheduled task) and
    the fix path depends on which single layer breaks. Get-EntraDeviceHealth.ps1
    covers fleet-wide device state (stale/no-MDM/duplicate) but has no
    HAADJ-specific logic (no SCP check, no DRS reachability, no scheduled task
    inspection) — this script fills that gap.

    Analysis flags applied:
      NOT_DOMAIN_JOINED       - Device is not domain-joined to on-prem AD; HAADJ
                                 cannot proceed until this is fixed first.
      SECURE_CHANNEL_BROKEN   - Test-ComputerSecureChannel returned False.
      NOT_AZUREAD_JOINED      - dsregcmd shows AzureAdJoined: NO.
      NO_PRT                  - dsregcmd shows AzureAdJoined: YES but AzureAdPrt: NO
                                 (SSO will fail even though join succeeded).
      SCP_MISSING             - No SCP object found in AD — devices cannot
                                 discover the DRS endpoint at all.
      SCP_TENANT_MISMATCH     - SCP exists but azureADId does not match the
                                 tenant ID returned by dsregcmd (multi-tenant
                                 misconfiguration).
      DRS_ENDPOINT_UNREACHABLE- One or more required DRS endpoints failed a
                                 TCP 443 connectivity test.
      TASK_NOT_FOUND          - Automatic-Device-Join scheduled task is missing.
      TASK_LAST_RUN_FAILED    - Scheduled task's last result was non-zero.
      REG_EVENT_FAILURE       - Event ID 204 (registration failed) or 301
                                 (DRS endpoint unreachable) found in the last
                                 20 Device Registration/Admin log entries.
      DEVICE_CERT_MISSING     - No MS-Organization-issued certificate found in
                                 LocalMachine\My — device never completed DRS
                                 certificate issuance.
      ENTRA_PENDING           - (Optional Graph check) Device object exists in
                                 Entra but TrustType/state indicates it is still
                                 Pending sync of the userCertificate attribute.

    Read-only. Makes no changes to domain join, SCP, scheduled tasks, or
    certificates — this is a diagnostic tool. Remediation steps are documented
    in EntraID/Troubleshooting/HybridJoin-A.md and HybridJoin-B.md.

.PARAMETER DomainName
    On-prem AD domain name for the DC reachability test (e.g. contoso.local).
    If omitted, the script attempts to read it from dsregcmd output.

.PARAMETER CheckEntra
    Switch. If set, also queries Microsoft Graph for this device's object state
    in Entra ID (requires Device.Read.All and an authenticated Graph session).

.PARAMETER OutputPath
    Path for the evidence/report text file. Default: .\HAADJ-Diagnostics-<timestamp>.txt

.EXAMPLE
    .\Get-HybridJoinDiagnostics.ps1

    Runs the full local diagnostic chain and writes a report.

.EXAMPLE
    .\Get-HybridJoinDiagnostics.ps1 -DomainName "contoso.local" -CheckEntra

    Same as above, explicitly targeting a domain for DC checks, plus a live
    cross-check of this device's object state in Entra via Graph.

.NOTES
    Requires: Run as local Administrator on the affected device (domain-joined).
              RSAT AD PowerShell module (ActiveDirectory) needed only if you also
              want AD computer-object attribute checks — not required for the
              core diagnostic chain in this script.
              Microsoft.Graph PowerShell SDK required only if -CheckEntra is used.
    Scopes needed (only for -CheckEntra): Device.Read.All
    Safe: Read-only — no device state, SCP, certificates, or scheduled tasks are modified
    Cross-references: EntraID/Troubleshooting/HybridJoin-A.md (Validation Steps
                       1-7, Dependency Stack), HybridJoin-B.md (Triage, Diagnosis
                       Steps 1-6, Fix 1-6)
#>

[CmdletBinding()]
param(
    [string]$DomainName = "",

    [switch]$CheckEntra,

    [string]$OutputPath = ".\HAADJ-Diagnostics-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
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

$flags = [System.Collections.Generic.List[string]]::new()
$reportLines = [System.Collections.Generic.List[string]]::new()
function Add-Report { param([string]$Line) $reportLines.Add($Line) | Out-Null }

Add-Report "=== HAADJ Diagnostics — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
Add-Report "Computer: $env:COMPUTERNAME"
Add-Report ""

# --- Step 1: Domain join + secure channel ---
Write-Status "Step 1: Checking on-prem AD domain join..." "INFO"
$isDomainJoined = (Get-CimInstance Win32_ComputerSystem).PartOfDomain
Add-Report "--- Domain Join ---"
Add-Report "PartOfDomain: $isDomainJoined"

if (-not $isDomainJoined) {
    $flags.Add("NOT_DOMAIN_JOINED")
    Write-Status "Device is NOT domain-joined. HAADJ cannot proceed until this is fixed." "ERROR"
} else {
    Write-Status "Domain-joined: OK" "OK"
    try {
        $secureChannel = Test-ComputerSecureChannel -EA Stop
        Add-Report "SecureChannel: $secureChannel"
        if (-not $secureChannel) {
            $flags.Add("SECURE_CHANNEL_BROKEN")
            Write-Status "Secure channel test FAILED — run Test-ComputerSecureChannel -Repair." "ERROR"
        } else {
            Write-Status "Secure channel: OK" "OK"
        }
    } catch {
        Add-Report "SecureChannel: Test failed - $($_.Exception.Message)"
        Write-Status "Could not test secure channel: $($_.Exception.Message)" "WARN"
    }
}

# --- Step 2: dsregcmd /status ---
Write-Status "`nStep 2: Running dsregcmd /status..." "INFO"
$dsregOutput = & dsregcmd /status 2>&1 | Out-String
Add-Report "`n--- dsregcmd /status ---"
Add-Report $dsregOutput

$azureAdJoined = ($dsregOutput -match "AzureAdJoined\s*:\s*YES")
$azureAdPrt    = ($dsregOutput -match "AzureAdPrt\s*:\s*YES")
$tenantIdMatch = [regex]::Match($dsregOutput, "TenantId\s*:\s*(\S+)")
$dsregTenantId = if ($tenantIdMatch.Success) { $tenantIdMatch.Groups[1].Value } else { $null }
$domainNameMatch = [regex]::Match($dsregOutput, "DomainName\s*:\s*(\S+)")
if (-not $DomainName -and $domainNameMatch.Success) { $DomainName = $domainNameMatch.Groups[1].Value }

if (-not $azureAdJoined) {
    $flags.Add("NOT_AZUREAD_JOINED")
    Write-Status "AzureAdJoined: NO" "ERROR"
} else {
    Write-Status "AzureAdJoined: YES" "OK"
    if (-not $azureAdPrt) {
        $flags.Add("NO_PRT")
        Write-Status "AzureAdPrt: NO — device is joined but SSO will fail. See PRT-Issues-B.md." "WARN"
    } else {
        Write-Status "AzureAdPrt: YES" "OK"
    }
}

# --- Step 3: SCP check ---
Write-Status "`nStep 3: Checking Service Connection Point (SCP)..." "INFO"
Add-Report "`n--- SCP Check ---"
try {
    $rootDSE = [ADSI]"LDAP://RootDSE"
    $configNC = $rootDSE.configurationNamingContext
    $scpPath = "LDAP://CN=62a0ff2e-97b9-4513-943f-0d221bd30080,CN=Device Registration Configuration,CN=Services,$configNC"
    $scp = [ADSI]$scpPath

    if ($scp.Properties["keywords"] -and $scp.Properties["keywords"].Count -gt 0) {
        $keywords = $scp.Properties["keywords"] -join "; "
        Add-Report "SCP keywords: $keywords"
        Write-Status "SCP found: $keywords" "OK"

        $scpTenantMatch = [regex]::Match($keywords, "azureADId:(\S+)")
        if ($scpTenantMatch.Success -and $dsregTenantId -and $scpTenantMatch.Groups[1].Value -ne $dsregTenantId) {
            $flags.Add("SCP_TENANT_MISMATCH")
            Write-Status "SCP tenant ID ($($scpTenantMatch.Groups[1].Value)) does NOT match dsregcmd TenantId ($dsregTenantId)!" "ERROR"
        }
    } else {
        $flags.Add("SCP_MISSING")
        Write-Status "SCP object found but has no keywords set — treat as effectively missing." "ERROR"
        Add-Report "SCP keywords: (none)"
    }
} catch {
    $flags.Add("SCP_MISSING")
    Add-Report "SCP: NOT FOUND - $($_.Exception.Message)"
    Write-Status "SCP not found or unreachable — devices cannot discover the DRS endpoint. See Fix 1 in HybridJoin-A.md." "ERROR"
}

# --- Step 4: DRS endpoint reachability ---
Write-Status "`nStep 4: Testing DRS endpoint reachability..." "INFO"
Add-Report "`n--- DRS Endpoint Reachability ---"
$endpoints = @(
    "login.microsoftonline.com",
    "device.login.microsoftonline.com",
    "enterpriseregistration.windows.net"
)
$endpointFailures = 0
foreach ($ep in $endpoints) {
    try {
        $result = Test-NetConnection -ComputerName $ep -Port 443 -WarningAction SilentlyContinue -EA Stop
        $status = if ($result.TcpTestSucceeded) { "OK" } else { "FAIL" }
        if (-not $result.TcpTestSucceeded) { $endpointFailures++ }
        Add-Report "$ep : TcpTestSucceeded=$($result.TcpTestSucceeded)"
        Write-Status "$ep : $status" $(if ($result.TcpTestSucceeded) { "OK" } else { "ERROR" })
    } catch {
        $endpointFailures++
        Add-Report "$ep : Test failed - $($_.Exception.Message)"
        Write-Status "$ep : Test failed" "ERROR"
    }
}
if ($endpointFailures -gt 0) {
    $flags.Add("DRS_ENDPOINT_UNREACHABLE")
    Write-Status "$endpointFailures endpoint(s) unreachable. If a proxy is in use, check for SSL inspection — DRS endpoints use certificate pinning. See Fix 5 (HybridJoin-A.md) / Fix 4 (HybridJoin-B.md)." "ERROR"
}

# --- Step 5: Scheduled task ---
Write-Status "`nStep 5: Checking Automatic-Device-Join scheduled task..." "INFO"
Add-Report "`n--- Automatic-Device-Join Scheduled Task ---"
$task = Get-ScheduledTask -TaskPath "\Microsoft\Windows\Workplace Join\" -TaskName "Automatic-Device-Join" -EA SilentlyContinue
if (-not $task) {
    $flags.Add("TASK_NOT_FOUND")
    Add-Report "Task: NOT FOUND"
    Write-Status "Scheduled task not found — check OS version or Workplace Join feature presence." "ERROR"
} else {
    $lastResult = $task.LastRunInfo.LastTaskResult
    Add-Report "State: $($task.State)"
    Add-Report "LastRunTime: $($task.LastRunInfo.LastRunTime)"
    Add-Report ("LastResult: 0x{0:X}" -f $lastResult)
    if ($lastResult -ne 0) {
        $flags.Add("TASK_LAST_RUN_FAILED")
        Write-Status ("Last task result: 0x{0:X} (non-zero = failure)" -f $lastResult) "ERROR"
    } else {
        Write-Status "Last task result: success (0x0)" "OK"
    }
}

# --- Step 6: Device Registration event log ---
Write-Status "`nStep 6: Scanning Device Registration/Admin event log..." "INFO"
Add-Report "`n--- Device Registration/Admin Log (last 20) ---"
$events = Get-WinEvent -LogName "Microsoft-Windows-User Device Registration/Admin" -MaxEvents 20 -EA SilentlyContinue
if ($events) {
    foreach ($e in $events) {
        Add-Report "$($e.TimeCreated) [ID:$($e.Id)] $($e.LevelDisplayName): $($e.Message -replace '\s+',' ')"
    }
    $failureEvents = $events | Where-Object { $_.Id -in @(204, 301) }
    if ($failureEvents.Count -gt 0) {
        $flags.Add("REG_EVENT_FAILURE")
        Write-Status "$($failureEvents.Count) known-failure event(s) found (ID 204/301) in the last 20 entries." "ERROR"
    } else {
        Write-Status "No known-failure event IDs (204/301) in the last 20 entries." "OK"
    }
} else {
    Add-Report "No events found or log unavailable."
    Write-Status "No Device Registration events found." "WARN"
}

# --- Step 7: Device certificate ---
Write-Status "`nStep 7: Checking for MS-Organization device certificate..." "INFO"
Add-Report "`n--- Device Certificate (LocalMachine\My, MS-Organization issuer) ---"
$deviceCerts = Get-ChildItem -Path "Cert:\LocalMachine\My" -EA SilentlyContinue |
    Where-Object { $_.Issuer -match "MS-Organization" }
if ($deviceCerts) {
    foreach ($cert in $deviceCerts) {
        Add-Report "Thumbprint: $($cert.Thumbprint) | Subject: $($cert.Subject) | Expires: $($cert.NotAfter)"
    }
    Write-Status "Device certificate found — expires $($deviceCerts[0].NotAfter)." "OK"
} else {
    $flags.Add("DEVICE_CERT_MISSING")
    Add-Report "No MS-Organization certificate found."
    Write-Status "No device certificate found — DRS certificate issuance never completed." "ERROR"
}

# --- Step 8 (optional): Entra device state via Graph ---
if ($CheckEntra) {
    Write-Status "`nStep 8: Checking device object state in Entra via Graph..." "INFO"
    Add-Report "`n--- Entra Device Object (Graph) ---"
    try {
        if (-not (Get-MgContext)) {
            Connect-MgGraph -Scopes "Device.Read.All" -NoWelcome
        }
        $entraDevice = Get-MgDevice -Filter "displayName eq '$env:COMPUTERNAME'" -EA Stop
        if (-not $entraDevice) {
            Add-Report "Device NOT found in Entra."
            Write-Status "Device not found in Entra — either never synced, or SCP/registration never completed." "ERROR"
        } else {
            foreach ($d in $entraDevice) {
                Add-Report "DisplayName=$($d.DisplayName) TrustType=$($d.TrustType) ApproximateLastSignIn=$($d.ApproximateLastSignInDateTime)"
            }
            $primary = $entraDevice | Select-Object -First 1
            if ($primary.TrustType -ne "ServerAd") {
                Write-Status "Entra TrustType is '$($primary.TrustType)', not 'ServerAd' — this device is not registered as Hybrid Joined." "WARN"
            }
            if (-not $primary.ApproximateLastSignInDateTime) {
                $flags.Add("ENTRA_PENDING")
                Write-Status "Device has no recorded sign-in in Entra yet — likely still Pending userCertificate sync. Try Start-ADSyncSyncCycle -PolicyType Delta on the Entra Connect server." "WARN"
            } else {
                Write-Status "Device found in Entra, TrustType=$($primary.TrustType), last sign-in $($primary.ApproximateLastSignInDateTime)." "OK"
            }
        }
    } catch {
        Add-Report "Graph query failed: $($_.Exception.Message)"
        Write-Status "Graph query failed: $($_.Exception.Message)" "ERROR"
    }
}

# --- Summary ---
Write-Host "`n=== HAADJ Diagnostic Summary ===" -ForegroundColor Cyan
if ($flags.Count -eq 0) {
    Write-Status "No issues flagged across all local checks. If HAADJ still isn't working, check Entra Connect sync state (staging mode) from the sync server side." "OK"
    Add-Report "`n--- Summary --- `nFlags: (none)"
} else {
    Write-Status "Flags raised: $($flags -join ', ')" "ERROR"
    Add-Report "`n--- Summary --- `nFlags: $($flags -join '|')"
}

$reportLines | Out-File -FilePath $OutputPath -Encoding UTF8
Write-Status "`nFull report written to: $OutputPath" "OK"
Write-Status "Cross-reference flags against EntraID/Troubleshooting/HybridJoin-A.md Symptom -> Cause Map and HybridJoin-B.md Fix 1-6." "INFO"
