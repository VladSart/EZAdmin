# Microsoft Entra Domain Services (Entra DS) — Reference Runbook (Mode A: Deep Dive)
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
- Microsoft Entra Domain Services (Entra DS) — the Microsoft-managed, highly-available pair of domain
  controllers providing classic AD DS protocols (NTLM, Kerberos, LDAP/LDAPS, Group Policy) against a
  domain synced one-way from Entra ID
- Password hash synchronization behavior into Entra DS, both cloud-only and hybrid (via Entra Connect)
- The flat `AADDC Users` / `AADDC Computers` OU architecture and its post-sync customization model
- Networking dependencies: dedicated VNet/subnet, VNet peering, DNS, NSG requirements
- Secure LDAP (LDAPS) certificate lifecycle
- Resource forest vs. user forest configuration types

**Out of scope:**
- On-premises Active Directory Domain Services (classic AD DS) — see general Windows Server AD docs,
  not covered in this repo
- Entra Connect / hybrid identity sync mechanics beyond what feeds Entra DS's password hash — see
  `EntraID/Troubleshooting/HybridJoin-B.md` and related Entra Connect content for sync engine internals
- Entra join / Hybrid Entra join of Windows 10/11 endpoints — that is a completely separate join type
  from a domain-joined VM against Entra DS (see [How It Works](#how-it-works) for why these are
  frequently confused)
- Azure Files identity-based authentication specifics — see `Azure/Files/_AGENT.md`, which depends on
  Entra DS or on-prem AD but has its own troubleshooting surface

**Assumptions:**
- Engineer has Azure RBAC access sufficient to read the Entra DS resource (`Az.ADDomainServices` module
  or Azure portal Reader+ on the resource group)
- At least one domain-joined VM (classic AD DS join, not Entra join) exists for network-path testing
- RSAT (`Get-ADUser`, `Get-ADGroupMember`, etc.) is available on a domain-joined VM for directory-level
  checks against the managed domain

---

## How It Works

<details><summary>Full architecture</summary>

Entra Domain Services solves a specific, narrow problem: legacy applications and lift-and-shift IaaS
workloads that need NTLM, Kerberos, LDAP, or Group Policy — protocols Entra ID (a modern OIDC/SAML/OAuth
identity provider) does not speak — but where standing up and patching real domain controllers isn't
wanted. Microsoft deploys and fully manages two domain controllers (a "replica set") per enabled region,
and keeps that managed domain's directory in sync with Entra ID.

**The critical architectural fact that drives almost every support ticket:** Entra DS is a **one-way,
downstream projection** of Entra ID. Nothing written into the managed domain flows back upstream, and
nothing in the managed domain is authoritative for identity — Entra ID is always the source of truth.
This is the opposite mental model from a traditional multi-DC on-prem AD forest, where any DC can
originate a change. Engineers with a strong on-prem AD background are the most likely to assume Entra DS
behaves like a peer DC and get tripped up by its one-way nature.

```
                         ┌─────────────────────────────┐
                         │   Microsoft Entra ID (cloud) │   ← always the source of truth
                         │   users / groups / passwords │
                         └───────────────┬─────────────┘
                                         │  one-way sync
                                         │  (password hash only syncs on
                                         │   change AFTER Entra DS enabled,
                                         │   or via Entra Connect PHS)
                                         ▼
                         ┌─────────────────────────────┐
                         │   Entra Domain Services      │
                         │   (Microsoft-managed)        │
                         │                              │
                         │  OU=AADDC Users               │
                         │  OU=AADDC Computers            │  ← permanently flat;
                         │  (flat containers, no          │     no nested OU import
                         │   inbound custom OU sync)       │     from Entra ID
                         │                              │
                         │  Replica Set (2x managed DC)  │
                         │  — one per enabled region     │
                         └───────────────┬─────────────┘
                                         │ NTLM / Kerberos / LDAP(S) / GPO
                                         │ over VNet peering + DNS
                                         ▼
                         ┌─────────────────────────────┐
                         │  Domain-joined VM (classic    │
                         │  AD DS join — NOT Entra join) │
                         └─────────────────────────────┘
```

**Why password hash sync is the #1 point of confusion:** Entra ID stores password hashes in a form
usable for modern (OIDC/SAML) auth, but NTLM and Kerberos require a different hash format (NT hash /
Kerberos long-term keys). Entra ID only computes and forwards this NTLM-compatible hash to Entra DS
**at the moment a password is set or changed**, and only for accounts created or changed *after* Entra DS
was enabled on the tenant. There is no bulk backfill. This means:
- A cloud-only user that existed before Entra DS was turned on will not be able to authenticate against
  the managed domain until they change or reset their password at least once.
- A hybrid user synced from on-prem AD via Entra Connect needs Password Hash Synchronization (PHS)
  enabled and healthy in Entra Connect — Pass-through Authentication (PTA) or Federation alone do **not**
  populate the hash Entra DS needs, since Entra ID itself never sees the actual password hash in a PTA
  or federated model.

**Why OU structure is permanently flat:** Entra ID has no native concept of the OU hierarchy that
on-prem AD uses for GPO scoping and delegation. Entra DS's sync engine therefore drops every synced user
and computer into two flat containers — `AADDC Users` and `AADDC Computers` — with no way to recreate an
on-prem OU tree via sync. Customers can create additional OUs **inside** Entra DS after the initial sync
and manually move objects into them for GPO scoping purposes, but this structure lives only in Entra DS,
is not fed by any Entra ID attribute, and does not sync back or get recreated if the managed domain is
ever rebuilt.

**Why this is a "resource forest" pattern architecturally:** Most Entra DS deployments follow a resource
forest model — the managed domain exists purely to host IaaS/legacy workloads and does not need to trust
or be trusted by an on-prem forest unless a customer explicitly sets up a one-way trust from Entra DS to
an on-prem forest (supported, but a distinct configuration step, not automatic).

</details>

---

## Dependency Stack

```
Entra ID tenant (source of truth: users, groups, password changes)
└── Entra DS enabled on the tenant + a dedicated /24 (or larger) VNet subnet
    └── Password hash projection
        ├── Cloud-only accounts: hash forwarded on next password set/change AFTER Entra DS enabled
        └── Hybrid accounts: Entra Connect configured with Password Hash Sync (PHS) — PTA/Federation
            alone do not supply a usable hash
            └── Managed domain replica set (2x Microsoft-managed DCs per enabled region)
                ├── Flat sync targets: OU=AADDC Users, OU=AADDC Computers (no nested OU import)
                ├── NSG on the dedicated Entra DS subnet allowing the
                │   AzureActiveDirectoryDomainServices service tag (mgmt plane — do not remove)
                └── Secure LDAP (optional): customer-uploaded PFX certificate, does not auto-renew
                    └── VNet peering from workload VNet(s) to the Entra DS VNet
                        (must be reciprocal — PeeringSyncLevel FullyInSync on BOTH sides)
                        └── DNS: workload VNet's DNS servers set to the Entra DS replica set IPs
                            (configured at the VNet level, not per-VM)
                            └── Domain-joined VM (classic AD DS join, NOT Entra join)
                                └── NTLM / Kerberos / LDAP(S) / Group Policy processing
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Every user/VM affected, domain-wide auth failures | Managed domain unhealthy or replica set alerting | `Get-AzADDomainService` health status / Azure portal Health blade |
| One specific (usually newly-migrated cloud-only) user can't authenticate | Password hash never synced — account predates Entra DS enable, no password change since | Force password change; confirm via `Get-ADUser` that the object exists but recall hash sync is invisible from the object itself |
| Hybrid users can't authenticate but cloud-only users can (or vice versa) | Entra Connect Password Hash Sync not enabled/healthy for hybrid, vs. cloud-only pwd-change gap | Check Entra Connect Health PHS status |
| Custom OU/GPO structure "disappeared" or "never applied" after a rebuild | Entra DS's OU customization is local to the managed domain and not preserved across a domain recreation | Confirm with client this is expected; document flat-sync architecture |
| Nested group membership behaves differently than on-prem | Entra DS token-building only supports certain nesting depths; not a 1:1 on-prem AD group engine | `Get-ADGroupMember` against the managed domain to confirm actual landed membership |
| LDAPS bind fails / certificate warning | Certificate expired, wrong NSG rule, or client doesn't trust the issuing CA | `LdapsSettings` on the resource; NSG on port 636; client trust store |
| VM can't domain-join or resolve the managed domain name at all | VNet peering one-sided, or DNS not pointed at Entra DS replica IPs | `Get-AzVirtualNetworkPeering` (check both sides); VNet `DhcpOptions` |
| Everything looks fine from workload VNet, but domain join still fails | Peering shows Connected on workload side only — Entra DS side not reciprocated | Check `PeeringSyncLevel` from the Entra DS VNet's own peering object, not just the workload side |
| Group Policy not applying as expected inside Entra DS | GPOs must be authored fresh inside the managed domain (via a domain-joined admin VM) — nothing imports from on-prem GPOs | Confirm GPO objects exist inside Entra DS itself via GPMC from a domain-joined VM |
| Security or NSG audit flags the Entra DS subnet's inbound rules as "unused" | `AzureActiveDirectoryDomainServices` service tag rules are structural management-plane traffic, not workload traffic | Confirm rule source/tag before removing; removing breaks the managed domain's own control plane |

---

## Validation Steps

**Step 1 — Confirm the managed domain resource itself is healthy**
```powershell
Get-AzADDomainService -ResourceGroupName "<rg>" -Name "<domainName>" |
    Select-Object DomainName, DomainConfigurationType, DeploymentId, ReplicaSets
```
Good: No active health alerts surfaced in the Azure portal's Health blade for the resource; `ReplicaSets`
shows expected regions with `ServiceStatus = Running`.
Bad: Any alert (DNS records missing, NSG blocking required traffic, replica set unhealthy) — this affects
every downstream consumer equally, so resolve here first before chasing a single-user or single-VM theory.

**Step 2 — Confirm password hash sync mechanism for the affected account**
```powershell
Get-MgUser -UserId "<user@domain.com>" -Property OnPremisesSyncEnabled,OnPremisesLastSyncDateTime |
    Select-Object DisplayName, OnPremisesSyncEnabled, OnPremisesLastSyncDateTime
```
Good: For hybrid accounts, a recent `OnPremisesLastSyncDateTime` and Entra Connect Health showing PHS
enabled and healthy (checked separately in Entra Connect Health, not exposed via this cmdlet). For
cloud-only accounts, confirm whether the account has had a password set/changed since Entra DS was
enabled on the tenant — if not, this is expected behavior, not a bug.
Bad: Hybrid account with PHS disabled (using PTA/Federation only) — Entra DS will never receive a usable
hash for that account without enabling PHS as a co-existing sync method.

**Step 3 — Confirm the object landed in Entra DS's synced OU structure**
```powershell
Get-ADUser -Filter "UserPrincipalName -eq '<user@domain.com>'" -Server <domainName> |
    Select-Object Name, DistinguishedName, Enabled
```
Good: Object present under `OU=AADDC Users,DC=<domain>,DC=<com>` (or `AADDC Computers` for device
objects), typically within 20 minutes of creation/change in Entra ID.
Bad: Object missing well beyond 20 minutes — a genuine sync delay worth escalating to Microsoft support,
since there is no customer-triggerable "force sync now" action for Entra DS.

**Step 4 — Confirm actual group membership as synced (not as designed in Entra ID)**
```powershell
Get-ADGroupMember -Identity "<groupName>" -Server <domainName>
```
Good: Membership matches expectations for the NTLM/Kerberos token-building use case (flat or single-level
nesting, as Entra DS supports).
Bad: Expected nested-group structure from Entra ID/on-prem AD doesn't appear — this is an architectural
limit of the sync engine, not a fault to troubleshoot further.

**Step 5 — Confirm network path from a workload VM to the managed domain**
```powershell
nltest /dsgetdc:<domainName>
Test-NetConnection -ComputerName <domainName> -Port 389
Test-NetConnection -ComputerName <domainName> -Port 636   # only if LDAPS is configured
```
Good: A domain controller is located; port 389 (and 636 if applicable) succeeds.
Bad: DC not located or port test fails — treat as a network/DNS/peering problem, not an identity problem;
proceed to Step 6.

**Step 6 — Confirm VNet peering and DNS are correctly and reciprocally configured**
```powershell
Get-AzVirtualNetworkPeering -ResourceGroupName "<rg>" -VirtualNetworkName "<workloadVnetName>" |
    Select-Object Name, PeeringState, PeeringSyncLevel
Get-AzVirtualNetworkPeering -ResourceGroupName "<rg>" -VirtualNetworkName "<entraDSVnetName>" |
    Select-Object Name, PeeringState, PeeringSyncLevel
Get-AzVirtualNetwork -ResourceGroupName "<rg>" -Name "<workloadVnetName>" |
    Select-Object -ExpandProperty DhcpOptions
```
Good: `PeeringState = Connected` and `PeeringSyncLevel = FullyInSync` on **both** the workload VNet's and
the Entra DS VNet's peering objects; workload VNet's `DhcpOptions.DnsServers` set to the Entra DS replica
set IPs.
Bad: Peering connected on only one side (common when the reciprocal peering link was never created from
the Entra DS VNet), or DNS still pointing at Azure-provided/on-prem DNS with no conditional forwarding to
Entra DS — both silently break domain join and name resolution while looking correct from the workload
side alone.

---

## Troubleshooting Steps (by phase)

### Phase 1: Domain-Wide Symptom (multiple users/VMs affected)
1. Check the managed domain's Health blade in the Azure portal / `Get-AzADDomainService` for active alerts
2. If a DNS-records-missing alert exists, confirm the Entra DS VNet's own DNS configuration (Microsoft
   manages this, but customer-side DNS forwarders can still interfere)
3. If an NSG alert exists, confirm the `AzureActiveDirectoryDomainServices` service tag rules are still
   present and unmodified on the Entra DS subnet's NSG — this is the most common accidental-removal cause
4. If replica set unhealthy persists beyond a few hours with no customer-side cause found, open a
   Microsoft support case — there is no customer-initiated repair action for the managed DCs

### Phase 2: Single-User Authentication Failure
1. Confirm the object exists in the synced OU (Validation Step 3)
2. Determine cloud-only vs. hybrid (Validation Step 2)
3. For cloud-only: force a password change — this is the action that actually triggers hash sync
4. For hybrid: confirm Entra Connect Password Hash Sync is enabled and healthy (Entra Connect Health,
   separate tool) — PTA/Federation-only configurations will never populate the hash Entra DS needs
5. Re-test authentication only after confirming the hash sync trigger has actually occurred (allow a few
   minutes for propagation)

### Phase 3: Group/OU Structure Mismatch
1. Compare the client's expectation (usually "why doesn't my on-prem-style OU tree show up") against the
   documented flat-sync architecture (Symptom → Cause Map)
2. If custom delegation is genuinely required, plan it as new OUs created **inside** Entra DS via a
   domain-joined admin VM — not as an Entra ID configuration change, since none exists for this
3. Document the flat architecture for the client to prevent repeat tickets on the same misunderstanding

### Phase 4: LDAPS Failure
1. Confirm certificate expiry via `LdapsSettings` on the resource
2. Confirm NSG allows inbound 636 from the intended client source (and that external/internet LDAPS
   access, if used, has the required public IP explicitly configured — most environments should restrict
   this to VNet-internal only)
3. Confirm the connecting client trusts the certificate's issuing CA (especially for internal/self-signed
   certs)

### Phase 5: Network/DNS/Peering Failure
1. Run Validation Steps 5 and 6 in order — network path first, then peering/DNS configuration
2. Pay specific attention to `PeeringSyncLevel` on **both** sides — a one-sided peering is the single most
   common root cause of "worked yesterday, broken today" domain-join/DNS tickets in Entra DS environments
3. Confirm DNS is set at the VNet level (`DhcpOptions`), not attempted per-VM, since per-VM static DNS
   configuration is fragile and not the supported pattern

---

## Remediation Playbooks

<details><summary>Playbook 1 — Force password hash sync for a cloud-only user</summary>

```powershell
# This does not "sync" a hash directly — it triggers the actual event (a password change)
# that causes Entra ID to compute and forward an NTLM-compatible hash to Entra DS.
Update-MgUserPassword -UserId "<user@domain.com>" -PasswordProfile @{ ForceChangePasswordNextSignIn = $true }
```

Communicate to the user before forcing this, since it requires them to set a new password at next
sign-in. There is no admin-side "push the existing hash" action — the hash Entra ID holds for
OIDC/SAML-style auth is not the same format NTLM/Kerberos require, so a genuine password-set event must
occur after Entra DS was enabled.

**Rollback:** N/A — not a destructive action, just a user-facing inconvenience if not communicated.

</details>

<details><summary>Playbook 2 — Repair one-sided VNet peering</summary>

```powershell
# Identify the missing reciprocal peering (usually the Entra DS VNet side)
Get-AzVirtualNetworkPeering -ResourceGroupName "<rg>" -VirtualNetworkName "<entraDSVnetName>"

# Create the missing reciprocal peering link if absent
Add-AzVirtualNetworkPeering `
    -Name "<peeringName>" `
    -VirtualNetwork (Get-AzVirtualNetwork -ResourceGroupName "<rg>" -Name "<entraDSVnetName>") `
    -RemoteVirtualNetworkId (Get-AzVirtualNetwork -ResourceGroupName "<rg>" -Name "<workloadVnetName>").Id
```

**Rollback:** N/A — creating the missing reciprocal peering is additive; it does not remove or alter the
existing one-sided link.

</details>

<details><summary>Playbook 3 — Rotate an expiring/expired LDAPS certificate</summary>

```powershell
# Confirm current cert details first
Get-AzADDomainService -ResourceGroupName "<rg>" -Name "<domainName>" |
    Select-Object -ExpandProperty LdapsSettings

# Upload the new PFX (password-protected) via the Azure portal:
# Entra Domain Services > <domain> > Secure LDAP > upload new certificate + private key
```

There is no PowerShell cmdlet to upload the LDAPS PFX directly as of this writing — the supported path is
the Azure portal's Secure LDAP blade. Track certificate expiry proactively (e.g., via a scheduled script
against `LdapsSettings.CertificateExpiryDate` if exposed by your module version, or portal reminders)
since Entra DS does not send a service-side renewal reminder.

