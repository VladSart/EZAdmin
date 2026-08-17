# AD LDS (Lightweight Directory Services) — Reference Runbook (Mode A: Deep Dive)
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

**In scope:** Active Directory Lightweight Directory Services (AD LDS, formerly Active Directory Application Mode / ADAM) — instance creation and identity, the `ADAM_<instanceName>` service model, per-instance schema and application partitions, the configuration-set multi-master replication model, the two authentication models (instance-local principals and bind-redirection/`userProxy` objects), ADAMSync one-way synchronization from AD DS, and instance removal.

**Out of scope / see elsewhere:**
- Full Active Directory Domain Services replication, FSMO roles, and the domain/forest schema — see `Troubleshooting/Replication/`. AD LDS's replication model is architecturally *similar* (same multi-master, same conflict-resolution rule) but is a **completely separate, per-instance** topology with no shared state, sites, or KCC awareness with AD DS.
- Azure AD Domain Services — despite the similar name, this is an unrelated managed Microsoft cloud service, not AD LDS.
- Entra ID / Entra Connect hybrid identity — see `EntraID/`.
- AD FS claims-based federation — a separate protocol layer; AD LDS is not a federation service.
- Kerberos ticket issuance — AD LDS is **not a KDC**. If an AD LDS server is also domain-joined, the OS handles Kerberos for the machine/domain logon independently of anything AD LDS itself does; AD LDS's own LDAP binds (instance-local or proxy) are a separate mechanism.

**Assumptions:**
- You have local administrator rights on the server hosting the AD LDS instance, and — for bind-redirection troubleshooting — read access to the relevant AD DS domain to check account status.
- The `ActiveDirectory` PowerShell module (RSAT: AD DS and AD LDS Tools) is available.
- You know or can obtain the instance name and its LDAP/SSL ports — AD LDS has no single "default" port the way AD DS has 389/636 baked in; each instance's ports are chosen at creation time.

---
## How It Works

<details><summary>Full architecture</summary>

AD LDS is best understood as **the same directory engine that powers AD DS, running in a mode stripped of domain infrastructure** — no Kerberos KDC, no Group Policy, no SYSVOL, no DNS SRV-record self-registration, no concept of a "domain" or "forest" at all. What's left is a general-purpose, schema-extensible LDAP data store with AD's multi-master replication engine underneath it — which is exactly why it was originally named Active Directory *Application Mode*: it exists to give an application its own directory without requiring that application to become a citizen of your production AD DS forest.

**Instance model.** A single Windows server can host any number of independent AD LDS *instances*, created one at a time (via the AD LDS Setup Wizard, or unattended install). Each instance is a fully separate unit:
- Its own Windows service, always named `ADAM_<instanceName>` (visible in `services.msc` and `Get-Service`).
- Its own LDAP port and SSL port, chosen at creation — there is no fixed default the way AD DS always uses 389/636. If AD LDS is being installed on a box that's also a domain controller (where 389/636 are already owned by AD DS), the setup wizard commonly suggests **50000/50001**, but this is only a convention that avoids the conflict, not a hard-coded AD LDS default; any free port pair is valid.
- Its own on-disk database and log files, physically separate from `NTDS.dit` even when co-located with AD DS on the same box.
- Its own **schema partition** and its own **configuration partition** — AD LDS ships with a minimal base schema and expects the application (or an admin, via `.ldf` schema extension files) to extend it as needed. Extending one instance's schema has zero effect on AD DS's forest-wide schema, and zero effect on any other AD LDS instance on the same or a different server.
- One or more **application directory partitions** — arbitrary-named naming contexts (e.g. `CN=Portal,DC=contoso,DC=extranet`) created either automatically by the connecting application or manually by an admin during instance setup.

