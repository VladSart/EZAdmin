<#
.SYNOPSIS
    Creates a new SharePoint Online site (Team Site or Communication Site) via Microsoft Graph API.

.DESCRIPTION
    Provisions a SharePoint Online site using the Graph /sites endpoint, which supports
    both modern Team Sites (Microsoft 365 Group-backed) and Communication Sites.

    Covers:
    - Team Site creation (creates backing M365 Group automatically)
    - Communication Site creation (no group, clean SPO site)
    - SensitivityLabel assignment at creation time
    - Optional: add owners and members to the backing M365 Group
    - Polls for provisioning completion and outputs the final site URL
    - Exports a provisioning report to CSV

    Does NOT cover:
    - Hub site registration (use Register-PnPHubSite or Graph separately)
    - Site design/script application (use Invoke-SPOSiteDesign post-provision)
    - SharePoint Admin quota/storage configuration
    - Teams channel provisioning on the backing Group

.PARAMETER SiteType
    Type of site to create. 'TeamSite' or 'CommunicationSite'. Required.

.PARAMETER DisplayName
    Display name for the site / group. Required.

.PARAMETER Alias
    URL alias (no spaces). Used as the URL slug: https://<tenant>.sharepoint.com/sites/<Alias>.
    For TeamSite, also becomes the M365 Group email prefix. Required.

.PARAMETER Description
    Optional description for the site.

.PARAMETER IsPublic
    For TeamSite only. $true = public group (all users can find and join). Default: $false (private).

.PARAMETER Owners
    Array of UPNs to add as owners of the backing M365 Group (TeamSite) or Site Collection Admins (CommSite).

.PARAMETER Members
    Array of UPNs to add as members (TeamSite only; CommSite has no group members).

.PARAMETER SensitivityLabelId
    Optional GUID of a sensitivity label to apply at creation. Get label GUIDs via:
    Get-MgBetaGroupSettingTemplate or the compliance portal.

.PARAMETER TenantName
    Your tenant name (the part before .onmicrosoft.com). e.g. "contoso". Required.

.PARAMETER WaitForProvisioningMinutes
    How many minutes to poll for provisioning completion. Default: 10.

.PARAMETER ExportPath
    Path for the CSV report. Default: .\SiteProvisioning-<timestamp>.csv

.EXAMPLE
    .\New-SharePointSiteViaGraph.ps1 `
        -SiteType TeamSite `
        -DisplayName "Project Alpha" `
        -Alias "project-alpha" `
        -Description "Collaboration space for Project Alpha" `
        -Owners "alice@contoso.com","bob@contoso.com" `
        -TenantName "contoso"

.EXAMPLE
    .\New-SharePointSiteViaGraph.ps1 `
        -SiteType CommunicationSite `
        -DisplayName "IT Help Desk" `
        -Alias "it-helpdesk" `
        -TenantName "contoso"

.NOTES
    Requires: Microsoft.Graph PowerShell SDK (Install-Module Microsoft.Graph)
    Permissions needed (delegated OR app):
        - Group.ReadWrite.All (TeamSite)
        - Sites.ReadWrite.All (CommunicationSite)
        - User.Read.All (to resolve UPNs to Object IDs for owners/members)
    Run-as: Global Admin OR SharePoint Admin + Group Admin
    Safe: Creates resources — confirm alias/display name before running
    Idempotency: Script checks if alias already exists before creating
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateSet("TeamSite","CommunicationSite")]
    [string]$SiteType,

    [Parameter(Mandatory)][string]$DisplayName,
    [Parameter(Mandatory)][string]$Alias,
    [string]$Description = "",

    [bool]$IsPublic = $false,

    [string[]]$Owners  = @(),
    [string[]]$Members = @(),

    [string]$SensitivityLabelId,

    [Parameter(Mandatory)][string]$TenantName,

    [int]$WaitForProvisioningMinutes = 10,

    [string]$ExportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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
Write-Status "New-SharePointSiteViaGraph — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\SiteProvisioning-$timestamp.csv"
}

# Check Graph module
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Sites)) {
    Write-Status "Microsoft.Graph module not found. Run: Install-Module Microsoft.Graph -Scope CurrentUser" "ERROR"
    exit 1
}

# Connect — request only the scopes we need
$scopes = @("Group.ReadWrite.All", "Sites.ReadWrite.All", "User.Read.All")
Write-Status "Connecting to Microsoft Graph (scopes: $($scopes -join ', '))..."
Connect-MgGraph -Scopes $scopes -NoWelcome -ErrorAction Stop
Write-Status "Connected to Graph" "OK"
#endregion

#region ─── Check alias availability ─────────────────────────────────────────
Write-Status "Checking alias availability: $Alias"

