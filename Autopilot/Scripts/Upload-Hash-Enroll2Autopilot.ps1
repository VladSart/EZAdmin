powershell.exe
# Set TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Install the Get-WindowsAutopilotInfo script
Install-Script -Name Get-WindowsAutopilotInfo -Force

# Set execution policy for the current process
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned

# Upload the hash and enroll the device
Get-WindowsAutopilotInfo -Online
