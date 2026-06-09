# Azure Virtual Desktop — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---
## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps (by phase)](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

This runbook covers Azure Virtual Desktop (AVD) — formerly Windows Virtual Desktop — including:
- Personal and pooled host pool troubleshooting
- AVD agent registration and health
- FSLogix profile container issues
- App group and workspace publishing
- Network connectivity requirements
- Session management and drain operations
- MSIX App Attach (overview only; attach configuration is out of scope)

**Assumes:**
- Az PowerShell module installed (`Install-Module Az -Scope CurrentUser`)
- Authenticated: `Connect-AzAccount` with Contributor or Desktop Virtualization Contributor
- Session host VMs are Azure-native (not Arc-connected on-premises)
- FSLogix is used for profile management (standard MSP deployment)

**Not covered:** AVD Insights (Log Analytics configuration), RDP Shortpath, Teams AV optimisation deep dives.

---
## How It Works

<details><summary>Full architecture</summary>

### Control Plane (Microsoft-managed)

AVD's control plane is fully managed by Microsoft and hosted globally. Engineers have no direct access to it. It consists of:

- **Web Client / Feed endpoint** (`rdweb.wvd.microsoft.com`): Delivers the list of published resources (desktops and RemoteApps) to AVD clients via a JSON feed. The feed is scoped per workspace.
- **Broker** (`rdbroker.wvd.microsoft.com`): Handles session brokering — load balancing new connections across available session hosts. For pooled host pools, uses breadth-first or depth-first algorithms. For personal pools, maintains user-to-host affinity.
- **Gateway** (`*.wvd.microsoft.com`): Acts as the RDP transport relay. The client and session host never connect directly unless RDP Shortpath (direct UDP) is enabled.
- **Diagnostics** (`gcs.prod.monitoring.core.windows.net`, `*.servicebus.windows.net`): Collects agent heartbeats and session telemetry. If blocked, host appears NeedsAssistance even when functionally healthy.

### Data Plane (Customer-managed)

The session host VMs are owned and managed by the customer. The following must be true on each VM:

```
Session Host VM
├── Windows OS (multi-session Win11 22H2+ or single-session)
├── RDAgentBootLoader (watchdog — restarts RDAgent on failure)
├── RDAgent (core AVD agent — handles broker registration + RDP)
├── RDMonitoringAgent (sends diagnostics to AVD control plane)
├── FSLogix Agent (profile container management)
│     ├── Profile VHD(x) stored on Azure Files or ANF
│     └── NTFS + share permissions: Users need Contributor or Storage File Data SMB Share Contributor
├── Microsoft Identity Platform components (if Entra ID joined)
│     └── Intune MDM enrollment (if managed)
└── Domain Join
      ├── AD DS join (traditional) — requires line-of-sight to DC via VNET
      └── Entra ID join — no DC required; limitations on shared profiles
```

### User Connection Flow

```
1. User opens AVD client (desktop app, browser, or thin client)
2. Client authenticates to Entra ID (MFA if required by CA policy)
3. Client requests resource feed from rdweb.wvd.microsoft.com
4. Control plane returns list of desktops/apps user is assigned to
5. User selects resource → client contacts rdbroker for session brokering
6. Broker selects available session host (load balancing algorithm)
7. Broker initiates reverse connection from session host → Gateway
8. Client connects to Gateway and is tunnelled to session host (TCP 443 or UDP 3478)
9. Session host starts Windows session
10. FSLogix mounts VHD(x) profile from Azure Files (SMB 445 or 443)
11. Shell loads, user lands on desktop
```

### Load Balancing Algorithms

| Algorithm | Behaviour | Best for |
|-----------|-----------|----------|
| Breadth-first | Fill each host to max before moving to next; host with fewest sessions gets priority when all equal | Pooled — cost optimisation |
| Depth-first | Spread sessions evenly across all healthy hosts | Pooled — performance |
| Personal | Direct assignment; one user per host; persistent | Knowledge workers needing persistent state |

### FSLogix Profile Architecture