**Tooling parity with AD DS, deliberately.** Because it's the same engine, most of the familiar AD DS toolset works against AD LDS with one consistent adjustment: **you must explicitly target `host:port`**, since a bare hostname on a box that's also a DC will resolve to AD DS instead. This applies to `repadmin`, and to standard `ActiveDirectory` PowerShell module cmdlets like `Get-ADObject`, `Get-ADRootDSE`, `New-ADObject`, and `Get-ADReplicationPartnerMetadata` — all support a `-Server "hostname:port"` parameter form specifically for this. `ADSI Edit` and `Ldp.exe` are the GUI equivalents and are the most common tools for ad-hoc browsing/binding during troubleshooting. On a server that has **only** the AD LDS role (no AD DS), `ntdsutil.exe` is not installed by default the way it is on a DC — use `dsdbutil.exe` and `dsmgmt.exe` instead, which provide the AD LDS-equivalent subset of functionality (listing instances, database maintenance, binding an SSL certificate to an instance's SSL port).

**Replication — the "configuration set."** Two or more copies of the *same* instance (same instance identity, deployed to different servers or ports) can be joined into a **configuration set**, which is AD LDS's name for a replica group. Replicas in a configuration set share the schema and configuration partitions and replicate application partition data between them using the same multi-master conflict-resolution rule AD DS uses: on a genuine simultaneous conflicting write to the same attribute, the replica with the **higher attribute version number wins**; if versions are tied, the **most recent timestamp** wins. There is no site topology or KCC-style automatic link generation the way AD DS builds one across an entire domain — a configuration set's replication graph is whatever was explicitly configured when replicas were added.

A documented, easy-to-hit failure mode: if **two or more replicas in the same configuration set have their service account changed at close to the same time**, replication between them can break, because each side needs to authenticate as the (possibly-just-changed) service identity to its partner and a race during propagation leaves them unable to agree. The safe pattern is sequential: change one replica's service account, let replication fully converge, confirm with `repadmin /showrepl`, then move to the next replica.

**Authentication — two distinct, non-overlapping models, chosen per object:**

1. **Instance-local security principals.** A user object created directly inside an AD LDS application partition, with its own password, managed entirely inside AD LDS and completely unrelated to any AD DS account. Simple, self-contained, but yet another credential set for whoever owns the application to manage and for users to remember.

2. **Bind-redirection ("proxy") via `userProxy` objects.** An AD LDS object of class `userProxy`, holding the `objectSid` of a real security principal in a trusted Windows domain (typically the org's own AD DS). When a client binds to this proxy object with a username/password, AD LDS does **not** validate the password itself — it transparently forwards the credential check to the AD DS domain that owns that SID, using the domain portion of the SID to locate the correct domain. This is the integration point most MSP environments actually use AD LDS for: letting an application authenticate against AD LDS's LDAP interface while the *real* password policy, lockout, and expiration all live in AD DS where they're already managed. It has two hard prerequisites that are the source of nearly every "bind redirection" ticket: the AD LDS server must have live network reachability to a domain controller in the SID's domain at bind time, and the underlying AD DS account must itself be enabled, unlocked, and not password-expired — none of which is visible from inside AD LDS, which is why troubleshooting has to explicitly check the real AD DS account rather than assuming the fault is local.

**ADAMSync — one-way, not general sync.** ADAMSync (`adamsync.exe`) is a narrowly-scoped tool shipped for one specific purpose: pulling a defined set of objects/attributes from an AD DS source into an AD LDS instance, one-way only (AD DS → AD LDS; it never writes back). It's driven by an XML configuration file that maps the AD DS search base, filter, and attribute list to the AD LDS target, and it performs **incremental** syncs after the first run by tracking AD DS's `highestCommittedUSN` as a watermark, rather than re-scanning the whole source every time. Because it's read-only against AD DS, the sync account only needs ordinary read permission on the objects/attributes being pulled — it does not need any AD DS replication rights, which is a common point of confusion for anyone who's used to thinking about "sync accounts" in terms of the far more privileged rights an AD Connect-style directory sync account needs.

</details>

---
## Dependency Stack

```
Windows Server + "Active Directory Lightweight Directory Services" role
  (Install-WindowsFeature ADLDS — a Windows Server role/feature, independent of
   whether AD DS is also present on the same box)
      │
      ▼
Per-instance identity (created individually, one at a time)
  ├── ADAM_<instanceName> service
  ├── LDAP port + SSL port (chosen at creation, no universal default)
  ├── Own database/log files (separate from NTDS.dit even if co-located with AD DS)
  ├── Own schema partition (independently extensible, zero cross-instance effect)
  └── Own application directory partition(s)
          │
          ▼
    (Optional) Configuration set — 2+ replicas of the SAME instance
      ├── Shared schema + configuration partitions across replicas
      ├── Multi-master replication (higher-version, then newer-timestamp wins)
      └── Sequential service-account changes only — simultaneous changes across
          replicas in the same set is a documented replication-break trigger
          │
          ▼
    Per-object authentication model (chosen individually, not instance-wide)
      ├── Instance-local principal → password lives entirely in AD LDS
      └── userProxy bind-redirection object → holds a real AD DS objectSid
            └── DEPENDS ON: live network path from the AD LDS server to a DC
                in that SID's domain, AND the real AD DS account being
                enabled/unlocked/not-expired — neither of which AD LDS itself
                can see or report on
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| `ADAM_<name>` service won't start | Port conflict, expired/changed service account password, missing/moved data files | Instance-specific `AD LDS (<instanceName>)` event log |
| Service running, but nothing can bind | Wrong port targeted by the client (bare hostname resolves to AD DS on a co-located DC), or a firewall rule blocking the custom port | `netstat -ano | findstr <port>`, firewall rule review |
| Auth fails for some users, not others | Those accounts are `userProxy` bind-redirection objects and the failure is on the AD DS side | `Get-ADObject -Filter "objectClass -eq 'userProxy'"`, then check the real account |
| Auth fails for ALL users of one application, all at once | AD LDS server lost network reachability to any DC in the proxied domain | `Test-NetConnection` from the AD LDS server to a DC |
| Replication between two replicas stalled/erroring | Recent near-simultaneous service-account change on both replicas | `repadmin /showrepl`, correlate with recent service-account change history |
| Schema extension in one instance "isn't showing up" in another instance or in AD DS | Expected behavior — schemas are fully independent per instance, never shared | Confirm the extension was applied to the correct instance's schema partition |
| ADAMSync run completes but expected objects/attributes are missing in AD LDS | XML config attribute/OU mapping drifted from an AD DS-side schema or OU change, or the sync account lost read permission | Re-run with verbose logging; diff the XML config against current AD DS reality |
| `repadmin`/`Get-ADObject` against AD LDS returns AD DS data instead, or nothing | Command targeted a bare hostname instead of `host:port` | Re-run with explicit `-Server "host:port"` |
| Instance appears to have "disappeared" after a reboot | Service was never set to auto-start, or the box came up with the port already claimed by something else | `Get-Service "ADAM_*" | Select StartType`; `netstat` for the port |

---
## Validation Steps

1. **Instance exists and its service is healthy.**
   ```powershell
   Get-Service "ADAM_*" | Select-Object Name, Status, StartType
   dsdbutil "list instances" q q
   ```
   Good: service `Running`, `StartType Automatic`, and the instance appears in `dsdbutil`'s list with the expected ports. Bad: service missing, `Stopped`, or `Manual` start type on a production instance.

2. **LDAP port is actually listening and reachable.**
   ```powershell
   Test-NetConnection -ComputerName localhost -Port <ldapPort>
   Get-ADRootDSE -Server "localhost:<ldapPort>"
   ```
   Good: `TcpTestSucceeded: True`, and `Get-ADRootDSE` returns `namingContexts` cleanly. Bad: connection refused (service down or wrong port) or a timeout (firewall, or the instance's LDAP stack is unhealthy despite the service showing `Running`).

3. **Application and configuration partitions are intact.**
   ```powershell
   (Get-ADRootDSE -Server "localhost:<ldapPort>").namingContexts
   ```
   Good: shows the expected `CN=Configuration,CN={GUID}`, the schema partition, and every application partition the instance is supposed to host. Bad: a missing application partition (possible corruption or accidental deletion — escalate before attempting repair).

4. **Replication health, if this instance is part of a configuration set.**
   ```powershell
   repadmin /showrepl localhost:<ldapPort>
   repadmin /replsummary localhost:<ldapPort>
   ```
   Good: zero failures, recent successful sync timestamps on every partner. Bad: nonzero consecutive failure count on any partner, or a "last success" timestamp older than your normal replication interval.

5. **Bind-redirection objects resolve to healthy AD DS accounts.**
   ```powershell
   Get-ADObject -Server "localhost:<ldapPort>" -Filter "objectClass -eq 'userProxy'" -Properties objectSid |
     ForEach-Object {
       $sid = (New-Object System.Security.Principal.SecurityIdentifier($_.objectSid,0))
       Write-Host $_.DistinguishedName '->' $sid
     }
   ```
   Good: every SID resolves to an enabled, unlocked AD DS account. Bad: a SID that no longer resolves at all (deleted/recreated account — the proxy object needs to be recreated pointing at the new SID) or resolves to a disabled/locked account.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Confirm the instance itself.** Service status, port reachability, RootDSE bind. Don't proceed to application-level or auth-level troubleshooting until this phase is clean — a huge fraction of "AD LDS auth is broken" tickets are actually "the instance/port I'm pointed at doesn't exist or isn't running."

**Phase 2 — Isolate the authentication model.** Determine whether the failing object is instance-local or a `userProxy` bind-redirection object *before* doing anything else auth-related. This single branch point determines whether you're troubleshooting AD LDS at all, or troubleshooting AD DS through an AD LDS-shaped window.

**Phase 3 (instance-local path) — Object and password state inside AD LDS.** Confirm the object exists, isn't disabled at the AD LDS level (AD LDS instance-local accounts have their own enable/disable and lockout state, entirely separate from AD DS), and that the password hasn't simply expired under whatever password policy is configured for that instance.

**Phase 3 (proxy path) — AD DS account state and network reachability.** Check `LockedOut`, `Enabled`, `PasswordExpired` on the real AD DS account, and confirm the AD LDS server can reach a DC for that domain on the ports the bind-redirection mechanism needs. A network change (new firewall segmentation, a decommissioned DC that was the AD LDS server's only reachable one) is a common silent cause here.

**Phase 4 — Replication (if applicable).** Only relevant if the instance is part of a configuration set. Check `repadmin /showrepl`/`replsummary`, and specifically correlate any failure onset with recent service-account changes on the replicas involved.

**Phase 5 — Escalate with the full picture.** If phases 1-4 are all clean and the symptom persists, the fault is very likely on the application side (wrong bind DN, wrong port in a connection string, or an application-level permission/ACL issue on the objects it's querying) — hand this back to the application owner with the evidence pack below rather than continuing to dig inside AD LDS itself.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Recreate a broken userProxy bind-redirection object</summary>

Used when an AD DS account was deleted and recreated (new SID, even with the same username), leaving the existing `userProxy` object pointing at a SID that no longer resolves.

```powershell
# 1. Get the CURRENT SID of the real AD DS account
$sid = (Get-ADUser -Identity <sAMAccountName> -Server <domainDC>).SID

# 2. Remove the stale proxy object
Remove-ADObject -Server "localhost:<ldapPort>" -Identity "<distinguishedNameOfStaleProxyObject>" -Confirm:$true

# 3. Recreate it pointing at the current SID (exact attribute set depends on the
#    application's schema requirements — confirm with the app owner before recreating,
#    since userProxy objects are frequently created with application-specific
#    additional attributes beyond the bare minimum)
New-ADObject -Server "localhost:<ldapPort>" -Type userProxy `
  -Name "<cn>" -Path "<applicationPartitionDN>" `
  -OtherAttributes @{ objectSid = $sid }
```
**Rollback:** if the recreated object is wrong, delete it (`Remove-ADObject`) — no data loss on the AD DS side either way, since this object only ever held a reference, never a password.
</details>

<details><summary>Playbook 2 — Remove an AD LDS instance cleanly</summary>

Removing an instance is **not** the same as removing the AD LDS role/feature — an instance is its own uninstallable unit that shows up separately in Programs and Features (as "AD LDS Instance `<instanceName>`" alongside the base "Active Directory Lightweight Directory Services" feature entry).

1. Confirm no application still depends on the instance, and confirm whether it's part of a configuration set (removing one replica of a set is very different from removing a standalone instance — coordinate with any remaining replicas' owners first).
2. If it's the last/only replica, back up the instance's data directory before removal — there is no supported "undo" once an instance is uninstalled.
3. Uninstall the specific instance via Programs and Features (or its unattended-uninstall equivalent) — this removes the `ADAM_<name>` service, its data files, and its registration, without touching the base AD LDS role/feature or any other instance on the box.
4. If this was the last instance on the server and the AD LDS role itself is no longer needed:
   ```powershell
   Uninstall-WindowsFeature ADLDS
   ```

**Rollback:** restore the pre-removal data-directory backup and recreate the instance pointing at it only if you have a documented, tested procedure for doing so — in the general case, treat instance removal as destructive and irreversible without a backup taken beforehand.
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects AD LDS instance, replication, and (optional) bind-redirection
    evidence for escalation. Read-only.
#>
$instances = Get-Service "ADAM_*" | Select-Object Name, Status, StartType
$instances | Format-Table -AutoSize

dsdbutil "list instances" q q

foreach ($svc in $instances) {
    $name = $svc.Name -replace '^ADAM_',''
    Write-Host "=== Instance: $name ===" -ForegroundColor Cyan
    try {
        Get-EventLog -LogName "AD LDS ($name)" -Newest 20 -EntryType Error, Warning |
            Select-Object TimeGenerated, EntryType, EventID, Message |
            Format-Table -AutoSize -Wrap
    } catch {
        Write-Host "  (no dedicated event log found for $name, or inaccessible)" -ForegroundColor Yellow
    }
}
```
Attach this output, plus: instance name and port(s) involved, the exact application-side connection string/bind DN in use, and — if bind-redirection is involved — the target AD DS account's `LockedOut`/`Enabled`/`PasswordExpired` status pulled separately from the real domain.

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-Service "ADAM_*"` | List all AD LDS instance services on this box and their status |
| `dsdbutil "list instances" q q` | Authoritative list of instances + ports on a box (works even without AD DS role present) |
| `Get-ADRootDSE -Server "host:port"` | Confirm an instance is bindable and see its partitions |
| `Get-ADObject -Server "host:port" -Filter ...` | Query objects inside an AD LDS instance |
| `New-ADObject -Server "host:port" -Type userProxy ...` | Create a bind-redirection proxy object |
| `repadmin /showrepl host:port` | Replication status for an instance that's part of a configuration set |
| `repadmin /replsummary host:port` | Condensed replication health summary |
| `adamsync /f <config.xml> host:port` | Run a one-way AD DS → AD LDS sync |
| `netstat -ano \| findstr <port>` | Confirm what's actually listening on an instance's port |
| `Test-NetConnection -ComputerName <host> -Port <port>` | Basic reachability check to an instance or a DC (for proxy auth) |
| `Uninstall-WindowsFeature ADLDS` | Remove the AD LDS role/feature itself (only after all instances are individually removed) |

---
## 🎓 Learning Pointers

- AD LDS and AD DS are **the same underlying directory engine** running in two different modes — that's why the tooling (`repadmin`, the `ActiveDirectory` PowerShell module, `ADSI Edit`) is shared, but it also means assumptions from AD DS troubleshooting (single well-known port, one schema per forest, site-aware replication) don't transfer directly and have to be re-checked per instance. See [What Is AD LDS — Microsoft Learn](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/adam/what-is-active-directory-lightweight-directory-services).
- The **bind-redirection (`userProxy`) model** is the integration pattern that matters most in practice — it lets an application speak plain LDAP to AD LDS while the real password policy, lockout, and account lifecycle stay entirely inside AD DS. Most "AD LDS auth broken" tickets are actually AD DS account-state or network-reachability tickets wearing an AD LDS costume.
- A configuration set's replication is **not** the same topology-management system as AD DS's site/KCC model — there's no automatic link generation across a whole forest here, just whatever replication agreements were explicitly configured between the specific replicas in that set.
- The near-simultaneous service-account-change-breaks-replication behavior is easy to hit by accident during routine service-account credential rotation — sequence AD LDS replica service-account changes one at a time, with a replication-convergence check between each.
- ADAMSync's one-way, incremental, USN-watermark design means a "full resync" isn't its normal operating mode — treat forcing one as an occasional recovery action, not routine maintenance, especially against a large AD DS source OU.
- Removing an AD LDS **instance** and removing the AD LDS **role/feature** are two different, independently-scoped actions — always confirm which one is actually being requested before proceeding, since removing the wrong one either leaves orphaned instances behind or fails outright because instances still exist.
