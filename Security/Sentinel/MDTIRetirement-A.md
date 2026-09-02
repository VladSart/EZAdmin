# Microsoft Defender Threat Intelligence (MDTI) Standalone Retirement — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers the **retirement of Microsoft Defender Threat Intelligence (MDTI) as a standalone, separately licensed product and portal**, and its convergence into the Microsoft Defender portal and Microsoft Sentinel. It assumes:

- The reader already understands Defender XDR portal basics (`security.microsoft.com`) and, if relevant, has a Sentinel workspace.
- This is **not** a mechanics deep dive on Sentinel's own STIX-typed threat-intelligence ingestion layer (`ThreatIntelIndicators`/`ThreatIntelObjects`, the "Defender Threat Intelligence" data connector) — that architecture, its four import paths, and its 2025-07-31 schema cutover are covered in `ThreatIntelligence-A.md`. This runbook exists specifically because the two are easy to conflate by name and this run confirmed the repo had zero prior coverage of the *product retirement/licensing* event, distinct from the *data-ingestion mechanics* already documented.
- Facts below are sourced primarily from Microsoft's own current Learn documentation (`ms.date` 2026-07-30, last updated 2026-08-02) and Microsoft's Message Center post **MC1192257**; community/vendor commentary (credit-memo mechanics, licensing-scenario tables) is cited separately and flagged where it adds detail beyond what Microsoft's own docs state directly.

---

## How It Works

### What Actually Retired

Three closely related but distinct things carry the "MDTI" name. Understanding which one retired — and which two did not — is the single most important fact in this topic:

1. **The standalone Microsoft Defender Threat Intelligence product**: a separately purchasable license/SKU, with its own separately browsed portal experience (including the "Intel Explorer" research tool). **This retired on August 1, 2026.**
2. **Threat intelligence inside the Defender XDR portal**: entity enrichments, Intel profiles, Intel explorer, and Threat analytics, all now living inside `security.microsoft.com`. This is the *destination* the standalone product's capabilities moved into — not a casualty of the retirement.
3. **Sentinel's own STIX-typed TI ingestion layer**: the `ThreatIntelIndicators`/`ThreatIntelObjects` tables and their "Defender Threat Intelligence" data connector (see `ThreatIntelligence-A.md`). This is a data-plumbing mechanism for pulling threat intelligence *into* a Sentinel workspace as queryable objects — architecturally unrelated to the standalone product/portal, and **entirely unaffected** by this retirement.

Microsoft's own current documentation has also quietly renamed the surviving capability from "Microsoft **Defender** Threat Intelligence (MDTI)" to simply "**Microsoft Threat Intelligence**." Expect "MDTI" to persist in tickets, internal documentation, and third-party blog posts for a long time after the rebrand — the name change is not itself announced with the same visibility as the retirement.

### Timeline — Three Dates That Are Easy to Conflate

| Date | Event | Source |
|---|---|---|
| 2025-10-01 | Standalone MDTI removed from Microsoft's purchasable Product Terms "Availability and Prerequisite" tables — no *new* standalone subscriptions sold from this date forward | Community/licensing commentary, consistent with standard Microsoft product-terms retirement practice |
| 2026-08-01 | The standalone MDTI portal and its Intel Explorer experience formally retire for existing customers — this is the "lights off" date | Microsoft Learn, `ms.date` 2026-07-30 |
| Ongoing (post-2026-08-01) | CSP partners with subscription term remaining past the retirement date receive Microsoft-issued credit memos for the unused portion; passing that credit to the end customer is a manual partner action | Community/partner reporting (Kocho); not independently verified against a Microsoft-published credit-memo policy document as of this writing — confirm exact mechanics via Partner Center for a specific case |

A Microsoft Community Hub post titled "MDTI Standalone Portal Retirement and Transition to Defender XDR" carries a **June 30, 2024** date in its own page description, despite being last modified in August 2026. This is very likely a residual artifact from an earlier, partial UI-consolidation phase (Defender XDR portal navigation absorbing some MDTI screens ahead of the full retirement) rather than evidence the full retirement happened two years earlier than Microsoft's current Learn page states — but flag this explicitly rather than silently picking one date if a client's compliance record depends on the exact day. The current Learn page (`ms.date` 2026-07-30) is the more authoritative, more recently dated source and should be treated as the controlling date for the full retirement.

