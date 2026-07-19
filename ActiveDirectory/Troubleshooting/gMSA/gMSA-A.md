# Group Managed Service Accounts (gMSA) — Reference Runbook (Mode A: Deep Dive)
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

**In scope:**
- Group Managed Service Accounts (gMSA) — multi-host automatic-password service identities, Windows Server 2012+
- KDS Root Key architecture and the Group Key Distribution Service (GKDS)
- Delegation model (`PrincipalsAllowedToRetrieveManagedPassword`), password rotation, and cross-forest limitations
- Common consumers: Windows services, IIS application pools, scheduled tasks, failover cluster roles, AD FS farm identity

**Out of scope:**
- Standalone Managed Service Accounts (sMSA) — the single-host-only predecessor from Windows Server 2008 R2, largely superseded by gMSA
- AD FS-specific farm identity troubleshooting beyond the gMSA layer itself (see `ActiveDirectory/Troubleshooting/ADFS/ADFS-A.md`)
- Delegated Managed Service Accounts (dMSA) — new in Windows Server 2025, briefly flagged in Learning Pointers but not covered in depth; verify current Microsoft Learn guidance before relying on this runbook for dMSA-specific work
- Third-party credential vaulting/PAM solutions as an alternative to gMSA

**Assumptions:**
- You have Domain Admin or delegated rights sufficient to create/manage AD service account objects and KDS root keys
- The `ActiveDirectory` PowerShell module (RSAT) is available on at least one management host
- Target hosts are domain-joined Windows Server 2012+ or Windows 8+

---
## How It Works

<details><summary>Full architecture — KDS root key, GKDS, and password derivation</summary>

### The Problem gMSA Solves

Traditional service accounts have a static, human-set password shared across every server that runs the service. Rotating it means touching every host's service configuration simultaneously — in practice, passwords rarely rotate, becoming long-lived high-value credentials. Standalone Managed Service Accounts (sMSA, Server 2008 R2) fixed the "auto-rotating password" problem but tied the account to exactly one computer, making them useless for load-balanced or clustered services. gMSA (Server 2012+) generalizes this: **any number of authorized hosts can independently and correctly compute the current password without ever transmitting it between them.**

### Key Distribution Services (KDS) Root Key

The forest-wide KDS root key is the seed material every domain controller uses to derive gMSA passwords. It is created once per forest with `Add-KdsRootKey` and, critically, defaults to an `EffectiveTime` **10 hours in the future** rather than immediately usable. This delay exists because the root key must replicate to *every* DC in the forest before any host can safely rely on it — a DC that hasn't yet received the key would fail (or worse, compute an inconsistent result) if asked to serve a gMSA password request before replication converges. The 10-hour default is a conservative estimate of worst-case AD replication latency, not an arbitrary number.

### Group Key Distribution Service (GKDS) and Password Derivation

When a host needs a gMSA's current password, its local LSA contacts a DC's Group Key Distribution Service, which uses the KDS root key plus the gMSA's SID and the current time interval to derive a 256-bit password via a one-way key derivation function (a construction based on `SP800-108` KDF in counter mode). Because the derivation is deterministic given the same root key, SID, and time interval, **every authorized host independently computes the identical password** — there is no password transmitted or synced between hosts, and no central "current password" store beyond the KDS root key itself.

### The Two-Step Authorization Model

Using a gMSA on a host requires two distinct, separately-failable steps:
1. **AD-side delegation** — the gMSA object's `PrincipalsAllowedToRetrieveManagedPassword` attribute lists which computer accounts (directly, or via group membership) are permitted to retrieve the password. This is an authorization grant, evaluated when the host requests the password.
2. **Local installation** — `Install-ADServiceAccount` on the target host caches the account object locally (populating the local security subsystem so services can reference `DOMAIN\gMSAName$`). A host can be fully authorized in AD and still fail every service start if this step was skipped — the two failure modes look identical from the service's perspective ("logon failure") but require different fixes.

### Password Rotation