**Rollback:** Re-upload the previous valid PFX if the new certificate was misconfigured and caused an
outage; keep the prior certificate archived until the new one is confirmed working end-to-end.

</details>

<details><summary>Playbook 4 — Rebuild expectations after a full Entra DS redeploy (disable/re-enable)</summary>

If a managed domain is ever disabled and a new one enabled (a full redeploy, not a routine operation),
treat this as **starting over architecturally**:
- All custom OUs/GPOs created inside the previous managed domain are gone — they must be recreated
- All cloud-only accounts will again need a password change post-redeploy to repopulate NTLM hashes,
  even if they had already changed their password under the old deployment
- LDAPS certificates must be re-uploaded
- VNet peering and DNS must be reconfigured pointing at the new replica set IPs

**Rollback:** N/A — this is a rebuild, not a reversible operation; plan and communicate scope to the
client before initiating.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects a full Entra Domain Services evidence pack for escalation or handoff.
.NOTES
    Read-only. Requires Az.ADDomainServices and Microsoft.Graph.Users modules connected
    (Connect-AzAccount / Connect-MgGraph) plus RSAT/AD cmdlets if run from a domain-joined VM.
#>
param(
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [string]$DomainServiceName,
    [string]$WorkloadVNetName,
    [string]$EntraDSVNetName,
    [string]$AffectedUserUpn
)

