# Entra Domain Services — Enhanced sAMAccountName Sync (Public Preview) — Reference Runbook (Mode A: Deep Dive)
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
- Microsoft Entra Domain Services' **enhanced sAMAccountName synchronization** feature (Public Preview as of this writing) — sourcing sAMAccountName from the `onPremisesSamAccountName` attribute in Microsoft Entra ID for hybrid users, instead of generating it from `mailNickname`/UPN prefix
- The SKU gate (Enterprise/Premium only), the dual-role RBAC requirement to change the setting, and the differing default-state behavior for existing vs. newly created managed domains
- Practical migration planning: what to check before flipping the setting on a production managed domain with existing users

**Out of scope:**
- The pre-existing, always-on sAMAccountName autogeneration logic (mailNickname/UPN-prefix-based, with truncation and de-duplication) — see `EntraDomainServices-A.md`'s "How It Works" and `EntraDomainServices-B.md` Fix 3 for that baseline behavior, which this feature modifies but does not replace outright
- The synchronization pipeline that populates `onPremisesSamAccountName` in Microsoft Entra ID in the first place — that's owned by Microsoft Entra Connect Sync or Cloud Sync, see `EntraID/Troubleshooting/Connect-Sync-A.md` / `EntraID/Troubleshooting/CloudSync-A.md`
- General Entra Domain Services architecture (replica sets, networking, forest trusts, authentication model) — see `EntraDomainServices-A.md`

**Assumptions:**
- You have an existing Microsoft Entra Domain Services managed domain, or are planning one
- Your tenant has hybrid identities synchronized from on-premises Active Directory via Entra Connect Sync or Cloud Sync
- You hold, or can obtain, both Application Administrator and Groups Administrator roles to test this feature
- This is a **Public Preview** feature — behavior, defaults, and even availability may change before general availability; re-verify against the live Microsoft Learn page before relying on any specific claim in a client engagement

---
## How It Works

<details><summary>Full mechanism</summary>

Microsoft Entra Domain Services has always needed a value for the legacy `sAMAccountName` attribute on every user object in its managed domain, because NTLM and pre-Windows-2000-style `DOMAIN\username` authentication — which many legacy applications still depend on — require it, and it must be unique, ≤20 characters, and free of unsupported special characters within the managed domain. Historically, Domain Services has generated this value itself, deriving it from `mailNickname` (or the UPN prefix as a fallback) and applying truncation and de-duplication logic when needed to satisfy those legacy constraints. This generated value has no guaranteed relationship to any sAMAccountName a hybrid user might already have on-premises — a common source of confusion when the same user has two different legacy logon names in two different Microsoft-managed directory contexts.

Enhanced sAMAccountName synchronization changes the *source* of that value for hybrid users only. Microsoft Entra Connect Sync and Cloud Sync already populate an `onPremisesSamAccountName` attribute on the corresponding Entra ID user object, carrying the user's actual on-premises AD DS `sAMAccountName` value into the cloud directory (this attribute existed and was populated before this feature; the feature is new consumption of an existing attribute, not a new sync pipeline). When enhanced synchronization is enabled on a managed domain, Domain Services reads this attribute directly instead of deriving a value from `mailNickname`, for every hybrid user whose `onPremisesSamAccountName` is populated.

This is still a strictly one-way flow — Entra ID (ultimately sourced from on-premises AD DS) into the managed domain, never the reverse — consistent with Domain Services' overall one-way synchronization architecture described in `EntraDomainServices-A.md`. Enhanced sync does not change that directionality; it only changes which source attribute feeds the sAMAccountName field specifically.

Cloud-only users — those with no on-premises AD DS counterpart and therefore no `onPremisesSamAccountName` value — are entirely unaffected by this setting in either state. They continue to use the original mailNickname/UPN-prefix-based generation logic regardless of whether enhanced sync is enabled, because there is no on-premises value for them to source instead.

