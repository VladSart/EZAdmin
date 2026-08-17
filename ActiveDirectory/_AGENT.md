# Active Directory (On-Prem AD DS) — Agent Instructions

## What's in this folder

On-premises Active Directory Domain Services — the identity foundation that DFS, Entra Connect/hybrid join, Kerberos auth, and Group Policy all sit on top of. This module covers the **directory replication layer** (NTDS.dit multi-master replication, FSMO roles, replication topology), **domain/forest trust relationships** (secure channel health, SID filtering, selective authentication), **backup/restore** (System State backup validity, authoritative vs. non-authoritative restore, USN rollback, DSRM, AD Recycle Bin), **Group Policy processing & replication** (client-side GPO processing pipeline, GPC/GPT version agreement, security/WMI filtering, loopback processing), **AD-integrated DNS** (zone replication scope, DC Locator SRV records, scavenging/aging, forwarders/root hints, split-brain detection), **AD FS / Web Application Proxy** (on-prem claims-based federation for M365/SaaS — token-signing/decrypting certificate lifecycle, relying party trusts, claims rules, WAP proxy trust), **Group Managed Service Accounts (gMSA)** (KDS root key/GKDS deterministic password derivation, the two-step AD-delegation-vs-local-installation authorization model, forest-scoping limits), **Delegated Managed Service Accounts (dMSA)** (Windows Server 2025's migration-tracked successor to gMSA — the two-phase `Start-`/`Complete-ADServiceAccountMigration` state machine, the client-side `DelegatedMSAEnabled` policy gate, and the BadSuccessor/CVE-2025-53779 privilege-escalation consideration), **Fine-Grained Password Policies** (Password Settings Objects/PSOs, precedence resolution, direct-vs-group targeting, the domain-wide GPO policy as fallback), **LDAP Signing / Channel Binding** (the NTLM-relay-to-LDAP hardening — `LDAPServerIntegrity`/`LdapEnforceChannelBinding` enforcement levels, Event 2886/2887/3039 exposure diagnostics, and why a TLS-terminating proxy breaks channel binding by design), **Certificate-Based Authentication Mapping / KB5014754** (the PKINIT/Schannel certificate-to-account binding hardening — the SID extension, `altSecurityIdentities` weak-vs-strong mapping types, Event 39/40/41 diagnostics, and why Full Enforcement is now permanent and unbypassable on any DC patched since September 9, 2025), **Kerberos Armoring (FAST)** (the pre-authentication-exchange hardening and Dynamic Access Control/compound-authentication/AD FS-device-claims prerequisite — the domain-functional-level gate that silently no-ops stricter enforcement below Windows Server 2012, the independent KDC-side/client-side GPO pairing, and down-level-DC-driven intermittent failures), **the Group Policy Central Store & ADMX/ADML management** (the SYSVOL-hosted `PolicyDefinitions` folder that supplies the ADMX/ADML definitions Group Policy Management Editor renders — its silent per-machine local fallback when absent, ADMX namespace collisions and ADMX/ADML version-pairing errors caused by incremental/partial updates, the `EnableLocalStoreOverride` escape hatch, and the presentation-layer-only nature of ADMX/ADML relative to the actual `registry.pol`-stored setting value), **DNSSEC for AD-integrated DNS zones** (zone signing/KSK-ZSK key architecture, the Key Master role and its move-vs-seize recovery paths, trust anchor distribution via forest-wide AD DS replication, the manual-and-never-automatic DS record required for secure delegation to a parent zone, and the Windows DNS Client's status as a non-validating stub resolver — a response-*integrity* control layered on top of, and architecturally independent from, the DC Locator/SRV/scavenging *availability* mechanics covered in the base DNS topic), **Kerberos Delegation** (unconstrained, constrained/KCD via S4U2Self+S4U2Proxy, and resource-based constrained delegation/RBCD — the three impersonation-authorization models that solve the "double hop" problem; the `AccountNotDelegated`/Protected Users controls that intentionally and unconditionally block delegation for Tier-0 accounts regardless of any front-end or resource configuration; and why classic constrained delegation is intra-domain-only while RBCD is the only model that works across a domain boundary within the same forest), **AdminSDHolder / SDProp** (the template-object-plus-enforcement-process pair that stamps a fixed ACL onto every protected account/group — Domain Admins, Enterprise Admins, Administrators, Schema Admins, and the rest of the built-in protected-groups list — on a 60-minute, PDC-Emulator-only cycle; why `adminCount` is a side effect of a correction, not the authoritative protection signal; and why `adminCount` is never automatically cleared when an account leaves a protected group, a deliberate Windows 2000-era design choice that makes orphaned `adminCount=1` one of the most common recurring AD hygiene findings), **Read-Only Domain Controllers (RODC)** (the read-only, unidirectionally-replicated DC role for lower-physical-security locations — Password Replication Policy's Allowed/Denied list model and absolute Deny-over-Allow precedence, the dedicated per-RODC `krbtgt_<xxxxx>` account as a blast-radius isolation control, the authentication-forwarding-to-a-writable-DC flow and its WAN-down failure mode, the RODC Filtered Attribute Set as a forest-wide exclusion layered on top of PRP, the credential-reset-on-deletion incident-response workflow for a stolen RODC, and the security-critical "Replicating Directory Changes All" over-permission misconfiguration that silently bypasses PRP domain-wide), **Shadow Groups** (the practitioner-coined, script/tool-driven pattern of keeping an ordinary security group's membership synchronized to an OU or attribute filter — built entirely from scheduled tasks/third-party tools rather than any native AD feature, since neither GPO security filtering nor FGPP/PSO targeting can reference an OU directly; the additive-only-sync implementation defect as the most common real-world failure mode, the narrow member-attribute delegation model for the sync account, and the pattern's complete lack of self-healing compared to its downstream GPO/PSO consumers), and **AD LDS / Active Directory Lightweight Directory Services** (formerly ADAM — the same directory engine as AD DS running in an independent, domain-infrastructure-free mode for application-specific directory stores; the per-instance `ADAM_<name>` service/port/schema/partition model, the configuration-set multi-master replication topology and its near-simultaneous-service-account-change failure mode, the two mutually-exclusive per-object authentication models — instance-local principals vs. `userProxy` bind-redirection objects that forward auth live to a real AD DS account, the single most common source of misdiagnosed AD LDS auth tickets — and ADAMSync's one-way, incremental AD DS-to-AD LDS sync design), and **PAC Requestor Validation / sAMAccountName Spoofing (noPac)** (the CVE-2021-42278 + CVE-2021-42287 chained privilege-escalation technique that let any unprivileged domain user reach full domain compromise via a spoofed computer-account identity — the KB5008380 phased rollout that added the `PAC_REQUESTOR` structure to Kerberos TGTs and made cname-to-SID validation permanently mandatory on every DC patched since October 2022, the independent `ms-DS-MachineAccountQuota` hardening item that closes the enabling precondition regardless of patch level, and the legacy/non-Windows Kerberos client breakage this Enforcement phase can cause) — not the SYSVOL DFSR replication engine itself (see `DFS/`), not client-side DNS resolver config (see `Windows/`), not SMB signing (a parallel but separate relay-mitigation control on a different protocol, see `Windows/Troubleshooting/SMB-A.md`), not NTLM relay to AD CS/PetitPotam/ESC8 (a related but architecturally distinct relay-to-certificate-issuance attack chain, see `Windows/Troubleshooting/NTLMRelayADCS-A.md`), not cloud/hybrid sync or Entra Connect PHS/PTA (see `EntraID/`), not Entra ID's own cloud-side Certificate-Based Authentication (a separate, non-KDC mechanism — see `EntraID/Troubleshooting/CBA-A.md`), not Windows Hello for Business Cloud Kerberos Trust (an unrelated feature that shares only the word "Kerberos" with the armoring topic here), not GPO client-side processing behavior or GPC/SYSVOL replication (the Central Store topic is specifically about the ADMX/ADML *editing-tool* dependency, not how a configured setting reaches or applies on an end-user machine — see `Troubleshooting/GroupPolicy/AD-GroupPolicy-A.md` and `Windows/Troubleshooting/GPO-A.md` for those), not Intune-native configuration profiles (see `Intune/Troubleshooting/GP-to-CSP-A.md`), and not NTLM relay or the general Kerberos ticket lifecycle (the Kerberos Delegation topic assumes the base Kerberos exchange already works — see `Windows/Troubleshooting/Kerberos-A.md` for foundational mechanics and `Windows/Troubleshooting/NTLM-A.md`/`NTLMRelayADCS-A.md` for the separate NTLM-relay attack class).

---

## Before responding, also check

