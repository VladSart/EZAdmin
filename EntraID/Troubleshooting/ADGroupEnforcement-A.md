# AD Group Enforcement (Cloud Sync, Preview) — Reference Runbook (Mode A: Deep Dive)
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
- AD group enforcement (preview) — the domain-controller-side mechanism that locks synced groups so only Cloud Sync (or an explicit break-glass SID) can modify them on-premises
- The `SOA-Policies` container, `CN=CloudSyncSOAPolicy` object, `msDS-Settings`, and the `msDS-ObjectSoa` group attribute
- Enforced vs. Audit mode behavior, per-DC rollout mechanics, and the Known Issue Rollback (KIR) enablement model
- `Set-CloudSyncSOAPolicy.ps1` / `Check-CloudSyncSOAPolicy.ps1` (AzureAD/EntraIDGovernance GitHub repo)
- The relationship to Microsoft Entra ID Governance's on-premises AD DS (Kerberos) app-governance scenario

**Out of scope:**
- Ordinary Cloud Sync Group Provisioning to AD DS mechanics, scale limits, and quarantine handling — see `CloudSync-A.md`/`-B.md`
- Entra Connect Sync → Cloud Sync migration — see `CloudSyncMigration-A.md`/`-B.md`
- Group Writeback v2 → Cloud Sync migration — see `GroupWritebackMigration-A.md`/`-B.md`
- General AD RBAC / delegation design (this feature is additive to, not a replacement for, existing delegation)
- User provisioning to AD DS — not supported by the Cloud Sync provisioning agent at all as of this writing, enforcement or otherwise

**Assumptions:**
- Cloud Sync Group Provisioning to AD DS is already configured and healthy for the group(s) in question
- You have Domain Admin rights to run `Set-CloudSyncSOAPolicy.ps1` and to install DC-level updates
- At least one domain controller runs Windows Server 2022 or Windows Server 2025 and holds (or can hold) the PDCe role
- This is being evaluated or piloted under the Azure Preview Supplemental Terms — not yet treated as a finished, fully-supported GA feature

---
## How It Works

<details><summary>Full architecture — the SOA-Policies container, per-DC enablement, and the enforcement decision path</summary>

### Why this exists

Cloud Sync's Group Provisioning to AD DS (GPAD, covered in `CloudSync-A.md`) lets a cloud-managed security group be recreated and kept in sync inside on-premises AD DS, typically so a legacy Kerberos-authenticating application can keep reading group membership the way it always has while the actual group lifecycle moves to Entra ID. The problem GPAD alone doesn't solve: nothing stops an on-premises administrator with ordinary AD permissions from directly editing that group in AD — adding a member Entra ID doesn't know about, removing one it does, or deleting the object outright. Because AD's own RBAC model has no concept of "this object is now owned by an external system," this creates a silent reconciliation gap and, more importantly for governance-minded engagements, a compliance gap: access nominally "governed by Entra ID" can be quietly altered by a completely separate authorization path that Entra ID has no visibility into.

AD group enforcement closes that specific gap. It does not change AD's RBAC model — a DC-side policy sits *in front of* the normal write path for objects explicitly marked as enforced, and rejects writes from any security principal not on an explicit allow-list, regardless of what that principal's ordinary AD permissions would otherwise allow.

### The SOA-Policies container

Enabling the feature on a domain controller creates a new container:

```
CN=SOA-Policies,CN=System,DC=<domain>
    └── CN=CloudSyncSOAPolicy
          ├── msDS-Settings   (multi-valued string: authorized bypass SIDs)
          └── (mode is tracked alongside this object — Enforced | Audit)
```

This container is *not* created by installing Cloud Sync, and not by converting a group's Source of Authority to the cloud. It is created only after the DC-level enablement sequence below runs successfully, and only appears on the DC(s) where that sequence ran — it is not automatically domain-wide.

### Per-DC enablement — the two-part Known Issue Rollback model

The enforcement code ships **dormant** inside a regular cumulative Windows Update for Windows Server 2022 and Windows Server 2025 (minimum `ntdsai.dll` versions: `10.0.20348.5257` for 2022, `10.0.26100.32995` for 2025). Installing the CU alone does nothing observable. A separate Group Policy MSI — one per OS version, hosted at `aka.ms/ADEnforcementGPMSI2022` / `2025` — flips the dormant code on using the same Known Issue Rollback (KIR) mechanism Microsoft uses to ship features that can be toggled off quickly if a regression is found post-release. This two-step, two-artifact design (a code-carrying CU plus a separate enablement switch) is deliberate: it lets Microsoft ship the capability broadly in a normal servicing channel while keeping the actual behavioral change opt-in and independently reversible without a CU rollback.

