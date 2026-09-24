<#
.SYNOPSIS
    Read-only tenant audit of Intune macOS ADE local account configuration with LAPS: which ADE profiles
    create a local admin, which macOS devices are (or can't be) LAPS-managed, password-policy conflicts,
    and recent password view/rotate audit events.

.DESCRIPTION
    Companion script to macOS/Troubleshooting/MacLAPS-A.md and MacLAPS-B.md.

    1. ADE PROFILES — enumerates every ADE token (depOnboardingSettings) and its macOS enrollment
       profiles, and reports account-configuration properties. Property names on the beta
       depMacOSEnrollmentProfile resource are matched by prefix (adminAccount*, primaryAccount*,
       hideAdminAccount, etc.) rather than hard-coded, because the beta schema can change. A profile is
       classed LAPS_ENABLED when any admin-account property is populated. Treat this as a strong
       heuristic and confirm in the portal (Profiles → Account settings).

    2. DEVICES — every Intune macOS device with enrollment type, enrollment profile name, OS version and
       last check-in. Flags:
         NOT_ADE          enrollment type isn't an Apple ADE type → can never be LAPS-managed without wipe
         NO_LAPS_PROFILE  enrolled with a profile not classed LAPS_ENABLED (or profile name unknown)
         OS_BELOW_26_4    affected by the documented pre-26.4 forced admin reset issue
         SYNC_STALE       last check-in older than -StaleSyncDays (rotations won't have landed)
       Note: enrolling with a LAPS profile today does not prove the device enrolled AFTER LAPS was
       enabled on that profile. The only authoritative per-device check is the "Passwords and keys" pane.

    3. PASSWORD POLICY CONFLICTS — macOS compliance policies and macOS device-restriction
       (macOSGeneralDeviceConfiguration) profiles with passwordRequired = true. Microsoft states these
       enable "Change at next authentication" by default and can break sign-in for LAPS accounts;
       password policy for LAPS devices should come from Settings catalog only.

    4. AUDIT — Intune audit events in the last -AuditDays whose activity/display name matches
       "AdminAccountDto" (password viewed) or "rotateLocalAdminPassword" (rotation).

    Does NOT: read any password, trigger rotation, change profiles/policies, or evaluate Settings
    catalog passcode policies' "Change at next authentication" value.

.PARAMETER StaleSyncDays
    Days since last check-in before a device is flagged SYNC_STALE. Default 14.

.PARAMETER AuditDays
    How many days of Intune audit events to scan. Default 30.

.PARAMETER OutputPath
    Base path (no extension). Writes <OutputPath>-Profiles.csv, -Devices.csv, -PolicyConflicts.csv,
    -Audit.csv. Default: $env:TEMP\MacLAPSAudit-<timestamp>

.EXAMPLE
    Connect-MgGraph -Scopes "DeviceManagementServiceConfig.Read.All","DeviceManagementManagedDevices.Read.All","DeviceManagementConfiguration.Read.All","DeviceManagementApps.Read.All"
    .\Get-MacLAPSAudit.ps1

.EXAMPLE
    .\Get-MacLAPSAudit.ps1 -StaleSyncDays 7 -AuditDays 90 -OutputPath C:\Temp\ContosoMacLAPS

.NOTES
    Requires: Microsoft.Graph.Authentication (Invoke-MgGraphRequest). Uses Graph beta endpoints.
    Scopes:   DeviceManagementServiceConfig.Read.All, DeviceManagementManagedDevices.Read.All,
              DeviceManagementConfiguration.Read.All, DeviceManagementApps.Read.All (audit events)
    Run as:   Intune read-only operator or higher. Does NOT need View/Rotate macOS admin password rights.
    Safe:     Read-only.
#>
[CmdletBinding()]
param(
    [int]$StaleSyncDays = 14,
    [int]$AuditDays = 30,
    [string]$OutputPath = (Join-Path ([IO.Path]::GetTempPath()) "MacLAPSAudit-$(Get-Date -Format 'yyyyMMdd-HHmm')")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" {"Green"} "WARN" {"Yellow"} "ERROR" {"Red"} default {"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-GraphAll {
    param([string]$Uri)
    $items = New-Object System.Collections.Generic.List[object]
    $next = $Uri
    while ($next) {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject
        if ($resp.PSObject.Properties.Name -contains 'value') { foreach ($v in $resp.value) { $items.Add($v) } }
        $next = if ($resp.PSObject.Properties.Name -contains '@odata.nextLink') { $resp.'@odata.nextLink' } else { $null }
    }
    return $items
}

function Get-Prop { param($Obj, [string]$Name) if ($Obj.PSObject.Properties.Name -contains $Name) { $Obj.$Name } else { $null } }

# ─── Preflight ───
if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
    Write-Status "Microsoft.Graph.Authentication module not found. Install-Module Microsoft.Graph.Authentication" "ERROR"; return
}
if (-not (Get-MgContext)) {
    Write-Status "Not connected to Graph. Run Connect-MgGraph with the scopes in .NOTES first." "ERROR"; return
}
$beta = "https://graph.microsoft.com/beta"
$acctPattern = '^(adminAccount|hideAdminAccount|primaryAccount|enableRestrictEditing|dontAutoPopulatePrimaryAccountInfo|setPrimarySetupAccountAsRegularUser|skipPrimarySetupAccountCreation|awaitDeviceConfiguredConfirmation)'

# ─── 1. ADE profiles ───
Write-Status "Enumerating ADE tokens and macOS enrollment profiles..."
$profileRows = New-Object System.Collections.Generic.List[object]
$lapsProfileNames = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
$allProfileNames  = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
try {
    $tokens = Get-GraphAll "$beta/deviceManagement/depOnboardingSettings"
} catch {
    Write-Status "Could not read depOnboardingSettings: $($_.Exception.Message)" "ERROR"; $tokens = @()
}
foreach ($t in $tokens) {
    try { $profiles = Get-GraphAll "$beta/deviceManagement/depOnboardingSettings/$($t.id)/enrollmentProfiles" }
    catch { Write-Status "Token '$($t.tokenName)': cannot list profiles ($($_.Exception.Message))" "WARN"; continue }
    foreach ($p in $profiles) {
        $type = Get-Prop $p '@odata.type'
        if ($type -ne '#microsoft.graph.depMacOSEnrollmentProfile') { continue }
        [void]$allProfileNames.Add($p.displayName)
        $acct = @{}
        foreach ($prop in $p.PSObject.Properties) {
            if ($prop.Name -match $acctPattern -and $null -ne $prop.Value -and "$($prop.Value)" -ne '') { $acct[$prop.Name] = "$($prop.Value)" }
        }
        $adminKeys = @($acct.Keys | Where-Object { $_ -like 'adminAccount*' -and $_ -notlike '*Password' })
        $isLaps = $adminKeys.Count -gt 0
        if ($isLaps) { [void]$lapsProfileNames.Add($p.displayName) }
        $profileRows.Add([pscustomobject]@{
            Token             = Get-Prop $t 'tokenName'
            Profile           = $p.displayName
            IsDefault         = Get-Prop $p 'isDefault'
            UserAffinity      = Get-Prop $p 'requiresUserAuthentication'
            Classification    = if ($isLaps) { 'LAPS_ENABLED' } else { 'NO_LOCAL_ADMIN' }
            AccountProperties = (($acct.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; ')
        })
        $st = if ($isLaps) { "OK" } else { "INFO" }
        Write-Status "Profile '$($p.displayName)' [$((Get-Prop $t 'tokenName'))]: $(if ($isLaps) {'LAPS_ENABLED'} else {'no local admin configured'})" $st
    }
}
if ($lapsProfileNames.Count -eq 0) { Write-Status "No macOS ADE profile appears to configure a local admin account." "WARN" }

# ─── 2. Devices ───
Write-Status "Enumerating macOS managed devices..."
$select = "id,deviceName,serialNumber,osVersion,deviceEnrollmentType,enrollmentProfileName,enrolledDateTime,lastSyncDateTime,userPrincipalName"
$devices = Get-GraphAll "$beta/deviceManagement/managedDevices?`$filter=operatingSystem eq 'macOS'&`$select=$select"
$adeTypes = @('appleBulkWithUser', 'appleBulkWithoutUser')
$staleCut = (Get-Date).ToUniversalTime().AddDays(-$StaleSyncDays)
$deviceRows = foreach ($d in $devices) {
    $flags = New-Object System.Collections.Generic.List[string]
    $etype = "$(Get-Prop $d 'deviceEnrollmentType')"
    $pname = "$(Get-Prop $d 'enrollmentProfileName')"
    if ($adeTypes -notcontains $etype) { $flags.Add('NOT_ADE') }
    elseif ([string]::IsNullOrWhiteSpace($pname) -or -not $lapsProfileNames.Contains($pname)) { $flags.Add('NO_LAPS_PROFILE') }
    $osv = $null
    if ([version]::TryParse(("$(Get-Prop $d 'osVersion')" -replace '[^0-9.]', '').Trim('.'), [ref]$osv)) {
        if ($osv -lt [version]'26.4') { $flags.Add('OS_BELOW_26_4') }
    }
    $last = Get-Prop $d 'lastSyncDateTime'
    if ($last -and ([datetime]$last).ToUniversalTime() -lt $staleCut) { $flags.Add('SYNC_STALE') }
    [pscustomobject]@{
        DeviceName        = $d.deviceName
        SerialNumber      = Get-Prop $d 'serialNumber'
        UPN               = Get-Prop $d 'userPrincipalName'
        OSVersion         = Get-Prop $d 'osVersion'
        EnrollmentType    = $etype
        EnrollmentProfile = $pname
        Enrolled          = Get-Prop $d 'enrolledDateTime'
        LastSync          = $last
        Flags             = if ($flags.Count) { $flags -join ',' } else { 'OK' }
    }
}
$deviceRows = @($deviceRows)
$lapsCandidates = @($deviceRows | Where-Object { $_.Flags -notmatch 'NOT_ADE|NO_LAPS_PROFILE' }).Count
Write-Status "macOS devices: $($deviceRows.Count); enrolled via a LAPS-enabled ADE profile: $lapsCandidates" "INFO"
foreach ($f in 'NOT_ADE','NO_LAPS_PROFILE','OS_BELOW_26_4','SYNC_STALE') {
    $n = @($deviceRows | Where-Object { $_.Flags -match $f }).Count
    if ($n) { Write-Status "$f : $n device(s)" "WARN" }
}

# ─── 3. Password policy conflicts ───
Write-Status "Checking macOS compliance and device-restriction password settings..."
$conflicts = New-Object System.Collections.Generic.List[object]
try {
    foreach ($c in (Get-GraphAll "$beta/deviceManagement/deviceCompliancePolicies")) {
        if ((Get-Prop $c '@odata.type') -eq '#microsoft.graph.macOSCompliancePolicy' -and (Get-Prop $c 'passwordRequired') -eq $true) {
            $conflicts.Add([pscustomobject]@{ Type = 'CompliancePolicy'; Name = $c.displayName; Id = $c.id; Note = 'passwordRequired=true — may enforce Change at next authentication on LAPS accounts' })
        }
    }
    foreach ($c in (Get-GraphAll "$beta/deviceManagement/deviceConfigurations")) {
        if ((Get-Prop $c '@odata.type') -eq '#microsoft.graph.macOSGeneralDeviceConfiguration' -and (Get-Prop $c 'passwordRequired') -eq $true) {
            $conflicts.Add([pscustomobject]@{ Type = 'DeviceRestrictions'; Name = $c.displayName; Id = $c.id; Note = 'passwordRequired=true — may enforce Change at next authentication on LAPS accounts' })
        }
    }
} catch { Write-Status "Policy read failed: $($_.Exception.Message)" "WARN" }
if ($conflicts.Count) {
    Write-Status "$($conflicts.Count) macOS compliance/device-restriction policy(ies) set passwords — move password policy for LAPS devices to Settings catalog" "WARN"
} else { Write-Status "No compliance/device-restriction password settings found for macOS" "OK" }

# ─── 4. Audit events ───
Write-Status "Scanning Intune audit events (last $AuditDays days)..."
$since = (Get-Date).ToUniversalTime().AddDays(-$AuditDays).ToString("yyyy-MM-ddTHH:mm:ssZ")
$auditRows = @()
try {
    $events = Get-GraphAll "$beta/deviceManagement/auditEvents?`$filter=activityDateTime ge $since"
    $auditRows = @(foreach ($e in $events) {
        $txt = "$(Get-Prop $e 'activity') $(Get-Prop $e 'displayName') $(Get-Prop $e 'activityType')"
        if ($txt -match 'AdminAccountDto|rotateLocalAdminPassword') {
            $actor = Get-Prop $e 'actor'
            [pscustomobject]@{
                When     = Get-Prop $e 'activityDateTime'
                Activity = (Get-Prop $e 'displayName')
                Kind     = if ($txt -match 'rotateLocalAdminPassword') { 'Rotate' } else { 'View' }
                Actor    = if ($actor) { Get-Prop $actor 'userPrincipalName' } else { $null }
                Resource = ((@(Get-Prop $e 'resources') | ForEach-Object { if ($_) { Get-Prop $_ 'displayName' } }) -join '; ')
                Result   = Get-Prop $e 'activityResult'
            }
        }
    })
    # Rotate events can also match Windows LAPS rotations; Resource column identifies the device.
    Write-Status "Password view/rotate events found: $($auditRows.Count) (includes Windows LAPS rotations if any — check Resource)" "INFO"
} catch { Write-Status "Audit read failed (needs DeviceManagementApps.Read.All): $($_.Exception.Message)" "WARN" }

# ─── Report ───
$profileRows | Export-Csv "$OutputPath-Profiles.csv" -NoTypeInformation
$deviceRows  | Export-Csv "$OutputPath-Devices.csv" -NoTypeInformation
$conflicts   | Export-Csv "$OutputPath-PolicyConflicts.csv" -NoTypeInformation
$auditRows   | Export-Csv "$OutputPath-Audit.csv" -NoTypeInformation
Write-Status "Reports written: $OutputPath-{Profiles,Devices,PolicyConflicts,Audit}.csv" "OK"
Write-Status "Authoritative per-device check remains Intune → device → Passwords and keys." "INFO"
