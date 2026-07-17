# AD FS (Active Directory Federation Services) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---
## Skim Index (with jump links)
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

This covers **on-premises AD FS** (Windows Server AD FS role, farm-based, WID or SQL configuration database) and its companion **Web Application Proxy (WAP)** role for extranet access — the legacy claims-based federation path many orgs still run for M365/Entra ID sign-in, either because they haven't migrated to Entra Connect Password Hash Sync/Pass-through Auth, or because a specific compliance requirement (smartcard-only auth, on-prem MFA enforcement, custom claims logic) keeps them on federation.

Out of scope: Entra Connect sync mechanics (see `EntraID/Troubleshooting/Connect-Sync-A.md`), hybrid Windows join / PRT issuance (see `EntraID/Troubleshooting/HybridJoin-A.md` and `PRT-Issues-A.md`), and Conditional Access enforcement once a token is issued (see `Security/ConditionalAccess/`). This runbook assumes AD FS is the org's chosen identity federation mechanism and focuses on keeping that federation trust itself healthy — not on whether federation vs. cloud auth is the right architecture (that's a design conversation, not a break-fix one).

---
## How It Works

<details><summary>Full architecture</summary>

AD FS issues security tokens (SAML or WS-Federation, depending on the relying party) that assert a user's identity to a relying party (RP) — most commonly Entra ID/M365, but potentially any SAML-aware SaaS app. The trust between AD FS and an RP is bidirectional and certificate-based:

1. **AD FS signs every token it issues** with its **Token-Signing certificate**. The RP validates that signature using a copy of AD FS's public key, obtained either from federation metadata (`/FederationMetadata/2007-06/FederationMetadata.xml`) or configured manually.
2. For RPs that require it, AD FS also **encrypts** the token using the RP's public key, requiring a **Token-Decrypting certificate** on the AD FS side so it can process anything the RP encrypts back (rare in the M365 scenario, more common for SAML apps that request encrypted assertions).
3. Each application AD FS federates with is a **Relying Party Trust** object in the AD FS configuration database, holding: the RP's identifier, its expected endpoints, claims issuance/transform rules (what attributes AD FS sends and how they're mapped), and — critically for M365 — the specific signature algorithm and certificate the RP expects.
4. **Claims rules** are the transformation logic that maps AD/LDAP attributes (UPN, `objectGUID`/`ms-DS-ConsistencyGuid`, group membership) into the claim types the RP expects (`nameidentifier`, `upn`, `immutableid`, `group`). For M365 specifically, the `immutableid` claim must match what Entra Connect populated as the corresponding cloud user's `ImmutableId` — a mismatch here causes "user not found" style failures that look like a sync problem but are actually a claims-rule problem.
5. **Certificate rollover**: by default (`AutoCertificateRollover = $true`), AD FS auto-generates a new Token-Signing/Token-Decrypting certificate roughly 20 days before the current one expires (`CertificateGenerationThreshold`), and both old and new certs remain valid for an overlap window so in-flight tokens/cached RP metadata don't break instantly. Federation metadata is republished automatically, and RPs configured for auto-metadata-refresh (Entra ID included) pick up the new cert within about 24 hours. If auto-rollover is disabled, or an admin manually reissues a cert without updating dependent RPs, every relying party that hasn't been told about the new cert will reject every subsequently issued token — this is the single most common cause of a farm-wide, all-users-locked-out AD FS outage.
6. **Web Application Proxy (WAP)** sits in a perimeter/DMZ and proxies AD FS traffic for external users without requiring the farm itself to be internet-facing. WAP maintains its own **proxy trust** with the farm — a separate, automatically-rolling certificate (distinct from the token-signing/decrypting certs) that must be periodically re-established. If a WAP server is offline longer than its proxy trust's validity window, trust lapses and external sign-ins fail while internal sign-ins (which don't traverse WAP) continue working — a distinctive "it only breaks from outside" symptom pattern.
7. **Farm topology**: AD FS runs as a farm of one or more nodes sharing a configuration database (WID for small farms, SQL Server for larger/HA farms) and a farm-wide service identity (traditionally a domain service account, increasingly a group Managed Service Account/gMSA). All farm nodes must be able to read the same certificates and configuration; a node that's fallen out of sync (missed a config database update, or has a stale local cert store) will behave inconsistently — some users succeed, some don't, depending on load-balancer routing.

