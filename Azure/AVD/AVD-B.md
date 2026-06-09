# Azure Virtual Desktop — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Run these first. Interpret results to choose a fix path.

```powershell
# 1. Check host pool session hosts status
Get-AzWvdSessionHost -ResourceGroupName "<rg-name>" -HostPoolName "<hostpool-name>" |
    Select-Object Name, Status, UpdateState, LastHeartBeat, AllowNewSession |
    Sort-Object Status | Format-Table -AutoSize

# 2. Check active user sessions
Get-AzWvdUserSession -ResourceGroupName "<rg-name>" -HostPoolName "<hostpool-name>" |
    Select-Object Name, UserPrincipalName, SessionState, CreateTime, ApplicationType |
    Format-Table -AutoSize

# 3. Check AVD agent health on a session host (run on the VM)
Get-Service RDAgentBootLoader, RDAgent | Select-Object Name, Status, StartType

# 4. Check host pool registration token validity
$token = Get-AzWvdRegistrationInfo -ResourceGroupName "<rg-name>" -HostPoolName "<hostpool-name>"
Write-Host "Token expires: $($token.ExpirationTime)" -ForegroundColor Cyan

# 5. Verify workspace/app group assignments
Get-AzWvdApplicationGroup -ResourceGroupName "<rg-name>" |
    Select-Object Name, ApplicationGroupType, HostPoolArmPath | Format-Table -AutoSize
```

