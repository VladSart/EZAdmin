# DFS Namespace — Reference Runbook (Mode A: Deep Dive)

> Engineering-grade reference. Explains why things fail, not just what to click. For L2/L3 diagnosis, post-mortems, and building understanding.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How DFS Namespace Works](#how-dfs-namespace-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps](#troubleshooting-steps)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)

---

## Scope & Assumptions

- **Covers:** Domain-based DFS Namespaces (v2 — Windows Server 2008+), standalone namespaces where noted
- **Environment:** Active Directory domain, Windows Server 2016/2019/2022 namespace servers
- **Not covered:** DFSR (separate runbook), Azure File Shares (different beast entirely)
- **Assumes:** Admin rights on namespace servers and DCs; RSAT tools installed

---

## How DFS Namespace Works

<details><summary>Full architecture — expand for deep understanding</summary>

### The Virtual Path Model

DFS Namespace creates a layer of indirection. When a user navigates to `\\contoso.com\files\documents`, they are **not** connecting directly to a file server. Instead:

1. The client sends a **DFS referral request** to a domain controller (or namespace server)
2. The namespace server looks up the target for `\documents` in its namespace data
3. It returns a **referral** — an ordered list of UNC paths (e.g., `\\fileserver1\documents`, `\\fileserver2\documents`)
4. The client caches this referral and connects **directly** to the first available target
5. Future accesses use the cached referral until it expires (default: 300 seconds for folders, 900 for roots)

This means: **namespace server outage ≠ access outage if referral is cached**. The client already knows the target path. This is why users sometimes only notice failures after a referral cache expires.

### Domain-Based vs Standalone

| Aspect | Domain-based | Standalone |
|--------|-------------|-----------|
| Namespace path | `\\domain.com\ns` | `\\servername\ns` |
| Config stored in | Active Directory | Registry on server |
| Fault tolerant | Yes (multiple namespace servers) | No (single server) |
| Requires AD | Yes | No |
| Recommended | Yes for orgs | Only for workgroups |

**Domain-based namespaces v2** (recommended): Namespace data stored as AD objects under `CN=Dfs-Configuration,CN=System,DC=...`. All namespace servers share the same logical view through AD replication.

### Root Scalability Mode

By default, namespace servers poll the **PDC emulator** for namespace changes (every 5 minutes by default). This creates a dependency on PDC availability and can cause replication storms in large environments.

**Root Scalability Mode** switches this: each namespace server polls AD independently for changes. Reduces PDC load, but introduces replication lag — changes to namespace configuration may take minutes to appear on all servers depending on AD replication topology.

**Impact:** If PDC is temporarily unreachable in non-scalability mode, namespace servers stop getting updates but still serve existing referrals from cache. If PDC is long-term unavailable, servers will eventually serve stale namespace data.

### How Referral Priority Works

When multiple folder targets exist, DFS applies **site cost ordering**:
1. Targets in the **same AD site** as the client → lowest cost → listed first
2. Targets in adjacent sites → ordered by site link cost
3. Targets in unconnected sites → listed last

Client always tries targets in order. If the first target is unreachable, it moves to the next. This means: **a single failed target in the same site as all clients = all clients fail on first attempt, then succeed on retry with the next target.**

This is why "DFS is slow" symptoms often point to a failed primary target, not a namespace problem.

</details>

---

## Dependency Stack

```
Layer 7: User access (SMB connection to file target)
            ↑ requires: share permissions + NTFS permissions
Layer 6: DFS referral resolution (client → namespace server)
            ↑ requires: DFS service running, namespace data intact
Layer 5: Namespace data (AD objects or registry)
            ↑ requires: AD replication healthy (domain-based)
Layer 4: Kerberos authentication
            ↑ requires: DC reachable, time sync ≤5 min, SPN correct
Layer 3: Network connectivity (TCP 135, 445, dynamic RPC, UDP 389)
            ↑ requires: firewall rules, routing
Layer 2: DNS resolution (namespace domain + target servers)
            ↑ requires: DNS server reachable, records correct
Layer 1: AD replication
            ↑ underpins layers 4 and 5
```

**Key insight:** Failures at lower layers (1–3) produce symptoms that look like DFS problems but aren't. Always validate bottom-up.

---

## Symptom → Cause Map

| Symptom | Most likely cause | Check |
|---------|------------------|-------|
| `\\domain\ns` not accessible from anywhere | Namespace server down / DFS service stopped | `Get-Service Dfs` on namespace servers |
| Accessible from some sites, not others | Site cost misconfigured / target in that site is offline | `Get-DfsnFolderTarget`, check site membership |
| Works, then randomly fails | Referral cache expiry hitting offline target | Target server unreachable; or referral TTL too short |
| New folder not visible | AD replication hasn't propagated yet | Check AD replication, or `dfsutil /purge` on clients |
| Access denied (not path error) | Permissions on target share/NTFS, not DFS | Test `\\targetserver\share` directly |
| Very slow access | Client resolving to distant target | Check AD site assignment of client + target |
| "DFS namespace cannot be found" | Namespace root missing from AD / registry | `Get-DfsnRoot` — check for errors |
| Works for some users, not others | NTFS/share permissions on target | Test direct path with affected user's account |
| Event ID 14548 | DFS namespace data corrupted or unreadable | Registry/AD namespace object integrity |

---

## Validation Steps

Run in order. Stop when you find the break. Each step must pass before proceeding.

```powershell
# --- Layer 1: DNS ---
Resolve-DnsName contoso.com
Resolve-DnsName <NamespaceServerFQDN>
# Must resolve correctly. Mismatched IPs = wrong DC or stale DNS record.

# --- Layer 2: DFS service ---
Get-Service Dfs -ComputerName <ns1>, <ns2>
# Must be Running on all namespace servers.

# --- Layer 3: Namespace exists ---
Get-DfsnRoot -Path \\contoso.com\<namespacename>
# Must return a namespace object without errors.

# --- Layer 4: Namespace servers registered ---
Get-DfsnRootTarget -Path \\contoso.com\<namespacename>
# All listed servers must show State: Online.

# --- Layer 5: Folder targets ---
Get-DfsnFolder -Path \\contoso.com\<namespacename> |
  ForEach-Object { Get-DfsnFolderTarget -Path $_.Path } |
  Where-Object { $_.State -ne "Online" }
# Should return nothing. Any Offline = investigate that target.

# --- Layer 6: Referral from client ---
dfsutil /root:\\contoso.com\<namespacename> /view
# Should show namespace structure without errors.

# --- Layer 7: Direct target access ---
Test-Path \\<TargetServer>\<ShareName>
# Must succeed. If this fails but DFS namespace is fine = it's a target server problem.

# --- Layer 8: AD namespace object ---
Get-ADObject -Filter { objectClass -eq "msDFS-Namespacev2" } `
  -SearchBase "CN=Dfs-Configuration,CN=System,DC=contoso,DC=com"
# Must exist. If missing = namespace lost from AD.
```

---

## Troubleshooting Steps

### Phase 1 — Confirm scope
```powershell
# Who is affected? Test from multiple clients and sites
# Test the direct UNC path — bypass DFS
Test-Path \\<TargetServer>\<ShareName>

# Test the DFS path
Test-Path \\contoso.com\<namespacename>\<folder>

# If direct works but DFS fails → DFS layer issue
# If both fail → target server issue
# If DFS works for some clients → site/referral ordering issue
```

### Phase 2 — Clear client cache
```powershell
# On affected client — rule out stale referral
dfsutil /pktflush    # Clears referral cache
dfsutil /spcflush    # Clears server connection cache
ipconfig /flushdns   # Clear DNS cache while we're here
```

### Phase 3 — Check namespace server health
```powershell
# Check all namespace servers for this root
$nsServers = (Get-DfsnRootTarget -Path \\contoso.com\<ns>).TargetPath -replace "\\\\","" | 
  ForEach-Object { $_.Split("\")[0] }

foreach ($server in $nsServers) {
    Write-Host "=== $server ===" -ForegroundColor Cyan
    Get-Service Dfs -ComputerName $server | Select Name, Status, StartType
    
    # Check for recent DFS events
    Get-WinEvent -ComputerName $server -LogName "DFS Namespaces" -MaxEvents 20 |
      Where-Object { $_.Level -le 3 } |  # 1=Critical, 2=Error, 3=Warning
      Select TimeCreated, Id, Message | Format-Table -Wrap
}
```

### Phase 4 — AD replication health (domain-based namespaces)
```powershell
# Are DCs replicating namespace changes?
repadmin /showrepl
repadmin /replsummary

# Force replication if needed
repadmin /syncall /AdeP
```

### Phase 5 — Site topology
```powershell
# What site is the client in?
nltest /dsgetsite    # Run on client

# What site is each namespace server in?
nltest /server:<NamespaceServer> /dsgetsite

# Check site link costs
Get-ADReplicationSiteLink -Filter * | Select Name, Cost, ReplicationFrequencyInMinutes
```

---

## Remediation Playbooks

<details><summary>Playbook 1 — DFS Service crashed or won't start</summary>

**Symptoms:** Event 14548, 7034; service stopped; `dfsutil /root` returns error

```powershell
# Check why the service stopped
Get-WinEvent -LogName System |
  Where-Object { $_.Id -in 7034, 7023 -and $_.Message -match "DFS" } |
  Select TimeCreated, Message | Format-Table -Wrap

# Check registry namespace data integrity
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Dfs\Parameters\Replicated" -ErrorAction SilentlyContinue

# Restart and monitor
Start-Service Dfs
Get-Service Dfs | Select Status
Start-Sleep -Seconds 10
Get-WinEvent -LogName "DFS Namespaces" -MaxEvents 5 | Select TimeCreated, LevelDisplayName, Message

# If service won't start — collect for escalation
sfc /scannow
Get-EventLog -LogName System -Source "Service Control Manager" -Newest 20 |
  Where-Object { $_.Message -match "DFS" }
```

**Rollback:** N/A — starting the service is non-destructive.

</details>

<details><summary>Playbook 2 — Folder target offline</summary>

**Symptoms:** `Get-DfsnFolderTarget` shows State: Offline; users can't reach specific folders

```powershell
# Get all offline targets
Get-DfsnFolder -Path \\contoso.com\<ns> | ForEach-Object {
    Get-DfsnFolderTarget -Path $_.Path
} | Where-Object { $_.State -ne "Online" } | 
  Select Path, TargetPath, State

# For each offline target — check the target server
$targetServer = "<TargetServer>"
$shareName = "<ShareName>"

# Is the server reachable?
Test-Connection $targetServer -Count 2

# Is the share present?
Get-SmbShare -Name $shareName -CimSession $targetServer -ErrorAction SilentlyContinue

# If share is missing, recreate
New-SmbShare -Name $shareName -Path "D:\<path>" `
  -FullAccess "Domain Admins" -ChangeAccess "Domain Users" `
  -CimSession $targetServer

# Bring target back online in DFS
Set-DfsnFolderTarget -Path "\\contoso.com\<ns>\<folder>" `
  -TargetPath "\\$targetServer\$shareName" -State Online

# Verify
Get-DfsnFolderTarget -Path "\\contoso.com\<ns>\<folder>"
```

</details>

<details><summary>Playbook 3 — Namespace missing from AD</summary>

**Symptoms:** `Get-DfsnRoot` fails; Event 14548 on namespace servers; namespace disappeared after DC restore

> ⚠️ Before taking action: verify with AD restore history. This may indicate a bad DC restore.

```powershell
# Confirm namespace is gone from AD
$adPath = "CN=Dfs-Configuration,CN=System,$(([adsi]'').distinguishedName)"
Get-ADObject -Filter { objectClass -eq "msDFS-Namespacev2" } -SearchBase $adPath |
  Select Name, DistinguishedName

# Option A: Restore from AD backup (preferred)
# Use AD Recycle Bin if enabled:
Get-ADObject -Filter { objectClass -eq "msDFS-Namespacev2" -and isDeleted -eq $true } `
  -IncludeDeletedObjects -SearchBase $adPath |
  Restore-ADObject

# Option B: Recreate namespace (if no backup)
# First, document all existing targets if any servers still have cached config
dfsutil /root:\\contoso.com\<ns> /export C:\dfs-backup.txt

# Recreate root
New-DfsnRoot -Path \\contoso.com\<ns> -Type DomainV2 `
  -TargetPath \\<NamespaceServer>\<RootShare>

# Re-add all folders and targets from your documentation
```

</details>

---

## Evidence Pack

For escalation to Microsoft or senior engineer:

```powershell
# Run on affected namespace server — generates diagnostic bundle
$path = "C:\DFS-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm')"
New-Item -ItemType Directory -Path $path

# DFS namespace config
dfsutil /root:\\contoso.com\<ns> /export "$path\dfs-config.txt"

# Event logs
Get-WinEvent -LogName "DFS Namespaces" -MaxEvents 100 |
  Export-Csv "$path\dfs-events.csv" -NoTypeInformation

# AD namespace objects
Get-ADObject -Filter { objectClass -eq "msDFS-Namespacev2" } `
  -SearchBase "CN=Dfs-Configuration,CN=System,$(([adsi]'').distinguishedName)" `
  -Properties * | Export-Csv "$path\ad-namespace-objects.csv" -NoTypeInformation

# Namespace targets
Get-DfsnFolder -Path \\contoso.com\<ns> | ForEach-Object {
    Get-DfsnFolderTarget -Path $_.Path
} | Export-Csv "$path\folder-targets.csv" -NoTypeInformation

# AD replication status
repadmin /showrepl > "$path\repadmin-showrepl.txt"
repadmin /replsummary > "$path\repadmin-summary.txt"

# Service status across namespace servers
(Get-DfsnRootTarget -Path \\contoso.com\<ns>).TargetPath | 
  ForEach-Object { $s = $_.Split("\")[2]; Get-Service Dfs -ComputerName $s } |
  Export-Csv "$path\dfs-service-status.csv" -NoTypeInformation

Write-Host "Evidence bundle saved to $path"
```

---

## Command Cheat Sheet

```powershell
# ---- NAMESPACE ----
Get-DfsnRoot -Path \\domain\ns                          # View root
Get-DfsnRootTarget -Path \\domain\ns                    # View namespace servers
Get-DfsnFolder -Path \\domain\ns                        # List all folders
Get-DfsnFolderTarget -Path \\domain\ns\folder           # View targets for a folder
Set-DfsnFolderTarget -Path ... -State Online/Offline    # Bring target up/down
New-DfsnFolder -Path \\domain\ns\folder -TargetPath \\srv\share   # Add folder
New-DfsnFolderTarget -Path \\domain\ns\folder -TargetPath \\srv2\share  # Add target

# ---- CLIENT SIDE ----
dfsutil /pktinfo                   # Show cached referrals
dfsutil /pktflush                  # Clear referral cache
dfsutil /spcflush                  # Clear server connection cache
dfsutil /root:\\domain\ns /view    # View namespace from client perspective

# ---- DIAGNOSTICS ----
dfsdiag /testdfsconfig /DFSRoot:\\domain\ns           # Full config validation
dfsdiag /testdfsintegrity /DFSRoot:\\domain\ns /recurse /full  # Integrity check
dfsdiag /testsites /DFSPath:\\domain\ns /Recurse      # Site cost validation

# ---- AD ----
Get-ADObject -Filter { objectClass -eq "msDFS-Namespacev2" } -SearchBase "CN=Dfs-Configuration,CN=System,DC=contoso,DC=com"
```

---

## 🎓 Learning Pointers

- **The referral model is everything** — DFS is not a file server. It's a referral service. Internalise that the namespace server only tells clients *where to go*, it doesn't serve files. This changes every diagnostic instinct.
- **Site topology and DFS** — DFS uses AD Sites to order referrals by network cost. If your AD site topology is inaccurate (clients in wrong sites, site link costs not reflecting reality), DFS will route users to the "wrong" server. Read: [How DFS Handles Referrals](https://learn.microsoft.com/en-us/windows-server/storage/dfs-namespaces/dfs-overview#referrals-and-server-selection)
- **Root Scalability Mode deep dive** — When and why to use it, and what breaks when the PDC goes down in each mode: [4sysops: DFS Root Scalability](https://4sysops.com/archives/dfs-root-scalability-mode/)
- **dfsdiag vs dfsutil** — `dfsutil` is for manual inspection and changes; `dfsdiag` is for automated testing and validation. Most engineers only use `dfsutil`. The `dfsdiag /testdfsintegrity` output is gold for post-mortem reports.
- **DFS and AD Recycle Bin** — If namespace objects disappear (DC restore gone wrong, accidental deletion), the AD Recycle Bin is your fastest recovery path if it was enabled. Worth knowing before you need it.
- **Community rabbit hole** — Search "DFS namespace referral not working" on [Spiceworks](https://community.spiceworks.com) — real-world edge cases around site costing, proxy server interference with referrals, and PDC emulator failover are documented extensively there.