The setting itself lives at the managed-domain level, under Security settings in the Entra admin center for that specific Domain Services instance — it is not a tenant-wide toggle, and (per Microsoft's documentation, as of this preview) has no confirmed Graph API or Az PowerShell cmdlet surface for reading or setting it; the admin center is the only confirmed control surface at time of writing.

</details>

---
## Dependency Stack

```
On-premises Active Directory Domain Services
    └── User object's own sAMAccountName (authoritative, set on-prem)
          │
          ▼  (Microsoft Entra Connect Sync / Cloud Sync — existing hybrid sync pipeline,
          │    not modified by this feature)
          ▼
Microsoft Entra ID
    └── onPremisesSamAccountName attribute (populated on the hybrid user object)
          │
          ▼  (Domain Services' own internal one-way sync from Entra ID —
          │    the layer this feature actually modifies)
          ▼
Microsoft Entra Domain Services managed domain — "sAMAccountName synchronization
from on-premises" setting
    ├── DISABLED: sAMAccountName <- generated from mailNickname/UPN prefix
    │              (truncated, de-duplicated as needed)
    └── ENABLED:  sAMAccountName <- onPremisesSamAccountName (hybrid users only;
                   cloud-only users still use the generated path)
          │
          ▼
Managed-domain sAMAccountName value — consumed by:
    ├── NTLM authentication (DOMAIN\username-style logon)
    ├── Legacy LDAP-bind applications keyed on sAMAccountName
    ├── Scripts/scheduled tasks that reference the logon name directly
    └── Kerberos pre-authentication (indirectly, via account lookup)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Setting not visible or greyed out in Security settings blade | Managed domain SKU is Standard (not Enterprise/Premium) | `Get-AzADDomainService -Name <domain> -ResourceGroupName <rg>` → check `Sku` |
| Admin gets an access-denied error trying to change the setting | Missing one of the two required roles (Application Administrator AND Groups Administrator — both, not either) | Check the admin's active/eligible role assignments |
| Hybrid user's DOMAIN\username logon suddenly stopped working after a config change | Enhanced sync was just enabled; the user's sAMAccountName legitimately changed to match on-prem | Compare `Get-ADUser -Server <managedDomainFQDN>` SamAccountName before/after against `Get-MgUser` OnPremisesSamAccountName |
| Some hybrid users got the new consistent naming, others didn't, after enabling | Affected users have no `onPremisesSamAccountName` populated in Entra ID — falls through to old generation logic | `Get-MgUser -Filter "onPremisesSyncEnabled eq true"` and check for null `OnPremisesSamAccountName` |
| Cloud-only user's sAMAccountName looks unchanged/unaffected by the new setting | Expected — cloud-only users never use this feature's source attribute regardless of setting state | Confirm the user has no on-premises AD DS counterpart |
| New managed domain's behavior doesn't match either documented default | Microsoft's own documentation for new-domain defaults is internally inconsistent (see Learning Pointers) | Empirically test against a known hybrid user rather than trusting either doc claim |
| Legacy app or script broke immediately after enabling on a production domain | Hardcoded reference to the OLD generated sAMAccountName value, now stale | Cross-reference the app/script's expected value against the new onPremisesSamAccountName-sourced value |

---
## Validation Steps

1. **Confirm SKU eligibility before doing anything else.**
   ```powershell
   Get-AzADDomainService -Name "<domainServiceName>" -ResourceGroupName "<rg>" | Select-Object Name, Sku
   ```
   Expected good output: `Sku` is `Enterprise` or `Premium`. Bad: `Standard` — the feature isn't available, full stop.

2. **Inventory hybrid users lacking a populated `onPremisesSamAccountName`, tenant-wide, before enabling.**
   ```powershell
   Get-MgUser -All -Filter "onPremisesSyncEnabled eq true" -Property DisplayName,UserPrincipalName,OnPremisesSamAccountName |
       Where-Object { -not $_.OnPremisesSamAccountName }
   ```
   Expected good output: empty or a small, understood list. Bad: a large unexpected count — investigate the sync engine's attribute-mapping configuration before proceeding (out of scope for this runbook; see the Connect-Sync/CloudSync references above).

3. **Inventory legacy dependencies on the current, pre-change sAMAccountName values.**
   There is no single automated check for this — it requires a manual review of scripts, scheduled tasks, LDAP-bind application configs, and mapped-drive/logon-script references that key on sAMAccountName within the managed domain. Treat this as a mandatory change-management step, not optional due diligence, given Fix 2's confirmed live-rename behavior on existing users.

4. **Confirm role eligibility for whoever will flip the setting.**
   ```powershell
   Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<adminObjectId>'" |
       ForEach-Object { (Get-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId $_.RoleDefinitionId).DisplayName }
   ```
   Expected: both `Application Administrator` and `Groups Administrator` present (active or PIM-eligible, per your tenant's PIM posture).

5. **After enabling, validate against a representative sample before declaring the change complete.**
   Pick 3-5 hybrid users spanning different OUs/business units if the managed domain has custom OU structure, confirm `Get-ADUser -Server <managedDomainFQDN>` SamAccountName matches `Get-MgUser` OnPremisesSamAccountName exactly, and have a real or test authentication attempt succeed against at least one legacy NTLM-dependent application before closing the change.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Pre-enablement planning**
Confirm SKU, confirm attribute population coverage, confirm RBAC, and complete the legacy-dependency inventory (Validation Steps 1-4). Do not skip the dependency inventory even under time pressure — this is the step that prevents a change from becoming an incident.

**Phase 2 — Enablement**
Via the Entra admin center: Microsoft Entra Domain Services > select the managed domain > Security settings > "sAMAccountName synchronization from on-premises" > Enable > Save. No confirmed PowerShell/Graph path exists for this specific action as of this preview — do not assume a cmdlet exists without checking the current module release notes first.

**Phase 3 — Post-enablement validation**
Run Validation Step 5 against a representative sample. Separately confirm cloud-only users are visibly unaffected (a quick spot-check prevents a false "nothing changed for anyone" assumption if the sample happened to include only cloud-only accounts).

**Phase 4 — Communication and cleanup**
For any hybrid user whose sAMAccountName value changed, communicate the new logon name proactively rather than waiting for a "can't log in" ticket. Update any documentation, runbooks, or onboarding materials that referenced the old generated-value convention for this managed domain.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Full staged rollout of enhanced sync on a production managed domain with existing users</summary>

1. Complete Validation Steps 1-4 in full — SKU, attribute-population inventory, legacy-dependency inventory, RBAC.
2. If possible, test first against a **non-production managed domain** (a second Domain Services instance, or a lab tenant) to empirically confirm the actual default-state and rollback behavior for your specific scenario, given the documented inconsistencies noted in Learning Pointers below.
3. Schedule the change during a change window, not silently — this is a live identity-attribute change on production accounts, not a passive configuration read.
4. Enable the setting per Phase 2 above.
5. Immediately run Validation Step 5 against the full hybrid-user population (not just a sample) if the managed domain's user count makes that feasible, to catch any unexpected mismatches early rather than waiting for user reports.
6. Communicate new logon names to affected users per Phase 4.
7. Monitor for a defined period (recommend at least one full business week) for legacy-app authentication failures that weren't caught by the pre-enablement dependency inventory.

**Rollback:** Disabling the setting again is available in the same Security settings blade, but Microsoft's documentation does not state whether this reverts already-changed sAMAccountName values back to the prior generated value, or leaves affected users on their new onPremisesSamAccountName-derived value going forward with only *future* changes reverting to generation logic. **Confirm this behavior empirically in a test managed domain, or via a Microsoft support case, before promising a client a clean rollback path** — do not commit to a rollback SLA based on an assumption.

</details>

<details><summary>Playbook 2 — New managed domain deployment, resolving the default-state documentation ambiguity</summary>

1. Do not assume either documented default (see Learning Pointers) applies to your specific new deployment.
2. Immediately after the managed domain finishes provisioning, before onboarding any production users, create or identify one known hybrid test user with a confirmed `onPremisesSamAccountName` value.
3. Check that test user's sAMAccountName on the managed domain directly:
   ```powershell
   Get-ADUser -Identity "<test-upn>" -Server "<managedDomainFQDN>" -Properties SamAccountName
   ```
4. Compare against their `OnPremisesSamAccountName` in Entra ID. A match indicates enhanced sync is active by default for this domain; a mismatch (i.e., a truncated/generated-looking value) indicates it is not.
5. Document the empirically-confirmed behavior for this specific managed domain in your client's environment documentation — do not rely on Microsoft's page alone for this fact going forward, and re-verify if Microsoft updates the documentation to resolve the inconsistency.

**Rollback:** N/A — this playbook is a verification procedure, not a configuration change. If the empirically-observed default is undesired, follow Playbook 1's enable/disable procedure as appropriate, with the same rollback caveat.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Evidence-collection snippet for escalating an Entra Domain Services sAMAccountName
    sync (preview) issue to Microsoft support or a senior engineer.
#>

$domainServiceName = "<domainServiceName>"
$resourceGroup     = "<rg>"
$managedDomainFQDN = "<managedDomainFQDN>"
$sampleUpns        = @("<upn1>", "<upn2>", "<upn3>")

$evidence = [ordered]@{
    Timestamp   = (Get-Date).ToString("o")
    DomainSku   = (Get-AzADDomainService -Name $domainServiceName -ResourceGroupName $resourceGroup).Sku
    SampleUsers = foreach ($upn in $sampleUpns) {
        $entraUser = Get-MgUser -UserId $upn -Property DisplayName, OnPremisesSamAccountName, OnPremisesSyncEnabled
        $adsUser   = Get-ADUser -Identity $upn -Server $managedDomainFQDN -Properties SamAccountName -ErrorAction SilentlyContinue
        [pscustomobject]@{
            UPN                     = $upn
            EntraOnPremSamAccountName = $entraUser.OnPremisesSamAccountName
            DomainServicesSamAccountName = $adsUser.SamAccountName
            Match                   = ($entraUser.OnPremisesSamAccountName -eq $adsUser.SamAccountName)
        }
    }
}

$evidence | ConvertTo-Json -Depth 5
```

---
## Command Cheat Sheet

```powershell
# Confirm SKU (Enterprise/Premium required)
Get-AzADDomainService -Name "<domain>" -ResourceGroupName "<rg>" | Select-Object Sku

# Confirm admin's role assignments
Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<adminObjectId>'"

# Inventory hybrid users missing onPremisesSamAccountName
Get-MgUser -All -Filter "onPremisesSyncEnabled eq true" -Property OnPremisesSamAccountName |
    Where-Object { -not $_.OnPremisesSamAccountName }

# Compare a single user's value cloud-side vs. managed-domain-side
Get-MgUser -UserId "<upn>" -Property OnPremisesSamAccountName
Get-ADUser -Identity "<upn>" -Server "<managedDomainFQDN>" -Properties SamAccountName

# Confirm a user's sync status generally
Get-MgUser -UserId "<upn>" -Property OnPremisesSyncEnabled,OnPremisesLastSyncDateTime
```

---
## 🎓 Learning Pointers

- **This feature reuses an existing attribute, not a new sync pipeline — the change is entirely in what Domain Services reads, not in what Entra Connect/Cloud Sync writes.** Understanding this distinction is what lets you correctly scope a "sAMAccountName looks wrong" ticket to either this feature's setting (Domain Services side) or the underlying sync engine's attribute mapping (Connect Sync/Cloud Sync side) — conflating the two wastes triage time. [MS Docs: SAM Account Name - Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/domain-services/security-account-name)

- **Enabling a "preference" setting on an existing managed domain is, functionally, a live rename operation on production identity attributes.** The single highest-value fact in this whole topic: this is not a passive display-preference change. Any MSP treating this as a low-risk toggle to flip on request without a dependency inventory first is setting up a very avoidable outage.

- **When a vendor's own documentation contradicts itself, don't silently pick the more official-sounding claim — verify empirically and document what you actually observed.** This preview page's new-managed-domain default-state contradiction is a useful teaching example: two sections of the same live Microsoft Learn article (fetched 2026-09-02, page dated 2026-08-18/updated 2026-08-24) disagree, and the correct professional response is testing, not guessing.

- **A two-role RBAC gate (Application Administrator + Groups Administrator) with no stated rationale should be treated as a real requirement, not a documentation bug.** Several other Entra features in this repo (see `EntraID/Troubleshooting/ExternalMFA-A.md`'s two-role admin-consent gate) share this pattern of stacking two seemingly-unrelated admin roles for a single feature toggle — worth recognizing as a recurring Microsoft platform pattern rather than re-investigating from scratch each time it appears.

- **Preview features can have thinner rollback guarantees than GA features — say so explicitly to a client before they rely on "we can always turn it back off."** This runbook deliberately does not assert a rollback behavior Microsoft hasn't documented, and neither should you in a client conversation — offering to test in a non-production environment first is the professionally honest alternative to guessing.
