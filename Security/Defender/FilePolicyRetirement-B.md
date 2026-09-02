# Defender for Cloud Apps File Policy Retirement — Hotfix Runbook (Mode B: Ops)
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

Microsoft is retiring **File policies in Defender for Cloud Apps (MDA)** — the file-based DLP/
auto-labeling governance mechanism (Cloud Discovery and session/access policies are **not**
affected). Retirement date: **January 6, 2027**. File-based data protection is moving entirely to
**Microsoft Purview DLP** and **Purview auto-labeling policies**. There is a Microsoft-built
**DLP to Purview migration tool** inside the Defender portal that handles SharePoint/OneDrive
file policies for you.

```
1. Confirm this is actually a File Policy issue (not Cloud Discovery, not a session/access policy)
   Microsoft Defender portal > Cloud apps > Policies > Policy management > Type filter = "File policy"

2. Check whether the retirement banner/migration tool is visible
   Same page — a banner reading "File policies in Defender for Cloud Apps are retired on
   January 6, 2027" with a Migrate button confirms this tenant is in scope
```

| Result | Action |
|--------|--------|
| Ticket is about a file policy no longer matching files, or "why do we need to do this migration" | → Fix 1: run the built-in DLP to Purview migration tool |
| Ticket is about a policy the migration tool marked **Cannot migrate** or **Partial migration** | → Fix 2: manual recreation in Purview |
| Ticket is about an **auto-labeling** file policy (applies a sensitivity label, not DLP action) | → Fix 3: manual auto-labeling policy recreation — the tool doesn't migrate these yet |
| Ticket is about a **non-Microsoft app** (Box, Dropbox, Google Workspace, Salesforce) file policy | → Fix 4: manual recreation only — tool doesn't cover these apps yet |
| Ticket is "the migrated Purview policy isn't blocking/quarantining anything" | → Fix 5: migrated policies land in **Test with notifications** mode by design — enforcement must be turned on manually |
| Ticket is about Cloud Discovery, session policies, or access policies stopping working | → Not this retirement — those are unaffected; troubleshoot via `MDA-B.md` instead |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
[Defender for Cloud Apps File Policy — legacy]
  └─ API-based scanning of files already at rest in SharePoint/OneDrive/Box/Dropbox/
     Google Workspace/Salesforce, governance actions (quarantine, label, remove sharing)
         |
[June 2026 — retirement announced, Jan 6 2027 — retirement date]
  └─ File policies STOP being evaluated/enforced after this date
  └─ Cloud Discovery, session policies, access policies, threat detection all UNAFFECTED
         |
[DLP to Purview migration tool — Defender portal > Cloud apps > Policies > Policy management]
  └─ Reads existing SharePoint/OneDrive DLP file policies only
  └─ Groups each as Can migrate / Partial migration / Cannot migrate
  └─ Creates equivalent Purview DLP policies automatically (Test with notifications mode)
         |
[Microsoft Purview DLP / Auto-labeling — destination]
  └─ DLP detection+response policies for "protect on match" file policies
  └─ Auto-labeling policies for "apply a label" file policies (NOT covered by the migration tool —
     manual recreation required for every auto-labeling file policy)
  └─ Non-Microsoft app coverage (Box/Dropbox/Google Workspace/Salesforce) requires an existing
     Defender for Cloud Apps app connector — Purview reuses that connector, doesn't replace it
         |
[Policies in MDA and Purview CANNOT coexist for the same content]
  └─ Running the old file policy and new Purview policy simultaneously creates enforcement
     conflicts — disable the MDA file policy only after the Purview policy is validated