### Where the Capability Lives Now

Two primary experiences inside the Defender portal replace the standalone product:

**Entity enrichments (Preview).** IP address, domain, URL, and file entity pages gain a **Threat Intelligence Insights** tab surfacing reputation data, attributed threat reports, sandbox analysis results, and infrastructure relationship data — in-context, without switching tools. Microsoft states this publicly-available data is accessible to **all** Defender XDR customers **at no extra cost**, with no license gate documented beyond ordinary Defender XDR access.

**Intelligence explorer.** The full research experience — **Intel profiles** (curated content organized by threat actor, tooling, and known vulnerabilities) and **Intel explorer** (search/investigate TI artifacts, IOCs, and related analyses) — accessed via the **Threat intelligence** navigation menu in the Defender portal. This is the part that inherits standalone MDTI's former premium-tier gating, and requires one of:
- Microsoft 365 E5 (included, no additional cost)
- An E5 Security add-on
- Microsoft Defender for Endpoint Plan 2
- Microsoft Sentinel, via a free connector (standard Sentinel ingestion/analytics charges may still apply on top)

A bare Microsoft 365 E3 tenant with none of the above add-ons does **not** include the full research experience.

**Threat analytics** — a separate, pre-existing Defender XDR capability (expert Microsoft-authored reports on active threat actors/campaigns, attack techniques, and vulnerabilities, cross-referenced against environment telemetry) is related but was **not** part of the standalone MDTI product and is unaffected by this retirement.

**Copilot in Defender** surfaces Threat analytics, Intel profiles, and Intel explorer content through chat (built-in **Summarize** / **Prioritize** / **Ask** prompts), gated by the same licensing as the research experience it draws from — not an independent access path.

### The Licensing Convergence, Explained

Before this retirement, standalone MDTI was purchased and licensed independently of Defender/Sentinel — an organization could hold MDTI without holding a premium Defender or Sentinel license, or vice versa. The convergence folds MDTI's premium capability into licenses many customers already hold (E5, E5 Security add-on, Defender for Endpoint P2) or makes it available at no incremental license cost through an existing Sentinel connection. For the large majority of customers already invested in Microsoft's security stack, this is a net licensing simplification and, in many cases, a cost reduction (no more separately-tracked, separately-renewed MDTI subscription). The customers who feel this as a *loss* are specifically: organizations that held standalone MDTI **without** any qualifying Defender/Sentinel license — those organizations lose access to the full research experience unless they add a qualifying license.

### The MSP/CSP Billing Tail

For MSPs holding standalone MDTI subscriptions on behalf of clients through CSP, the retirement generates a distinctly non-technical follow-up task: Microsoft issues a credit memo to the **partner** (not the end customer directly) for any unused subscription term running past the retirement date. The partner is then responsible for passing that credit through to the client per their own billing practice, and for removing the now-pointless SKU from future renewal quotes. This is worth building into a standard post-retirement billing sweep across a client roster, since nothing on the technical/tenant side surfaces this automatically — an MSP that only tracks tenant configuration state (not Partner Center billing state) can easily miss it entirely.

---

## Dependency Stack