FSLogix redirects the Windows user profile into a VHD(x) file stored on a network share (Azure Files or Azure NetApp Files). When a user logs on:
1. FSLogix driver attaches the VHD(x) — it appears as a local disk
2. Junction points redirect `C:\Users\<username>` to the mounted volume
3. On logoff, VHD(x) is cleanly dismounted and sync'd back to storage

This means the same profile is available regardless of which session host the user lands on — critical for pooled deployments.

</details>

---
## Dependency Stack

```
Entra ID (Identity)
  └── User UPN + licenses (M365/Azure sub)
        └── MFA / Conditional Access policies
              └── AVD Workspace
                    └── AVD App Group (Desktop or RemoteApp)
                          ├── RBAC: Desktop Virtualization User role
                          └── AVD Host Pool
                                ├── Pooled or Personal
                                ├── Session Host VMs (Azure)
                                │     ├── VM Running state
                                │     ├── RDAgentBootLoader + RDAgent (Running)
                                │     ├── RDMonitoringAgent (Running)
                                │     ├── Outbound 443 to *.wvd.microsoft.com
                                │     ├── Outbound 443 to *.servicebus.windows.net
                                │     ├── Outbound 443 to gcs.prod.monitoring.core.windows.net
                                │     └── Domain Join (AD DS or Entra ID)
                                │           └── AD DS: VNET DNS → DC reachable on TCP/UDP 389, 636, 3268
                                └── FSLogix Profile Storage
                                      └── Azure Files or Azure NetApp Files
                                            ├── SMB 445 (or HTTPS 443 for private endpoint)
                                            ├── Storage Account Firewall rules
                                            ├── Share-level RBAC: Storage File Data SMB Share Contributor
                                            └── NTFS permissions on share root
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Session host Status = `Unavailable` | VM deallocated or RDAgent stopped | VM power state; RDAgent service |
| Session host Status = `NeedsAssistance` | Outbound network blocked; agent version mismatch; diagnostics endpoint unreachable | NSG outbound rules; event log 3401; monitoring agent |
| User can authenticate but sees no resources | App group not assigned to workspace; user not in Desktop Virtualization User role | `Get-AzWvdApplicationGroup`; role assignments |
| User gets blank/temp profile | FSLogix VHD(x) failed to mount | FSLogix event log; SMB 445 connectivity; storage NTFS permissions |
| Session connects then immediately drops | GPO redirecting RDP port; AVD gateway unreachable; NLA conflict | Network trace on session host; gateway FQDN resolution |
| "We couldn't connect to the Gateway" error | Session host cannot reach AVD gateway outbound | `Test-NetConnection rdbroker.wvd.microsoft.com 443` from VM |
| Long login times (>2 min) | FSLogix profile VHD large; Azure Files high latency; antivirus scanning profile VHD | Azure Files latency metrics; FSLogix event 65 (size); AV exclusions |
| Conditional Access blocking sign-in | CA policy targeting AVD app not excluding compliant/Entra joined devices | CA sign-in logs; What If tool |
| MSIX App Attach app not visible | App group not configured; MSIX image not staged | MSIX event log; host pool MSIX packages |
| Personal host showing wrong user assigned | Host affinity set to wrong user from previous assignment | `Get-AzWvdSessionHost` AssignedUser; clear if needed |

---
## Validation Steps

**1. Confirm Az PowerShell connected**
```powershell
Get-AzContext | Select-Object Account, Subscription, Tenant
```
Expected: Correct subscription and account. If blank: `Connect-AzAccount`.

**2. Enumerate host pool health**
```powershell
Get-AzWvdSessionHost -ResourceGroupName "<rg>" -HostPoolName "<pool>" |
    Select-Object Name, Status, UpdateState, LastHeartBeat, AllowNewSession, AssignedUser |
    Format-Table -AutoSize
```
Expected: All hosts `Available` with LastHeartBeat within last 5 minutes. `UpdateState` should be `Succeeded`.

**3. Validate agent services on session host**
```powershell
# Via Azure Run Command (no Bastion needed):
Invoke-AzVMRunCommand -ResourceGroupName "<rg>" -VMName "<vm>" `
    -CommandId 'RunPowerShellScript' `
    -ScriptString "Get-Service RDAgentBootLoader,RDAgent,RDMonitoringAgent | Select Name,Status"