- `DFS/` — if the symptom is a SYSVOL/DFSR replication backlog itself (not GPO processing behavior), that's a separate replication system layered on top of AD — `Troubleshooting/GroupPolicy/` here covers the GPO-processing side of that same dependency
- `Intune/` — if the org has migrated or is migrating settings off Group Policy onto CSP/Intune configuration profiles (see `Intune/Troubleshooting/GP-to-CSP-B.md`)
- `EntraID/` — if the symptom involves Entra Connect, hybrid join, cloud-side identity, or the org uses Password Hash Sync/Pass-through Auth instead of federation; on-prem AD health is a prerequisite dependency for all of it
- `Windows/` — if the issue is Kerberos/NTLM auth failures on a client (not between DCs), DNS client-side resolver config, time sync at the endpoint level (this folder's DNS coverage is the AD-integrated *server* side — zones, SRV records, scavenging), or SMB signing/relay hardening (a parallel control on a different protocol from LDAP signing)
- `Security/ConditionalAccess/` — if access is being blocked by policy rather than by a broken identity/replication chain; this includes the case where AD FS issued a valid token but Entra ID's Conditional Access still blocks the resulting sign-in
- "Permissions on a Domain Admins/Administrators-equivalent account keep reverting" is `Troubleshooting/AdminSDHolder/` (SDProp ACL enforcement), not a Group Policy or delegation bug — check `Troubleshooting/KerberosDelegation/` only if the symptom is impersonation/second-hop authentication, not ACL/permission changes on the account itself
- "Branch office logon fails when the WAN is down" or "an RODC seems to be caching too many passwords" is `Troubleshooting/RODC/` (Password Replication Policy), not a replication-health problem — check `Troubleshooting/Replication/` only if the RODC itself isn't receiving any updates at all, not for password-caching-specific symptoms
- "Can we just make a dynamic group like Entra ID has?" — no native on-prem AD equivalent exists; `Troubleshooting/ShadowGroups/` is the script/tool-driven practitioner pattern that fills this gap, not a feature to look for in AD itself — see `EntraID/Troubleshooting/DynamicGroups-A.md` for the cloud-only native feature this gets confused with
- "AD LDS auth fails for some users but not others" is almost always an AD DS account-state or network-reachability problem surfacing through an AD LDS `userProxy` bind-redirection object, not an AD LDS instance fault — check `Troubleshooting/ADLDS/` before assuming AD LDS itself is broken

---

## Folder contents

| File | What it covers |
|------|---------------|
| `Troubleshooting/Replication/AD-Replication-B.md` | Hotfix: replication failures, error code lookup, common fix paths (network/DNS/time/topology/lingering objects) |
| `Troubleshooting/Replication/AD-Replication-A.md` | Deep dive: multi-master replication model, FSMO roles, USN/topology internals, FSMO seizure and lingering-object remediation playbooks |
| `Scripts/Get-ADReplicationHealth.ps1` | One-shot health check: replication summary, FSMO reachability, time sync offsets, tombstone/lingering-object risk, key DCDiag tests |
| `Troubleshooting/Trusts/AD-Trusts-B.md` | Hotfix: trust secure channel failures, SID filtering/selective auth denial patterns, common fix paths |
| `Troubleshooting/Trusts/AD-Trusts-A.md` | Deep dive: trust types, Kerberos referral path, SID filtering/selective auth internals, trust-password-reset and migration playbooks |
| `Scripts/Get-ADTrustHealth.ps1` | One-shot trust health check: attribute summary, secure channel verify, DNS SRV resolution, port reachability to trusted-domain DCs |
| `Troubleshooting/BackupRestore/AD-BackupRestore-B.md` | Hotfix: USN rollback triage, DSRM password reset, authoritative restore of deleted objects, stale-backup decision gate |
| `Troubleshooting/BackupRestore/AD-BackupRestore-A.md` | Deep dive: System State backup internals, authoritative vs. non-authoritative restore, USN rollback mechanics, DSRM, AD Recycle Bin, demote/rebuild and scoped-restore playbooks |
| `Scripts/Get-ADBackupRestoreHealth.ps1` | One-shot backup/restore posture check: backup age vs. tombstone lifetime, NTDS VSS writer state, USN rollback/lingering-object event scan, replication isolation flags, Recycle Bin status |
| `Troubleshooting/GroupPolicy/AD-GroupPolicy-B.md` | Hotfix: Event 1058/1030/1096 triage, security/WMI filter denial, GPC/SYSVOL version mismatch, slow-link/loopback quirks |
| `Troubleshooting/GroupPolicy/AD-GroupPolicy-A.md` | Deep dive: GPC/GPT two-part architecture, client-side processing pipeline internals, precedence model, DFSR-backlog and corrupt-GPO remediation playbooks |
| `Scripts/Get-GroupPolicyHealth.ps1` | One-shot GPO health check: gpresult summary, GP Operational log critical events, DFS client state, DC locator, time sync, optional GPC/GPT version comparison and DFSR backlog check |
| `Troubleshooting/DNS/AD-DNS-B.md` | Hotfix: missing/stale SRV records (DC Locator broken), over-aggressive scavenging, forwarder/root-hint failures, split-brain DNS, replication scope mismatch |
| `Troubleshooting/DNS/AD-DNS-A.md` | Deep dive: `_msdcs` zone architecture, dynamic update/registration lifecycle, replication scope internals, scavenging mechanics, rebuild/scavenging-recovery/cross-domain-scope playbooks |
| `Scripts/Get-ADDNSHealth.ps1` | One-shot DNS health check: zone inventory/scope, dynamic update mode, DC Locator SRV presence per DC, netlogon.dns comparison, scavenging config coherence, external resolution test |
| `Troubleshooting/DNS/DNSSEC-B.md` | Hotfix: signed-state/Key Master triage, DNS_ERROR_UNSECURE_PACKET diagnosis, Key Master move-vs-seize, missing parent DS record fix, the nslookup.exe testing trap |
| `Troubleshooting/DNS/DNSSEC-A.md` | Deep dive: KSK/ZSK signing architecture, in-memory-only signed-zone internals for AD-integrated zones, trust anchor distribution (forest-wide AD DS vs. TrustAnchors.dns), secure delegation/DS-record mechanics, NRPT and the non-validating-stub-resolver client model, Key Master rollover/seizure and secure-delegation playbooks |
| `Scripts/Get-DNSSECAudit.ps1` | One-shot DNSSEC posture audit: per-zone signed state, Key Master identity/status, KSK/ZSK inventory and algorithm-compatibility check, trust anchor presence, RFC 5011 rollover state, parent secure-delegation status, live Resolve-DnsName -DnssecOk signature-expiry check |
| `Troubleshooting/ADFS/ADFS-B.md` | Hotfix: farm-wide vs. extranet-only outage triage, certificate expiry/mismatch checks, relying party trust and WAP proxy trust fix paths |
| `Troubleshooting/ADFS/ADFS-A.md` | Deep dive: token-signing/decrypting cert lifecycle and rollover mechanics, relying party trust and claims rule architecture, WAP proxy trust internals, farm topology/behavior level playbooks |
| `Scripts/Get-ADFSHealth.ps1` | One-shot farm health check: certificate expiry/rollover state, relying party trust inventory, farm topology, recent AD FS/Admin log errors, optional WAP proxy trust event scan |
| `Troubleshooting/gMSA/gMSA-B.md` | Hotfix: KDS root key convergence triage, authorization-vs-installation two-step diagnosis, service credential format fixes, forest-boundary dead ends |
| `Troubleshooting/gMSA/gMSA-A.md` | Deep dive: KDS root key/GKDS password derivation architecture, two-step authorization model, rotation mechanics, forest-scoping limits, cluster-node and static-to-gMSA migration playbooks |
| `Scripts/Get-GMSAHealth.ps1` | One-shot gMSA health check: KDS root key convergence, per-gMSA delegation resolution (direct + group), password interval, optional local Test-ADServiceAccount + GMSA event log scan via `-TestLocal` |
| `Troubleshooting/dMSA/dMSA-B.md` | Hotfix: Windows Server 2025 platform-gate triage, `msDS-DelegatedMSAState` lookup table, client-side `DelegatedMSAEnabled` gap fix, migration undo/reset, BadSuccessor security-incident triage |
| `Troubleshooting/dMSA/dMSA-A.md` | Deep dive: schema-vs-functional-level nuance, two-phase migration state machine internals, two-gate authorization model (AD delegation + client policy), BadSuccessor (CVE-2025-53779) architecture, standalone/migration/security-triage playbooks |
| `Scripts/Get-DMSAHealth.ps1` | One-shot dMSA health check: Windows Server 2025 DC presence, KDS root key convergence, per-dMSA delegation resolution, migration-state interpretation with observation-window elapsed-time flagging, optional local `DelegatedMSAEnabled` + Kerberos event log scan via `-TestLocal` |
| `Troubleshooting/FineGrainedPasswordPolicies/FGPP-B.md` | Hotfix: resultant-policy lookup, invalid OU-targeting triage, precedence-collision and direct-link-override fixes, PSO delegation gaps |
| `Troubleshooting/FineGrainedPasswordPolicies/FGPP-A.md` | Deep dive: PSO/Password Settings Container architecture, precedence and direct-vs-group resolution rules, domain-wide GPO fallback, delegation model, new-tier and OU-to-group migration playbooks |
| `Scripts/Get-FGPPAudit.ps1` | One-shot PSO audit: invalid target-type detection (OU/wrong-scope-group), precedence-collision detection across all PSOs, optional per-user resultant-policy + direct-link check via `-UserName` |
| `Troubleshooting/LDAPSigning/LDAP-Signing-B.md` | Hotfix: current enforcement triage, unsigned-bind/channel-binding rejection diagnosis, client remediation vs. temporary-bridge fix paths, TLS-terminating-proxy conflict |
| `Troubleshooting/LDAPSigning/LDAP-Signing-A.md` | Deep dive: NTLM-relay-to-LDAP attack this hardening closes, signing vs. channel binding architecture, why TLS-terminating proxies break CBT by design, phased-rollout and legacy-device-exception playbooks |
| `Scripts/Get-LDAPSigningAudit.ps1` | One-shot audit across every DC: LDAPServerIntegrity/LdapEnforceChannelBinding enforcement level, cross-DC consistency check, Event 2886/2887/3039 exposure counts, current diagnostics logging level |
| `Troubleshooting/CertificateMapping/Certificate-Mapping-B.md` | Hotfix: Event 39/40/41 lookup table, SID-extension vs. explicit altSecurityIdentities diagnosis, weak-vs-strong mapping fix paths, third-party CA and Schannel/IIS fix paths |
| `Troubleshooting/CertificateMapping/Certificate-Mapping-A.md` | Deep dive: CVE-2022-34691/26931/26923 vulnerability this hardening closes, SID extension and altSecurityIdentities architecture, why the Compatibility-mode registry bypass is now permanently retired (Sept 9 2025+), PKINIT-vs-Schannel/S4U2Self distinction, fleet-wide and third-party-CA remediation playbooks |
| `Scripts/Get-CertificateMappingAudit.ps1` | One-shot audit across every DC: patch-level-derived effective enforcement state, KDC/Schannel registry values, Event 39/40/41 counts, optional fleet-wide altSecurityIdentities weak/strong classification via `-AuditUserMappings` |
| `Troubleshooting/KerberosArmoring/KerberosArmoring-B.md` | Hotfix: domain-functional-level gate triage (the #1 root cause), down-level-DC intermittent-failure diagnosis, KDC-side/client-side policy-pair fix paths, legacy-device scoped exceptions |
| `Troubleshooting/KerberosArmoring/KerberosArmoring-A.md` | Deep dive: FAST armor-key/pre-authentication protection architecture, the three-GPO independent-policy model, DAC/compound-authentication/AD FS-device-claims prerequisite relationship, domain-functional-level-raise and down-level-DC-decommission playbooks |
| `Scripts/Get-KerberosArmoringAudit.ps1` | One-shot prerequisite audit: domain functional level, DC OS-version homogeneity (down-level DC detection), optional local gpresult Kerberos/KDC policy scan via `-IncludeLocalPolicy` |
| `Troubleshooting/GroupPolicyCentralStore/GPO-CentralStore-B.md` | Hotfix: Central Store existence/staleness triage, "Extra Registry Settings" and namespace-collision/resource-not-found error diagnosis, `EnableLocalStoreOverride` check, rename-swap rebuild fix path |
| `Troubleshooting/GroupPolicyCentralStore/GPO-CentralStore-A.md` | Deep dive: ADMX/ADML-as-presentation-layer architecture, why incremental copy-in-place updates cause namespace conflicts, the rename-swap atomic-promotion migration method, clean-rebuild and governance playbooks |
| `Scripts/Get-GPOCentralStoreAudit.ps1` | One-shot audit: Central Store existence/freshness, ADMX namespace-conflict detection, ADMX/ADML pairing-gap detection per locale, optional per-DC freshness consistency via `-CheckAllDCs`, local `EnableLocalStoreOverride` check |
| `Troubleshooting/KerberosDelegation/Delegation-B.md` | Hotfix: delegation-model triage (unconstrained/constrained/RBCD), double-hop diagnosis, SPN-mismatch and RBCD-not-configured fix paths, sensitive-account/Protected-Users dead-end recognition |
| `Troubleshooting/KerberosDelegation/Delegation-A.md` | Deep dive: S4U2Self/S4U2Proxy protocol architecture, why classic KCD is intra-domain-only vs. RBCD's cross-domain capability, unconstrained-delegation risk model, phased-migration and cross-domain RBCD playbooks |
| `Scripts/Get-KerberosDelegationAudit.ps1` | One-shot domain-wide audit: unconstrained/constrained/RBCD inventory, exact authorized-target listing per object, Tier-0 group membership cross-check flagging tiering violations |
| `Troubleshooting/AdminSDHolder/AdminSDHolder-B.md` | Hotfix: reverting-permissions triage, orphaned adminCount=1 diagnosis, OU-delegation-doesn't-apply recognition, forcing an on-demand SDProp run |
| `Troubleshooting/AdminSDHolder/AdminSDHolder-A.md` | Deep dive: AdminSDHolder template/SDProp enforcement architecture, why adminCount is a side effect not the authoritative signal, why adminCount is never auto-cleared, orphaned-cleanup and template-customization playbooks |
| `Scripts/Get-AdminSDHolderAudit.ps1` | One-shot domain-wide audit: current protected-group membership baseline (transitive), every adminCount=1 object, orphaned/stale protection cross-check, optional AdminSDHolder template ACL dump |
| `Troubleshooting/RODC/RODC-B.md` | Hotfix: Allowed/Denied PRP triage, offline-branch-logon diagnosis, orphaned-Allow-entry-vs-Deny-wins recognition, the "Replicating Directory Changes All" over-permission red flag, stolen-RODC incident response |
| `Troubleshooting/RODC/RODC-A.md` | Deep dive: read-only/unidirectional replication architecture, PRP attribute model, per-RODC krbtgt isolation design, Filtered Attribute Set vs. PRP distinction, over-permission remediation and theft-response playbooks |
| `Scripts/Get-RODCPasswordReplicationAudit.ps1` | One-shot audit per RODC (or domain-wide): Allowed/Denied list membership, currently-cached credentials, Allow/Deny overlap (no-op) detection, domain-wide "Replicating Directory Changes All" over-permission security check |
| `Troubleshooting/ShadowGroups/ShadowGroups-B.md` | Hotfix: membership-drift triage, additive-only-sync-bug diagnosis, sync-account delegation checks, GPO/PSO downstream-consumer handoff recognition |
| `Troubleshooting/ShadowGroups/ShadowGroups-A.md` | Deep dive: why OUs can't be security principals, the script/tool-driven sync architecture, delegation model, greenfield-build and safe-retirement playbooks |
| `Scripts/Get-ShadowGroupDriftAudit.ps1` | One-shot (or batch, via CSV) audit per shadow group: scope validation, actual-vs-expected membership diff (stale/missing), delegated-permission reporting, optional GPO/PSO downstream-reference cross-check |
| `Troubleshooting/ADLDS/ADLDS-B.md` | Hotfix: instance service/port triage, RootDSE bind diagnosis, bind-redirection (userProxy) vs. instance-local auth isolation, replication and ADAMSync fix paths |
| `Troubleshooting/ADLDS/ADLDS-A.md` | Deep dive: AD LDS instance/service/schema architecture, configuration-set replication model, the two authentication models, ADAMSync design, instance removal playbook |
| `Scripts/Get-ADLDSInstanceAudit.ps1` | Read-only per-instance audit: service/port/RootDSE health, replication status, optional userProxy bind-redirection SID resolution and AD DS account status check |
| `Troubleshooting/PACValidation/PACValidation-B.md` | Hotfix: noPac (CVE-2021-42278/CVE-2021-42287) triage, patch-level and MachineAccountQuota checks, Event 4741/4781 exploitation-signature correlation, legacy-client Enforcement-breakage fix path, security-incident response |
| `Troubleshooting/PACValidation/PACValidation-A.md` | Deep dive: sAMAccountName spoofing + KDC name-confusion attack chain architecture, PAC_REQUESTOR/PAC_ATTRIBUTES_INFO structures, the three-phase KB5008380 rollout to permanent Enforcement, Event ID 35/36/37/38 reference, pentest-closure and incident-response playbooks |
| `Scripts/Get-PACValidationAudit.ps1` | One-shot domain-wide audit: per-DC patch/registry state, MachineAccountQuota value, Event 4741+4781 correlation sweep flagging possible active/attempted exploitation |

---

## Common entry points

- "Replication is failing between DCs" / "repadmin shows errors" → `Troubleshooting/Replication/AD-Replication-B.md`
- "A DC seems to be missing changes / objects out of sync" → `Troubleshooting/Replication/AD-Replication-B.md`
- "FSMO role holder is down, need to seize a role" → `Troubleshooting/Replication/AD-Replication-A.md` (Playbook 1)
- "Deleted objects are reappearing after a DC came back online" → `Troubleshooting/Replication/AD-Replication-A.md` (Playbook 3, lingering objects)
- "Redesigned AD Sites/Subnets, replication looks wrong now" → `Troubleshooting/Replication/AD-Replication-A.md` (Playbook 2)
- "Need a quick health snapshot before/after a change" → `Scripts/Get-ADReplicationHealth.ps1`
- "GPOs aren't applying / files not syncing" → this is SYSVOL, go to `DFS/Troubleshooting/Replication/`
- "Trust relationship failed" / "netdom trust /verify fails" → `Troubleshooting/Trusts/AD-Trusts-B.md`
- "Trust looks healthy but users still get access denied cross-domain" → `Troubleshooting/Trusts/AD-Trusts-B.md` (SID filtering / selective auth, Fix 3/Fix 4)
- "Access broke for migrated users after a domain migration" → `Troubleshooting/Trusts/AD-Trusts-A.md` (SID filtering / Playbook 2)
- "Setting up a new cross-forest trust with selective authentication" → `Troubleshooting/Trusts/AD-Trusts-A.md` (Playbook 3)
- "Quick trust health snapshot" → `Scripts/Get-ADTrustHealth.ps1`
- "Event ID 2095 / USN rollback detected" → `Troubleshooting/BackupRestore/AD-BackupRestore-B.md` (Fix 1 — urgent, isolate the DC)
- "Accidentally deleted an OU/users/group memberships, need them back" → `Troubleshooting/BackupRestore/AD-BackupRestore-B.md` (check Recycle Bin first, Fix 2)
- "DSRM password unknown, need to boot into Directory Services Restore Mode" → `Troubleshooting/BackupRestore/AD-BackupRestore-B.md` (Fix 3)
- "Is this backup even still restorable?" / backup age vs. tombstone lifetime → `Troubleshooting/BackupRestore/AD-BackupRestore-B.md` (Fix 4) or `Scripts/Get-ADBackupRestoreHealth.ps1`
- "Difference between authoritative and non-authoritative restore" → `Troubleshooting/BackupRestore/AD-BackupRestore-A.md`
- "Quick backup/restore posture check" → `Scripts/Get-ADBackupRestoreHealth.ps1`
- "GPO isn't applying" / Event 1058, 1030, or 1096 → `Troubleshooting/GroupPolicy/AD-GroupPolicy-B.md`
- "gpresult shows AD / SYSVOL Version Mismatch" → `Troubleshooting/GroupPolicy/AD-GroupPolicy-B.md` (Fix 6) — check `DFS/Troubleshooting/Replication/` if DFSR itself is backlogged
- "GPO applies to some machines in an OU but not others" → `Troubleshooting/GroupPolicy/AD-GroupPolicy-B.md` (Fix 3/Fix 4, security/WMI filtering)
- "How does GPO precedence/inheritance actually resolve?" / "why did the wrong setting win?" → `Troubleshooting/GroupPolicy/AD-GroupPolicy-A.md`
- "Loopback processing giving inconsistent results on shared machines" → `Troubleshooting/GroupPolicy/AD-GroupPolicy-A.md` (Playbook 3)
- "Quick GPO health snapshot" → `Scripts/Get-GroupPolicyHealth.ps1`
- "Replication errors mention DNS lookup failure / error 8524" → `Troubleshooting/DNS/AD-DNS-B.md`
- "A DC's SRV records disappeared, DC Locator seems broken" → `Troubleshooting/DNS/AD-DNS-B.md` (Fix 1) or `Troubleshooting/DNS/AD-DNS-A.md` (Playbook 2 if scavenging is the cause)
- "Internal AD works but Outlook/Teams/websites are broken tenant-wide" → `Troubleshooting/DNS/AD-DNS-B.md` (Fix 3 — forwarders/root hints, not AD itself)
- "Some users get random DNS failures with no clear pattern" → `Troubleshooting/DNS/AD-DNS-B.md` (Fix 4 — split-brain DNS)
- "Cross-domain DC Locator fails in a multi-domain forest" → `Troubleshooting/DNS/AD-DNS-A.md` (Playbook 3 — `_msdcs` replication scope)
- "Quick AD DNS health snapshot" → `Scripts/Get-ADDNSHealth.ps1`
- "Need to sign a zone with DNSSEC / zone won't sign" → `Troubleshooting/DNS/DNSSEC-B.md` (Fix 1)
- "Client gets DNS_ERROR_UNSECURE_PACKET" → `Troubleshooting/DNS/DNSSEC-B.md` (Triage row 4/Fix 2)
- "DNS Manager says DNSSEC settings couldn't be loaded from the Key Master" / Key Master is down → `Troubleshooting/DNS/DNSSEC-B.md` (Fix 3) or `Troubleshooting/DNS/DNSSEC-A.md` (Playbook 2 — seizure)
- "Signed a child zone but external/strict validators still don't trust it" → `Troubleshooting/DNS/DNSSEC-B.md` (Fix 4 — missing parent DS record) or `Troubleshooting/DNS/DNSSEC-A.md` (Playbook 3)
- "I tested with nslookup and DNSSEC looks broken/doesn't show anything" → `Troubleshooting/DNS/DNSSEC-B.md` (Fix 5) — nslookup.exe is not DNSSEC-aware, re-test with `Resolve-DnsName -DnssecOk`
- "Planning a KSK/ZSK rollover or moving the Key Master to a new DC" → `Troubleshooting/DNS/DNSSEC-A.md` (Playbook 1)
- "Is this the same as the DC Locator/SRV-record DNS topic?" → No — `Troubleshooting/DNS/DNSSEC-A.md` Scope & Assumptions explicitly disambiguates (integrity control vs. availability mechanics, see `Troubleshooting/DNS/AD-DNS-A.md` for the latter)
- "Quick DNSSEC posture audit across all zones" → `Scripts/Get-DNSSECAudit.ps1`
- "Everyone can't sign into M365/federated apps at once" → `Troubleshooting/ADFS/ADFS-B.md` (Fix 1 — check token-signing/decrypting cert expiry first)
- "Only external/remote users can't sign in, internal is fine" → `Troubleshooting/ADFS/ADFS-B.md` (Fix 5 — WAP proxy trust)
- "AD FS says signed in but Entra ID says user not found" → `Troubleshooting/ADFS/ADFS-A.md` (Playbook 2 — immutableid claims rule mismatch)
- "One specific app's SSO broke, everything else including M365 works" → `Troubleshooting/ADFS/ADFS-B.md` (Fix 3 — relying party trust)
- "AD FS certificate keeps expiring and breaking things repeatedly" → `Troubleshooting/ADFS/ADFS-B.md` (Fix 4 — enable AutoCertificateRollover)
- "Quick AD FS farm health snapshot" → `Scripts/Get-ADFSHealth.ps1`
- "A service/scheduled task using a gMSA won't start / logon failure" → `Troubleshooting/gMSA/gMSA-B.md`
- "Test-ADServiceAccount returns False" → `Troubleshooting/gMSA/gMSA-B.md` (Fix 2/Fix 3 — authorization vs. local installation)
- "gMSA worked fine for weeks, suddenly fails everywhere on the same day" → `Troubleshooting/gMSA/gMSA-B.md` (rotation-boundary correlation) or `Troubleshooting/gMSA/gMSA-A.md` (Phase 5)
- "Setting up gMSA for the first time in this forest" → `Troubleshooting/gMSA/gMSA-A.md` (Playbook 1)
- "Migrating a service off a static-password account onto a gMSA" → `Troubleshooting/gMSA/gMSA-A.md` (Playbook 2)
- "New cluster node can't run the clustered gMSA-based service" → `Troubleshooting/gMSA/gMSA-A.md` (Playbook 3)
- "Quick gMSA health snapshot" → `Scripts/Get-GMSAHealth.ps1`
- "A service/task using a dMSA won't log on, or dMSA creation fails outright" → `Troubleshooting/dMSA/dMSA-B.md` (Triage — confirm a Windows Server 2025 DC exists first, the #1 wrong-ticket cause)
- "What does msDS-DelegatedMSAState mean / what state is this dMSA in" → `Troubleshooting/dMSA/dMSA-B.md` (Triage table)
- "dMSA authorized in AD but the host still can't log on" → `Troubleshooting/dMSA/dMSA-B.md` (Fix 3 — client-side `DelegatedMSAEnabled` gate, disabled by default)
- "Migrating a legacy service account to dMSA" / "Start-ADServiceAccountMigration" → `Troubleshooting/dMSA/dMSA-A.md` (Playbook 2 — full state-machine walkthrough with observation-window guidance)
- "Can we convert our gMSA to a dMSA?" → No — `Troubleshooting/dMSA/dMSA-A.md` Scope & Assumptions and Learning Pointers explicitly state no conversion path exists
- "Account was just created and immediately has Domain Admin-equivalent rights" → **Stop, security incident** — `Troubleshooting/dMSA/dMSA-B.md` (Fix 6) / `Troubleshooting/dMSA/dMSA-A.md` (Playbook 4, BadSuccessor/CVE-2025-53779)
- "Quick dMSA health snapshot" → `Scripts/Get-DMSAHealth.ps1`
- "User has the wrong password policy / wrong complexity or lockout settings" → `Troubleshooting/FineGrainedPasswordPolicies/FGPP-B.md`
- "I linked a PSO to an OU and nothing happened" → `Troubleshooting/FineGrainedPasswordPolicies/FGPP-B.md` (Fix 1 — PSOs can't target OUs)
- "Two password policies seem to conflict / wrong one is winning" → `Troubleshooting/FineGrainedPasswordPolicies/FGPP-B.md` (Fix 3/Fix 4 — precedence and direct-link resolution)
- "Need to stand up a stricter password policy for admin/service accounts only" → `Troubleshooting/FineGrainedPasswordPolicies/FGPP-A.md` (Playbook 1)
- "Non-Domain-Admin can't manage PSOs despite OU delegation" → `Troubleshooting/FineGrainedPasswordPolicies/FGPP-B.md` (Fix 5)
- "Quick PSO / FGPP audit across the domain" → `Scripts/Get-FGPPAudit.ps1`
- "App/service can't bind to AD after a DC patch or GPO push" → `Troubleshooting/LDAPSigning/LDAP-Signing-B.md` (Fix 1 — check LDAPServerIntegrity first)
- "Bind fails over LDAPS/636 specifically but works fine over 389" → `Troubleshooting/LDAPSigning/LDAP-Signing-B.md` (Fix 2 — channel binding)
- "We put a load balancer in front of the DCs and LDAPS auth broke" → `Troubleshooting/LDAPSigning/LDAP-Signing-A.md` (Playbook 2 — TLS-terminating proxy breaks CBT by design)
- "Need to safely roll out LDAP signing/channel binding enforcement domain-wide" → `Troubleshooting/LDAPSigning/LDAP-Signing-A.md` (Playbook 1 — phased rollout)
- "Legacy printer/scanner/appliance can't support signing or channel binding" → `Troubleshooting/LDAPSigning/LDAP-Signing-A.md` (Playbook 3 — scoped exception)
- "Quick LDAP signing/channel binding posture check across all DCs" → `Scripts/Get-LDAPSigningAudit.ps1`
- "Smart card/WHfB/cert-based logon suddenly denied after a DC patch" → `Troubleshooting/CertificateMapping/Certificate-Mapping-B.md` (Triage — check patch date first, Full Enforcement is permanent on Sept 2025+ DCs)
- "Event ID 39, 40, or 41 in the System log (Kdcsvc source)" → `Troubleshooting/CertificateMapping/Certificate-Mapping-B.md` (interpretation table)
- "Certificate looks valid but the SID doesn't match the account (Event 41)" → `Troubleshooting/CertificateMapping/Certificate-Mapping-B.md` (Fix 3 — investigate before remediating, possible security event)
- "Certificates from our third-party/public CA keep failing authentication" → `Troubleshooting/CertificateMapping/Certificate-Mapping-B.md` (Fix 4) or `Troubleshooting/CertificateMapping/Certificate-Mapping-A.md` (Playbook 2 — bulk altSecurityIdentities rollout)
- "IIS client-certificate mapping broke but smart-card logon still works fine" → `Troubleshooting/CertificateMapping/Certificate-Mapping-A.md` (Playbook 3 — this is the separate Schannel/S4U2Self path, not PKINIT)
- "Tried resetting StrongCertificateBindingEnforcement and it did nothing" → `Troubleshooting/CertificateMapping/Certificate-Mapping-A.md` — the key is retired on any DC patched Sept 9 2025+, not a permissions issue
- "Quick certificate mapping posture check across all DCs / accounts" → `Scripts/Get-CertificateMappingAudit.ps1`
- "I configured 'Fail unarmored authentication requests' / 'Always provide claims' and nothing changed" → `Troubleshooting/KerberosArmoring/KerberosArmoring-B.md` (Fix 1 — check domain functional level first, the #1 cause)
- "DAC/claims-based file access denied but NTFS/share permissions look correct" → `Troubleshooting/KerberosArmoring/KerberosArmoring-B.md` (Fix 3 — confirm armoring transport before investigating DAC policy)
- "Armoring failures seem random / intermittent, no consistent pattern by user" → `Troubleshooting/KerberosArmoring/KerberosArmoring-B.md` (Fix 2 — down-level DC in the mix)
- "AD FS device claims never fire even though the token itself is issued" → `Troubleshooting/KerberosArmoring/KerberosArmoring-A.md` (transport prerequisite, isolate before AD FS claims-rule troubleshooting)
- "Is this the same thing as Windows Hello for Business Cloud Kerberos Trust?" → No — `Troubleshooting/KerberosArmoring/KerberosArmoring-A.md` Scope & Assumptions explicitly disambiguates
- "Quick Kerberos armoring prerequisite check (domain functional level, DC OS versions)" → `Scripts/Get-KerberosArmoringAudit.ps1`
- "Two admins see different available settings editing the same GPO" → `Troubleshooting/GroupPolicyCentralStore/GPO-CentralStore-B.md` (Triage — no Central Store, or one admin's machine is overridden)
- "A setting shows as 'Extra Registry Settings' and can't be edited" → `Troubleshooting/GroupPolicyCentralStore/GPO-CentralStore-B.md` (Fix 2)
- "GPMC/GPEdit won't open the Administrative Templates node — namespace already defined error" → `Troubleshooting/GroupPolicyCentralStore/GPO-CentralStore-B.md` (Fix 3) or `-A.md` (Remediation Playbook 2 for an urgent narrow fix)
- "'Resource ... could not be found' error editing a policy" → `Troubleshooting/GroupPolicyCentralStore/GPO-CentralStore-B.md` (Fix 4 — ADMX/ADML version mismatch)
- "A configured setting disappeared after a routine GPO edit by someone else" → `Troubleshooting/GroupPolicyCentralStore/GPO-CentralStore-B.md` (Fix 6) — the setting may still exist in `registry.pol` even though GPMC couldn't render it
- "Need to safely update/rebuild the Central Store without breaking every admin's editor" → `Troubleshooting/GroupPolicyCentralStore/GPO-CentralStore-A.md` (Remediation Playbook 1 — rename-swap method)
- "Quick Central Store / ADMX health check" → `Scripts/Get-GPOCentralStoreAudit.ps1`
- "App works fine directly on the server but fails with access denied through the web/RDS front-end" → `Troubleshooting/KerberosDelegation/Delegation-B.md` (Triage — classic double-hop)
- "We configured constrained delegation and it still doesn't work" → `Troubleshooting/KerberosDelegation/Delegation-B.md` (Fix 1/Fix 2 — confirm SPN exact match, and check whether RBCD on the backend is actually what's missing)
- "Delegation fails for one admin account but works for everyone else doing the same thing" → `Troubleshooting/KerberosDelegation/Delegation-B.md` (Fix 3 — AccountNotDelegated / Protected Users, working as designed)
- "Found a server with 'Trust this computer for delegation to any service' enabled, nobody knows why" → `Troubleshooting/KerberosDelegation/Delegation-A.md` (Remediation Playbook 2 — treat as a standing risk, migrate off unconstrained)
- "Multi-tier app spans two domains in the same forest, constrained delegation won't authorize the target" → `Troubleshooting/KerberosDelegation/Delegation-A.md` (Remediation Playbook 3 — RBCD is required, classic KCD is intra-domain only)
- "Need a domain-wide inventory of every account with any kind of delegation configured" → `Scripts/Get-KerberosDelegationAudit.ps1`
- "I changed permissions on a Domain Admins member and they disappeared an hour later" → `Troubleshooting/AdminSDHolder/AdminSDHolder-B.md` (Fix 1 — SDProp working as designed)
- "This account hasn't been an admin in months but still behaves oddly / won't inherit OU permissions" → `Troubleshooting/AdminSDHolder/AdminSDHolder-B.md` (Fix 2 — orphaned adminCount)
- "PingCastle/Purple Knight/BloodHound flagged a list of stale adminCount=1 objects" → `Troubleshooting/AdminSDHolder/AdminSDHolder-A.md` (Remediation Playbook 1) or `Scripts/Get-AdminSDHolderAudit.ps1`
- "Delegated OU admin can't manage a user that used to be a Domain Admin" → `Troubleshooting/AdminSDHolder/AdminSDHolder-B.md` (Fix 3 — inheritance disabled by design)
- "Need to validate an AdminSDHolder/group-membership change right now, not in an hour" → `Troubleshooting/AdminSDHolder/AdminSDHolder-B.md` (Fix 4) or `-A.md` (Remediation Playbook 2)
- "Need a permission to apply permanently to every protected account/group domain-wide" → `Troubleshooting/AdminSDHolder/AdminSDHolder-A.md` (Remediation Playbook 4 — edit the template, not individual objects)
- "Quick AdminSDHolder/adminCount posture audit across the domain" → `Scripts/Get-AdminSDHolderAudit.ps1`
- "Branch office user can't log in when the internet/WAN is down" → `Troubleshooting/RODC/RODC-B.md` (Fix 1 — password never cached)
- "I added a user to the Allowed RODC Password Replication list but it's still not caching" → `Troubleshooting/RODC/RODC-B.md` (Fix 2 — Deny overrides Allow, check nested Denied-group membership)
- "This RODC seems to have way more cached passwords than it should" → `Troubleshooting/RODC/RODC-B.md` (Fix 4 — check for "Replicating Directory Changes All") or `Scripts/Get-RODCPasswordReplicationAudit.ps1`
- "An RODC was stolen / physically compromised" → **Stop, security incident** — `Troubleshooting/RODC/RODC-B.md` (Fix 3) / `Troubleshooting/RODC/RODC-A.md` (Remediation Playbook 2)
- "LAPS password / BitLocker key isn't available through the RODC even though the account is Allowed" → `Troubleshooting/RODC/RODC-B.md` (Triage — Filtered Attribute Set, not a PRP issue)
- "Quick RODC Password Replication Policy audit / replication-ACL over-permission check" → `Scripts/Get-RODCPasswordReplicationAudit.ps1`
- "A group tied to an OU has stale members who left months ago" → `Troubleshooting/ShadowGroups/ShadowGroups-B.md` (Fix 2 — additive-only sync bug, the most common cause)
- "I linked a GPO or PSO directly to an OU and it didn't work like a group would" → `Troubleshooting/ShadowGroups/ShadowGroups-B.md` (Fix 6) — OUs can't be GPO security-filter principals or PSO targets, a shadow group is required
- "Sync job for this group runs fine but membership never actually updates" → `Troubleshooting/ShadowGroups/ShadowGroups-B.md` (Fix 3 — sync account lost its delegated member-attribute permission)
- "Do we have a dynamic/rule-based security group feature like Entra ID?" → No — `Troubleshooting/ShadowGroups/ShadowGroups-A.md` Scope & Assumptions explicitly disambiguates from `EntraID/Troubleshooting/DynamicGroups-A.md`
- "Need to stand up a new shadow group for GPO scoping or PSO targeting" → `Troubleshooting/ShadowGroups/ShadowGroups-A.md` (Remediation Playbook 1)
- "Quick shadow-group drift and delegation audit" → `Scripts/Get-ShadowGroupDriftAudit.ps1`
- "AD LDS instance service won't start" → `Troubleshooting/ADLDS/ADLDS-B.md` (Fix 1)
- "Application can bind to AD DS on this box but not to our AD LDS instance" → `Troubleshooting/ADLDS/ADLDS-B.md` (Fix 5 — bare hostname resolves to AD DS on a co-located DC; the app needs an explicit `host:port`)
- "AD LDS login works for most users but fails for a few, no pattern" → `Troubleshooting/ADLDS/ADLDS-B.md` (Fix 4 — check the userProxy object's referenced AD DS account status first)
- "Two AD LDS replicas stopped replicating after a service account password rotation" → `Troubleshooting/ADLDS/ADLDS-B.md` (Fix 3) / `Troubleshooting/ADLDS/ADLDS-A.md` (near-simultaneous service-account-change failure mode)
- "ADAMSync isn't picking up a recent AD DS attribute/OU change" → `Troubleshooting/ADLDS/ADLDS-B.md` (Fix 6)
- "Quick AD LDS instance health + bind-redirection proxy audit" → `Scripts/Get-ADLDSInstanceAudit.ps1`
- "Pentest/vuln scan flagged noPac or sAMAccountName spoofing" → `Troubleshooting/PACValidation/PACValidation-B.md` (Triage — confirm patch level first)
- "Legacy NAS/Linux/Samba Kerberos auth broke after a DC patch cycle" → `Troubleshooting/PACValidation/PACValidation-B.md` (Fix 2 — Enforcement-phase client compatibility, vendor fix required)
- "Unexplained computer account created then immediately renamed" → **Stop, possible security incident** — `Troubleshooting/PACValidation/PACValidation-B.md` (Fix 3) / `Troubleshooting/PACValidation/PACValidation-A.md` (Remediation Playbook 2)
- "Should we set MachineAccountQuota to 0?" → `Troubleshooting/PACValidation/PACValidation-A.md` (Remediation Playbook 1) — recommended regardless of patch status
- "Quick noPac/PAC-validation posture audit across the domain" → `Scripts/Get-PACValidationAudit.ps1`

---

## Key diagnostic commands

```powershell
repadmin /replsummary                        # domain-wide replication health, always start here
repadmin /showrepl <DC> /verbose /all         # exact error code for a failing partnership
netdom query fsmo                             # FSMO role holder identity
dcdiag /v /c /d /e                            # full DC health sweep
w32tm /query /status                          # time sync — Kerberos hard-fails past 5 min skew
```

---

## Key dependency chain

```
Network/DNS reachability between DCs
  └── Netlogon (SRV record registration, DC location)
        └── Firewall ports open (389/636/3268-3269/88/53/135 + dynamic RPC)
              └── W32Time (within 5 min of PDC Emulator — Kerberos hard limit)
                    └── Kerberos auth between DC pair
                          └── KCC/manual topology (connection objects, site links)
                                └── USN exchange → object/attribute replication
                                      └── (separate system) SYSVOL replicates via DFSR
```

**Trust dependency chain** (separate from intra-domain replication above — see `Troubleshooting/Trusts/`):

```
DNS resolution between the two domains (conditional forwarder/delegation)
  └── Network reachability (88/389/636/445/135+dynamic RPC) to a trusted-domain DC
        └── Trusted Domain Object (TDO) password in sync on both sides
              └── Netlogon secure channel (netdom trust /verify)
                    └── Kerberos referral chain across the trust
                          └── SID filtering (quarantine) + selective authentication evaluated
                                └── Normal resource ACL evaluation in the target domain
```

**Backup/restore dependency chain** (separate again — see `Troubleshooting/BackupRestore/`):

```
VSS-aware System State backup (not raw disk/VM snapshot of a live DC)
  └── Backup age within tombstone lifetime (default 180 days — hard usability ceiling)
        └── DSRM local admin password known/resettable
              └── (authoritative restore only) DC booted into DSRM
                    └── ntdsutil restore executed (authoritative or non-authoritative)
                          └── (authoritative only) version numbers incremented on restored objects
                                └── Normal replication propagates the restored state outward
```

**Group Policy processing chain** (see `Troubleshooting/GroupPolicy/`):

```
Network stack up (NLA) + DC Locator resolves a reachable, correctly-sited DC
  └── Kerberos auth succeeds (time sync dependency, same as above)
        └── SYSVOL (GPT) reachable via SMB + AD (GPC) enumerable via LDAP
              └── GPC (AD) version and GPT (SYSVOL/DFSR) version agree
                    └── Security filtering + WMI filtering pass
                          └── Loopback mode (if configured) resolves as expected
                                └── Client-Side Extensions apply settings
                                      └── Precedence resolves the final winning value
```

**AD-integrated DNS chain** (see `Troubleshooting/DNS/`):

```
DNS Server role running on enough DCs
  └── AD-integrated zone(s) present (domain zone + _msdcs.<forest-root>)
        └── Replication scope correct (Forest for _msdcs, Domain/Forest for domain zone)
              └── Dynamic Update = Secure only
                    └── Netlogon registers SRV + host records (netlogon.dns lists expected set)
                          └── Scavenging tuned wide enough not to remove live records
                                └── AD replication carries zone data to every DNS-hosting DC
                                      └── DC Locator (_ldap/_kerberos/_gc SRV) resolves correctly
                                            └── (separate path) Forwarders/root hints resolve external names
```

**DNSSEC chain** (see `Troubleshooting/DNS/DNSSEC-A.md` — an integrity control layered on top of, and independent from, the AD-integrated DNS availability chain above):

```
Zone is primary, authoritative, and unsigned
  └── Key Master designated (ONE signing DNS server per zone — not every DC)
        └── >=1 KSK (double-signature rollover) + >=1 ZSK (prepublish rollover), compatible
            crypto algorithm + zone-wide NSEC/NSEC3 choice
              └── (AD-integrated, default ON) private key replicates via AD DS to every
                  other primary DNS server authoritative for the zone
                    └── Zone signed — signed copy held IN MEMORY ONLY on AD-integrated DCs
                        (never committed to disk; file-backed zones DO write to disk)
                          └── Trust anchor distributed: forest-wide via AD DS (on a DC) or
                              TrustAnchors.dns (standalone) — RFC 5011 can automate this
                                └── (child zone only, MANUAL — never automatic) DS record
                                    added to the PARENT zone → secure delegation chain
                                      └── Recursive/validating resolver holds a current trust
                                          anchor and supports the signing algorithm
                                            └── (optional, via NRPT) client namespace rule
                                                requires DnsSecValidationRequired=True
                                                  └── Windows DNS Client is a NON-VALIDATING
                                                      stub resolver — trusts the server's AD
                                                      bit, never validates independently
```

**AD FS federation chain** (see `Troubleshooting/ADFS/`):

```
Active Directory reachable (service account/gMSA authentication)
  └── AD FS Configuration Database (WID/SQL) shared across all farm nodes
        └── Token-Signing / Token-Decrypting certificates live + service account has private-key read access
              └── Relying Party Trust object (e.g. Microsoft Office 365 Identity Platform) — enabled, correct claims rules
                    └── Claims issued (immutableid must match Entra Connect's sourceAnchor/ImmutableId)
                          └── (extranet only) Web Application Proxy — separate rolling proxy trust certificate
                                └── Relying party (Entra ID) validates signature + claims → issues its own token
                                      └── (post-token) Conditional Access evaluated — see `Security/ConditionalAccess/`
```

**gMSA dependency chain** (see `Troubleshooting/gMSA/`):

```
Forest has >=1 Windows Server 2012+ DC able to serve KDS root key material
  └── KDS Root Key created (Add-KdsRootKey) AND past its EffectiveTime (default 10h delay)
        └── AD replication has carried the root key to every DC requesting hosts contact
              └── gMSA object exists with PrincipalsAllowedToRetrieveManagedPassword delegation
                    └── Target host authorized directly or via group (group membership replicated)
                          └── Install-ADServiceAccount run locally on that host
                                └── Service/task/app pool logs on as DOMAIN\gMSA$ with a BLANK password
                                      └── msDS-ManagedPasswordInterval rotation (default 30 days), no manual sync
```

**dMSA dependency chain** (see `Troubleshooting/dMSA/` — builds on the gMSA chain above, adds a migration state machine and a client-side policy gate):

```
Forest schema extended to Windows Server 2025 level (adprep — independent of functional level)
  └── >=1 Windows Server 2025 DC exists AND is discoverable by the requesting client/server
        └── KDS Root Key created AND past its EffectiveTime (shared prerequisite with gMSA)
              └── dMSA object created (New-ADServiceAccount -CreateDelegatedServiceAccount)
                    └── PrincipalsAllowedToRetrieveManagedPassword grants the target machine identity
                          ├── (standalone) msDS-DelegatedMSAState = 3 — ready to use directly
                          └── (migration) Start-ADServiceAccountMigration links dMSA ↔ legacy account
                                (state=1; AD auto-discovers consuming hosts)
                                └── Observation window (~14d min, ~28d typical) → Complete-ADServiceAccountMigration
                                    (state=2; legacy account disabled, SPNs/delegation transferred)
  └── Client/server OS supports dMSA (Server 2025 or Windows 11 24H2+)
        AND DelegatedMSAEnabled registry/GPO policy = 1 — DISABLED BY DEFAULT, separate gate from AD authorization
              └── Service/task/app pool manually reconfigured to log on as the dMSA (never automatic)
```

**FGPP / PSO precedence chain** (see `Troubleshooting/FineGrainedPasswordPolicies/`):

```
Domain functional level >= Windows Server 2012
  └── Password Settings Container exists (hidden from default ADUC view)
        └── PSO created with Name + Precedence, msDS-PSOAppliesTo targets USERS/GLOBAL SECURITY
            GROUPS ONLY (never an OU — the #1 real-world misconfiguration)
              └── Direct-linked PSOs beat group-linked PSOs; among group-linked, lowest
                  msDS-PasswordSettingsPrecedence wins
                    └── msDS-ResultantPSO on the user object reflects the actual winner
                          └── If nothing applies: silent fallback to the domain-wide GPO-based
                              Default Domain Policy password settings
```

**LDAP signing / channel binding chain** (see `Troubleshooting/LDAPSigning/`):

```
Client initiates an LDAP bind (port 389, or LDAPS/StartTLS on 636)
  └── LDAPServerIntegrity governs signing requirement — 0/None, 1/Negotiate (unsigned still
      accepted, Event 2887 counts it), 2/Require (unsigned REJECTED)
        └── (LDAPS/StartTLS only) LdapEnforceChannelBinding governs CBT requirement — 0/Never,
            1/When supported, 2/Always (bind REJECTED without a valid, matching CBT)
              └── CBT is cryptographically tied to the exact TLS session — a TLS-terminating
                  proxy/load balancer in the path invalidates it by design, not misconfiguration
                    └── Kerberos/SASL-signed binds are unaffected by Require; simple/plaintext
                        binds (legacy LOB apps, non-Windows clients, fixed-function devices)
                        are what actually breaks when enforcement tightens
```

**Certificate mapping (KB5014754) chain** (see `Troubleshooting/CertificateMapping/`):

```
Client presents a certificate for PKINIT (smart card/WHfB/cert VPN) or TLS client auth (Schannel)
  ├── PKINIT path — KDC checks, in order:
  │     1. Does the cert carry the SID extension (OID 1.3.6.1.4.1.311.25.2)? Only added by
  │        Microsoft Enterprise CAs on online templates, unless msPKI-Enrollment-Flag
  │        0x00080000 suppresses it
  │           └── SID matches account → success | SID mismatch → Event 41, DENIED
  │     2. No extension → does the account have an explicit STRONG altSecurityIdentities
  │        mapping (X509IssuerSerialNumber/X509SKI/X509SHA1PublicKey)?
  │           └── YES → success | NO (or weak-only) → Event 39/40
  │                 └── DC patched Sept 9 2025+? → Full Enforcement is PERMANENT, DENIED
  │                     (the StrongCertificateBindingEnforcement registry key has no effect)
  └── Schannel/TLS path — separate registry key (CertificateMappingMethods), separate
        mechanism (Kerberos S4U2Self), and the relevant event log lives on the APPLICATION
        SERVER, not the client — do not conflate with the PKINIT path above
```

**Kerberos armoring (FAST) chain** (see `Troubleshooting/KerberosArmoring/`):

```
Domain functional level >= Windows Server 2012 (hard gate — stricter KDC options are
  silent no-ops below this level, the #1 real-world "configured but not working" cause)
  └── Every DC a client might reach is Server 2012+ (a single down-level DC causes
      per-DC intermittent failures, not a hard domain-wide break)
        └── KDC-side GPO (Support Dynamic Access Control and Kerberos armoring):
            Not Configured/Supported (opportunistic) — Always provide claims
            (opportunistic + claims) — Fail unarmored authentication requests (hard reject)
              └── Client-side GPO (independently configured): Kerberos client support for
                  claims, compound authentication, and Kerberos armoring — must be
                  separately enabled for a client to ever request armoring at all
                    └── (Optional, stricter) Client-side: Fail authentication requests
                        when Kerberos armoring is not available
                          └── Consumers requiring a working armored exchange: Dynamic
                              Access Control (claims, compound auth), AD FS device claims
                                (architecturally UNRELATED to Windows Hello for Business
                                Cloud Kerberos Trust, despite the shared "Kerberos" name)
```

**Group Policy Central Store / ADMX chain** (see `Troubleshooting/GroupPolicyCentralStore/` — a dependency of the GPO EDITING TOOL only, separate from the client-side processing chain above):

```
Admin opens Group Policy Management Editor on some machine
  └── EnableLocalStoreOverride on THAT machine (0/absent=default, 1=always local)
        └── (if not overridden) \\<domain>\SYSVOL\<domain>\Policies\PolicyDefinitions exists?
              ├── NO  — silent per-machine fallback to LOCAL C:\Windows\PolicyDefinitions
              │        (version varies by OS build/RSAT — different admins see different settings)
              └── YES — Central Store supplies ADMX (definitions) + locale ADML (display
                        strings) as the rendering source
                          ├── Requires: no two .admx files share a target namespace (or the
                          │             ENTIRE Administrative Templates node fails to load —
                          │             caused by incremental copy-in-place updates, never a
                          │             full clean replace)
                          ├── Requires: every .admx has a version-matched .adml in the
                          │             relevant locale folder (or resource-not-found errors)
                          └── Inherits SYSVOL/DFSR replication health/timing to reach every
                                        DC consistently (Windows Update NEVER auto-updates
                                        this store — manual, deliberate update required)
  (in parallel, always) Client-side GPO processing on end-user machines reads registry.pol
  directly and has NO dependency on ADMX/ADML/Central Store at all — a missing/broken ADMX
  affects an ADMIN'S ability to view/re-save a setting, never client-side enforcement
```

**Kerberos delegation chain** (see `Troubleshooting/KerberosDelegation/` — builds on the base Kerberos exchange in `Windows/Troubleshooting/Kerberos-A.md`):

```
User authenticates to a front-end service, which needs to act on the user's behalf
against a second, backend resource (the "double hop")
  ├── UNCONSTRAINED: TrustedForDelegation=True on front-end
  │     └── Full TGT forwarded/cached — front-end can impersonate to ANY service, unscoped
  ├── CONSTRAINED (KCD): TrustedToAuthForDelegation (S4U2Self, if needed) +
  │     msDS-AllowedToDelegateTo lists exact target SPN(s) — INTRA-DOMAIN ONLY
  └── RESOURCE-BASED (RBCD): backend's msDS-AllowedToActOnBehalfOfOtherIdentity lists the
        front-end's SID — authorized by the RESOURCE owner, works CROSS-DOMAIN in-forest
  ALL THREE unconditionally blocked if the impersonated user has AccountNotDelegated=True
  or is a member of Protected Users (which also disables NTLM fallback entirely)
```

**AdminSDHolder / SDProp chain** (see `Troubleshooting/AdminSDHolder/` — an ACL-stamping mechanism, architecturally unrelated to Kerberos delegation above despite both protecting Tier-0 accounts):

```
PDC Emulator FSMO role — SDProp evaluates and enforces ONLY here, no distributed fallback
  └── AdminSDProtectFrequency (default 3600s/60min) governs the scheduled interval
        └── Transitively expand membership of all protected groups (Domain Admins,
            Enterprise Admins, Administrators, Schema Admins, Account/Backup/Print/Server
            Operators, Replicator, Krbtgt, Domain Controllers, Read-only Domain Controllers,
            Enterprise/Key Admins)
              └── Compare each protected principal's ACL against the AdminSDHolder template
                  object's ACL (CN=AdminSDHolder,CN=System,<domain DN>)
                    └── Mismatch → ACL overwritten to match template, adminCount=1 set,
                        inheritance disabled (AreAccessRulesProtected=True) — PERMANENT until
                        MANUALLY cleared; removal from the protected group does NOT auto-clear
                        this by design (assumption: a former privileged account warrants review,
                        not silent restoration)
```

**RODC / Password Replication Policy chain** (see `Troubleshooting/RODC/` — a read-only, unidirectional replication model layered on top of the base AD replication chain above, with its own dedicated credential-caching policy):

```
At least one writable DC exists (RODC cannot be the first DC, and cannot itself be
another RODC's replication source)
  └── RODC computer account + dedicated PER-RODC krbtgt_<xxxxx> cached locally by
      default (isolated from every other RODC's krbtgt and the domain's shared krbtgt)
        └── Password Replication Policy — DENY ALWAYS WINS over Allow:
              ├── msDS-Reveal-OnDemandGroup → Allowed list (empty by default)
              └── msDS-NeverRevealGroup → Denied list (Domain Admins, Enterprise Admins,
                  Schema Admins, and other Tier-0 groups pre-populated by default)
                    └── Enforcement DEPENDS ON Enterprise Read-only Domain Controllers
                        holding ONLY "Replicating Directory Changes" (never "...All") on
                        the domain partition — if over-scoped, PRP is silently bypassed
                        domain-wide regardless of its own Allowed/Denied configuration
  └── (separate, forest-wide, NOT tunable per-RODC) Filtered Attribute Set — excludes
      specific schema attributes (LAPS password, BitLocker recovery key, etc.) from
      replicating to ANY RODC, independent of what PRP allows for the owning account
  └── At logon: cached → local auth | not cached → forward to a writable DC → (if PRP
      allows) background pull-replicate that one account's password for next time
        └── WAN link down + password never cached = hard authentication failure
```

**Shadow group chain** (see `Troubleshooting/ShadowGroups/` — a script/tool-driven convention layered on top of ordinary AD security groups, with no native AD support anywhere in this chain):

```
OU structure or attribute defines the TRUE population (the source of truth an admin
actually manages day to day)
  └── Ordinary security group created ONCE (Security/Global scope — required for both
      downstream consumers below; nothing native ties it to the OU)
        └── Sync identity delegated Write on the group's "member" attribute ONLY
            (never Domain Admin, never full group-management rights)
              └── Scheduled task / third-party tool job runs on an admin-chosen interval
                  (NO platform-enforced cadence, NO native scheduling engine)
                    └── Job RECONCILES desired-vs-actual membership (add AND remove) —
                        additive-only logic is the #1 real-world implementation defect
                          └── Membership change replicates via normal AD replication
                                └── Downstream consumers evaluate independently, on
                                    THEIR OWN schedules (shadow-group sync has ZERO
                                    self-healing if it silently stops):
                                      ├── GPO security filtering — Read + Apply Group
                                      │     Policy ACE, since an OU cannot appear there
                                      └── FGPP/PSO msDS-PSOAppliesTo — users/global
                                            security groups only, never an OU (identical
                                            root constraint to the GPO side, see
                                            Troubleshooting/FineGrainedPasswordPolicies/)
  (NOT the same as Entra ID Dynamic Groups — that's a live-evaluated, native rule
  engine with no on-prem AD DS equivalent; see EntraID/Troubleshooting/DynamicGroups-A.md)
```

**AD LDS instance chain** (see `Troubleshooting/ADLDS/` — the same directory engine as AD DS,
running independently, with its own service/port/schema/replication/auth stack per instance):

```
Windows Server + "Active Directory Lightweight Directory Services" role
(Install-WindowsFeature ADLDS — independent of whether AD DS is also present on the box)
  └── Per-instance identity, created one at a time:
        ├── ADAM_<instanceName> service (always this naming — no exceptions)
        ├── Own LDAP port + SSL port (no fixed default; 50000/50001 is a common
        │   convention when co-located with AD DS on a DC, never a hard rule)
        ├── Own database files (physically separate from NTDS.dit)
        └── Own schema + application partition(s) — changes NEVER cross instances
              └── (Optional) Configuration set — 2+ replicas of the SAME instance
                    ├── Multi-master replication, same version/timestamp
                    │     conflict rule as AD DS, but a fully independent topology
                    └── Near-simultaneous service-account changes across replicas
                          = documented replication-break trigger (sequence them)
              └── Per-OBJECT authentication model (pick one, not instance-wide):
                    ├── Instance-local principal — password lives only in AD LDS
                    └── userProxy bind-redirection object — holds a real AD DS
                        objectSid; auth is forwarded LIVE to that domain's DC
                          └── DEPENDS ON: network reachability to a DC in that
                              domain + the real account being enabled/unlocked/
                              not-expired — invisible from inside AD LDS itself,
                              the #1 source of misdiagnosed "AD LDS auth" tickets
```

**PAC requestor validation / noPac chain** (see `Troubleshooting/PACValidation/` — a KDC-side Kerberos ticket-issuance hardening, independent of but frequently bundled with Kerberos Delegation and AdminSDHolder findings in security assessments):

```
Any authenticated domain user (no special rights required)
  └── ms-DS-MachineAccountQuota > 0 (default 10) — precondition for step one, INDEPENDENT
      of patch level; hardening to 0 closes this regardless of DC patch status
        └── (CVE-2021-42278, pre-Nov-2021-patch) computer object created, sAMAccountName
            renamed to spoof an existing account (e.g. a DC's name minus trailing $)
              └── (CVE-2021-42287, pre-Nov-2021-patch) KDC name-confusion + PAC gap lets
                  the resulting TGT carry DC-equivalent privilege
                    └── Full domain compromise (DCSync-equivalent) from one unprivileged
                        starting account

PATCHED (Nov 2021 CU+, Enforcement phase permanent and unconditional since Oct 11 2022):
  KDC validates client name (cname) resolves to the SAME SID as the ticket's
  PAC_REQUESTOR structure — mismatch = ticket rejected, chain broken at the TGT stage
    (validation applies ONLY when client and KDC share the same domain — cross-trust
    forged-ticket scenarios for non-existent users are a separate, still-open boundary)
```

---

## Response format reminder

Always respond with all three layers:
1. **Hotfix** — triage commands → fix → validation proof
2. **Deep Dive** — dependency chain, FSMO/topology architecture, community findings
3. **Learning Pointers** — what to go study after this is resolved