$out = "$env:TEMP\EntraDS-Evidence-$(Get-Date -Format yyyyMMdd-HHmmss).txt"

"=== ENTRA DOMAIN SERVICES EVIDENCE PACK ===" | Out-File $out
"Collected: $(Get-Date)" | Out-File $out -Append

"--- Managed Domain Resource ---" | Out-File $out -Append
Get-AzADDomainService -ResourceGroupName $ResourceGroupName -Name $DomainServiceName |
    Format-List | Out-File $out -Append

if ($WorkloadVNetName) {
    "--- Workload VNet Peering ---" | Out-File $out -Append
    Get-AzVirtualNetworkPeering -ResourceGroupName $ResourceGroupName -VirtualNetworkName $WorkloadVNetName |
        Select-Object Name, PeeringState, PeeringSyncLevel | Format-Table | Out-File $out -Append

    "--- Workload VNet DNS Configuration ---" | Out-File $out -Append
    Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $WorkloadVNetName |
        Select-Object -ExpandProperty DhcpOptions | Out-File $out -Append
}

if ($EntraDSVNetName) {
    "--- Entra DS VNet Peering (check reciprocal state) ---" | Out-File $out -Append
    Get-AzVirtualNetworkPeering -ResourceGroupName $ResourceGroupName -VirtualNetworkName $EntraDSVNetName |
        Select-Object Name, PeeringState, PeeringSyncLevel | Format-Table | Out-File $out -Append
}

