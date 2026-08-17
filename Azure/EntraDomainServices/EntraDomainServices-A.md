# Microsoft Entra Domain Services (AADDS) — Reference Runbook (Mode A: Deep Dive)
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
- Microsoft Entra Domain Services (formerly Azure AD Domain Services / AADDS) architecture: the managed-domain model, replica sets, and the platform-owned domain controller pair
- One-way synchronization from Microsoft Entra ID (and, transitively, from on-premises AD DS via Microsoft Entra Connect) into the managed domain — object/attribute/credential mapping, scoped synchronization and group filtering
- Networking requirements: dedicated subnet, platform-managed NSG, required inbound/outbound rules and service tags, DNS behavior, VNet peering vs. VPN gateway connectivity models
- Authentication model: NTLM/Kerberos/LDAP(S) against synced credentials, password hash prerequisites (including the federation/PHS hard dependency), local password/lockout policy on the managed domain
- Administration model: *Microsoft Entra DC Administrators* group, management VM pattern, custom OU creation, DNS administration, forest trust to on-premises AD DS
- Common enablement and sign-in failure modes, with root-cause mapping back to sync state, network configuration, or account eligibility

**Out of scope:**
- On-premises AD DS domain controller deployment, replication topology, FSMO roles, and Group Policy authoring — Domain Services provides *managed* DCs; it does not extend or replace an on-premises AD DS forest. See `ActiveDirectory/Troubleshooting/Replication/AD-Replication-A.md` for the on-prem side.
- AD LDS (Lightweight Directory Services) — a completely different, standalone, non-domain LDAP role with no relationship to Domain Services beyond sharing the word "directory." See `ActiveDirectory/Troubleshooting/ADLDS/ADLDS-A.md`.
- Microsoft Entra Connect deployment and configuration itself, beyond the specific settings (password hash sync) that gate Domain Services functionality. See `EntraID/Troubleshooting/Connect-Sync-A.md`.
- Azure VMs running AD DS themselves ("AD DS on Azure IaaS") — an entirely different, self-managed deployment pattern that Domain Services is explicitly positioned as an alternative to.
- Azure AD B2C / external tenants — Domain Services is a feature of a standard Microsoft Entra ID (workforce) tenant only.

**Assumptions:**
- A Microsoft Entra Domain Services managed domain has already been enabled for the tenant, or enablement is the specific task at hand
- Diagnostic access: Owner/Contributor on the resource group hosting Domain Services, Global Administrator or Domain Services Contributor in Entra ID, and — for in-domain checks — membership in *Microsoft Entra DC Administrators* plus a management VM domain-joined to the managed domain with RSAT AD tools installed
- Microsoft Graph PowerShell SDK and Az PowerShell modules available for tenant-side and control-plane checks respectively

---
## How It Works

<details><summary>Full architecture</summary>

Microsoft Entra Domain Services provisions a **managed domain** — a namespace you choose at enablement time (e.g. `dscontoso.com`) — backed by two Windows Server domain controllers that Microsoft fully owns and operates as a **replica set**. You never see, patch, back up, or connect to these DCs directly; all of that is handled by the platform. In regions with Azure Availability Zone support, the two DCs are zone-distributed; elsewhere they use Availability Sets. You can add additional **replica sets** in other (peered) regions for geographic disaster recovery — all replica sets share the same namespace and configuration.

The managed domain is a **stand-alone domain**. It is not an extension of your on-premises AD DS forest and does not appear as a child or trusted domain automatically — if you need cross-authentication with on-premises AD DS, you configure an explicit one-way or two-way **forest trust** (Domain Services supports forest trusts only, not external/domain-level trusts, and does not support trusting on-premises *child* domains directly).

**The single most important mental model:** Domain Services is populated by a **one-way, automatic, continuous background synchronization from Microsoft Entra ID** — never the reverse. In a hybrid environment, the real chain is:

```
On-premises AD DS  →  Microsoft Entra Connect  →  Microsoft Entra ID  →  (one-way sync)  →  Managed domain
```