```
Expected: All three services `Running`.

**4. Validate outbound connectivity**
```powershell
# Run on session host
$required = @(
    @{Host="rdweb.wvd.microsoft.com";Port=443},
    @{Host="rdbroker.wvd.microsoft.com";Port=443},
    @{Host="gcs.prod.monitoring.core.windows.net";Port=443},
    @{Host="www.servicebus.windows.net";Port=443},
    @{Host="login.microsoftonline.com";Port=443}
)
foreach ($r in $required) {
    $t = Test-NetConnection -ComputerName $r.Host -Port $r.Port -WarningAction SilentlyContinue
    "$($r.Host):$($r.Port) — $(if($t.TcpTestSucceeded){'OK'}else{'FAIL'})"
}
```
Expected: All `OK`. Any `FAIL` = NSG or firewall change required.

**5. Validate FSLogix profile health**
```powershell
# Run on session host after a user logs in
Get-WinEvent -ProviderName FSLogix -MaxEvents 30 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Where-Object LevelDisplayName -in "Error","Warning" | Format-List
```
Expected: No errors. Key event IDs: 25 (profile attached), 26 (profile detached), non-zero attach errors indicate storage access issues.

**6. Validate app group to workspace linkage**
```powershell
$ws = Get-AzWvdWorkspace -ResourceGroupName "<rg>" -Name "<workspace>"
$ws.ApplicationGroupReference | ForEach-Object { Write-Host $_ }
```
Expected: App group resource IDs listed. Empty = workspace not linked to any app group.

---
## Troubleshooting Steps (by phase)

### Phase 1: Pre-Connection (User cannot see published resources)

1. Confirm user has a valid Entra ID account and licence
2. Check Entra ID sign-in logs for authentication failures (especially MFA or CA policy blocks)
3. Confirm app group has `Desktop Virtualization User` role assigned to user or their group
4. Confirm app group is linked to the workspace
5. Have user refresh feed in AVD client (`Ctrl+R` in Windows client, or force reload in web)

### Phase 2: Connection Brokering (User sees resources but cannot connect)

1. Check all session hosts in host pool — are any `Available`?
2. If all hosts `Unavailable`: check VM power state, then agent services
3. If hosts `NeedsAssistance`: check outbound network from VM to AVD endpoints
4. Check host pool `MaxSessionLimit` — if all sessions used, users get queued or rejected
5. For personal host pools: confirm user has an assigned host and that host is available

### Phase 3: Session Initialisation (Connects but profile/desktop fails)

1. Check FSLogix event log — look for VHD mount errors
2. Test SMB connectivity from session host to storage account (port 445 or 443 if private endpoint)
3. Check storage account firewall — is the subnet of the session host VMs whitelisted?
4. Check NTFS permissions on the profile share root — Users need at minimum `Modify` on their own folder
5. Check if user is hitting multiple concurrent session hosts at once (FSLogix `ConcurrentUserSessions` registry key)

### Phase 4: Mid-Session Issues (Drops, disconnects, performance)

1. Check Azure infrastructure health for the region (Azure Status: status.azure.com)
2. Review session host CPU/memory metrics in Azure Monitor
3. Check network round-trip time from client to AVD gateway (AVD Insights or Network Test tool)
4. Review FSLogix container size — oversized profiles (>10GB) cause slow logon/logoff
5. Verify no scheduled tasks or GPO scripts are forcibly logging off sessions

---
## Remediation Playbooks

<details><summary>Playbook 1 — Full Agent Reinstall on Session Host</summary>

Use when: Agent services exist but won't start; repeated NeedsAssistance after restarts; UpdateState = `Failed`.

```powershell
# Step 1: Put host in drain mode (no new sessions)
Update-AzWvdSessionHost -ResourceGroupName "<rg>" -HostPoolName "<pool>" `
    -Name "<sessionhost-fqdn>" -AllowNewSession:$false

# Step 2: Wait for active sessions to drain or force logoff
Get-AzWvdUserSession -ResourceGroupName "<rg>" -HostPoolName "<pool>" |
    Where-Object SessionHostName -eq "<sessionhost-fqdn>" |
    ForEach-Object {
        Invoke-AzWvdUserSessionLogOff -ResourceGroupName "<rg>" -HostPoolName "<pool>" `
            -SessionHostName $_.SessionHostName -UserSessionId $_.Name.Split('/')[-1] -Force
    }

