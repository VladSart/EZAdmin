# Microsoft Secure Score — Hotfix Runbook (Mode B: Ops)
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

> **First: confirm which "Secure Score" the ticket is actually about.** Three different Microsoft products use the same name for three different, non-interoperable scores. If the ticket says "Secure Score" and mentions an Azure subscription/resource, you're in the wrong runbook — go to `DefenderForCloud-B.md`. If it's about a single device's exposure/vulnerability score, cross-check `DefenderVulnMgmt-B.md`. This runbook covers only the tenant-wide score at **security.microsoft.com/securescore** (Identity/Device/Apps/Data).

Run via Microsoft Graph PowerShell (`Connect-MgGraph -Scopes "SecurityEvents.Read.All"`):

```powershell
# 1 — Current tenant-wide score (most recent daily snapshot)
$score = Get-MgSecuritySecureScore -Top 1
$score | Select-Object CreatedDateTime, CurrentScore, MaxScore,
    @{N="Percent";E={[math]::Round(($_.CurrentScore/$_.MaxScore)*100,1)}}

# 2 — Which workloads are actually contributing (license/enablement gate)
$score.EnabledServices

# 3 — Per-category rollup (Identity / Device / Apps / Data)
$score.ControlScores | Group-Object ControlCategory |
    ForEach-Object { [pscustomobject]@{ Category=$_.Name; Points=($_.Group.Score | Measure-Object -Sum).Sum } }

# 4 — Compare against the previous daily snapshot (regression check)
$last2 = Get-MgSecuritySecureScore -Top 2
$delta = $last2[0].CurrentScore - $last2[1].CurrentScore
"Score changed by $delta points since $($last2[1].CreatedDateTime)"

# 5 — Your own RBAC/permission gate for the portal itself
Get-MgUserMemberOf -UserId (Get-MgContext).Account -All |
    Select-Object -ExpandProperty AdditionalProperties | Select-Object displayName
```

| Result | Likely cause | Go to |
|--------|-------------|-------|
| `EnabledServices` missing a workload the client definitely owns | License/enablement lag (24–48h) or the workload was never provisioned | Fix 2 |
| Score dropped between the two most recent snapshots | Genuine regression — someone changed a control | Fix 1 |
| A recommendation the engineer fixed manually still shows unresolved | Points take 24–48h to reflect after a config change | Fix 3 (patience) or Fix 4 (third-party tool) |
| A "Device" category action won't accept a status change in the portal | Device category routes to Defender Vulnerability Management, not Secure Score directly | Fix 5 |
| Portal shows blank/"no access" for a user who should see it | Missing Defender XDR Unified RBAC "Exposure Management" role or legacy Entra role | Fix 6 |
| Graph script returns 403/empty despite the user having portal access | Graph API doesn't yet honor Unified RBAC custom roles — needs a legacy Entra role or app permission | Fix 6 |

---

## Dependency Cascade

<details><summary>What must be true for a score to be accurate</summary>

```
[Workload licensed & provisioned for the tenant]
        │  (Entra ID, Exchange Online, SharePoint Online, Teams, MDE, MDI,
        │   MDCA, Purview Information Protection, App Governance/OAuth apps,
        │   + connected non-Microsoft: Okta, Salesforce, ServiceNow, GitHub,
        │   Docusign, Zoom, Citrix ShareFile)
        ▼
[Workload appears in EnabledServices on the secureScore object]
        │  if missing here, EVERY recommendation for that workload is absent
        │  from the score — not a bug, expected behavior
        ▼
[secureScoreControlProfiles evaluated against live config]
        │  refresh cadence varies: most = real-time + daily sync;
        │  Teams & Entra recommendations = weekly/monthly only
        ▼
[controlScores computed — points awarded, full or partial]
        │  most controls are binary (100% or 0%); some are percentage-of-
        │  population (e.g. "% of users covered by MFA")
        ▼
[currentScore / maxScore aggregated into the tenant secureScore object]
        ▼
[Portal / Graph API — gated by RBAC]
        ├── Defender XDR Unified RBAC "Exposure Management" (read/manage)
        ├── Legacy Entra global roles (Security Admin+ = read/write,
        │       Security Reader/Global Reader/etc. = read-only)
        └── Graph API access specifically = legacy Entra roles ONLY —
                Unified RBAC custom roles are not yet honored by the API
```