```
                    ┌─────────────────────────────┐
                    │   AD FS Configuration DB     │
                    │  (WID or SQL) — RP trusts,   │
                    │  claims rules, certs, farm   │
                    │  behavior level              │
                    └──────────────┬──────────────┘
                                   │ replicated/shared
              ┌────────────────────┼────────────────────┐
              ▼                    ▼                     ▼
        AD FS Node 1          AD FS Node 2           AD FS Node N
        (adfssrv)             (adfssrv)              (adfssrv)
              │                    │                     │
              └────────────────────┴─────────────────────┘
                                   │
                     Internal clients ── direct AD FS endpoint
                                   │
                    ┌──────────────┴──────────────┐
                    │  Web Application Proxy (WAP) │  ← separate proxy trust cert
                    │  (perimeter/DMZ)             │
                    └──────────────┬──────────────┘
                                   │
                          External/extranet clients
```

</details>

---
## Dependency Stack

```
Layer 5:  Relying Party (Entra ID / M365, or any SAML-aware SaaS app)
              ▲ validates token signature + claims against its configured trust
Layer 4:  Relying Party Trust object (AD FS config DB) — identifier, claims rules,
          expected signature algorithm, endpoint bindings
              ▲ requires
Layer 3:  Token-Signing / Token-Decrypting certificates — live, trusted chain,
          service account has private-key read access
              ▲ requires
Layer 2:  AD FS Configuration Database (WID/SQL) + farm service identity (domain
          account or gMSA) — shared across all farm nodes
              ▲ requires
Layer 1:  adfssrv service healthy on every farm node; Active Directory reachable
          for service account authentication
Layer 0 (extranet only):  Web Application Proxy — separate proxy trust certificate,
          independent rolling renewal cycle from Layers 3
```