# Step 3: Generate new registration token
$token = New-AzWvdRegistrationInfo -ResourceGroupName "<rg>" -HostPoolName "<pool>" `
    -ExpirationTime (Get-Date).AddHours(4)

# Step 4: On the session host — uninstall agent, reinstall
# Run via Bastion or Azure Run Command:
$script = @'
# Stop services
Stop-Service RDAgentBootLoader,RDAgent -Force -ErrorAction SilentlyContinue

# Uninstall existing agents
$apps = Get-WmiObject Win32_Product | Where-Object Name -like "*Remote Desktop*Agent*"
foreach ($app in $apps) {
    Write-Host "Uninstalling: $($app.Name)"
    $app.Uninstall() | Out-Null
}

# Download and install latest agent (update URLs from MS docs)
$bootloaderUrl = "https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrmXv"
$agentUrl = "https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrmXv"
# NOTE: Get actual URLs from https://learn.microsoft.com/en-us/azure/virtual-desktop/agent-overview
Write-Host "Download and install agent from Microsoft documentation URLs"
Write-Host "Registration token needed: [TOKEN]"
'@

# Replace [TOKEN] with $token.Token before running
Write-Host "Token for reinstall: $($token.Token)"

# Step 5: Re-enable session host
Update-AzWvdSessionHost -ResourceGroupName "<rg>" -HostPoolName "<pool>" `
    -Name "<sessionhost-fqdn>" -AllowNewSession:$true
```

**Rollback:** If reinstall fails, the VM can be reimaged from the session host image (destroy + recreate) without data loss — FSLogix profiles are external to the VM.

</details>

<details><summary>Playbook 2 — FSLogix Profile Corruption Recovery</summary>

Use when: User gets a temp profile; FSLogix errors 25 with access denied or corruption; user profile VHD locked.

```powershell
# Step 1: Identify the VHD(x) path for the affected user
# Standard path format: \\<storageaccount>.file.core.windows.net\<share>\<username>\Profile_<SID>.vhdx

# Step 2: Check if VHD is locked (mounted by another session)
# Look for FSLogix event 66 (profile in use on another host)

# Step 3: Force unlock if stuck (no active sessions)
# On the storage host or via Azure Files:
# - In Azure Portal: Storage Account → File Shares → navigate to user folder → check for .lock files
# - Delete the .lock file if present and user has no active sessions

# Step 4: If profile is corrupt — copy VHD to backup, create fresh
$userSamAccount = "<username>"
$profileShare = "\\<storageaccount>.file.core.windows.net\<sharename>"
$userProfilePath = "$profileShare\$userSamAccount"

# Backup existing (corrupt) VHD
$timestamp = Get-Date -Format "yyyyMMdd-HHmm"
Rename-Item "$userProfilePath\Profile_<SID>.vhdx" `
    "Profile_<SID>_CORRUPT_$timestamp.vhdx"

# Next user login will create a fresh VHD
# User will lose profile customisations — warn them

# Step 5: If backup VHD exists — restore from it
# Copy backup VHD to Profile_<SID>.vhdx in user folder
```

**Rollback:** Always rename (not delete) the corrupt VHD first. If fresh profile is worse, restore the backup rename.

</details>

<details><summary>Playbook 3 — Scale Session Hosts (Add VMs to Host Pool)</summary>

Use when: Host pool is consistently at max session limit; users experiencing connection queuing.

```powershell
# Option A: Add existing VMs to host pool
# Step 1: Generate registration token
$token = New-AzWvdRegistrationInfo -ResourceGroupName "<rg>" -HostPoolName "<pool>" `
    -ExpirationTime (Get-Date).AddHours(4)

