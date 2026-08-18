# Entra Connect Sync → Entra Cloud Sync Migration — Reference Runbook (Mode A: Deep Dive)
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

**Covers:**
- The **architectural migration** from Microsoft Entra Connect Sync (on-prem sync engine) to Microsoft Entra Cloud Sync (lightweight cloud-managed provisioning-agent model) — Microsoft's stated strategic direction as of April 2026, with a Microsoft-phased, notification-driven eligibility rollout beginning July 2026
- The full technical feature comparison between the two sync tools, and how to translate that comparison into a readiness decision for a specific tenant
- The documented, OU-scoped, staged migration mechanism — including the `cloudNoFlow` custom sync rule pair that is the actual technical device by which Connect Sync stops exporting a migrating OU
- Migration eligibility/timeline mechanics, exception handling, and the mandatory-backup/rollback model
- What migration does and does not carry over automatically, and the explicit "you aren't required to migrate until you're ready" posture Microsoft documents for unsupported-feature dependencies

**Does not cover:**
- **Day-2 operation of an already-migrated, steady-state Cloud Sync deployment** (agent health, quarantine, gMSA auth, disconnected-forest sync, Group Provisioning to AD DS mechanics) — that is `CloudSync-A.md`/`-B.md`'s scope; this file is specifically the transition itself
- **Day-2 operation of a Connect Sync server staying on Connect Sync** (attribute sync errors, staging mode, object matching) — see `Connect-Sync-A.md`/`-B.md`
- **Whether a given Connect Sync server is on a supported/current version** — a fully separate, one-time 30 September 2026 mandatory-upgrade deadline and an ongoing per-version retirement policy that apply regardless of any Cloud Sync migration plans; see `ConnectSyncUpgrade-A.md`/`-B.md`. A tenant can be actively planning a Cloud Sync migration and still need to clear the Connect Sync version deadline in the interim, since migration is phased over time, not instantaneous.
- **Cloud Kerberos Trust deployment mechanics** — the replacement for Hybrid Azure AD Join device sync, referenced here as a migration dependency but covered in its own topic
- **Password Hash Sync, PTA, ADFS, or Seamless SSO configuration** beyond confirming they remain functional and are configured independently of the sync tool choice

**Assumes:**
- An existing, functioning Microsoft Entra Connect Sync deployment already synchronizing users/groups/contacts to Microsoft Entra ID
- Access to both the Connect Sync server (local admin, Synchronization Rules Editor) and the target Active Directory (Domain Administrator or Enterprise Administrator credentials to create the Cloud Sync gMSA)
- Microsoft Entra ID P1 licensing (required for several Cloud Sync capabilities, including Group Provisioning to AD DS)
- A Hybrid Identity Administrator account for the tenant, not a guest user

---
## How It Works

<details><summary>Full architecture — the migration model</summary>

### Two separate timelines that are easy to conflate

There are genuinely two different clocks in play whenever this topic comes up, and confusing them is the single biggest source of miscommunication with a customer:

1. **The strategic mandate.** Microsoft announced in April 2026 that all customers will ultimately move from Connect Sync to Cloud Sync. This is directional and long-term — it does not mean every tenant migrates this quarter, or even this year.
2. **The phased eligibility rollout.** Starting July 2026, Microsoft began assigning migration transition windows in waves, notifying tenants when their configuration makes them a good early candidate — generally single forest, standard attribute flows, no exotic sync rules. Later waves follow as Cloud Sync closes specific feature-parity gaps for more complex environments.

A tenant can be fully committed to the strategic direction and still be, correctly, nowhere near its assigned wave — that's expected, not a sign anything is broken or overdue.

### The feature comparison — what actually changes

Microsoft's own decision guide publishes a detailed capability-by-capability comparison. The rows that matter most for a migration-readiness conversation:

| Feature/Capability | Connect Sync | Cloud Sync | Technical Notes |
|---|---|---|---|
| Users, Groups, Contacts Sync | ✓ | ✓ | Full parity for basic directory object sync |
| Single Connected Forest | ✓ | ✓ | Both support standard single-forest topologies |
| Multiple Connected Forests | ✓ | ✓ | Both support multiple connected forest scenarios |
| Disconnected Forest Support | ✗ | ✓ | Cloud Sync-only — a genuine migration *driver* for M&A scenarios, not a blocker |
| Device Synchronization | ✓ | ✗ | Connect supports Hybrid Azure AD Join; not currently supported in Cloud Sync — the most common near-term blocker |
| Multiple Active Sync Instances | ✗ | ✓ | Cloud Sync agents provide automatic failover/load distribution |
| Scale Limits per Domain | Unlimited | 150K objects | Hard planning ceiling for large tenants |
| Large Group Support | 250K members | 50K members | Also the Group Provisioning to AD DS cap |
| Password Hash Sync | ✓ | ✓ | Full parity |
| Password Writeback | ✓ | ✓ | SSPR writeback supported in both |
| Pass-Through Authentication Config | ✓ | ✗ (managed separately) | PTA/Seamless SSO remain functional after migration — configured through their own wizard, not the sync tool |
| ADFS Integration Setup | ✓ | ✗ (managed separately) | Federation configuration is independent of the sync-tool choice |
| Exchange Hybrid Attributes | ✓ | ✓ | Full support |
| Directory Extensions (1-15) | ✓ | ✓ | Supported |
| Custom AD Attributes | ✓ | ✓ | Supported |
| Basic Attribute Customization | ✓ | ✓ | Via expression builder in Cloud Sync |
| Advanced Sync Rules | ✓ | ✗ | Complex rule engine (Connect) vs. expression builder (Cloud Sync) — not a 1:1 replacement |
| OU-based Filtering | ✓ | ✓ | Supported in both — and the mechanism the migration itself relies on |
| Attribute-based Filtering | ✓ (full) | Limited | Cloud Sync's filtering is materially less capable |
| Device Writeback | ✓ | ✗ | Discontinued in favor of Cloud Kerberos Trust |
| Group Writeback V1 | ✓ | ✓ | Supported in both (see also the separate Group Writeback V2 migration path) |
| Group Provisioning to AD | ✗ | ✓ | Cloud Sync-only, reverse-direction feature |
| User Provisioning to AD | ✗ | ✗ | Not supported by either, currently |
| Cross-Domain References | ✓ | ✓ | Supported |
| Cross-Forest References | ✓ | ✗ | Connect-only |
| Merge Attributes from Multiple Domains | ✓ | ✗ | Connect-only |
| Reconciliation Capabilities | ✓ | ✗ | No out-of-band sync correction in Cloud Sync |
| On-Demand Provisioning | ✗ | ✓ | Cloud Sync-only — useful for validating a single user during migration |
| Cloud Configuration Management | ✗ | ✓ | Cloud Sync-only — no on-prem config store |
| Seamless Single Sign-On | ✓ | ✓ | Supported in both |

This table shifts as Cloud Sync closes gaps — treat it as a living reference and re-pull the current version before making a migration-readiness call on any borderline case.

### Migration readiness — three tiers

Microsoft's own decision framework sorts a tenant into one of three buckets:

- **Ready for immediate migration:** under 150,000 objects/domain, groups under 50,000 members, not dependent on Hybrid Azure AD Join (or willing to transition to Cloud Kerberos Trust), PHS or independently-managed ADFS/PTA, OU-based rather than complex attribute-based filtering, single or connected-forest topology.
- **Plan for near-term migration:** depends on a feature with an active Microsoft roadmap item (device sync, advanced attribute filtering, user provisioning to AD) — monitor the feature-comparison table and plan migration timing around actual GA, not an assumed date.
- **Evaluate for future migration:** large-scale deployments beyond the scale limits, extensive custom sync rules, cross-forest dependencies, or a hard dependency on reconciliation — for these, segmenting migration by domain/OU may offer a partial path even before full parity exists.