$expectedUrl = "https://$TenantName.sharepoint.com/sites/$Alias"

# Check via Graph sites search
try {
    $existingSite = Get-MgSite -SiteId "$TenantName.sharepoint.com:/sites/$Alias" -ErrorAction SilentlyContinue
} catch {
    $existingSite = $null
}

if ($existingSite) {
    Write-Status "A site already exists at $expectedUrl" "ERROR"
    Write-Status "Existing site ID: $($existingSite.Id)" "ERROR"
    exit 1
}

Write-Status "Alias '$Alias' appears available" "OK"
#endregion

#region ─── Resolve owner / member Object IDs ────────────────────────────────
function Resolve-UserObjectId {
    param([string]$UPN)
    try {
        $user = Get-MgUser -UserId $UPN -ErrorAction Stop
        return $user.Id
    } catch {
        Write-Status "Could not resolve user '$UPN': $_" "WARN"
        return $null
    }
}

$ownerIds  = @()
$memberIds = @()

if ($Owners) {
    Write-Status "Resolving $($Owners.Count) owner(s)..."
    foreach ($upn in $Owners) {
        $id = Resolve-UserObjectId -UPN $upn
        if ($id) { $ownerIds += $id }
    }
}

if ($Members -and $SiteType -eq "TeamSite") {
    Write-Status "Resolving $($Members.Count) member(s)..."
    foreach ($upn in $Members) {
        $id = Resolve-UserObjectId -UPN $upn
        if ($id) { $memberIds += $id }
    }
}
#endregion

#region ─── Build request body ────────────────────────────────────────────────
$report = [PSCustomObject]@{
    SiteType        = $SiteType
    DisplayName     = $DisplayName
    Alias           = $Alias
    ExpectedURL     = $expectedUrl
    Owners          = ($Owners -join ", ")
    Members         = ($Members -join ", ")
    SensitivityLabel = $SensitivityLabelId
    ProvisionedAt   = $null
    SiteId          = $null
    ActualURL       = $null
    Status          = "Pending"
    Error           = $null
    RunAt           = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
}