```
                    Standalone Microsoft Defender Threat Intelligence (MDTI) PRODUCT
                    ├── Removed from purchasable Product Terms: 2025-10-01
                    └── Portal + Intel Explorer RETIRED: 2026-08-01
                                        │
                                        ▼ (capability converges into)
                        Microsoft Defender portal (security.microsoft.com)
                                        │
                ┌───────────────────────┴────────────────────────────┐
                │                                                     │
    Entity enrichments (Preview)                            Intelligence explorer
    "Threat Intelligence Insights" tab                       (Intel profiles + Intel explorer)
    on IP/domain/URL/file entity pages                        via "Threat intelligence" nav menu
        │                                                            │
    FREE — all Defender XDR customers,                    LICENSE-GATED — requires ONE of:
    no license gate documented                              • Microsoft 365 E5
                                                              • E5 Security add-on
                                                              • Defender for Endpoint Plan 2
                                                              • Microsoft Sentinel (free connector;
                                                                ingestion/analytics costs may apply)
                                        │
                        Threat analytics (separate, pre-existing, unaffected)
                                        │
                        Copilot in Defender (same license gate as Intelligence explorer)


── ARCHITECTURALLY SEPARATE SYSTEM (see ThreatIntelligence-A.md) — NOT part of this stack ──

    Sentinel workspace (Log Analytics)
            │
    "Defender Threat Intelligence" DATA CONNECTOR (one of four TI import paths)
            │
    ThreatIntelIndicators / ThreatIntelObjects tables
            │
    Analytics rules / Hunting / Notebooks / Workbooks
    (pre-existing mechanism; unaffected by the standalone-product retirement above)


── MSP/CSP BILLING TAIL (finance process, not a technical dependency) ──

    CSP-held standalone MDTI subscription, term remaining past 2026-08-01
            │
    Microsoft issues credit memo → PARTNER (not end customer)
            │
    Partner manually applies credit to customer account + removes stale SKU from renewal
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Bookmarked MDTI URL 404s or redirects after Aug 2026 | Expected — standalone portal retired | Confirm date of last successful access vs. 2026-08-01 |
| Analyst can see entity reputation data but not Intel profiles/Intel explorer | Missing qualifying license (E5 / E5 Security add-on / Defender for Endpoint P2) or no Sentinel connection | `Get-MgUserLicenseDetail` against the specific analyst |
| Entire org reports no threat intelligence anywhere in Defender portal | Defender XDR onboarding/RBAC issue, not a licensing gap — free entity enrichments should never require a paid SKU | Confirm Defender XDR portal access generally, independent of TI specifically |
| "Our Sentinel threat intel feed stopped" | Almost never this retirement — Sentinel's TI connector is a separate system | `ThreatIntelIndicators \| where TimeGenerated > ago(2h)` (see `ThreatIntelligence-B.md`) |
| Client still billed for standalone MDTI in 2026 H2/2027 | Partner-side billing cleanup not yet actioned | Partner Center subscription list + Message Center MC1192257 |
| Script/integration errors calling a documented standalone-MDTI endpoint | Product retirement removed the dependency's target | Identify exact endpoint; check for a Sentinel Upload API migration path if it's IOC-feed related |
| Internal SOC documentation still references the old portal | Documentation debt, not a platform issue | Grep internal wikis/runbooks for the old URL/branding |

---

## Validation Steps

1. **Confirm which of the three "MDTI" systems the report actually concerns.** Ask for the exact URL, menu path, or table name involved before doing anything else — this single question resolves the majority of misrouted tickets on this topic.
   - Expected good outcome: a clear answer maps directly to one of standalone portal / Defender-portal TI / Sentinel TI connector.
   - Bad sign: vague references to "the threat intel thing" with no specifics — get a screenshot or exact URL before proceeding.

2. **Confirm tenant/user licensing for the research experience:**
   ```powershell
   Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits
   Get-MgUserLicenseDetail -UserId <user@domain.com> | Select-Object SkuPartNumber
   ```
   - Good: one of the qualifying SKUs (E5 family, E5 Security add-on, MDATP/Defender for Endpoint P2) is present and assigned to the specific user.
   - Bad: none present, and the tenant has no Sentinel connection either — this is a genuine, expected licensing gap, not a fault.

3. **Confirm Defender-portal TI surfaces are actually reachable for a licensed user:**
   - Navigate to `security.microsoft.com` → **Threat intelligence** → confirm **Intel profiles** and **Intel explorer** both load.
   - Open any IP/domain/URL/file entity page → confirm the **Threat Intelligence Insights** tab is present (this should work for ALL Defender XDR customers regardless of the license check above).
   - Bad sign: the free entity-enrichment tab itself is missing — this points to a Defender XDR onboarding/RBAC issue, not this retirement.

4. **If a Sentinel connection is the claimed access path, confirm the connector exists and is enabled:**
   ```powershell
   Get-AzSentinelDataConnector -ResourceGroupName <rg> -WorkspaceName <workspace>
   ```

5. **For CSP/MSP billing questions, confirm against Partner Center and Message Center, not tenant configuration:**
   - Partner Center → the client's subscription list → confirm standalone MDTI subscription status/end date.
   - Tenant Message Center → search for **MC1192257**.

---

## Troubleshooting Steps (by phase)

### Phase 1: Disambiguation
Establish which of the three MDTI-named systems is actually in scope before any further diagnosis. This alone resolves most tickets that reach this runbook in error.

### Phase 2: Licensing Confirmation
Run the SKU checks above against both tenant-wide and user-specific license state. Distinguish "no qualifying SKU exists anywhere in the tenant" (a sales/licensing conversation) from "a qualifying SKU exists but wasn't assigned to this user" (an assignment fix).

### Phase 3: Portal/Feature Reachability
Confirm the free entity-enrichment tier works independently of the licensed research tier — these have different failure domains and should not be diagnosed as one problem.

### Phase 4: Cross-System Rule-Out
If there's any ambiguity that this might actually be a Sentinel TI-ingestion issue, rule that out explicitly using `ThreatIntelligence-B.md`'s own triage queries before continuing here.

### Phase 5: Billing/Account Reconciliation (CSP/MSP only)
Separate from all technical phases above — check Partner Center and Message Center MC1192257 for credit-memo and subscription-cleanup status.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Fleet-wide post-retirement cleanup for an MSP client roster</summary>

**Use when:** An MSP wants to proactively sweep all managed tenants for lingering standalone-MDTI dependencies rather than waiting for reactive tickets.

1. Pull the full client subscription list from Partner Center; filter for any standalone MDTI SKU still present.
2. For each match, confirm actual usage: was this tenant relying on MDTI features that now need a licensing decision (add E5 Security/Defender for Endpoint P2, or connect Sentinel), or was it unused/redundant?
3. Check Message Center (MC1192257) per tenant for credit-memo status; apply credits and remove the stale SKU from the next renewal cycle.
4. Update every client-facing and internal runbook/wiki reference to the old standalone portal URL.
5. Run a quick per-tenant validation (Validation Steps 2-3 above) to confirm the intended replacement access path (free enrichments, licensed research experience, or Sentinel connector) actually works post-cleanup.

**Rollback:** N/A — this is a cleanup/reconciliation playbook, not a reversible configuration change.

</details>

<details><summary>Playbook 2 — Deciding the right licensing path for a client that held standalone MDTI without E5/Sentinel</summary>

**Use when:** A client's only threat-intelligence spend was standalone MDTI, and they now need a decision on how (or whether) to retain the research-experience capability.

1. Confirm actual usage pattern: was Intel profiles/Intel explorer used regularly by a SOC team, or was it lightly used/exploratory?
2. If regularly used and the client already has Microsoft 365 E3: compare the incremental cost of an E5 Security add-on or Defender for Endpoint Plan 2 against a standalone Sentinel deployment — the right answer depends heavily on whether the client would also benefit from Sentinel's SIEM capabilities generally, not just the free TI connector.
3. If usage was light: the free entity-enrichment tier (available to all Defender XDR customers with no license gate) may already cover the client's actual needs — validate before recommending a paid add-on.
4. Document the decision and licensing change (if any) in the client's account record, and update Partner Center accordingly.

**Rollback:** Standard license removal if the added SKU proves unnecessary after a trial period.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects tenant licensing and Sentinel-connector evidence relevant to an
    MDTI-standalone-retirement ticket, for escalation or client review.
#>

Write-Host "=== Tenant SKU inventory (qualifying SKUs highlighted) ===" -ForegroundColor Cyan
Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits,
    @{N='PrepaidEnabled';E={$_.PrepaidUnits.Enabled}} |
    Sort-Object SkuPartNumber | Format-Table -AutoSize

Write-Host "`n=== Qualifying-SKU flag (E5 family / E5 Security / Defender for Endpoint P2) ===" -ForegroundColor Cyan
$qualifying = Get-MgSubscribedSku | Where-Object {
    $_.SkuPartNumber -match "SPE_E5|SPE_E5_RPA1|EMSPREMIUM|ATP_ENTERPRISE|MDATP|IDENTITY_THREAT_PROTECTION"
}
if ($qualifying) {
    $qualifying | Select-Object SkuPartNumber, ConsumedUnits
} else {
    Write-Host "No obviously-qualifying SKU found by name pattern — verify manually against the current licensing matrix." -ForegroundColor Yellow
}