### The migration mechanism — how objects actually move without a collision

Running Connect Sync and Cloud Sync side by side for the *same* objects is explicitly unsupported — both tools would attempt to own and potentially conflict-write the same directory objects in Microsoft Entra ID. Microsoft's documented answer is **OU-based scoping**: each organizational unit is managed by exactly one tool at any given time, and migration proceeds OU by OU.

The technical mechanism that makes this safe is a custom Connect Sync sync-rule pair, conventionally called by its target attribute name, `cloudNoFlow`:

- An **inbound** join rule scoped to the migrating OU, setting a `cloudNoFlow` metaverse attribute to `True` for every object in that OU
- An **outbound** rule with link type `JoinNoFlow` and a scoping filter on `cloudNoFlow = True`

Together, these tell Connect Sync's own export step to deliberately skip objects from the migrating OU — Connect Sync keeps *importing and joining* them internally (so it retains visibility and can still be used for rollback), but stops *exporting* them to Microsoft Entra ID. Cloud Sync, configured with a job scoped to that same OU, then becomes the sole tool actually writing those objects to the cloud. This is the load-bearing detail behind "no side-by-side sync" — it's not a Cloud Sync-side setting, it's a Connect Sync-side opt-out.

### What is, and isn't, preserved automatically

The migration tooling transfers *supported* configuration — it is not a blind lift-and-shift. After migration, Microsoft's documented process is to run an on-demand sync (Cloud Sync's single-user validation feature) and confirm the result matches expectations *before* proceeding to a production cutover for that OU. Any configuration that depends on an unsupported Connect Sync capability (from the feature table above) simply does not have anywhere to go in Cloud Sync and needs a redesign, not a transfer.

</details>

---
## Dependency Stack

```
Layer 6 — Strategic mandate (directional, long-term, not itself an action trigger)
          — all customers eventually move to Cloud Sync
Layer 5 — Eligibility / wave assignment (Microsoft-controlled, notification-driven)
          — phased rollout beginning July 2026; determines WHEN, not WHETHER
Layer 4 — Readiness assessment (customer/MSP-controlled — do this independently
          of any wave notification)
          ├─ Object scale (<150K/domain) and group scale (<50K members)
          ├─ Device sync dependency (Hybrid Azure AD Join → needs Cloud Kerberos
          │       Trust first/alongside)
          ├─ Advanced Sync Rules / cross-forest / reconciliation dependencies
          │       (no Cloud Sync equivalent — redesign or defer)
          └─ Filtering complexity (OU-based fine; complex attribute-based limited)
Layer 3 — Prerequisites (Cloud Sync agent side)
          ├─ Domain-joined, Tier-0-hardened server; gMSA created at install
          ├─ Hybrid Identity Administrator account (non-guest)
          └─ msDS-ExternalDirectoryObjectId AD schema attribute (Server 2016+)
Layer 2 — Migration mechanism (OU-scoped, staged)
          ├─ Config backup (Import/Export settings) — the sole rollback path
          ├─ cloudNoFlow inbound/outbound rule pair on Connect Sync — the actual
          │       mechanism preventing dual-tool collision on the same objects
          └─ Cloud Sync job scoped to the same OU, installed and configured
Layer 1 — Validation (per OU, before moving to the next one)
          ├─ Pre/post object-count match
          └─ New-object provisioning test (create a user in the OU, confirm it
                flows through Cloud Sync, not Connect Sync)
Layer 0 — Decommission (final step only)
          — stop-but-don't-uninstall Connect Sync for a soak period, THEN
                uninstall once the soak period confirms no regression
```

