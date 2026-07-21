<#
.SYNOPSIS
    Audits an AD CS server for exposure to NTLM relay attacks against its
    HTTP(S) enrollment endpoints (Certificate Authority Web Enrollment /
    Certificate Enrollment Web Service) — the class of misconfiguration
    commonly referenced as ESC8, exploitable via PetitPotam and related
    coercion techniques.

.DESCRIPTION
    Checks, on the local machine:
      - Whether the ADCS-Web-Enrollment and/or ADCS-Enroll-Web-Svc roles are
        installed
      - Whether the relevant IIS sites are reachable over HTTP vs. HTTPS
      - Current NTLM restriction posture (RestrictSendingNTLMTraffic)
      - Which certificate templates in the forest carry a client-authentication
        EKU (the payoff an attacker is after via a successful relay)

    This script does NOT read the Extended Protection for Authentication (EPA)
    setting directly — that value lives in IIS's applicationHost.config /
    web.config and its exact read path varies by IIS version and whether the
    WebAdministration module is available. Where possible it attempts a
    best-effort read via the WebAdministration module; where not available, it
    explicitly flags EPA as requiring manual verification in IIS Manager
    rather than guessing or reporting a false "OK".

    This script does NOT change any AD CS, IIS, or registry setting. Read-only.
    Exports a consolidated CSV.

.PARAMETER SiteName
    IIS site name to check for CertSrv/CES virtual directories. Default:
    "Default Web Site" (the standard AD CS Web Enrollment install location).

.PARAMETER ExportPath
    Path for the CSV export. Default: $env:TEMP\NTLMRelayADCSAudit_<timestamp>.csv

.EXAMPLE
    .\Get-NTLMRelayADCSAudit.ps1
    # Audits the local AD CS server using default IIS site assumptions

.EXAMPLE
    .\Get-NTLMRelayADCSAudit.ps1 -SiteName "Custom CA Site"
    # Audits against a non-default IIS site name

.NOTES
    Requires: Run locally on the AD CS server; ActiveDirectory module (RSAT)
              for the certificate template inventory portion; WebAdministration
              module (present on IIS-hosting servers) for best-effort EPA reads
    Run as: Local administrator on the AD CS server
    Safe/Unsafe: READ-ONLY — does not modify EPA, SSL requirements, NTLM
                 restriction, or any certificate template
    Tested against: Windows Server 2019 / 2022 hosting AD CS Web
                    Enrollment/CES roles
    Limitation: EPA's exact configured value cannot always be read reliably
                via PowerShell across every IIS/AD CS version combination —
                this script's EPA section is best-effort and explicitly flags
                when manual verification in IIS Manager is required rather
                than asserting a value it isn't confident in.
#>

