<#
.SYNOPSIS
    Audits the Group Policy Central Store for existence, freshness, ADMX
    namespace conflicts, and ADMX/ADML pairing gaps — the four conditions
    that cause the large majority of "Extra Registry Settings", namespace
    collision, and resource-not-found errors in Group Policy Management
    Editor.

.DESCRIPTION
    The Central Store (\\<domain>\SYSVOL\<domain>\Policies\PolicyDefinitions)
    is discovered silently by Group Policy tooling with no warning when it's
    absent, stale, or internally inconsistent. This script checks, in order:
      1. Whether the Central Store exists at all
      2. How stale its newest .admx file is
      3. Whether any two .admx files declare the same target namespace
         (which blocks the entire Administrative Templates node from
         loading, not just one setting)
      4. Whether every .admx has a matching .adml in the specified locale
         folder (mismatched pairs throw resource-not-found errors)
      5. (Optional, -CheckAllDCs) Whether every domain controller's copy of
         the store shows the same newest-file date, as a rough SYSVOL/DFSR
         consistency signal
      6. Whether this machine has EnableLocalStoreOverride set, which
         causes it to ignore the Central Store entirely regardless of its
         health

    This script does NOT modify the Central Store, any GPO, or any registry
    value. Read-only / reporting only. Exports a consolidated CSV.

.PARAMETER Locale
    The ADML locale folder to check for ADMX/ADML pairing completeness.
    Default: en-US

.PARAMETER CheckAllDCs
    If specified, additionally queries every domain controller's own copy
    of the PolicyDefinitions folder and compares newest-file dates across
    all of them, as a rough SYSVOL/DFSR replication-consistency signal.
    Requires network reachability to each DC's SYSVOL share.

.PARAMETER ExportPath
    Path for the CSV export. Default: $env:TEMP\GPOCentralStoreAudit_<timestamp>.csv

.EXAMPLE
    .\Get-GPOCentralStoreAudit.ps1
    # Checks store existence, freshness, namespace conflicts, and ADMX/ADML
    # pairing for en-US, plus this machine's EnableLocalStoreOverride state

.EXAMPLE
    .\Get-GPOCentralStoreAudit.ps1 -Locale de-DE -CheckAllDCs
    # Same, but checks the German locale pairing and compares freshness
    # across every domain controller

.NOTES
    Requires: ActiveDirectory PowerShell module (RSAT); network read access
              to the SYSVOL Policies share
    Run as:   Any account with read access to the SYSVOL Policies share;
              no elevated/admin rights required for the read-only checks
    Safe/Unsafe: READ-ONLY — does not create, modify, or delete any file in
                 the Central Store, any GPO, or any registry value
    Tested against: Windows Server 2016 / 2019 / 2022 domain controllers,
                     Windows 10/11 RSAT admin workstations
    Limitation: The namespace-conflict and pairing checks only cover the
                store's CONTENTS as found — they do not evaluate whether
                the store's content is actually CURRENT relative to your
                latest Windows/Office baseline beyond a simple file-date
                freshness check. Cross-check against your patch baseline
                manually when investigating a specific missing setting.
#>

[CmdletBinding()]
param(
    [string] $Locale = "en-US",
    [switch] $CheckAllDCs,
    [string] $ExportPath = "$env:TEMP\GPOCentralStoreAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
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

#region --- Preflight ---

Write-Status "Group Policy Central Store / ADMX Audit" -Status "HEADER"
Write-Status "Run time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Status "INFO"

if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Status "ActiveDirectory module not found. Install RSAT: AD DS Tools." -Status "ERROR"
    exit 1
}
Import-Module ActiveDirectory -ErrorAction Stop

$results = @()

try {
    $domain = (Get-ADDomain -ErrorAction Stop).DNSRoot
} catch {
    Write-Status "Could not determine domain via Get-ADDomain: $_" -Status "ERROR"
    exit 1
}

$store = "\\$domain\SYSVOL\$domain\Policies\PolicyDefinitions"

#endregion

#region --- 1. Central Store Existence ---

Write-Status "`n=== Central Store Existence ===" -Status "HEADER"

$storeExists = Test-Path $store -ErrorAction SilentlyContinue
$existsStatus = if ($storeExists) { "OK" } else { "ERROR" }
Write-Status "  Path: $store" -Status "INFO"
Write-Status "  Exists: $storeExists" -Status $existsStatus

