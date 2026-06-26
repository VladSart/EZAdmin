# SMB File Share Access — Reference Runbook (Mode A: Deep Dive)
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

Covers SMB file share access failures in Windows environments — both standalone servers and DFS namespaces. Applies to:
- SMB 2.x / 3.x (Windows Server 2012 R2 and later)
- Domain-joined clients accessing domain server shares
- Workgroup / cross-domain scenarios noted where behaviour differs
- On-premises file servers (not Azure Files, though many principles apply)

**Out of scope:** DFS replication (see `DFS/Troubleshooting/Replication/`), Azure Files SMB, NFS shares.

**Assumed role:** L2/L3 engineer with local admin on the client and at least read access to server event logs.

---

## How It Works

<details><summary>Full architecture — SMB connection lifecycle</summary>

### Protocol Overview

SMB (Server Message Block) is a client-server protocol that runs over TCP port 445. Since Windows Vista / Server 2008, the stack is:

```
Application (Explorer, net use, Map-Drive)
      |
SMB Client (mrxsmb.sys, mrxsmb20.sys)
      |
TCP/IP stack → port 445 → TCP/IP on server
      |
SMB Server service (srv2.sys for SMB2/3, srv.sys for SMB1)
      |
NTFS / ReFS filesystem driver
```

### Negotiation and Session Setup

1. **TCP connect** — Client opens TCP 445 to server IP.
2. **Protocol negotiate** — Client advertises supported SMB versions; server picks highest mutual version (typically SMB 3.1.1).
3. **Session setup** — Kerberos or NTLM authentication exchange. On a domain, Kerberos is always tried first using a Service Principal Name of `cifs/<servername>` or `cifs/<server-FQDN>`.
4. **Tree connect** — Client sends TREE_CONNECT to `\\server\share`. Server checks share ACL then NTFS ACL.
5. **File operations** — CREATE, READ, WRITE, CLOSE packets.

### SMB Dialect Comparison

| Dialect | OS | Key features |
|---------|-----|-------------|
| SMB 1.0 | Windows XP/2003 | Legacy, deprecated, disable it |
| SMB 2.0 | Vista/2008 | Request compounding, larger reads |
| SMB 2.1 | Win7/2008R2 | Client oplock leasing |
| SMB 3.0 | Win8/2012 | Multichannel, encryption, ODX |
| SMB 3.1.1 | Win10/2016 | Pre-auth integrity, AES-128-GCM |

### Authentication Path

```
Client wants \\server\share
      |
1. Does client have a Kerberos TGT?  
      Yes → request CIFS/<server> service ticket from DC
      No  → fall through to NTLM
      |
2. NTLM path:
   Client sends NEGOTIATE → CHALLENGE → AUTHENTICATE
   Server validates hash against DC (NetLogon pass-through) or local SAM
      |
3. Session authenticated → check share permissions → check NTFS ACLs
```

### Share vs. NTFS Permissions

Both layers apply — the **more restrictive wins**:
- **Share permissions**: coarse-grained, apply at the share boundary (Everyone / Read / Change / Full Control)
- **NTFS permissions**: granular, apply to files and folders (Read, Write, Modify, Full Control, Special)

A user with NTFS Full Control but only Share Read gets Read access. Best practice is Share = Everyone Full Control, govern with NTFS only.

### SMB Encryption (SMB 3.x)

When enabled, SMB 3.x encrypts data in transit using AES-128-CCM or AES-128-GCM. Can be enforced per-share or globally. Clients that don't support SMB 3.x (XP, 2003) are blocked if encryption is required.

### Opportunistic Locks and Leases

Oplocks allow the client to cache file data locally. When a second client opens the same file, the server sends an oplock break; the first client must flush its cache. Break failures cause delays and apparent hangs. SMB 2.1+ uses lease-based oplocks that are more resilient.

</details>

---

## Dependency Stack