Critically, **this enablement is per-domain-controller**, not per-domain or per-forest. A write that lands on a DC that never received the CU+MSI is processed exactly as it would have been before this feature existed — the write succeeds, and it replicates outward from that DC as an authoritative change. For full protection, every DC that could plausibly receive a direct write for a protected object needs the same CU, the same MSI, and a restart. A partial rollout is not "partial protection, spread thin" — it is a specific, exploitable gap: any principal who can identify (or simply stumble onto) an un-updated DC bypasses the entire policy for that write.

### Enforced vs. Audit mode

The policy mode is a property of the `CloudSyncSOAPolicy` object, set by `Set-CloudSyncSOAPolicy.ps1 -EnforcementMode <Enforced|Audit>` (Domain Admin credentials required):

| Mode | Behavior |
|---|---|
| **Enforced** | LDAP modify operations against marked objects are rejected outright for any SID not present in `msDS-Settings`. Recycle Bin restores are also blocked for non-authorized SIDs. LDAP **Add** operations are still permitted even if the add itself sets `msDS-ObjectSoa` — the block is on modifying an *already-marked* object, not on creating one. |
| **Audit** | No writes are blocked. Every write to a marked object made by a non-authorized SID is instead logged to the Directory Services event log (requires the Security Diagnostics registry value set to `1` first). This is the "what-if" mode — run it before flipping to Enforced in any environment where an unexpected block could disrupt a legitimate, undocumented on-prem process. |

### The msDS-ObjectSoa marking

Enforcement applies **only** to AD objects carrying `msDS-ObjectSoa = Cloud`. This attribute is set through ordinary Cloud Sync attribute mapping (constant or expression-based), the same mechanism already used for every other GPAD attribute mapping. It is explicitly **not** set automatically when a group's Source of Authority is converted to the cloud in Entra ID — SOA conversion determines who owns the group's *lifecycle* (create/update/delete decisions originate in Entra ID going forward); `msDS-ObjectSoa` separately determines whether the on-prem *copy* of that group is write-protected at the DC level. An administrator can have a fully cloud-managed group (SOA converted) with zero on-prem write protection, because the two are independent, sequential configuration steps.

### Break-glass access

`msDS-Settings` is the single authorization list for bypassing an Enforced-mode policy. It is edited directly via ADSI Edit — there is no Entra admin center surface for it in this preview. An **empty** `msDS-Settings` list does not mean "the policy has no bypass" — the current documented behavior is that an empty list makes the policy **effectively inert entirely** ("If no SIDs are in the policy, the policy is effectively off. Any user with permission to update the group can update it as if the policy weren't present"). This is a meaningfully different failure mode than a normal deny-all-by-default access control list, and needs to be understood before deploying to production: forgetting to populate `msDS-Settings` at all is not "maximally locked down," it is "not enforcing."

### Known preview limitations (documented by Microsoft, not inferred)

- **Groups only.** The underlying enforcement mechanism (`msDS-ObjectSoa`) can technically apply to both groups and users, but user provisioning to AD through the Cloud Sync provisioning agent doesn't exist as a shipped capability yet — so user-object enforcement has nothing to attach to in practice.
- **No deletion block.** Enforced mode blocks modify and restore; it does not currently block delete.
- **SOA conversion does not auto-enforce.** Already covered above — worth restating because it is the most common misconfiguration.
- **Per-DC, not global, by default.** Already covered above — the most common false "it isn't working" report.

</details>

---
## Dependency Stack

```
Layer 4:  Cloud Sync attribute mapping sets msDS-ObjectSoa = "Cloud" on the target group
              ↑ depends on
Layer 3:  CN=CloudSyncSOAPolicy configured (mode: Enforced/Audit; msDS-Settings populated
          with at least one break-glass SID before going to Enforced in production)
              ↑ depends on
Layer 2:  CN=SOA-Policies,CN=System,<domain DN> container exists on the relevant DC(s)
              ↑ depends on
Layer 1:  Every DC that must enforce has BOTH:
            - the cumulative Windows Update (ntdsai.dll >= documented minimum)
            - the matching Group Policy enablement MSI, installed, DC restarted
              ↑ depends on
Layer 0:  Domain controller OS = Windows Server 2022 or Windows Server 2025
          (PDCe role required for the initial container-creation step)
              ↑ depends on
Layer -1: Cloud Sync Group Provisioning to AD DS already configured and healthy
          (see CloudSync-A.md — this feature has no independent existence without it)
```

