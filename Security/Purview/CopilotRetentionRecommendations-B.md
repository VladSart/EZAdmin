# Purview Copilot & AI App Retention Insights (Roadmap 561209) — Hotfix Runbook (Mode B: Ops)
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

**This is a new insights/recommendations layer, not a new deletion mechanism.** Microsoft 365 Roadmap
ID 561209 adds a capability inside Microsoft Purview Data Lifecycle Management that analyzes how
employees use Microsoft Copilot and other AI apps, then **recommends** retention policies for the
resulting prompts and responses — entering preview around August 2026, targeted GA September 2026.
The underlying retention *mechanism* for Copilot/AI app messages already exists and is unchanged by
this feature (separate **Microsoft Copilot experiences** / **Enterprise AI apps** / **Other AI apps**
retention locations, in place since the Teams-chat-and-Copilot split). Most tickets here are "what is
this new recommendation banner/panel" or "should we accept this suggested policy," not a defect.

```powershell
Connect-IPPSSession -UserPrincipalName <adminUPN>

# 1. What retention policies already target AI app locations?
Get-RetentionCompliancePolicy | Where-Object {
    $_.Copilot -or $_.SkypeLocation -match "AI" -or $_.ModernGroupLocation
} | Select-Object Name, Enabled, Copilot, ExchangeLocation

# 2. Confirm the exact locations a given policy covers (Copilot experiences vs Enterprise AI apps vs Other AI apps)
Get-RetentionCompliancePolicy -Identity "<PolicyName>" | Format-List Name, Copilot, ExchangeLocation, ExchangeLocationException

# 3. Is a collection policy configured to actually capture the AI app's prompts/responses in the first place?
#    (A retention policy on an AI app location does nothing if content isn't being collected)
Get-CollectionPolicy 2>$null | Select-Object Name, Enabled, Workload
```

| Result | Interpretation |
|---|---|
| Admin asks "where do I see the new recommendations" | Purview portal only, under Data Lifecycle Management — no PowerShell/Graph surface exists for the recommendation engine itself as of this writing. Go to Fix 1. |
| Admin wants to know if a recommendation is safe to auto-apply | It isn't automatic by design — Microsoft's own roadmap language stops short of promising auto-activation. Treat every recommendation as a proposal requiring compliance/legal review. Go to Fix 2. |
| A recommended policy conflicts with an existing retain-forever policy or a Litigation/eDiscovery hold | Expected and safe — the **first principle of retention** (preservation wins) means the longer/held requirement always takes precedence; no data loss risk from applying a shorter recommended policy on top. Go to Fix 3. |
| User asks why a Copilot conversation they deleted is still returned by eDiscovery | Not a bug — deletion in the AI app UI is not the same as permanent backend deletion. See Fix 4. |
| Recommendation references an AI app the org didn't know was in use | Expected value of the feature — treat as a shadow-AI discovery signal, not solely a retention question. Go to Fix 5. |
| Admin wants a "one day" delete-only recommendation to mean true one-day erasure | Not accurate — see Fix 4's timing math; escalate expectations internally rather than the platform. |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
[Microsoft Purview portal — Data Lifecycle Management]
        |
[Insights & recommendations layer (Roadmap 561209, preview ~Aug 2026, GA target Sep 2026)]
  └─ Analyzes OBSERVED AI app usage the tenant already has visibility into
        |
[Visibility depends on collection configuration per AI app category]
  ├─ Microsoft Copilot experiences (M365 Copilot, Security Copilot, Copilot in Fabric, Copilot Studio)
  │     └─ Captured by default once Copilot is licensed/used — no separate collection policy needed
  ├─ Enterprise AI apps (Entra-registered AI apps, ChatGPT Enterprise, Microsoft Foundry)
  │     └─ Requires a collection policy configured to capture content — see collection-policies-solution-overview
  └─ Other AI apps (ChatGPT, Google Gemini, consumer Copilot, DeepSeek)
        └─ Requires a collection policy — narrowest, most likely to be incompletely configured
        |
[Recommendation surfaced to admin]
  └─ Proposes a retention policy scope/duration — NOT auto-applied (undocumented whether Microsoft
        will ever change this; treat as proposal-only until Microsoft states otherwise)
        |