```
User (SID, group memberships)
    │
    ▼
Kerberos TGT (from DC)  ←── DNS: client must resolve DC name
    │                   ←── Time: within 5 minutes of DC (Kerberos)
    ▼
CIFS/<server> service ticket
    │
    ▼
TCP port 445 reachable (firewall, routing)
    │
    ▼
SMB Server service running (LanmanServer)
    │
    ▼
Share exists and is accessible (net share)
    │
    ▼
Share ACL grants at least Read
    │
    ▼
NTFS ACL grants at least Read on folder/file
    │
    ▼
SMB signing / encryption settings compatible between client and server
    │
    ▼
File accessible (not exclusively locked, not offline)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| "Access is denied" | NTFS or Share ACL | `Get-Acl`, `icacls`, `Get-SmbShareAccess` |
| "The network path was not found" | DNS/name resolution, server offline, share missing | `Test-NetConnection -Port 445`, `net view \\<server>` |
| "Logon failure: unknown user or bad password" | NTLM credential mismatch, account locked | Check DC event logs (4625), `net use` with explicit creds |
| "A specified logon session does not exist" | Stale credential in Windows Credential Manager | `cmdkey /list`, clear stored creds |
| Mapped drive disconnects after idle | SMB keep-alive timeout, DFS referral expiry | `Get-SmbClientConfiguration` (`SessionTimeout`) |
| Very slow file transfers | SMB multichannel not negotiating, NIC RSS off | `Get-SmbMultichannelConnection`, NIC adapter settings |
| File locked, can't open | Oplock held by another user/process | `Get-SmbOpenFile | Where ShareRelativePath -like '*filename*'` |
| "The specified network name is no longer available" | Session dropped (SMB timeout, network blip) | Network stability, `SmbClientNetworkInterface` |
| SMB 1.0 disabled, legacy clients break | Old application requires SMB 1 | Audit with `Get-SmbServerConfiguration`, consider isolation VLAN |
| Encryption required but client doesn't support | SMB 3.x encryption mismatch | `Get-SmbServerConfiguration | Select EncryptData`, check client OS |

---

## Validation Steps

**1 — Confirm the server is reachable on port 445**
```powershell
Test-NetConnection -ComputerName <FileServer> -Port 445
```
Expected good: `TcpTestSucceeded : True`
Bad: `False` → firewall or routing issue; check Windows Firewall on server and any network ACLs.

**2 — Confirm SMB shares are published**
```powershell
Get-SmbShare -CimSession <FileServer> | Select Name, Path, Description
```
Expected good: your share appears in the list.
Bad: share not listed → it was deleted or never created; re-create with `New-SmbShare`.

**3 — Confirm share-level ACL**
```powershell
Get-SmbShareAccess -Name <ShareName> -CimSession <FileServer>
```
Expected good: user/group with at least `Read` permission.
Bad: user or their groups missing → `Grant-SmbShareAccess`.

**4 — Confirm NTFS ACL on the share root**
```powershell
Invoke-Command -ComputerName <FileServer> { Get-Acl "D:\Shares\<ShareFolder>" | Format-List }
```
Expected good: user's group in the ACL with at least `ReadAndExecute`.
Bad: no matching ACE, or explicit Deny → `icacls` to remediate.

**5 — Test authentication — Kerberos vs NTLM**
```powershell
# On the CLIENT machine, check what auth was used after connecting
klist
# Look for cifs/<server> or cifs/<server.domain.com> tickets
```
Expected good: service ticket for `cifs/<server>` with valid lifetime.
Bad: no ticket, falling to NTLM → check SPN, DNS, time sync.

**6 — Check SMB server configuration**
```powershell
Get-SmbServerConfiguration -CimSession <FileServer> | Select RequireSecuritySignature, EncryptData, EnableSMB1Protocol, EnableSMB2Protocol
```
Expected good: SMB2 enabled, SMB1 disabled, signing/encryption settings consistent with client capability.
Bad: SMB2 disabled → re-enable with `Set-SmbServerConfiguration -EnableSMB2Protocol $true`.

**7 — Check client SMB configuration**
```powershell
Get-SmbClientConfiguration | Select RequireSecuritySignature, EnableBandwidthThrottling, EnableMultiChannel
```

**8 — Check for file/session limits**
```powershell
Get-SmbSession -CimSession <FileServer> | Measure-Object
Get-SmbOpenFile -CimSession <FileServer> | Measure-Object
```
If session or open-file count is very high, may indicate a hung process or ransomware IOC.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Name Resolution

The most common hidden cause of SMB failures is DNS. The client must resolve the server name to the correct IP, and Kerberos SPN registration depends on DNS name.

```powershell
# From the CLIENT
Resolve-DnsName <FileServer>
Resolve-DnsName <FileServer>.<domain.com>

