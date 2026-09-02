# AD Group Enforcement (Cloud Sync, Preview) — Hotfix Runbook (Mode B: Ops)
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

This is **not** the same feature as ordinary Group Provisioning to AD DS (see `CloudSync-B.md`). AD group enforcement is a **preview** add-on that locks a synced group so only the Cloud Sync provisioning service (or an explicit break-glass SID) can modify it on-premises — an on-prem admin's own AD RBAC permissions stop mattering for that specific object. Run these on a domain controller (ideally the PDCe):

```powershell
# 1. Does the SOA-Policies container even exist? If not, the feature was never enabled on this DC.
Get-ADObject -Identity "CN=SOA-Policies,CN=System,$((Get-ADDomain).DistinguishedName)" -ErrorAction SilentlyContinue

# 2. What mode is the policy in, and which SIDs are authorized to bypass it?
$policy = Get-ADObject -Identity "CN=CloudSyncSOAPolicy,CN=SOA-Policies,CN=System,$((Get-ADDomain).DistinguishedName)" `
    -Properties msDS-Settings -ErrorAction SilentlyContinue
$policy.'msDS-Settings'

# 3. Is the enforcement code actually present and enabled on THIS DC (not just the PDCe)?
(Get-Item C:\Windows\System32\ntdsai.dll).VersionInfo.FileVersion
# Windows Server 2022 needs >= 10.0.20348.5257 ; Windows Server 2025 needs >= 10.0.26100.32995
# A present-but-below-minimum version means the update is installed but too old -- enforcement is NOT active.

# 4. Is a specific group actually marked for enforcement?
Get-ADGroup -Identity "<GroupName>" -Properties msDS-ObjectSoa | Select-Object Name, msDS-ObjectSoa

# 5. Any blocked-change audit events? (Audit mode only -- Enforced mode blocks silently at the DC, no app-visible error)
Get-WinEvent -LogName "Directory Service" -MaxEvents 50 |
    Where-Object { $_.Message -match "SOA|msDS-ObjectSoa|enforcement" }
```

| What you see | What it means |
|---|---|
| `SOA-Policies` container doesn't exist on this DC | Enforcement was never installed here -- the OS update + Group Policy MSI step was skipped or hasn't propagated to this DC yet (Fix 1) |
| Container exists, but `ntdsai.dll` version is below the minimum | Cumulative update installed but the enablement MSI wasn't, or an older update shipped after and regressed the DLL version (Fix 1) |
| Group has no `msDS-ObjectSoa` attribute | The group was never marked for enforcement -- converting SOA to cloud does **not** auto-enforce it; this is a separate, deliberate step (Fix 2) |
| On-prem admin change to a marked group went through when it should have been blocked | Either the policy is in **Audit** (not Enforced) mode, or the change landed on a DC where enforcement isn't installed (Fix 3) |
| Legitimate on-prem emergency change to an enforced group is blocked and there's no working break-glass account | No SID was ever added to `msDS-Settings`, or the SID added doesn't match the account actually being used (Fix 4) |
| A ticket says "user provisioning to AD is silently ignoring `msDS-ObjectSoa`" | Expected in this preview -- **only group objects are supported**; user provisioning to AD via the agent doesn't exist yet at all (Fix 5) |
| Deleted/restored an enforced group from the Recycle Bin without going through Cloud Sync | Expected -- Enforced mode blocks LDAP *modify* and Recycle Bin *restore*, but does **not** block outright deletion (Fix 6) |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Cloud Sync Group Provisioning to AD DS (must already be configured and working -- see CloudSync-B.md)
    |
    +-- PDCe role DC: Windows Server 2022/2025
    |       |
    |       +-- Cumulative Windows Update installed
    |       |     (min ntdsai.dll: 2022 = 10.0.20348.5257 | 2025 = 10.0.26100.32995)
    |       |
    |       +-- Matching Group Policy enablement MSI installed + DC restarted
    |             (KIR-style: code ships dormant in the CU, MSI flips it on)
    |                   |
    |                   v
    |             CN=SOA-Policies,CN=System,<domain DN> container created (5-10 min after restart)
    |                   |
    |                   +-- msDS-Settings  -> list of authorized bypass SIDs (empty = policy effectively OFF)
    |                   +-- policy mode    -> Enforced | Audit
    |
    +-- EVERY other DC that should also enforce needs the SAME CU + MSI + restart
    |     (a change landing on an un-updated DC is NOT blocked -- partial rollout = partial protection)
    |
    +-- Set-CloudSyncSOAPolicy.ps1 (AzureAD/EntraIDGovernance GitHub repo) run with Domain Admin creds
    |     -> writes the mode into CN=CloudSyncSOAPolicy
    |
    +-- Group itself must carry msDS-ObjectSoa = "Cloud"
          (set via Cloud Sync attribute mapping, NOT automatic on SOA conversion)
                |
                v
          Enforcement applies ONLY to that specific group object
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm the feature is installed where the change actually happened.** Enforcement is per-DC, not domain-wide by default. A blocked-change complaint from one site and a working-change report from another usually means uneven CU/MSI rollout, not a policy bug. Run the version check (Triage #3) against every DC in scope, or use `Check-CloudSyncSOAPolicy.ps1` (same GitHub repo) which reports pass/fail per DC directly.

2. **Confirm the policy mode.** Read `msDS-Settings`/mode off `CN=CloudSyncSOAPolicy`. If Audit, on-prem changes are allowed by design -- enforcement isn't broken, it just isn't enforcing yet. Expected behavior in Audit mode: the change succeeds AND an event is logged (requires Security Diagnostics registry value set to `1` first -- see MS Docs "AD and LDS diagnostic event logging").

3. **Confirm the group is actually in scope.** `msDS-ObjectSoa` must be present and set to `Cloud`. Converting a group's Source of Authority to the cloud is a separate action from marking it for enforcement -- this is the single most common "why isn't this working" gap. SOA conversion alone does nothing here.

4. **If Enforced mode is confirmed active on the right DC and the group is correctly marked, but a change still went through:** check whether it was a deletion (not blocked by design in this preview) or a Recycle Bin restore that bypassed a DC without the update.

5. **If a legitimate change needs to happen on-prem right now and enforcement is correctly blocking it:** this is what the break-glass mechanism exists for -- go to Fix 4, don't disable the whole policy for a single change.

---
## Common Fix Paths

<details><summary>Fix 1 — SOA-Policies container missing or ntdsai.dll below minimum version</summary>

Install (or reinstall) in the correct order -- the CU alone does nothing until the MSI flips the feature on:

```powershell
# On the target DC, after installing the latest cumulative Windows Update and restarting:
# Windows Server 2022: https://aka.ms/ADEnforcementGPMSI2022
# Windows Server 2025: https://aka.ms/ADEnforcementGPMSI2025
# Install the matching MSI, then restart the DC again.

