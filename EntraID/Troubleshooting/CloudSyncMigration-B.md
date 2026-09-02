# Entra Connect Sync → Entra Cloud Sync Migration — Hotfix Runbook (Mode B: Ops)
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
# Run ON the Entra Connect Sync server, with the ActiveDirectory RSAT module and
# a Graph connection (Connect-MgGraph -Scopes "Device.Read.All,Domain.Read.All") available.

# 1. Rough object-count scale per synced domain (Cloud Sync's documented cap is 150,000
#    objects per AD domain — Connect Sync has no such cap)
(Get-ADUser -Filter * -ResultSetSize $null).Count +
(Get-ADGroup -Filter * -ResultSetSize $null).Count +
(Get-ADObject -Filter 'objectClass -eq "contact"' -ResultSetSize $null).Count

# 2. Is this tenant relying on Hybrid Azure AD Join device sync? (Cloud Sync now has a
#    PREVIEW device sync feature closing this gap as of end of July 2026 -- see
#    CloudSyncDeviceSync-B.md -- but Cloud Kerberos Trust is still the GA-supported path)
Get-MgDevice -Filter "trustType eq 'ServerAd'" -ConsistencyLevel eventual -CountVariable deviceCount -Top 1
$deviceCount

# 3. Custom/advanced Entra Connect sync rules in play (Cloud Sync has no equivalent
#    sync-rule engine — it uses a simpler expression builder instead)
Import-Module ADSync -ErrorAction SilentlyContinue
(Get-ADSyncRule | Where-Object { -not $_.IsDefault }).Count

# 4. Largest AD group by member count (Cloud Sync caps groups at 50,000 members;
#    Connect Sync supports up to 250,000) — run only if group scale is a live concern,
#    this can be slow on a large directory
Get-ADGroup -Filter * -Properties Members |
  Sort-Object { $_.Members.Count } -Descending |
  Select-Object -First 5 Name, @{N='MemberCount';E={$_.Members.Count}}

# 5. PTA / ADFS federation in play (not a migration blocker — both are configured
#    separately from the sync tool and remain functional after migration — but worth
#    confirming before a customer assumes "migrating sync" also migrates authentication)
Get-Service AzureADConnectAuthenticationAgentService -ErrorAction SilentlyContinue | Select-Object Status
Get-MgDomain -All | Where-Object { $_.AuthenticationType -eq 'Federated' } | Select-Object Id
```

| Triage result | Interpretation | Do this |
|---|---|---|
| Combined user+group+contact count per domain exceeds ~150,000 | Above Cloud Sync's documented per-domain object scale limit | Fix 1 |
| `$deviceCount` > 0 | Hybrid Azure AD Join device sync in active use — Cloud Sync has a preview-status Device sync feature now, GA alternative is Cloud Kerberos Trust | Fix 2 |
| Non-default sync rule count > 0 | Custom/advanced sync rules exist that Cloud Sync's expression builder may not replicate | Fix 3 |
| A group shows a member count near or above 50,000 | Above Cloud Sync's group-size cap (also the Group Provisioning to AD DS cap) | Fix 4 |
| Customer wants to actually start the migration | This is the "how do I do it" fix path — pilot via a scoped OU, not a big-bang cutover | Fix 5 |
| Both Connect Sync and Cloud Sync appear to be touching the same user/group and objects are flapping or duplicating | Side-by-side sync of the *same* objects by both tools is unsupported | Fix 6 |
| Customer received (or expects) a Microsoft migration-wave notification and can't hit the window | Exception request needed — this is not something to route through this repo's usual fix paths | Fix 7 |
| Migration completed but needs to be reversed | Rollback path, contingent on having taken a config backup first | Fix 8 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Directional mandate: ALL customers eventually move from Connect Sync to Cloud Sync
(Microsoft guidance, announced April 2026) — this is a "when," not an "if," but
migration is Microsoft-phased, not a self-service flag flip for every tenant
   │
   ├─ Eligibility / wave assignment
   │     — Microsoft notifies a tenant when it becomes eligible to begin migrating
   │     — phased rollout, tenant notifications began July 2026
   │     — NOT chosen by the customer; based on their config against Cloud Sync's
   │           supported-scenario list
   │
   ├─ Readiness gate (independent of eligibility notification — check this FIRST)
   │     ├─ Object scale: <150,000 objects per AD domain
   │     ├─ Group scale: <50,000 members per group
   │     ├─ Not dependent on Hybrid Azure AD Join device sync (or willing to move
   │     │     to Cloud Kerberos Trust first/alongside, OR willing to accept
   │     │     preview-status risk on Cloud Sync's own Device sync feature --
   │     │     see CloudSyncDeviceSync-B.md)
   │     ├─ Not dependent on Advanced Sync Rules, cross-forest references, or
   │     │     out-of-band reconciliation (none of these exist in Cloud Sync)
   │     └─ OU-based filtering rather than complex attribute-based filtering
   │
   ├─ Prerequisites (Cloud Sync agent side — see CloudSync-A.md for full detail)
   │     ├─ Domain-joined server for the provisioning agent (Tier 0 hardening
   │     │       recommended), gMSA created during install
   │     ├─ Hybrid Identity Administrator account (non-guest)
   │     └─ AD schema attribute msDS-ExternalDirectoryObjectId (Server 2016+)
   │
   ├─ Migration mechanics (the part this file is actually about)
   │     ├─ Connect Sync and Cloud Sync CANNOT manage the same objects
   │     │       side by side — OU-based scoping is mandatory
   │     ├─ The "cloudNoFlow" custom inbound/outbound sync rule pair on Connect
   │     │       Sync is what excludes the pilot OU from Connect Sync's own export,
   │     │       so Cloud Sync can pick those objects up without a collision
   │     └─ Config backup (Import/Export settings) BEFORE any change — this is
   │             the only realistic rollback path
   │
   └─ Decommission (final step, only after a soak period)
         └─ Stop Connect Sync, leave disabled for a verification window, THEN
               uninstall — do not uninstall the same day as the final cutover
```