A gap anywhere in Layer 4 (readiness) should stop forward progress regardless of what Layer 5 (eligibility notification) says — an eligibility wave is an invitation to begin assessing, not a green light to skip the assessment.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Customer received a Microsoft notification about Cloud Sync migration and isn't sure what it means | Phased eligibility rollout notification — informational/scheduling, not an emergency | Confirm the recommended window and run the readiness triage independently before committing to a date |
| Migration stalls or is deprioritized indefinitely with no clear reason | A genuine unsupported-feature dependency exists but was never documented/tracked | Run the full readiness assessment (Mode B Triage) and record the specific blocking dependency |
| Users/groups in a "migrated" OU still show Connect Sync export activity, or objects intermittently flap/duplicate | The `cloudNoFlow` outbound rule's scoping filter isn't correctly excluding that OU from Connect Sync's export | Inspect the outbound rule's scope condition and confirm every object in the OU actually has `cloudNoFlow = True` set by the inbound rule |
| A pilot OU migrates cleanly but a later, larger OU migration fails or behaves unexpectedly | The larger OU has a dependency the pilot OU didn't (advanced sync rule, larger nested-OU structure, group over 50K members) | Re-run the readiness checks scoped specifically to the next OU before migrating it — don't assume pilot success generalizes |
| New users created after cutover aren't appearing in Microsoft Entra ID for a migrated OU | Cloud Sync job's OU scope doesn't actually include the new user's OU, or the Cloud Sync job itself isn't running | Confirm the job's scoping configuration and agent health — see `CloudSync-B.md` for Cloud Sync-specific provisioning troubleshooting once migration itself is confirmed correctly configured |
| Devices stop appearing/updating in Microsoft Entra ID after a migration | Device sync was in use and had no Cloud Kerberos Trust replacement in place before cutover | Confirm device-sync dependency was assessed (readiness Layer 4) before this OU/tenant migrated — this is a planning gap, not a Cloud Sync bug |
| A previously-working custom attribute transform stops working post-migration | The transform relied on an Advanced Sync Rule capability with no Cloud Sync equivalent | Re-check the feature comparison table for that specific capability; redesign via Cloud Sync's expression builder if a supported equivalent exists, otherwise keep that OU on Connect Sync |
| Team wants to migrate faster than the assigned window but Microsoft support says no | Migration timing is Microsoft-controlled per the phased rollout, not customer-accelerable by default | Confirm there's no legitimate exception-request path being missed (this applies to *delaying* past a window per the FAQ — accelerating ahead of an assigned window isn't a documented option either) |
| Rollback is needed but no config backup exists | The mandatory pre-migration backup step (Import/Export settings) was skipped | Restore from a VM snapshot if one exists; otherwise this is a rebuild-from-scratch situation — escalate and treat as a process-gap finding for next time |

---
## Validation Steps

1. **Readiness assessment completed and documented, independent of any eligibility notification.**
   Expected: a clear bucket (ready now / plan near-term / evaluate future) with the specific supporting/blocking facts recorded. Bad: "we'll just try it and see" with no documented assessment.

2. **Config backup exists and is recent.**
   ```powershell
   # Via the Microsoft Entra Connect wizard's Import/Export settings feature — confirm
   # a backup file exists and its timestamp predates any migration change
   ```
   Expected: a backup taken immediately before the first migration change. Bad: no backup, or a backup predating unrelated subsequent Connect Sync changes.

3. **cloudNoFlow rule pair correctly scoped to the intended OU only.**
   ```powershell
   Get-ADSyncRule | Where-Object { $_.Name -match 'cloudNoFlow' } | Select-Object Name, Direction, Precedence
   ```
   Expected: exactly one inbound + one outbound rule, both scoped to the intended pilot/production OU. Bad: a scope that's broader (or narrower) than intended, or a missing rule half.

4. **Cloud Sync job scope matches the Connect Sync exclusion scope exactly.**
   Expected: the OU excluded from Connect Sync's export is the same OU Cloud Sync's job is configured to pick up — no gap, no overlap. Bad: a mismatch, which produces either an object that's synced by neither tool or (if Connect Sync's exclusion is misconfigured) by both.

