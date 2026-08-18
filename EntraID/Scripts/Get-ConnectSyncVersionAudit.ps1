<#
.SYNOPSIS
    Read-only Microsoft Entra Connect Sync version/EOL readiness audit — the
    30 September 2026 mandatory-upgrade floor and per-version retirement
    checks ConnectSyncUpgrade-A.md and ConnectSyncUpgrade-B.md describe.

.DESCRIPTION
    Runs locally on a Microsoft Entra Connect Sync server (this is a host-based
    diagnostic, not a Graph-based tenant audit — there is no supported Graph
    API surface that reports an on-prem sync server's installed version).

    Performs five independent checks:

    1. TRUE RUNNING VERSION — reads miiserver.exe's own VersionInfo directly
       (authoritative) and cross-checks against the ADSync module's own
       reported Microsoft.Synchronize.ServerConfigurationVersion parameter.
       Programs and Features / Get-Package installed-version is intentionally
       NOT used as the primary source, since Microsoft can push incremental
       back-end service updates without bumping install metadata — this
       script flags MISMATCH if the two sources disagree.

    2. MANDATORY-FLOOR CHECK — flags BELOW_MANDATORY_FLOOR (HIGH risk) if the
       running version is below 2.5.79.0, the version below which ALL
       synchronization services stop tenant-wide on 30 September 2026 per
       Microsoft's own version-history reference.

    3. PER-VERSION RETIREMENT CHECK — cross-references the running version
       against Microsoft's published End-of-Support table (embedded below;
       re-verify against https://aka.ms/aadconnectrss periodically, as this
       table shifts with every new release) and flags RETIRED or
       RETIRING_SOON (within 90 days) accordingly.

    4. PREREQUISITE CHECK — .NET Framework release key (461808+ required for
       4.7.2) and TLS 1.2 SCHANNEL registry state (client half). Flags
       PREREQ_GAP if either is missing — the upgrade installer will refuse
       to proceed without both.

    5. CONFIG-MODIFICATION SIGNAL — compares miiserver.exe.config's
       LastWriteTime against miiserver.exe's own install/link timestamp as a
       best-effort (non-conclusive) signal that the config file may have been
       manually modified — the documented trigger for the post-upgrade
       FileLoadException / System.Diagnostics.DiagnosticSource known issue on
       upgrades to 2.5.190.0/2.6.1.0, and the reason auto-upgrade skips a
       server outright as of 2.6.3.0+. Flags CONFIG_POSSIBLY_MODIFIED — this
       is a heuristic, not a guarantee; confirm manually via change history
       or a diff against a known-clean baseline before relying on it alone.

    Read-only throughout. Makes no changes to the server, the sync
    configuration, or any file. Does NOT run the upgrade installer, does NOT
    modify miiserver.exe.config, and does NOT restart any service. Exports a
    single-row-per-server CSV suitable for aggregating across an MSP's full
    customer fleet (run once per server, combine externally).

    Does NOT cover (see ConnectSyncUpgrade-A.md "Does not cover"):
    - Attribute sync errors, object matching/joining, or staging-mode day-2
      issues on an already-current server — see Connect-Sync-A.md/-B.md
    - Whether THIS release was actually published for auto-upgrade — that
      status lives only on the Microsoft Learn version-history page, not in
      any locally queryable state
    - Actually applying the config-file binding-redirect fix — see
      ConnectSyncUpgrade-B.md Fix 4 / ConnectSyncUpgrade-A.md Playbook 2
    - Cloud-side / Entra Connect Health telemetry — this script is entirely
      local-host based

.PARAMETER RetirementWarningDays
    Number of days before a version's own End-of-Support date to flag
    RETIRING_SOON instead of just RETIRED-eventually. Defaults to 90.

.PARAMETER OutputPath
    Folder where the CSV report is written. Defaults to
    $env:TEMP\ConnectSyncVersionAudit-<timestamp>.

.EXAMPLE
    .\Get-ConnectSyncVersionAudit.ps1

    Standard audit against the local server with the default 90-day
    retirement warning window.

.EXAMPLE
    .\Get-ConnectSyncVersionAudit.ps1 -RetirementWarningDays 30 -OutputPath C:\Reports\ConnectSync

    Tighter 30-day retirement warning window, custom output folder.

