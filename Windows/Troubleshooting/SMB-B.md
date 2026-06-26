# SMB File Share Access — Hotfix Runbook (Mode B: Ops)
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

Run these within 60 seconds of getting the ticket. Paste output into your ticket notes.

```powershell
# 1. Test basic SMB connectivity (from affected client — run as user seeing issue)
Test-NetConnection -ComputerName <serverFQDN> -Port 445

# 2. Check if share exists and client can see it
net view \\<serverFQDN>

# 3. Check SMB client protocols enabled
Get-SmbClientConfiguration | Select-Object EnableSMB1Protocol, EnableSMB2Protocol

# 4. Check server SMB config (run on server)
Get-SmbServerConfiguration | Select-Object EnableSMB1Protocol, EnableSMB2Protocol, RequireSecuritySignature

# 5. Check current SMB sessions (run on server)
Get-SmbSession | Select-Object ClientComputerName, ClientUserName, NumOpens
```

**Interpret:**
| Result | Meaning | Action |
|--------|---------|--------|
| Port 445 blocked | Network/firewall issue | → Fix 1 |
| `net view` fails with error 5 | Access denied (permissions) | → Fix 2 |
| `net view` fails with error 53 | Name not found / network path issue | → Fix 1 |
| SMB1 enabled on client, disabled on server | Protocol mismatch | → Fix 3 |
| Share not listed in `net view` | Share doesn't exist or hidden | → Fix 4 |
| Sessions show, but user not listed | Auth failing silently | → Fix 5 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
User can access \\server\share
        │
        ├── 1. Network: Client → Server TCP 445 open
        │       └── No firewall blocking; correct DNS resolution
        │
        ├── 2. SMB Protocol match
        │       ├── Server accepts SMBv2 or SMBv3
        │       └── Client has matching version enabled
        │
        ├── 3. Authentication succeeds
        │       ├── Kerberos: DC reachable, SPN valid, ticket issued
        │       ├── NTLM: DC reachable, NetLogon secure channel valid
        │       └── Local auth: credentials match (workgroup scenario)
        │
        ├── 4. Share exists and permissions allow access
        │       ├── Share-level ACL: Read or Full Control
        │       └── NTFS ACL: at least Read
        │
        └── 5. Server Service running on file server
                └── Get-Service -Name "Server" | Select Status
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Verify the Server service is running**
```powershell
# Run on file server
Get-Service -Name "LanmanServer" | Select-Object Name, Status, StartType
```
Expected: `Status = Running`. If stopped → start it: `Start-Service LanmanServer`

---

**Step 2 — Confirm share exists**
```powershell
# Run on file server
Get-SmbShare | Where-Object { $_.Name -eq "<ShareName>" } | Select-Object Name, Path, Description
```
Expected: Share entry returned. If nothing → share doesn't exist or is misspelled.

---

**Step 3 — Check share-level permissions**
```powershell
# Run on file server
Get-SmbShareAccess -Name "<ShareName>" | Format-Table -AutoSize
```
Expected: User, their group, or "Everyone" with Read or Full Control listed.  
Bad: No entry for user/group → add share ACL entry.

---

**Step 4 — Check NTFS permissions on share path**
```powershell
# Run on file server
$sharePath = (Get-SmbShare -Name "<ShareName>").Path
(Get-Acl $sharePath).Access | Select-Object IdentityReference, FileSystemRights, AccessControlType | Format-Table -AutoSize
```
Expected: User/group has at minimum `ReadAndExecute`.

---

