# Company Branding Custom CSS Retirement — Hotfix Runbook (Mode B: Ops)
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

**What's retiring:** Microsoft Entra ID is retiring support for a defined list of **custom CSS layout and positioning properties** used in **Company branding** / **Branding themes** sign-in customization, as part of the Secure Future Initiative (SFI) to harden branded sign-in pages against phishing impersonation. Two dates matter, and they are NOT the same event:

- **July 21, 2026** — tenants that were **not already using** these custom CSS properties can no longer **start** using them. If your tenant already uses none of the retiring properties, this date has already passed with zero impact.
- **Late October 2026** (Microsoft's Message Center specifies **Act by Oct 26, 2026**) — Microsoft **stops honoring** the retired properties globally, for every tenant, including ones that were using them before July 21. Branded elements don't disappear; they revert to default layout/position.

**Not affected:** Microsoft Entra **External ID** (CIAM) tenants are explicitly excluded from this change. If the ticket concerns an External ID tenant's branding, stop here — this runbook doesn't apply.

```powershell
# Custom CSS has NO Graph-queryable property list for its literal content — it's a
# downloadable file, not structured Graph data. Confirm exposure by DOWNLOADING and
# INSPECTING the file directly (portal steps below), then optionally use the companion
# script to pattern-match the retired property list against the downloaded file.

# 1. Confirm whether this tenant even HAS a custom branding configuration at all
Connect-MgGraph -Scopes "Organization.Read.All"
Get-MgOrganizationBranding -OrganizationId (Get-MgOrganization).Id

# 2. Download the actual custom CSS file for inspection (portal, not Graph):
#    Entra admin center -> Company branding -> Edit -> Layout -> Custom CSS -> Download
#    (Branding THEMES follow a similar per-app path: Enterprise applications -> <app> ->
#    Company branding / custom sign-in -> same Custom CSS download step)

# 3. Run the companion script against the downloaded .css file to flag retired properties
.\Get-BrandingCSSRetirementAudit.ps1 -CssFilePath "C:\temp\downloaded-branding.css"
```

| Result | Likely cause | Go to |
|--------|-------------|-------|
| Tenant has no custom branding configured at all | Zero impact — nothing to remediate | No action needed |
| Custom CSS file exists but uses none of the retired properties | Zero impact from THIS change (may still be affected by a later, broader CSS retirement in 2027) | No action needed now — re-check when the 2027 milestone is announced |
| Custom CSS file uses one or more retired properties (see list in Common Fix Paths) | Action required before Oct 26, 2026 | Fix 1 |
| Sign-in page suddenly looks "wrong"/misaligned after Oct 26, 2026 with no recent config change | Expected — the properties in use stopped being honored on the global retirement date | Fix 2 |
| Admin trying to ADD a new custom CSS property they've never used before, on/after July 21, 2026 | Expected — new usage is blocked from that date for tenants not already using custom CSS | Fix 3 |
| Ticket concerns an Entra External ID (CIAM) tenant | Not affected by this change — confirm tenant type before investigating further | Verify tenant type, redirect if misrouted |
| Ticket concerns Branding **themes** (per-application branding) rather than Company branding | Same retirement, same property list, applies to both surfaces — same remediation path | Fix 1 (check the per-app branding theme's CSS too) |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft Secure Future Initiative (SFI) — phishing-hardening mandate
        │
        ▼
Microsoft Entra ID Company Branding / Branding Themes
        │
        ├── Custom CSS layout & positioning properties (a defined list —
        │   offset/margin-*/order/grid-*/isolation/overflow-*/content-visibility/
        │   clip/mask/-webkit-mask* — see Common Fix Paths for the full list)
        │
        ├── July 21, 2026: tenants NOT ALREADY using these properties can no
        │   longer begin using them (new-usage block, not retroactive removal)
        │
        └── Late October 2026 (Act by Oct 26, 2026 per MC1458474): Microsoft
            stops honoring these properties GLOBALLY, for every tenant
                    │
                    ▼
        Branding elements remain VISIBLE but revert to DEFAULT
        placement/presentation (nothing is deleted; the CSS override
        that used to reposition them simply stops applying)
                    │
        ┌───────────┴────────────────────────────────┐
        │                                              │
   Company branding                          Branding themes (per-application
   (tenant-wide default                       custom sign-in experience,
   sign-in experience)                         Enterprise Applications scope)
        │                                              │
        └──────────────────┬───────────────────────────┘
                            ▼
        BOTH surfaces share the same retired-property list and
        the same October 2026 cutover — check both if a tenant uses either

── EXPLICITLY EXCLUDED ──
Microsoft Entra External ID (CIAM) tenants — not affected by this change at all

── FUTURE MILESTONE (not this change, do not conflate) ──
"Later in 2027" — Microsoft's stated plan to move toward FULL custom CSS
retirement (all properties, not just layout/positioning), with separate
advance notice to be provided — out of scope for this runbook until announced
```

**Key concept:** this is a two-stage rollout (new-usage block, then global enforcement of a specific property list) inside a larger, still-evolving retirement of Entra ID custom CSS generally. Branding content itself is never deleted — only the layout/positioning override behavior stops working, and elements fall back to their default position.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm the tenant type.** Entra External ID (CIAM) tenants are excluded. Confirm you're looking at a standard Microsoft Entra ID (workforce) tenant before proceeding.

**Step 2 — Confirm whether custom branding exists at all:**
```powershell
Get-MgOrganizationBranding -OrganizationId (Get-MgOrganization).Id
```
If this returns nothing, there's no branding configuration to audit — no action needed.

**Step 3 — Download and inspect the actual CSS file.** The retired-property list is a literal CSS-property matter, not something exposed as structured Graph metadata — you must download the file (Entra admin center → Company branding → Edit → Layout → Custom CSS → Download) and inspect it directly, or run it through the companion script.

**Step 4 — Cross-reference against the full retired-property list** (see Fix 1). Distinguish "uses zero retired properties — no action" from "uses one or more — remediation required before Oct 26, 2026."

**Step 5 — If the ticket is a live "sign-in page looks broken" report after the cutover date**, confirm the date first (was this reported on/after late October 2026?) before assuming a configuration error — a correctly-configured branding page using retired properties is EXPECTED to visually change after the cutover with zero admin action taken.

**Step 6 — Check both Company branding AND Branding themes** if the tenant uses per-application custom sign-in experiences — they share the same property list and cutover date but are configured and downloaded separately.

---

## Common Fix Paths

<details><summary>Fix 1 — Custom CSS uses one or more retired properties (remediation required)</summary>

**Cause:** The tenant's branding configuration relies on layout/positioning behavior that Microsoft stops honoring after the late-October 2026 cutover.

**The full retired-property list** (per Message Center MC1458474):
```
offset, offset-path, offset-distance
margin-block, margin-block-start, margin-block-end
margin-inline, margin-inline-start, margin-inline-end
order
grid-area, grid-column, grid-column-start, grid-column-end
grid-row, grid-row-start, grid-row-end
isolation
overflow-x, overflow-y, overflow-block, overflow-inline
content-visibility
clip
mask, mask-image
-webkit-mask, -webkit-mask-image
```

**Remediation:**
1. Download the current custom CSS file: Entra admin center → **Company branding** → **Edit** → **Layout** → **Custom CSS** → **Download**.
2. Run the companion script against it to flag every retired property in use:
   ```powershell
   .\Get-BrandingCSSRetirementAudit.ps1 -CssFilePath "C:\temp\branding.css"
   ```
3. For each flagged property, either remove the declaration or redesign the affected element's layout using non-retired CSS properties/approaches.
4. Test the branded sign-in page after edits to confirm it still displays as intended.
5. Re-upload the corrected CSS file via the same Custom CSS interface.
6. Repeat for any **Branding themes** (per-application) configurations separately — they are configured independently even though they share the same property list.
7. Communicate the visual change (if any is unavoidable) to internal stakeholders ahead of the cutover, not after users start asking why the sign-in page "looks different."

**Rollback:** Re-upload the previous CSS file if the redesign introduces a regression — standard file-based rollback, no platform-side undo needed.

</details>

<details><summary>Fix 2 — Sign-in page visually changed after the cutover (expected)</summary>

**Cause:** Expected behavior. The retired properties stopped being honored on the global cutover date; branded elements reverted to their default placement/presentation. Nothing was deleted or misconfigured.

**Remediation:**
1. Confirm the report date is on/after the late-October 2026 cutover.
2. Confirm the previous CSS did in fact use one or more retired properties (download and check, per Fix 1) — this confirms the visual change is the expected consequence, not an unrelated regression.
3. If the new default layout is unacceptable, redesign using non-retired CSS properties (Fix 1) rather than attempting to restore the old behavior — the retired properties cannot be re-enabled.

**Rollback:** N/A — there is no supported way to restore the retired properties' effect; only forward redesign is available.

</details>

<details><summary>Fix 3 — Admin can't add a NEW custom CSS property they've never used before</summary>

**Cause:** Expected. Beginning July 21, 2026, tenants that were not already using custom CSS in their branding configuration can no longer begin using it. This applies to custom CSS generally for tenants with no prior usage — not only the specific layout/positioning properties being retired in October.

**Remediation:**
1. Confirm whether the tenant had any custom CSS configured before July 21, 2026 (check branding change history/audit logs if available, or ask the admin directly).
2. If the tenant genuinely never used custom CSS before that date, there is no supported path to begin using it now — achieve the desired branding effect through the Entra admin center's standard (non-CSS) branding options (logo, background image, colors, layout templates) instead.
3. If the tenant DID have prior custom CSS usage and this is a false block, escalate to Microsoft Support with the tenant ID and the exact error encountered — this would be an enforcement bug, not expected behavior.

**Rollback:** N/A — this is a capability-availability question, not a configuration change.

</details>

---

## Escalation Evidence

```
ESCALATION TICKET — Company Branding Custom CSS Retirement
=====================================
Tenant:                            [tenant name/ID]
Tenant type confirmed:             [ ] Standard Microsoft Entra ID (affected)
                                    [ ] Entra External ID / CIAM (NOT affected — verify before proceeding)
Branding surface affected:         [ ] Company branding (tenant-wide)
                                    [ ] Branding themes (per-application)
Custom CSS downloaded and checked: [Yes/No]
Retired properties found in use:   [list, or "none"]
Prior usage before 2026-07-21:     [Yes/No/Unknown]
Report date relative to cutover:   [before / during / after late-Oct-2026 cutover]
Message Center posts reviewed:     [MC1435782 / MC1458474 — Yes/No]

Symptom description:
[what the user/admin reported]

Steps already attempted:
[ ] Confirmed tenant type (Entra ID vs. External ID)
[ ] Downloaded and inspected the actual custom CSS file (both surfaces if applicable)
[ ] Ran the companion script to flag retired properties
[ ] Confirmed whether this is a pre-cutover remediation task or a post-cutover expected-change report
[ ] Redesigned/removed retired-property usage if applicable
```

---

## 🎓 Learning Pointers

- **This is a two-stage retirement, and mixing up the two dates changes the answer you give a client.** July 21, 2026 blocks *new* usage for tenants not already using custom CSS; late October 2026 (act by Oct 26) stops honoring the retired properties *globally*, including for tenants that were using them before July 21. A tenant that started using custom CSS in June 2026 is fine until the second date, not the first. [Deprecation of custom CSS positioning properties — CSS template reference](https://learn.microsoft.com/en-us/entra/fundamentals/reference-company-branding-css-template)

- **Content isn't deleted — only layout/positioning behavior stops working.** Branded logos, colors, and text remain; only the specific CSS properties controlling *where* and *how* things are positioned (offset, margin-*, grid-*, order, overflow-*, mask, clip, isolation, content-visibility) stop being honored, and affected elements fall back to default placement. Set client expectations accordingly — this is a visual-layout regression risk, not a branding-loss event.

- **This is driven by phishing hardening (Secure Future Initiative), not a technical deprecation for its own sake.** Microsoft's stated reasoning is that these layout/positioning properties were being used by malicious actors to construct convincing fake branded sign-in pages — framing this to stakeholders as a security improvement (not an arbitrary platform change) tends to land better than a pure "Microsoft removed a feature" explanation.

- **Custom CSS content has no Graph-queryable structured representation.** Unlike most Entra branding settings, the CSS file itself must be downloaded and inspected directly (or scripted against as a text file) — there's no `Get-MgOrganizationBranding` property that exposes individual CSS rules. Build the audit workflow around the downloaded file, not around Graph cmdlet output alone.

- **Check BOTH Company branding and Branding themes independently.** They share the identical retired-property list and cutover date but are separately configured, separately downloaded, and easy to check for one while forgetting the other — especially in tenants using per-application custom sign-in experiences for specific enterprise apps.

- **A further, fuller custom-CSS retirement is already flagged for "later in 2027."** This October 2026 change only retires the specific layout/positioning property list documented here — treat it as the first of at least two retirement waves, and note the 2027 milestone as a forward-looking item worth flagging in client documentation now, even though Microsoft hasn't published specifics yet.