# Verify:
(Get-Item C:\Windows\System32\ntdsai.dll).VersionInfo.FileVersion

# Confirm the container appeared (allow 5-10 minutes after restart):
Get-ADObject -Identity "CN=SOA-Policies,CN=System,$((Get-ADDomain).DistinguishedName)"
```

For a disposable test/lab environment, a Windows Server Insider Preview build has the feature enabled out of the box -- skip the MSI step entirely there. Do not use Insider Preview builds in production.

**Rollback:** the MSI uses a Known Issue Rollback (KIR) enablement model -- uninstalling the MSI turns the code back off without requiring the CU itself to be removed.

</details>

<details><summary>Fix 2 — Group isn't actually marked for enforcement</summary>

Marking happens through Cloud Sync attribute mapping, not through the SOA-conversion UI:

1. In the Cloud Sync group-provisioning-to-AD configuration, edit attribute mappings.
2. Add `msDS-ObjectSoa` as a target attribute with value `Cloud` -- either as a constant (applies to every group in scope) or via an expression (applies to a subset).
3. Re-provision the group (on-demand or wait for the next cycle).
4. Confirm on the DC:

```powershell
Get-ADGroup -Identity "<GroupName>" -Properties msDS-ObjectSoa | Select-Object Name, msDS-ObjectSoa
```

No rollback concern -- removing the mapping and re-provisioning clears the attribute and the group returns to normal AD RBAC.

</details>

<details><summary>Fix 3 — Enforced mode not actually blocking changes</summary>

Two independent things to check in order:

```powershell
# a) Confirm the policy mode is actually Enforced, not Audit
.\Check-CloudSyncSOAPolicy.ps1   # reports mode + enablement state for the local DC

