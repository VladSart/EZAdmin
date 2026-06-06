# DFS Namespace — Hotfix Runbook (Mode B: Ops)

> Fix or correctly escalate in under 10 minutes. No theory. Every command has a purpose.

---

## Skim Index
- [Triage (60 sec)](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis Flow](#diagnosis--validation-flow)
- [Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

Run these first. Stop when you find the break.

```powershell
# 1. Can this machine resolve the namespace domain?
Resolve-DnsName contoso.com

# 2. Is the DFS Namespace service running on the namespace server?
Get-Service -Name Dfs -ComputerName <NamespaceServer>

# 3. Can you reach the namespace at all?
dfsutil /root:\\contoso.com\<namespacename> /view

# 4. Is the folder target reachable directly?
Test-Path \\<TargetServer>\<ShareName>

# 5. Check for namespace errors in last 24 hours
Get-WinEvent -LogName "DFS Namespaces" -MaxEvents 50 |
  Where-Object { $_.LevelDisplayName -in "Error","Warning" } |
  Select-Object TimeCreated, Id, Message | Format-Table -Wrap
```

**Interpret:**
- DNS fails → fix DNS first. Nothing else matters.
- DFS service stopped → start it, check why it stopped (Event ID 14548)
- `dfsutil /view` returns error → namespace server issue (see Fix Paths)
- Target unreachable directly → problem is on the target server, not DFSN
- Events show 14548/14549 → namespace data is corrupted or AD objects missing

---

## Dependency Cascade

<details><summary>What must be true for DFS Namespace to work</summary>

```
[Client]
    → DNS resolves domain → [DC reachable]
    → Kerberos auth succeeds → [DC + time sync OK]
    → DFS Referral request → [Namespace Server, TCP 135 + dynamic RPC]
    → Namespace server reads from AD (domain-based) or registry (standalone)
    → Returns referral to folder target UNC path
    → Client connects directly to target → [File server, TCP 445]
    → NTFS + share permissions evaluated
```

**Root scalability mode**: If enabled, namespace servers read from the PDC emulator only. PDC unavailable = referral failures everywhere.

**AD replication lag**: Namespace changes made on one DC may not be visible on others for minutes. New targets won't appear until AD replicates.

</details>

---

## Diagnosis & Validation Flow

Work top to bottom. Stop at the first broken layer.

**Step 1 — DNS**
```powershell
nslookup contoso.com
nslookup <NamespaceServerFQDN>
```
Expected: Resolves to correct IP. If not → fix DNS, re-test.

**Step 2 — DFS service on namespace server**
```powershell
Get-Service Dfs -ComputerName <NamespaceServer> | Select Status, StartType
```
Expected: `Running`. If `Stopped` → `Start-Service Dfs -ComputerName <NamespaceServer>`

**Step 3 — Namespace exists in AD**
```powershell
# Domain-based namespace only
Get-DfsnRoot -Path \\contoso.com\<namespacename>
```
Expected: Returns namespace object. If errors → the DFS root object may be missing from AD.

**Step 4 — Namespace server is registered**
```powershell
Get-DfsnRootTarget -Path \\contoso.com\<namespacename>
```
Expected: Shows one or more `TargetPath` entries with `State: Online`. `Offline` = server unreachable.

**Step 5 — Folder targets**
```powershell
Get-DfsnFolderTarget -Path \\contoso.com\<namespacename>\<foldername>
```
Expected: `State: Online`. If `Offline` → target server or share unreachable.

**Step 6 — Referral from client side**
```powershell
dfsutil /pktinfo   # Shows cached DFS referrals on client
dfsutil /pktflush  # Clears the referral cache — force re-query
```

---

## Common Fix Paths

<details><summary>Fix 1 — DFS service not running</summary>

```powershell
Start-Service Dfs -ComputerName <NamespaceServer>
Set-Service Dfs -StartupType Automatic -ComputerName <NamespaceServer>

# Verify
Get-Service Dfs -ComputerName <NamespaceServer>
```
Check Event ID 14548 in System log for why it stopped — could be registry corruption.

</details>

<details><summary>Fix 2 — Folder target offline / unreachable</summary>

```powershell
# Check if target share exists
Get-SmbShare -Name <ShareName> -CimSession <TargetServer>

# If share missing, recreate it
New-SmbShare -Name <ShareName> -Path "C:\<path>" -CimSession <TargetServer>

# Then bring target back online in DFS
Set-DfsnFolderTarget -Path "\\contoso.com\<ns>\<folder>" `
  -TargetPath "\\<TargetServer>\<ShareName>" -State Online
```

</details>

<details><summary>Fix 3 — Client referral cache stale</summary>

```powershell
# On the affected client
dfsutil /pktflush        # Clear referral cache
dfsutil /spcflush        # Clear server connection cache
net use * /delete        # Drop all mapped drives
# Re-map and test
```

</details>

<details><summary>Fix 4 — Root scalability mode blocking referrals</summary>

```powershell
# Check if enabled
(Get-DfsnRoot -Path \\contoso.com\<ns>).Flags

# If "RootScalability" is set and PDC is unreachable, disable it
Set-DfsnRoot -Path \\contoso.com\<ns> -EnableRootScalability $false
```
> ⚠️ Only disable if you understand the replication load implications. In large environments this was enabled for a reason.

</details>

<details><summary>Fix 5 — Namespace missing from AD (corruption)</summary>

This is a last resort. Verify with Microsoft docs before proceeding.

```powershell
# Check if DFS root object exists in AD
Get-ADObject -Filter {objectClass -eq "msDFS-Namespacev2"} -SearchBase "CN=Dfs-Configuration,CN=System,DC=contoso,DC=com"

# If missing, you need to restore from backup or recreate the namespace
# Document all folder targets first
Get-DfsnFolder -Path \\contoso.com\<ns> | Get-DfsnFolderTarget | Export-Csv C:\dfs-targets-backup.csv
```

</details>

---

## Escalation Evidence

Copy this block, fill it in, paste into your ticket:

```
DFS Namespace Issue — Evidence Pack
====================================
Namespace path:        \\<domain>\<namespacename>
Namespace server(s):   <FQDN>
Affected users/sites:  
Error message seen:    
When it started:       

DNS resolution:        [OK / FAIL — output]
DFS service state:     [Running / Stopped]
dfsutil /root output:  [paste]
Folder target state:   [Online / Offline]
Relevant event IDs:    [14548 / 14549 / other]
Direct target access:  [OK / FAIL]
AD namespace object:   [Present / Missing]
```

---

## 🎓 Learning Pointers

- **DFS Namespace vs DFS Replication** — These are two separate services. DFSN handles the virtual path; DFSR handles file sync. You can have one without the other. Worth understanding the split deeply: [MS Docs: DFS Overview](https://learn.microsoft.com/en-us/windows-server/storage/dfs-namespaces/dfs-overview)
- **Root Scalability Mode** — Enabled in large environments to reduce PDC load, but it means namespace server changes depend entirely on AD replication timing. If you hit a mysterious "works from some sites, not others" pattern, this is likely why.
- **DFS referral process** — The client never talks directly to the namespace share. It gets a *referral* (list of UNC targets ranked by site cost) and then connects independently. Understanding this changes how you diagnose access failures.
- **`dfsutil`** — The most powerful DFS command-line tool. Worth spending 30 minutes reading `dfsutil /?` — most engineers only know the basic flags.
- **r/sysadmin DFS thread** — Search "DFS replication not working site" on Reddit — recurring patterns around site link costs and target priority ordering come up constantly.