# Step 2: Install AVD agent on new VM with the token
# This is typically done via:
# - Custom Script Extension
# - Azure Image Builder (pre-baked)
# - DSC/Bicep template
# Example via Custom Script Extension:
Set-AzVMCustomScriptExtension -ResourceGroupName "<rg>" -VMName "<new-vm>" `
    -Name "AVDAgentInstall" -Location "<location>" `
    -FileUri "https://<storageaccount>.blob.core.windows.net/scripts/Install-AVDAgent.ps1" `
    -Run "Install-AVDAgent.ps1 -RegistrationToken '$($token.Token)'"

# Option B: Scaling plan (automated) — check existing scaling plan
Get-AzWvdScalingPlan -ResourceGroupName "<rg>" | Select-Object Name, HostPoolType, TimeZone

# Review schedule — adjust peak hours or minimum hosts if capacity is the issue
```

</details>

---
## Evidence Pack

Run this script on a session host to collect all evidence needed for a Microsoft support case.

```powershell
<#
.SYNOPSIS  Collect AVD diagnostic evidence from a session host
.NOTES     Run on the affected session host VM (as local admin or SYSTEM via Run Command)
#>

$outputPath = "C:\AVD_Diagnostics_$(Get-Date -Format 'yyyyMMdd_HHmm')"
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

# Agent registry info
$agentReg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\RDInfraAgent" -ErrorAction SilentlyContinue
$agentReg | Out-File "$outputPath\agent_registry.txt"

# Service status
Get-Service RDAgentBootLoader,RDAgent,RDMonitoringAgent,FSLogix |
    Select-Object Name,Status,StartType | Export-Csv "$outputPath\services.csv" -NoTypeInformation

# AVD agent event log (last 100 events)
Get-WinEvent -LogName "Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational" `
    -MaxEvents 100 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated,Id,LevelDisplayName,Message |
    Export-Csv "$outputPath\rdcm_events.csv" -NoTypeInformation

# FSLogix events
Get-WinEvent -ProviderName FSLogix -MaxEvents 50 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated,Id,LevelDisplayName,Message |
    Export-Csv "$outputPath\fslogix_events.csv" -NoTypeInformation

# Network connectivity test
$endpoints = @("rdweb.wvd.microsoft.com","rdbroker.wvd.microsoft.com",
    "gcs.prod.monitoring.core.windows.net","login.microsoftonline.com")
$results = foreach ($ep in $endpoints) {
    $t = Test-NetConnection $ep -Port 443 -WarningAction SilentlyContinue
    [PSCustomObject]@{Endpoint=$ep; Port=443; Success=$t.TcpTestSucceeded; Latency=$t.PingReplyDetails.RoundtripTime}
}
$results | Export-Csv "$outputPath\network_tests.csv" -NoTypeInformation

# System info
Get-ComputerInfo | Select-Object CsName,OsName,OsVersion,OsBuildNumber |
    Out-File "$outputPath\system_info.txt"

Write-Host "Evidence collected to: $outputPath" -ForegroundColor Green
Compress-Archive -Path "$outputPath\*" -DestinationPath "$outputPath.zip" -Force
Write-Host "Archive: $outputPath.zip" -ForegroundColor Cyan
```

---
## Command Cheat Sheet

```powershell
# List all session hosts with status
Get-AzWvdSessionHost -ResourceGroupName "<rg>" -HostPoolName "<pool>" | Select Name,Status,LastHeartBeat

# List active sessions
Get-AzWvdUserSession -ResourceGroupName "<rg>" -HostPoolName "<pool>" | Select UserPrincipalName,SessionState,CreateTime

# Force logoff a user
Invoke-AzWvdUserSessionLogOff -ResourceGroupName "<rg>" -HostPoolName "<pool>" -SessionHostName "<host>" -UserSessionId <id> -Force

# Put host in drain mode
Update-AzWvdSessionHost -ResourceGroupName "<rg>" -HostPoolName "<pool>" -Name "<host-fqdn>" -AllowNewSession:$false

