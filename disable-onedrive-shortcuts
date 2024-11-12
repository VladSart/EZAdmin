# Install SharePoint Online Management Shell if not already installed
if (!(Get-Module -ListAvailable -Name Microsoft.Online.SharePoint.PowerShell)) {
    Install-Module -Name Microsoft.Online.SharePoint.PowerShell -Force -Scope CurrentUser
}

# Install Microsoft Graph PowerShell SDK if not already installed
if (!(Get-Module -ListAvailable -Name Microsoft.Graph)) {
    Install-Module -Name Microsoft.Graph -Force -Scope CurrentUser
}

# Connect to Microsoft Graph
Connect-MgGraph -Scopes "Organization.Read.All"

# Get tenant domain
$tenantDomain = (Get-MgOrganization).VerifiedDomains | Where-Object { $_.IsDefault -eq $true } | Select-Object -ExpandProperty Name

# Construct SharePoint admin URL
$tenantUrl = "https://$($tenantDomain.Split('.')[0])-admin.sharepoint.com"

# Connect to SharePoint Online
Connect-SPOService -Url $tenantUrl

# Disable "Add shortcut to OneDrive" feature
Set-SPOTenant -DisableAddShortcutsToOneDrive $True

# Verify the change
Get-SPOTenant | Select-Object DisableAddShortcutsToOneDrive

Write-Host "The 'Add shortcut to OneDrive' feature has been disabled for $tenantUrl. Changes may take 15-20 minutes to propagate."

# Disconnect from services
Disconnect-MgGraph
Disconnect-SPOService