5. **Pre/post object count matches for the migrated OU.**
   ```powershell
   Get-ADUser -Filter * -SearchBase "<DN path of migrated OU>" | Measure-Object
   ```
   Expected: matches the pre-migration baseline count. Bad: a discrepancy — investigate before proceeding to the next OU.

6. **New-object provisioning test passes.**
   Expected: a newly created test user in the migrated OU provisions via Cloud Sync (visible in Cloud Sync's provisioning logs) rather than Connect Sync. Bad: it doesn't appear at all, or appears via Connect Sync instead — the scoping isn't correctly cut over.

7. **Post-cutover, pre-decommission soak period observed.**
   Expected: Connect Sync stopped (not uninstalled) for a deliberate verification window before the final uninstall step. Bad: uninstalling Connect Sync the same day as the final OU's cutover.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Separate the strategic conversation from the operational one.**
Confirm with the customer/stakeholder whether this is "we got a notification and need to act" or "we want to plan ahead of one" — both are legitimate, but they carry different urgency and different amounts of lead time to work with.

**Phase 2 — Run the readiness assessment before any technical work begins.**
Object/group scale, device sync dependency, advanced sync rule usage, and filtering complexity — all four should be checked regardless of whether a wave notification exists yet. A tenant that's technically eligible per Microsoft's notification but fails this internal readiness check should still defer.

**Phase 3 — Back up the Connect Sync configuration before touching anything.**
This is the single non-negotiable step in the entire process — everything downstream assumes this exists.

**Phase 4 — Pilot on a small, low-risk OU first.**
Never attempt a first migration on a production-critical OU. Build the `cloudNoFlow` rule pair, configure the matching Cloud Sync job scope, and validate fully (Validation Steps 3-6) before considering the pilot a template for the rest of the tenant.

**Phase 5 — Phase the remaining rollout deliberately, OU by OU.**
Each OU gets its own validation pass. Resist the temptation to batch multiple OUs into one cutover window just because the pilot succeeded — a later OU can have a dependency the pilot didn't.

**Phase 6 — Soak, then decommission.**
Stop Connect Sync and hold for a verification window once every in-scope OU has migrated and validated cleanly. Only uninstall after that window closes without a regression surfacing.

**Phase 7 — Escalate to Microsoft only for eligibility/timeline questions, not technical migration failures.**
A stuck migration-wave assignment or an exception request goes through Microsoft Support/the account team. A technical failure in the OU-scoping/cloudNoFlow mechanism is this repo's own troubleshooting territory first — most of these resolve via Fix 6 (Mode B) before any escalation is needed.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Full readiness assessment and go/no-go decision</summary>

1. Gather AD object counts (users + groups + contacts) per domain via the ActiveDirectory module; compare against the 150,000-object Cloud Sync limit.
2. Identify the largest AD groups by member count; compare against the 50,000-member Cloud Sync cap.
3. Query Microsoft Entra ID for Hybrid Azure AD Join device count (`trustType eq 'ServerAd'`); if non-zero, flag a Cloud Kerberos Trust dependency as a prerequisite project.
4. Enumerate non-default Connect Sync rules via `Get-ADSyncRule`; review each against the current Cloud Sync feature comparison table to classify as "has an equivalent" vs. "no equivalent, needs redesign or deferral."
5. Confirm PTA/ADFS federation status (informational only — not a blocker, but worth flagging to the customer that these remain independently configured post-migration).
6. Classify the tenant (or specific OUs within it) into Ready Now / Plan Near-Term / Evaluate Future, and document the specific supporting facts for each classification.
7. If "Ready Now," proceed to Playbook 2. If "Plan Near-Term," document the specific dependency being tracked and set a re-assessment date. If "Evaluate Future," document why and consider whether segmenting by domain/OU offers a partial path.

**Rollback:** none — this is an assessment-only playbook.
</details>

<details><summary>Playbook 2 — Pilot OU migration, end to end</summary>

1. Select a small, low-risk pilot OU (not production-critical) and get its baseline user count.
2. Back up the Microsoft Entra Connect configuration via Import/Export settings.
3. Install the Cloud Sync provisioning agent if not already present (domain-joined server, gMSA created during install, Hybrid Identity Administrator credentials).
4. Stop the Connect Sync scheduler: `Set-ADSyncScheduler -SyncCycleEnabled $false`.
5. In the Synchronization Rules Editor, create the `cloudNoFlow` inbound (join rule, target attribute `cloudNoFlow`) and outbound (link type `JoinNoFlow`, scope `cloudNoFlow = True`) rule pair, scoped to the pilot OU.
6. Configure a Cloud Sync job scoped to the same pilot OU.
7. Restart the Connect Sync scheduler: `Set-ADSyncScheduler -SyncCycleEnabled $true`.
8. Validate: pre/post object count match (Validation Step 5), new-object provisioning test (Validation Step 6).
9. Document the pilot outcome and any deviations from the expected process before using it as a template for the phased rollout.

**Rollback:** remove the `cloudNoFlow` rule pair from Connect Sync and disable/remove the Cloud Sync job's scope for the pilot OU — this returns the OU to Connect Sync-only management. If a deeper issue occurred, restore the step-2 config backup.
</details>

<details><summary>Playbook 3 — Phased full-tenant rollout and decommission</summary>

1. Using the validated pilot as a template, schedule progressively larger OUs for migration, each following Playbook 2's steps 4-8 independently.
2. For each OU, re-run the readiness checks scoped to that specific OU before migrating it — a later OU can have a dependency the pilot didn't (larger group, an advanced sync rule not present in the pilot OU, device-sync-dependent users).
3. Track migration status per OU (not started / migrated / validated) to avoid losing track of partial progress across a rollout that may span weeks or months.
4. Once every in-scope OU has migrated and validated cleanly, stop the Connect Sync service (do not uninstall) and hold for a soak period.
5. After the soak period passes with no regression, uninstall Connect Sync from the server.

**Rollback:** for any individual OU, follow Playbook 2's rollback. For the full-tenant decommission step specifically, do not proceed past "stop the service" until confident — an uninstalled Connect Sync server has no rollback path beyond a full rebuild from the original config backup.
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS    Collects Entra Connect Sync → Cloud Sync migration readiness and
             in-progress-migration evidence, for planning or ticket escalation.
.DESCRIPTION Read-only. Gathers AD object/group scale, Hybrid Azure AD Join device
             count (via Graph), non-default Connect Sync rule count, and
             cloudNoFlow rule presence. Exports to CSV.
.NOTES       Run on the Connect Sync server with the ActiveDirectory module, the
             ADSync module, and an active Graph connection
             (Connect-MgGraph -Scopes "Device.Read.All,Domain.Read.All").
#>

$domainObjectCount = (Get-ADUser -Filter * -ResultSetSize $null).Count +
                      (Get-ADGroup -Filter * -ResultSetSize $null).Count +
                      (Get-ADObject -Filter 'objectClass -eq "contact"' -ResultSetSize $null).Count

$hybridJoinDeviceCount = (Get-MgDevice -Filter "trustType eq 'ServerAd'" -All -ErrorAction SilentlyContinue).Count

Import-Module ADSync -ErrorAction SilentlyContinue
$customRuleCount = (Get-ADSyncRule -ErrorAction SilentlyContinue | Where-Object { -not $_.IsDefault }).Count
$cloudNoFlowRules = Get-ADSyncRule -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'cloudNoFlow' }

