# Company Branding Custom CSS Retirement — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers Microsoft's retirement of a defined list of **custom CSS layout and positioning properties** used in Microsoft Entra ID **Company branding** and **Branding themes** (per-application custom sign-in), announced across two related Message Center posts — **MC1435782** (the original announcement) and **MC1458474** (published 2026-08-21, expanding the retired-property list beyond what MC1435782 first announced) — as part of Microsoft's Secure Future Initiative (SFI). It assumes:

- The reader has basic familiarity with Entra ID Company branding configuration (Entra admin center → Company branding) and, where relevant, Branding themes for individual enterprise applications.
- This is a **security-driven UX/branding change**, not a licensing, RBAC, or authentication-flow change — no sign-in functionality is affected, only visual presentation of branding elements.
- Facts below are sourced from Microsoft's Message Center post MC1458474 (published 2026-08-21, the most current and complete statement of the retired-property list) and its referenced predecessor MC1435782. Note explicitly: **MC1458474 expands the property list originally announced in MC1435782** — if a client or internal reference cites only the earlier post, it may be working from an incomplete property list; treat MC1458474 as authoritative for the full list as of this writing.

---

## How It Works

### Why This Is Happening

Microsoft frames this retirement explicitly under the **Secure Future Initiative (SFI)** — its company-wide security-hardening program — with a specific, stated threat model: malicious actors have been observed using custom CSS layout and positioning properties in Entra ID branding configurations to construct convincing **fake branded sign-in pages**, used in phishing campaigns. By limiting which CSS properties can reposition or restructure sign-in page elements, Microsoft reduces the surface area available for constructing a deceptive lookalike sign-in experience, while still allowing legitimate branding customization (logos, colors, background images, text) to continue working.

This is deliberately narrower than "remove all custom CSS" — it targets specifically the *layout and positioning* category of properties (things that can move, resize, reorder, mask, or clip page elements) rather than purely cosmetic properties (colors, fonts, borders). Microsoft has separately signaled that a broader, fuller custom-CSS retirement is planned for "later in 2027," with this October 2026 change positioned as the first of at least two stages.

### The Two-Stage Rollout, Precisely

| Stage | Date | What happens | Who's affected |
|---|---|---|---|
| Stage 1 — New-usage block | **2026-07-21** | Tenants that were **not already using** custom CSS in their branding configuration as of this date can no longer **begin** using it | Tenants with zero prior custom CSS usage attempting to adopt it for the first time on/after this date |
| Stage 2 — Global retirement | **Late October 2026** (Message Center: **Act by Oct 26, 2026**) | Microsoft stops honoring the specific list of retired layout/positioning CSS properties, **globally, for every tenant** — including tenants that were using custom CSS before Stage 1 | Any tenant (regardless of when they started using custom CSS) whose configuration relies on one or more of the retired properties |
| Future — full retirement | **"Later in 2027"** (no specific date published as of this writing) | Microsoft's stated direction toward retiring custom CSS support more broadly, with advance notice to be provided | Out of scope for this runbook until formally announced with specifics |