A gap at any layer produces the same user-visible symptom — "the group wasn't protected" — with a completely different root cause and fix. Diagnosis always works top-down from Layer 4.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| On-prem write to a supposedly-protected group succeeds when it shouldn't | Mode is Audit, not Enforced; OR write landed on an un-updated DC; OR `msDS-ObjectSoa` was never set | Check policy mode, DC `ntdsai.dll` version, and group's `msDS-ObjectSoa` attribute in that order |
| "Enforcement isn't blocking anything at all" across the whole environment | `msDS-Settings` is empty — policy is present but inert by design | Read `msDS-Settings` on `CN=CloudSyncSOAPolicy`; an empty list means off, not deny-all |
| Legitimate emergency change blocked with no way in | No break-glass SID configured, or the SID used doesn't match `msDS-Settings` | ADSI Edit → `CN=SOA-Policies` → `CN=CloudSyncSOAPolicy` → `msDS-Settings` |
| Inconsistent behavior between sites/DCs for the same group | Uneven CU+MSI rollout across the DC fleet | Run `Check-CloudSyncSOAPolicy.ps1` against every DC in scope, not just the PDCe |
| SOA-Policies container never appears after CU install | MSI enablement step skipped, or DC not yet restarted after MSI | Confirm MSI install event in the DC's Application log; confirm restart occurred after, not before, MSI install |
| Group deleted from on-prem despite Enforced mode | Expected — deletion is not currently blocked by this preview | Restore from AD Recycle Bin; re-verify `msDS-ObjectSoa` survived the restore |
| Audit mode configured but no events appear in the log | Security Diagnostics registry value not set to enable this specific logging | Set the diagnostic logging level per MS Docs "AD and LDS diagnostic event logging" before relying on Audit-mode telemetry |

---
## Validation Steps

1. **Confirm DC-level enablement, per DC, not just the PDCe:**
   ```powershell
   (Get-Item C:\Windows\System32\ntdsai.dll).VersionInfo.FileVersion
   ```
   Expected good output: version at or above the documented minimum for that OS. Bad output: a version present but below minimum (CU installed, MSI not) or the file/DC simply predating any of this (older CU baseline entirely).

2. **Confirm the container and policy object exist:**
   ```powershell
   Get-ADObject -Identity "CN=CloudSyncSOAPolicy,CN=SOA-Policies,CN=System,$((Get-ADDomain).DistinguishedName)" -Properties *
   ```
   Expected good output: object returned with a populated `msDS-Settings` (if any break-glass accounts were configured) and a determinable mode. Bad output: `ADIdentityNotFoundException` — enablement never completed on this DC.

3. **Confirm mode using the official checker script rather than inferring it from behavior:**
   ```powershell
   .\Check-CloudSyncSOAPolicy.ps1
   ```
   Expected good output: explicit pass/fail plus mode reported for the local DC. This is more reliable than reading `msDS-Settings` directly, since mode storage internals aren't guaranteed stable across preview iterations.

4. **Confirm a specific group is actually marked:**
   ```powershell
   Get-ADGroup -Identity "<GroupName>" -Properties msDS-ObjectSoa | Select-Object Name, msDS-ObjectSoa
   ```
   Expected good output: `msDS-ObjectSoa = Cloud`. Bad output: attribute absent — the Cloud Sync attribute-mapping step (Fix 2 in Mode B) was never completed for this group.

5. **Live-fire test in Audit mode before ever enabling Enforced in production:**
   Make a deliberate unauthorized on-prem change to a marked test group; confirm it succeeds (expected in Audit) and that an event lands in the Directory Services log. This validates the full chain — container, mode read, attribute marking, and logging — without any risk of blocking a real workflow.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Pre-deployment (before touching any production DC):**
- Confirm which DCs are candidates for the PDCe role and plan the CU+MSI rollout order — PDCe first (required for initial container creation), then remaining DCs.
- Identify and pre-stage at least one break-glass account and its SID before any group is set to Enforced mode.
- Pilot in Audit mode against a disposable test group in a non-production OU first.

**Phase 2 — Rollout:**
- Install CU, then matching MSI, then restart — in that exact order — on each targeted DC.
- Verify container creation per DC (allow 5-10 minutes post-restart) before moving to the next DC.
- Do not flip any group to `msDS-ObjectSoa = Cloud` until every DC expected to enforce has completed Phase 2.