# Verify the resolved IP is what you expect
Test-NetConnection <FileServer> -Port 445
```

If DNS returns the wrong IP (split DNS misconfiguration, stale entry), the Kerberos service ticket will be issued for the wrong host and authentication fails.

### Phase 2 — Authentication

```powershell
# Clear any stale NTLM credentials
cmdkey /delete:<FileServer>
cmdkey /delete:<FileServer>.<domain.com>

# Test explicit connection
net use \\<FileServer>\<ShareName> /user:<DOMAIN>\<Username>

# Check for account lockout
Search-ADAccount -LockedOut | Where SamAccountName -eq <Username>
```

Check DC Security log (Event ID 4625) to see why authentication failed — the Sub Status code tells you exactly:
- `0xC000006D` — wrong username or auth mechanism
- `0xC000006A` — wrong password  
- `0xC0000064` — user doesn't exist
- `0xC000006F` — logon outside allowed hours
- `0xC0000071` — password expired

### Phase 3 — ACL Investigation

```powershell
# Effective access check on the TARGET folder (Windows Server 2012+)
# In File Explorer: Properties > Security > Advanced > Effective Access — enter user UPN

# Command-line effective permissions check
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)

# On the server:
Invoke-Command -ComputerName <FileServer> {
    $acl = Get-Acl "D:\Shares\<Folder>"
    $acl.Access | Where-Object {$_.IdentityReference -match "<Username>|<Group>"}
}
```

Watch for:
- **Inherited Deny** — a Deny ACE from a parent folder overriding Allow
- **SID history issues** — migrated accounts where the group SID changed
- **Token size bloat** — user in >120 security groups causes Kerberos token to exceed network limit; client falls back to NTLM which may be blocked

### Phase 4 — SMB Signing and Encryption Conflicts

```powershell
# Check if signing mismatch is causing failures
Get-SmbServerConfiguration -CimSession <FileServer> | Select RequireSecuritySignature
Get-SmbClientConfiguration | Select RequireSecuritySignature

# If server requires signing but client doesn't enforce it → usually still works
# If encryption is required on server but client is SMB 2.x → breaks

Get-SmbServerConfiguration -CimSession <FileServer> | Select EncryptData
Get-SmbShare -Name <ShareName> -CimSession <FileServer> | Select EncryptData
```

### Phase 5 — Performance and Connectivity

```powershell
# Check SMB Multichannel (requires multiple NICs or RDMA)
Get-SmbMultichannelConnection -CimSession <FileServer>
Get-SmbMultichannelConstraint  # any constraints configured?

# Check NIC RSS (Receive Side Scaling) — needed for Multichannel
Get-NetAdapterRss -Name "<NIC Name>" -CimSession <FileServer>

# SMB performance counters
Get-Counter -Counter "\SMB Client Shares(*)\*" -ComputerName <ClientMachine>
```

---

## Remediation Playbooks

<details><summary>Fix 1 — Re-create a missing or broken share</summary>

```powershell
# On the file server (run as admin)
$ShareName   = "<ShareName>"
$SharePath   = "D:\Shares\<FolderName>"
$Description = "Shared folder for <Department>"

# Ensure the folder exists
if (-not (Test-Path $SharePath)) { New-Item -ItemType Directory -Path $SharePath }

# Create share — Everyone Read/Write at share level, govern with NTFS
New-SmbShare -Name $ShareName `
             -Path $SharePath `
             -Description $Description `
             -FullAccess "Everyone" `
             -CimSession <FileServer>

