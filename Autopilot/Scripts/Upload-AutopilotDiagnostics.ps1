
    # Set TLS protocol to ensure secure connections
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    foreach ($module in $requiredModules) {
        try {
            if (-not (Get-Module -ListAvailable -Name $module)) {
                Write-Host "Installing module: $module"
                Install-Module -Name $module -Force -Scope AllUsers -AllowClobber -ErrorAction Stop
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

# Function to create a SharePoint site named AutopilotDiagnostics
function Create-AutopilotDiagnosticsSite {
    try {
        Connect-PnPOnline -Url (Get-SharePointAdminUrl) -Interactive
        
        # Create the SharePoint site if it doesn't exist
        $siteTitle = "AutopilotDiagnostics"
        $siteUrl = "https://yourtenant.sharepoint.com/sites/$siteTitle" # Replace 'yourtenant' with your actual tenant name
        
        if (-not (Get-PnPTenantSite | Where-Object { $_.Url -eq $siteUrl })) {
            New-PnPSite -Type TeamSite -Title $siteTitle -Alias "AutopilotDiagnostics" -IsPublic $true
            Write-Host "Created SharePoint site: $siteTitle"
        } else {
            Write-Host "SharePoint site already exists: $siteTitle"
        }

        Disconnect-PnPOnline

    } catch {
        Write-Host "Error creating SharePoint site: $_"
    }
}

# Function to upload report to SharePoint in a folder named after the machine's serial number
function Upload-ReportToSharePoint {
    param (
        [string]$ReportPath,
        [string]$SerialNumber
    )

    try {
        Connect-PnPOnline -Url (Get-SharePointAdminUrl) -Interactive
        
        # Create folder name based on machine's serial number
        $folderName = "$SerialNumber"

        # Check if target folder exists, create if not
        if (-not (Get-PnPFolder -Url "/sites/AutopilotDiagnostics/$folderName" -ErrorAction SilentlyContinue)) {
            New-PnPFolder -Name $folderName -Folder "/sites/AutopilotDiagnostics" -Web (Get-PnPWeb).Url 
            Write-Host "Created folder: /sites/AutopilotDiagnostics/$folderName"
        }

        Add-PnPFile -Path $ReportPath -Folder "/sites/AutopilotDiagnostics/$folderName"
        
        Disconnect-PnPOnline
        
        return "Report uploaded successfully to SharePoint in folder '$folderName'."
        
    } catch {
        return "Error uploading report to SharePoint: $_"
    }
}

# Main script execution starts here

# Create AutopilotDiagnostics site without prompting for URL
Create-AutopilotDiagnosticsSite

# Get machine's serial number using WMI (Windows Management Instrumentation)
$serialNumber = (Get-WmiObject Win32_BIOS).SerialNumber

# Example placeholder for results collection (replace with actual logic)
$results = @("Sample report data")  # Replace this with your actual connectivity test results collection logic

# Save results to a file locally before attempting upload
$reportPath = "$env:TEMP\AutopilotConnectivityReport.csv"
$results | Export-Csv -Path $reportPath -NoTypeInformation

Write-Host "`nDetailed report saved locally to: $reportPath"

# Attempt to upload report to SharePoint in a folder named after the machine's serial number
$uploadResult = Upload-ReportToSharePoint -ReportPath $reportPath -SerialNumber $serialNumber
Write-Host "$uploadResult"

# Output summary to console at the end of the script execution.
Write-Host "`nFinal Report Location: `"$reportPath`" and uploaded location: `"/sites/AutopilotDiagnostics/$serialNumber/$(Split-Path $reportPath -Leaf)`""