[CmdletBinding()]
param(
    [string] $SiteName = "Default Web Site",
    [string] $ExportPath = "$env:TEMP\NTLMRelayADCSAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"     { "Green"  }
        "WARN"   { "Yellow" }
        "ERROR"  { "Red"    }
        "HEADER" { "Cyan"   }
        default  { "White"  }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

Write-Status "NTLM Relay to AD CS (PetitPotam / ESC8) Exposure Audit" -Status "HEADER"
Write-Status "Run time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Status "INFO"
Write-Status "Target site: $SiteName`n" -Status "INFO"

$results = @()

#region --- AD CS Roles ---

Write-Status "=== AD CS Web Enrollment / CES Role Check ===" -Status "HEADER"

try {
    $roles = Get-WindowsFeature -Name ADCS-Web-Enrollment, ADCS-Enroll-Web-Svc -ErrorAction Stop
    $webEnrollmentInstalled = ($roles | Where-Object { $_.Name -eq "ADCS-Web-Enrollment" }).InstallState -eq "Installed"
    $cesInstalled           = ($roles | Where-Object { $_.Name -eq "ADCS-Enroll-Web-Svc" }).InstallState -eq "Installed"

    Write-Status "  Certificate Authority Web Enrollment: $(if ($webEnrollmentInstalled) { 'INSTALLED' } else { 'Not installed' })" -Status $(if ($webEnrollmentInstalled) { "WARN" } else { "OK" })
    Write-Status "  Certificate Enrollment Web Service (CES): $(if ($cesInstalled) { 'INSTALLED' } else { 'Not installed' })" -Status $(if ($cesInstalled) { "WARN" } else { "OK" })

    $results += [PSCustomObject]@{
        Category = "Roles"; Item = "ADCS-Web-Enrollment"
        Value = if ($webEnrollmentInstalled) { "Installed" } else { "Not installed" }
        Status = if ($webEnrollmentInstalled) { "WARN" } else { "OK" }
        Note = "If installed, this is a potential ESC8 relay target requiring EPA verification"
    }
    $results += [PSCustomObject]@{
        Category = "Roles"; Item = "ADCS-Enroll-Web-Svc"
        Value = if ($cesInstalled) { "Installed" } else { "Not installed" }
        Status = if ($cesInstalled) { "WARN" } else { "OK" }
        Note = "If installed, this is a potential ESC8 relay target requiring EPA verification"
    }

    $anyRoleInstalled = $webEnrollmentInstalled -or $cesInstalled
    if (-not $anyRoleInstalled) {
        Write-Status "  Neither role installed on this server — ESC8 does not apply here directly." -Status "OK"
        Write-Status "  (Confirm no OTHER server in the environment hosts these roles before closing out.)" -Status "INFO"
    }
} catch {
    Write-Status "  Could not query Windows Features: $_" -Status "ERROR"
    $anyRoleInstalled = $true  # fail open to still attempt subsequent checks
    $results += [PSCustomObject]@{ Category = "Roles"; Item = "Query"; Value = "FAILED"; Status = "ERROR"; Note = "$_" }
}

#endregion

#region --- HTTP / HTTPS Reachability ---

if ($anyRoleInstalled) {
    Write-Status "`n=== HTTP / HTTPS Reachability ===" -Status "HEADER"
    try {
        $http = Test-NetConnection -ComputerName "localhost" -Port 80 -WarningAction SilentlyContinue
        $https = Test-NetConnection -ComputerName "localhost" -Port 443 -WarningAction SilentlyContinue

        $httpStatus = if ($http.TcpTestSucceeded) { "WARN" } else { "OK" }
        Write-Status "  Port 80 (HTTP) reachable: $($http.TcpTestSucceeded)" -Status $httpStatus
        Write-Status "  Port 443 (HTTPS) reachable: $($https.TcpTestSucceeded)" -Status "INFO"

        $results += [PSCustomObject]@{
            Category = "Connectivity"; Item = "HTTP (port 80)"
            Value = $http.TcpTestSucceeded; Status = $httpStatus
            Note = if ($http.TcpTestSucceeded) { "HTTP reachable - no TLS session for EPA to bind to, exploitable regardless of EPA config; require SSL" } else { "HTTP not reachable - good" }
        }
        $results += [PSCustomObject]@{
            Category = "Connectivity"; Item = "HTTPS (port 443)"
            Value = $https.TcpTestSucceeded; Status = "INFO"
            Note = "HTTPS reachability alone is not sufficient - EPA must still be verified as Required"
        }
    } catch {
        Write-Status "  Could not test connectivity: $_" -Status "WARN"
        $results += [PSCustomObject]@{ Category = "Connectivity"; Item = "Test"; Value = "FAILED"; Status = "WARN"; Note = "$_" }
    }

    #endregion

    #region --- Best-Effort EPA Check ---

    Write-Status "`n=== Extended Protection for Authentication (best-effort) ===" -Status "HEADER"
    $epaChecked = $false
    if (Get-Module -ListAvailable -Name WebAdministration) {
        try {
            Import-Module WebAdministration -ErrorAction Stop
            $paths = @("IIS:\Sites\$SiteName\CertSrv", "IIS:\Sites\$SiteName\CertSrv\CES_Kerberos")
            foreach ($path in $paths) {
                if (Test-Path $path) {
                    try {
                        $epa = Get-WebConfiguration -Filter "system.webServer/security/authentication/windowsAuthentication/extendedProtection" -PSPath $path -ErrorAction Stop
                        $epaValue = $epa.TokenChecking
                        $epaStatus = if ($epaValue -eq "Require") { "OK" } else { "ERROR" }
                        Write-Status "  $path : TokenChecking = $epaValue" -Status $epaStatus
                        $results += [PSCustomObject]@{
                            Category = "EPA"; Item = $path; Value = $epaValue; Status = $epaStatus
                            Note = if ($epaValue -eq "Require") { "EPA required - primary mitigation in place" } else { "EPA NOT required - PRIMARY MITIGATION MISSING, see Fix 1 in the runbook" }
                        }
                        $epaChecked = $true
                    } catch {
                        Write-Status "  Could not read EPA setting for $path : $_" -Status "WARN"
                    }
                }
            }
        } catch {
            Write-Status "  WebAdministration module present but could not be imported: $_" -Status "WARN"
        }
    }
    if (-not $epaChecked) {
        Write-Status "  Could not automatically confirm EPA state. MANUAL VERIFICATION REQUIRED:" -Status "WARN"
        Write-Status "  IIS Manager > $SiteName > CertSrv (and CES site) > Authentication >" -Status "WARN"
        Write-Status "  Windows Authentication > Advanced Settings > Extended Protection" -Status "WARN"
        $results += [PSCustomObject]@{
            Category = "EPA"; Item = "AutoDetect"; Value = "Unavailable"; Status = "WARN"
            Note = "Manual verification required in IIS Manager - this script does not assert an EPA value it cannot confirm"
        }
    }

    #endregion
}

#region --- NTLM Restriction Posture ---

Write-Status "`n=== NTLM Restriction Posture ===" -Status "HEADER"
try {
    $ntlmRestrict = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0" -Name "RestrictSendingNTLMTraffic" -ErrorAction SilentlyContinue
    $ntlmValue = if ($ntlmRestrict) { $ntlmRestrict.RestrictSendingNTLMTraffic } else { $null }
    $ntlmStatus = if ($null -eq $ntlmValue -or $ntlmValue -eq 0) { "WARN" } else { "OK" }

    Write-Status "  RestrictSendingNTLMTraffic: $(if ($null -ne $ntlmValue) { $ntlmValue } else { 'Not configured (NTLM fully permitted)' })" -Status $ntlmStatus

    $results += [PSCustomObject]@{
        Category = "NTLMRestriction"; Item = "RestrictSendingNTLMTraffic"
        Value = if ($null -ne $ntlmValue) { $ntlmValue } else { "Not configured" }
        Status = $ntlmStatus
        Note = "Defense-in-depth only - EPA (Fix 1) is the primary control regardless of this value"
    }
} catch {
    Write-Status "  Could not read NTLM restriction registry value: $_" -Status "WARN"
    $results += [PSCustomObject]@{ Category = "NTLMRestriction"; Item = "Query"; Value = "FAILED"; Status = "WARN"; Note = "$_" }
}

#endregion

#region --- Certificate Template Exposure ---

Write-Status "`n=== Client-Authentication-Capable Certificate Templates ===" -Status "HEADER"
if (Get-Module -ListAvailable -Name ActiveDirectory) {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $templates = Get-ADObject -SearchBase (Get-ADRootDSE).ConfigurationNamingContext -LDAPFilter `
            "(&(objectClass=pKICertificateTemplate)(pKIExtendedKeyUsage=1.3.6.1.5.5.7.3.2))" -Properties Name -ErrorAction Stop

        if ($templates) {
            Write-Status "  $($templates.Count) client-authentication-capable template(s) found:" -Status "WARN"
            $templates | ForEach-Object {
                Write-Host "    - $($_.Name)"
                $results += [PSCustomObject]@{
                    Category = "CertTemplate"; Item = $_.Name; Value = "Client-auth capable"; Status = "INFO"
                    Note = "Review enrollment ACL via certtmpl.msc - broad grants raise ESC8 impact severity"
                }
            }
        } else {
            Write-Status "  No client-authentication-capable templates found." -Status "OK"
        }
    } catch {
        Write-Status "  Could not query certificate templates: $_" -Status "WARN"
        $results += [PSCustomObject]@{ Category = "CertTemplate"; Item = "Query"; Value = "FAILED"; Status = "WARN"; Note = "$_" }
    }
} else {
    Write-Status "  ActiveDirectory module not available — skipping template inventory." -Status "WARN"
}

#endregion

#region --- Export & Summary ---

$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8

Write-Status "`n=== Summary ===" -Status "HEADER"
$errorCount = ($results | Where-Object Status -eq "ERROR").Count
$warnCount  = ($results | Where-Object Status -eq "WARN").Count
Write-Host "  Total checks run : $($results.Count)"
Write-Host "  Errors           : $errorCount"
Write-Host "  Warnings         : $warnCount"
Write-Host "  Report saved to  : $ExportPath"

if ($errorCount -gt 0) {
    Write-Status "EPA confirmed NOT required - this server is exposed to NTLM relay (ESC8). Apply Fix 1 immediately." -Status "ERROR"
} elseif ($warnCount -gt 0) {
    Write-Status "Potential exposure found or EPA could not be auto-confirmed - review the CSV and verify EPA manually in IIS Manager." -Status "WARN"
} else {
    Write-Status "No exposure indicators found on this server." -Status "OK"
}

#endregion