[If admin accepts and creates/edits a retention policy]
  └─ Falls onto the EXISTING, unchanged Purview retention mechanism for AI app messages:
        Exchange hidden mailbox folder → timer job (1-7 days) → SubstrateHolds folder (>=1 day) →
        timer job (1-7 days) → permanent deletion
        |
[Principles of retention — always evaluated, independent of this new feature]
  └─ Preservation wins: a longer retention policy, Litigation Hold, delay hold, or eDiscovery hold
        on the same mailbox suspends permanent deletion regardless of what any shorter policy or
        recommendation says
```

</details>

---
## Diagnosis & Validation Flow

**1. Inventory existing AI-app-scoped retention policies**
```powershell
Connect-IPPSSession -UserPrincipalName <adminUPN>
Get-RetentionCompliancePolicy | Select-Object Name, Enabled, Copilot
```
`Copilot` (or an AI-app-specific location property, naming may still be shifting pre-GA) being blank
or `$false` on a policy the admin *thought* covered Copilot is a common false assumption — Teams chat
policies and Copilot policies are separate since the split documented in `retention-policies-copilot`.

**2. Confirm collection is actually happening for the AI app in question**
Retention only governs content that's been captured. For **Enterprise AI apps** and **Other AI apps**
specifically, verify a collection policy exists and is enabled; for first-party Copilot experiences,
collection is automatic and this step can be skipped.

**3. Cross-check a specific user's hidden mailbox state (support-ticket scenario)**
There is no supported cmdlet to browse the hidden AI-message folder directly. Use eDiscovery (Content
Search or an eDiscovery case) scoped to the user's mailbox with an AI-app-relevant keyword/date range
to confirm whether a message is still retained, rather than trusting what the AI app's own chat
history currently shows.

**4. Rule out timing confusion on a "delete-only, 1 day" policy**
A delete-only policy configured for 1 day can still take up to ~16 days end-to-end (timer job cycles
of 1-7 days at two separate stages, plus the SubstrateHolds minimum 1-day hold) before a message stops
appearing in eDiscovery. This is expected service behavior, not a stuck job.

**5. Confirm licensing/metering for any newly-recommended AI app location**
Microsoft's current Data Lifecycle Management guidance notes that policies covering Microsoft Copilot
experiences, Enterprise AI apps, and Other AI apps can carry pay-as-you-go billing requirements —
verify licensing before rolling a recommendation into production, not after.

---
## Common Fix Paths

<details><summary>Fix 1 — Locate and review a surfaced recommendation</summary>

Use when: an admin can't find where the new recommendations appear, or wants to walk through one.

```
1. Microsoft Purview portal (https://purview.microsoft.com/) > Data Lifecycle Management.
2. Look for an insights/recommendations panel or banner (exact placement/naming may shift during
   preview — Microsoft's roadmap entry does not disclose UI specifics as of this writing).
3. Review what the recommendation discloses: affected AI app category, approximate user/activity
   scope, and proposed retain/delete behavior. Do not assume parity across tenants — Microsoft has
   not documented whether recommendations vary by department, geography, or sensitivity signals.
4. Do NOT accept the recommendation directly from this screen without Fix 2's review pass.
```

**Rollback:** N/A — reviewing a recommendation makes no changes.

</details>

<details><summary>Fix 2 — Route a recommendation through review before activating</summary>

Use when: a recommendation looks reasonable and someone wants to turn it into a live policy.

```
1. Do NOT treat the recommendation as a compliance determination — it identifies technical activity
   and proposes a configuration; it cannot determine whether a given conversation is a regulated
   business record or how long the law/contract actually requires it be kept.
2. Route to compliance/legal/privacy (and Microsoft 365 admin) for joint review, per this org's
   existing retention-policy change process.
3. On acceptance, create the policy explicitly via Get-started-with-data-lifecycle-management /
   Create-retention-policies guidance rather than relying on any one-click "accept" if offered —
   confirm the resulting policy's actual location scope and duration match what was reviewed.
4. Verify with Diagnosis Step 1 that the created policy's Copilot/AI-app location property reflects
   what was intended.
```

**Rollback:** Disable or delete the resulting retention policy via
`Set-RetentionCompliancePolicy -Identity "<Name>" -Enabled $false` / `Remove-RetentionCompliancePolicy`.

</details>

<details><summary>Fix 3 — Recommended policy appears to conflict with an existing hold</summary>

Use when: a recommended delete-oriented policy targets content also under Litigation Hold, a
delay hold, or an eDiscovery hold.

```
1. No action needed to prevent data loss — per the first principle of retention, preservation always
   wins. The shorter/delete policy will not permanently remove held content.
2. If the goal is genuinely to reduce retained AI-app data despite a hold, that requires releasing or
   narrowing the hold itself (a separate, deliberate legal/compliance decision) — not something this
   feature does or should override automatically.
3. Document the conflict for the reviewing team so the recommendation isn't silently re-surfaced
   without context each review cycle.
```

**Rollback:** N/A — no destructive action is taken by the conflicting policy while the hold is active.

</details>

<details><summary>Fix 4 — User reports a "deleted" AI conversation still found via eDiscovery</summary>

Use when: a user or investigator is confused that a chat removed from the AI app's UI is still
searchable.

```
1. Explain the two-copy model: the AI app's own UI does not reflect the compliance copy's real state.
   Removing a chat client-side starts the backend process but does not immediately purge the Exchange
   hidden-folder copy.
2. Walk through the applicable timing: item moves to SubstrateHolds (>=1 day), then permanent deletion
   on the next timer job run (typically another 1-7 days) — unless another retention policy or hold
   applies, in which case it is not deleted at all.
3. For an active legal/investigative need, this is by design, not a fix to make — the searchability
   window IS the compliance control working as intended.
```

**Rollback:** N/A — diagnostic/explanatory only.

</details>

<details><summary>Fix 5 — Recommendation surfaces an unrecognized AI app in use</summary>

Use when: a recommendation references an AI app category the security/compliance team didn't know
employees were using.

```
1. Treat this as a shadow-AI / data-exfiltration-risk finding first, retention-policy question second.
2. Cross-reference with Entra enterprise app registrations (Enterprise AI apps category) or, for
   consumer "Other AI apps" (ChatGPT, Gemini, DeepSeek, consumer Copilot), with existing DLP/network
   controls — see Security/Purview/NetworkDataSecurity-A.md for the GSA-based content-layer control
   that can restrict traffic to unmanaged AI services rather than just retaining what already left.
3. Only after the exposure question is addressed, proceed with the retention-policy recommendation on
   its own merits via Fix 2.
```

**Rollback:** N/A — investigative.

</details>

---
## Escalation Evidence

```
PURVIEW COPILOT RETENTION RECOMMENDATION ESCALATION
=====================================================
Date/Time                              :
Tenant cloud (Worldwide/GCC/GCC High/DoD) :
AI app category involved               : Microsoft Copilot experiences / Enterprise AI apps / Other AI apps
Specific app (if known)                :
Recommendation text/screenshot         :
Existing retention policy on this location? : Yes/No — Name:
Existing hold on affected mailbox(es)? : Yes/No — Type:
Collection policy confirmed enabled?   : Yes/No/N-A (first-party Copilot)
Licensing/pay-as-you-go confirmed?     : Yes/No
Steps Already Tried                    :
```

---
## 🎓 Learning Pointers

- **The recommendation engine is new; the retention mechanism it recommends into is not.** Don't
  troubleshoot this as if it introduces a new deletion pipeline — it proposes configuration for the
  existing Exchange-hidden-folder/SubstrateHolds pipeline documented in
  [Learn about retention for Copilot & AI apps](https://learn.microsoft.com/en-us/purview/retention-policies-copilot).
- **"Delete after 1 day" never means erased in 1 day.** Build this timing model into any SLA or
  privacy-request commitment language before promising a deletion timeframe to stakeholders.
- **Preservation always wins.** A recommended short-retention or delete-only policy can safely coexist
  with a longer policy or hold on the same content — Purview will never let the shorter one win.
- **Enterprise AI apps and Other AI apps require a collection policy; first-party Copilot experiences
  don't.** A recommendation with zero visibility into a given AI app is a collection-configuration gap,
  not evidence the app isn't being used.
- **Treat every recommendation as a proposal, not a mandate.** Microsoft's own roadmap language avoids
  promising auto-activation — route through compliance/legal review every time, especially early in
  preview when recommendation logic/thresholds are undocumented.
- Community analysis: [Purview Recommends Copilot Retention Policies in September 2026](https://windowsforum.com/windows-news.4/microsoft-purview-recommends-copilot-retention-policies-in-september-2026.438268/) (Roadmap ID 561209 — preview and GA dates per this source; reconfirm against the live Microsoft 365 Roadmap before treating as final).