$results += [PSCustomObject]@{
    Category = "CentralStoreExistence"; Item = $store
    Value = $storeExists; Status = $existsStatus
    Note = if ($storeExists) { "Central Store present" } else { "NO CENTRAL STORE - every editing machine falls back to its own local PolicyDefinitions folder" }
}

if (-not $storeExists) {
    Write-Status "`nCentral Store does not exist - skipping remaining content checks (nothing to check)." -Status "WARN"
    Write-Status "See GPO-CentralStore-B.md Fix 1 / GPO-CentralStore-A.md Remediation Playbook 1 to create one." -Status "WARN"
    $results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
    Write-Host "`nReport saved to: $ExportPath"
    exit 0
}

#endregion

#region --- 2. Store Freshness ---

Write-Status "`n=== Store Freshness ===" -Status "HEADER"

try {
    $admxFiles = Get-ChildItem $store -Filter *.admx -ErrorAction Stop
    if (-not $admxFiles) {
        Write-Status "  Store folder exists but contains NO .admx files." -Status "ERROR"
        $results += [PSCustomObject]@{
            Category = "StoreFreshness"; Item = "ADMXCount"; Value = 0; Status = "ERROR"
            Note = "Central Store folder exists but is empty - effectively the same as not having one"
        }
    } else {
        $newest = ($admxFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        $ageDays = (New-TimeSpan -Start $newest.LastWriteTime -End (Get-Date)).Days
        $freshStatus = if ($ageDays -gt 365) { "WARN" } else { "OK" }

        Write-Status "  ADMX file count: $($admxFiles.Count)" -Status "INFO"
        Write-Status "  Newest ADMX: $($newest.Name) ($($newest.LastWriteTime))" -Status "INFO"
        Write-Status "  Age of newest file: $ageDays day(s)" -Status $freshStatus

        if ($ageDays -gt 365) {
            Write-Status "  Store hasn't been updated in over a year - recent OS/Office ADMX-backed" -Status "WARN"
            Write-Status "  settings are very likely missing. Windows Update never updates this store." -Status "WARN"
        }

        $results += [PSCustomObject]@{
            Category = "StoreFreshness"; Item = "NewestADMXFile"
            Value = "$($newest.Name) : $($newest.LastWriteTime)"; Status = $freshStatus
            Note = "Age: $ageDays day(s). Central Store is never auto-updated by Windows Update - verify against your current OS/Office baseline"
        }
    }
} catch {
    Write-Status "  Could not enumerate ADMX files: $_" -Status "ERROR"
    $results += [PSCustomObject]@{
        Category = "StoreFreshness"; Item = "Enumeration"; Value = "FAILED"; Status = "ERROR"; Note = "$_"
    }
}

#endregion

#region --- 3. Namespace Conflict Check ---

Write-Status "`n=== ADMX Namespace Conflict Check ===" -Status "HEADER"

try {
    $namespaceMap = @()
    foreach ($file in $admxFiles) {
        try {
            [xml]$xml = Get-Content $file.FullName -ErrorAction Stop
            $ns = $xml.policyDefinitions.policyNamespaces.target.namespace
            $namespaceMap += [PSCustomObject]@{ File = $file.Name; Namespace = $ns }
        } catch {
            $namespaceMap += [PSCustomObject]@{ File = $file.Name; Namespace = "PARSE ERROR" }
            Write-Status "  Could not parse $($file.Name): $_" -Status "WARN"
        }
    }

    $conflicts = $namespaceMap | Where-Object { $_.Namespace -and $_.Namespace -ne "PARSE ERROR" } |
        Group-Object Namespace | Where-Object Count -gt 1

    if ($conflicts) {
        Write-Status "  $($conflicts.Count) duplicate namespace(s) found - THIS WILL BLOCK THE ENTIRE" -Status "ERROR"
        Write-Status "  Administrative Templates node from loading, not just one setting." -Status "ERROR"
        foreach ($c in $conflicts) {
            $filesInConflict = ($c.Group.File -join ", ")
            Write-Host "    Namespace '$($c.Name)' declared by: $filesInConflict" -ForegroundColor Red
            $results += [PSCustomObject]@{
                Category = "NamespaceConflict"; Item = $c.Name
                Value = $filesInConflict; Status = "ERROR"
                Note = "Duplicate target namespace across $($c.Count) files - typically caused by an incremental/partial ADMX copy. Rebuild the store from a single clean source rather than removing one file blindly."
            }
        }
    } else {
        Write-Status "  No duplicate ADMX target namespaces found." -Status "OK"
        $results += [PSCustomObject]@{
            Category = "NamespaceConflict"; Item = "Check"; Value = "Clean"; Status = "OK"
            Note = "No duplicate target namespaces detected across $($admxFiles.Count) ADMX files"
        }
    }
} catch {
    Write-Status "  Namespace conflict check failed: $_" -Status "ERROR"
    $results += [PSCustomObject]@{
        Category = "NamespaceConflict"; Item = "Check"; Value = "FAILED"; Status = "ERROR"; Note = "$_"
    }
}

#endregion

#region --- 4. ADMX/ADML Pairing Check ---

Write-Status "`n=== ADMX/ADML Pairing Check ($Locale) ===" -Status "HEADER"

$localePath = Join-Path $store $Locale
if (-not (Test-Path $localePath)) {
    Write-Status "  Locale folder '$Locale' not found under the store." -Status "WARN"
    $results += [PSCustomObject]@{
        Category = "ADMLPairing"; Item = $Locale; Value = "Folder missing"; Status = "WARN"
        Note = "Requested locale folder does not exist in the Central Store - check the locale name or that language pack was ever copied in"
    }
} else {
    try {
        $admxNames = $admxFiles.BaseName
        $admlNames = (Get-ChildItem $localePath -Filter *.adml -ErrorAction Stop).BaseName

        $missingAdml = Compare-Object $admxNames $admlNames | Where-Object SideIndicator -eq "<=" | Select-Object -ExpandProperty InputObject
        $orphanAdml  = Compare-Object $admxNames $admlNames | Where-Object SideIndicator -eq "=>" | Select-Object -ExpandProperty InputObject

        if ($missingAdml) {
            Write-Status "  $($missingAdml.Count) ADMX file(s) with NO matching ADML in '$Locale':" -Status "ERROR"
            $missingAdml | ForEach-Object {
                Write-Host "    $_.admx (missing $_.adml)" -ForegroundColor Red
                $results += [PSCustomObject]@{
                    Category = "ADMLPairing"; Item = "$_.admx"; Value = "Missing $_.adml in $Locale"; Status = "ERROR"
                    Note = "This setting will throw a resource-not-found error when rendered - re-copy the ADMX/ADML pair together from the same source version"
                }
            }
        } else {
            Write-Status "  Every ADMX file has a matching ADML in '$Locale'." -Status "OK"
        }

        if ($orphanAdml) {
            Write-Status "  $($orphanAdml.Count) orphan ADML file(s) with no matching ADMX (harmless, but indicates leftover cruft):" -Status "WARN"
            $orphanAdml | ForEach-Object {
                $results += [PSCustomObject]@{
                    Category = "ADMLPairing"; Item = "$_.adml"; Value = "No matching $_.admx"; Status = "WARN"
                    Note = "Orphaned ADML with no corresponding ADMX - not harmful, but suggests an incomplete prior cleanup"
                }
            }
        }

        if (-not $missingAdml -and -not $orphanAdml) {
            $results += [PSCustomObject]@{
                Category = "ADMLPairing"; Item = $Locale; Value = "Clean"; Status = "OK"
                Note = "$($admxNames.Count) ADMX files, all with matching $Locale ADML files"
            }
        }
    } catch {
        Write-Status "  ADML pairing check failed: $_" -Status "ERROR"
        $results += [PSCustomObject]@{
            Category = "ADMLPairing"; Item = $Locale; Value = "FAILED"; Status = "ERROR"; Note = "$_"
        }
    }
}

#endregion

#region --- 5. Optional: Per-DC Freshness Consistency ---

if ($CheckAllDCs) {
    Write-Status "`n=== Per-DC Store Freshness (SYSVOL/DFSR consistency signal) ===" -Status "HEADER"
    try {
        $dcs = (Get-ADDomainController -Filter *).HostName
        $dcDates = @()
        foreach ($dc in $dcs) {
            $dcPath = "\\$dc\SYSVOL\$domain\Policies\PolicyDefinitions"
            try {
                $dcNewest = (Get-ChildItem $dcPath -Filter *.admx -ErrorAction Stop |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
                Write-Host "  $dc : $dcNewest"
                $dcDates += [PSCustomObject]@{ DC = $dc; NewestADMXDate = $dcNewest }
            } catch {
                Write-Status "  $dc : could not read ($($_.Exception.Message))" -Status "WARN"
                $dcDates += [PSCustomObject]@{ DC = $dc; NewestADMXDate = $null }
            }
        }

        $distinctDates = $dcDates | Where-Object NewestADMXDate | Select-Object -ExpandProperty NewestADMXDate -Unique
        $consistencyStatus = if ($distinctDates.Count -le 1) { "OK" } else { "WARN" }

        if ($consistencyStatus -eq "WARN") {
            Write-Status "  DCs show DIFFERING newest-file dates - likely an in-progress or stalled SYSVOL/DFSR" -Status "WARN"
            Write-Status "  replication of a recent Central Store update. Cross-check with dfsrdiag/AD-Replication-A.md." -Status "WARN"
        } else {
            Write-Status "  All reachable DCs show a consistent newest-file date." -Status "OK"
        }

        $results += [PSCustomObject]@{
            Category = "PerDCConsistency"; Item = "AllDCs"
            Value = ($dcDates | ForEach-Object { "$($_.DC)=$($_.NewestADMXDate)" }) -join "; "
            Status = $consistencyStatus
            Note = if ($consistencyStatus -eq "OK") { "Consistent across all reachable DCs" } else { "Inconsistent - check SYSVOL/DFSR replication health" }
        }
    } catch {
        Write-Status "  Per-DC check failed: $_" -Status "ERROR"
        $results += [PSCustomObject]@{
            Category = "PerDCConsistency"; Item = "Check"; Value = "FAILED"; Status = "ERROR"; Note = "$_"
        }
    }
} else {
    Write-Status "`n(Skipping per-DC consistency check - run with -CheckAllDCs to compare the Central Store across every domain controller.)" -Status "INFO"
}

#endregion

#region --- 6. Local Override Check (this machine) ---

Write-Status "`n=== EnableLocalStoreOverride (this machine) ===" -Status "HEADER"

try {
    $overrideVal = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Group Policy" -Name "EnableLocalStoreOverride" -ErrorAction SilentlyContinue
    $isOverridden = $overrideVal -and $overrideVal.EnableLocalStoreOverride -eq 1
    $overrideStatus = if ($isOverridden) { "WARN" } else { "OK" }

    if ($isOverridden) {
        Write-Status "  EnableLocalStoreOverride = 1 on $env:COMPUTERNAME" -Status "WARN"
        Write-Status "  This machine IGNORES the Central Store entirely, regardless of its health." -Status "WARN"
        Write-Status "  Confirm this is an active, intentional diagnostic session, not a forgotten leftover." -Status "WARN"
    } else {
        Write-Status "  Not set (or 0) - this machine uses the Central Store normally." -Status "OK"
    }

    $results += [PSCustomObject]@{
        Category = "LocalOverride"; Item = $env:COMPUTERNAME
        Value = if ($overrideVal) { $overrideVal.EnableLocalStoreOverride } else { "Not set" }
        Status = $overrideStatus
        Note = if ($isOverridden) { "This machine ignores the Central Store - confirm intentional and time-boxed" } else { "Normal - defers to Central Store when present" }
    }
} catch {
    Write-Status "  Could not check EnableLocalStoreOverride: $_" -Status "WARN"
    $results += [PSCustomObject]@{
        Category = "LocalOverride"; Item = $env:COMPUTERNAME; Value = "FAILED"; Status = "WARN"; Note = "$_"
    }
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
    Write-Status "One or more Central Store issues found (missing store, empty store, namespace conflict, or ADML pairing gap) - review the CSV before assuming a client-side GPO problem." -Status "ERROR"
} elseif ($warnCount -gt 0) {
    Write-Status "No hard failures, but review warnings (staleness, local override, or DC inconsistency) before considering this store fully healthy." -Status "WARN"
} else {
    Write-Status "Central Store is present, current, internally consistent, and this machine is not overridden." -Status "OK"
}

#endregion