A failure at Layer 3 (certificates) breaks **everyone**. A failure at Layer 0 (WAP proxy trust) breaks **only external users** — this split is the fastest triage signal available and should be checked first in any "AD FS is down" report.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| All federated sign-ins fail, internal and external, all at once | Token-signing/decrypting cert expired or rotated without RP update | `Get-AdfsCertificate`, compare thumbprint against Entra ID's `Get-MgDomainFederationConfiguration` |
| Sign-in fails only for users coming from outside the network | WAP proxy trust expired | WAP server event log, `Get-WebApplicationProxyConfiguration`, events 224/276 |
| Sign-in succeeds but the wrong user/no user is matched in Entra ID ("user not found" despite existing) | Claims rule `immutableid` mismatch vs. Entra Connect's `ms-DS-ConsistencyGuid`/`ImmutableId` | Compare `IssuanceTransformRules` output against `Get-MgUser` `-Property onPremisesImmutableId` |
| One specific application fails, everything else (including M365) works | That RP's individual trust is disabled, misconfigured, or has a stale cert | `Get-AdfsRelyingPartyTrust -Name <app>` |
| Sign-in works from some farm nodes but not others | Farm node out of sync — stale local cert store or missed config DB update | `Get-AdfsFarmInformation`, compare cert store contents node-to-node |
| "Federation Service configuration could not be updated" (Event 224) on WAP | Proxy trust needs re-establishment | `Install-WebApplicationProxy` |
| Users see a certificate warning/browser TLS error hitting the AD FS/WAP URL | This is the **SSL/TLS binding certificate**, a completely separate cert from token-signing/decrypting — don't confuse the two | `netsh http show sslcert`, IIS/WAP binding config |
| Farm upgrade or new server added, but new features/cmdlets unavailable | `FarmBehaviorLevel` not raised after all nodes upgraded | `Get-AdfsFarmInformation`, `Set-AdfsFarmInformation -FarmBehaviorLevel` |
| Claims-based app suddenly rejects tokens after a "routine" AD FS certificate refresh | Admin manually rotated a cert without pushing updated metadata to that RP (common for RPs that don't auto-refresh federation metadata, unlike Entra ID) | Compare RP's configured signing cert vs. farm's current live cert |

---
## Validation Steps

1. **Service and farm membership.**
   ```powershell
   Get-Service adfssrv
   Get-AdfsFarmInformation | Select-Object -ExpandProperty FarmNodes
   ```
   Good: service running on this node; every expected node listed. Bad: a node missing from `FarmNodes` — it has dropped out of the farm and needs investigation independently.

2. **Certificate inventory and expiry window.**
   ```powershell
   Get-AdfsCertificate | Select-Object CertificateType, IsPrimary, Thumbprint, @{N='NotAfter';E={$_.Certificate.NotAfter}}
   ```
   Good: primary certs valid for weeks/months out; if a secondary (rollover) cert is present, that's normal mid-rotation behavior. Bad: primary cert expired or `< 5 days` remaining with `AutoCertificateRollover` off.

3. **Cross-check what the relying party actually has on file.**
   ```powershell
   Get-MgDomainFederationConfiguration -DomainId <yourdomain.com>
   ```
   Good: `SigningCertificate` thumbprint matches the farm's current live Token-Signing cert. Bad: mismatch — Entra ID is validating against a certificate the farm no longer uses to sign.

4. **Claims rules for the M365 relying party.**
   ```powershell
   (Get-AdfsRelyingPartyTrust -Name "Microsoft Office 365 Identity Platform").IssuanceTransformRules
   ```
   Good: standard rule set present including an `immutableid` mapping consistent with the attribute Entra Connect uses as its source anchor. Bad: rules missing, edited, or referencing an attribute that doesn't match Entra Connect's configured `sourceAnchor`.

5. **WAP proxy trust state** (extranet path only).
   ```powershell
   Get-WebApplicationProxyConfiguration
   Get-WinEvent -LogName 'AD FS/Admin' -MaxEvents 50 | Where-Object Id -in 224,276,394,395,396 | Sort-Object TimeCreated -Descending
   ```
   Good: periodic 396 (trust renewed) events with no unresolved 224/276 afterward. Bad: repeated 224/276 with no subsequent successful renewal.

6. **Farm behavior level matches the actual OS/role version across all nodes** (relevant after any node was upgraded or replaced).
   ```powershell
   Get-AdfsFarmInformation | Select-Object CurrentFarmBehavior
   ```
   Good: matches the lowest common OS version across all farm members, raised deliberately once all nodes are upgraded. Bad: left at a legacy level indefinitely after a full farm upgrade, silently disabling newer features/cmdlets.

7. **End-to-end token issuance test** (best done from a domain-joined test machine, internal and — separately — from outside the network via WAP):
   ```powershell
   # Sign-in test via a browser to https://<adfs-fqdn>/adfs/ls/idpinitiatedsignon
   # or, for a scripted check:
   Invoke-WebRequest -Uri "https://<adfs-fqdn>/federationmetadata/2007-06/federationmetadata.xml" -UseBasicParsing
   ```
   Good: metadata document loads and is current (check the `<EntityDescriptor>` timestamp/certs). Bad: TLS error (separate SSL cert problem, not token-signing), timeout (service or network issue), or stale certs in the returned metadata.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Scope the blast radius.** Internal-only-broken vs. external-only-broken vs. single-application-broken determines which layer of the dependency stack to investigate. Don't start pulling certificates until you know which layer is implicated.

**Phase 2 — Certificate layer.** Compare farm-side live signing/decrypting cert thumbprints against what the affected RP(s) have on file. For Entra ID, this is the fastest, highest-yield check given how common cert-mismatch outages are.

**Phase 3 — Trust object layer.** If certs check out but one specific RP is broken, inspect that RP's trust object directly — enabled state, claims rules, expected signature algorithm — rather than assuming a farm-wide cause.

**Phase 4 — Farm consistency layer.** If behavior is inconsistent across attempts (some succeed, some fail, no obvious pattern by internal/external), suspect a farm node out of sync — compare `Get-AdfsFarmInformation` and local cert stores across all nodes.

**Phase 5 — WAP/proxy layer (extranet symptoms only).** Confirm proxy trust state independently of farm health; a fully healthy farm can still have all-external sign-ins fail if WAP's proxy trust alone has lapsed.

**Phase 6 — Escalate if:** Event 133 appears (service identity token corruption — this points at farm identity/gMSA problems that risk further damage from ad-hoc fixes), the configuration database itself appears corrupt, or a SQL-based farm's database server is unreachable (that's a SQL Server incident, not an AD FS one).

---
## Remediation Playbooks

<details><summary>Playbook 1 — Farm-wide outage from certificate mismatch/expiry</summary>