**Key structural fact:** Secure Score shows every possible recommendation for a product regardless of which license edition the tenant owns, so the maximum score is the same for every tenant on a given product mix. What changes per-tenant is `EnabledServices` (which products are present at all) and `currentScore` (how many of those points are actually earned).

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm which Secure Score the ticket means**
Ask: "Azure subscription/resource, or Microsoft 365 tenant-wide?" If Azure → `DefenderForCloud-B.md`. This runbook only covers the M365 tenant-wide score.

**Step 2 — Pull the current score and category breakdown**
```powershell
$score = Get-MgSecuritySecureScore -Top 1
$score | Select-Object CreatedDateTime, CurrentScore, MaxScore, LicensedUserCount, ActiveUserCount
```
Expected: a recent `CreatedDateTime` (within the last 24h — the score syncs daily even though the portal visualization updates in real time).

**Step 3 — If a regression is reported, diff against history**
```powershell
$history = Get-MgSecuritySecureScore -Top 30 | Sort-Object CreatedDateTime
for ($i = 1; $i -lt $history.Count; $i++) {
    $d = $history[$i].CurrentScore - $history[$i-1].CurrentScore
    if ($d -ne 0) { "$($history[$i].CreatedDateTime): $d points" }
}
```
Cross-reference the date of the drop against CA policy changes, license removals, or TVM exceptions granted around that date (see `Security/ConditionalAccess/` and `DefenderVulnMgmt-B.md`).

**Step 4 — If a specific recommendation is stuck, pull its control profile**
```powershell
$controls = Get-MgSecuritySecureScoreControlProfile -All
$controls | Where-Object { $_.Title -like "*<keyword>*" } |
    Select-Object Id, Title, ControlCategory, MaxScore, Rank, ImplementationCost, UserImpact, Tier, ActionUrl
```
Cross-reference the `Id`/`ControlName` against `$score.ControlScores` to see current points earned for that specific control.

**Step 5 — Check the control's status history**
```powershell
($controls | Where-Object Id -eq "<ControlId>").ControlStateUpdates |
    Select-Object State, Comment, UpdatedBy, UpdatedDateTime
```
`State = Default` means nobody has manually set a status — the score reflects live configuration only, not a manual override.

**Step 6 — Confirm RBAC if the reporting engineer can't see the data**
Portal access: Defender portal > Permissions > Roles (Unified RBAC) — check the "Security posture" category for Exposure Management read/manage. Legacy path: Entra ID > Roles — Security Administrator or higher for write, Security Reader/Global Reader for read-only.

---

## Common Fix Paths

<details>
<summary>Fix 1 — Score dropped between snapshots (genuine regression)</summary>

1. Run the Step 3 diff loop to identify the exact date and delta.
2. Pull the Defender portal's own **History** tab (Secure Score > History) for the same date range — it lists the specific action and category, which the Graph API's `secureScores` history does not break out per-control as cleanly.
3. Common real causes, roughly in order of frequency:
   - A Conditional Access policy protecting MFA/legacy-auth was disabled or scoped down
   - A batch of user licenses were removed (shrinks the denominator for percentage-based controls, which can lower `currentScore` even with no config change)
   - A Defender Vulnerability Management exception was granted for a device-category recommendation
   - A third-party tool that was previously marked "Resolved through third party" was disconnected, but the manual status was never reverted — check `ControlStateUpdates` for a stale override
4. Fix the underlying configuration (not the score directly — the score is a read-only reflection of state).
5. Allow 24–48h for the fix to reflect. Do not re-run the diff before then; a fix applied today will not show today.

