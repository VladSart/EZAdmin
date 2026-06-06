# Hybrid Join Autopilot — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Triage

Run these on the target device from a local admin session (or OOBE debug shell via Shift+F10):

```powershell
# 1. Check Autopilot profile assignment and join type
Get-Item "HKLM:\SOFTWARE\Microsoft\Provisioning\Diagnostics\AutoPilot" | Select-Object -ExpandProperty Property | ForEach-Object { "$_ = $(Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\Provisioning\Diagnostics\AutoPilot' -Name $_)" }

# 2. Check domain join status
dsregcmd /status | Select-String "DomainJoined|AzureAdJoined|EnterpriseJoined|TenantId"

# 3. Validate ODJ blob receipt (Offline Domain Join)
Get-ChildItem "C:\Windows\Provisioning\Autopilot\" -ErrorAction SilentlyContinue

# 4. Check Intune connector (ODJ connector) health — run from the connector server
Get-Service -Name "ODJConnectorSvc" | Select-Object Name, Status, StartType

# 5. Check recent MDM enrollment event log for failures
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" -MaxEvents 20 | Where-Object { $_.LevelDisplayName -eq "Error" } | Select-Object TimeCreated, Message
```

| Result | Action |
|--------|--------|
| `DomainJoined: NO` after reboot | ODJ blob not applied → Fix 1 |
| ODJ connector service stopped | Restart ODJConnectorSvc on connector server → Fix 2 |
| No blob in `C:\Windows\Provisioning\Autopilot\` | Intune connector never delivered blob → Fix 2 |
| `AzureAdJoined: YES` but `DomainJoined: NO` | Device enrolled as Azure AD Join, not Hybrid — profile misconfiguration → Fix 3 |
| Event log shows `0x801c03ed` | Entra token issue — device not pre-staged or wrong Autopilot profile → Fix 3 |
| Connector healthy, blob present, still failing | Clock skew or DNS issue on device → Fix 4 |

---

## Dependency Cascade

<details><summary>What must be true for Hybrid Autopilot to work</summary>

```
Internet connectivity (device) ─────────────────────────────────────┐
                                                                     ▼
Autopilot profile in Intune ──────► Device hardware hash registered ─► Profile assigned to device
                                                                     │
                                                                     ▼
                                              Intune ODJ Connector (on-prem server)
                                                │  - HTTPS outbound to *.manage.microsoft.com
                                                │  - HTTPS outbound to enterpriseregistration.windows.net
                                                │  - Domain Admin or delegated OU rights
                                                ▼
                                    Active Directory (on-prem DC)
                                                │  - OU in connector's scope
                                                │  - Connector has "Create Computer Objects" rights
                                                ▼
                                         ODJ Blob generated
                                                │
                                                ▼
                                    Blob delivered to device via Intune
                                                │
                                                ▼
                                    Device reboots → domain join applied
                                                │
                                                ▼
                                    Device calls back to Intune (MDM enroll)
                                                │
                                                ▼
                                    ESP completes → User signs in
```
</details>

---

## Diagnosis & Validation Flow

1. **Confirm the Autopilot profile is Hybrid Azure AD Join type**
   ```powershell
   # Run from any admin machine with Graph/Intune PowerShell
   Connect-MgGraph -Scopes "DeviceManagementServiceConfig.Read.All"
   Get-MgDeviceManagementWindowsAutopilotDeploymentProfile | Select-Object DisplayName, @{N="JoinType";E={$_.OutOfBoxExperienceSettings.DeviceUsageType}}
   ```
   Expected: `JoinType` = `hybridAzureADJoined`  
   Bad: `JoinType` = `azureADJoined` → wrong profile, device will not do hybrid join

2. **Verify ODJ Connector is installed and healthy**
   ```powershell
   # Run on connector server
   Get-Service "ODJConnectorSvc" | Select-Object Name, Status
   Get-EventLog -LogName Application -Source "ODJ Connector Service" -Newest 20 | Select-Object TimeGenerated, EntryType, Message
   ```
   Expected: Service Running, no errors in last 20 events  
   Bad: Stopped, or events showing `Unable to reach Intune`

3. **Check connector server outbound connectivity**
   ```powershell
   # Run on connector server
   Test-NetConnection -ComputerName "enterpriseregistration.windows.net" -Port 443
   Test-NetConnection -ComputerName "manage.microsoft.com" -Port 443
   Test-NetConnection -ComputerName "login.microsoftonline.com" -Port 443
   ```
   Expected: `TcpTestSucceeded: True` for all  
   Bad: Any `False` → firewall/proxy blocking connector outbound

4. **Validate connector account has OU permissions**
   ```powershell
   # Run on DC — check ACL on target OU
   $OU = "OU=<AutopilotOU>,DC=<domain>,DC=<tld>"
   (Get-Acl "AD:$OU").Access | Where-Object { $_.IdentityReference -like "*<ConnectorAccount>*" }
   ```
   Expected: `CreateChild` right for `computer` objects  
   Bad: No entry for connector account → Fix 2

5. **Check device-side MDM enrollment logs**
   ```powershell
   # Run on device (debug shell or post-boot)
   Get-WinEvent -LogName "Microsoft-Windows-User Device Registration/Admin" -MaxEvents 30 |
     Select-Object TimeCreated, Id, Message | Format-List
   ```
   Expected: Event IDs 304 (join succeeded) or similar success codes  
   Bad: Event ID 335 (hybrid join failed), 104 (network), 360+ (token issues)

---

## Common Fix Paths

<details><summary>Fix 1 — ODJ blob present but domain join not applied after reboot</summary>

The device received the blob from Intune but the join was not applied. Usually a timing or service issue during OOBE.

```powershell
# Run on device — verify blob exists
Get-ChildItem "C:\Windows\Provisioning\Autopilot\" | Select-Object Name, LastWriteTime