.NOTES
    Requires: local access to the Microsoft Entra Connect Sync installation
              folder; the ADSync PowerShell module (installed alongside
              Connect Sync itself) for the cross-check in Check 1.
    Run As:   Any account with read access to
              "%ProgramFiles%\Microsoft Azure AD Sync\Bin" and the relevant
              HKLM registry keys. Local Administrator is NOT strictly
              required for these read-only checks, but is typically already
              the operating context on a Connect Sync server.
    Safe:     Fully read-only — no Set-/New-/Remove-/Restart-Service, no file
              writes outside the CSV report, and the upgrade installer is
              never invoked by this script.
    Cross-references: EntraID/Troubleshooting/ConnectSyncUpgrade-B.md (Triage,
                       Fix 1-6) and ConnectSyncUpgrade-A.md (Validation Steps
                       1-5, Symptom -> Cause Map).
    Compatible with Windows PowerShell 5.1 and PowerShell 7+.
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 365)]
    [int]$RetirementWarningDays = 90,

    [string]$OutputPath = "$env:TEMP\ConnectSyncVersionAudit-$(Get-Date -Format 'yyyyMMdd-HHmm')"
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

# Published End-of-Support table (source: Microsoft Entra Connect version-history
# reference page). Re-verify against https://aka.ms/aadconnectrss — this table is
# expected to gain new rows and shift as future versions release.
$eosTable = [ordered]@{
    "2.3.2.0"    = [datetime]"2025-04-30"
    "2.3.6.0"    = [datetime]"2025-04-30"
    "2.3.8.0"    = [datetime]"2025-04-30"
    "2.3.20.0"   = [datetime]"2025-04-30"
    "2.4.18.0"   = [datetime]"2025-10-09"
    "2.4.21.0"   = [datetime]"2025-11-15"
    "2.4.27.0"   = [datetime]"2026-01-15"
    "2.4.129.0"  = [datetime]"2026-03-27"
    "2.4.131.0"  = [datetime]"2026-05-26"
    "2.5.3.0"    = [datetime]"2026-07-31"
    "2.5.76.0"   = [datetime]"2026-09-01"
    "2.5.79.0"   = [datetime]"2026-10-23"
    "2.5.190.0"  = [datetime]"2027-02-02"
    "2.6.1.0"    = [datetime]"2027-03-10"
    "2.6.3.0"    = [datetime]"2027-07-07"
    # 2.6.84.0 — current release as of this script's authoring, no EOS scheduled yet
}
$mandatoryFloor = [version]"2.5.79.0"
$mandatoryDeadline = [datetime]"2026-09-30"
$binPath = "$env:ProgramFiles\Microsoft Azure AD Sync\Bin"

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$findings = [System.Collections.Generic.List[object]]::new()

# ---- Preflight ----
$miiserverPath = Join-Path $binPath "miiserver.exe"
if (-not (Test-Path $miiserverPath)) {
    Write-Status "miiserver.exe not found at '$miiserverPath'. Is this a Microsoft Entra Connect Sync server? Run this script directly on the sync server, not a management workstation." "ERROR"
    return
}

# =====================================================================
# CHECK 1 — True running version + cross-check
# =====================================================================
Write-Status "Reading true running version from miiserver.exe..." "INFO"
$installedVersionRaw = (Get-Item $miiserverPath).VersionInfo.ProductVersion
try { $installedVersion = [version]($installedVersionRaw -replace '[^\d\.]', '') } catch { $installedVersion = $null }

$serverConfigVersion = $null
try {
    Import-Module ADSync -ErrorAction Stop
    $serverConfigVersion = (Get-ADSyncGlobalSettingsParameter -ErrorAction Stop |
        Where-Object { $_.Name -eq 'Microsoft.Synchronize.ServerConfigurationVersion' }).Value
}
catch {
    Write-Status "Could not load ADSync module or read ServerConfigurationVersion: $($_.Exception.Message)" "WARN"
}

if ($serverConfigVersion -and $installedVersionRaw -and ($serverConfigVersion -ne $installedVersionRaw)) {
    $findings.Add([PSCustomObject]@{
        Category = "VersionCheck"; Flag = "VERSION_SOURCE_MISMATCH"
        Detail = "miiserver.exe reports '$installedVersionRaw' but ADSync module reports ServerConfigurationVersion '$serverConfigVersion' — investigate before trusting either value for a deadline/compliance decision."
        RiskLevel = "MEDIUM"
    })
    Write-Status "Version source mismatch: miiserver.exe='$installedVersionRaw' vs ServerConfigurationVersion='$serverConfigVersion'" "WARN"
}
else {
    Write-Status "Running version: $installedVersionRaw" "OK"
}

# =====================================================================
# CHECK 2 — Mandatory-floor check (30 Sep 2026 hard deadline)
# =====================================================================
$belowFloor = $false
if ($installedVersion) {
    $belowFloor = $installedVersion -lt $mandatoryFloor
    if ($belowFloor) {
        $daysToDeadline = ($mandatoryDeadline - (Get-Date)).Days
        $findings.Add([PSCustomObject]@{
            Category = "MandatoryFloor"; Flag = "BELOW_MANDATORY_FLOOR"
            Detail = "Running version '$installedVersionRaw' is below the mandatory floor 2.5.79.0 — ALL synchronization services stop tenant-wide on 2026-09-30 ($daysToDeadline day(s) from today) if not upgraded. See ConnectSyncUpgrade-B.md Fix 1."
            RiskLevel = "HIGH"
        })
        Write-Status "BELOW MANDATORY FLOOR — $daysToDeadline day(s) until the 2026-09-30 hard deadline. Treat as urgent." "ERROR"
    }
    else {
        Write-Status "At or above the mandatory floor (2.5.79.0)." "OK"
    }
}
else {
    Write-Status "Could not parse a valid version number from '$installedVersionRaw' — mandatory-floor check skipped." "WARN"
}