Microsoft Entra ID is always the intermediate source of authority. Domain Services never talks to your on-premises AD DS directly, and Microsoft Entra Connect must never be installed inside the managed domain to sync it back to Entra ID — that configuration is explicitly unsupported.

**Credentials are the hard part.** Microsoft Entra ID does not store cleartext passwords, so NTLM/Kerberos-compatible legacy password hashes have to be deliberately generated and stored (encrypted, per-tenant-keyed, decryptable only by the Domain Services backend) for every user who needs to authenticate against the managed domain:
- **Cloud-only users:** the hash is generated only when the user changes their password *after* Domain Services has been enabled. A brand-new cloud user, or one who hasn't changed their password since enablement, has no hash yet — full stop.
- **Hybrid users:** Microsoft Entra Connect must be configured to synchronize NTLM/Kerberos-compatible password hashes (this is bundled into standard Password Hash Synchronization).
- **Federated tenants without PHS enabled as well:** Domain Services **cannot function at all** for any user, because no password hashes ever reach Entra ID to synchronize onward. This is a hard architectural blocker, not a per-user issue.
- **Guest/B2B/external accounts:** never have credentials in the tenant to synchronize, and can never sign in to the managed domain.

Once synchronized, the managed domain evaluates authentication **entirely locally** — password expiry (default 90-day lifetime, independent of and not synchronized with the Entra ID password policy), account lockout (5 bad attempts in 2 minutes → 30-minute lockout, visible only inside the managed domain), and the KRBTGT account (rolled automatically every 7 days) are all managed-domain-local concerns with no Entra ID equivalent view.

</details>

---
## Dependency Stack

```
Layer 5 — Application / VM
    Domain-joined machine or app authenticating via NTLM, Kerberos, or LDAP(S)
    against the managed domain
        ▲ requires
Layer 4 — Managed domain (2 platform-owned DCs, one replica set per region)
    Local password policy (90-day default) · Local lockout policy (5/2min→30min)
    KRBTGT rotated every 7 days · Flat OU structure (AADDC Users/Computers +
    optional custom OUs) · Optional forest trust to on-prem AD DS
        ▲ requires
Layer 3 — One-way background synchronization (Entra ID → managed domain, automatic)
    Users, groups, credential hashes · Attribute mapping (UPN, SAMAccountName from
    mailNickname, SidHistory from on-prem primary SID) · Optional scoped sync /
    group filtering
        ▲ requires
Layer 2 — Password hash availability in Microsoft Entra ID
    Cloud-only: generated on password change AFTER Domain Services enablement
    Hybrid: Microsoft Entra Connect configured for NTLM/Kerberos hash sync
    Federated WITHOUT PHS: hard blocker — no hashes ever exist to sync
        ▲ requires
Layer 1 — Azure networking substrate
    Dedicated subnet (3-5 IPs, no custom DNS) · Platform-managed NSG (inbound:
    WinRM 5986 required, RDP 3389 optional/CorpNetSaw-only; outbound: 443 to
    AAD-DS/Monitor/Storage/AAD/GuestAndHybridManagement service tags; internal
    replica-set ports 135/389/445/636/3268/3269/53/88) · Platform-managed load
    balancer, public IP, NAT rules
        ▲ requires
Layer 0 — Microsoft Entra ID tenant
    Source of authority for all users, groups, and (indirectly) credentials
```