| Result | Action |
|--------|--------|
| Session host Status = `Unavailable` | → [Fix 1 — Restart AVD Agent](#fix-1--restart-avd-agent) |
| Session host Status = `NeedsAssistance` | → [Fix 2 — Re-register Session Host](#fix-2--re-register-session-host) |
| User stuck in `Pending` session state | → [Fix 3 — Force Disconnect Stale Session](#fix-3--force-disconnect-stale-session) |
| Registration token expired | → [Fix 4 — Rotate Registration Token](#fix-4--rotate-registration-token) |
| User can't see published resources | → [Fix 5 — App Group Assignment Check](#fix-5--app-group-assignment-check) |
| All hosts Unavailable, token valid | → Escalate — possible backend fabric issue |

---
## Dependency Cascade

<details><summary>What must be true for AVD to work</summary>

```
Azure Active Directory (Entra ID)
  └── User licensed (M365/Azure subscription)
        └── User assigned to AVD App Group
              └── App Group linked to Host Pool
                    └── Session Host VM
                          ├── Running in Azure (VM state = Running)
                          ├── RDAgentBootLoader service running
                          ├── RDAgent service running
                          ├── Outbound HTTPS (443) to *.wvd.microsoft.com
                          ├── Outbound HTTPS (443) to gcs.prod.monitoring.core.windows.net
                          ├── Outbound HTTPS (443) to *.servicebus.windows.net
                          └── Domain join (AD DS or Entra ID joined)
                                └── FSLogix profile storage (Azure Files / MSIX)
                                      └── Storage Account (SMB 445 or 443 NFS)
                                            └── NTFS + share permissions for users
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm VM is running**
```powershell
Get-AzVM -ResourceGroupName "<rg-name>" -Name "<vm-name>" -Status |
    Select-Object -ExpandProperty Statuses | Where-Object Code -like "PowerState/*"
```
Expected: `PowerState/running`. If `deallocated` → start the VM.

**Step 2 — Check AVD agent services on session host**
```powershell
# Run on the session host VM (via Bastion or Run Command)
Get-Service RDAgentBootLoader, RDAgent, RDMonitoringAgent |
    Select-Object Name, Status, StartType | Format-Table
```
Expected: All three `Running`. If `Stopped` → [Fix 1](#fix-1--restart-avd-agent).

**Step 3 — Check agent event logs**
```powershell
# Run on session host
Get-WinEvent -LogName "Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational" -MaxEvents 20 |
    Where-Object LevelDisplayName -in "Error","Warning" |
    Select-Object TimeCreated, Id, Message | Format-List
```
Expected: No errors within last 10 minutes. Error 3401 = registration issue.

**Step 4 — Verify outbound network from session host**
```powershell
# Run on session host — test required endpoints
$endpoints = @(
    "rdweb.wvd.microsoft.com",
    "rdbroker.wvd.microsoft.com",
    "gcs.prod.monitoring.core.windows.net"
)
foreach ($ep in $endpoints) {
    $result = Test-NetConnection -ComputerName $ep -Port 443
    Write-Host "$ep`:443 - $(if ($result.TcpTestSucceeded) {'OK'} else {'FAIL'})" -ForegroundColor $(if ($result.TcpTestSucceeded) {'Green'} else {'Red'})
}
```
Expected: All `OK`. Failures = firewall/NSG blocking required traffic.

**Step 5 — Check FSLogix profile mount (if users get desktop but profiles fail)**
```powershell
# Run on session host
Get-WinEvent -ProviderName FSLogix -MaxEvents 20 -ErrorAction SilentlyContinue |
    Where-Object LevelDisplayName -in "Error","Warning" |
    Select-Object TimeCreated, Id, Message | Format-List
```
Expected: No errors. Event 25 = profile mounted OK. Event 26 = profile unloaded cleanly.

---
## Common Fix Paths

<details><summary>Fix 1 — Restart AVD Agent</summary>

**When:** RDAgent or RDAgentBootLoader stopped; session host shows Unavailable.

```powershell
# Run on the session host VM (via Azure Run Command or Bastion)
$services = @('RDAgentBootLoader','RDAgent','RDMonitoringAgent')
foreach ($svc in $services) {
    Restart-Service -Name $svc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    $status = (Get-Service -Name $svc).Status
    Write-Host "$svc`: $status" -ForegroundColor $(if ($status -eq 'Running') {'Green'} else {'Red'})
}
# Wait 2-3 minutes then re-check portal
```

**Via Azure Run Command (no Bastion needed):**
```powershell
Invoke-AzVMRunCommand -ResourceGroupName "<rg-name>" -Name "<vm-name>" `
    -CommandId 'RunPowerShellScript' `
    -ScriptString "Restart-Service RDAgentBootLoader,RDAgent,RDMonitoringAgent -Force"
```

**Rollback:** If services fail to start after restart, check Windows Event Log Application source for RDAgent install errors — may need agent reinstall ([Fix 2](#fix-2--re-register-session-host)).

</details>

<details><summary>Fix 2 — Re-register Session Host</summary>

**When:** Host shows NeedsAssistance; error 3401 in event log; agent services running but host still Unavailable.

```powershell
# Step 1: Generate a new registration token (valid 2 hours)
$token = New-AzWvdRegistrationInfo -ResourceGroupName "<rg-name>" `
    -HostPoolName "<hostpool-name>" `
    -ExpirationTime (Get-Date).AddHours(2)
$regKey = $token.Token
Write-Host "New token generated, expires: $($token.ExpirationTime)"

# Step 2: On the session host — update the registration key
# Run via Azure Run Command:
$script = @"
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent' -Name 'RegistrationToken' -Value '$regKey'
Restart-Service RDAgentBootLoader -Force
"@
Invoke-AzVMRunCommand -ResourceGroupName "<rg-name>" -Name "<vm-name>" `
    -CommandId 'RunPowerShellScript' -ScriptString $script
```

**Rollback:** Old token is automatically invalidated when a new one is generated — no data loss. If re-registration fails, the VM may need the RDAgent reinstalled from the Microsoft documentation installer package.

</details>

<details><summary>Fix 3 — Force Disconnect Stale Session</summary>

**When:** User stuck in Pending or Disconnected state, cannot reconnect.

```powershell
# List sessions for a specific user
Get-AzWvdUserSession -ResourceGroupName "<rg-name>" -HostPoolName "<hostpool-name>" |
    Where-Object UserPrincipalName -eq "<user@domain.com>"

# Force disconnect (preserves session state)
Remove-AzWvdUserSession -ResourceGroupName "<rg-name>" `
    -HostPoolName "<hostpool-name>" `
    -SessionHostName "<sessionhost-name>" `
    -Id <session-id> `
    -Force

# Full logoff (clears session completely)
Invoke-AzWvdUserSessionLogOff -ResourceGroupName "<rg-name>" `
    -HostPoolName "<hostpool-name>" `
    -SessionHostName "<sessionhost-name>" `
    -UserSessionId <session-id> `
    -Force
```

**Rollback:** Logoff terminates unsaved work — warn user before running `Invoke-AzWvdUserSessionLogOff`. `Remove-AzWvdUserSession` (disconnect) is safer as it preserves session state.

</details>

<details><summary>Fix 4 — Rotate Registration Token</summary>

**When:** Existing token expired; need to add new session hosts to pool.

```powershell
# Generate token valid for 4 hours
$expiry = (Get-Date).AddHours(4)
$regInfo = New-AzWvdRegistrationInfo -ResourceGroupName "<rg-name>" `
    -HostPoolName "<hostpool-name>" `
    -ExpirationTime $expiry
Write-Host "Token: $($regInfo.Token)"
Write-Host "Expires: $($regInfo.ExpirationTime)"

# Copy token to clipboard for use in agent installer / DSC / Bicep
$regInfo.Token | Set-Clipboard
```

**Note:** This is non-destructive — existing registered hosts are not affected. Token is only required for new host registrations.

</details>

<details><summary>Fix 5 — App Group Assignment Check</summary>

**When:** User authenticates successfully but sees no published resources in AVD client.

```powershell
# Check what app groups exist in the host pool
Get-AzWvdApplicationGroup -ResourceGroupName "<rg-name>" |
    Where-Object HostPoolArmPath -like "*<hostpool-name>*" |
    Select-Object Name, ApplicationGroupType, Description

# Check role assignments on the app group
$appGroupId = (Get-AzWvdApplicationGroup -ResourceGroupName "<rg-name>" -Name "<appgroup-name>").Id
Get-AzRoleAssignment -Scope $appGroupId |
    Where-Object RoleDefinitionName -eq "Desktop Virtualization User" |
    Select-Object DisplayName, SignInName, ObjectType

# Add user to app group
New-AzRoleAssignment -SignInName "<user@domain.com>" `
    -RoleDefinitionName "Desktop Virtualization User" `
    -Scope $appGroupId

# Check workspace associations
Get-AzWvdWorkspace -ResourceGroupName "<rg-name>" |
    Select-Object Name, ApplicationGroupReferences | Format-List
```

**Common miss:** App group exists and user is assigned, but the app group is not linked to the workspace. Use the portal or:
```powershell
Update-AzWvdWorkspace -ResourceGroupName "<rg-name>" -Name "<workspace-name>" `
    -ApplicationGroupReference @("<appgroup-resource-id>")
```

</details>

---
## Escalation Evidence

Copy this template, fill in all fields, attach to ticket before escalating to Microsoft Support or senior engineering.

```
=== AVD ESCALATION EVIDENCE PACK ===
Date/Time (UTC): _______________
Reported by: _______________
Affected user(s): _______________
Subscription ID: _______________
Resource Group: _______________
Host Pool Name: _______________
Session Host(s) affected: _______________

SYMPTOM:
[ ] Cannot connect to session host
[ ] Session host showing Unavailable/NeedsAssistance
[ ] User sees no published resources
[ ] Profile failing to load (FSLogix)
[ ] Disconnecting/dropping sessions
[ ] Other: _______________

TRIAGE RESULTS:
VM Power State: _______________
RDAgent Service Status: _______________
RDAgentBootLoader Status: _______________
Registration Token Expiry: _______________
Outbound connectivity test results: _______________

AVD AGENT EVENT LOG (last 5 errors):
Event ID | Time | Message
_______________

ACTIONS TAKEN:
_______________

CORRELATION ID (from Azure Activity Log): _______________
TENANT ID: _______________
SESSION HOST OS VERSION: _______________
AVD AGENT VERSION (HKLM:\SOFTWARE\Microsoft\RDInfraAgent):
  - AgentVersion: _______________
  - LastHeartBeat: _______________
```

---
## 🎓 Learning Pointers

- **AVD Architecture layers**: The stack is Control Plane (Microsoft-managed) → Session Host VM (customer-managed) → User Profile (FSLogix). Triage always starts with the layer you own — the VM and agent.
- **RDAgentBootLoader vs RDAgent**: BootLoader is the watchdog service; it starts and monitors RDAgent. If BootLoader is stopped, RDAgent will not restart automatically even after a reboot.
- **FSLogix profile priority**: Profile load failures silently fall back to a temporary profile — users get a desktop but lose personalisation and redirected folders. Always check FSLogix event log when users report "settings reset".
- **Outbound firewall requirements**: AVD requires outbound 443 to specific FQDNs — NSG outbound rules blocking `*.servicebus.windows.net` are a common cause of NeedsAssistance status. Full list: [Required URLs for AVD](https://learn.microsoft.com/en-us/azure/virtual-desktop/safe-url-list)
- **Drain mode**: Before rebooting a session host for maintenance, set `AllowNewSession = $false` via `Update-AzWvdSessionHost` to drain gracefully without disrupting active users.
- **Agent auto-updates**: AVD agents update automatically outside business hours. If an update fails, the host can enter NeedsAssistance. Check `HKLM:\SOFTWARE\Microsoft\RDInfraAgent` for `AgentVersion` to confirm current state.
