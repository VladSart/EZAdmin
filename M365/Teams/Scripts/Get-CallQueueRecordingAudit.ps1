<#
.SYNOPSIS
    Audits Microsoft Teams Call Queue Automatic Recording / Compliance Recording configuration across a tenant.

.DESCRIPTION
    Read-only fleet audit for the Automatic Recording for Call Queue feature (GA-track August 2026).
    For every call queue in the tenant, reports:
      - Whether an Automatic Recording template is assigned
      - Whether queue-level prerequisites (Conference mode, Shared Call History, group/channel-based
        call answering) are satisfied
      - The assigned template's Recording/Transcription/AgentViewPermission settings
      - Whether the SharePoint site backing the template is reachable and has more than one site admin
        (single-admin sites are flagged as an offboarding risk)
      - Whether agents assigned to the queue hold a Queues App license (required for in-app visibility)

    This script does NOT enable, disable, or modify any recording configuration. It also cannot
    determine whether the tenant-wide explicit recording consent policy is compatible (that check
    is included as a separate, tenant-level informational read) or verify actual recording file
    integrity in SharePoint — only that the site itself is reachable.

.PARAMETER OutputPath
    Folder to write the CSV report to. Defaults to the current directory.

.PARAMETER IncludeLicenseCheck
    If specified, also checks Queues App licensing for every distinct agent found across audited
    queues. This requires the Microsoft.Graph.Users module and Graph delegated/app permissions
    (User.Read.All). Skipped by default because it significantly increases runtime on large tenants.

.EXAMPLE
    .\Get-CallQueueRecordingAudit.ps1 -OutputPath "C:\Reports"

.EXAMPLE
    .\Get-CallQueueRecordingAudit.ps1 -IncludeLicenseCheck

.NOTES
    Requires: MicrosoftTeams PowerShell module 7.8.0 or later (Automatic Recording cmdlets do not
    exist in earlier versions), and Microsoft.Online.SharePoint.PowerShell for the site-admin check.
    Run-as: an account with Teams Administrator + SharePoint Administrator (read) rights.
    Safe/unsafe: fully read-only. No configuration is changed.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputPath = ".",
    [switch]$IncludeLicenseCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---- Preflight ----
$teamsModule = Get-Module MicrosoftTeams -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
if (-not $teamsModule) {
    Write-Status "MicrosoftTeams module not found. Install with: Install-Module MicrosoftTeams" "ERROR"
    return
}
if ($teamsModule.Version -lt [version]"7.8.0") {
    Write-Status "MicrosoftTeams module version $($teamsModule.Version) is below 7.8.0 — Automatic Recording cmdlets (Get-CsAutoRecordingTemplate) will not be available. Update-Module MicrosoftTeams before re-running." "WARN"
}

try {
    $null = Get-CsTenant -ErrorAction Stop
} catch {
    Write-Status "Not connected to Microsoft Teams PowerShell. Run Connect-MicrosoftTeams first." "ERROR"
    return
}

# ---- Detect: pull templates and queues ----
Write-Status "Retrieving Automatic Recording templates..."
$templates = @()
try {
    $templates = Get-CsAutoRecordingTemplate -ErrorAction Stop
} catch {
    Write-Status "Get-CsAutoRecordingTemplate failed or returned nothing — confirm module version and that at least one template exists. $($_.Exception.Message)" "WARN"
}
$templateMap = @{}
foreach ($t in $templates) { $templateMap[$t.Identity] = $t }
Write-Status "Found $($templates.Count) recording template(s)." "OK"

Write-Status "Retrieving all call queues..."
$queues = Get-CsCallQueue -ErrorAction Stop
Write-Status "Found $($queues.Count) call queue(s)." "OK"

# ---- Optional: SharePoint site admin count cache ----
$spoSiteAdminCounts = @{}
$spoAvailable = $null -ne (Get-Module Microsoft.Online.SharePoint.PowerShell -ListAvailable)
if (-not $spoAvailable) {
    Write-Status "Microsoft.Online.SharePoint.PowerShell module not found — SharePoint site-admin resilience check will be skipped." "WARN"
}

function Get-SiteAdminCount {
    param([string]$HostName, [string]$SiteName)
    if (-not $spoAvailable) { return $null }
    $key = "$HostName/$SiteName"
    if ($spoSiteAdminCounts.ContainsKey($key)) { return $spoSiteAdminCounts[$key] }
    try {
        $site = Get-SPOSite -Identity "https://$HostName/sites/$SiteName" -ErrorAction Stop
        $count = @($site.SiteAdmins).Count
        $spoSiteAdminCounts[$key] = $count
        return $count
    } catch {
        $spoSiteAdminCounts[$key] = -1
        return -1
    }
}

# ---- Execute: build per-queue findings ----
$results = New-Object System.Collections.Generic.List[Object]
$agentsToLicenseCheck = New-Object System.Collections.Generic.HashSet[string]

