# Group Managed Service Accounts (gMSA) — Hotfix Runbook (Mode B: Ops)
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

Run these from an elevated PowerShell session — steps 1-3 from a DC (or a machine with the ActiveDirectory module), steps 4-5 from the affected host itself:

```powershell
# 1. Confirm the KDS root key exists and check its effective time
Get-KdsRootKey | Select-Object KeyId, EffectiveTime, CreationTime

# 2. Confirm the gMSA object exists and see who's authorized to retrieve its password
Get-ADServiceAccount -Identity "<gMSAName>" -Properties PrincipalsAllowedToRetrieveManagedPassword |
  Select-Object Name, Enabled, PrincipalsAllowedToRetrieveManagedPassword

# 3. Confirm the affected host (or its group) is actually in the authorized list — compare against step 2's output
Get-ADComputer -Identity "<HostName>"

# 4. From the AFFECTED HOST — confirm the gMSA is installed locally
Get-ADServiceAccount -Identity "<gMSAName>" | Test-ADServiceAccount

# 5. From the AFFECTED HOST — check the GMSA event log for the specific failure
Get-WinEvent -LogName "Microsoft-Windows-GroupManagedServiceAccounts/Operational" -MaxEvents 20
```

| What you see | What it means |
|---|---|
| `Get-KdsRootKey` returns nothing | No root key exists yet — no gMSA in the forest can work until one is created |
| `EffectiveTime` is in the future | Root key exists but hasn't converged yet (default 10-hour delay) — gMSAs will fail to resolve passwords until that time passes |
| `Test-ADServiceAccount` returns `False` on the affected host | Either the host isn't authorized (`PrincipalsAllowedToRetrieveManagedPassword`), the KDS root key hasn't converged, or `Install-ADServiceAccount` was never run on this host — go to Fix 2 or Fix 3 |
| `Test-ADServiceAccount` returns `True` but the *service* still won't start | The service/scheduled task/app pool logon credential isn't configured correctly for a gMSA (wrong account format or a literal password was entered) — go to Fix 4 |
| Event ID 6 in the GMSA Operational log | Password retrieval failed — read the embedded error text; it almost always points at authorization or KDS root key convergence |
| gMSA worked for months, suddenly fails tenant/domain-wide on the same day | Password rotation (default every 30 days) landed during a KDS root key or DC reachability problem — check `msDS-ManagedPasswordInterval` and DC health, not the gMSA object itself |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Forest has ≥1 Windows Server 2012+ DC able to serve KDS root key material
  └── KDS Root Key created (Add-KdsRootKey) AND past its EffectiveTime
        └── AD replication has carried the root key to every DC the requesting hosts talk to
              └── gMSA object exists with PrincipalsAllowedToRetrieveManagedPassword delegation set
                    └── Target host is domain-joined (Server 2012+ / Windows 8+) and is itself — or its group — authorized
                          └── Install-ADServiceAccount run locally on that host (caches the account)
                                └── Local LSA can reach a DC to compute the current password via the Group Key Distribution Service
                                      └── Service/task/app pool configured to log on as DOMAIN\gMSA$ with a BLANK password
                                            └── msDS-ManagedPasswordInterval rotation (default 30 days) — every authorized host re-derives independently, no manual sync
```

Key failure points:
- The 10-hour KDS root key convergence delay after first creation — the single most common "it worked in the lab, fails in prod five minutes later" cause
- Host authorized in AD but `Install-ADServiceAccount` never actually run on that host — authorization and local installation are two separate steps
- gMSA cannot cross a forest trust boundary — this is architectural, not a permission you can grant your way around
- A Failover Cluster node added after the gMSA was scoped, but never individually added to `PrincipalsAllowedToRetrieveManagedPassword`

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm a KDS root key exists and has converged**
```powershell
Get-KdsRootKey | Select-Object KeyId, EffectiveTime, CreationTime
```
Expected: at least one key with `EffectiveTime` in the past. If the only key's `EffectiveTime` is still in the future, nothing using it will work until that time passes — this is by design, not a bug (the 10-hour default gives AD replication time to carry the key to every DC before any host relies on it).

**Step 2 — Confirm the gMSA object and its delegation**
```powershell
Get-ADServiceAccount -Identity "<gMSAName>" -Properties * |
  Select-Object Name, Enabled, DNSHostName, PrincipalsAllowedToRetrieveManagedPassword, msDS-ManagedPasswordInterval