1. Confirm the mismatch: compare `Get-AdfsCertificate` thumbprint against every affected RP's configured thumbprint (for Entra ID: `Get-MgDomainFederationConfiguration`).
2. If the farm's cert is genuinely expired or about to be: `Update-AdfsCertificate -CertificateType Token-Signing` (and `Token-Decrypting` if also affected).
3. Push updated metadata to every RP that doesn't auto-refresh. For Entra ID: `Update-MgDomainFederationConfiguration` (or the legacy `Update-MsolFederatedDomain`) rather than waiting on the ~24-hour automatic metadata refresh during an active outage.
4. Enable `AutoCertificateRollover` going forward if it wasn't already: `Set-AdfsProperties -AutoCertificateRollover $true`.
5. Document the manual intervention — a farm that needed a manual cert push once will need it again unless the root cause (rollover disabled, or an RP that doesn't auto-refresh metadata) is addressed.

**Rollback:** if the newly issued certificate itself is the problem (e.g., wrong template, wrong key size for a specific RP's requirements), re-promote the previous cert with `Set-AdfsCertificate -CertificateType <type> -Thumbprint <previous>` as long as it hasn't been purged from the local store, then re-issue more carefully.
</details>

<details><summary>Playbook 2 — Claims rule / immutableid mismatch causing "user not found" in Entra ID</summary>

1. Get the claims rule output for the M365 RP: `(Get-AdfsRelyingPartyTrust -Name "Microsoft Office 365 Identity Platform").IssuanceTransformRules`.
2. Identify what source attribute the `immutableid` claim is built from (commonly `objectGUID` or `ms-DS-ConsistencyGuid`, base64-encoded).
3. Confirm this matches Entra Connect's configured `sourceAnchor`/`ImmutableId` source for the same users: check the Entra Connect sync rule configuration (Synchronization Rules Editor, "In from AD - User AccountEnabled" and the sourceAnchor rule) or `Get-MgUser -UserId <upn> -Property onPremisesImmutableId`.
4. If they diverge — often after an AD migration, forest restructure, or a manual claims-rule "fix" that used the wrong attribute — correct the claims rule to reference the same source attribute Entra Connect uses, not the other way around (changing Entra Connect's sourceAnchor after go-live risks re-provisioning every user object in the cloud).

**Rollback:** claims rule edits in AD FS are configuration-only and reversible via the AD FS management console's rule history/export, or by re-applying a saved rule set backup before making changes.
</details>

<details><summary>Playbook 3 — WAP proxy trust lapsed (extranet-only outage)</summary>

1. Confirm scope: internal sign-ins succeed, external fail — this isolates the problem to WAP.
2. On the WAP server, check for repeated 224/276 events without a following 396 (successful renewal).
3. Re-establish trust: `Install-WebApplicationProxy -CertificateThumbprint <wap-ssl-thumbprint> -FederationServiceName <adfs-fqdn>` using farm admin credentials.
4. Confirm published applications are still intact after trust re-establishment: `Get-WebApplicationProxyApplication`.

**Rollback:** none required — re-establishing proxy trust doesn't alter published application configuration; if applications are missing afterward, that's a separate WAP configuration issue to investigate independently.
</details>

<details><summary>Playbook 4 — Farm node out of sync</summary>

1. Confirm all expected nodes appear in `Get-AdfsFarmInformation`.
2. On the affected node, compare local certificate store contents (`Get-ChildItem Cert:\LocalMachine\My`) against a known-healthy node.
3. If the node is missing recent certs/config, the safest fix is usually to remove it from the farm and re-join rather than attempting to manually patch its local state:
   ```powershell
   # On the affected node
   Remove-AdfsFarmNode
   # Then re-join per the standard farm-join procedure for this environment
   ```
4. If SQL-based farm and the issue is database connectivity rather than the node itself, that's a SQL Server availability incident — treat accordingly, don't attempt AD FS-side fixes.

**Rollback:** removing and re-joining a farm node is itself the safe/reversible path here — a node that fails to re-join cleanly can simply be left removed while the farm continues serving from healthy nodes (assuming farm capacity allows it).
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS    Collects AD FS farm, certificate, and relying-party trust health for escalation.
.DESCRIPTION Read-only. Run on a farm node with AD FS PowerShell module available.
#>
$out = [ordered]@{}
$out.FarmInfo        = Get-AdfsFarmInformation | Select-Object CurrentFarmBehavior, @{N='Nodes';E={$_.FarmNodes -join ', '}}
$out.Properties      = Get-AdfsProperties | Select-Object HostName, Identifier, AutoCertificateRollover, CertificateGenerationThreshold, CertificateDuration
$out.Certificates    = Get-AdfsCertificate | Select-Object CertificateType, IsPrimary, Thumbprint, @{N='NotAfter';E={$_.Certificate.NotAfter}}, @{N='DaysLeft';E={($_.Certificate.NotAfter - (Get-Date)).Days}}
$out.RelyingParties  = Get-AdfsRelyingPartyTrust | Select-Object Name, Enabled, MonitoringEnabled, Identifier
$out.RecentErrors    = Get-WinEvent -LogName 'AD FS/Admin' -MaxEvents 50 | Where-Object LevelDisplayName -in 'Error','Warning' |
                        Select-Object TimeCreated, Id, LevelDisplayName, Message
$out | ConvertTo-Json -Depth 4 | Out-File ".\ADFS-EvidencePack-$(Get-Date -Format yyyyMMdd-HHmm).json"
Write-Host "Evidence pack written." -ForegroundColor Green
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-AdfsProperties` | Farm-wide properties: hostname, identifier, auto-rollover settings |
| `Get-AdfsCertificate` | Lists Token-Signing/Token-Decrypting certs and primary/secondary state |
| `Update-AdfsCertificate -CertificateType <type>` | Forces a certificate rollover |
| `Set-AdfsCertificate -CertificateType <type> -Thumbprint <thumb>` | Re-promotes a specific certificate as primary |
| `Set-AdfsProperties -AutoCertificateRollover $true` | Enables automatic cert renewal |
| `Get-AdfsRelyingPartyTrust [-Name <name>]` | Lists or inspects relying party trust objects |
| `Set-AdfsRelyingPartyTrust -TargetName <name> -Enabled $true` | Re-enables a disabled trust |
| `Get-AdfsFarmInformation` | Farm topology, node list, farm behavior level |
| `Set-AdfsFarmInformation -FarmBehaviorLevel <n>` | Raises the farm behavior level after a full-farm upgrade |
| `Remove-AdfsFarmNode` | Removes the local node from the farm |
| `Get-WebApplicationProxyConfiguration` | WAP proxy configuration and trust state |
| `Install-WebApplicationProxy` | Re-establishes WAP-to-farm proxy trust |
| `Get-MgDomainFederationConfiguration -DomainId <domain>` | What Entra ID has on file for a federated domain (Graph) |
| `Update-MgDomainFederationConfiguration` | Forces Entra ID to refresh federation config from the farm |
| `Convert-MsolDomainToStandard -DomainName <domain>` | Emergency bypass: moves a domain to cloud-managed auth |
| `Get-WinEvent -LogName 'AD FS/Admin'` | Primary AD FS diagnostic event log |

---
## 🎓 Learning Pointers
- Certificate-related outages dominate real-world AD FS incidents precisely because the failure mode is silent until expiry — build the "days left" check into routine monitoring rather than discovering it during an outage. See [AD FS troubleshooting — certificates](https://learn.microsoft.com/en-us/windows-server/identity/ad-fs/troubleshooting/ad-fs-tshoot-certs).
- The token-signing certificate and the AD FS/WAP **SSL binding certificate** are two entirely different certificates with different renewal mechanisms and different failure symptoms (browser TLS warning vs. sign-in failure) — conflating them wastes triage time.
- WAP's proxy trust renewal cycle is independent from the farm's token-signing cert rollover — a healthy farm can still have a fully broken extranet path if a WAP server was offline long enough for its trust to lapse.
- `immutableid` claims-rule mismatches are frequently misdiagnosed as Entra Connect sync failures because the symptom ("user not found") looks identical — always check the claims rule's source attribute against Entra Connect's actual `sourceAnchor` before assuming a sync problem.
- Treat `FarmBehaviorLevel` like a schema version: raising it unlocks newer functionality but is a one-way operation once all farm members are confirmed upgraded — don't raise it prematurely on a farm still mid-upgrade.
- For general troubleshooting flow when the specific cause isn't yet obvious, Microsoft's own decision-tree style guide is a good second reference: [Troubleshoot AD FS issues](https://learn.microsoft.com/en-us/troubleshoot/windows-server/active-directory/troubleshoot-ad-fs-issues).