# Verify
Get-SmbShare -Name $ShareName -CimSession <FileServer>
```

**Rollback:** `Remove-SmbShare -Name $ShareName -Force -CimSession <FileServer>`

</details>

<details><summary>Fix 2 — Grant share and NTFS permissions</summary>

```powershell
$ShareName  = "<ShareName>"
$Server     = "<FileServer>"
$GroupOrUser = "<DOMAIN>\<SecurityGroup>"
$LocalPath  = "D:\Shares\<FolderName>"

# Share-level: grant Change (read+write)
Grant-SmbShareAccess -Name $ShareName -AccountName $GroupOrUser -AccessRight Change -CimSession $Server -Force

# NTFS: grant Modify on the folder, propagate to children
Invoke-Command -ComputerName $Server {
    $acl  = Get-Acl $using:LocalPath
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $using:GroupOrUser, "Modify",
                "ContainerInherit,ObjectInherit", "None", "Allow")
    $acl.SetAccessRule($rule)
    Set-Acl -Path $using:LocalPath -AclObject $acl
}

Write-Host "Permissions applied. Verify with: Get-Acl '$LocalPath' on $Server" -ForegroundColor Green
```

**Note:** This is non-destructive (adds/replaces the ACE for the named principal). Test before applying to shares with complex existing ACLs.

</details>

<details><summary>Fix 3 — Clear stale Kerberos tickets and credential cache</summary>

```powershell
# Run on the CLIENT machine

# Purge all Kerberos tickets
klist purge

# Remove any stored credentials for the server
cmdkey /list | Select-String "<FileServer>"
cmdkey /delete:<FileServer>
cmdkey /delete:<FileServer>.<domain.com>

# Disconnect any existing SMB sessions
net use \\<FileServer>\<ShareName> /delete

# Re-connect — Kerberos will negotiate fresh
net use \\<FileServer>\<ShareName> /persistent:yes

# Verify a fresh CIFS ticket was obtained
klist | Select-String -Pattern "cifs|<FileServer>" -Context 2,2
```

</details>

<details><summary>Fix 4 — Re-register missing or broken SMB SPN</summary>

```powershell
# If Kerberos fails because the server's SPN is missing or wrong
# Run on a DC or machine with AD admin rights

$ServerName   = "<FileServer>"
$ServerFQDN   = "<FileServer>.<domain.com>"
$ComputerDN   = (Get-ADComputer $ServerName).DistinguishedName

# Check existing SPNs
Get-ADComputer $ServerName -Properties ServicePrincipalName | 
    Select -ExpandProperty ServicePrincipalName | Sort

# Add missing CIFS SPNs
setspn -S "cifs/$ServerName" "$ServerName$"
setspn -S "cifs/$ServerFQDN" "$ServerName$"

# Verify
setspn -L $ServerName
```

**Rollback:** `setspn -D "cifs/<ServerName>" "<ServerName>$"`

</details>

<details><summary>Fix 5 — Release locked file handles</summary>

```powershell
# Find who has a specific file open
$FileName = "ImportantDoc.xlsx"
$OpenFiles = Get-SmbOpenFile -CimSession <FileServer> | 
    Where-Object { $_.Path -like "*$FileName*" }

$OpenFiles | Select ClientUserName, ClientComputerName, Path

# Close a specific open file (by FileId)
$OpenFiles | ForEach-Object {
    Write-Host "Closing file held by $($_.ClientUserName) on $($_.ClientComputerName)"
    Close-SmbOpenFile -FileId $_.FileId -CimSession <FileServer> -Force
}
```

**Warning:** Force-closing open files without notifying the user may cause data loss if they have unsaved changes. Always attempt to contact the user first.

</details>

<details><summary>Fix 6 — Re-enable SMB 2.x (if accidentally disabled)</summary>

```powershell
# Run on the FILE SERVER as admin
Set-SmbServerConfiguration -EnableSMB2Protocol $true -Confirm:$false

# Verify
Get-SmbServerConfiguration | Select EnableSMB1Protocol, EnableSMB2Protocol