if ($SiteType -eq "TeamSite") {
    # Team Site = M365 Group-connected site
    # Use the Groups endpoint; SPO site is provisioned automatically
    Write-Status "Creating M365 Group-backed Team Site..."

    $groupBody = @{
        displayName     = $DisplayName
        description     = $Description
        mailEnabled     = $true
        mailNickname    = $Alias
        securityEnabled = $false
        groupTypes      = @("Unified")
        visibility      = if ($IsPublic) { "Public" } else { "Private" }
        "owners@odata.bind"  = @($ownerIds  | ForEach-Object { "https://graph.microsoft.com/v1.0/users/$_" })
        "members@odata.bind" = @($memberIds | ForEach-Object { "https://graph.microsoft.com/v1.0/users/$_" })
    }

    if ($SensitivityLabelId) {
        $groupBody["assignedLabels"] = @(@{ labelId = $SensitivityLabelId })
    }

    if ($PSCmdlet.ShouldProcess($DisplayName, "Create M365 Group (Team Site)")) {
        try {
            $newGroup = New-MgGroup -BodyParameter $groupBody -ErrorAction Stop
            Write-Status "M365 Group created: $($newGroup.Id)" "OK"
            $report.SiteId = $newGroup.Id
            $report.Status = "GroupCreated"
        } catch {
            $report.Status = "Failed"
            $report.Error  = $_.Exception.Message
            Write-Status "Group creation failed: $_" "ERROR"
            $report | Export-Csv -Path $ExportPath -NoTypeInformation
            exit 1
        }
    }

    # Poll for SPO site to be provisioned
    Write-Status "Polling for SharePoint site provisioning (up to $WaitForProvisioningMinutes min)..."
    $deadline   = (Get-Date).AddMinutes($WaitForProvisioningMinutes)
    $siteReady  = $false

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        try {
            $spSite = Get-MgGroupSite -GroupId $newGroup.Id -ErrorAction SilentlyContinue
            if ($spSite -and $spSite.WebUrl) {
                $siteReady      = $true
                $report.ActualURL = $spSite.WebUrl
                $report.Status    = "Provisioned"
                $report.ProvisionedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                Write-Status "Site provisioned: $($spSite.WebUrl)" "OK"
                break
            }
        } catch {
            Write-Verbose "Site not ready yet: $_"
        }
        Write-Status "  Still provisioning... ($('{0:mm\:ss}' -f ((Get-Date) - (Get-Date).AddMinutes($WaitForProvisioningMinutes) + [timespan]::FromMinutes($WaitForProvisioningMinutes))) elapsed)" "INFO"
    }

    if (-not $siteReady) {
        Write-Status "Site not detected within timeout. Group was created — site may still provision. Check: $expectedUrl" "WARN"
        $report.Status = "ProvisioningTimeout"
        $report.ActualURL = $expectedUrl
    }

} else {
    # Communication Site — use SharePoint provisioning via Graph (beta endpoint)
    Write-Status "Creating Communication Site via Graph beta endpoint..."

    $commSiteBody = @{
        displayName  = $DisplayName
        description  = $Description
        "root" = @{}
        siteCollection = @{
            hostname = "$TenantName.sharepoint.com"
        }
    } # Note: Comm sites via pure Graph are limited; PnP.PowerShell or SPO module preferred for full control

    # More reliable approach: use SharePoint REST API via Invoke-MgGraphRequest
    $commSitePayload = @{
        request = @{
            "__metadata" = @{ "type" = "SP.Publishing.CommunicationSiteCreationRequest" }
            AllowFileSharingForGuestUsers = $false
            Classification               = ""
            Description                  = $Description
            SiteDesignId                 = "00000000-0000-0000-0000-000000000000"  # default design
            Title                        = $DisplayName
            Url                          = $expectedUrl
            lcid                         = 1033
        }
    }

    if ($PSCmdlet.ShouldProcess($DisplayName, "Create Communication Site")) {
        try {
            $spoAdminUrl = "https://$TenantName-admin.sharepoint.com"
            $createUri   = "https://graph.microsoft.com/v1.0/sites/root/sites"

            # Use PnP if available (more reliable for CommSite)
            if (Get-Module -ListAvailable -Name PnP.PowerShell) {
                Write-Status "PnP.PowerShell found — using New-PnPSite for Communication Site..."
                Connect-PnPOnline -Url $spoAdminUrl -Interactive
                $newSite = New-PnPSite -Type CommunicationSite -Title $DisplayName -Url $expectedUrl -Description $Description -ErrorAction Stop
                $report.ActualURL    = $expectedUrl
                $report.Status       = "Provisioned"
                $report.ProvisionedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                Write-Status "Communication Site provisioned: $expectedUrl" "OK"
            } else {
                # Fallback: Graph POST to /sites (requires Sites.Manage.All)
                Write-Status "PnP.PowerShell not found. Attempting via Graph (limited support for CommSite)." "WARN"
                Write-Status "Recommended: Install-Module PnP.PowerShell for full Communication Site support." "WARN"

                $result = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/sites/contoso.sharepoint.com:/sites" -Body ($commSiteBody | ConvertTo-Json -Depth 5) -ContentType "application/json"
                $report.SiteId    = $result.id
                $report.ActualURL = $result.webUrl
                $report.Status    = "Provisioned"
                $report.ProvisionedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                Write-Status "Communication Site created: $($result.webUrl)" "OK"
            }

        } catch {
            $report.Status = "Failed"
            $report.Error  = $_.Exception.Message
            Write-Status "Communication Site creation failed: $_" "ERROR"
            $report | Export-Csv -Path $ExportPath -NoTypeInformation
            exit 1
        }

        # Assign owners as Site Collection Admins for CommSite
        if ($ownerIds -and $report.Status -eq "Provisioned") {
            Write-Status "Assigning $($ownerIds.Count) owner(s) as Site Collection Admin(s)..."
            foreach ($ownerId in $ownerIds) {
                try {
                    $ownerUpn = (Get-MgUser -UserId $ownerId).UserPrincipalName
                    # SPO admin assignment requires SharePoint module or PnP
                    if (Get-Module -ListAvailable -Name PnP.PowerShell) {
                        Set-PnPSite -Url $expectedUrl -Owners $ownerUpn
                        Write-Status "  Assigned owner: $ownerUpn" "OK"
                    } else {
                        Write-Status "  Cannot assign owner without PnP.PowerShell — assign manually: $ownerUpn" "WARN"
                    }
                } catch {
                    Write-Status "  Failed to assign owner $ownerId : $_" "WARN"
                }
            }
        }
    }
}
#endregion

#region ─── Final summary ─────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── Provisioning Summary ──────────────────────────" -ForegroundColor Cyan
Write-Host "  Site Type   : $SiteType"
Write-Host "  Display Name: $DisplayName"
Write-Host "  Status      : $($report.Status)"
Write-Host "  URL         : $($report.ActualURL)"
if ($report.ProvisionedAt) {
    Write-Host "  Provisioned : $($report.ProvisionedAt)"
}
if ($report.Error) {
    Write-Host "  Error       : $($report.Error)" -ForegroundColor Red
}
Write-Host ""

$report | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Report exported → $ExportPath" "OK"
Write-Status "Done — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