**Step 5 — Verify SMB signing compatibility**
```powershell
# Client
(Get-SmbClientConfiguration).RequireSecuritySignature
# Server
(Get-SmbServerConfiguration).RequireSecuritySignature
```
If client = True and server = False (or vice versa and it's enforced differently) → signing mismatch.  
See Fix 3.

---

**Step 6 — Check for authentication failures (on DC)**
```powershell
# On DC — look for 4625 (failed logon) or 4776 (NTLM failure) in last 30 minutes
Get-WinEvent -FilterHashtable @{
    LogName   = "Security"
    Id        = @(4625, 4776)
    StartTime = (Get-Date).AddMinutes(-30)
} | Select-Object TimeCreated, Id, Message | Format-List
```
Look for the affected username in the output.

---

## Common Fix Paths

<details><summary>Fix 1 — Network/DNS: TCP 445 not reaching server</summary>

**Symptoms:** `Test-NetConnection` fails; error 53 on net view.

```powershell
# 1. Resolve hostname (from client)
Resolve-DnsName <serverFQDN>

# 2. Test TCP 445
Test-NetConnection -ComputerName <serverFQDN> -Port 445

# 3. Check Windows Firewall on server (if rule missing)
Get-NetFirewallRule -DisplayName "File and Printer Sharing*" | Select-Object DisplayName, Enabled, Direction

# If rule disabled, enable it:
Enable-NetFirewallRule -DisplayName "File and Printer Sharing (SMB-In)"

# 4. Flush DNS cache on client if stale record suspected
Clear-DnsClientCache
ipconfig /flushdns

# 5. Test again
Test-NetConnection -ComputerName <serverFQDN> -Port 445
```

**Rollback:** If firewall rule was manually disabled before, restore that state.

</details>

<details><summary>Fix 2 — Permissions: Access denied (Error 5)</summary>

**Symptoms:** Share reachable, but access denied when browsing or mapping.

```powershell
# Run on file server as admin

$shareName = "<ShareName>"
$userOrGroup = "<DOMAIN\Username or GroupName>"

# Step 1: Add to share ACL (if missing)
Grant-SmbShareAccess -Name $shareName -AccountName $userOrGroup -AccessRight Read -Force
# Change Read to Full if needed

# Step 2: Check NTFS path
$sharePath = (Get-SmbShare -Name $shareName).Path
$acl = Get-Acl $sharePath

# Add NTFS permission (Read & Execute minimum)
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $userOrGroup, "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow"
)
$acl.AddAccessRule($rule)
Set-Acl -Path $sharePath -AclObject $acl

Write-Host "Permissions granted. Ask user to retry." -ForegroundColor Green
```

**Rollback:**
```powershell
Revoke-SmbShareAccess -Name $shareName -AccountName $userOrGroup -Force
# Manually remove NTFS rule via Get-Acl + SetAccessRule with Deny, or via ICACLS
```

</details>

<details><summary>Fix 3 — SMB Protocol Mismatch or Signing Conflict</summary>

**Symptoms:** Connection resets; event 31017 on client; 4 on server; signing errors.

```powershell
# Check both sides
$clientCfg = Get-SmbClientConfiguration
$serverCfg = Get-SmbServerConfiguration

Write-Host "Client SMB1: $($clientCfg.EnableSMB1Protocol)"
Write-Host "Client SMB2: $($clientCfg.EnableSMB2Protocol)"
Write-Host "Client RequireSign: $($clientCfg.RequireSecuritySignature)"
Write-Host "Server SMB1: $($serverCfg.EnableSMB1Protocol)"
Write-Host "Server SMB2: $($serverCfg.EnableSMB2Protocol)"
Write-Host "Server RequireSign: $($serverCfg.RequireSecuritySignature)"

# If client is SMB1-only and server has SMB1 disabled — client needs update
# Enable SMB2 on client if it's somehow off (rare):
Set-SmbClientConfiguration -EnableSMB2Protocol $true -Force

# If signing mismatch (client requires, server doesn't enforce):
# On server — enable signing (recommended):
Set-SmbServerConfiguration -RequireSecuritySignature $true -Force
# Or on client — relax requirement (not recommended long-term):
# Set-SmbClientConfiguration -RequireSecuritySignature $false -Force
```

**Note:** Never re-enable SMB1 unless absolutely required for legacy devices. Disable SMB1 everywhere — it's a critical attack surface.

**Rollback:** Revert signing setting only; don't re-enable SMB1.

</details>

<details><summary>Fix 4 — Share Doesn't Exist or Wrong Path</summary>

**Symptoms:** `net view \\server` works but target share not listed; or share listed but path wrong.

```powershell
# Confirm what shares exist
Get-SmbShare | Where-Object { $_.Name -notmatch '^\$' } | Select-Object Name, Path

# Create share if it's missing
$path = "D:\<FolderPath>"
$shareName = "<ShareName>"
if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path }
New-SmbShare -Name $shareName -Path $path -Description "Created by IT" -ReadAccess "Everyone"

# Verify
Get-SmbShare -Name $shareName | Format-List

# Set proper permissions (don't rely on Everyone — replace with correct group)
Revoke-SmbShareAccess -Name $shareName -AccountName "Everyone" -Force
Grant-SmbShareAccess -Name $shareName -AccountName "<DOMAIN\GroupName>" -AccessRight Change -Force
```

**Rollback:** `Remove-SmbShare -Name $shareName -Force`

</details>

<details><summary>Fix 5 — Authentication Failing (Credential/NTLM Issue)</summary>

**Symptoms:** Prompted for credentials repeatedly; sessions not establishing; Event 4625 on DC.

```powershell
# Step 1: Check if user is locked out
Get-ADUser -Identity <username> -Properties LockedOut, PasswordExpired, BadLogonCount |
    Select-Object Name, LockedOut, PasswordExpired, BadLogonCount

# Unlock if locked:
Unlock-ADAccount -Identity <username>

# Step 2: Test with explicit credentials (from client)
$cred = Get-Credential
New-PSDrive -Name Z -PSProvider FileSystem -Root "\\<serverFQDN>\<ShareName>" -Credential $cred

# Step 3: Check NTLM secure channel on server
nltest /sc_query:<DomainName>
# If broken: nltest /sc_reset:<DomainName>

# Step 4: Clear cached credentials on client (if stale creds)
cmdkey /list | Where-Object { $_ -match "<server>" }
cmdkey /delete:<serverFQDN>
# Then retry UNC access — Windows will prompt for fresh creds
```

**Rollback:** No destructive changes. Credential cache clear is safe and easily re-added.

</details>

---

## Escalation Evidence

Copy this block, fill in the blanks, attach to your ticket:

```
=== SMB Access Failure — Escalation Pack ===
Date/Time       : 
Affected User(s): 
Source Client   : 
Target Server   : \\<server>\<share>
Error Observed  : (exact error message / error code)

--- Client Diagnostics ---
TCP 445 Test    : [Pass/Fail]
DNS Resolution  : [Resolved to: IP]
SMB1 Enabled    : [Yes/No]
SMB2 Enabled    : [Yes/No]

--- Server Diagnostics ---
Server Service  : [Running/Stopped]
Share Exists    : [Yes/No]
Share ACL       : [Paste Get-SmbShareAccess output]
NTFS ACL        : [Paste relevant Get-Acl output]
SMB Signing     : [RequireSecuritySignature: True/False]

--- Auth/DC Diagnostics ---
Account Locked  : [Yes/No]
Event 4625/4776 : [Yes/No — paste event details if yes]
Secure Channel  : [nltest output]

--- Attempted Fixes ---
1. 
2. 

--- Next Recommended Step ---
```

---

## 🎓 Learning Pointers

- **Always check both share ACL AND NTFS ACL.** The effective permission is the most restrictive intersection of both. A user with Full Control at the share level still gets nothing if NTFS denies them. Use `icacls <path>` to see the raw effective access. See: [Share and NTFS permissions](https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/shared-resources-permissions-overview)

- **SMB1 is permanently dangerous — don't re-enable it.** SMB1 is the protocol exploited by EternalBlue/WannaCry. If a legacy device (old NAS, scanner, pre-2012 server) requires SMB1, replace the device, not the protocol. See: [Stop using SMB1](https://techcommunity.microsoft.com/t5/storage-at-microsoft/stop-using-smb1/ba-p/425858)

- **Event 4625 on the DC, not the server, tells you why auth failed.** The file server itself doesn't validate credentials — it passes them to the DC via NTLM or Kerberos. The DC's Security log (Event 4625 with sub-status codes) has the real reason for failure. Don't only look at logs on the file server.

- **Error 53 = name resolution failure; Error 5 = permission failure.** These two error codes cover 80% of SMB cases. Error 53 means DNS or network; Error 5 means ACL or auth. Once you know which you're dealing with, the path forward is clear.

- **`Get-SmbSession` and `Get-SmbOpenFile` are your live diagnostic tools.** On the server, these show you who has sessions and what files are open right now. If a user's session shows but they're still getting errors, it's a permissions issue inside the share (per-folder NTFS), not a connectivity or auth issue. See: [SMB PowerShell cmdlets](https://learn.microsoft.com/en-us/powershell/module/smbshare/)