A failure at any layer masks everything above it — always validate top-down from Layer 0 rather than starting your diagnosis at the application.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Domain Services enablement fails: "the name X is already in use on this network" | An existing AD DS environment on Azure VMs already responds on that domain name within the same/peered VNet | DNS lookup for the proposed name on the target VNet before retrying |
| Enablement fails citing a named application (Sync app or `d87dcbc6-a371-462e-88e3-28ad15ec4e64`) | Stale app registration/service principal from a prior failed or deleted Domain Services deployment | `Get-MgServicePrincipal -Filter "AppId eq '...'"` |
| Enablement fails citing Microsoft Graph app (`00000002-0000-0000-c000-000000000000`) disabled | Someone disabled sign-in on the Microsoft Graph enterprise app tenant-wide | Enterprise Applications > search AppId > `Enabled for users to sign-in` |
| No users can authenticate against the managed domain at all, tenant-wide | Federated tenant without Password Hash Synchronization enabled — hard architectural blocker | `Get-MgOrganization` federation config + Entra Connect Optional Features |
| One specific new user can't domain-join a VM | Cloud-only account has never changed its password since Domain Services was enabled — no hash generated yet | `Get-ADUser -Server <fqdn> -Properties PasswordLastSet` |
| A specific hybrid user can't authenticate, others are fine | Microsoft Entra Connect not configured for NTLM/Kerberos hash sync, or sync hasn't completed for that OU/scope | Entra Connect sync rules + `Start-ADSyncSyncCycle -PolicyType Initial` |
| A guest/B2B user can never sign in, no matter what | External accounts have no stored credentials in the tenant — architecturally impossible, not a bug | `Get-MgUser -Property UserType` returns `Guest` |
| User authenticates with UPN but not `DOMAIN\username` | `SAMAccountName` autogenerated due to `mailNickname` collision or >20-char UPN prefix | `Get-ADUser -Properties SamAccountName` vs. expected value |
| Account "locked out" per the help desk, but Entra ID shows no risk/lockout signal | Lockout is 100% local to the managed domain (5 attempts/2 min → 30 min) — Entra ID has no visibility into it | `Get-ADUser -Server <fqdn> -Properties LockedOut` |
| User's password "still works" in Entra ID/M365 but is rejected on domain-joined resources | Managed domain's local 90-day password lifetime expired independently of the Entra ID password policy | Compare `PasswordLastSet` against the managed domain's configured max age |
| User regained Entra ID access after being restored from the recycle bin, but lost access to files/shares they used to have | Restored users get a brand-new GUID/SID in the managed domain — old ACLs reference a SID that no longer exists | `Get-ADUser -Properties SID` vs. the SID baked into the resource's ACL |
| Custom OU objects are missing from Microsoft Graph / the Entra admin center | Working as designed — objects created directly inside the managed domain's custom OUs are never synchronized back to Entra ID | Confirm object exists via `Get-ADObject -SearchBase <customOU> -Server <fqdn>` |
| Group Policy or SYSVOL content from on-premises AD DS is missing in the managed domain | Working as designed — GPOs and SYSVOL contents are never synchronized; the managed domain's own GPOs must be authored independently | N/A — expected behavior, not a defect |
| DFS namespaces/replication configured on-prem don't appear/function in the managed domain | Working as designed — DFS and DFSR are not available in a managed domain at all | N/A — expected behavior |
| Replication or management functions intermittently fail after a network change | Custom NSG rule added/removed on the managed domain's subnet, or a user-defined route altered the `0.0.0.0/0` route | `Get-AzNetworkSecurityGroup` rule diff against platform baseline; `Get-AzRouteTable` |
| Sync appears "stuck" for a large initial deployment | Expected — initial sync can take hours to a couple of days depending on tenant object count | Re-check after allowing sufficient time; no action needed unless days pass with zero progress |
| Domain controller name referenced in an app's connection string stopped resolving | DC names can change during platform maintenance — hardcoded DC names are unsupported | Reconfigure the app to use the managed domain FQDN, never a specific DC hostname |

---
## Validation Steps

1. **Confirm the managed domain's control-plane health.**
   ```powershell
   Get-AzADDomainService -Name "<domain>" -ResourceGroupName "<rg>"
   ```
   Good: provisioning state healthy, no active Health-blade alerts. Bad: any alert present — resolve it before validating anything downstream, since most per-user symptoms are noise underneath an active domain-level alert.

2. **Confirm tenant-wide credential-sync eligibility.**
   ```powershell
   Get-MgOrganization | Select-Object OnPremisesSyncEnabled
   ```
   Good: PHS enabled (cloud-only tenants have this implicitly; hybrid/federated tenants must confirm explicitly in Entra Connect). Bad: federated with PHS off — stop here, this blocks the entire feature, not one user.

