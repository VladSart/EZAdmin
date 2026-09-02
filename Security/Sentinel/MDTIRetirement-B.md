# Microsoft Defender Threat Intelligence (MDTI) Standalone Retirement — Hotfix Runbook (Mode B: Ops)
> Redirect, license-check, or bill-reconcile a post-retirement MDTI ticket in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

**Disambiguation up front — three different things share the "MDTI" name, only one of them retired:**
1. **The standalone Microsoft Defender Threat Intelligence product/portal/SKU** — a separately licensed, separately browsed experience. **This is what retired on August 1, 2026.** Microsoft's current documentation has also quietly dropped the "Defender" from the name — it's now referred to as simply "Microsoft Threat Intelligence."
2. **Threat intelligence *inside* the Defender XDR portal** (entity enrichments, Intel profiles, Intel explorer, Threat analytics) — this is where the capability now lives. Not retiring; this is the destination, not the casualty.
3. **Sentinel's own STIX-typed TI ingestion layer** (`ThreatIntelIndicators`/`ThreatIntelObjects` tables, the "Defender Threat Intelligence" data *connector*) — a completely separate mechanism for pulling TI into Sentinel workspace tables. **Unaffected by this retirement.** If a ticket is actually about this, stop here and go to `ThreatIntelligence-B.md` instead.

```powershell
# 1. Confirm the tenant's relevant license SKUs (gates the full Intel profiles/Intel explorer
#    research experience — NOT the free entity-enrichment data, which needs no license)
Connect-MgGraph -Scopes "Organization.Read.All"
Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits, @{N='Prepaid';E={$_.PrepaidUnits.Enabled}} |
    Where-Object { $_.SkuPartNumber -match "SPE_E5|EMSPREMIUM|ATP_ENTERPRISE|MDATP|THREAT_INTELLIGENCE" }
# Look for: SPE_E5/M365 E5 family, an E5 Security add-on SKU, or MDATP (Defender for Endpoint P2)

# 2. Is this tenant Sentinel-connected? (Sentinel gets MDTI capability via a free connector,
#    separately from the Defender-portal license gate above)
Get-AzSentinelDataConnector -ResourceGroupName <rg> -WorkspaceName <workspace> |
    Where-Object { $_.Kind -match "ThreatIntelligence|MDTI" }

# 3. Confirm what the user is actually looking at — ask for the URL/bookmark, don't assume
#    (a bookmarked standalone-portal URL is now dead; security.microsoft.com is current)
```

| Result | Likely cause | Go to |
|--------|-------------|-------|
| User/analyst reports a bookmarked MDTI portal URL now 404s or redirects unexpectedly | Expected — the standalone portal retired 2026-08-01, no exceptions, no extension path documented | Fix 1 |
| Tenant has no E5/E5-Security-add-on/Defender-for-Endpoint-P2 SKU and analyst can't see Intel profiles/Intel explorer in the Defender portal | Expected license gate — free entity enrichments still work, but the full research experience needs one of these SKUs (or a Sentinel connection) | Fix 2 |
| Ticket says "our Sentinel threat intel data stopped" | Almost certainly NOT this retirement — check `ThreatIntelIndicators` table health instead | Fix 3 → `ThreatIntelligence-B.md` |
| MSP/CSP still sees a standalone MDTI line item on a client's invoice/renewal past Aug 2026 | Stale SKU not yet cleaned up post-retirement; Microsoft issues a partner-level credit memo for unused term but does NOT auto-refund the end customer | Fix 4 |
| An internal script/integration calls a documented standalone-MDTI REST API endpoint and now errors | Expected — the standalone product (and by extension any API surface tied only to it) is retired; no confirmed like-for-like public API is documented for Intel profiles/Intel explorer content as of this writing | Fix 5 |
| Internal wiki/SOC runbook still tells analysts to go to the old MDTI portal | Documentation debt, not a platform fault | Fix 6 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Standalone Microsoft Defender Threat Intelligence (MDTI) product
    ├── Removed from Microsoft's purchasable Product Terms "Availability and
    │   Prerequisite" tables: October 1, 2025 (no NEW standalone subscriptions
    │   sold from this date — existing subscriptions continued to run)
    └── Standalone portal + Intel Explorer experience RETIRED: August 1, 2026
            (existing customers had full access up to this date; no
            documented extension mechanism)
                │
                ▼
    Capabilities converge into the Microsoft Defender portal (security.microsoft.com)
                │
        ┌───────┴────────────────────────────────────────────┐
        │                                                      │