# b) If mode is confirmed Enforced on this DC, find out which DC the change actually replicated FROM
#    A change made against a DC that itself doesn't have the update installed is never blocked at the source.
repadmin /showrepl <affected DC> | Select-String "SOA-Policies"
```

If mode was Audit and someone expected Enforced: re-run `Set-CloudSyncSOAPolicy.ps1 -EnforcementMode Enforced`. This requires Domain Admin credentials and takes effect immediately on the DC it's run against -- replicate/repeat on every DC in scope.

</details>

<details><summary>Fix 4 — No working break-glass account for an enforced group</summary>

```
1. Open ADSI Edit on the PDCe.
2. Navigate to CN=SOA-Policies > CN=CloudSyncSOAPolicy.
3. Open Attribute Editor, edit msDS-Settings (multi-valued string).
4. Add the SID of the account that needs emergency on-prem write access.
5. Save. The account can now modify enforced groups directly in AD.
```

Get the SID first: `(Get-ADUser -Identity "<account>").SID.Value`

**This is a standing bypass, not a one-time token** -- treat it the same as any other privileged-access break-glass account: named, monitored, and removed from `msDS-Settings` again once the emergency work is done. An empty `msDS-Settings` list does not mean "nobody can bypass" -- it means the *policy itself* is effectively off, which is different from a populated allow-list.

</details>

<details><summary>Fix 5 — Ticket assumes user provisioning to AD respects this policy</summary>

No fix needed -- this is expected preview behavior, not a bug. Set expectations with the requester: only **group** objects are supported by AD group enforcement in this preview. User provisioning to AD via the Cloud Sync provisioning agent does not exist as a feature at all yet (separate from enforcement). If the underlying ask is "lock down a user object from on-prem tampering," there is currently no Cloud Sync mechanism for that -- escalate as a feature gap, don't try to force `msDS-ObjectSoa` onto a user object.

</details>

<details><summary>Fix 6 — Enforced group was deleted (not just modified) from on-prem</summary>

Expected limitation, not a bug: Enforced mode blocks LDAP *modify* operations and Recycle Bin *restores*, but currently does **not** block outright deletion of the object. If a group protected by this policy was deleted on-prem:

1. Restore from the AD Recycle Bin as usual (`Restore-ADObject`) -- the restore itself isn't blocked by policy on the way back in, only ongoing modification afterward is.
2. Re-verify `msDS-ObjectSoa` survived the restore; if not, the group has effectively lost enforcement and Fix 2 needs to be re-run.
3. If Cloud Sync's own provisioning cycle recreates the group before you can restore from the Recycle Bin, treat the recreated object as authoritative and reconcile membership manually -- don't restore an orphaned duplicate on top of it.

No native rollback path exists for the deletion gap itself; this is a documented, current-preview limitation to plan around (break-glass account management and change-control discipline are the only mitigations until Microsoft closes the gap).

</details>

---
## Escalation Evidence

```
AD GROUP ENFORCEMENT (CLOUD SYNC PREVIEW) -- ESCALATION TEMPLATE
================================================================
Date/Time of issue:
Domain / forest:
Affected group (DN):
Expected behavior:                    [ ] Change should have been blocked   [ ] Change should have been allowed
Actual behavior:

--- Policy state (from PDCe) ---
SOA-Policies container present:       [ ] Yes  [ ] No
Policy mode (Enforced/Audit):
msDS-Settings (authorized bypass SIDs, redact non-relevant ones):

--- DC where the change actually landed ---
DC name:
ntdsai.dll version:
Meets minimum (2022: 10.0.20348.5257 / 2025: 10.0.26100.32995)?  [ ] Yes  [ ] No

--- Group state ---
msDS-ObjectSoa value:
Cloud Sync provisioning job status for this group:

--- Evidence attached ---
[ ] Output of Check-CloudSyncSOAPolicy.ps1 from the affected DC
[ ] Directory Service event log export (if Audit mode)
[ ] Cloud Sync provisioning log entry for the group in question

Business impact:
Preview feature -- confirm whether this is a known limitation before escalating to Microsoft Support
(see Known behavior and limitations: no-deletion-block, groups-only, per-DC rollout requirement).
```

---
## 🎓 Learning Pointers

- **This is additive to AD RBAC, not a replacement for it.** AD group enforcement layers a DC-side restriction on top of whatever permissions already exist -- it never grants access, only removes it for non-authorized SIDs on marked objects. A user who already couldn't modify the group before enforcement was enabled still can't; the policy only closes the gap for people who *could*. [Microsoft Learn: Configure AD group enforcement](https://learn.microsoft.com/en-us/entra/identity/hybrid/cloud-sync/how-to-ad-group-enforcement)

- **Enablement is per-domain-controller, not a tenant or domain-wide switch.** Treat a partial rollout as no protection at all for any write that happens to land on an un-updated DC -- this is the single most likely cause of "enforcement isn't working" tickets during a phased rollout.

- **Converting a group's Source of Authority to the cloud and marking it for enforcement are two separate, sequential actions.** Don't assume SOA conversion alone locks the object down -- this repo has already documented the SOA-conversion mechanics in `CloudSync-A.md`; enforcement is a distinct opt-in layered on top.

- **This preview currently protects groups only, and does not block deletion.** Set expectations accordingly with anyone requesting it as a general-purpose AD tamper-protection mechanism -- it is scoped narrowly today.

- **The GitHub-hosted scripts (`Set-CloudSyncSOAPolicy.ps1`, `Check-CloudSyncSOAPolicy.ps1`) are the only documented way to read or change policy mode** -- there is no Entra admin center UI toggle for this preview as of this writing. Get them from the [AzureAD/EntraIDGovernance repository](https://github.com/AzureAD/EntraIDGovernance) directly rather than a mirrored copy, since this is an actively evolving preview.

- **Being a preview feature under the Azure Preview Supplemental Terms**, don't commit a client to Enforced mode in production without an explicit break-glass account already configured and tested -- Fix 4 is not optional hardening, it's the only documented emergency-access path.