[PSCustomObject]@{
    Server                    = $env:COMPUTERNAME
    DomainObjectCount         = $domainObjectCount
    ExceedsObjectScaleLimit   = ($domainObjectCount -gt 150000)
    HybridJoinDeviceCount     = $hybridJoinDeviceCount
    NonDefaultSyncRuleCount   = $customRuleCount
    CloudNoFlowRulesPresent   = ($cloudNoFlowRules.Count -gt 0)
    CollectedAt               = Get-Date
} | Export-Csv -Path ".\CloudSyncMigrationReadiness_$($env:COMPUTERNAME)_$(Get-Date -Format yyyyMMdd).csv" -NoTypeInformation
```

---
## Command Cheat Sheet

```powershell
# AD object scale (users + groups + contacts) per domain
(Get-ADUser -Filter * -ResultSetSize $null).Count + (Get-ADGroup -Filter * -ResultSetSize $null).Count

# Largest AD group by member count
Get-ADGroup -Filter * -Properties Members | Sort-Object { $_.Members.Count } -Descending | Select-Object -First 5

# Hybrid Azure AD Join device count (via Graph)
Get-MgDevice -Filter "trustType eq 'ServerAd'" -All | Measure-Object

# Non-default Connect Sync rules
Import-Module ADSync
Get-ADSyncRule | Where-Object { -not $_.IsDefault }

