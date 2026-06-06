# Define variables - Edit these for each use
$calendarOwner = "user1@contoso.com"  # Replace with the calendar owner's email address
$newUser = "user2@contoso.com"        # Replace with the new user's email address

# Import the Exchange Online PowerShell module
Import-Module ExchangeOnlineManagement

# Connect to Exchange Online PowerShell
Connect-ExchangeOnline

# Check if variables are set
if (-not $calendarOwner -or -not $newUser) {
    Write-Host "Error: Please set both `$calendarOwner and `$newUser variables at the top of the script." -ForegroundColor Red
    exit
}

# Set calendar permissions
Write-Host "Setting calendar permissions for $newUser on $calendarOwner's calendar..."
Set-MailboxFolderPermission -Identity "$calendarOwner:\Calendar" -User $newUser -AccessRights Owner

# Verify the permissions
Write-Host "Verifying permissions..."
$permissions = Get-MailboxFolderPermission -Identity "$calendarOwner:\Calendar"

# Display all permissions
Write-Host "Current permissions on $calendarOwner's calendar:"
$permissions | Format-Table User, AccessRights -AutoSize

# Check if the new user has the correct permissions
$newUserPermission = $permissions | Where-Object {$_.User.DisplayName -eq $newUser}
if ($newUserPermission) {
    Write-Host "Confirmed: $newUser has $($newUserPermission.AccessRights) rights on $calendarOwner's calendar." -ForegroundColor Green
} else {
    Write-Host "Warning: Could not find permissions for $newUser on $calendarOwner's calendar." -ForegroundColor Yellow
}