By default, the password rotates every 30 days (`msDS-ManagedPasswordInterval`, configurable per-gMSA on Windows Server 2016+ domain functional level and above). Rotation requires no coordination between hosts — each host simply re-derives the new password from the (unchanged) KDS root key and the new time interval the next time it needs to authenticate. A host that's offline during rotation will correctly compute the new password whenever it comes back online, because the derivation is time-interval-based, not push-based.

### Forest Scoping

gMSA password derivation depends on forest-local KDS root key material and Kerberos AES-256 support. This means a gMSA created in Forest A **cannot** be authorized for use by a computer in Forest B, even across a fully-transitive, healthy forest trust — the derivation function has no cross-forest analog. This is a hard architectural boundary, not a permission that can be granted.

</details>

---
## Dependency Stack

```
Forest has ≥1 Windows Server 2012+ DC capable of hosting the KDS root key / Group Key Distribution Service
  └── KDS Root Key created (Add-KdsRootKey) and its EffectiveTime has passed (default 10-hour convergence window)
        └── AD replication has carried the root key object to every DC that requesting hosts will contact
              └── gMSA object created (New-ADServiceAccount) with PrincipalsAllowedToRetrieveManagedPassword set
                    └── Target host is domain-joined, Server 2012+/Windows 8+, and is itself (or via group) authorized
                          └── Install-ADServiceAccount run locally on that host — caches the account
                                └── Local LSA reaches a DC's GKDS to derive the current password on demand
                                      └── Service/scheduled task/app pool logon configured as DOMAIN\gMSAName$ with a blank password
                                            └── msDS-ManagedPasswordInterval rotation (default 30 days) — every authorized host re-derives independently
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| `New-ADServiceAccount` fails, error references a missing/unavailable key | No KDS root key exists in the forest yet | `Get-KdsRootKey` |
| gMSA created successfully, but every host fails to retrieve the password immediately after | KDS root key's `EffectiveTime` hasn't passed yet (10-hour default) | `Get-KdsRootKey \| Select EffectiveTime` |
| Works on some hosts, fails on others | Failing hosts (or their group) aren't in `PrincipalsAllowedToRetrieveManagedPassword`, or group membership hasn't replicated yet | `Get-ADServiceAccount -Properties PrincipalsAllowedToRetrieveManagedPassword`; confirm group membership + replication |
| `Test-ADServiceAccount` returns `False` on an authorized host | `Install-ADServiceAccount` was never run locally on that host | Run `Install-ADServiceAccount`, then re-test |
| `Test-ADServiceAccount` returns `True` but the service still won't start | Service is configured with the wrong account format or a literal password instead of a blank one | `Get-CimInstance Win32_Service` → check `StartName` |
| gMSA worked for months, fails domain-wide on the same day | Password rotation (default 30 days) coincided with a KDS root key or DC reachability problem | Correlate failure time with `msDS-ManagedPasswordInterval` rotation schedule and DC health |
| Attempting to authorize a computer in a trusted forest, fails regardless of trust health | gMSA cannot cross a forest boundary — architectural, not a permission gap | Confirm both computer and gMSA are in the same forest |
| A newly-added Failover Cluster node can't run the clustered service using the gMSA | New node was never individually added to `PrincipalsAllowedToRetrieveManagedPassword` (cluster membership doesn't auto-grant this) | `Get-ADServiceAccount -Properties PrincipalsAllowedToRetrieveManagedPassword` against the cluster's authorized group |
| Event ID 6 in `Microsoft-Windows-GroupManagedServiceAccounts/Operational` | Generic password-retrieval failure — the embedded error text distinguishes authorization vs. KDS root key vs. network reachability causes | Read the full event message, not just the ID |
| Service authenticates fine locally but Kerberos delegation to a backend resource fails | gMSA is correctly authenticating, but constrained/resource-based delegation for the *service's* onward calls was never configured — a separate delegation problem, not a gMSA problem | Review `msDS-AllowedToDelegateTo` / RBCD on the target resource |

---
## Validation Steps

**Step 1 — Confirm KDS root key state**
```powershell
Get-KdsRootKey | Select-Object KeyId, EffectiveTime, CreationTime
```
Expected: at least one key with `EffectiveTime` in the past.

**Step 2 — Confirm the gMSA object and delegation**
```powershell
Get-ADServiceAccount -Identity "<gMSAName>" -Properties * |
  Select-Object Name, Enabled, DNSHostName, PrincipalsAllowedToRetrieveManagedPassword, "msDS-ManagedPasswordInterval"
