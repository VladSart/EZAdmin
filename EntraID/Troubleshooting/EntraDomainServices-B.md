# Microsoft Entra Domain Services (Entra DS) — Hotfix Runbook (Mode B: Ops)
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

```powershell
# 1. Managed domain health status (Healthy / Running / Deploying / etc.) — Azure PowerShell (Az.ADDomainServices)
Get-AzADDomainService -ResourceGroupName "<rg>" -Name "<domainName>" |
    Select-Object DomainName, DomainConfigurationType, DeploymentId |
    Format-List

# 2. Replica set / domain controller health (surfaced under the domain service resource's health alerts in the Azure portal;
#    PowerShell equivalent pulls the replica set collection)
(Get-AzADDomainService -ResourceGroupName "<rg>" -Name "<domainName>").ReplicaSets |
    Select-Object Location, SubnetId, ServiceStatus, DomainControllerIpAddress

# 3. Confirm synchronization type and password hash sync status (Entra DS is downstream of Entra ID — it does NOT sync on its own)
Get-AzADDomainService -ResourceGroupName "<rg>" -Name "<domainName>" |
    Select-Object -ExpandProperty NotificationSettings

# 4. From a domain-joined VM: confirm it can actually see the managed domain
nltest /dsgetdc:<yourdomain.com>
Test-NetConnection -ComputerName <domainName> -Port 389   # LDAP
Test-NetConnection -ComputerName <domainName> -Port 636   # Secure LDAP, if enabled

# 5. Confirm the VM's NSG/VNet allows the required management traffic to the Entra DS subnet
Get-AzNetworkSecurityGroup -ResourceGroupName "<rg>" -Name "<nsgName>" |
    Get-AzNetworkSecurityRuleConfig
```