if ($AffectedUserUpn) {
    "--- Affected User Sync State ---" | Out-File $out -Append
    Get-MgUser -UserId $AffectedUserUpn -Property OnPremisesSyncEnabled,OnPremisesLastSyncDateTime |
        Select-Object DisplayName, OnPremisesSyncEnabled, OnPremisesLastSyncDateTime |
        Format-List | Out-File $out -Append
}

"--- Instructions: if run from a domain-joined VM, also capture ---" | Out-File $out -Append
"    nltest /dsgetdc:<domainName>" | Out-File $out -Append
"    Test-NetConnection -ComputerName <domainName> -Port 389" | Out-File $out -Append
"    Test-NetConnection -ComputerName <domainName> -Port 636" | Out-File $out -Append
"    Get-ADUser -Filter `"UserPrincipalName -eq '<upn>'`" -Server <domainName>" | Out-File $out -Append

Write-Host "Evidence written to: $out"
```

---

## Command Cheat Sheet

| Task | Command |
|---|---|
| Get managed domain status | `Get-AzADDomainService -ResourceGroupName <rg> -Name <domainName>` |
| Check replica set health | `(Get-AzADDomainService ...).ReplicaSets` |
| Check LDAPS certificate settings | `(Get-AzADDomainService ...).LdapsSettings` |
| Check hybrid user's on-prem sync state | `Get-MgUser -UserId <upn> -Property OnPremisesSyncEnabled,OnPremisesLastSyncDateTime` |
| Force cloud-only user password change (triggers hash sync) | `Update-MgUserPassword -UserId <upn> -PasswordProfile @{ForceChangePasswordNextSignIn=$true}` |
| Confirm object synced into Entra DS | `Get-ADUser -Filter "UserPrincipalName -eq '<upn>'" -Server <domainName>` |
| Confirm group membership as landed | `Get-ADGroupMember -Identity <groupName> -Server <domainName>` |
| Locate a DC for the managed domain | `nltest /dsgetdc:<domainName>` |
| Test LDAP connectivity | `Test-NetConnection -ComputerName <domainName> -Port 389` |
| Test LDAPS connectivity | `Test-NetConnection -ComputerName <domainName> -Port 636` |
| Check VNet peering state (both sides!) | `Get-AzVirtualNetworkPeering -ResourceGroupName <rg> -VirtualNetworkName <vnet>` |
| Check workload VNet DNS servers | `(Get-AzVirtualNetwork -ResourceGroupName <rg> -Name <vnet>).DhcpOptions` |
| Check NSG rules on the Entra DS subnet | `Get-AzNetworkSecurityGroup -ResourceGroupName <rg> -Name <nsg> \| Get-AzNetworkSecurityRuleConfig` |