# =====================================================================
# CHECK 3 — Per-version retirement check
# =====================================================================
if ($installedVersionRaw -and $eosTable.Contains($installedVersionRaw)) {
    $eosDate = $eosTable[$installedVersionRaw]
    $daysToEos = ($eosDate - (Get-Date)).Days
    if ($daysToEos -lt 0) {
        $findings.Add([PSCustomObject]@{
            Category = "Retirement"; Flag = "RETIRED"
            Detail = "Version '$installedVersionRaw' reached its own End of Support on $($eosDate.ToString('yyyy-MM-dd')) ($([math]::Abs($daysToEos)) day(s) ago). Retired versions may unexpectedly stop working and no longer receive security fixes."
            RiskLevel = "HIGH"
        })
        Write-Status "RETIRED — this version's own End of Support was $($eosDate.ToString('yyyy-MM-dd'))." "ERROR"
    }
    elseif ($daysToEos -le $RetirementWarningDays) {
        $findings.Add([PSCustomObject]@{
            Category = "Retirement"; Flag = "RETIRING_SOON"
            Detail = "Version '$installedVersionRaw' reaches End of Support on $($eosDate.ToString('yyyy-MM-dd')) ($daysToEos day(s) from today, within the $RetirementWarningDays-day warning window)."
            RiskLevel = "MEDIUM"
        })
        Write-Status "RETIRING SOON — End of Support $($eosDate.ToString('yyyy-MM-dd')), $daysToEos day(s) away." "WARN"
    }
    else {
        Write-Status "Not yet approaching its own End of Support ($($eosDate.ToString('yyyy-MM-dd')), $daysToEos day(s) away)." "OK"
    }
}
elseif ($installedVersionRaw) {
    Write-Status "Version '$installedVersionRaw' not found in the embedded EOS table — either it is the current release with no EOS scheduled yet, or the table is stale. Re-verify against https://aka.ms/aadconnectrss." "INFO"
}

if ($installedVersionRaw -eq "2.6.79.0") {
    $findings.Add([PSCustomObject]@{
        Category = "Retirement"; Flag = "RECALLED_VERSION"
        Detail = "Version 2.6.79.0 was recalled by Microsoft after a post-release issue was identified. Uninstall and reinstall the current release rather than patching forward. See ConnectSyncUpgrade-B.md Fix 3."
        RiskLevel = "HIGH"
    })
    Write-Status "RECALLED VERSION DETECTED (2.6.79.0) — uninstall and reinstall the current release." "ERROR"
}

# =====================================================================
# CHECK 4 — Prerequisite check (.NET Framework 4.7.2+, TLS 1.2)
# =====================================================================
Write-Status "Checking upgrade prerequisites (.NET Framework release key, TLS 1.2)..." "INFO"
$netRelease = $null
try {
    $netRelease = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -Name Release -ErrorAction Stop).Release
}
catch {
    Write-Status "Could not read .NET Framework release key: $($_.Exception.Message)" "WARN"
}
$netOk = $netRelease -and ($netRelease -ge 461808)

$tlsClient = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client" -ErrorAction SilentlyContinue
$tlsOk = $tlsClient -and ($tlsClient.Enabled -eq 1) -and ($tlsClient.DisabledByDefault -eq 0)

if (-not $netOk -or -not $tlsOk) {
    $findings.Add([PSCustomObject]@{
        Category = "Prerequisites"; Flag = "PREREQ_GAP"
        Detail = ".NET Framework 4.7.2+ present: $netOk (release key: $netRelease). TLS 1.2 client enabled: $tlsOk. The upgrade installer will fail its own prerequisite check without both."
        RiskLevel = if ($belowFloor) { "HIGH" } else { "MEDIUM" }
    })
    Write-Status "Prerequisite gap detected — .NET OK: $netOk, TLS 1.2 OK: $tlsOk" "WARN"
}
else {
    Write-Status "Prerequisites present (.NET Framework 4.7.2+, TLS 1.2 enabled)." "OK"
}