**Interpret:**
- Domain service status not `Running`/healthy → root cause is likely the managed domain itself (replica set, VNet peering, or a health alert) — see [Fix 1](#fix-1--managed-domain-unhealthy-or-alerting)
- A specific user/group can't authenticate against Entra DS but others can → password hash not yet synced for that object, see [Fix 2](#fix-2--user-cannot-authenticate-ntlmkerberos-against-entra-ds)
- New OU/nested group structure not reflecting → Entra DS only syncs from the flat top-level, see [Fix 3](#fix-3--ou-or-group-nesting-not-reflected-in-entra-ds)
- LDAPS bind failing / certificate errors → secure LDAP not configured, expired cert, or NSG blocking 636 — see [Fix 4](#fix-4--secure-ldap-ldaps-not-working)
- VM can't domain-join or resolve the managed domain at all → DNS/VNet peering problem, see [Fix 5](#fix-5--vm-cannot-domain-join-or-resolve-managed-domain)

---

## Dependency Cascade

<details><summary>What must be true for Entra DS authentication to work</summary>

```
Entra ID (cloud identity — source of truth)
    │
    └── Password hash synchronization to Entra DS
          (one-way, one-time-per-change; requires either:
             • Cloud-only user password reset/set AFTER Entra DS is enabled, or
             • Entra Connect syncing on-prem AD with password hash sync enabled)
                │
                └── Entra DS managed domain (Microsoft-managed, two replicated DCs)
                        ├── Flat OU structure synced from Entra ID:
                        │     "AADDC Users" and "AADDC Computers" — NO nested OUs,
                        │     NO on-prem-style group nesting beyond one level for
                        │     security groups used in NTLM/Kerberos token building
                        ├── VNet / subnet dedicated to Entra DS (cannot be shared
                        │     with anything else; NSG rules control mgmt traffic)
                        └── Replica set(s) — one per peered VNet/region for HA
                                │
                                └── VNet peering from the workload VNet
                                        └── DNS pointing workload VMs at the Entra DS
                                              replica set IPs (set on the VNet, not per-VM)
                                                └── Domain-joined VM (classic AD DS join,
                                                      NOT Entra join) authenticates via
                                                      NTLM/Kerberos/LDAP against the
                                                      managed domain
```

**Key fact:** Entra DS is a one-way, downstream sync target of Entra ID — it is never authoritative and cannot be written back to. Any password or group change must originate in Entra ID (or on-prem AD via Entra Connect) and then sync down; there is no direct write path into Entra DS's directory from a domain-joined VM the way there would be against a real on-prem DC.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm the managed domain itself is healthy**
```powershell
Get-AzADDomainService -ResourceGroupName "<rg>" -Name "<domainName>"
```
Expected: no active health alerts. If the Azure portal shows a health alert (e.g., "DNS records missing," "NSG rules blocking required ports," "Replica set unhealthy"), resolve that before investigating anything downstream — a domain-wide health alert affects every user and every VM equally, so don't chase a single-user theory first.

**Step 2 — Confirm password hash sync landed for the affected user**
```powershell
# In Entra ID — confirm the user is cloud-only or synced from on-prem with PHS enabled
Get-MgUser -UserId "<user@domain.com>" -Property OnPremisesSyncEnabled,OnPremisesLastSyncDateTime |
    Select-Object DisplayName, OnPremisesSyncEnabled, OnPremisesLastSyncDateTime
```
Expected: For hybrid users, recent `OnPremisesLastSyncDateTime` and Entra Connect configured with Password Hash Synchronization (verify in Entra Connect Health, not shown here). For cloud-only users, the password hash only syncs to Entra DS the *next time the user changes or resets their password after Entra DS was enabled* — a cloud-only account created before Entra DS was turned on, that has never had a password reset since, will not authenticate until it does.

**Step 3 — Confirm the object appears in Entra DS's synced OU structure**
On a domain-joined VM with RSAT installed against the managed domain:
```powershell
Get-ADUser -Filter "UserPrincipalName -eq '<user@domain.com>'" -Server <domainName> |
    Select-Object Name, DistinguishedName, Enabled
```
Expected: Object present under `OU=AADDC Users,DC=<domain>,DC=<com>`. Missing object after >20 minutes from Entra ID creation indicates a sync delay worth escalating, not a config problem.

**Step 4 — Confirm network path from the workload VM to the managed domain**
```powershell
nltest /dsgetdc:<domainName>
Test-NetConnection -ComputerName <domainName> -Port 389
```
Expected: A DC is located and port 389 (LDAP) succeeds. Failure here is almost always VNet peering or DNS — not an identity problem — see Fix 5.

**Step 5 — If using Secure LDAP, confirm the certificate is valid and NSG allows 636**
```powershell
Test-NetConnection -ComputerName <domainName> -Port 636
```
Expected: Success. Also confirm in the Azure portal that the uploaded LDAPS certificate has not expired — Entra DS does not auto-renew a customer-supplied LDAPS certificate.

---

## Common Fix Paths

<details id="fix-1"><summary>Fix 1 — Managed domain unhealthy or alerting</summary>

```powershell
# Review active health alerts for the managed domain (best done in Azure portal: Entra Domain Services > Health)
Get-AzADDomainService -ResourceGroupName "<rg>" -Name "<domainName>"
```

Common alert causes and fixes:
- **Missing DNS records for the managed domain** — ensure the VNet's DNS servers point to the Entra DS replica set IPs (set at the VNet level, Azure will show the two required IPs on the resource overview).
- **NSG rules blocking required management traffic** — Entra DS requires specific inbound rules from `AzureActiveDirectoryDomainServices` service tag (ports 443, 3389 for management) on the dedicated Entra DS subnet's NSG. Do not remove these rules even though they look unused from a workload perspective.
- **Replica set unhealthy** — usually resolves itself; if it persists beyond a few hours, open a support case rather than attempting a rebuild — there is no customer-initiated repair action for the managed DCs themselves.

**Rollback:** N/A — these are Microsoft-managed components; fixes are configuration corrections (DNS, NSG) on the customer side, not rollbacks.

</details>

<details id="fix-2"><summary>Fix 2 — User cannot authenticate (NTLM/Kerberos) against Entra DS</summary>

**When:** Object exists in Entra DS's synced OU but sign-in still fails with bad password / KDC errors.

```powershell
# Force the user to change or reset their password — this is what actually triggers hash sync to Entra DS
# for a cloud-only account. For hybrid accounts, confirm Entra Connect Password Hash Sync is enabled and healthy.
Update-MgUserPassword -UserId "<user@domain.com>" -PasswordProfile @{ ForceChangePasswordNextSignIn = $true }
```

**Common miss:** Enabling Entra DS does not retroactively sync existing passwords — only a password change *after* Entra DS is enabled populates the hash Entra DS needs for NTLM/Kerberos. This is the single most common "why can't this user log into the domain-joined VM" ticket for newly-enabled Entra DS environments.

**Rollback:** N/A — forcing a password change is not destructive, just an inconvenience; communicate to the user first.

</details>

<details id="fix-3"><summary>Fix 3 — OU or group nesting not reflected in Entra DS</summary>

**When:** A group structure or OU layout designed in Entra ID doesn't appear as expected inside Entra DS.

Entra DS synchronizes **all users and groups into two flat containers** — `AADDC Users` and `AADDC Computers` — regardless of how they're organized in Entra ID. There is no custom OU structure sync, and nested group membership beyond what NTLM/Kerberos token building natively supports is not preserved in a customizable way.

```powershell
# Confirm actual group membership as it landed in Entra DS (query against the managed domain, RSAT tools)
Get-ADGroupMember -Identity "<groupName>" -Server <domainName>
```

If custom OU delegation is required (e.g., to scope GPOs differently per business unit), this must be built **inside** Entra DS after initial sync — Entra DS supports creating additional OUs and moving synced objects into them post-sync, but that structure is unique to Entra DS and does not sync back to Entra ID or on-prem AD.

**Rollback:** N/A — this is an architectural constraint, not a bug; document the flat-sync behavior for the client so future OU requests are scoped correctly the first time.

</details>

<details id="fix-4"><summary>Fix 4 — Secure LDAP (LDAPS) not working</summary>

```powershell
# Confirm the certificate currently bound to the managed domain
Get-AzADDomainService -ResourceGroupName "<rg>" -Name "<domainName>" |
    Select-Object -ExpandProperty LdapsSettings
```

Checks in order:
1. Certificate expired — customer-supplied LDAPS certificates do not auto-renew; a new PFX must be uploaded before expiry.
2. NSG on the Entra DS subnet blocking inbound 636 from the client's source (secure LDAP external access requires an explicit NSG allow plus, if accessed from the internet, a public IP configured on the domain — most environments should restrict this to VNet-internal access only).
3. Client not trusting the certificate chain — if using a self-signed or internal CA cert, the connecting client/app must have the issuing CA in its trusted root store.

**Rollback:** Re-upload the previous valid certificate if a rotation caused the break and the new cert was misconfigured.

</details>

<details id="fix-5"><summary>Fix 5 — VM cannot domain-join or resolve managed domain</summary>

```powershell
# Confirm the VNet's DNS servers are set to the Entra DS replica set IPs (not Azure-provided DNS, not on-prem DNS
# unless conditional forwarding to Entra DS is explicitly configured)
Get-AzVirtualNetwork -ResourceGroupName "<rg>" -Name "<vnetName>" |
    Select-Object -ExpandProperty DhcpOptions

# Confirm VNet peering exists and is fully connected (not just "Initiated" on one side)
Get-AzVirtualNetworkPeering -ResourceGroupName "<rg>" -VirtualNetworkName "<vnetName>" |
    Select-Object Name, PeeringState, PeeringSyncLevel
```

Expected: `PeeringState = Connected` and `PeeringSyncLevel = FullyInSync` on both sides. A one-sided peering (common when the workload VNet's peering was created without the reciprocal link from the Entra DS VNet) will silently break domain join and DNS resolution while looking correct from the workload side alone.

**Rollback:** N/A for diagnosis; correcting a one-sided peering is additive (create the missing reciprocal peering), not destructive.

</details>

---

## Escalation Evidence

```
Entra Domain Services Issue — Evidence Pack
====================================
Managed domain name:                
Resource group / subscription:      
Domain configuration type:          [User forest / Resource forest]
Replica set location(s):            
Affected VM(s) / user(s):           
Symptom:                            [Domain-join fails / Auth fails / LDAPS fails / OU-sync question]
Managed domain health status:       [Get-AzADDomainService output]
Password hash sync confirmed:       [Yes/No — hybrid PHS status or cloud-only pwd-reset-since-enable]
Object present in AADDC Users/Computers: [Yes/No]
VNet peering state:                 [PeeringState / PeeringSyncLevel]
NSG rules on Entra DS subnet:       [confirm AzureActiveDirectoryDomainServices tag present]
LDAPS certificate expiry:           
Network test results (389/636):     
```

---

## 🎓 Learning Pointers

- **Entra DS is a one-way, downstream copy of Entra ID — never authoritative.** You cannot write directly into its directory the way you would an on-prem DC (beyond post-sync OU/group organization inside Entra DS itself); every user/password/group change must originate upstream and sync down. Treat "why doesn't my change from the managed domain show up in Entra ID" as an architecture question, not a bug. [MS Docs: Microsoft Entra Domain Services overview](https://learn.microsoft.com/en-us/entra/identity/domain-services/overview)
- **Password hash sync to Entra DS only happens on a password change *after* Entra DS is enabled.** This is the #1 "can't log into the domain-joined VM" ticket right after a new Entra DS deployment — force a password reset for any pre-existing cloud-only account rather than assuming the sync config is broken.
- **The synced OU structure is permanently flat (`AADDC Users`/`AADDC Computers`) unless you build additional OUs inside Entra DS after the fact.** Set client expectations early if they're expecting an on-prem-style OU/GPO delegation model to appear automatically — it will not.
- **VNet peering for Entra DS must be reciprocal and fully synced on both sides.** A peering that shows connected from the workload VNet but not from the Entra DS VNet's side breaks DNS resolution and domain join silently — always check `PeeringSyncLevel` on both ends, not just one.
- **NSG rules using the `AzureActiveDirectoryDomainServices` service tag on the dedicated Entra DS subnet are structural, not optional.** They're easy to mistake for unused/legacy rules during a security audit — removing them breaks the managed domain's own management plane, not just customer traffic. [MS Docs: Network considerations for Microsoft Entra Domain Services](https://learn.microsoft.com/en-us/entra/identity/domain-services/network-considerations)
- **LDAPS certificates on Entra DS do not auto-renew.** Track expiry manually (or via a scheduled script) since there's no service-side renewal reminder built into the managed domain resource itself.
