<#
.SYNOPSIS
    Device-local diagnostic for Outlook desktop client connectivity issues —
    identifies classic vs. New Outlook, checks profile/OST state, Autodiscover
    DNS, cached credentials, and COM add-in load state.

.DESCRIPTION
    Run ON the affected device (as the affected user, or local admin). Checks,
    in dependency order:
      1. Which Outlook client is present/in use (classic Win32 vs. New Outlook
         WebView2 package) — the two share no troubleshooting mechanisms, so
         this is evaluated first and gates which later checks are meaningful.
      2. Classic Outlook profile enumeration (registry).
      3. .ost file presence, size, and freshness (Cached Exchange Mode).
      4. Autodiscover CNAME resolution for a supplied SMTP domain.
      5. Windows Credential Manager — lists Office/Outlook-related cached
         credential entries by name only (never reads or exports secret
         material).
      6. Installed COM add-ins and their LoadBehavior (classic Outlook only).
      7. New Outlook cache folder presence (Olk, OneAuth) — informational,
         used to confirm whether Playbook 6 (cache clear) has already run.
      8. Optional: pulls the user's recent Microsoft 365 sign-in events via
         Microsoft Graph to check for Conditional Access interference.

    This is intentionally NOT a fleet-wide script — Outlook client issues are
    device/profile-specific by nature (a corrupt local .ost or a stale local
    credential cache doesn't affect other machines the same user signs into).
    For tenant-wide mail flow, licensing, or CA policy audits, see the other
    scripts in this folder and in Security/ConditionalAccess/Scripts.

    Analysis flags applied:
      NEW_OUTLOOK_DETECTED     - Microsoft.OutlookForWindows package present;
                                  classic-Outlook-specific fixes (OST rebuild,
                                  Credential Manager, COM add-ins, profile
                                  recreation) do not apply.
      NO_CLASSIC_PROFILE       - Classic Outlook installed but no profile found
                                  under the Profiles registry key.
      OST_STALE                - .ost LastWriteTime is more than 24 hours old
                                  despite the file existing (possible sync
                                  stall — not necessarily corruption).
      OST_ZERO_BYTES           - .ost file exists but is 0 bytes — corrupted or
                                  a rebuild that never completed.
      OST_NOT_FOUND            - No .ost file found for a classic Outlook
                                  install — either Online mode is in use, or no
                                  profile has fully initialized yet.
      AUTODISCOVER_CNAME_MISSING - No CNAME record found for the supplied
                                  domain's autodiscover subdomain.
      AUTODISCOVER_CNAME_UNEXPECTED - CNAME resolves but not to an
                                  outlook.com / *.outlook.com target — possible
                                  hybrid misconfiguration or third-party hijack;
                                  requires manual judgment, not auto-flagged as
                                  wrong.
      STALE_CREDENTIAL_ENTRIES - One or more Office/Outlook Credential Manager
                                  entries found — informational; presence alone
                                  isn't a problem, but is the first thing to
                                  clear if an auth loop is reported.
      COM_ADDIN_FOUND           - One or more third-party COM add-ins with
                                  LoadBehavior 3 (loads at startup) detected —
                                  informational shortlist for Safe Mode triage.
      CA_SIGNIN_FAILURE         - (Optional Graph check) A recent sign-in for
                                  this user against Office apps shows
                                  ConditionalAccessStatus = failure.

    Read-only. Makes no changes to profiles, credentials, the .ost file, or
    add-in state — this is a diagnostic tool. Remediation steps are documented
    in M365/Exchange/Outlook-Client-A.md and Outlook-Client-B.md.

.PARAMETER SmtpDomain
    The SMTP domain to test Autodiscover DNS resolution against (e.g.
    contoso.com). If omitted, the Autodiscover DNS check is skipped.

.PARAMETER CheckSignIns
    Switch. If set, also queries Microsoft Graph for this user's recent
    Office sign-in events to check for Conditional Access interference.
    Requires AuditLog.Read.All and an authenticated Graph session.

.PARAMETER UserPrincipalName
    UPN to check sign-in logs for, when -CheckSignIns is used. If omitted,
    defaults to the currently logged-on user's UPN where derivable.

.PARAMETER OutputPath
    Path for the evidence/report text file. Default:
    .\OutlookClient-Diagnostics-<timestamp>.txt

.EXAMPLE
    .\Get-OutlookClientHealth.ps1 -SmtpDomain "contoso.com"

    Runs the local diagnostic chain and tests Autodiscover DNS for contoso.com.

.EXAMPLE
    .\Get-OutlookClientHealth.ps1 -SmtpDomain "contoso.com" -CheckSignIns -UserPrincipalName "alice@contoso.com"

    Same as above, plus a live Conditional Access sign-in check via Graph.

.NOTES
    Requires: Run in the affected user's Windows session for profile/OST/
              credential checks to reflect that user's state. Local admin not
              required for the core diagnostic chain.
              Microsoft.Graph PowerShell SDK required only if -CheckSignIns is used.
    Scopes needed (only for -CheckSignIns): AuditLog.Read.All
    Safe: Read-only — no profiles, credentials, .ost files, or add-ins are modified
    Cross-references: M365/Exchange/Outlook-Client-A.md (Validation Steps 1-8,
                       Dependency Stack), Outlook-Client-B.md (Triage, Diagnosis
                       Steps 1-5, Fix 1-7)
#>

[CmdletBinding()]
param(
    [string]$SmtpDomain = "",

    [switch]$CheckSignIns,

    [string]$UserPrincipalName = "",

    [string]$OutputPath = ".\OutlookClient-Diagnostics-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
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

Add-Report "=== Outlook Client Diagnostics — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
Add-Report "Computer: $env:COMPUTERNAME | User: $env:USERNAME"
Add-Report ""

# --- Step 1: Which client? ---
Write-Status "Step 1: Checking for New Outlook (Microsoft.OutlookForWindows)..." "INFO"
Add-Report "--- Client Detection ---"
$newOutlookPkg = Get-AppxPackage -Name "Microsoft.OutlookForWindows" -EA SilentlyContinue
if ($newOutlookPkg) {
    $flags.Add("NEW_OUTLOOK_DETECTED")
    Add-Report "New Outlook package: FOUND — Version $($newOutlookPkg.Version)"
    Write-Status "New Outlook is installed (Version $($newOutlookPkg.Version)). Classic-Outlook-specific checks below (OST, Credential Manager, COM add-ins, profiles) only apply if the user is actually toggled to classic mode." "WARN"
} else {
    Add-Report "New Outlook package: not found"
    Write-Status "New Outlook not installed — assuming classic Outlook." "OK"
}

$classicVersionKey = Get-ItemProperty "HKCU:\Software\Microsoft\Office\16.0\Outlook\Options\General" -EA SilentlyContinue
if ($classicVersionKey) {
    Add-Report "Classic Outlook (Office 16.0) registry hive present."
} else {
    Add-Report "Classic Outlook (Office 16.0) registry hive not found under HKCU."
}

# --- Step 2: Classic Outlook profiles ---
Write-Status "`nStep 2: Enumerating classic Outlook profiles..." "INFO"
Add-Report "`n--- Classic Outlook Profiles ---"
$profilesPath = "HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles"
if (Test-Path $profilesPath) {
    $profiles = Get-ChildItem $profilesPath -EA SilentlyContinue
    if ($profiles) {
        foreach ($p in $profiles) { Add-Report "Profile: $($p.PSChildName)" }
        Write-Status "$($profiles.Count) profile(s) found." "OK"
    } else {
        $flags.Add("NO_CLASSIC_PROFILE")
        Add-Report "Profiles key exists but is empty."
        Write-Status "No profiles found under the Profiles key." "WARN"
    }
} else {
    $flags.Add("NO_CLASSIC_PROFILE")
    Add-Report "Profiles registry key not found."
    Write-Status "Profiles key not found — classic Outlook may never have been configured on this machine/user context." "WARN"
}

# --- Step 3: OST file state ---
Write-Status "`nStep 3: Checking .ost file(s)..." "INFO"
Add-Report "`n--- OST Files ---"
$ostFiles = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Outlook\*.ost" -EA SilentlyContinue
if ($ostFiles) {
    foreach ($ost in $ostFiles) {
        $ageHours = [math]::Round(((Get-Date) - $ost.LastWriteTime).TotalHours, 1)
        $sizeMB = [math]::Round($ost.Length / 1MB, 1)
        Add-Report "File: $($ost.Name) | SizeMB: $sizeMB | LastWriteTime: $($ost.LastWriteTime) | AgeHours: $ageHours"

        if ($ost.Length -eq 0) {
            $flags.Add("OST_ZERO_BYTES")
            Write-Status "$($ost.Name): 0 bytes — corrupted or an incomplete rebuild." "ERROR"
        } elseif ($ageHours -gt 24) {
            $flags.Add("OST_STALE")
            Write-Status "$($ost.Name): last written $ageHours hours ago — possible sync stall." "WARN"
        } else {
            Write-Status "$($ost.Name): $sizeMB MB, last synced $ageHours hour(s) ago — looks active." "OK"
        }
    }
} else {
    $flags.Add("OST_NOT_FOUND")
    Add-Report "No .ost files found."
    Write-Status "No .ost file found — either Online mode is in use, New Outlook is the active client, or no profile has synced yet." "WARN"
}

# --- Step 4: Autodiscover DNS ---
if ($SmtpDomain) {
    Write-Status "`nStep 4: Testing Autodiscover CNAME for '$SmtpDomain'..." "INFO"
    Add-Report "`n--- Autodiscover DNS ($SmtpDomain) ---"
    try {
        $cname = Resolve-DnsName -Name "autodiscover.$SmtpDomain" -Type CNAME -EA Stop
        $target = $cname.NameHost
        Add-Report "autodiscover.$SmtpDomain CNAME -> $target"
        if ($target -match "outlook\.com$") {
            Write-Status "CNAME resolves to $target — looks correct for Exchange Online." "OK"
        } else {
            $flags.Add("AUTODISCOVER_CNAME_UNEXPECTED")
            Write-Status "CNAME resolves to $target — not an outlook.com target. Could be a valid hybrid/on-prem endpoint, or a third-party hijack. Manual review needed." "WARN"
        }
    } catch {
        $flags.Add("AUTODISCOVER_CNAME_MISSING")
        Add-Report "CNAME resolution failed: $($_.Exception.Message)"
        Write-Status "No CNAME found for autodiscover.$SmtpDomain — profile creation will rely on Autodiscover v2 / root domain fallback only." "WARN"
    }
} else {
    Write-Status "`nStep 4: Skipped (no -SmtpDomain supplied)." "INFO"
    Add-Report "`n--- Autodiscover DNS ---`nSkipped - no -SmtpDomain parameter supplied."
}

# --- Step 5: Credential Manager entries (names only) ---
Write-Status "`nStep 5: Listing Office/Outlook Credential Manager entries..." "INFO"
Add-Report "`n--- Credential Manager (Office/Outlook entries, names only) ---"
try {
    $cmdkeyOutput = & cmdkey /list 2>&1 | Out-String
    $officeEntries = [regex]::Matches($cmdkeyOutput, "Target:\s*(.*(?:MicrosoftOffice|SSPI|OUTLOOK).*)") |
        ForEach-Object { $_.Groups[1].Value.Trim() }
    if ($officeEntries -and $officeEntries.Count -gt 0) {
        $flags.Add("STALE_CREDENTIAL_ENTRIES")
        foreach ($e in $officeEntries) { Add-Report "Entry: $e" }
        Write-Status "$($officeEntries.Count) Office/Outlook credential entr(y/ies) found — first thing to clear if an auth loop is reported." "INFO"
    } else {
        Add-Report "No Office/Outlook Credential Manager entries found."
        Write-Status "No Office/Outlook credential entries found." "OK"
    }
} catch {
    Add-Report "cmdkey enumeration failed: $($_.Exception.Message)"
    Write-Status "Could not enumerate Credential Manager: $($_.Exception.Message)" "WARN"
}

# --- Step 6: COM add-ins ---
Write-Status "`nStep 6: Enumerating COM add-ins..." "INFO"
Add-Report "`n--- COM Add-ins ---"
$addinsPath = "HKCU:\Software\Microsoft\Office\Outlook\Addins"
if (Test-Path $addinsPath) {
    $addins = Get-ChildItem $addinsPath -EA SilentlyContinue
    if ($addins) {
        $startupAddins = 0
        foreach ($a in $addins) {
            $props = Get-ItemProperty $a.PSPath -EA SilentlyContinue
            $loadBehavior = $props.LoadBehavior
            $friendlyName = $props.FriendlyName
            Add-Report "Addin: $($a.PSChildName) | LoadBehavior: $loadBehavior | FriendlyName: $friendlyName"
            if ($loadBehavior -eq 3) { $startupAddins++ }
        }
        if ($startupAddins -gt 0) {
            $flags.Add("COM_ADDIN_FOUND")
            Write-Status "$startupAddins add-in(s) configured to load at startup (LoadBehavior=3) — shortlist for Safe Mode triage if a hang/crash is reported." "INFO"
        } else {
            Write-Status "No add-ins currently set to load at startup." "OK"
        }
    } else {
        Add-Report "Addins key present but empty."
        Write-Status "No COM add-ins registered." "OK"
    }
} else {
    Add-Report "No Addins registry key found."
    Write-Status "No COM add-ins registry key found." "OK"
}

# --- Step 7: New Outlook cache folders (informational) ---
Write-Status "`nStep 7: Checking New Outlook cache folder state..." "INFO"
Add-Report "`n--- New Outlook Cache Folders ---"
foreach ($folder in @("Olk", "OneAuth")) {
    $path = "$env:LOCALAPPDATA\Microsoft\$folder"
    if (Test-Path $path) {
        $lastWrite = (Get-Item $path).LastWriteTime
        Add-Report "$folder : present, last modified $lastWrite"
    } else {
        Add-Report "$folder : not present"
    }
}
Write-Status "Cache folder check complete (informational only)." "OK"

# --- Step 8 (optional): Conditional Access sign-in check ---
if ($CheckSignIns) {
    Write-Status "`nStep 8: Checking recent Office sign-ins for Conditional Access interference..." "INFO"
    Add-Report "`n--- Conditional Access Sign-In Check (Graph) ---"
    try {
        if (-not (Get-MgContext)) {
            Connect-MgGraph -Scopes "AuditLog.Read.All" -NoWelcome
        }
        $upn = if ($UserPrincipalName) { $UserPrincipalName } else { "$env:USERNAME@$env:USERDNSDOMAIN" }
        $signIns = Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$upn' and appDisplayName eq 'Microsoft Office'" -Top 10 -EA Stop
        if ($signIns) {
            $failures = 0
            foreach ($s in $signIns) {
                Add-Report "$($s.CreatedDateTime) | Status: $($s.Status.ErrorCode) | CA: $($s.ConditionalAccessStatus) | ClientApp: $($s.ClientAppUsed)"
                if ($s.ConditionalAccessStatus -eq "failure") { $failures++ }
            }
            if ($failures -gt 0) {
                $flags.Add("CA_SIGNIN_FAILURE")
                Write-Status "$failures of the last $($signIns.Count) Office sign-in(s) show a Conditional Access failure. Cross-check ClientAppUsed for legacy-auth attempts." "ERROR"
            } else {
                Write-Status "No Conditional Access failures in the last $($signIns.Count) Office sign-in(s)." "OK"
            }
        } else {
            Add-Report "No recent Office sign-in events found for $upn."
            Write-Status "No recent Office sign-in events found for $upn." "WARN"
        }
    } catch {
        Add-Report "Graph sign-in query failed: $($_.Exception.Message)"
        Write-Status "Graph query failed: $($_.Exception.Message)" "WARN"
    }
} else {
    Write-Status "`nStep 8: Skipped (-CheckSignIns not specified)." "INFO"
}

# --- Summary ---
Write-Host "`n=== Outlook Client Diagnostic Summary ===" -ForegroundColor Cyan
if ($flags.Count -eq 0) {
    Write-Status "No issues flagged across all local checks." "OK"
    Add-Report "`n--- Summary --- `nFlags: (none)"
} else {
    Write-Status "Flags raised: $($flags -join ', ')" "WARN"
    Add-Report "`n--- Summary --- `nFlags: $($flags -join '|')"
}

$reportLines | Out-File -FilePath $OutputPath -Encoding UTF8
Write-Status "`nFull report written to: $OutputPath" "OK"
Write-Status "Cross-reference flags against M365/Exchange/Outlook-Client-A.md Symptom -> Cause Map and Outlook-Client-B.md Fix 1-7." "INFO"