Write-Host "`n=== Sentinel Threat-Intelligence connector state (if a workspace is supplied) ===" -ForegroundColor Cyan
# Get-AzSentinelDataConnector -ResourceGroupName <rg> -WorkspaceName <workspace> |
#     Where-Object { $_.Kind -match "ThreatIntelligence|MDTI" } | Format-Table -AutoSize
Write-Host "Populate -ResourceGroupName/-WorkspaceName above and uncomment to include." -ForegroundColor DarkGray
```

---

## Command Cheat Sheet

```powershell
# Tenant SKU inventory
Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits

# Specific user's license detail
Get-MgUserLicenseDetail -UserId <user@domain.com> | Select-Object SkuPartNumber

# Sentinel TI connector state (separate, unaffected system — see ThreatIntelligence-A.md)
Get-AzSentinelDataConnector -ResourceGroupName <rg> -WorkspaceName <workspace> |
    Where-Object { $_.Kind -match "ThreatIntelligence|MDTI" }

# Confirm current-schema Sentinel TI ingestion is unrelated/healthy (rule-out check)
# ThreatIntelIndicators | where TimeGenerated > ago(2h) | summarize count() by SourceSystem
```

```
# Portal navigation (current, post-retirement)
Defender portal → https://security.microsoft.com
  → Threat intelligence (nav menu) → Intel profiles / Intel explorer
  → Any IP/domain/URL/file entity page → "Threat Intelligence Insights" tab

