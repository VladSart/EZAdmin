powershell.exe
# Enable VBS
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard"
Set-ItemProperty -Path $regPath -Name "EnableVirtualizationBasedSecurity" -Value 1
Set-ItemProperty -Path $regPath -Name "RequirePlatformSecurityFeatures" -Value 3

# Enable Credential Guard
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\LSA"
Set-ItemProperty -Path $regPath -Name "LsaCfgFlags" -Value 1