# =====================================================================
# CHECK 5 — Config-modification signal (heuristic)
# =====================================================================
Write-Status "Checking miiserver.exe.config for a possible manual-modification signal..." "INFO"
$configPath = Join-Path $binPath "miiserver.exe.config"
$configPossiblyModified = $false
$configLastWrite = $null
$exeLastWrite = $null
try {
    $configLastWrite = (Get-Item $configPath -ErrorAction Stop).LastWriteTime
    $exeLastWrite = (Get-Item $miiserverPath -ErrorAction Stop).LastWriteTime
    # Heuristic only: a config file written meaningfully AFTER the binary itself was
    # last updated is a signal (not proof) of a manual edit outside the normal
    # install/upgrade process, which always touches both together.
    if ($configLastWrite -gt $exeLastWrite.AddMinutes(10)) {
        $configPossiblyModified = $true
    }
}
catch {
    Write-Status "Could not read config/exe timestamps: $($_.Exception.Message)" "WARN"
}

if ($configPossiblyModified) {
    $findings.Add([PSCustomObject]@{
        Category = "ConfigModification"; Flag = "CONFIG_POSSIBLY_MODIFIED"
        Detail = "miiserver.exe.config was last written ($configLastWrite) meaningfully after miiserver.exe itself ($exeLastWrite) — a heuristic (not conclusive) signal of a manual edit, most commonly historical FIPS-mode Password Hash Sync guidance. If confirmed, pre-stage the binding-redirect fix (ConnectSyncUpgrade-B.md Fix 4) before any manual upgrade to 2.5.190.0/2.6.1.0-class releases, and expect auto-upgrade to skip this server on 2.6.3.0+ by design."
        RiskLevel = "MEDIUM"
    })
    Write-Status "Possible config modification signal detected — confirm manually before upgrading." "WARN"
}
else {
    Write-Status "No config-modification signal detected (heuristic check only — not a guarantee)." "OK"
}

# =====================================================================
# Report
# =====================================================================
Write-Host ""
Write-Host "=== Entra Connect Sync Version / EOL Readiness Summary ===" -ForegroundColor Cyan
Write-Status "Server: $env:COMPUTERNAME" "INFO"
Write-Status "Running version: $installedVersionRaw" $(if ($belowFloor) { "ERROR" } else { "OK" })

$highFindings = $findings | Where-Object { $_.RiskLevel -eq "HIGH" }
$medFindings  = $findings | Where-Object { $_.RiskLevel -eq "MEDIUM" }
Write-Status "$($highFindings.Count) HIGH-risk finding(s), $($medFindings.Count) MEDIUM-risk finding(s)." $(if ($highFindings.Count -gt 0) { "ERROR" } elseif ($medFindings.Count -gt 0) { "WARN" } else { "OK" })

if ($findings.Count -gt 0) {
    Write-Host ""
    Write-Host "--- Findings ---" -ForegroundColor Yellow
    $findings | Select-Object Category, Flag, RiskLevel, Detail | Format-Table -AutoSize -Wrap
}

Write-Host ""
Write-Host "KNOWN GAPS (not covered by this script — see .DESCRIPTION and ConnectSyncUpgrade-A.md):" -ForegroundColor DarkGray
Write-Host " - Whether the current release was actually published for auto-upgrade — only visible on the Microsoft Learn version-history page" -ForegroundColor DarkGray
Write-Host " - Config-modification detection is a timestamp heuristic, not a confirmed diff against a known-clean baseline" -ForegroundColor DarkGray
Write-Host " - Applying the upgrade or the config binding-redirect fix — this script is read-only, see ConnectSyncUpgrade-B.md for remediation steps" -ForegroundColor DarkGray
Write-Host " - Cloud-side Entra Connect Health telemetry — this is a local-host-only audit" -ForegroundColor DarkGray

$reportPath = Join-Path $OutputPath "ConnectSyncVersionAudit_$($env:COMPUTERNAME)_$(Get-Date -Format yyyyMMdd).csv"
[PSCustomObject]@{
    Hostname                = $env:COMPUTERNAME
    InstalledVersion         = $installedVersionRaw
    ServerConfigVersion       = $serverConfigVersion
    BelowMandatoryFloor       = $belowFloor
    DaysToMandatoryDeadline    = if ($installedVersion) { ($mandatoryDeadline - (Get-Date)).Days } else { $null }
    DotNetPrereqOk             = $netOk
    TLS12ClientOk              = $tlsOk
    ConfigPossiblyModified     = $configPossiblyModified
    ConfigLastWriteTime        = $configLastWrite
    ExeLastWriteTime           = $exeLastWrite
    HighRiskFindingCount       = $highFindings.Count
    MediumRiskFindingCount     = $medFindings.Count
    CollectedAt                = Get-Date
} | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8

$findingsPath = Join-Path $OutputPath "Findings.csv"
$findings | Export-Csv -Path $findingsPath -NoTypeInformation -Encoding UTF8

Write-Status "Summary report exported to $reportPath" "OK"
Write-Status "Findings exported to $findingsPath" "OK"