# Tenant Message Center
security.microsoft.com or admin.cloud.microsoft → Message Center → search "MC1192257"

# Partner Center (CSP/MSP billing check)
partner.microsoft.com → Customers → <client> → Subscriptions → filter for standalone MDTI
```

---

## 🎓 Learning Pointers

- **Three "MDTI" systems, one retirement.** Only the standalone product/portal/SKU retired. The Defender-portal-integrated capability it converged into, and Sentinel's own STIX TI ingestion layer, are both unaffected — misrouting between these three is the most common failure mode for tickets on this topic. [Microsoft Threat Intelligence in Microsoft Defender XDR](https://learn.microsoft.com/en-us/defender-xdr/defender-threat-intelligence)

- **The rebrand happened quietly.** Microsoft's current Learn documentation drops "Defender" from the name entirely ("Microsoft Threat Intelligence"), but almost every ticket, internal doc, and third-party blog post will keep saying "MDTI" for a long time. Don't let naming inconsistency block disambiguation — confirm by URL/menu path, not by what the user calls it.

- **Most affected customers lose nothing financially.** Because the replacement capability is bundled into licenses (E5, E5 Security add-on, Defender for Endpoint P2) or connectors (Sentinel) that the large majority of Microsoft-security customers already hold, this retirement is a net simplification for most tenants — the exception is a customer who held standalone MDTI with none of those qualifying licenses.

- **CSP credit memos land with the partner, not the client.** If you manage a client roster through CSP, this retirement creates an easy-to-miss manual billing task — nothing on the tenant/technical side surfaces it. Build a one-time roster sweep (Playbook 1) rather than waiting for a client to notice a stale invoice line.

- **Watch for conflicting Microsoft-published dates on this exact topic.** A Community Hub post modified as recently as August 2026 still carries a June 30, 2024 date in its own description — treat the current Microsoft Learn page (`ms.date` 2026-07-30) as authoritative, and verify directly rather than trusting either date blindly when it matters for a client record.

- **No confirmed public API replaces the standalone product's full research-content surface.** If a client had automation built directly against the standalone MDTI API, don't assume a drop-in replacement exists — the documented current guidance covers portal-based access (entity enrichments, Intel profiles/explorer) and Sentinel's Upload API for IOC-style ingestion, not a like-for-like programmatic export of Intel profile/report content.