3. **Confirm subnet/NSG posture matches the platform-managed baseline.**
   ```powershell
   Get-AzNetworkSecurityGroup -Name "<nsgName>" -ResourceGroupName "<rg>" | Select-Object -ExpandProperty SecurityRules
   ```
   Good: only the platform defaults plus `AzureActiveDirectoryDomainServices→5986` and (optionally) `CorpNetSaw→3389`. Bad: any additional custom rule, or a missing default rule — both are unsupported states.

4. **Confirm a representative user's object and credential state landed correctly.**
   ```powershell
   Get-ADUser -Filter "UserPrincipalName -eq '<upn>'" -Server "<fqdn>" -Properties PasswordLastSet,LockedOut,Enabled,SamAccountName,SID
   ```
   Good: object present, `PasswordLastSet` populated, not locked out. Bad: object missing (sync incomplete or credential never generated) or `PasswordLastSet` null (cloud-only user needs a password change).

5. **Confirm outbound connectivity for replication/management isn't silently blocked.**
   ```powershell
   Get-AzNetworkSecurityGroup -Name "<nsgName>" -ResourceGroupName "<rg>" |
     Select-Object -ExpandProperty SecurityRules | Where-Object { $_.Direction -eq "Outbound" }
   ```
   Good: `AllowVnetOutbound`/`AllowInternetOutBound` present, or explicit allow rules for the required service tags (443 to AzureActiveDirectoryDomainServices, AzureMonitor, Storage, AzureActiveDirectory, GuestAndHybridManagement). Bad: a higher-priority deny rule silently blocking any of these — breaks replica-set sync and patch delivery, not just one symptom.

6. **Confirm no unsupported route-table interference.**
   ```powershell
   Get-AzRouteTable -ResourceGroupName "<rg>" | Select-Object -ExpandProperty Routes
   ```
   Good: no user-defined route touching `0.0.0.0/0` for the Domain Services subnet. Bad: an altered default route — this is an unsupported state per Microsoft, and the Azure SLA explicitly excludes outages it causes.

7. **Confirm forest trust health, if one is configured.**
   ```powershell
   Get-ADTrust -Filter * -Server "<fqdn>"
   ```
   Good: trust status healthy/verified. Bad: broken trust — cross-forest authentication to/from on-premises AD DS will fail even though the managed domain itself is otherwise healthy.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Enablement failures**
Identify the exact error text from the enablement wizard/PowerShell and match it against the four documented failure signatures (domain name conflict, stale Sync app, stale `d87dcbc6-...` app, disabled Graph app). All four have exact, scripted remediations — resist the urge to troubleshoot generically; check the named-application state first.

**Phase 2 — Domain-wide authentication failure (affects all/most users)**
Start at Layer 0/2 of the dependency stack: confirm PHS is genuinely enabled and current, not just configured-but-stale. For federated tenants, confirm PHS is enabled *in addition to* federation — Domain Services needs the hash regardless of the tenant's primary sign-in method.

