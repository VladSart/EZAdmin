<#
.SYNOPSIS
    Collects Windows user profile registry state, disk space, and temp-profile indicators for triage or escalation.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/UserProfile-B.md and UserProfile-A.md.
    Gathers, in one pass, everything the runbook's triage and diagnosis steps ask for:
    - Whether the CURRENT session is running under a temp profile (C:\Users\TEMP)
    - SID resolution and ProfileList registry state for a target user (ProfileImagePath, State, RefCount)
    - Detection of duplicate SID/.bak registry key pairs (the most common temp-profile root cause)
    - NTUSER.DAT presence at the profile path
    - Recent User Profile Service (Microsoft-Windows-User Profiles Service) event log entries
    - C: drive free space (profile load failures below ~500MB free)

    Produces a console summary with pass/fail per check and exports full detail to CSV, so the
    output can be pasted directly into the runbook's Escalation Evidence template. Interprets
    ProfileList State values (0=normal, 4=loaded/locked, 256=mandatory) per the runbook's Learning
    Pointers so an engineer doesn't have to look them up mid-incident.

    Does NOT cover:
    - Actually deleting/renaming registry keys or profile folders (that's Fix 1-5 in UserProfile-B.md — this script only detects)
    - Roaming profile share-side troubleshooting (file server SMB connectivity — check separately per the runbook's final Learning Pointer)
    - USMT-based profile migration (see USMT documentation referenced in the runbook)

.PARAMETER TargetUser
    Username (SamAccountName, no domain prefix) to check ProfileList registry state for.
    Defaults to the currently logged-on user.

.PARAMETER ExportPath
    Path for CSV export. Default: .\UserProfileDiagnostics-<timestamp>.csv

.EXAMPLE
    .\Get-UserProfileDiagnostics.ps1
    Runs the full sweep for the current user/session.

.EXAMPLE
    .\Get-UserProfileDiagnostics.ps1 -TargetUser jsmith
    Checks ProfileList registry state for a specific user (must be run as an account with registry read access — typically local admin).

.NOTES
    Requires: Windows PowerShell 5.1+
    Run-as: Administrator recommended — HKLM\...\ProfileList and other users' profile paths require elevated access
    Safe: Fully read-only. No registry keys, profile folders, or services are modified.
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
Write-Status "Get-UserProfileDiagnostics — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\UserProfileDiagnostics-$timestamp.csv"
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

$regBase = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
#endregion

#region ─── 1. Current session temp-profile check ──────────────────────────────
try {
    $currentProfilePath = $env:USERPROFILE
    if ($currentProfilePath -match '\\TEMP(\\|$)|\\TEMP\.') {
        Add-Result "CurrentSessionProfile" "ERROR" "Current session is running under a TEMP profile ($currentProfilePath) — settings will not persist"
    } else {
        Add-Result "CurrentSessionProfile" "OK" "Current session profile path: $currentProfilePath"
    }
} catch {
    Add-Result "CurrentSessionProfile" "WARN" "Could not read `$env:USERPROFILE : $_"
}
#endregion

#region ─── 2. SID resolution + ProfileList registry state for target user ──────
$sid = $null
try {
    $ntAccount = New-Object System.Security.Principal.NTAccount($TargetUser)
    $sid = ($ntAccount.Translate([System.Security.Principal.SecurityIdentifier])).Value
    Add-Result "SIDResolution" "OK" "$TargetUser resolved to $sid"
} catch {
    Add-Result "SIDResolution" "ERROR" "Could not resolve SID for '$TargetUser': $_"
}

$profileImagePath = $null
if ($sid) {
    $mainKeyPath = "$regBase\$sid"
    $bakKeyPath  = "$regBase\$sid.bak"

    if (Test-Path $mainKeyPath) {
        $mainKey = Get-ItemProperty $mainKeyPath -ErrorAction SilentlyContinue
        $profileImagePath = $mainKey.ProfileImagePath
        $state    = $mainKey.State
        $refCount = $mainKey.RefCount

        $stateLabel = switch ($state) {
            0       { "Normal" }
            4       { "Loaded/in-use (stuck if no active session)" }
            256     { "Mandatory profile (intentional — local changes don't persist)" }
            1024    { "Local profile" }
            default { "Value $state — see MS Docs for full flag meaning" }
        }
        Add-Result "ProfileListEntry" "OK" "ProfileImagePath=$profileImagePath, State=$state ($stateLabel), RefCount=$refCount"

        if ($state -eq 4) {
            Add-Result "ProfileState" "WARN" "State=4 (loaded/locked) — if no active session exists for this user, this is a stuck-lock condition (Fix 3)"
        }
        if ($profileImagePath -match '\\TEMP(\\|$)') {
            Add-Result "ProfileImagePathCheck" "ERROR" "Registry ProfileImagePath itself points to a TEMP path — Fix 1 or Fix 2 likely needed"
        }
    } else {
        Add-Result "ProfileListEntry" "ERROR" "No ProfileList registry entry for SID $sid — profile key missing (Fix 4 or Fix 5)"
    }

    if (Test-Path $bakKeyPath) {
        $bakKey = Get-ItemProperty $bakKeyPath -ErrorAction SilentlyContinue
        Add-Result "DuplicateSIDKey" "ERROR" "Duplicate .bak key found: $($bakKey.ProfileImagePath) — this is the most common temp-profile cause (Fix 1). Compare paths before deciding which key is authoritative."
    } else {
        Add-Result "DuplicateSIDKey" "OK" "No .bak duplicate key found for this SID"
    }
}
#endregion

#region ─── 3. NTUSER.DAT presence ──────────────────────────────────────────────
if ($profileImagePath) {
    $ntuserPath = Join-Path $profileImagePath "NTUSER.DAT"
    if (Test-Path $ntuserPath) {
        Add-Result "NTUSERDAT" "OK" "NTUSER.DAT present at $ntuserPath (existence confirmed; corruption cannot be ruled out without a logon attempt)"
    } else {
        Add-Result "NTUSERDAT" "ERROR" "NTUSER.DAT missing at $ntuserPath — profile folder may be incomplete or deleted (Fix 5)"
    }

    if (-not (Test-Path $profileImagePath)) {
        Add-Result "ProfileFolder" "ERROR" "Profile folder does not exist on disk at $profileImagePath despite registry entry — Fix 5 (rebuild from scratch)"
    }
} else {
    Add-Result "NTUSERDAT" "INFO" "Skipped — no ProfileImagePath resolved from registry"
}
#endregion

#region ─── 4. Recent User Profile Service event log entries ───────────────────
try {
    $profileEvents = Get-WinEvent -LogName Application -MaxEvents 200 -ErrorAction Stop |
        Where-Object { $_.ProviderName -eq "Microsoft-Windows-User Profiles Service" -and $_.Id -in @(1500,1502,1505,1511,1515,1530,1534) }

    if ($profileEvents -and $profileEvents.Count -gt 0) {
        $errorEvents = $profileEvents | Where-Object { $_.LevelDisplayName -eq "Error" }
        if ($errorEvents.Count -gt 0) {
            Add-Result "ProfileServiceEvents" "WARN" "$($profileEvents.Count) relevant event(s) found, $($errorEvents.Count) at Error level — most recent: ID $($profileEvents[0].Id) at $($profileEvents[0].TimeCreated)"
        } else {
            Add-Result "ProfileServiceEvents" "INFO" "$($profileEvents.Count) relevant event(s) found, none at Error level"
        }
    } else {
        Add-Result "ProfileServiceEvents" "OK" "No recent User Profile Service warning/error events found (last 200 Application log entries)"
    }
} catch {
    Add-Result "ProfileServiceEvents" "WARN" "Could not query Application event log: $_"
}
#endregion

#region ─── 5. Disk space ───────────────────────────────────────────────────────
try {
    $cDrive = Get-PSDrive C -ErrorAction Stop
    $freeMB = [math]::Round($cDrive.Free / 1MB, 0)
    if ($freeMB -lt 500) {
        Add-Result "DiskSpace" "ERROR" "C: free space is ${freeMB}MB — below the ~500MB threshold where profile load operations can fail silently"
    } else {
        Add-Result "DiskSpace" "OK" "C: free space: ${freeMB}MB"
    }
} catch {
    Add-Result "DiskSpace" "WARN" "Could not query C: drive space: $_"
}
#endregion

#region ─── Summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── User Profile Diagnostics Summary ───────────────────" -ForegroundColor Cyan
$errorCount = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
$warnCount  = ($results | Where-Object { $_.Status -eq "WARN" }).Count

Write-Host "  Checks run   : $($results.Count)"
Write-Host "  Errors       : $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Warnings     : $warnCount" -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "Green" })

if ($errorCount -eq 0 -and $warnCount -eq 0) {
    Write-Host "  Overall: User profile registry state looks healthy for $TargetUser." -ForegroundColor Green
} else {
    Write-Host "  Overall: Issues found — cross-reference against UserProfile-B.md Fix 1-5." -ForegroundColor Yellow
}
Write-Host ""
#endregion

#region ─── Export ──────────────────────────────────────────────────────────────
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Exported → $ExportPath" "OK"
Write-Status "Done — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
