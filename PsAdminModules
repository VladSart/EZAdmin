# Call the function to check for PowerShell version
Check-PowerShellVersion

# Part 1: Ensure required PowerShell modules are installed and imported

function Ensure-Modules {
    $requiredModules = @(
        "PnP.PowerShell",           # PnP PowerShell for SharePoint
        "Microsoft.Graph",          # Microsoft Graph PowerShell
        "ExchangeOnlineManagement",  # Exchange Online Management
        "AzureAD",                  # Azure Active Directory PowerShell for Graph
        "MSOnline"                  # MSOnline module for legacy Azure AD management
    )

    # Set TLS protocol to ensure secure connections
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    foreach ($module in $requiredModules) {
        try {
            if (-not (Get-Module -ListAvailable -Name $module)) {
                Write-Host "Installing module: $module"
                Install-Module -Name $module -Force -Scope CurrentUser -AllowClobber -ErrorAction Stop
            } else {
                Write-Host "Module already installed: $module"
            }
            Import-Module -Name $module -ErrorAction Stop  
        } catch {
            Write-Host "Failed to install or import module ${module}: $_"
        }
    }
}

# Call the function to ensure all required modules are installed and imported
Ensure-Modules