```
Expected: `Enabled = True`; the authorized-hosts group or specific hosts listed.

**Step 3 — Confirm group-based delegation membership**
```powershell
Get-ADGroupMember -Identity "<AuthorizedHostsGroup>" | Select-Object Name, ObjectClass
```
Expected: every intended host's computer object is a current, replicated member.

**Step 4 — From the target host, confirm local installation state**
```powershell
Get-Service -Name "ADServiceAccounts" -ErrorAction SilentlyContinue  # sanity check the host is domain-joined and functional
Get-ADServiceAccount -Identity "<gMSAName>"
```

**Step 5 — From the target host, run the actual retrieval test**
```powershell
Test-ADServiceAccount -Identity "<gMSAName>"
```
Expected: `True`. This is the single authoritative test that the whole chain — KDS root key, delegation, local installation, and network path to a DC — is working end to end for this specific host.

**Step 6 — Confirm the consuming service is configured correctly**
```powershell
Get-CimInstance Win32_Service -Filter "Name='<ServiceName>'" | Select-Object Name, StartName, State, Status
```
Expected: `StartName = "DOMAIN\gMSAName$"`.

**Step 7 — Review the GMSA-specific event log for the exact failure reason**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-GroupManagedServiceAccounts/Operational" -MaxEvents 50 |
  Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-List
```

---
## Troubleshooting Steps (by phase)

### Phase 1 — Forest / KDS Root Key Layer
1. Confirm at least one KDS root key exists and has passed its `EffectiveTime`
2. If the forest is genuinely brand-new to gMSA, expect and communicate the 10-hour wait — don't backdate a production key to skip it
3. Confirm the DC serving the request has actually replicated the root key object (check replication health per `AD-Replication-A.md` if any DC is behind)

### Phase 2 — Delegation Layer
1. Confirm the specific failing host (not just "a host like it") is listed in `PrincipalsAllowedToRetrieveManagedPassword`, directly or via group
2. If via group, confirm the host's group membership has actually replicated to the DC it's contacting
3. Prefer group-based delegation for anything beyond a single host — direct host entries don't scale and are easy to forget when adding cluster nodes

### Phase 3 — Local Installation Layer
1. Run `Install-ADServiceAccount` on the host if it hasn't been run — authorization in AD does not imply local installation
2. Re-run `Test-ADServiceAccount` after installation to confirm end-to-end success
3. If installation itself fails, confirm the ActiveDirectory PowerShell module and RSAT tools are present and the host can reach a DC over the ports AD normally requires

### Phase 4 — Service Configuration Layer
1. Confirm the consuming service/task/app pool is configured with `DOMAIN\gMSAName$` and a blank password — not a typed password, not a missing `$`
2. For scheduled tasks, confirm the task principal's logon type is compatible with gMSA (password-based logon type, not "S4U only" without the account properly registered)
3. Restart the service/recycle the app pool after any credential change — a running process won't pick up a corrected logon account without a restart

### Phase 5 — Rotation & Ongoing Health
1. If a gMSA that worked for a long time suddenly fails everywhere at once, check whether the failure timestamp aligns with a rotation boundary (`msDS-ManagedPasswordInterval`)
2. Confirm no DC was unreachable or unhealthy at the rotation boundary — a rotation itself doesn't require host coordination, but a DC issue at the wrong moment can surface as if it does

---
## Remediation Playbooks

<details><summary>Playbook 1 — First-time gMSA rollout in a forest with no existing KDS root key</summary>

**Scenario:** Standing up gMSA for the first time in a forest — no KDS root key exists yet.

**Step 1 — Create the KDS root key with the default (safe) effective time**
```powershell
Add-KdsRootKey
```
This defaults to `EffectiveTime` = now + 10 hours. Plan the gMSA-dependent deployment around this wait — don't schedule a cutover for the same day.

**Step 2 — After the wait, confirm convergence**
```powershell
Get-KdsRootKey | Select-Object KeyId, EffectiveTime
```