# Note: SMB 1 should remain disabled unless required for legacy devices
# If SMB 1 is needed, isolate to a separate VLAN and document the risk
```

**Rollback:** `Set-SmbServerConfiguration -EnableSMB2Protocol $false -Confirm:$false`  
(This will break all SMB 2.x clients — only do this intentionally.)

</details>

<details><summary>Fix 7 — Fix Kerberos token size issue (too many group memberships)</summary>

```powershell
# Check approximate token size for a user
$User   = Get-ADUser <Username> -Properties MemberOf
$Groups = $User.MemberOf.Count
Write-Host "User is in $Groups groups. Kerberos token may be large."

# Token size formula (rough): 1200 + (Groups * 40) bytes
# Default MaxTokenSize = 12000 bytes; > ~250 groups causes failures

# Resolution options:
# 1. Remove unnecessary group memberships (preferred)
# 2. Increase MaxTokenSize via GPO (Computer Configuration > Administrative Templates > System > Kerberos)
#    Key: HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters
#    Value: MaxTokenSize (DWORD) = 65535

$RegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters"
Set-ItemProperty -Path $RegPath -Name MaxTokenSize -Value 65535 -Type DWord
# Requires reboot to take effect
```

See: [KB327825 — Problems with Kerberos authentication when a user belongs to many groups](https://support.microsoft.com/kb/327825)

</details>

---

## Evidence Pack

Run this on the **client machine** and **file server** to collect everything needed for escalation.

```powershell
# Save to: C:\EZAdmin\SMB-Evidence-<hostname>-<date>.txt
$Date     = Get-Date -Format "yyyyMMdd-HHmm"
$Server   = "<FileServer>"
$Share    = "<ShareName>"
$OutFile  = "C:\EZAdmin\SMB-Evidence-$env:COMPUTERNAME-$Date.txt"

New-Item -ItemType Directory -Path C:\EZAdmin -Force | Out-Null
"=== SMB Evidence Pack — $Date ===" | Out-File $OutFile

# CLIENT SIDE
"--- DNS Resolution ---" | Add-Content $OutFile
Resolve-DnsName $Server 2>&1 | Add-Content $OutFile

"--- TCP Port 445 Test ---" | Add-Content $OutFile
Test-NetConnection $Server -Port 445 2>&1 | Add-Content $OutFile

"--- Kerberos Tickets ---" | Add-Content $OutFile
& klist 2>&1 | Add-Content $OutFile

"--- Stored Credentials ---" | Add-Content $OutFile
& cmdkey /list 2>&1 | Add-Content $OutFile

"--- Net Use Sessions ---" | Add-Content $OutFile
& net use 2>&1 | Add-Content $OutFile

"--- SMB Client Config ---" | Add-Content $OutFile
Get-SmbClientConfiguration 2>&1 | Add-Content $OutFile

"--- SMB Multichannel (client) ---" | Add-Content $OutFile
Get-SmbMultichannelConnection 2>&1 | Add-Content $OutFile

# RECENT EVENTS (client)
"--- System Events (past 2h) ---" | Add-Content $OutFile
Get-WinEvent -LogName System -MaxEvents 50 | 
    Where-Object { $_.TimeCreated -gt (Get-Date).AddHours(-2) -and $_.LevelDisplayName -match "Error|Warning" } |
    Select TimeCreated, Id, LevelDisplayName, Message |
    Format-Table -AutoSize 2>&1 | Add-Content $OutFile

# SERVER SIDE (requires remote access)
"--- SMB Server Config ---" | Add-Content $OutFile
Get-SmbServerConfiguration -CimSession $Server 2>&1 | Add-Content $OutFile

"--- Share List ---" | Add-Content $OutFile
Get-SmbShare -CimSession $Server 2>&1 | Add-Content $OutFile

"--- Share Access ($Share) ---" | Add-Content $OutFile
Get-SmbShareAccess -Name $Share -CimSession $Server 2>&1 | Add-Content $OutFile