```
Expected: `Enabled = True`, and the affected host (or a group it belongs to) listed under `PrincipalsAllowedToRetrieveManagedPassword`.

**Step 3 — Confirm group membership resolves correctly (if using a group, not a direct host entry)**
```powershell
Get-ADGroupMember -Identity "<AuthorizedHostsGroup>" | Select-Object Name
```
Expected: the affected host's computer object is a current member — and has had time to replicate if it was just added.

**Step 4 — On the affected host: confirm local installation**
```powershell
Get-ADServiceAccount -Identity "<gMSAName>"
```
If this fails with "cannot find an object with identity" from the host itself, the ActiveDirectory module isn't present — install RSAT first, this step just confirms the module can see AD, not the gMSA state.

**Step 5 — On the affected host: run the actual retrieval test**
```powershell
Test-ADServiceAccount -Identity "<gMSAName>"
```
`True` = this host can successfully compute the current password right now. `False` with no further detail means one of: not authorized, KDS root key not converged, or the gMSA was never installed here (`Install-ADServiceAccount` step skipped).

**Step 6 — Check the GMSA-specific event log for the exact failure**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-GroupManagedServiceAccounts/Operational" -MaxEvents 20 |
  Select-Object TimeCreated, Id, Message | Format-List
```

**Step 7 — Confirm the service/task itself is configured correctly**
```powershell
Get-CimInstance Win32_Service -Filter "Name='<ServiceName>'" | Select-Object Name, StartName
```
Expected: `StartName` shows `DOMAIN\gMSAName$` (note the trailing `$`). Anything else — or evidence a password was manually entered — means Fix 4 applies.

---
## Common Fix Paths

<details><summary>Fix 1 — KDS root key hasn't converged yet</summary>

**Cause:** A KDS root key was just created and its `EffectiveTime` (10 hours from creation, by default) hasn't passed. Every gMSA in the forest will fail to resolve passwords until it does — this is the single most common first-time-setup trap.

```powershell
Get-KdsRootKey | Select-Object KeyId, EffectiveTime
```

**In production:** wait it out — there is no safe way to force convergence faster without risking a DC that hasn't replicated the key yet serving a gMSA request it can't fulfil correctly.

**In a lab/single-DC test environment only** — backdate the key so it's immediately usable (do **not** do this in a multi-DC production forest; a backdated key can be requested by a DC that hasn't replicated it yet, producing intermittent, hard-to-diagnose failures):
```powershell
Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10))
```

**Rollback note:** Creating an additional KDS root key is non-destructive — multiple root keys can coexist, and gMSA password computation simply uses whichever is currently effective. There's nothing to roll back.

</details>

<details><summary>Fix 2 — Host not authorized to retrieve the password</summary>

**Cause:** The host (or its group) was never added to `PrincipalsAllowedToRetrieveManagedPassword`, or was added to a group that hasn't finished replicating.

```powershell
# Preferred: authorize via a group, not individual hosts, for maintainability
Add-ADGroupMember -Identity "<AuthorizedHostsGroup>" -Members "<HostName>$"

# Or authorize directly if not using a group
Set-ADServiceAccount -Identity "<gMSAName>" -PrincipalsAllowedToRetrieveManagedPassword "<HostName>$"

# From the host, force a Kerberos ticket refresh and re-test
klist purge
Test-ADServiceAccount -Identity "<gMSAName>"
```

**Rollback note:** Additive group membership / delegation — remove the specific member to revert scope.

</details>

<details><summary>Fix 3 — gMSA never installed locally on the host</summary>

**Cause:** Authorization in AD only grants the *right* to retrieve the password — the host still needs the account installed locally before any service on it can use it.