A tenant that adopted custom CSS in, say, June 2026 (before Stage 1's cutoff) is **not** blocked from continuing to use it through Stage 1 — Stage 1 only blocks *new* adoption. That same tenant IS affected by Stage 2 if its CSS relies on retired properties, exactly the same as a tenant that had used custom CSS for years. The two stages target different populations for different reasons: Stage 1 prevents the retired-property surface from growing further; Stage 2 shrinks it globally regardless of adoption history.

### What Actually Happens to a Sign-In Page

Critically, this is **not** a content-deletion event. Company branding configuration (logo, background image, sign-in page text, colors, favicon) remains fully intact and functional. Only the specific CSS properties governing *layout and positioning* — where elements sit, how they're sized, whether they're clipped/masked, their stacking/rendering order — stop being honored after the Stage 2 cutover. The practical effect: branding elements remain **visible**, but revert to their **default placement and presentation** as defined by Microsoft's standard sign-in page template, rather than wherever the retired CSS properties had positioned them.

### The Full Retired-Property List (per MC1458474)

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

These fall into recognizable functional groups: **positioning/offset** (`offset`, `offset-path`, `offset-distance`), **spacing** (`margin-block*`, `margin-inline*`), **ordering** (`order`), **grid placement** (`grid-area`, `grid-column*`, `grid-row*`), **stacking context** (`isolation`), **overflow/clipping** (`overflow-*`, `clip`, `content-visibility`), and **masking** (`mask`, `mask-image`, and the `-webkit-` prefixed equivalents for WebKit-based browser rendering). Notably, standard cosmetic properties — `color`, `background-color`, `font-family`, `border`, simple `padding`, and non-retired positioning like basic `position: relative/absolute` with `top`/`left`/`right`/`bottom` — are **not** in this list and remain supported. The distinction Microsoft draws is specifically toward properties capable of *restructuring or concealing* page layout in ways that could disguise a phishing page as legitimate, versus properties that only affect color/typography/simple spacing.

### Scope: Company Branding vs. Branding Themes

Two related but separately-configured surfaces share this exact retired-property list and cutover date:

- **Company branding** — the tenant-wide default sign-in experience, configured once per tenant (Entra admin center → Company branding), optionally with locale-specific variants.
- **Branding themes** — per-application custom sign-in experiences, configured against individual Enterprise Applications for organizations that want a different branded look for specific app sign-ins (e.g., a customer-facing app branded differently from the general employee sign-in page).

Both surfaces accept custom CSS independently, and both are subject to the identical Stage 1/Stage 2 rules and the identical retired-property list. A tenant auditing its exposure must check both surfaces separately — a clean Company branding CSS file does not imply Branding themes CSS files (if any exist) are also clean, and vice versa.

### Entra External ID (CIAM) Exclusion

Microsoft explicitly states **Microsoft Entra External ID tenants are not affected by this change**. External ID (the customer-facing identity platform, formerly associated with Azure AD B2C-successor CIAM scenarios) has its own separate branding/customization model and is out of scope for this specific retirement entirely — not merely exempt from Stage 1 or Stage 2 individually, but excluded from the whole change.

---

## Dependency Stack

```
Microsoft Secure Future Initiative (SFI)
        │
        ▼
Entra ID Company Branding + Branding Themes custom CSS capability
        │
        ├── Stage 1 (2026-07-21): NEW usage blocked for tenants with no prior
        │   custom CSS usage — does not affect tenants already using it
        │
        └── Stage 2 (late Oct 2026 / Act by Oct 26, 2026 — MC1458474):
            retired-property list stops being honored GLOBALLY
                    │
        ┌───────────┴────────────────────────────────────────┐
        │                                                      │
   Retired properties (offset*, margin-block*/inline*,   Non-retired properties
   order, grid-*, isolation, overflow-*,                 (color, background-color,
   content-visibility, clip, mask*, -webkit-mask*)         font-family, border, basic
        │                                                   position/top/left/right/bottom)
   STOP being honored after Stage 2                       CONTINUE working unchanged
        │
   Affected element reverts to DEFAULT
   layout/position — content NOT deleted
        │
        ├── Company branding (tenant-wide)
        └── Branding themes (per-application) — same list, same date,
            separately configured, must be checked independently

── EXPLICITLY OUT OF SCOPE ──
Microsoft Entra External ID (CIAM) tenants — entirely excluded from this change

── FUTURE, NOT YET SPECIFIED ──
"Later in 2027" — broader full custom-CSS retirement, advance notice pending,
out of scope until formally announced
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Sign-in page layout looks different after late Oct 2026, no recent admin change | Expected — retired properties stopped being honored, element reverted to default position | Download and check CSS for retired properties |
| Admin can't add ANY custom CSS to a tenant that never used it before, on/after 2026-07-21 | Expected Stage 1 new-usage block | Confirm no prior custom CSS usage; use non-CSS branding options instead |
| Branding "disappeared" entirely | Unlikely to be this retirement — content isn't deleted, only layout/positioning reverts | Re-check actual branding configuration state via `Get-MgOrganizationBranding`; investigate as a separate issue if content is truly gone |
| One app's branded sign-in looks fine but the tenant-wide default looks broken (or vice versa) | Company branding and Branding themes are separately configured — only one surface was remediated | Check both surfaces' CSS independently |
| Ticket concerns an External ID / CIAM tenant | Not affected by this change at all | Confirm tenant type before investigating further |
| Client cites "MC1435782" and says they're fully compliant, but a retired property is still present | MC1435782 announced an earlier, shorter property list; MC1458474 (2026-08-21) expanded it | Re-check against the CURRENT full list in MC1458474, not the original announcement |

---

## Validation Steps

1. **Confirm tenant type.** External ID (CIAM) tenants are excluded entirely — verify before proceeding further.

2. **Confirm branding configuration exists:**
   ```powershell
   Get-MgOrganizationBranding -OrganizationId (Get-MgOrganization).Id
   ```

3. **Download the actual CSS file(s).** For Company branding: Entra admin center → Company branding → Edit → Layout → Custom CSS → Download. For each Branding theme in use: the equivalent per-application custom sign-in configuration path.
   - Good: file downloads cleanly and can be inspected/diffed.
   - Note: there is no Graph endpoint that exposes individual CSS rule content as structured data — the file itself is the source of truth.

4. **Pattern-match the downloaded file(s) against the full retired-property list** (see How It Works above), either manually or via the companion script:
   ```powershell
   .\Get-BrandingCSSRetirementAudit.ps1 -CssFilePath "C:\temp\branding.css"
   ```

5. **Confirm the reference Message Center post being used is current.** MC1458474 (2026-08-21) supersedes MC1435782 with an expanded property list — if a client's internal documentation only references the earlier post, its remediation may be incomplete.

6. **If checking Stage 1 exposure specifically**, determine whether the tenant had ANY custom CSS configured before 2026-07-21 (branding audit history, or direct confirmation from the admin) — this determines whether the tenant is subject to the new-usage block at all.

---

## Troubleshooting Steps (by phase)

### Phase 1: Tenant Type and Scope Confirmation
Confirm the tenant is a standard Microsoft Entra ID tenant (not External ID/CIAM), and identify which branding surfaces (Company branding, one or more Branding themes) are in use.

### Phase 2: Current-State Discovery
Download every relevant custom CSS file and confirm whether custom CSS is used at all, and since when (for Stage 1 relevance).

### Phase 3: Property-List Cross-Reference
Pattern-match downloaded CSS against the CURRENT full retired-property list (MC1458474, not the earlier MC1435782 list), either manually or via the companion script.

### Phase 4: Remediation Design
For each flagged property, determine whether it can simply be removed (no visible impact) or requires a layout redesign using non-retired properties to preserve the intended visual effect.

### Phase 5: Validation and Stakeholder Communication
Test the redesigned branding, confirm it displays as intended, and communicate any unavoidable visual change to internal stakeholders ahead of the Stage 2 cutover date rather than reactively after users notice.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Full pre-cutover branding CSS audit for an MSP client roster</summary>

**Use when:** An MSP wants to proactively sweep all managed tenants' branding configurations ahead of the late-October 2026 Stage 2 cutover, rather than waiting for individual client tickets.

1. For each managed tenant, confirm it's a standard Entra ID tenant (skip External ID/CIAM tenants — out of scope).
2. Confirm whether Company branding and/or any Branding themes are configured (`Get-MgOrganizationBranding`, plus manual check of Enterprise Applications for per-app custom sign-in).
3. Download every in-use custom CSS file across both surfaces.
4. Run each through the companion script to flag retired properties against the current (MC1458474) full list.
5. For tenants with zero flagged properties: document as "reviewed, no action needed" and move on.
6. For tenants with flagged properties: schedule a redesign pass before the cutover date, prioritizing tenants where the branding serves an external/customer-facing audience (higher phishing-impersonation stakes, and higher visibility if the layout shifts unexpectedly).
7. Track completion against the Oct 26, 2026 deadline in your standard client-facing change calendar.

**Rollback:** N/A — this is an audit/remediation sweep; individual CSS file edits remain reversible by re-uploading a prior version.

</details>

<details><summary>Playbook 2 — Redesigning a branding layout that depended on a retired property</summary>

**Use when:** A specific branding element's positioning genuinely depends on a retired property and simply removing the declaration produces an unacceptable visual result.

1. Identify exactly which visual effect the retired property was producing (e.g., `grid-column`/`grid-row` used to place a custom banner in a specific position, `mask-image` used to apply a custom shape to a logo).
2. Evaluate whether the effect can be reproduced with non-retired properties — basic `position: relative/absolute` with `top`/`left`/`right`/`bottom`, standard `padding`/simple `margin` (non-block/inline logical variants), `flex` properties (not in the retired list), or by pre-rendering the desired visual effect directly into the image/logo asset itself rather than achieving it via CSS.
3. Where no CSS-only substitute exists, consider baking the effect into a modified image asset (e.g., a background image with the mask/clip effect already applied) as a common workaround pattern for retired masking/clipping properties specifically.
4. Test across the browsers/devices your organization's users actually use for sign-in — rendering nuances can differ, especially around any WebKit-specific fallback behavior.
5. Document the before/after for stakeholder sign-off before the cutover date.

**Rollback:** Re-upload the previous CSS file if the redesign is rejected — no platform-side rollback mechanism exists once the cutover has occurred and the property is no longer honored, so pre-cutover testing is the only real safety net.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Company branding configuration state and a manual-inspection reminder
    for an escalation or pre-cutover audit record. (Custom CSS content itself must be
    downloaded and inspected separately — see the companion script for pattern-matching.)
#>

Write-Host "=== Organization branding configuration ===" -ForegroundColor Cyan
$orgId = (Get-MgOrganization).Id
Get-MgOrganizationBranding -OrganizationId $orgId | Format-List

Write-Host "`n=== Branding localizations (if any) ===" -ForegroundColor Cyan
try {
    Get-MgOrganizationBrandingLocalization -OrganizationId $orgId -ErrorAction Stop | Format-Table -AutoSize
} catch {
    Write-Host "No localizations found or endpoint unavailable in this module version." -ForegroundColor DarkGray
}

Write-Host "`n=== Manual step reminder ===" -ForegroundColor Yellow
Write-Host "Download the Custom CSS file directly: Entra admin center -> Company branding ->" -ForegroundColor DarkGray
Write-Host "Edit -> Layout -> Custom CSS -> Download. Repeat for each Branding theme in use." -ForegroundColor DarkGray
Write-Host "Then run: .\Get-BrandingCSSRetirementAudit.ps1 -CssFilePath <downloaded file>" -ForegroundColor DarkGray
```

---

## Command Cheat Sheet

```powershell
# Confirm branding configuration exists
Get-MgOrganizationBranding -OrganizationId (Get-MgOrganization).Id

# Confirm locale-specific branding variants
Get-MgOrganizationBrandingLocalization -OrganizationId (Get-MgOrganization).Id

# Run the companion script against a downloaded CSS file
.\Get-BrandingCSSRetirementAudit.ps1 -CssFilePath "C:\temp\branding.css"
```

```
# Portal navigation
Entra admin center → Company branding → Edit → Layout → Custom CSS → Download
Entra admin center → Enterprise applications → <app> → Custom branding (Branding themes) → same download step

# Tenant Message Center
admin.cloud.microsoft or security.microsoft.com → Message Center → search "MC1458474" and "MC1435782"
```

---

## 🎓 Learning Pointers

- **Two Message Center posts, one retirement — and the later one supersedes the earlier one's property list.** MC1435782 was the original announcement; MC1458474 (2026-08-21) expanded the retired-property list further. A client remediation based only on the earlier post may be working from an incomplete list — always confirm against the most current post. [Deprecation of custom CSS positioning properties — CSS template reference](https://learn.microsoft.com/en-us/entra/fundamentals/reference-company-branding-css-template#deprecation-of-custom-css-positioning-properties)

- **This is a phishing-hardening move (SFI), not an arbitrary feature cut.** The specific properties targeted — those capable of repositioning, reordering, masking, or clipping page elements — are exactly the tools that would let an attacker construct a convincing fake sign-in page. Framing this to stakeholders around the security rationale, not just "Microsoft removed some CSS support," tends to land better.

- **Nothing is deleted — only layout/positioning reverts to default.** This is a common point of client anxiety worth pre-empting: logos, colors, and text remain fully intact; only where/how certain elements are positioned changes if the CSS relied on a retired property.

- **Stage 1 and Stage 2 target different populations for different reasons — don't conflate them.** Stage 1 (new-usage block, July 2026) only prevents *new* adoption; Stage 2 (global enforcement, late October 2026) affects every tenant using retired properties regardless of when they started. A tenant that's fine under Stage 1 can still be fully exposed under Stage 2.

- **Company branding and Branding themes are separate configurations sharing one rule set.** Auditing one surface and declaring a tenant "compliant" without checking the other is a common gap — especially for organizations with customer-facing apps using distinct per-application sign-in branding.

- **This is explicitly the first of at least two retirement waves.** Microsoft has signaled a fuller custom-CSS retirement "later in 2027" with advance notice still pending. Treat this October 2026 change as a checkpoint, not the finish line, when advising clients on their branding customization roadmap — heavy continued investment in custom CSS generally may be worth flagging as a longer-term risk even for properties not retired in this wave.