If Hybrid Azure AD Join, Advanced Sync Rules, or a >150K/50K-object scale limit is in play, treat this as "plan for later" rather than "migrate now" — pushing ahead anyway is the single most common way this migration goes wrong.

</details>

---
## Diagnosis & Validation Flow

1. **Establish why migration is being discussed.** Was a Microsoft eligibility notification received, or is this a proactive customer/MSP-driven request ahead of one? Both are valid, but a received notification changes the urgency and gives a recommended window to work within.
2. **Run the readiness triage above before touching anything.** A blocker here (device sync, advanced sync rules, scale) means this is a "plan for later" conversation, not a "migrate this week" one — don't let a Microsoft notification pressure a migration past a genuine feature-parity gap.
3. **If clear to proceed, confirm this is a pilot-OU migration, not a big-bang cutover.** Microsoft's own documented process is OU-by-OU, validated at each step — see Fix 5.
4. **Before making any change, back up the Microsoft Entra Connect configuration** via the Import/Export settings feature. This is the only supported rollback path if something goes wrong mid-migration.
5. **After each OU migrates, verify object counts match** between the pre-migration Connect Sync count and the post-migration Cloud Sync-synchronized count for that OU before moving to the next OU.
6. **Only decommission Connect Sync after a soak period** with it stopped-but-not-uninstalled — Microsoft explicitly recommends this so a rollback is still possible if a downstream issue surfaces late.

---
## Common Fix Paths

<details><summary>Fix 1 — Object count exceeds Cloud Sync's ~150,000-per-domain scale limit</summary>

This isn't a hard technical wall the same way a licensing gate is, but Microsoft's own decision guide places tenants over this limit in the "evaluate for future migration" bucket, not "ready now." Segmenting the migration by domain (in a multi-domain forest) or by a subset of OUs can sometimes bring an individual migration wave under the limit even if the tenant as a whole is over it — but this needs deliberate planning, not an ad hoc cutover.

**Rollback:** none needed — this is an assessment finding, not a change.
</details>

<details><summary>Fix 2 — Hybrid Azure AD Join device sync is in active use</summary>

As of end of July 2026, Cloud Sync has its own **Device sync (preview)** feature that synchronizes AD computer objects for Hybrid Azure AD Join purposes — this row in Microsoft's feature comparison table is no longer a flat ✗ (see `CloudSyncDeviceSync-A.md`/`-B.md` for full setup and troubleshooting). It is still preview-only: no GA SLA, one-directional (AD→Entra, no device writeback), and subject to change. A tenant relying on Hybrid Azure AD Join has two paths, not one: transition to **Cloud Kerberos Trust** (GA, the modern hybrid-join alternative that doesn't depend on the sync engine for device objects at all), or pilot Cloud Sync's own Device sync preview feature if the tenant is comfortable with preview-status risk. Either way this is a separate project with its own prerequisites, not a same-day Cloud Sync configuration toggle.