Entity enrichments (Preview)                          Intelligence explorer
"Threat Intelligence Insights" tab on                 Intel profiles + Intel explorer,
IP/domain/URL/file entity pages                       via the "Threat intelligence" nav menu
    └── Publicly available data: FREE to ALL                └── Full research experience requires
        Defender XDR customers, no license gate                 ONE of:
        documented                                                • Microsoft 365 E5 (included, no
                                                                      extra cost)
                                                                    • E5 Security add-on
                                                                    • Microsoft Defender for Endpoint
                                                                      Plan 2
                                                                    • Microsoft Sentinel (via a FREE
                                                                      connector — standard Sentinel
                                                                      ingestion/analytics costs may
                                                                      still apply)
                │
Threat analytics — a SEPARATE, pre-existing Defender XDR capability, NOT part
of this retirement, unaffected
                │
Microsoft Copilot in Defender — surfaces Threat analytics / Intel profiles /
Intel explorer content via chat (Summarize / Prioritize / Ask), gated by the
SAME license requirement as the research experience above

── SEPARATE, UNRELATED SYSTEM — do not conflate ──
Sentinel's own STIX TI ingestion layer (ThreatIntelIndicators/ThreatIntelObjects,
the "Defender Threat Intelligence" DATA CONNECTOR) — pre-existing, unaffected by
this retirement, covered in ThreatIntelligence-A.md/-B.md

── MSP/CSP-SPECIFIC BILLING TAIL ──
CSP-held standalone MDTI subscriptions with term remaining past 2026-08-01
    └── Microsoft issues a CREDIT MEMO to the PARTNER for the unused term
            └── Partner must manually pass the credit through to the end
                customer — a finance/account-management action, not a
                technical migration task; nothing on the tenant side triggers
                this automatically
```

**Key concept:** the retirement removes a *separately licensed, separately browsed product*. It does not remove any threat-intelligence *data* — the data and (for licensed tenants) the full research tooling both continue, just relocated and, for most already-licensed customers, at no incremental cost.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Disambiguate which of the three "MDTI" things the ticket is actually about** (see Triage disambiguation above). Most misrouted tickets land here by assuming any mention of "Defender Threat Intelligence" means the same thing.

**Step 2 — If it's the standalone portal:** confirm the exact URL the user was using and when they last successfully used it. Anything after 2026-08-01 failing to load the old standalone experience is expected, not a fault.

**Step 3 — If it's about missing research-experience content (Intel profiles/Intel explorer) in the Defender portal:**
```powershell
Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits
```
Confirm the tenant (or the specific user, via `Get-MgUserLicenseDetail`) actually holds one of the qualifying SKUs. Entity enrichments (the free tier) should still work regardless — if even those are missing, that's a Defender XDR onboarding issue, not a licensing one.

**Step 4 — If it's an MSP/CSP billing question:** check Partner Center for the client's current subscription list and the tenant's Message Center for post **MC1192257** (Microsoft's own convergence/retirement announcement), which documents the credit-memo mechanism.

**Step 5 — If it's a broken integration/script:** identify exactly which endpoint or portal page the automation was calling. If it was calling the standalone MDTI product's own API or scraping the standalone portal, there is no confirmed like-for-like public replacement documented as of this writing for the full Intel profile/explorer content — escalate as a genuine capability gap rather than searching further for a drop-in API substitute.

---

## Common Fix Paths

<details><summary>Fix 1 — Standalone portal bookmark/link is dead</summary>

**Cause:** Expected. The standalone MDTI portal and its Intel Explorer experience retired 2026-08-01 with no extension path.

**Remediation:**
1. Point the user to the Microsoft Defender portal instead: `https://security.microsoft.com` → **Threat intelligence** nav menu → **Intel profiles** / **Intel explorer**.
2. For entity-level lookups (IP/domain/URL/file), point them to the entity page's **Threat Intelligence Insights** tab instead of a separate lookup tool.
3. Update any internal bookmarks, SOC onboarding docs, or browser favorites that reference the old standalone URL.