**Rollback:** N/A — this is a diagnostic/config-fix path, not a destructive change.
</details>

<details>
<summary>Fix 2 — A known workload is missing from EnabledServices</summary>

1. Confirm the license is actually assigned tenant-wide, not just to a pilot group:
   ```powershell
   Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits
   ```
2. Confirm the workload is provisioned (e.g., MDE onboarded — see `MDE-Onboarding-B.md`; MDI sensor installed — see `MDI-B.md`).
3. If newly licensed/provisioned, allow up to 48h for `EnabledServices` to pick it up — this is a known propagation delay, not a fault.
4. If still missing after 48h with confirmed licensing and provisioning, escalate — this is one of the few genuine Microsoft-side sync issues worth a support ticket.

**Rollback:** N/A — read-only diagnostic.
</details>

<details>
<summary>Fix 3 — Manually fixed a recommendation but score hasn't moved</summary>

1. Confirm the fix was actually applied at the workload level (not just planned) — Secure Score reflects live state, it does not accept "I fixed it" as an input for Microsoft-managed controls.
2. Check the elapsed time. Per Microsoft's own guidance, allow 24–48 hours after a change before expecting the score to update.
3. If more than 48h have passed, re-verify the underlying config actually took effect (a GPO/Intune conflict can silently prevent a setting from applying — see `Intune/Troubleshooting/Policy-Conflict-A.md`).
4. For Teams- and Entra-specific recommendations specifically: these refresh weekly/monthly, not daily — this is a documented exception, not a bug.

**Rollback:** N/A.
</details>

<details>
<summary>Fix 4 — Fixed via a non-Microsoft tool, score still shows unresolved</summary>

Microsoft has no visibility into third-party tools by default — the status must be set manually.

1. Defender portal > Secure Score > Recommended actions > select the action.
2. Set status to **Resolved through third party** (a dedicated non-Microsoft app/software addressed it) or **Resolved through alternate mitigation** (an internal/compensating control addresses the same risk).
3. This awards the points immediately in the score calculation (subject to the normal ~24h refresh), even though Microsoft cannot verify the underlying implementation — document the actual mitigation in the action's **Notes** field for the next engineer/auditor.
4. If the third-party tool or mitigation is later removed, this status must be manually reverted — nothing automatically re-flags it. Build this into decommission checklists.

**Rollback:** Revert the status to "To address" from the same flyout if the mitigation is removed.
</details>

<details>
<summary>Fix 5 — "Device" category recommendation won't accept a status change</summary>

This is by design — Secure Score's Device category is a read-through view of Defender Vulnerability Management, not an independently editable list.