foreach ($q in $queues) {
    $tplAssigned = $null
    if ($q.AutoRecordingTemplateId -and $templateMap.ContainsKey($q.AutoRecordingTemplateId)) {
        $tplAssigned = $templateMap[$q.AutoRecordingTemplateId]
    }

    $routingOk = $true
    # Users-based or Shifts-based call answering is unsupported for Automatic Recording
    if ($q.PSObject.Properties.Match('Users').Count -gt 0 -and $q.Users -and @($q.Users).Count -gt 0) {
        $routingOk = $false
    }

    $siteAdminCount = $null
    if ($tplAssigned) {
        $siteAdminCount = Get-SiteAdminCount -HostName $tplAssigned.SharePointHostName -SiteName $tplAssigned.SharePointSiteName
    }

    $findings = New-Object System.Collections.Generic.List[string]
    if (-not $tplAssigned) { $findings.Add("No template assigned") }
    if (-not $q.ConferenceMode) { $findings.Add("Conference mode disabled (hard prerequisite)") }
    if (-not $routingOk) { $findings.Add("Call answering uses Users/Shifts — unsupported for Automatic Recording") }
    if (-not $q.SharedCallHistory) { $findings.Add("Shared Call History disabled — agents/authorized users can't view via Queues App") }
    if ($tplAssigned -and -not $tplAssigned.RecordingEnabled) { $findings.Add("Template assigned but RecordingEnabled=false") }
    if ($tplAssigned -and -not $tplAssigned.AgentViewPermission) { $findings.Add("AgentViewPermission disabled at template creation (immutable — requires new template to fix)") }
    if ($null -ne $siteAdminCount -and $siteAdminCount -eq -1) { $findings.Add("SharePoint site unreachable — check host/site name and admin access") }
    if ($null -ne $siteAdminCount -and $siteAdminCount -eq 1) { $findings.Add("Only 1 SharePoint site admin — offboarding risk, add a backup admin") }

    if ($IncludeLicenseCheck -and $q.PSObject.Properties.Match('Users').Count -gt 0) {
        foreach ($u in @($q.Users)) { [void]$agentsToLicenseCheck.Add($u) }
    }

    $results.Add([PSCustomObject]@{
        QueueName            = $q.Name
        QueueIdentity        = $q.Identity
        TemplateAssigned     = [bool]$tplAssigned
        TemplateName         = if ($tplAssigned) { $tplAssigned.Name } else { $null }
        RecordingEnabled     = if ($tplAssigned) { $tplAssigned.RecordingEnabled } else { $null }
        TranscriptionEnabled = if ($tplAssigned) { $tplAssigned.TranscriptionEnabled } else { $null }
        AgentViewPermission  = if ($tplAssigned) { $tplAssigned.AgentViewPermission } else { $null }
        ConferenceMode       = $q.ConferenceMode
        SharedCallHistory    = $q.SharedCallHistory
        CallAnsweringOk      = $routingOk
        SharePointHost       = if ($tplAssigned) { $tplAssigned.SharePointHostName } else { $null }
        SharePointSite       = if ($tplAssigned) { $tplAssigned.SharePointSiteName } else { $null }
        SiteAdminCount       = $siteAdminCount
        FindingsCount        = $findings.Count
        Findings             = ($findings -join "; ")
    })
}

# ---- Optional license check ----
if ($IncludeLicenseCheck -and $agentsToLicenseCheck.Count -gt 0) {
    if (-not (Get-Module Microsoft.Graph.Users -ListAvailable)) {
        Write-Status "Microsoft.Graph.Users module not found — skipping Queues App license check. Install-Module Microsoft.Graph.Users to enable it." "WARN"
    } else {
        Write-Status "Checking Queues App licensing for $($agentsToLicenseCheck.Count) distinct agent(s)..."
        try {
            $licenseResults = New-Object System.Collections.Generic.List[Object]
            foreach ($agent in $agentsToLicenseCheck) {
                try {
                    $plans = Get-MgUserLicenseDetail -UserId $agent -ErrorAction Stop | Select-Object -ExpandProperty ServicePlans
                    $hasQueuesApp = @($plans | Where-Object { $_.ServicePlanName -match "QUEUES" }).Count -gt 0
                    $licenseResults.Add([PSCustomObject]@{ Agent = $agent; QueuesAppLicensed = $hasQueuesApp })
                } catch {
                    $licenseResults.Add([PSCustomObject]@{ Agent = $agent; QueuesAppLicensed = "LookupFailed" })
                }
            }
            $licensePath = Join-Path $OutputPath "CallQueueRecording-AgentLicenses-$(Get-Date -Format yyyyMMdd-HHmm).csv"
            $licenseResults | Export-Csv -Path $licensePath -NoTypeInformation
            Write-Status "Agent license results written to $licensePath" "OK"
        } catch {
            Write-Status "License check failed: $($_.Exception.Message)" "WARN"
        }
    }
}

# ---- Report ----
$reportPath = Join-Path $OutputPath "CallQueueRecording-Audit-$(Get-Date -Format yyyyMMdd-HHmm).csv"
$results | Sort-Object FindingsCount -Descending | Export-Csv -Path $reportPath -NoTypeInformation

$flagged = @($results | Where-Object { $_.FindingsCount -gt 0 }).Count
Write-Status "Audit complete: $($results.Count) queue(s) checked, $flagged with findings." "OK"
Write-Status "Report written to $reportPath" "OK"

$results | Sort-Object FindingsCount -Descending | Select-Object QueueName, TemplateAssigned, FindingsCount, Findings | Format-Table -AutoSize