**Rollback:** N/A — the old portal cannot be restored; there is no supported reversal.

</details>

<details><summary>Fix 2 — Missing Intel profiles/Intel explorer (license gate)</summary>

**Cause:** The full research experience (what standalone MDTI's premium tier used to gate) now requires Microsoft 365 E5, an E5 Security add-on, Microsoft Defender for Endpoint Plan 2, or a Sentinel connection — a bare Microsoft 365 E3 tenant with no add-on does not include it.

**Remediation:**
```powershell
# Confirm the specific user's assigned license SKUs
Get-MgUserLicenseDetail -UserId <user@domain.com> | Select-Object SkuPartNumber
```
- If the tenant genuinely lacks a qualifying SKU: this is a licensing/procurement conversation, not a technical fault — confirm with the customer whether they want to add E5 Security, upgrade to E5, or rely on the free Sentinel-connector path instead.
- If the tenant DOES hold a qualifying SKU but the specific user still can't see the menu: confirm the user has an assigned Defender XDR role (e.g., Security Reader or higher) — this is an RBAC gap, not a licensing one.

**Rollback:** N/A — this is an entitlement confirmation, not a configuration change.

</details>

<details><summary>Fix 3 — Ticket conflates this retirement with Sentinel's own TI ingestion</summary>

**Cause:** "Threat intelligence stopped working" is frequently reported against the wrong system. Sentinel's `ThreatIntelIndicators`/`ThreatIntelObjects` tables and their data connector are a completely separate, pre-existing mechanism, unaffected by the standalone-portal retirement.

**Remediation:** Redirect to `ThreatIntelligence-B.md` Triage — run its query 1 (`ThreatIntelIndicators | where TimeGenerated > ago(2h)`) to confirm whether this is actually a connector/ingestion problem instead.

**Rollback:** N/A — routing correction only.

</details>

<details><summary>Fix 4 — Stale standalone-MDTI billing line for an MSP/CSP client</summary>

**Cause:** Microsoft's retirement does not automatically zero out or refund an existing CSP subscription — it issues a partner-level credit memo for unused term, which the partner must then apply to the customer manually.

**Remediation:**
1. In Partner Center, locate the client's standalone MDTI subscription and confirm its end/cancellation date.
2. Check for the corresponding credit memo (tied to Message Center post **MC1192257**).
3. Apply the credit to the customer's account per your own billing process; remove the SKU from future renewal quotes.
4. Confirm the client doesn't still need paid MDTI capability — in nearly all cases the answer is no, since it's now bundled into licenses they likely already hold.

**Rollback:** N/A — this is account reconciliation, not a reversible technical change.

</details>

<details><summary>Fix 5 — Custom automation depended on the standalone MDTI API/portal</summary>

**Cause:** Scripts or integrations built directly against the standalone product (its own REST API, or scraping/automating the standalone portal UI) lose their target when the product retires.

**Remediation:**
1. Identify exactly what data the integration consumed (IOC feed, Intel profile content, entity reputation lookups, etc.).
2. For IOC/indicator feeds specifically: evaluate migrating to Sentinel's Upload API pattern documented in `ThreatIntelligence-A.md` Playbook 1 — this is the current recommended path for programmatic TI ingestion.
3. For Intel profile/report content specifically: no confirmed public API equivalent is documented as of this writing — treat this as a genuine capability gap and open a Microsoft support case referencing MC1192257 if the client has a hard programmatic dependency, rather than continuing to search for an undocumented replacement.

**Rollback:** N/A — this is a migration/gap-assessment task.

</details>

<details><summary>Fix 6 — Internal documentation still references the old portal</summary>

**Cause:** Documentation debt — SOC runbooks, onboarding guides, or internal wikis still tell analysts to use the retired standalone portal.

**Remediation:** Update references to point at the Defender portal's **Threat intelligence** menu (Intel profiles/Intel explorer) and entity-page **Threat Intelligence Insights** tab. Treat this the same way you'd treat any other stale-link cleanup pass.

**Rollback:** N/A.

</details>

---

## Escalation Evidence

```
ESCALATION TICKET — MDTI Standalone Retirement Issue
=====================================
Tenant:                          [tenant name/ID]
Ticket concerns (pick one):      [ ] Standalone portal access
                                  [ ] Missing Intel profiles/Intel explorer content
                                  [ ] Sentinel TI ingestion (may be MISROUTED — verify first)
                                  [ ] MSP/CSP billing/credit memo
                                  [ ] Broken automation/integration
Relevant license SKUs held:      [output of Get-MgSubscribedSku / Get-MgUserLicenseDetail]
Sentinel-connected:               [Yes/No — workspace name if yes]
Old URL/bookmark reported (if any): [URL]
Message Center post reviewed:     [MC1192257 — Yes/No]

Symptom description:
[what the user/admin reported]

Steps already attempted:
[ ] Confirmed which of the three "MDTI" systems this ticket actually concerns
[ ] Checked tenant/user licensing (E5 / E5 Security add-on / Defender for Endpoint P2)
[ ] Confirmed Sentinel connector status if relevant
[ ] Checked Partner Center subscription/credit-memo status (CSP tickets only)
[ ] Ruled out Sentinel's own ThreatIntelIndicators ingestion as the real issue
```

---

## 🎓 Learning Pointers

- **This retirement removed a product, not a capability.** Nearly every affected customer already holds a license that includes the replacement at no extra cost (M365 E5, E5 Security add-on, Defender for Endpoint P2, or a free Sentinel connector). Lead conversations with "where did it go," not "how do we replace what we lost." [Microsoft Threat Intelligence in Microsoft Defender XDR](https://learn.microsoft.com/en-us/defender-xdr/defender-threat-intelligence)

- **Microsoft quietly dropped "Defender" from the name.** Current Microsoft Learn documentation (as of this writing, `ms.date` 2026-07-30) refers to the capability as simply "Microsoft Threat Intelligence," not "Microsoft Defender Threat Intelligence (MDTI)." Most community and vendor blog posts still say "MDTI" — expect that naming lag to persist in tickets and third-party documentation for a while yet.

- **A Microsoft Community Hub post titled "MDTI Standalone Portal Retirement and Transition to Defender XDR" carries a June 30, 2024 date in its own description text despite being last modified in August 2026** — a real, confirmed discrepancy against the current, authoritative Learn page's stated August 1, 2026 retirement date. Treat the Learn page as authoritative; the 2024 date most likely reflects an earlier, partial UI-consolidation phase that predates this final full retirement, but verify directly (try the old portal URL, don't trust either date blindly) if a client's compliance documentation hinges on the exact day.

- **Three distinct dates apply to this one retirement, and mixing them up changes the answer you give a client:** October 1, 2025 (standalone MDTI removed from Microsoft's purchasable Product Terms — no new subscriptions sold from this date), August 1, 2026 (the standalone portal and Intel Explorer experience actually shut off for existing customers), and the undated, ongoing CSP credit-memo reconciliation tail that follows for partners with subscriptions that ran past the retirement date.

- **CSPs do not get an automatic customer-side refund.** Microsoft's credit memo lands with the partner, not the end customer — passing that credit through, and cleaning the stale SKU off future renewals, is a manual partner-side action worth building into a standard post-retirement billing sweep for any client roster that included standalone MDTI.

- **Don't confuse this with Sentinel's own threat-intelligence data connector.** The "Defender Threat Intelligence" connector that feeds Sentinel's `ThreatIntelIndicators`/`ThreatIntelObjects` tables (see `ThreatIntelligence-A.md`/`-B.md`) is a completely separate, pre-existing mechanism and is not affected by this retirement — a surprising number of tickets will arrive misrouted between the two because they share a name.