# If blob exists, force apply it (requires restart)
# This is handled automatically by Windows at next boot via the provisioning engine.
# Ensure the device is NOT reimaged — just reboot it once more.

# Check provisioning status
Get-WinEvent -LogName "Microsoft-Windows-Provisioning-Diagnostics-Provider/Admin" -MaxEvents 30 |
  Select-Object TimeCreated, Id, Message | Format-List
```

**Rollback:** None needed — blob application is non-destructive. If device loops, check for clock skew (Fix 4).
</details>

<details><summary>Fix 2 — ODJ Connector service stopped or not delivering blobs</summary>

```powershell
# Run on connector server
# Restart the connector service
Restart-Service "ODJConnectorSvc" -Force
Start-Sleep -Seconds 10
Get-Service "ODJConnectorSvc" | Select-Object Name, Status

# Check connector application log for errors
Get-EventLog -LogName Application -Source "ODJ Connector Service" -Newest 30 |
  Where-Object { $_.EntryType -in "Error","Warning" } |
  Select-Object TimeGenerated, EntryType, Message | Format-List

# Verify connector is still registered in Intune
Connect-MgGraph -Scopes "DeviceManagementServiceConfig.Read.All"
Get-MgDeviceManagementDeviceConfigurationODataType # Check for connector registration
```

If connector is expired/not registered:
1. Open **Intune portal → Devices → Windows → Windows enrollment → Intune Connector for Active Directory**
2. Verify the connector shows as active (green)
3. If expired: download and re-run the connector installer on the server

**Rollback:** Reinstalling connector is safe — it re-registers without disrupting existing joins.
</details>

<details><summary>Fix 3 — Device profile set to Azure AD Join instead of Hybrid</summary>

The device enrolled as pure AAD Join. The Autopilot profile assignment was wrong.

```powershell
# Identify the device in Autopilot and reassign
Connect-MgGraph -Scopes "DeviceManagementServiceConfig.ReadWrite.All"

# Get device serial number
$serial = (Get-WmiObject Win32_BIOS).SerialNumber

# Find Autopilot device record
$apDevice = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity | Where-Object { $_.SerialNumber -eq $serial }
$apDevice | Select-Object Id, SerialNumber, GroupTag, AssignedUserPrincipalName

# To reassign profile: update GroupTag to match correct dynamic group
Update-MgDeviceManagementWindowsAutopilotDeviceIdentity -WindowsAutopilotDeviceIdentityId $apDevice.Id -GroupTag "<HybridJoinGroupTag>"
```

Then wipe and re-enroll the device — there is no in-place fix once enrolled as wrong join type.

**Rollback:** Changing the GroupTag only affects future enrollments for this device. Safe.
</details>

<details><summary>Fix 4 — Clock skew causing Kerberos/token failures during domain join</summary>

Domain join via ODJ requires time to be within 5 minutes of the DC.

```powershell
# Run on device (debug shell)
# Check current time vs internet
w32tm /query /status
w32tm /resync /force

# If w32tm not available in OOBE shell, set manually:
Set-Date -Date (Invoke-RestMethod "http://worldtimeapi.org/api/timezone/Etc/UTC").datetime

# Verify after sync
Get-Date
```

After correcting time, reboot the device and allow OOBE to retry domain join.

**Rollback:** None needed — time sync is safe.
</details>

---

## Escalation Evidence

```
TICKET ESCALATION — Hybrid Autopilot Join Failure
==================================================
Device Serial:          ___________________________
Device Model:           ___________________________
Autopilot Profile Name: ___________________________
Expected Join Type:     Hybrid Azure AD Join
Actual Join State:      (dsregcmd /status output below)

ODJ Connector Server:   ___________________________
Connector Service:      Running / Stopped / Not registered
Connector Version:      ___________________________

Intune Tenant ID:       ___________________________
Target OU:              ___________________________

Error Code (if any):    ___________________________
Event Log Errors:       (paste from DeviceManagement/Admin log)

dsregcmd /status:
---
[paste full output here]
---

Connector Event Log (last 10 errors):
---
[paste here]
---

Attempted fixes:        ___________________________
Escalation contact:     Intune / AAD L3 / Microsoft Support
```

---

## 🎓 Learning Pointers

- **Hybrid Autopilot requires the ODJ Connector** to be installed on a domain-joined server with line-of-sight to a DC and outbound HTTPS to Intune. Without it, the device cannot receive the offline domain join blob. See: [Intune ODJ Connector docs](https://learn.microsoft.com/en-us/mem/autopilot/windows-autopilot-hybrid)
- **The blob must arrive before the device reboots out of OOBE** — the connector has up to 15 minutes to deliver it. If the network is slow or the connector is unreachable, the join will fail silently.
- **Dynamic groups drive profile assignment** — the GroupTag on an Autopilot device record maps to an Entra ID dynamic group, which is assigned the profile. Wrong tag = wrong profile = wrong join type.
- **Error 0x801c03ed** means Intune could not issue a token for device registration — usually the device's hardware hash is not in Autopilot, or it's assigned to the wrong profile type.
- **Clock skew is a silent killer** — new devices may have drifted clocks from sitting in a box. Kerberos tolerates only 5 minutes. Always check `w32tm /query /status` if domain join fails with no obvious error.
- Reference: [Troubleshoot Hybrid Azure AD joined devices](https://learn.microsoft.com/en-us/azure/active-directory/devices/troubleshoot-hybrid-join-windows-current)
