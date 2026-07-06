<#
.SYNOPSIS
    Collects Windows certificate enrollment, chain, CRL, and CA reachability health for triage or escalation.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/CertificateServices-B.md and CertificateServices-A.md.
    Gathers, in one pass, everything the runbooks' triage and diagnosis steps ask for:
    - Certificates present in LocalMachine\My (subject, issuer, expiry, thumbprint)
    - Certificate chain build/validation status per cert (flags RevocationStatusUnknown etc.)
    - Recent auto-enrollment success/failure events (Event ID 19 / 6)
    - CRL Distribution Point URLs extracted from certs, with live HTTP reachability test
    - CA server RPC (135) and HTTPS (443) reachability (for on-prem CA / CEP-CES)
    - NTAuth store contents (required for domain/machine auth via certs)
    - certsvc service state (only meaningful when run ON the CA server)

    Produces a console summary with pass/fail per check and exports full detail to CSV,
    so the output can be pasted directly into the runbook's Escalation Evidence template.

    Does NOT cover:
    - Publishing new CRLs, restarting certsvc, or NTAuth store changes (that's CertificateServices-B.md Fix 1-5 — this script only detects)
    - NDES/SCEP connector-side diagnostics (run Intune's own NDES troubleshooting tools on the connector host)
    - Certificate template ACL auditing (requires AD PKI module — out of scope here)

.PARAMETER CAServerFQDN
    FQDN of the on-prem Certification Authority server to test RPC/HTTPS reachability against.
    Optional — if omitted, CA reachability checks are skipped.

.PARAMETER ExportPath
    Path for CSV export. Default: .\CertificateServicesDiagnostics-<timestamp>.csv

.EXAMPLE
    .\Get-CertificateServicesDiagnostics.ps1
    Runs client-side certificate and CRL checks only.

.EXAMPLE
    .\Get-CertificateServicesDiagnostics.ps1 -CAServerFQDN ca01.corp.contoso.com
    Also tests RPC/HTTPS reachability to the named CA server.

.NOTES
    Requires: Windows PowerShell 5.1+
    Run-as: Administrator recommended (NTAuth store enumeration and some event log reads need elevation)
    Safe: Fully read-only. No enrollment triggered, no CRL published, no service restarted.
    Tested on: Windows 10 21H2+, Windows 11, Windows Server 2016+ (client-side checks); Windows Server 2016+ for certsvc check.
#>

[CmdletBinding()]
param(
    [string]$CAServerFQDN,

    [string]$ExportPath
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

#region ─── Preflight ──────────────────────────────────────────────────────────
Write-Status "Get-CertificateServicesDiagnostics — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\CertificateServicesDiagnostics-$timestamp.csv"
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param([string]$Check, [string]$Status, [string]$Detail)
    $results.Add([PSCustomObject]@{
        Check     = $Check
        Status    = $Status
        Detail    = $Detail
        CheckedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    })
    Write-Status "$Check — $Detail" $Status
}
#endregion

#region ─── 1. Certificates in LocalMachine\My ──────────────────────────────────
$myCerts = @()
try {
    $myCerts = Get-ChildItem Cert:\LocalMachine\My -ErrorAction Stop
    if ($myCerts.Count -gt 0) {
        Add-Result "LocalMachineMyCount" "OK" "$($myCerts.Count) certificate(s) present"
        foreach ($cert in $myCerts) {
            $daysLeft = ($cert.NotAfter - (Get-Date)).Days
            if ($daysLeft -lt 0) {
                Add-Result "Cert-$($cert.Thumbprint.Substring(0,8))" "ERROR" "EXPIRED $($daysLeft * -1) day(s) ago — Subject: $($cert.Subject)"
            } elseif ($daysLeft -lt 14) {
                Add-Result "Cert-$($cert.Thumbprint.Substring(0,8))" "WARN" "Expires in $daysLeft day(s) — Subject: $($cert.Subject) — verify auto-enrollment will renew in time"
            } else {
                Add-Result "Cert-$($cert.Thumbprint.Substring(0,8))" "OK" "Valid, $daysLeft day(s) remaining — Subject: $($cert.Subject)"
            }
        }
    } else {
        Add-Result "LocalMachineMyCount" "WARN" "No certificates in LocalMachine\My — enrollment may not have run yet"
    }
} catch {
    Add-Result "LocalMachineMyCount" "ERROR" "Could not enumerate LocalMachine\My store: $_"
}
#endregion

#region ─── 2. Certificate chain validation ─────────────────────────────────────
foreach ($cert in $myCerts) {
    try {
        $chain = New-Object Security.Cryptography.X509Certificates.X509Chain
        $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::Online
        $built = $chain.Build($cert)
        $shortThumb = $cert.Thumbprint.Substring(0,8)

        if ($built) {
            Add-Result "Chain-$shortThumb" "OK" "Chain built successfully"
        } else {
            $statuses = ($chain.ChainStatus | ForEach-Object { $_.Status }) -join ', '
            if ($statuses -match "RevocationStatusUnknown|Revoked") {
                Add-Result "Chain-$shortThumb" "ERROR" "Chain issue: $statuses — likely CRL/OCSP unreachable or cert revoked"
            } else {
                Add-Result "Chain-$shortThumb" "WARN" "Chain issue: $statuses"
            }
        }
    } catch {
        Add-Result "Chain-$($cert.Thumbprint.Substring(0,8))" "WARN" "Could not build chain: $_"
    }
}
#endregion

#region ─── 3. Recent auto-enrollment events ────────────────────────────────────
try {
    $enrollEvents = Get-WinEvent -LogName "Application" -MaxEvents 200 -ErrorAction Stop |
        Where-Object { $_.Source -like "*AutoEnrollment*" -or $_.Source -like "*CertMgr*" }

    $successEvents = $enrollEvents | Where-Object { $_.Id -eq 19 }
    $failEvents    = $enrollEvents | Where-Object { $_.Id -eq 6 }

    if ($failEvents) {
        Add-Result "AutoEnrollmentFailures" "ERROR" "$($failEvents.Count) failure event(s) (ID 6) found — most recent: $($failEvents[0].TimeCreated) — $($failEvents[0].Message.Substring(0, [Math]::Min(150,$failEvents[0].Message.Length)))"
    } elseif ($successEvents) {
        Add-Result "AutoEnrollmentEvents" "OK" "$($successEvents.Count) success event(s) (ID 19) found, no recent failures"
    } else {
        Add-Result "AutoEnrollmentEvents" "INFO" "No auto-enrollment events found in last 200 Application log entries"
    }
} catch {
    Add-Result "AutoEnrollmentEvents" "WARN" "Could not query Application log: $_"
}
#endregion

#region ─── 4. CRL Distribution Point reachability ──────────────────────────────
$cdpUrls = New-Object System.Collections.Generic.HashSet[string]
foreach ($cert in $myCerts) {
    try {
        $cdpExt = $cert.Extensions | Where-Object { $_.Oid.FriendlyName -eq "CRL Distribution Points" }
        if ($cdpExt) {
            $formatted = $cdpExt.Format($true)
            $urls = [regex]::Matches($formatted, 'http[s]?://[^\s\]]+')
            foreach ($m in $urls) { [void]$cdpUrls.Add($m.Value) }
        }
    } catch {
        # non-fatal — some certs won't have CDP extension (e.g. root CAs)
    }
}

if ($cdpUrls.Count -gt 0) {
    foreach ($url in $cdpUrls) {
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
            if ($resp.StatusCode -eq 200) {
                Add-Result "CDP-$($url.Substring(0,[Math]::Min(40,$url.Length)))" "OK" "HTTP 200 — CRL reachable"
            } else {
                Add-Result "CDP-$($url.Substring(0,[Math]::Min(40,$url.Length)))" "WARN" "HTTP $($resp.StatusCode)"
            }
        } catch {
            Add-Result "CDP-$($url.Substring(0,[Math]::Min(40,$url.Length)))" "ERROR" "CRL unreachable: $($_.Exception.Message)"
        }
    }
} else {
    Add-Result "CDPUrls" "INFO" "No HTTP CRL Distribution Point URLs found on certs in LocalMachine\My (may use LDAP CDP only)"
}
#endregion

#region ─── 5. CA server reachability (optional) ───────────────────────────────
if ($CAServerFQDN) {
    try {
        $rpcTest = Test-NetConnection -ComputerName $CAServerFQDN -Port 135 -WarningAction SilentlyContinue -ErrorAction Stop
        if ($rpcTest.TcpTestSucceeded) {
            Add-Result "CA-RPC-135" "OK" "$CAServerFQDN reachable on TCP 135"
        } else {
            Add-Result "CA-RPC-135" "ERROR" "$CAServerFQDN NOT reachable on TCP 135 — firewall/routing issue for classic enrollment"
        }
    } catch {
        Add-Result "CA-RPC-135" "WARN" "Could not test RPC reachability: $_"
    }

    try {
        $httpsTest = Test-NetConnection -ComputerName $CAServerFQDN -Port 443 -WarningAction SilentlyContinue -ErrorAction Stop
        if ($httpsTest.TcpTestSucceeded) {
            Add-Result "CA-HTTPS-443" "OK" "$CAServerFQDN reachable on TCP 443 (CEP/CES)"
        } else {
            Add-Result "CA-HTTPS-443" "WARN" "$CAServerFQDN NOT reachable on TCP 443 — CEP/CES enrollment would fail if used"
        }
    } catch {
        Add-Result "CA-HTTPS-443" "WARN" "Could not test HTTPS reachability: $_"
    }
} else {
    Add-Result "CAReachability" "INFO" "No -CAServerFQDN supplied — skipped CA reachability tests"
}
#endregion

#region ─── 6. NTAuth store contents ─────────────────────────────────────────────
try {
    $ntAuthOutput = certutil -enterprise -store NTAuth 2>&1
    $subjects = $ntAuthOutput | Select-String "Subject:"
    if ($subjects) {
        Add-Result "NTAuthStore" "OK" "$($subjects.Count) CA(s) published to NTAuth store"
    } else {
        Add-Result "NTAuthStore" "WARN" "No CAs found in NTAuth store — smartcard/machine domain auth via certs will fail"
    }
} catch {
    Add-Result "NTAuthStore" "WARN" "Could not query NTAuth store (requires domain connectivity): $_"
}
#endregion

#region ─── 7. certsvc service state (only meaningful on the CA server) ────────
try {
    $certsvc = Get-Service -Name certsvc -ErrorAction Stop
    if ($certsvc.Status -eq 'Running') {
        Add-Result "CertSvc" "OK" "Running (this appears to be the CA server)"
    } else {
        Add-Result "CertSvc" "ERROR" "Status: $($certsvc.Status) — CA is not issuing/responding"
    }
} catch {
    Add-Result "CertSvc" "INFO" "certsvc service not found — this is expected on a non-CA client machine"
}
#endregion

#region ─── Summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── Certificate Services Diagnostics Summary ───────────" -ForegroundColor Cyan
$errorCount = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
$warnCount  = ($results | Where-Object { $_.Status -eq "WARN" }).Count

Write-Host "  Checks run   : $($results.Count)"
Write-Host "  Errors       : $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Warnings     : $warnCount" -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "Green" })

if ($errorCount -eq 0 -and $warnCount -eq 0) {
    Write-Host "  Overall: Certificate enrollment, chain, and CRL state look healthy." -ForegroundColor Green
} else {
    Write-Host "  Overall: Issues found — cross-reference against CertificateServices-B.md Fix 1-5." -ForegroundColor Yellow
}
Write-Host ""
#endregion

#region ─── Export ──────────────────────────────────────────────────────────────
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Exported → $ExportPath" "OK"
Write-Status "Done — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
