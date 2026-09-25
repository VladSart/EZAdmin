<#
.SYNOPSIS
    Tenant-wide, read-only Graph audit of macOS line-of-business app objects in Intune (LOB .pkg, unmanaged PKG, DMG).

.DESCRIPTION
    Admin-side companion to macOS/Troubleshooting/MacLOBApps-A.md / -B.md. MacLOBApps covers the
    device side (Get-MacLOBAppStatus.sh); this script covers the Intune object side, across every macOS app
    object in the tenant, and flags the configuration patterns behind the most common "Failed" and
    "Not detected" tickets:

      macOSLobApp  (#microsoft.graph.macOSLobApp  - "macOS line-of-business app", MDM channel)
        - childApps empty, or more than -ChildAppWarnThreshold entries (helper/framework bundle IDs that
          mdmclient never reports cause 0x87D13BA2 "invalid bundleIDs" failures)
        - childApps entries with blank bundleId or version
        - ignoreVersionDetection = false on apps that self-update (flagged as INFO, it's a judgement call)
        - installAsManaged = true (needs macOS 11+ and the managed-app flow; no uninstall intent otherwise)
      macOSPkgApp  (#microsoft.graph.macOSPkgApp  - "macOS apps (PKG)", Intune agent channel)
        - includedApps empty / primaryBundleId missing
        - pre/post-install scripts present (reported, since they are a frequent silent failure source)
      macOSDmgApp  (#microsoft.graph.macOSDmgApp  - "macOS apps (DMG)", Intune agent channel)
        - includedApps empty / primaryBundleId missing
      All types
        - not assigned (isAssigned = false), or assigned only as "available" without enrolled-device intent
        - publishingState not 'published' (upload never finished)
        - minimumSupportedOperatingSystem floor (reported, compared against -FleetMinimumMacOS if supplied)
        - duplicate primary bundle IDs across more than one app object (two objects fighting over one app)
        - optional: missing app icon (-CheckIcons, one extra GET per app)

    Does NOT: read install status per device, change anything, or validate the package contents
    themselves (signing, notarisation, payload). For device-side checks use Get-MacLOBAppStatus.sh.

.PARAMETER ChildAppWarnThreshold
    Flag macOSLobApp objects whose childApps list has more entries than this. Default 3.

.PARAMETER FleetMinimumMacOS
    Optional oldest macOS major version still in your fleet (e.g. 14). Apps whose minimum OS floor is
    above it are flagged, because those Macs will silently show "Not applicable".

.PARAMETER CheckIcons
    Also fetch largeIcon for each app (one extra Graph call per app). Missing icons only affect Company Portal UX.

.PARAMETER OutputPath
    Folder for the CSV. Default: current directory.

.EXAMPLE
    Connect-MgGraph -Scopes 'DeviceManagementApps.Read.All'
    .\Get-MacLOBAppInventoryAudit.ps1 -FleetMinimumMacOS 14

.EXAMPLE
    .\Get-MacLOBAppInventoryAudit.ps1 -ChildAppWarnThreshold 2 -CheckIcons -OutputPath C:\Temp

.NOTES
    Requires: Microsoft.Graph.Authentication module; delegated or app permission DeviceManagementApps.Read.All.
    Uses the Graph beta endpoint (the macOSPkgApp/macOSDmgApp types and some properties are beta-first).
    Run as: any user with an Intune read role. No elevation needed. Read-only and safe.
    Minimum-OS property shape varies by app type and API version, so it's parsed defensively; treat
    "unknown" as "check in the portal".
#>
[CmdletBinding()]
param(
    [ValidateRange(1,50)][int]$ChildAppWarnThreshold = 3,
    [ValidateRange(0,40)][int]$FleetMinimumMacOS = 0,
    [switch]$CheckIcons,
    [string]$OutputPath = (Get-Location).Path
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    param([string]$Message, [string]$Status = 'INFO')
    $colour = switch ($Status) { 'OK' {'Green'} 'WARN' {'Yellow'} 'ERROR' {'Red'} default {'Cyan'} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-Prop {
    # StrictMode-safe property read from a hashtable/dictionary returned by Invoke-MgGraphRequest
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } else { return $null } }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $null
}

function Get-MinOsMajor {
    # minimumSupportedOperatingSystem is an object of booleans like v10_13, v11_0, v14_0 ... ; return the lowest true major
    param($MinOs)
    if ($null -eq $MinOs) { return $null }
    $keys = if ($MinOs -is [System.Collections.IDictionary]) { @($MinOs.Keys) } else { @($MinOs.PSObject.Properties.Name) }
    $majors = foreach ($k in $keys) {
        if ($k -match '^v(\d+)_(\d+)$' -and [bool](Get-Prop $MinOs $k)) {
            $maj = [int]$Matches[1]
            if ($maj -eq 10) { [double]("10." + $Matches[2]) } else { [double]$maj }
        }
    }
    if (@($majors).Count -eq 0) { return $null }
    return (@($majors) | Measure-Object -Minimum).Minimum
}

# ───────────────────────── Preflight ─────────────────────────
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    throw 'Microsoft.Graph.Authentication module not found. Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
}
$ctx = Get-MgContext
if (-not $ctx) {
    Write-Status 'Not connected to Graph - connecting with DeviceManagementApps.Read.All' 'WARN'
    Connect-MgGraph -Scopes 'DeviceManagementApps.Read.All' -NoWelcome
    $ctx = Get-MgContext
}
Write-Status "Connected to tenant $($ctx.TenantId) as $($ctx.Account)"
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

# ───────────────────────── Detect ─────────────────────────
$macTypes = @('#microsoft.graph.macOSLobApp', '#microsoft.graph.macOSPkgApp', '#microsoft.graph.macOSDmgApp')
$apps = New-Object System.Collections.Generic.List[object]
$uri = 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps'
do {
    $page = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType Hashtable
    foreach ($a in @(Get-Prop $page 'value')) {
        if ($macTypes -contains (Get-Prop $a '@odata.type')) { $apps.Add($a) }
    }
    $uri = Get-Prop $page '@odata.nextLink'
} while ($uri)
Write-Status "Found $($apps.Count) macOS LOB/PKG/DMG app objects"
if ($apps.Count -eq 0) { Write-Status 'Nothing to audit.' 'OK'; return }

# ───────────────────────── Execute: per-app checks ─────────────────────────
$rows = New-Object System.Collections.Generic.List[object]
foreach ($a in $apps) {
    $type = (Get-Prop $a '@odata.type') -replace '#microsoft.graph.', ''
    $id = Get-Prop $a 'id'
    $name = Get-Prop $a 'displayName'
    $findings = New-Object System.Collections.Generic.List[string]
    $raise = { param($lvl) if ($lvl -eq 'ERROR' -or ($lvl -eq 'WARN' -and $script:sev -ne 'ERROR')) { $script:sev = $lvl } }
    $script:sev = 'OK'

    $primaryBundle = $null; $primaryVersion = $null; $bundleList = @()
    switch ($type) {
        'macOSLobApp' {
            $primaryBundle = Get-Prop $a 'bundleId'
            $primaryVersion = Get-Prop $a 'versionNumber'
            $children = @(@(Get-Prop $a 'childApps') | Where-Object { $null -ne $_ })
            $bundleList = @($children | ForEach-Object { '{0}@{1}' -f (Get-Prop $_ 'bundleId'), (Get-Prop $_ 'versionNumber') })
            if ($children.Count -eq 0) { $findings.Add('childApps empty - detection has nothing to match'); & $raise 'ERROR' }
            elseif ($children.Count -gt $ChildAppWarnThreshold) { $findings.Add("childApps has $($children.Count) entries - prune helpers/frameworks that mdmclient won't report (0x87D13BA2)"); & $raise 'WARN' }
            $blank = @($children | Where-Object { [string]::IsNullOrWhiteSpace((Get-Prop $_ 'bundleId')) -or [string]::IsNullOrWhiteSpace((Get-Prop $_ 'versionNumber')) })
            if ($blank.Count -gt 0) { $findings.Add("$($blank.Count) childApps entries with blank bundleId/version"); & $raise 'WARN' }
            if (-not [bool](Get-Prop $a 'ignoreVersionDetection')) { $findings.Add('ignoreVersionDetection=false - self-updating apps will flip to Failed/Not detected after an update') }
            if ([bool](Get-Prop $a 'installAsManaged')) { $findings.Add('installAsManaged=true (macOS 11+, enables uninstall intent)') }
        }
        { $_ -in 'macOSPkgApp', 'macOSDmgApp' } {
            $primaryBundle = Get-Prop $a 'primaryBundleId'
            $primaryVersion = Get-Prop $a 'primaryBundleVersion'
            $included = @(@(Get-Prop $a 'includedApps') | Where-Object { $null -ne $_ })
            $bundleList = @($included | ForEach-Object { '{0}@{1}' -f (Get-Prop $_ 'bundleId'), (Get-Prop $_ 'bundleVersion') })
            if ($included.Count -eq 0) { $findings.Add('includedApps empty - detection has nothing to match'); & $raise 'ERROR' }
            if (-not [bool](Get-Prop $a 'ignoreVersionDetection')) { $findings.Add('ignoreVersionDetection=false') }
            if ($type -eq 'macOSPkgApp') {
                if (Get-Prop $a 'preInstallScript')  { $findings.Add('has pre-install script') }
                if (Get-Prop $a 'postInstallScript') { $findings.Add('has post-install script') }
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($primaryBundle)) { $findings.Add('primary bundle ID missing'); & $raise 'ERROR' }

    $pub = Get-Prop $a 'publishingState'
    if ($pub -and $pub -ne 'published') { $findings.Add("publishingState=$pub - upload/commit never completed"); & $raise 'ERROR' }

    $assigned = [bool](Get-Prop $a 'isAssigned')
    $intents = ''
    if (-not $assigned) { $findings.Add('not assigned'); & $raise 'WARN' }
    else {
        try {
            $as = Invoke-MgGraphRequest -Method GET -OutputType Hashtable -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$id/assignments"
            $intents = (@(Get-Prop $as 'value') | ForEach-Object { Get-Prop $_ 'intent' } | Sort-Object -Unique) -join ','
        } catch { $intents = 'lookup failed' }
    }

    $minOs = Get-MinOsMajor (Get-Prop $a 'minimumSupportedOperatingSystem')
    $minOsText = if ($null -eq $minOs) { 'unknown' } else { [string]$minOs }
    if ($FleetMinimumMacOS -gt 0 -and $null -ne $minOs -and $minOs -gt $FleetMinimumMacOS) {
        $findings.Add("min OS $minOs above fleet minimum $FleetMinimumMacOS - older Macs show Not applicable"); & $raise 'WARN'
    }

    $iconState = 'not checked'
    if ($CheckIcons) {
        try {
            $ic = Invoke-MgGraphRequest -Method GET -OutputType Hashtable -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/${id}?`$select=largeIcon"
            $iconState = if (Get-Prop $ic 'largeIcon') { 'present' } else { 'missing' }
            if ($iconState -eq 'missing') { $findings.Add('no icon (Company Portal cosmetic)') }
        } catch { $iconState = 'lookup failed' }
    }

    $rows.Add([pscustomobject]@{
        DisplayName = $name; Type = $type; Id = $id
        PrimaryBundleId = $primaryBundle; PrimaryVersion = $primaryVersion
        DetectionBundles = ($bundleList -join '; '); DetectionCount = $bundleList.Count
        IgnoreVersion = [bool](Get-Prop $a 'ignoreVersionDetection')
        MinOS = $minOsText; Assigned = $assigned; Intents = $intents
        PublishingState = $pub; Icon = $iconState
        LastModified = Get-Prop $a 'lastModifiedDateTime'
        Severity = $script:sev; Findings = ($findings -join ' | ')
    })
}

# ───────────────────────── Validate: cross-object checks ─────────────────────────
$dupes = $rows | Where-Object { $_.PrimaryBundleId } | Group-Object PrimaryBundleId | Where-Object Count -gt 1
foreach ($d in $dupes) {
    foreach ($r in $d.Group) {
        $others = ($d.Group | Where-Object Id -ne $r.Id | ForEach-Object { "$($_.DisplayName) [$($_.Type)]" }) -join ', '
        $r.Findings = (@($r.Findings, "duplicate primary bundle ID with: $others") | Where-Object { $_ }) -join ' | '
        if ($r.Severity -eq 'OK') { $r.Severity = 'WARN' }
    }
}

# ───────────────────────── Report ─────────────────────────
foreach ($r in ($rows | Sort-Object Severity, DisplayName)) {
    Write-Status ("{0} [{1}] {2}" -f $r.DisplayName, $r.Type, $(if ($r.Findings) { "- $($r.Findings)" } else { '' })) $r.Severity
}
$summary = $rows | Group-Object Severity | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Status ("Summary: {0} apps; {1}" -f $rows.Count, ($summary -join ', '))

$csv = Join-Path $OutputPath ("MacLOBAppInventoryAudit-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$rows | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Write-Status "CSV report: $csv" 'OK'