```powershell
# Confirm the scale of the dependency before scoping either path
Get-MgDevice -Filter "trustType eq 'ServerAd'" -All | Measure-Object
```

**Rollback:** none — this is a planning finding. Do not proceed with the Cloud Sync migration for device-dependent OUs until either Cloud Kerberos Trust is in place or the Device sync preview feature has been deliberately piloted and validated (`CloudSyncDeviceSync-B.md`).
</details>

<details><summary>Fix 3 — Custom/advanced Entra Connect sync rules are in use</summary>

```powershell
Import-Module ADSync
Get-ADSyncRule | Where-Object { -not $_.IsDefault } | Select-Object Name, Direction, Precedence
```
Cloud Sync replaces Connect Sync's full sync-rule engine with a simpler attribute-mapping expression builder. Review each custom rule's actual purpose — some (basic attribute transforms, simple filtering) have a direct Cloud Sync equivalent; others (complex joins, multi-source attribute merging, cross-forest reconciliation) do not and are explicitly unsupported in Cloud Sync per Microsoft's feature comparison. An OU or group depending on an unsupported rule type should stay on Connect Sync until Cloud Sync closes that specific gap — check the decision guide's comparison table for the current state before assuming a workaround exists.

**Rollback:** none — this is an assessment step.
</details>

<details><summary>Fix 4 — A group exceeds (or is near) 50,000 members</summary>

Cloud Sync's group member cap is 50,000 — lower than Connect Sync's 250,000. Split the group's membership across multiple groups, or adopt a staged-group approach (e.g., by region or business unit) so each individual group stays under the cap before that group's OU/scope migrates to Cloud Sync.

**Rollback:** none — this is a pre-migration remediation, not a reversible change in itself.
</details>

<details><summary>Fix 5 — Running the actual pilot migration (OU-based, staged)</summary>

This is Microsoft's documented process, condensed:

```powershell
# 1. Identify or create a pilot OU containing a small, low-risk set of test users
# 2. Get a baseline count of users in that OU before any change
Get-ADUser -Filter * -SearchBase "<DN path of pilot OU>" | Measure-Object

# 3. Stop the Entra Connect Sync scheduler before creating new sync rules
Set-ADSyncScheduler -SyncCycleEnabled $false

# 4. In the Synchronization Rules Editor, create the cloudNoFlow rule PAIR:
#    - INBOUND rule: join rule, target attribute cloudNoFlow, scoped to the pilot OU
#    - OUTBOUND rule: link type JoinNoFlow, scoping filter cloudNoFlow = True
#    This is what excludes the pilot OU's objects from Connect Sync's own export,
#    so Cloud Sync can pick them up without both tools fighting over the same objects.

# 5. Install the Cloud Sync provisioning agent (if not already installed), then
#    configure a Cloud Sync job scoped specifically to the pilot OU

# 6. Re-enable the Connect Sync scheduler
Set-ADSyncScheduler -SyncCycleEnabled $true

# 7. Verify: pilot-OU user count synchronizing via Cloud Sync should match step 2's
#    baseline. Create a brand-new test user in the pilot OU and confirm it provisions
#    through Cloud Sync, not Connect Sync.
```
Once the pilot OU is validated, repeat with progressively larger OUs on a phased schedule — never attempt every OU in a single cutover window.

**Rollback:** disable the Cloud Sync job scope for the pilot OU and remove the cloudNoFlow inbound/outbound rule pair from Connect Sync — this returns the pilot OU to Connect Sync-only management. Confirm the config backup taken before step 3 is available as a full fallback if the sync-rule removal itself causes issues.
</details>

<details><summary>Fix 6 — Both tools appear to be managing the same objects (flapping/duplication)</summary>

Running Connect Sync and Cloud Sync side by side for the *same* objects is explicitly unsupported. If objects in a supposedly-migrated OU are still showing Connect Sync activity, the cloudNoFlow scoping filter from Fix 5 likely isn't correctly excluding that OU — re-check the outbound rule's scoping condition (`cloudNoFlow = True`) and confirm the inbound join rule is actually being applied to every object in that OU (a nested-OU or naming mismatch is the most common cause).

```powershell
# Confirm which objects the cloudNoFlow outbound rule is actually excluding
Get-ADSyncRule -Identity "<cloudNoFlow outbound rule name>" | Select-Object Name, Direction, ScopeFilter
```