**Phase 3 — Single-user or single-group authentication failure**
Work top-down: confirm the user's `UserType` isn't `Guest`, confirm `OnPremisesSyncEnabled` to determine cloud-only vs. hybrid handling, confirm the object exists in the managed domain, confirm `PasswordLastSet` is populated, confirm lockout state locally (never trust Entra ID's view for this).

**Phase 4 — Resource-access failure despite successful authentication**
The user can authenticate but can't access a specific resource — check for a recent recycle-bin restore (new SID), a `SAMAccountName` mismatch in a script/app expecting the old format, or a custom OU object that's out of sync with a since-changed group membership scope.

**Phase 5 — Network/management-plane degradation**
Confirm NSG and route-table state against the platform baseline first — both are common self-inflicted causes that present as vague "management stopped working" or "replication seems behind" symptoms days after the actual change was made.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Onboarding a federated tenant for Domain Services (enable PHS as a backup auth method)</summary>

Federated tenants must have Password Hash Synchronization enabled **in addition to** federation for Domain Services to function — PHS acting purely as the credential-hash source for Domain Services, not as the tenant's primary sign-in method.

```powershell
# On the Microsoft Entra Connect server, enable PHS as an Optional Feature
# (Azure AD Connect wizard: Additional tasks > Customize synchronization options >
#  Optional features > check "Password hash synchronization")

# After enabling, force an initial sync cycle to backfill hashes for existing users
Start-ADSyncSyncCycle -PolicyType Initial

# Verify the tenant now reports PHS as enabled
Get-MgOrganization | Select-Object OnPremisesSyncEnabled
```

**Rollback note:** Disabling PHS after Domain Services is in production use will break authentication for every user going forward — do not disable without a planned cutover.

</details>

<details><summary>Playbook 2 — Configuring scoped synchronization to limit which users/groups reach the managed domain</summary>

By default, all users and groups synchronize to the managed domain. For tenants with a large or sensitive directory, scope synchronization to a specific set of groups (cloud-only, on-premises-sourced, or both).

```powershell
# Configured via the Entra admin center: Entra ID > Domain Services > <domain> >
# Scoped synchronization > select the security groups in scope
# There is no supported unattended PowerShell path for this configuration change —
# treat it as a portal-driven, change-controlled operation
```

**Rollback note:** Removing a group from scope removes its members' credentials from the managed domain on the next sync cycle — any resource relying on those accounts for domain-joined authentication will start failing. Communicate before narrowing scope on an already-live managed domain.

</details>

<details><summary>Playbook 3 — Configuring a fine-grained password policy to override the 90-day default</summary>

The managed domain's default 90-day password lifetime is independent of Entra ID's own policy and applies locally.

```powershell
# From a management VM domain-joined to the managed domain (RSAT AD module required)
New-ADFineGrainedPasswordPolicy -Name "CustomPasswordPolicy" `
  -Precedence 500 -MaxPasswordAge "60.00:00:00" -MinPasswordLength 12 `
  -LockoutThreshold 5 -LockoutDuration "00:30:00" -LockoutObservationWindow "00:02:00"

Add-ADFineGrainedPasswordPolicySubject -Identity "CustomPasswordPolicy" -Subjects "<GroupName>"
```

**Rollback note:** Removing the fine-grained policy (`Remove-ADFineGrainedPasswordPolicy`) reverts affected users to the domain default (90 days) on next evaluation — non-destructive, but plan for a brief window where policy is ambiguous mid-change.

</details>

<details><summary>Playbook 4 — Establishing a forest trust to on-premises AD DS</summary>

Use when legacy applications need cross-authentication between the managed domain and an existing on-premises AD DS forest, beyond what Entra ID sync alone provides.

```powershell
# High-level sequence (full detail: Microsoft Entra admin center > Domain Services >
# <domain> > Trusts):
# 1. Ensure network connectivity (VPN gateway or ExpressRoute) between the managed
#    domain's VNet and the on-premises network
# 2. Create the trust from the Entra admin center, specifying trust direction
#    (one-way incoming, one-way outgoing, or two-way) and the on-prem forest's DNS name
# 3. Validate from a management VM in the managed domain:
Get-ADTrust -Filter * -Server "<managedDomainFQDN>"
```

**Rollback note:** Removing a forest trust is non-destructive to either forest's own objects, but immediately breaks any cross-forest authentication depending on it — confirm no production workload relies on the trust before removing.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Microsoft Entra Domain Services health/config evidence for escalation to Microsoft support.
.NOTES
    Run from a machine with Az PowerShell + Microsoft Graph PowerShell authenticated,
    and (for the in-domain section) from a management VM domain-joined to the managed domain.
#>
param(
    [Parameter(Mandatory)] [string]$DomainServiceName,
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [string]$ManagedDomainFQDN
)

$evidence = [ordered]@{
    Timestamp        = Get-Date -Format "o"
    DomainService    = Get-AzADDomainService -Name $DomainServiceName -ResourceGroupName $ResourceGroupName
    Organization     = Get-MgOrganization | Select-Object Id, OnPremisesSyncEnabled, VerifiedDomains
    NsgRules         = (Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName |
                          Where-Object { $_.Subnets -match $DomainServiceName }).SecurityRules
}

if ($ManagedDomainFQDN) {
    $evidence.SampleUserCount = (Get-ADUser -Filter * -Server $ManagedDomainFQDN -ResultSetSize 5).Count
    $evidence.TrustState      = Get-ADTrust -Filter * -Server $ManagedDomainFQDN -ErrorAction SilentlyContinue
}

$evidence | ConvertTo-Json -Depth 6 | Out-File ".\AADDS-Evidence-$(Get-Date -Format yyyyMMdd-HHmmss).json"
Write-Host "Evidence pack written." -ForegroundColor Green
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-AzADDomainService -Name <n> -ResourceGroupName <rg>` | Managed domain control-plane state |
| `Get-MgOrganization \| Select OnPremisesSyncEnabled` | Tenant PHS/federation posture |
| `Get-MgUser -UserId <upn> -Property UserType,OnPremisesSyncEnabled` | Is this account eligible to sync at all |
| `Get-ADUser -Server <fqdn> -Properties PasswordLastSet,LockedOut,SID` | In-domain account state (source of truth for auth issues) |
| `Unlock-ADAccount -Identity <sam> -Server <fqdn>` | Clear a local managed-domain lockout |
| `New-ADFineGrainedPasswordPolicy` / `Add-ADFineGrainedPasswordPolicySubject` | Override the 90-day default password policy |
| `Get-ADTrust -Filter * -Server <fqdn>` | Forest trust health to on-prem AD DS |
| `Get-AzNetworkSecurityGroup -Name <n> -ResourceGroupName <rg>` | Validate NSG against platform baseline |
| `Get-AzRouteTable -ResourceGroupName <rg>` | Confirm no unsupported UDR on the `0.0.0.0/0` route |
| `Start-ADSyncSyncCycle -PolicyType Initial\|Delta` | Force an Entra Connect sync cycle (hybrid credential backfill) |
| `Get-MgServicePrincipal -Filter "AppId eq '<id>'"` | Find stale Domain Services app registrations blocking re-enablement |
| `Get-ADObject -SearchBase <customOU> -Server <fqdn>` | Inspect objects in a custom OU (never synced back to Entra ID) |

---
## 🎓 Learning Pointers

- **The sync direction is permanently one-way: Entra ID → managed domain, never the reverse.** A managed domain is largely read-only from the perspective of anything that originated in Entra ID — you can create and manage objects in custom OUs, but you cannot push changes to synced users/groups back upstream, and installing Entra Connect *inside* the managed domain to attempt this is explicitly unsupported.
- **Federation without Password Hash Synchronization is a hard, tenant-wide blocker for Domain Services**, not a per-user misconfiguration — NTLM/Kerberos require a legacy password hash that a purely-federated tenant never generates or stores in Entra ID. This is worth confirming during any Domain Services scoping conversation, before enablement, not after a failed pilot.
- **`SidHistory` in the managed domain only ever carries forward the on-premises primary SID at time of sync — it does not regenerate after a delete/restore cycle inside Entra ID.** A restored user gets a brand-new managed-domain SID, silently orphaning any ACLs that referenced the old one; this is the most common "why did this user lose file access after being re-invited" root cause.
- **Group Policy, SYSVOL, DFS/DFSR, and on-premises OU hierarchy are all permanently out of scope for a managed domain** — it is not a lighter-weight AD DS, it is a purpose-built, flattened, credential-focused directory for lift-and-shift legacy authentication. Set this expectation early; it prevents a large class of "why doesn't this work like our real domain" tickets.
- **Never hardcode a specific domain controller's hostname anywhere** — DC names can change during Microsoft's own maintenance of the managed domain. Always reference the managed domain's FQDN.
- Related: [What is Microsoft Entra Domain Services?](https://learn.microsoft.com/en-us/entra/identity/domain-services/overview), [Network planning and connections for Microsoft Entra Domain Services](https://learn.microsoft.com/en-us/entra/identity/domain-services/network-considerations), [How synchronization works in Microsoft Entra Domain Services](https://learn.microsoft.com/en-us/entra/identity/domain-services/synchronization), [Common errors and troubleshooting steps](https://learn.microsoft.com/en-us/entra/identity/domain-services/troubleshoot), [Frequently asked questions](https://learn.microsoft.com/en-us/entra/identity/domain-services/faqs)
