<#
.SYNOPSIS
    Collects Windows Firewall service, profile, and rule-source diagnostics.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/Firewall-B.md.
    Runs the runbook's triage and diagnosis steps in one pass:
    - mpssvc and BFE service state
    - Active firewall profile per network connection (Domain/Private/Public)
    - Whether an allow rule exists for a given app/executable or port
    - Whether the found rule's Profile scope matches the machine's active profile
    - Whether GPO/Intune (RSOP PolicyStore) rules override local configuration
    - Recent firewall drop events (5152/5157), if auditing is enabled

    Exports full detail to CSV so results can be pasted into the runbook's
    Escalation Evidence template.

    Does NOT cover:
    - Creating or removing rules (see Firewall-B.md Fix 3 / Fix 4)
    - Resetting the firewall to defaults (destructive — see Firewall-B.md Fix 5)
    - IPsec/connection security rule diagnostics

.PARAMETER Port
    TCP/UDP port to check for blocking rules. Optional — provide either -Port
    or -ProgramPath (or both).

.PARAMETER ProgramPath
    Full path to the executable to check for an existing allow rule. Optional.

.PARAMETER RuleNameFilter
    Keyword to filter RSOP (GPO/Intune) rule lookups. Default: "*" (all rules).

.PARAMETER ExportPath
    Path for CSV export. Default: .\FirewallDiagnostics-<timestamp>.csv

.EXAMPLE
    .\Get-FirewallDiagnostics.ps1 -Port 443
    Checks service health, profile state, and whether TCP 443 is blocked.

.EXAMPLE
    .\Get-FirewallDiagnostics.ps1 -ProgramPath "C:\Program Files\MyApp\MyApp.exe" -RuleNameFilter "MyApp"
    Checks for an existing allow rule for the executable and searches GPO/Intune
    RSOP rules matching "MyApp".

.NOTES
    Requires: Windows PowerShell 5.1+; NetSecurity module (built-in)
    Run-as: Administrator (required for RSOP PolicyStore queries and service state)
    Safe: Read-only — makes no changes to services, rules, or profiles
    Tested on: Windows 10 21H2+, Windows 11, Windows Server 2019/2022
#>

[CmdletBinding()]
param(
    [int]$Port,
    [string]$ProgramPath,
    [string]$RuleNameFilter = "*",
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
Write-Status "Get-FirewallDiagnostics — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\FirewallDiagnostics-$timestamp.csv"
}