**Rollback:** none beyond correcting the scoping filter — this is a misconfiguration fix, not a destructive change.
</details>

<details><summary>Fix 7 — Can't migrate within Microsoft's recommended window</summary>

Request an exception. Per Microsoft's own migration FAQ, a tenant unable to migrate within its assigned window should work with Microsoft Support or their account team to plan an appropriate alternative timeline — this is not a self-service extension, and there is no documented automatic grace period. Document the specific blocking dependency (scale, device sync, unsupported sync rule) as part of the exception request; "we haven't gotten to it yet" and "we have a documented unsupported-feature dependency" are treated very differently.

**Rollback:** n/a — this is a scheduling/escalation action, not a technical change.
</details>

<details><summary>Fix 8 — Migration needs to be rolled back</summary>

```powershell
# Re-enable the Connect Sync scheduler if it was stopped
Set-ADSyncScheduler -SyncCycleEnabled $true
```
If the config backup was taken before migration began (Diagnosis step 4), restore it via the Import/Export settings feature. If only a specific OU's cloudNoFlow rule pair needs reverting rather than a full config restore, removing that rule pair (Fix 5's rollback) returns just that OU to Connect Sync-only management without touching anything else. Do not uninstall Connect Sync until every in-scope OU has been fully validated post-migration and the recommended soak period has passed — an uninstalled Connect Sync server has no rollback path at all.

**Rollback:** this fix *is* the rollback — there's no further fallback beyond the original config backup and (if applicable) a VM snapshot of the Connect Sync server taken before migration started.
</details>

---
## Escalation Evidence

```
Tenant/customer name: ____________________
Migration trigger (Microsoft wave notification / proactive): ____________________
Combined AD object count (users+groups+contacts) per domain: ____________________
Largest AD group member count: ____________________
Hybrid Azure AD Join device count (trustType eq 'ServerAd'): ____________________
Non-default Connect Sync rule count: ____________________
PTA agent service present (Y/N): ____________________
ADFS-federated domain(s) present (Y/N): ____________________
Config backup taken before migration started (Y/N, date): ____________________
Pilot OU used and validated (Y/N, OU path): ____________________
Current migration phase (not started / pilot / phased rollout / soak period / decommissioned): ____________________
Specific blocker (if any): ____________________
```

---
## 🎓 Learning Pointers

- **This is a Microsoft-mandated direction, not an optional modernization project.** All customers ultimately move from Connect Sync to Cloud Sync — the open questions are timing and readiness, not whether. Build this into every customer's hybrid-identity roadmap conversation now rather than waiting for their eligibility notification. [Migrate from Microsoft Entra Connect to Cloud Sync: Decision Guide](https://learn.microsoft.com/en-us/entra/identity/hybrid/cloud-sync/connect-to-cloud-sync-decision-guide)
- **Readiness and eligibility are two different gates.** Microsoft's wave notification tells you *when* you're invited to migrate; it says nothing about whether your specific configuration (device sync, advanced sync rules, scale) is actually a good fit yet. Run the readiness triage independently of any notification timeline.
- **The cloudNoFlow rule pair is the real mechanism behind "no side-by-side sync."** Understanding that Connect Sync has to be told to explicitly stop exporting an OU (not just told that Cloud Sync now also covers it) explains most of the "why are both tools touching this user" tickets during a migration in progress.
- **Device sync is no longer an automatic blocker — but it's still preview, so treat it as a risk conversation, not a solved problem.** Cloud Sync's own Device sync (preview) feature can now close a Hybrid Azure AD Join dependency (see `CloudSyncDeviceSync-A.md`/`-B.md`), but Cloud Kerberos Trust (GA) remains the safer default for a production-critical dependency. Flag this early in any migration conversation either way, since whichever path is chosen is a separate project with its own timeline.
- **Treat the config backup as non-negotiable, not a nice-to-have.** There is no in-place downgrade for a Connect Sync server the way there's no rollback for a Cloud Sync migration without one — the Import/Export settings backup is the entire safety net. [Import and export Microsoft Entra Connect configuration settings](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/how-to-connect-import-export-config)
- **Don't decommission Connect Sync the same day as the final OU cutover.** Microsoft explicitly recommends a soak period with the service stopped-but-installed before uninstalling — this is the difference between a same-day rollback and a full disaster-recovery rebuild if something surfaces late.