# Re-enable host
Update-AzWvdSessionHost -ResourceGroupName "<rg>" -HostPoolName "<pool>" -Name "<host-fqdn>" -AllowNewSession:$true

# Generate registration token
New-AzWvdRegistrationInfo -ResourceGroupName "<rg>" -HostPoolName "<pool>" -ExpirationTime (Get-Date).AddHours(4)

# List app groups and their host pools
Get-AzWvdApplicationGroup -ResourceGroupName "<rg>" | Select Name,ApplicationGroupType,HostPoolArmPath

# Check role assignments on app group
Get-AzRoleAssignment -Scope (Get-AzWvdApplicationGroup -ResourceGroupName "<rg>" -Name "<ag>").Id

# Add user to app group
New-AzRoleAssignment -SignInName "<upn>" -RoleDefinitionName "Desktop Virtualization User" -Scope "<appgroup-id>"

# Check host pool load balancing config
Get-AzWvdHostPool -ResourceGroupName "<rg>" -Name "<pool>" | Select LoadBalancerType,MaxSessionLimit,PreferredAppGroupType

# List scaling plans
Get-AzWvdScalingPlan -ResourceGroupName "<rg>" | Select Name,HostPoolType

# Run command on session host without Bastion
Invoke-AzVMRunCommand -ResourceGroupName "<rg>" -VMName "<vm>" -CommandId RunPowerShellScript -ScriptString "<ps1>"

# Check FSLogix version on session host
Invoke-AzVMRunCommand -ResourceGroupName "<rg>" -VMName "<vm>" -CommandId RunPowerShellScript `
    -ScriptString "(Get-ItemProperty 'HKLM:\SOFTWARE\FSLogix\Apps').InstallVersion"
```

---
## 🎓 Learning Pointers

- **Why reverse connections?** AVD session hosts initiate outbound connections to the gateway rather than accepting inbound RDP (3389). This means you don't need to open inbound firewall rules on your VMs — only outbound 443. This is a security win but means NSG outbound rules can silently break AVD if misconfigured. Reference: [AVD network connectivity](https://learn.microsoft.com/en-us/azure/virtual-desktop/network-connectivity)
- **FSLogix vs. roaming profiles**: Traditional roaming profiles copy the entire profile to/from a network share at logon/logoff — catastrophic for cloud latency. FSLogix mounts a VHD(x) at logon and accesses it in-place over SMB, keeping the I/O local-ish and making logon times fast regardless of profile size. Reference: [FSLogix overview](https://learn.microsoft.com/en-us/fslogix/overview)
- **Entra ID Join vs. AD DS Join trade-offs**: Entra ID joined session hosts don't require a DC in the VNET and are simpler to manage with Intune, but FSLogix profiles require Azure Files with Kerberos authentication (using a storage account AD DS join or Entra ID Kerberos) — this is a common gap in Entra-only AVD deployments. Reference: [Configure Azure Files for FSLogix](https://learn.microsoft.com/en-us/azure/storage/files/storage-files-identity-auth-azure-active-directory-enable)
- **Autoscale and drain mode**: AVD scaling plans can deallocate idle session hosts to save cost. If a host is deallocated and a user tries to connect, AVD starts it (cold start penalty ~2–5 min). Ensure your minimum host count covers your business hours traffic. Reference: [AVD Autoscale](https://learn.microsoft.com/en-us/azure/virtual-desktop/autoscale-scaling-plan)
- **Agent versioning**: AVD agents update automatically during maintenance windows. You can control update schedules via the host pool update settings. Agent version is in `HKLM:\SOFTWARE\Microsoft\RDInfraAgent` → `AgentVersion`. Mismatched agent versions between BootLoader and Agent are a documented cause of NeedsAssistance. Reference: [AVD Agent overview](https://learn.microsoft.com/en-us/azure/virtual-desktop/agent-overview)
- **AVD Insights**: Connect a Log Analytics workspace to your host pool diagnostics for structured session, connectivity, and error data. This is essential for recurring or intermittent issues where real-time triage isn't enough. Reference: [AVD Insights](https://learn.microsoft.com/en-us/azure/virtual-desktop/insights)