```

</details>

---
## Diagnosis & Validation Flow

**1. Inventory every File policy in Defender for Cloud Apps**
```
Microsoft Defender portal (security.microsoft.com) > Cloud apps > Policies > Policy management
Filter: Type = "File policy"
```
Document for each: target apps, content inspection method, sensitive info types/labels, context
filters, and governance action(s) — you need this before deciding DLP-vs-auto-labeling category.

**2. Categorize each policy**
- Detects sensitive content and takes a protective action (quarantine, remove sharing, alert) →
  **DLP detection and response** — migrate to a Purview DLP policy.
- Applies a sensitivity label based on content → **Auto-labeling** — migrate to a Purview
  auto-labeling policy (manual recreation; not covered by the migration tool).
- Does both → treat as two separate migrations, one of each type.

**3. Run the migration tool for eligible (SharePoint/OneDrive) policies**
```
Policy management > All policies tab > banner "File policies... are retired on January 6, 2027" >
Migrate
```
Step 1 of the wizard groups every policy as **Can migrate**, **Partial migration**, or
**Cannot migrate** — expand each policy's Notes to see why it landed in that group before
selecting which to run.

**4. Validate the migrated Purview policy before disabling the original**
```
Microsoft Purview portal (purview.microsoft.com) > Data loss prevention > Policies
Confirm: policy name "[Migrated] <original name> (1P DLP)", Mode = Test with notifications
Run in simulation mode, compare matches against the original MDA file policy's activity, THEN
turn enforcement on.
```

---
## Common Fix Paths

<details><summary>Fix 1 — Run the DLP to Purview migration tool (SharePoint/OneDrive DLP policies)</summary>

Use when: the affected file policy targets SharePoint and/or OneDrive and performs a DLP
detect-and-respond action (not labeling).

```
1. Confirm role: Security Administrator (to view MDA DLP policies) + Compliance Administrator
   (to create Purview DLP policies). Confirm Microsoft 365 E5 / E5 Compliance / equivalent
   standalone Purview DLP + Information Protection & Governance licensing.
2. Microsoft Defender portal > Cloud apps > Policies > Policy management > All policies tab.
3. Select "Migrate" on the retirement banner — opens the 4-step wizard.
4. Step 1: select the policy/policies (only "Can migrate" and reviewed "Partial migration"
   policies are safe to multi-select in one run).
5. Step 2: review the generated Purview payload per policy — check the Verdict, expand
   "Show payload" for any policy flagged with a warning that needs manual attention.
6. Step 3: DO NOT close the browser tab/window until Step 4 loads — closing early can create
   incomplete or misconfigured Purview policies.
7. Step 4: confirm every row shows "Created in Purview" in the Status column.
8. Open Microsoft Purview portal > Data loss prevention > Policies — confirm the new policy
   exists in Test with notifications mode.
9. Run in simulation, compare against the original MDA file policy's match history for at
   least a few days, THEN turn enforcement on and disable (not delete) the original MDA policy.
```

**Rollback:** Migration does not touch or remove the original MDA file policy — it only creates
a new, independent Purview policy. If the migrated policy misbehaves, simply leave it Off/in
simulation mode; the original MDA file policy keeps functioning until you manually disable it
(and until January 6, 2027 regardless).

</details>

<details><summary>Fix 2 — Manual recreation for a policy marked Cannot migrate or needing Partial-migration cleanup</summary>

Use when: the migration tool's Step 1 grouped the policy as **Cannot migrate**, or a
**Partial migration** policy needs manual completion of fields the tool couldn't map.

```
1. Microsoft Purview portal > Data loss prevention > Policies > Create policy.
2. Choose the closest matching template, or Custom policy to define conditions manually.
3. Set scope to the same locations as the original file policy (SharePoint sites /
   OneDrive accounts).