```powershell
Install-ADServiceAccount -Identity "<gMSAName>"
Test-ADServiceAccount -Identity "<gMSAName>"
```

**Rollback note:** `Uninstall-ADServiceAccount -Identity "<gMSAName>"` removes the local cached account cleanly — safe if the host no longer needs it.

</details>

<details><summary>Fix 4 — Service/task configured with the wrong credential format</summary>

**Cause:** gMSAs authenticate with the account name (`DOMAIN\gMSAName$`) and a **blank** password — Windows manages the actual password transparently. Entering any literal password, or omitting the trailing `$`, breaks logon.

```powershell
# Windows service — reconfigure logon account correctly
sc.exe config "<ServiceName>" obj= "DOMAIN\gMSAName$" password= ""
Start-Service -Name "<ServiceName>"

# Scheduled task — recreate the principal with the gMSA and no password prompt
$principal = New-ScheduledTaskPrincipal -UserId "DOMAIN\gMSAName$" -LogonType Password -RunLevel Highest
Set-ScheduledTask -TaskName "<TaskName>" -Principal $principal
```

**Rollback note:** Revert `StartName`/principal to the prior account if the gMSA path needs to be backed out — no data implications either way.

</details>

<details><summary>Fix 5 — Attempting to share a gMSA across a forest trust</summary>

**Cause:** gMSA password computation depends on forest-local KDS root key material — it does **not** extend across a forest trust, even a healthy, fully-transitive one.

There is no fix that keeps a single gMSA object working across two forests. Options:
- Create a separate, forest-local gMSA in each forest for the same purpose
- Fall back to a traditional service account with a managed/vaulted password for the cross-forest case only

**Rollback note:** N/A — this is a design constraint, not a broken configuration.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — gMSA Failure

gMSA name: ___________________
Affected host(s): ____________
Service/task/app pool using it: ____________

Get-KdsRootKey EffectiveTime: ____________ (past / future)
Test-ADServiceAccount result on affected host: ____________
PrincipalsAllowedToRetrieveManagedPassword contents: ____________
Affected host's group membership confirmed replicated: (Yes/No)
Install-ADServiceAccount run on affected host: (Yes/No)
Service StartName format confirmed correct (DOMAIN\gMSAName$, blank password): (Yes/No)

Relevant GMSA Operational log event IDs seen: ____________

Steps already attempted:
[ ] Get-KdsRootKey checked for convergence
[ ] PrincipalsAllowedToRetrieveManagedPassword reviewed
[ ] Test-ADServiceAccount run from the affected host
[ ] Install-ADServiceAccount run/re-run on the affected host
[ ] Service/task credential format verified
[ ] Cross-forest scenario ruled out
```

---
## 🎓 Learning Pointers

- **The 10-hour KDS root key convergence delay is the #1 first-time-setup trap.** It exists to give AD replication time to carry the key to every DC before any host relies on it — don't backdate it in production to skip the wait.
- **Authorization and installation are two separate steps.** `PrincipalsAllowedToRetrieveManagedPassword` grants the *right* to retrieve the password; `Install-ADServiceAccount` actually caches it locally. A host can be fully authorized in AD and still fail if the second step was skipped.
- **gMSA passwords rotate automatically and independently on every authorized host** — there is no manual sync step, and no shared "current password" to distribute. If it worked yesterday and fails everywhere today, suspect the rotation landed during a KDS root key or DC reachability problem, not the gMSA object itself.
- **gMSAs are forest-scoped — they cannot cross a forest trust**, no matter how the trust is configured. This trips up MSPs doing cross-forest service consolidation.
- **Authorize via groups, not individual host entries**, so cluster/farm scaling doesn't require recreating the gMSA object each time a node is added.
- This is fast-evolving territory: Windows Server 2025 introduced delegated Managed Service Accounts (dMSA) as an evolution aimed at easing migration off legacy (non-managed) service accounts and reducing Kerberoasting exposure — worth checking current Microsoft Learn guidance directly if dMSA is in scope, since this is newer technology with active security research attention and this runbook focuses on the long-stable gMSA model.