if (-not $Port -and -not $ProgramPath) {
    Write-Status "No -Port or -ProgramPath supplied — running service/profile checks only" "WARN"
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

#region ─── 1. Service health ──────────────────────────────────────────────────
try {
    $bfe = Get-Service -Name BFE -ErrorAction Stop
    Add-Result "Service-BFE" $(if ($bfe.Status -eq 'Running') { "OK" } else { "ERROR" }) "Status: $($bfe.Status)"
} catch {
    Add-Result "Service-BFE" "ERROR" "Could not query BFE service: $_"
}

try {
    $mpssvc = Get-Service -Name mpssvc -ErrorAction Stop
    Add-Result "Service-mpssvc" $(if ($mpssvc.Status -eq 'Running') { "OK" } else { "ERROR" }) "Status: $($mpssvc.Status)"
} catch {
    Add-Result "Service-mpssvc" "ERROR" "Could not query mpssvc service: $_"
}
#endregion

#region ─── 2. Firewall profiles ───────────────────────────────────────────────
try {
    $profiles = Get-NetFirewallProfile
    foreach ($p in $profiles) {
        $status = if ($p.Enabled) { "OK" } else { "WARN" }
        Add-Result "Profile-$($p.Name)" $status "Enabled: $($p.Enabled); InboundDefault: $($p.DefaultInboundAction); OutboundDefault: $($p.DefaultOutboundAction)"
    }
} catch {
    Add-Result "Profiles" "ERROR" "Get-NetFirewallProfile failed: $_"
}

try {
    $connProfiles = Get-NetConnectionProfile
    foreach ($cp in $connProfiles) {
        $status = if ($cp.NetworkCategory -eq 'Public') { "WARN" } else { "OK" }
        Add-Result "ActiveProfile-$($cp.InterfaceAlias)" $status "Category: $($cp.NetworkCategory)"
    }
} catch {
    Add-Result "ActiveProfile" "WARN" "Get-NetConnectionProfile failed: $_"
}
#endregion

#region ─── 3. Port rule check ─────────────────────────────────────────────────
if ($Port) {
    try {
        $blockRules = Get-NetFirewallRule -Enabled True -Direction Inbound -Action Block -ErrorAction Stop |
            Get-NetFirewallPortFilter | Where-Object { $_.LocalPort -eq $Port -or $_.LocalPort -eq "Any" }
        if ($blockRules) {
            Add-Result "Port-$Port-BlockRule" "ERROR" "Explicit block rule found for port $Port"
        } else {
            Add-Result "Port-$Port-BlockRule" "OK" "No explicit block rule found for port $Port"
        }
    } catch {
        Add-Result "Port-$Port-BlockRule" "WARN" "Rule query failed: $_"
    }
}
#endregion

#region ─── 4. Program allow-rule check ────────────────────────────────────────
if ($ProgramPath) {
    try {
        $appRules = Get-NetFirewallRule -Enabled True -Direction Inbound -Action Allow -ErrorAction Stop |
            Get-NetFirewallApplicationFilter | Where-Object { $_.Program -eq $ProgramPath }
        if ($appRules) {
            $ruleNames = ($appRules | ForEach-Object {
                (Get-NetFirewallRule -AssociatedNetFirewallApplicationFilter $_).DisplayName
            }) -join ", "
            Add-Result "Program-AllowRule" "OK" "Allow rule(s) found: $ruleNames"

            # Check profile scope of the found rule(s) vs active connection profile
            $activeCategories = (Get-NetConnectionProfile).NetworkCategory -join ","
            foreach ($rn in ($ruleNames -split ", ")) {
                $ruleDetail = Get-NetFirewallRule -DisplayName $rn -ErrorAction SilentlyContinue
                if ($ruleDetail) {
                    Add-Result "Program-RuleProfile-$rn" "INFO" "Rule profile scope: $($ruleDetail.Profile); Active connection categories: $activeCategories"
                }
            }
        } else {
            Add-Result "Program-AllowRule" "ERROR" "No allow rule found for $ProgramPath"
        }
    } catch {
        Add-Result "Program-AllowRule" "WARN" "Rule query failed: $_"
    }
}
#endregion

#region ─── 5. GPO/Intune (RSOP) rule check ────────────────────────────────────
try {
    $rsopRules = Get-NetFirewallRule -PolicyStore "RSOP" -ErrorAction Stop |
        Where-Object { $_.DisplayName -like "*$RuleNameFilter*" -and $_.Action -eq "Block" }
    if ($rsopRules) {
        Add-Result "RSOP-BlockRules" "WARN" "$($rsopRules.Count) GPO/Intune block rule(s) matching '$RuleNameFilter' found — local overrides will not take effect"
    } else {
        Add-Result "RSOP-BlockRules" "OK" "No GPO/Intune block rules matching '$RuleNameFilter'"
    }
} catch {
    Add-Result "RSOP-BlockRules" "WARN" "RSOP PolicyStore query failed (may require elevated admin): $_"
}
#endregion

#region ─── 6. Drop event audit (best-effort) ──────────────────────────────────
try {
    $dropEvents = Get-WinEvent -LogName "Security" -FilterXPath "*[System[(EventID=5152 or EventID=5157)]]" -MaxEvents 20 -ErrorAction Stop
    Add-Result "DropEvents" "WARN" "$($dropEvents.Count) recent drop event(s) found (5152/5157) — review for the affected app/port"
} catch {
    Add-Result "DropEvents" "INFO" "No drop events found or auditing not enabled (auditpol /set /subcategory:`"Filtering Platform Packet Drop`" /success:enable /failure:enable)"
}
#endregion

#region ─── Summary ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── Firewall Diagnostics Summary ──────────────────────" -ForegroundColor Cyan
$errorCount = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
$warnCount  = ($results | Where-Object { $_.Status -eq "WARN" }).Count

Write-Host "  Checks run   : $($results.Count)"
Write-Host "  Errors       : $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Warnings     : $warnCount" -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "Green" })

if ($errorCount -eq 0 -and $warnCount -eq 0) {
    Write-Host "  Overall: Firewall configuration looks healthy for the checks run." -ForegroundColor Green
} else {
    Write-Host "  Overall: Issues found — match failed checks to Firewall-B.md fix paths (Fix 1-5)." -ForegroundColor Yellow
}
Write-Host ""
#endregion

#region ─── Export ────────────────────────────────────────────────────────────
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Exported → $ExportPath" "OK"
Write-Status "Done — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