4. Recreate content conditions:
   - Same sensitive information types as the original (Purview DLP uses the same
     classification engine the file policy's Data Classification Service inspection used).
   - Custom regex patterns → recreate as a custom sensitive information type in Purview first,
     then reference it in the policy.
5. Recreate governance actions using the mapping table in FilePolicyRetirement-A.md
   "Governance Action Mapping" — flag any action with No equivalent (Trash/delete file,
   Expire shared link, Transfer file ownership) to the requesting team before proceeding;
   these need a different mechanism (Power Automate, SharePoint sharing policy, CA) or a
   documented capability gap.
6. Set to simulation mode, validate, then turn on.
```

**Rollback:** N/A — this creates a new policy alongside the still-functioning original; no
existing configuration is changed.

</details>

<details><summary>Fix 3 — Recreate an auto-labeling file policy in Purview (not covered by the migration tool)</summary>

Use when: the file policy applies a sensitivity label rather than a DLP action — the migration
tool does not migrate auto-labeling policies for Microsoft workloads yet (listed under its own
"Coming soon" callout).

```
1. Microsoft Purview portal > Information protection > Auto-labeling > Create auto-labeling
   policy.
2. Choose the sensitive information types/conditions matching the original file policy's
   content inspection rule.
3. Select the same sensitivity label the file policy applied.
4. Scope to the same SharePoint sites / OneDrive accounts (add specific sites/accounts if the
   original was scoped to particular groups).
5. Run in simulation mode first — review matched files before enabling automatic labeling.
6. Turn on. For files already at rest that need labeling retroactively (auto-labeling only
   labels new/changed files going forward), run an on-demand classification scan for the same
   sensitive information types.
```

**Rollback:** Turn the auto-labeling policy off; already-applied labels are not automatically
removed (use a separate "Remove labels only" auto-labeling policy if rollback of applied labels
is required).

</details>

<details><summary>Fix 4 — Non-Microsoft app (Box/Dropbox/Google Workspace/Salesforce) file policy</summary>

Use when: the affected file policy targets a connected non-Microsoft app — the migration tool
does not migrate these yet, and Purview coverage for them is in **preview**, rolling out in
phases (not guaranteed present in every tenant yet).

```
1. Confirm the app still has an active Defender for Cloud Apps app connector — Purview DLP for
   non-Microsoft apps reuses this connector rather than requiring a separate one.
2. Confirm Purview DLP for non-Microsoft connected apps is available in this tenant (preview,
   phased rollout — check Purview portal > Data loss prevention > Policies > Create policy for
   the app appearing as a location option before assuming parity).
3. If available: create policy using the Custom policy template ONLY — predefined templates
   (Financial, Medical/health, Privacy) do not support non-Microsoft app locations. Non-Microsoft
   app locations cannot be combined with SharePoint/OneDrive/Exchange/Teams/Devices in the same
   policy — use a separate policy per location type.
4. Configure using Advanced DLP rules (required for these apps; available conditions/actions
   vary by app). Policy tips and user overrides are not supported for non-Microsoft apps.
5. If not yet available in this tenant: recreate manually once it ships, and flag this policy
   as at-risk of a coverage gap between Jan 6 2027 (old policy retires) and whenever preview
   support lands for this tenant — escalate for a documented interim risk acceptance if the
   gap is likely to span the retirement date.
```

**Rollback:** N/A — non-Microsoft app policies are net-new in Purview; original MDA policy is
untouched until manually disabled.

</details>

<details><summary>Fix 5 — Migrated Purview policy isn't blocking/quarantining anything</summary>

Use when: migration completed (Fix 1) but the new Purview policy appears to do nothing.

```
1. Microsoft Purview portal > Data loss prevention > Policies > select the migrated policy.
2. Confirm Mode — every policy the migration tool creates lands in "Test with notifications"
   by design. This is expected, not a fault: it does NOT enforce actions until you turn it on.
3. Review simulation/test results in Data loss prevention > Activity explorer to confirm the
   policy is matching the expected content.
4. Once validated, edit the policy and switch from Test/simulation to On (enforce).
```

**Rollback:** Switch back to Test with notifications mode — no enforcement occurs, matching
continues to be logged for review.

</details>

---
## Escalation Evidence

```
MDA FILE POLICY RETIREMENT ESCALATION
==========================================
Date/Time                          :
Tenant ID                          :
Original MDA file policy name(s)   :
Target app(s)                      :
Policy category (DLP / labeling)   :
Migration tool used?               : Yes / No
Migration tool verdict             : Can migrate / Partial / Cannot migrate
Purview policy name (if created)   :
Purview policy mode                : Simulation / Test with notifications / On
Original MDA policy still enabled? : Yes / No
Error message (verbatim)           :
Steps Already Tried                :
```

---
## 🎓 Learning Pointers

- **The retirement date is January 6, 2027 — do not confuse it with the December 31, 2026 date
  circulating in some third-party MSP blog summaries.** Microsoft's own Learn documentation
  (`migrate-file-policies-to-purview`) states January 6, 2027 explicitly, twice, and is the
  authoritative source for change-management planning. [Migrate file policies to Microsoft
  Purview](https://learn.microsoft.com/en-us/defender-cloud-apps/migrate-file-policies-to-purview)
- **Only File policies are retiring.** Cloud Discovery, session/access policies, and threat
  detection inside Defender for Cloud Apps are explicitly unaffected — don't scope a client's
  entire MDA deployment into this migration project. See `MDA-B.md`/`-A.md` for the rest of the
  product.
- **Auto-labeling file policies and non-Microsoft app policies are NOT covered by the automated
  migration tool** — budget manual recreation time for both categories; don't assume the tool's
  "migration complete" banner covers 100% of a tenant's file policy inventory.
- **Migrated policies land in Test with notifications mode on purpose** — treat "the new policy
  isn't blocking anything" tickets as expected behavior requiring a manual on-switch after
  validation, not a migration failure.
- **MDA and Purview policies cannot enforce the same content simultaneously without conflict.**
  Always validate the Purview policy in simulation, then pilot enforcement, THEN disable (don't
  delete) the original MDA file policy — keep it disabled-but-present until confident, in case
  a rollback is needed before January 6, 2027.