"--- Active Sessions ---" | Add-Content $OutFile
Get-SmbSession -CimSession $Server 2>&1 | Select ClientUserName, ClientComputerName, NumOpens | Add-Content $OutFile

"--- Open Files (top 20) ---" | Add-Content $OutFile
Get-SmbOpenFile -CimSession $Server 2>&1 | Select ClientUserName, Path -First 20 | Add-Content $OutFile

Write-Host "Evidence saved to: $OutFile" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Test TCP 445 | `Test-NetConnection <server> -Port 445` |
| List all shares on server | `Get-SmbShare -CimSession <server>` |
| Check share ACL | `Get-SmbShareAccess -Name <share> -CimSession <server>` |
| Grant share access | `Grant-SmbShareAccess -Name <share> -AccountName <user> -AccessRight Change -CimSession <server> -Force` |
| Check NTFS ACL | `Get-Acl \\<server>\<share> \| Format-List` |
| Set NTFS permission | `icacls \\<server>\<share>\<folder> /grant "<user>:(OI)(CI)M"` |
| Purge Kerberos tickets | `klist purge` |
| Remove stored credentials | `cmdkey /delete:<server>` |
| List open files on server | `Get-SmbOpenFile -CimSession <server>` |
| Close a locked file | `Close-SmbOpenFile -FileId <id> -CimSession <server> -Force` |
| List SMB sessions | `Get-SmbSession -CimSession <server>` |
| Disconnect all sessions from a user | `Get-SmbSession -CimSession <server> \| Where ClientUserName -eq "<user>" \| Close-SmbSession -Force` |
| Check SMB signing | `Get-SmbServerConfiguration -CimSession <server> \| Select RequireSecuritySignature` |
| Check SMB version in use | `Get-SmbConnection` (on client) |
| Enable SMB 2 on server | `Set-SmbServerConfiguration -EnableSMB2Protocol $true -Confirm:$false` |
| Check Multichannel | `Get-SmbMultichannelConnection -CimSession <server>` |
| Check for duplicate SPNs | `setspn -X -F` |

---

## 🎓 Learning Pointers

- **SMB 1 is dangerous and deprecated** — if you still have devices requiring SMB 1, audit them with `Get-SmbServerConfiguration | Select EnableSMB1Protocol` and plan for removal or VLAN isolation. WannaCry and NotPetya exploited SMB 1 (EternalBlue). See [MS Security Advisory ADV170012](https://msrc.microsoft.com/update-guide/vulnerability/ADV170012).

- **Kerberos is stateful; NTLM is stateless** — when SMB authentication suddenly breaks after a server rename or IP change, the Kerberos SPN is the first thing to check. `setspn -Q cifs/<servername>` shows you in seconds whether the SPN exists. [Kerberos SPN and Delegation docs](https://docs.microsoft.com/en-us/windows-server/security/kerberos/kerberos-authentication-overview).

- **The "Access Denied" you see is almost never the full story** — always check both layers (share ACL and NTFS ACL). The common pattern is IT creates the share, forgets to set NTFS permissions, and everyone gets "Access Denied" even with correct share access. The effective permission is always the most restrictive of the two.

- **SMB Multichannel is automatic but not magic** — it only activates when the client and server both have multiple NICs (or RDMA-capable NICs) and RSS is enabled. On a VM with a single vNIC you'll never see Multichannel regardless of config. [SMB Multichannel docs](https://docs.microsoft.com/en-us/windows-server/storage/file-server/smb-multichannel).

- **Event IDs to know**: `5140` (share accessed), `5145` (share object access check), `4625` (logon failure on DC), `3` in Microsoft-Windows-SMBClient/Connectivity (SMB client connection events). Enable object access auditing in GPO to surface 5145.

- **Token bloat is a silent killer** — users in 200+ security groups will fail Kerberos authentication silently and fall back to NTLM. If NTLM is blocked by CA policy, they get "Access Denied" with no clear error. The fix is either pruning group memberships or increasing `MaxTokenSize` via registry — see [KB327825](https://support.microsoft.com/kb/327825).