# Stop / start the Connect Sync scheduler (required before/after cloudNoFlow rule changes)
Set-ADSyncScheduler -SyncCycleEnabled $false
Set-ADSyncScheduler -SyncCycleEnabled $true

# Confirm the cloudNoFlow rule pair
Get-ADSyncRule | Where-Object { $_.Name -match 'cloudNoFlow' }

# Federated domains (ADFS) and PTA agent presence — informational, not a blocker
Get-MgDomain -All | Where-Object { $_.AuthenticationType -eq 'Federated' }
Get-Service AzureADConnectAuthenticationAgentService -ErrorAction SilentlyContinue

# Object count for a specific OU (pre/post migration comparison)
Get-ADUser -Filter * -SearchBase "<DN path of OU>" | Measure-Object

# Decision guide comparison table (always re-pull the live version — it shifts)
# https://learn.microsoft.com/en-us/entra/identity/hybrid/cloud-sync/connect-to-cloud-sync-decision-guide

# Migration FAQ
# https://learn.microsoft.com/en-us/entra/identity/hybrid/cloud-sync/cloud-sync-migration-faq
```

---
## 🎓 Learning Pointers

- **This is a direction, not a deadline — until it is one.** Unlike the hard 30 September 2026 Connect Sync version-EOL date (`ConnectSyncUpgrade-A.md`), Cloud Sync migration is phased and notification-driven per tenant. Don't import the urgency of one topic into the other when advising a customer. [Migrate from Microsoft Entra Connect to Cloud Sync: Decision Guide](https://learn.microsoft.com/en-us/entra/identity/hybrid/cloud-sync/connect-to-cloud-sync-decision-guide)
- **`cloudNoFlow` is the single most important technical detail in this entire topic.** Every "why are both tools touching this object" ticket during an in-progress migration traces back to this rule pair's scoping — understanding it as a Connect-Sync-side export opt-out (not a Cloud-Sync-side setting) is what makes those tickets fast to diagnose.
- **Device sync has no Cloud Sync equivalent, full stop.** This single feature-comparison row (✓ in Connect, ✗ in Cloud Sync) is the most common reason a tenant lands in "plan for near-term" rather than "ready now" — flag it as the first question in any readiness conversation.
- **The feature comparison table is a living document, not a fixed spec.** Cloud Sync is actively closing parity gaps (Source of Authority conversion, Group Provisioning to AD, improved Exchange Hybrid support were all recent additions) — re-check the current table before treating any "Evaluate for future" classification as permanent.
- **Config backup is the entire safety net.** There's no in-place "undo migration" button — the Import/Export settings backup, taken before the first change, is what makes Playbook 2/3's rollback paths possible at all. [Import and export Microsoft Entra Connect configuration settings](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/how-to-connect-import-export-config)
- **A pilot OU's success doesn't generalize automatically.** Re-run the readiness checks per OU during a phased rollout — a later, larger OU can carry a dependency (an advanced sync rule, a near-50K-member group, device-sync-dependent users) the pilot never exercised.
