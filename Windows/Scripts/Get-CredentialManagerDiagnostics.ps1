<#
.SYNOPSIS
    Collects Windows Credential Manager, Kerberos ticket, and DPAPI health for triage or escalation.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/CredentialManager-B.md.
    Gathers, in one pass, everything the runbook's triage and diagnosis steps ask for:
    - VaultSvc (Credential Manager) and CryptSvc service state
    - Stored credentials via cmdkey /list, with duplicate-target detection
    - Kerberos ticket cache health (klist) — flags expired/missing TGT
    - DPAPI master key folder presence for the current/target user
    - Client-side LmCompatibilityLevel (NTLM downgrade risk)
    - NetLogon secure channel health (Test-ComputerSecureChannel)

    Produces a console summary with pass/fail per check and exports full detail to CSV,
    so the output can be pasted directly into the runbook's Escalation Evidence template.
    Credential values themselves are never captured — only target names, usernames, and
    persistence type are recorded, matching the runbook's "redact passwords" guidance.

    Does NOT cover:
    - Removing/rotating stored credentials (that's CredentialManager-B.md Fix 1-5 — this script only detects)
    - Azure AD / WAM broker token state (use dsregcmd /status for PRT/SSO issues — out of scope here)
    - Server-side account lockout source (check AD/Entra sign-in logs separately)

.PARAMETER TargetUser
    Username (SamAccountName, no domain prefix) to check DPAPI master key folder for.
    Defaults to the currently logged-on user.

.PARAMETER ExportPath
    Path for CSV export. Default: .\CredentialManagerDiagnostics-<timestamp>.csv

.EXAMPLE
    .\Get-CredentialManagerDiagnostics.ps1
    Runs the full sweep for the current user.

.EXAMPLE
    .\Get-CredentialManagerDiagnostics.ps1 -TargetUser jsmith
    Checks DPAPI master keys for a specific user profile (must be readable by the running account).

.NOTES
    Requires: Windows PowerShell 5.1+
    Run-as: Standard user for most checks; Administrator recommended for full DPAPI folder access
    Safe: Fully read-only. Never prints stored password values. No credential deletion or ticket purge performed.
    Tested on: Windows 10 21H2+, Windows 11, domain-joined and workgroup.
#>

[CmdletBinding()]
param(
    [string]$TargetUser = $env:USERNAME,

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
Write-Status "Get-CredentialManagerDiagnostics — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\CredentialManagerDiagnostics-$timestamp.csv"
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

$isDomainJoined = (Get-CimInstance Win32_ComputerSystem).PartOfDomain
#endregion

#region ─── 1. VaultSvc + CryptSvc service state ───────────────────────────────
try {
    $vaultSvc = Get-Service -Name VaultSvc -ErrorAction Stop
    if ($vaultSvc.Status -eq 'Running') {
        Add-Result "VaultSvc" "OK" "Running (StartType: $($vaultSvc.StartType))"
    } else {
        Add-Result "VaultSvc" "ERROR" "Status: $($vaultSvc.Status) — Credential Manager cannot store/retrieve credentials"
    }
} catch {
    Add-Result "VaultSvc" "ERROR" "Could not query VaultSvc: $_"
}

try {
    $cryptSvc = Get-Service -Name CryptSvc -ErrorAction Stop
    if ($cryptSvc.Status -eq 'Running') {
        Add-Result "CryptSvc" "OK" "Running (dependency of VaultSvc)"
    } else {
        Add-Result "CryptSvc" "ERROR" "Status: $($cryptSvc.Status) — VaultSvc depends on this; start CryptSvc first"
    }
} catch {
    Add-Result "CryptSvc" "WARN" "Could not query CryptSvc: $_"
}
#endregion

#region ─── 2. Stored credentials via cmdkey — duplicate-target detection ─────
try {
    $cmdkeyOutput = cmdkey /list 2>&1
    $targetLines  = $cmdkeyOutput | Select-String "Target:"

    if ($targetLines) {
        Add-Result "CmdkeyEntryCount" "INFO" "$($targetLines.Count) stored credential target(s) found"

        $targets = $targetLines | ForEach-Object { ($_ -replace ".*Target:\s+", "").Trim() }
        $dupGroups = $targets | Group-Object | Where-Object { $_.Count -gt 1 }
        if ($dupGroups) {
            foreach ($dup in $dupGroups) {
                Add-Result "CmdkeyDuplicate-$($dup.Name)" "WARN" "$($dup.Count) duplicate entries for same target — common cause of auth loops"
            }
        } else {
            Add-Result "CmdkeyDuplicates" "OK" "No duplicate target entries found"
        }

        # Flag Office/OneDrive/SharePoint entries specifically — most common lockout source
        $officeEntries = $targets | Where-Object { $_ -match "MicrosoftOffice|OneDrive|SharePoint" }
        if ($officeEntries) {
            Add-Result "OfficeCredentialEntries" "INFO" "$($officeEntries.Count) Office/OneDrive/SharePoint entr(ies) present — clear these first if troubleshooting post-password-change lockouts"
        }
    } else {
        Add-Result "CmdkeyEntryCount" "INFO" "No stored credentials found via cmdkey"
    }
} catch {
    Add-Result "CmdkeyList" "ERROR" "Could not run cmdkey /list: $_"
}
#endregion

#region ─── 3. Kerberos ticket cache health ─────────────────────────────────────
try {
    $klistOutput = klist 2>&1
    if ($klistOutput -match "Cached Tickets:\s*\(0\)" -or $klistOutput -match "No credentials are cached") {
        if ($isDomainJoined) {
            Add-Result "KerberosTickets" "WARN" "No cached Kerberos tickets on a domain-joined machine — expected only if never authenticated this session"
        } else {
            Add-Result "KerberosTickets" "INFO" "No cached tickets (workgroup machine — expected)"
        }
    } else {
        $tgtLine = $klistOutput | Select-String "krbtgt"
        if ($tgtLine) {
            Add-Result "KerberosTGT" "OK" "TGT present: $($tgtLine.Line.Trim())"
        } else {
            Add-Result "KerberosTGT" "WARN" "Service tickets present but no TGT found — re-authentication may be needed"
        }

        $expiredCount = ($klistOutput | Select-String "Expired|renew until").Count
        if ($expiredCount -gt 0) {
            Add-Result "KerberosExpiredCheck" "INFO" "$expiredCount ticket line(s) reference expiry/renewal windows — review manually with 'klist' for stale entries"
        }
    }
} catch {
    Add-Result "KerberosTickets" "WARN" "Could not run klist (may not be available on this OS edition): $_"
}
#endregion

#region ─── 4. DPAPI master key folder presence ─────────────────────────────────
try {
    $sid = $null
    try {
        if ($TargetUser -eq $env:USERNAME) {
            $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        } else {
            $ntAccount = New-Object System.Security.Principal.NTAccount($TargetUser)
            $sid = ($ntAccount.Translate([System.Security.Principal.SecurityIdentifier])).Value
        }
    } catch {
        Add-Result "DPAPI-SIDLookup" "WARN" "Could not resolve SID for '$TargetUser': $_"
    }

    if ($sid) {
        $dpapiPath = "$env:APPDATA\Microsoft\Protect\$sid"
        if (Test-Path $dpapiPath) {
            $keyFiles = Get-ChildItem $dpapiPath -ErrorAction SilentlyContinue
            if ($keyFiles -and $keyFiles.Count -gt 0) {
                Add-Result "DPAPIMasterKeys" "OK" "$($keyFiles.Count) DPAPI master key file(s) present for $TargetUser"
            } else {
                Add-Result "DPAPIMasterKeys" "ERROR" "DPAPI folder exists but is empty for $TargetUser — stored credentials are likely unreadable (profile migration issue)"
            }
        } else {
            Add-Result "DPAPIMasterKeys" "WARN" "DPAPI Protect folder not found for $TargetUser at expected path — checked: $dpapiPath (only readable for the profile owner or an admin)"
        }
    }
} catch {
    Add-Result "DPAPIMasterKeys" "WARN" "Could not check DPAPI master key folder: $_"
}
#endregion

#region ─── 5. LmCompatibilityLevel (NTLM downgrade risk) ──────────────────────
try {
    $lmLevel = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name LmCompatibilityLevel -ErrorAction Stop).LmCompatibilityLevel
    if ($lmLevel -ge 3) {
        Add-Result "LmCompatibilityLevel" "OK" "Level $lmLevel (NTLMv2 or higher enforced)"
    } else {
        Add-Result "LmCompatibilityLevel" "WARN" "Level $lmLevel — allows legacy NTLM/LM; if a target server requires NTLMv2-only (Level 5), auth will fail"
    }
} catch {
    Add-Result "LmCompatibilityLevel" "INFO" "LmCompatibilityLevel not explicitly set (using OS default)"
}
#endregion

#region ─── 6. NetLogon secure channel health ───────────────────────────────────
if ($isDomainJoined) {
    try {
        $scResult = Test-ComputerSecureChannel -ErrorAction Stop
        if ($scResult) {
            Add-Result "SecureChannel" "OK" "Computer secure channel to domain is healthy"
        } else {
            Add-Result "SecureChannel" "ERROR" "Secure channel test failed — machine account password/trust may be broken (Test-ComputerSecureChannel -Repair to fix, requires local admin)"
        }
    } catch {
        Add-Result "SecureChannel" "WARN" "Could not test secure channel: $_"
    }
} else {
    Add-Result "SecureChannel" "INFO" "Not domain-joined — secure channel check skipped"
}
#endregion

#region ─── Summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── Credential Manager Diagnostics Summary ─────────────" -ForegroundColor Cyan
$errorCount = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
$warnCount  = ($results | Where-Object { $_.Status -eq "WARN" }).Count

Write-Host "  Checks run   : $($results.Count)"
Write-Host "  Errors       : $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Warnings     : $warnCount" -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "Green" })

if ($errorCount -eq 0 -and $warnCount -eq 0) {
    Write-Host "  Overall: Credential Manager / Kerberos / DPAPI state looks healthy on this device." -ForegroundColor Green
} else {
    Write-Host "  Overall: Issues found — cross-reference against CredentialManager-B.md Fix 1-6." -ForegroundColor Yellow
}
Write-Host ""
#endregion

#region ─── Export ──────────────────────────────────────────────────────────────
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Exported → $ExportPath" "OK"
Write-Status "Done — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