1. Go to the linked **Microsoft Defender Vulnerability Management** security recommendation (the action's flyout has a direct link) instead of trying to set status in Secure Score.
2. To resolve: fix the underlying misconfiguration, OR create a **Global exception** in TVM.
   - A **Global exception** updates the Secure Score status — allow up to ~2 hours.
   - An **Exception per device group** does **not** update Secure Score — the action stays "To address" even though TVM shows it excepted for that group. This asymmetry is the #1 cause of "I already excepted this, why does Secure Score still show it open" tickets.
3. If the client specifically needs the Secure Score number to reflect a device-group-scoped exception, there is no supported way to do that — document the discrepancy rather than trying to force it.

**Rollback:** Remove the TVM exception to restore the recommendation to active.
</details>

<details>
<summary>Fix 6 — User/script can't see Secure Score data (RBAC)</summary>

**Portal access (interactive user):**
1. Check Defender portal > Permissions & roles > Roles (Unified RBAC) for a custom role granting **Exposure Management (read)** or **(manage)** under the "Security posture" category, with the **Microsoft Security Exposure Management** data source assigned.
2. If no custom Unified RBAC role is assigned, fall back to legacy Entra global roles: Security Administrator, Exchange Administrator, or SharePoint Administrator grant read/write; Security Reader, Security Operator, Global Reader, Helpdesk Administrator, User Administrator, or Service Support Administrator grant read-only.
3. If the user has a Unified RBAC custom role but was previously relying on an Entra global role, both can coexist — but Microsoft recommends removing the redundant elevated Entra role once the custom role is confirmed working, to keep least-privilege intact.

**Graph API / automation (service principal or script):**
1. Confirm the app registration or signed-in user has been granted `SecurityEvents.Read.All` (or `.ReadWrite.All`) and that admin consent was granted.
2. **Important:** as of this writing, Graph API access to Secure Score is **not yet covered by Defender XDR Unified RBAC** — it still relies on the legacy Entra global role model. A user/app with only a Unified RBAC custom role but no qualifying legacy Entra role assignment will get 403s calling `Get-MgSecuritySecureScore` even though they can see the same data fine in the portal. Assign a legacy read role (e.g., Security Reader) to unblock automation specifically.

**Rollback:** N/A — permission grants, not destructive changes.
</details>

---

## Escalation Evidence

```
=== MICROSOFT SECURE SCORE ESCALATION ===
Date/Time      :
Engineer       :
Ticket         :

Tenant         :
Confirmed this is the M365 tenant-wide Secure Score (NOT Defender for Cloud CSPM, NOT a single-device TVM exposure score): Yes/No

Current Score  : (CurrentScore / MaxScore, from Get-MgSecuritySecureScore -Top 1)
Snapshot Date  : (CreatedDateTime)
EnabledServices: (list)

Issue Type     : [ ] Unexpected regression  [ ] Missing workload/recommendation
                 [ ] Manual fix not reflected  [ ] Device-category status stuck
                 [ ] RBAC/access  [ ] Other:

If regression:
  Delta          :
  Date of change :
  Correlated config change (CA policy / license / TVM exception):

If specific control:
  Control Id/Name :
  Category        :
  Current / Max points :
  Rank / ImplementationCost / UserImpact :
  ControlStateUpdates (last state, who, when):

Steps Attempted:
1.
2.
3.

Expected behavior :
Actual behavior   :
```

---

## 🎓 Learning Pointers

- **Three products share the phrase "Secure Score" and none of them talk to each other:** M365 Defender's tenant-wide score (this doc), Defender for Cloud's Azure resource CSPM score (`DefenderForCloud-A.md`), and the per-device exposure score inside Defender Vulnerability Management (`DefenderVulnMgmt-A.md`). Confirming which one a ticket means is the highest-leverage first question. [MS Docs: Microsoft Secure Score](https://learn.microsoft.com/en-us/defender-xdr/microsoft-secure-score)
- **Points take 24–48 hours to reflect, and Teams/Entra recommendations refresh even slower** (weekly/monthly). A huge share of "I fixed it, why isn't the score updated" tickets are just this delay. [MS Docs: Take action to improve your score](https://learn.microsoft.com/en-us/defender-xdr/microsoft-secure-score-improvement-actions)
- **A Global exception in TVM updates Secure Score; a per-device-group exception does not.** This asymmetry is undocumented in most client-facing explanations and is worth proactively flagging to clients who scope exceptions narrowly.
- **Secure Score shows every recommendation for a licensed-or-not product** — the maximum achievable score is not inflated or deflated by which specific license SKU a tenant owns, only by which products are enabled at all (`EnabledServices`). Use the portal's "Current license score" view to see what's actually achievable without a new purchase.
- **Graph API automation needs a legacy Entra role, even if the human user only has a Unified RBAC custom role.** Unified RBAC coverage for the Graph API is still pending as of this writing — don't burn time debugging a "working in the portal but not in my script" case as an app-permission problem before checking this.
- **Third-party/alternate-mitigation statuses are manual and don't self-heal.** If a client decommissions the tool that earned those points, build a "revert Secure Score status" step into the decommission checklist — otherwise the score silently overstates the real posture indefinitely. [MS Docs: History and trends](https://learn.microsoft.com/en-us/defender-xdr/microsoft-secure-score-history-metrics-trends)