**Phase 3 — Enable and validate:**
- Set policy mode to Audit first tenant-wide (or per-DC, depending on scope), even if the eventual goal is Enforced everywhere.
- Mark a small pilot set of groups via Cloud Sync attribute mapping.
- Run the live-fire Audit-mode test (Validation Step 5) and confirm expected logging behavior before proceeding.

**Phase 4 — Cutover to Enforced:**
- Re-run `Set-CloudSyncSOAPolicy.ps1 -EnforcementMode Enforced` against each DC in scope.
- Re-test with the same deliberate unauthorized-change probe used in Phase 3 — this time expecting a block, not a log entry.
- Confirm the break-glass account can still successfully modify a marked group.

**Phase 5 — Ongoing operations:**
- Treat `msDS-Settings` membership changes as privileged-access events requiring the same change-control rigor as any other break-glass account grant.
- Re-run `Check-CloudSyncSOAPolicy.ps1` after any DC patching cycle, DC decommission, or new DC promotion — new DCs do not inherit enforcement automatically and need the full Phase 2 sequence themselves.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Full pilot-to-production rollout for a single domain</summary>

1. Select the PDCe and confirm its OS is Windows Server 2022 or 2025.
2. Install the latest cumulative Windows Update; restart.
3. Install the matching Group Policy MSI (`aka.ms/ADEnforcementGPMSI2022` or `2025`); restart again.
4. Confirm `CN=SOA-Policies` exists (allow up to 10 minutes).
5. Download `Set-CloudSyncSOAPolicy.ps1` and `Check-CloudSyncSOAPolicy.ps1` from the [AzureAD/EntraIDGovernance](https://github.com/AzureAD/EntraIDGovernance) repository — verify the download source matches the official repo before running anything with Domain Admin credentials.
6. Run `Check-CloudSyncSOAPolicy.ps1` to confirm enablement on the PDCe.
7. Run `Set-CloudSyncSOAPolicy.ps1 -EnforcementMode Audit`.
8. Add a designated break-glass account's SID to `msDS-Settings` via ADSI Edit.
9. Repeat steps 2-3 (CU + MSI + restart) on every remaining DC in the domain.
10. In Cloud Sync, add `msDS-ObjectSoa = Cloud` as a constant or expression-based attribute mapping for a small pilot group set; re-provision.
11. Validate with a deliberate on-prem test change (expect: allowed + logged).
12. Once satisfied, re-run `Set-CloudSyncSOAPolicy.ps1 -EnforcementMode Enforced` on every DC.
13. Re-validate (expect: blocked for non-authorized SIDs, allowed for the break-glass SID).
14. Expand the `msDS-ObjectSoa` mapping to the full intended group scope.

**Rollback:** set mode back to `Audit` (non-destructive, immediate) or uninstall the Group Policy MSI on affected DCs (KIR-style — turns the dormant code back off without removing the underlying CU).

</details>

<details><summary>Playbook 2 — Emergency on-prem change to an Enforced group with no pre-staged break-glass account</summary>

1. Confirm this is genuinely urgent — the standing fix is to pre-stage a break-glass account (Playbook 1, step 8) well before this situation arises.
2. Obtain Domain Admin credentials and access to ADSI Edit on the PDCe.
3. Navigate to `CN=SOA-Policies` > `CN=CloudSyncSOAPolicy`, edit `msDS-Settings`, add the SID of the account that will perform the emergency change.
4. Perform the change using that account.
5. **Immediately** remove the SID from `msDS-Settings` once the change is complete — do not leave an ad hoc emergency grant standing.
6. File a follow-up action to add a permanent, properly-governed break-glass account so this playbook doesn't need to be repeated under time pressure.

**Rollback:** removing the SID from `msDS-Settings` fully reverts the emergency grant; no other state changes are made by this playbook.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects AD group enforcement (Cloud Sync preview) state for escalation or audit.
#>
$domainDN = (Get-ADDomain).DistinguishedName
$report = [ordered]@{
    Timestamp        = Get-Date -Format o
    DCName           = $env:COMPUTERNAME
    NtdsaiVersion    = (Get-Item C:\Windows\System32\ntdsai.dll).VersionInfo.FileVersion
    SOAPoliciesExist = [bool](Get-ADObject -Identity "CN=SOA-Policies,CN=System,$domainDN" -ErrorAction SilentlyContinue)
}
$policyObj = Get-ADObject -Identity "CN=CloudSyncSOAPolicy,CN=SOA-Policies,CN=System,$domainDN" -Properties msDS-Settings -ErrorAction SilentlyContinue
$report.PolicyObjectExists = [bool]$policyObj
$report.AuthorizedBypassSIDCount = if ($policyObj) { @($policyObj.'msDS-Settings').Count } else { 0 }

# Enumerate all groups currently marked for enforcement
$markedGroups = Get-ADGroup -Filter { msDS-ObjectSoa -eq "Cloud" } -Properties msDS-ObjectSoa |
    Select-Object Name, DistinguishedName, msDS-ObjectSoa

$report | Format-List
$markedGroups | Format-Table -AutoSize
$markedGroups | Export-Csv -Path ".\ADGroupEnforcement-EvidencePack-$(Get-Date -Format yyyyMMdd-HHmmss).csv" -NoTypeInformation
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-ADObject -Identity "CN=SOA-Policies,CN=System,$((Get-ADDomain).DistinguishedName)"` | Confirm the policy container exists on this DC |
| `(Get-Item C:\Windows\System32\ntdsai.dll).VersionInfo.FileVersion` | Confirm enforcement code minimum version on this DC |
| `.\Check-CloudSyncSOAPolicy.ps1` | Official pass/fail + mode check for the local DC |
| `.\Set-CloudSyncSOAPolicy.ps1 -EnforcementMode Enforced\|Audit -Credential (Get-Credential)` | Set or change policy mode (Domain Admin required) |
| `Get-ADGroup -Identity "<name>" -Properties msDS-ObjectSoa` | Check whether a specific group is marked for enforcement |
| `Get-ADGroup -Filter { msDS-ObjectSoa -eq "Cloud" }` | Enumerate every group currently marked |
| ADSI Edit → `CN=SOA-Policies` → `CN=CloudSyncSOAPolicy` → `msDS-Settings` | Read/edit the break-glass SID allow-list |
| `Get-WinEvent -LogName "Directory Service"` | Review Audit-mode logged unauthorized-change events |
| `Restore-ADObject` | Restore an enforced group deleted on-prem (deletion is not blocked by this preview) |
| `repadmin /showrepl <DC>` | Confirm whether a specific DC has received/replicated relevant policy objects |

---
## 🎓 Learning Pointers

- **The two-artifact enablement model (dormant CU code + separate MSI switch) is a deliberate, reversible-by-design rollout pattern**, not an unusual packaging accident — recognizing this pattern (also called Known Issue Rollback elsewhere in Microsoft's servicing model) speeds up diagnosis of "the update is installed but nothing changed" tickets generally, beyond just this feature. [Microsoft Learn: Configure AD group enforcement](https://learn.microsoft.com/en-us/entra/identity/hybrid/cloud-sync/how-to-ad-group-enforcement)

- **An empty allow-list here means "off," not "deny all."** This is the inverse of how most admins instinctively read an empty ACL, and is the single highest-value fact for avoiding a false sense of security during a partial rollout.

- **This feature is a governance/compliance control, not a sync-conflict-prevention control.** It doesn't make GPAD more reliable or resolve reconciliation races any differently than before — it exists to answer "can we prove only Entra ID changed this group" for audit purposes. Frame client conversations accordingly; it's not a fix for GPAD flakiness (see `CloudSync-B.md` for that).

- **Enforcement scope (per-DC) and provisioning scope (per-tenant, via Cloud Sync configuration) are independent axes.** A group can be perfectly in-scope for GPAD provisioning while sitting completely unprotected by enforcement, simply because the DC it happens to be written against was never updated. Always validate both axes separately during a pilot.

- **This sits inside the broader Microsoft Entra ID Governance story for on-premises Kerberos apps** — Microsoft's own "Govern on-premises Active Directory Domain Services based apps (Kerberos) using Microsoft Entra ID Governance" scenario builds directly on top of AD group enforcement plus GPAD. If a client's actual goal is full lifecycle governance of a legacy Kerberos app's access (not just tamper-evidence on one group), point them at that broader Governance scenario rather than treating enforcement as the complete answer on its own.

- **As a preview feature, treat published minimum version numbers and behavior as a snapshot, not a permanent contract** — re-verify against the current Microsoft Learn page before any new client engagement, the same discipline this repo already applies to other preview/rapidly-evolving topics (e.g. Global Secure Access MCP Firewall, Catalog Access Reviews).