---

## 🎓 Learning Pointers

- **Entra DS is one-way and never authoritative.** Every identity/password/group fact must originate in
  Entra ID (or on-prem AD via Entra Connect) and sync down; there is no write-back path from the managed
  domain to Entra ID, aside from post-sync OU/GPO customization living purely inside Entra DS itself.
  [MS Docs: Microsoft Entra Domain Services overview](https://learn.microsoft.com/en-us/entra/identity/domain-services/overview)
- **Password hash sync is event-triggered, not a bulk backfill.** Enabling Entra DS does not retroactively
  populate NTLM/Kerberos-compatible hashes for existing accounts — only a password change *after*
  enablement does. This single fact resolves the majority of "new managed domain, can't log into the
  domain-joined VM" tickets. [MS Docs: Password hash synchronization to Entra Domain Services](https://learn.microsoft.com/en-us/entra/identity/domain-services/tutorial-configure-networking)
- **The flat `AADDC Users`/`AADDC Computers` OU model is architectural, not a limitation to work around.**
  Set client expectations early that on-prem-style OU/GPO delegation must be rebuilt fresh inside Entra DS,
  not imported.
- **VNet peering for Entra DS must be reciprocal.** Always check `PeeringSyncLevel` from both the workload
  VNet's and the Entra DS VNet's own peering objects — a connection that looks fine from one side only is
  one of the most common silent-failure patterns in this domain. [MS Docs: Network considerations for Microsoft Entra Domain Services](https://learn.microsoft.com/en-us/entra/identity/domain-services/network-considerations)
- **NSG rules tagged `AzureActiveDirectoryDomainServices` are management-plane, not workload traffic.**
  They're frequently mistaken for unused legacy rules during a security review — removing them breaks the
  managed domain's own control plane, not customer application traffic.
- **LDAPS certificates do not auto-renew.** There is no service-side reminder — track expiry proactively,
  since an expired cert silently breaks every LDAPS-dependent application at once.