**Step 3 — Create the gMSA with delegation to a group, not individual hosts**
```powershell
New-ADGroup -Name "gMSA-<ServiceName>-Hosts" -GroupScope DomainLocal -GroupCategory Security
New-ADServiceAccount -Name "<gMSAName>" -DNSHostName "<gMSAName>.<domain.fqdn>" `
  -PrincipalsAllowedToRetrieveManagedPassword "gMSA-<ServiceName>-Hosts"
```

**Step 4 — Add hosts to the group and install locally on each**
```powershell
Add-ADGroupMember -Identity "gMSA-<ServiceName>-Hosts" -Members "<Host1>$","<Host2>$"
# On each host:
Install-ADServiceAccount -Identity "<gMSAName>"
Test-ADServiceAccount -Identity "<gMSAName>"
```

**Rollback note:** Nothing here is destructive — a KDS root key, once created, is safe to leave in place even if the gMSA rollout is abandoned. Removing the gMSA object (`Remove-ADServiceAccount`) is a clean, reversible-by-recreation operation as long as no live service depends on it at the time.

</details>

<details><summary>Playbook 2 — Migrating an existing service from a static-password service account to gMSA</summary>

**Scenario:** A service (IIS app pool, Windows service, scheduled task) currently runs under a traditional domain service account with a static password, and the goal is to move it to gMSA for automatic rotation.

**Step 1 — Create and delegate the gMSA (see Playbook 1 if no KDS root key exists yet)**

**Step 2 — Install and validate on the target host(s) *before* touching the live service**
```powershell
Install-ADServiceAccount -Identity "<gMSAName>"
Test-ADServiceAccount -Identity "<gMSAName>"
```

**Step 3 — Reconfigure the service to use the gMSA, in a maintenance window**
```powershell
sc.exe config "<ServiceName>" obj= "DOMAIN\gMSAName$" password= ""
Restart-Service -Name "<ServiceName>"
```

**Step 4 — Confirm the service starts and functions correctly, then decommission the old service account**
```powershell
Get-Service -Name "<ServiceName>" | Select-Object Status
```
Only disable (don't immediately delete) the old service account for a rollback window — deleting it removes the ability to quickly revert if the gMSA migration surfaces an unexpected issue (e.g., a hardcoded dependency on the old account's SID in an ACL somewhere).

**Rollback note:** Revert `StartName` to the original account and re-enable it if issues surface. Keep the old account disabled-but-present for at least one full business cycle before deletion.

</details>

<details><summary>Playbook 3 — Authorizing an additional Failover Cluster node</summary>

**Scenario:** A clustered role uses a gMSA; a new node was added to the cluster but the clustered service fails to start on it.

**Step 1 — Confirm the new node isn't authorized**
```powershell
Get-ADServiceAccount -Identity "<gMSAName>" -Properties PrincipalsAllowedToRetrieveManagedPassword
```

**Step 2 — Add the new node to the authorized-hosts group (cluster membership does not imply this automatically)**
```powershell
Add-ADGroupMember -Identity "gMSA-<ServiceName>-Hosts" -Members "<NewNode>$"
```

**Step 3 — Install and validate locally on the new node**
```powershell
Install-ADServiceAccount -Identity "<gMSAName>"
Test-ADServiceAccount -Identity "<gMSAName>"
```

**Step 4 — Fail the clustered role over to the new node to confirm**

**Rollback note:** Removing the node from the authorized-hosts group reverts the grant cleanly; the node's local gMSA cache can be removed with `Uninstall-ADServiceAccount` if it's being removed from the cluster entirely.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  gMSA Evidence Collector
.NOTES     Run from a DC (or host with RSAT) with rights to read the gMSA object,
           then separately from the affected host for the local-side checks.
#>

$reportPath = "C:\Temp\gMSAEvidence_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

"=== KDS Root Key(s) ===" | Out-File "$reportPath\01_KdsRootKey.txt"
Get-KdsRootKey | Format-List | Out-File "$reportPath\01_KdsRootKey.txt" -Append

"=== gMSA Object ===" | Out-File "$reportPath\02_gMSAObject.txt"
Get-ADServiceAccount -Identity "<gMSAName>" -Properties * |
  Format-List | Out-File "$reportPath\02_gMSAObject.txt" -Append

"=== Authorized Hosts Group Membership ===" | Out-File "$reportPath\03_GroupMembership.txt"
Get-ADGroupMember -Identity "<AuthorizedHostsGroup>" |
  Format-List | Out-File "$reportPath\03_GroupMembership.txt" -Append

"=== GMSA Operational Event Log (last 100) ===" | Out-File "$reportPath\04_GMSAEvents.txt"
Get-WinEvent -LogName "Microsoft-Windows-GroupManagedServiceAccounts/Operational" -MaxEvents 100 -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id, LevelDisplayName, Message |
  Format-List | Out-File "$reportPath\04_GMSAEvents.txt" -Append

Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "Evidence collected: $reportPath.zip" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Check KDS root key(s) and effective time | `Get-KdsRootKey \| Select KeyId, EffectiveTime` |
| Create a KDS root key (production, safe default) | `Add-KdsRootKey` |
| Create a KDS root key (lab-only, immediate use) | `Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10))` |
| Create a gMSA | `New-ADServiceAccount -Name "<Name>" -DNSHostName "<fqdn>" -PrincipalsAllowedToRetrieveManagedPassword "<Group>"` |
| View gMSA delegation | `Get-ADServiceAccount -Identity "<Name>" -Properties PrincipalsAllowedToRetrieveManagedPassword` |
| Update gMSA delegation | `Set-ADServiceAccount -Identity "<Name>" -PrincipalsAllowedToRetrieveManagedPassword "<Group>"` |
| Install gMSA locally on a host | `Install-ADServiceAccount -Identity "<Name>"` |
| Uninstall gMSA locally | `Uninstall-ADServiceAccount -Identity "<Name>"` |
| Test retrieval end-to-end from a host | `Test-ADServiceAccount -Identity "<Name>"` |
| Configure a Windows service to use a gMSA | `sc.exe config "<Service>" obj= "DOMAIN\Name$" password= ""` |
| View the gMSA-specific event log | `Get-WinEvent -LogName "Microsoft-Windows-GroupManagedServiceAccounts/Operational"` |
| Check password rotation interval | `Get-ADServiceAccount -Identity "<Name>" -Properties msDS-ManagedPasswordInterval` |

---
## 🎓 Learning Pointers

- **gMSA's core innovation is deterministic, independent password derivation** — no host ever transmits or syncs a password with another; every authorized host computes the same value from the same KDS root key, SID, and time interval. Understanding this explains why rotation "just works" with zero coordination. [Getting Started with Group Managed Service Accounts](https://learn.microsoft.com/en-us/windows-server/security/group-managed-service-accounts/getting-started-with-group-managed-service-accounts)
- **The 10-hour KDS root key convergence delay is a replication-safety margin, not an arbitrary limit.** It protects against a DC that hasn't yet replicated the key being asked to serve a password derivation before it can do so correctly.
- **Authorization (AD-side) and installation (host-side) are independently failable.** Treat "the host is in `PrincipalsAllowedToRetrieveManagedPassword`" and "the host has actually run `Install-ADServiceAccount`" as two separate checklist items — they fail for different reasons and produce identical symptoms.
- **gMSA is a hard forest boundary.** Unlike most AD delegation models that can be extended via trusts, gMSA password computation is forest-local by design — plan cross-forest service consolidation around this rather than fighting it.
- **Delegate via groups, not individual host entries**, especially for anything that scales — clusters, farms, load-balanced pools. Adding a node to the cluster does not automatically authorize it for the gMSA; that's always a separate step.
- **Windows Server 2025 introduced delegated Managed Service Accounts (dMSA)** as a further evolution — aimed at easing migration away from legacy (non-gMSA) service accounts and reducing certain Kerberos-related attack surface. This is newer technology with active industry security research attention; verify current Microsoft Learn guidance directly before treating dMSA specifics as settled, since this runbook's depth is on the long-stable gMSA model rather than dMSA. [Group Managed Service Accounts overview](https://learn.microsoft.com/en-us/windows-server/security/group-managed-service-accounts/group-managed-service-accounts-overview)
