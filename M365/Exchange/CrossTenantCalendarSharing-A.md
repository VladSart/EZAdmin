# Exchange Online Cross-Tenant Calendar Sharing (EWS → M365 XTAP Migration) — Reference Runbook (Mode A: Deep Dive)
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

**In scope:** the migration of three legacy Exchange Online cross-tenant sharing mechanisms — **Organization Relationship** (Free/Busy + MailTips), **Availability Address Space** with `AccessMethod: OrgWideFBToken` (Free/Busy), and **Sharing Policy** (external Calendar Sharing) — to the new **Microsoft 365 Cross-Tenant Access Policy (M365 XTAP)**, driven by the retirement of Exchange Web Services (EWS) in Exchange Online (deprecation begins **October 1, 2026**) and Microsoft's broader move away from High-Privilege Access authentication patterns.

**Out of scope (covered elsewhere):**
- Entra ID B2B guest collaboration and the base Entra Cross-Tenant Access Policy trust relationship in general — see `EntraID/Troubleshooting/CrossTenant-B.md`. M365 XTAP for calendar/Free-Busy/MailTips is layered **on top of** that trust relationship, not a replacement for B2B collaboration settings.
- On-premises Exchange hybrid Organization Relationships used for hybrid free/busy between on-prem and Exchange Online within the *same* organization — see `Hybrid-Coexistence-A.md`. This runbook covers **tenant-to-tenant** (different organizations) sharing only.
- The general EWS deprecation program beyond these three sharing scenarios (Outlook client EWS dependencies, third-party app EWS usage, hybrid free/busy) — see [Deprecation of EWS in Exchange Online](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/deprecation-of-ews-exchange-online) for the full retirement scope.

**Assumed baseline:** Exchange Online tenant with Organization Management (or Exchange Administrator) role for legacy-object management, Global Administrator or Exchange Administrator for the new Graph-based XTAP configuration, and Microsoft Graph PowerShell SDK **Beta** module installed (the XTAP cmdlets used here are beta-only as of this writing).

---

## How It Works

<details><summary>Full architecture</summary>

### Why this migration exists

Three unrelated-looking Exchange Online features — sharing Free/Busy availability, sharing MailTips (out-of-office status, large-audience warnings, custom tips), and sharing full calendar details externally — have historically been implemented as three separate legacy object types, all of which resolve the target organization's endpoint via **Exchange Web Services**:

- **Organization Relationship** — the oldest and most flexible mechanism; one object can carry both Free/Busy and MailTips sharing for a set of external domains, with independent access-level and scope controls for each.
- **Availability Address Space** — a narrower, Free/Busy-only mechanism. When its `AccessMethod` is `OrgWideFBToken`, it's used specifically for tenant-to-tenant Microsoft 365 Free/Busy lookups (any other `AccessMethod` value isn't functional for this scenario and isn't part of this deprecation).
- **Sharing Policy** — controls what level of calendar detail a user's own calendar-sharing invitations expose to external recipients (time-only, time+subject+location, or full reviewer-level detail), including anonymous published-calendar URLs.

All three, when pointed at another Microsoft 365 tenant, resolve via EWS endpoints (`TargetSharingEpr`/`TargetAutodiscoverEpr`/`TargetServiceEpr`). As Microsoft retires EWS across its entire product surface (Outlook, Teams, Dynamics 365, and Exchange Online itself) and migrates away from High-Privilege Access authentication patterns, these three sharing scenarios need a non-EWS-dependent replacement — which is Microsoft 365 Cross-Tenant Access Policy.

### The architectural shift: object-per-relationship → capability-per-partner

The legacy model is **object-centric**: an admin creates one Organization Relationship object (or Sharing Policy, or Availability Address Space) that bundles multiple capabilities and multiple external domains together. The new model is **capability-centric and per-partner**: each sharing capability (Free/Busy at one of two detail levels, MailTips at one of two detail levels, Calendar Sharing at one of three detail levels, plus a separate Anonymous variant) is its own discrete policy object, explicitly scoped to one partner Tenant ID (identified by GUID, not domain name) — or, for Calendar Sharing only, to a wildcard/default policy and a separate Anonymous policy.

This has a real practical consequence for multi-domain organizations: **the old model let you identify a partner by any of its SMTP domains; the new model identifies a partner exclusively by Entra Tenant ID.** All of that partner's domains are automatically included once the Tenant ID relationship exists — there is no per-domain configuration step in XTAP, which simplifies multi-domain partners but means you must obtain the correct Tenant ID from the partner admin rather than simply knowing their email domain.

### Two-layer trust model

M365 XTAP is not a standalone policy — it is explicitly built **on top of** the existing Entra Cross-Tenant Access Policy framework (the same framework governing B2B guest collaboration). Before any Free/Busy, MailTips, or Calendar Sharing capability can take effect for a given partner, that partner must have the **Microsoft 365 Collaboration trust level** enabled in the tenant's Entra Cross-Tenant Access Policy (`m365CollaborationInbound`). This is a one-time, per-partner setup step (Tenant-ID-scoped, no domain enumeration needed) that sits *underneath* the sharing-specific capability objects described above. Omitting this step — building the sharing capability without first establishing the trust relationship — is the single most common configuration-order mistake in this migration, because the capability object will create successfully with no error, yet have no effect.

### Inbound-only, non-reciprocal capabilities

Every XTAP capability object created here is an **inbound** setting: it governs what *your* organization exposes to the outside world when queried by the partner, not what you can see of theirs. There is no bidirectional or "mutual" configuration object. For two organizations to see each other's Free/Busy, both must independently create their own inbound capability — Tenant A's outbound visibility into Tenant B is entirely a function of Tenant B's own inbound configuration, and vice versa. This mirrors how Organization Relationships worked (each side needed its own relationship object), but it's easy to miss with XTAP specifically because the underlying Entra trust-relationship step can *feel* like a single shared handshake even though the M365 capability layer above it is not.

### Precedence during migration

Legacy configurations are **not automatically disabled** when an equivalent XTAP capability is created — both can coexist, and the legacy object always takes precedence while it remains `Enabled: True` (or, for Availability Address Space, simply exists — it has no enable/disable flag, only exists/removed). This is intentional: it lets an admin build and validate the new XTAP configuration in parallel with a still-functioning legacy path, then cut over deliberately by disabling (or removing, for Availability Address Space) the old object once both sides confirm the new path works. Skipping this validate-before-cutover sequence, or forgetting that a legacy object needs to be explicitly disabled (not just superseded), is the second most common post-migration troubleshooting call.

</details>

---

## Dependency Stack

```
Layer 5: Feature-level user experience
           Outlook/OWA Free-Busy grid, MailTips banners, calendar-sharing invitations
Layer 4: Microsoft 365 Cross-Tenant Access Policy — per-capability objects (per partner Tenant ID)
           crossTenantCalendarAvailabilityBasic / -LimitedDetails        (Free/Busy)
           crossTenantMailTipsLimited / -All                             (MailTips)
           crossTenantCalendarSharingFreeBusySimple / -Detail / -Reviewer (Calendar Sharing)
           AnonymousCalendarFreeBusySimple / -Detail / -Reviewer          (Calendar Sharing, anonymous only)
           — INBOUND-only, independently configured per organization, no cmdlet-level "test both sides" check
Layer 3: Entra Cross-Tenant Access Policy — Microsoft 365 Collaboration trust (m365CollaborationInbound)
           — prerequisite layer; capability objects above have no effect without this
Layer 2: Legacy EWS-dependent objects (still evaluated FIRST if enabled — precedence over Layer 3/4)
           Organization Relationship | Availability Address Space (OrgWideFBToken) | Sharing Policy
Layer 1: Exchange Web Services (EWS) in Exchange Online
           — deprecation begins October 1, 2026; Layer 2 breaks once removed for the relevant scenario
```

A tenant can be fully "migrated" at Layer 4 yet still show no behavior change at all if Layer 2 objects remain enabled — Layer 2 wins on precedence regardless of what exists at Layer 3/4. This is the single highest-value fact in this entire topic for triage purposes.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Configured XTAP capability, but Free/Busy/MailTips/sharing behavior unchanged | Legacy Organization Relationship / Sharing Policy still `Enabled: True`, taking precedence | `Get-OrganizationRelationship` / `Get-SharingPolicy` for the partner domain |
| XTAP capability created, still no effect even after disabling legacy config | Entra `m365CollaborationInbound` trust relationship never created for that partner | `Invoke-MgGraphRequest GET .../policies/crossTenantAccessPolicy/partners/<id>` |
| Free/Busy migrated and working, but MailTips (OOF, large-audience warning) missing | MailTips is a separate capability object from Free/Busy — migrating one doesn't migrate the other, even though a single legacy Organization Relationship carried both | Check for a `crossTenantMailTipsLimited`/`-All` capability object specifically |
| Works from our side querying the partner, but the partner reports they can't see us | XTAP capabilities are inbound-only and non-reciprocal — the partner hasn't built their own inbound configuration | Confirm directly with partner admin; nothing to check on your own side |
| Everything works internally in testing right after Oct 2026 EWS deprecation date, but breaks for one specific older partner | That partner hasn't migrated their own EWS-dependent legacy config on their side yet, and their outbound EWS calls to you (or yours to them) start failing | Coordinate migration timing with partner admin; not fixable unilaterally |
| Anonymous published calendar URL (`CalendarSharingFreeBusy...` Anonymous variant) stopped working post-migration | Anonymous capabilities can **only** be set on the default/wildcard Cross-Tenant Access Policy, not a per-partner policy — a common configuration-target mistake | Confirm `AnonymousCalendarFreeBusy...` capability was created via `New-MgBetaPolicyCrossTenantAccessPolicyDefaultM365Capability`, not the per-partner cmdlet |
| Multiple legacy Sharing Policies existed, assigned to different user subsets, but XTAP only replicates one detail level | XTAP per-partner/default capability objects don't natively support "different detail levels per internal user group" the way multiple assigned Sharing Policies did — this requires deliberate use of the optional security-group scoping parameter on the capability object | Rebuild using `resourceScopes.included` security groups per distinct detail level required |

---

## Validation Steps

1. **Enumerate every legacy object touching a given partner domain.**
   ```powershell
   Get-OrganizationRelationship | Where-Object { $_.DomainNames -match "<partnerdomain>" }
   Get-AvailabilityAddressSpace | Where-Object { $_.ForestName -match "<partnerdomain>" }
   Get-SharingPolicy | Where-Object { $_.Domains -match "<partnerdomain>" }
   ```
   *Good:* complete inventory before any change. *Bad:* skipping this step risks migrating an incomplete picture — a domain can appear in more than one legacy object type simultaneously.

2. **Confirm the Entra M365 Collaboration trust exists for the partner Tenant ID.**
   ```powershell
   Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners/<partnerTenantId>"
   ```
   *Good:* `m365CollaborationInbound.users.accessType` = `allowed`. *Bad:* object missing entirely, or present without the `m365CollaborationInbound` block — build it before anything else.

3. **Confirm each required capability object exists with the correct scope.**
   ```powershell
   Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners/<partnerTenantId>/microsoft365CapabilitiesInbound"
   ```
   *Good:* the expected capability names (matching what was migrated from Free/Busy, MailTips, and/or Calendar Sharing) are present with `inboundAccess.isAllowed: true`. *Bad:* wrong capability variant chosen (e.g., `-Basic` instead of `-LimitedDetails`) — cross-check against the legacy object's original access level using the mapping table in the Command Cheat Sheet.

4. **Confirm legacy precedence has actually been removed.**
   ```powershell
   Get-OrganizationRelationship -Identity "<name>" | Select-Object Name, Enabled
   Get-SharingPolicy -Identity "<name>" | Select-Object Name, Enabled
   ```
   *Good:* `Enabled: False` (or, for Availability Address Space, the object no longer exists). *Bad:* still `True` — this alone fully explains "XTAP configured but nothing changed."

5. **Confirm bidirectional readiness with the partner (cannot be validated unilaterally).**
   No cmdlet in either tenant can confirm the *other* organization's inbound configuration. This must be confirmed by direct coordination with the partner admin — document this explicitly in change records rather than assuming.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Inventory and blast-radius sizing**
Enumerate all three legacy object types tenant-wide (not just for one partner) and cross-reference against `Get-EXOMailbox ... -Properties SharingPolicy` to know how many mailboxes are actually affected by a Sharing Policy before planning migration order.

**Phase 2 — Entra trust-layer setup**
For every partner Tenant ID identified in Phase 1, confirm or create the `m365CollaborationInbound` trust relationship. This is a one-time step per partner regardless of how many of the three sharing capabilities that partner needs.

**Phase 3 — Capability object creation**
Create the specific XTAP capability object(s) matching each legacy object's original access level, using the mapping table in the Command Cheat Sheet. Do this for every partner before touching any legacy object's enabled state.

**Phase 4 — Parallel-run validation**
With both legacy and XTAP configurations live simultaneously, temporarily disable only the legacy config for a single test partner, confirm functionality with that partner's admin, then re-enable the legacy config if anything is wrong. Do not disable legacy configs tenant-wide before this validation completes for at least one partner.

**Phase 5 — Cutover and cleanup**
Once validated, disable (Organization Relationship/Sharing Policy) or remove (Availability Address Space, after exporting a backup) the legacy objects for each migrated partner. Retain the backups until confident no rollback is needed, then permanently remove with `Remove-OrganizationRelationship`/`Remove-SharingPolicy`.

**Phase 6 — Deadline tracking**
Track remaining un-migrated partners against the October 1, 2026 EWS deprecation start date. Migration doesn't need to complete by that exact date for every partner simultaneously, but any partner relationship still fully dependent on EWS after that date is at risk the moment Microsoft's phased EWS removal reaches the affected API surface for that scenario.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Full tenant migration for a single external partner</summary>

1. Run Validation Step 1 to inventory every legacy object touching the partner's domain(s).
2. Obtain the partner's Entra Tenant ID from their admin (not derivable from domain name alone).
3. Build the Entra `m365CollaborationInbound` trust relationship (Validation Step 2).
4. For each legacy capability found in step 1, create the matching XTAP capability object using the correct access-level mapping (Command Cheat Sheet table).
5. Ask the partner admin to complete the mirrored steps 2-4 on their own side — this cannot be validated or completed unilaterally.
6. Both sides temporarily disable their legacy objects for this partner only (Phase 4) and jointly test Free/Busy, MailTips, and calendar-sharing invitations in both directions.
7. On confirmed success, both sides permanently disable/remove the legacy objects for this partner (Phase 5).

**Rollback:** re-enable the legacy Organization Relationship/Sharing Policy (`-Enabled $True`), or re-import the Availability Address Space backup via `Add-AvailabilityAddressSpace`. Because legacy precedence is unconditional while enabled, rollback is immediate and doesn't require touching the new XTAP objects at all.

</details>

<details><summary>Playbook 2 — Multi-domain partner with differentiated Sharing Policy detail levels</summary>

1. Identify each distinct detail level currently assigned across the partner's users via `Get-EXOMailbox ... -Properties SharingPolicy` grouped by policy name.
2. For each distinct detail level, create (or maintain) a security group containing exactly the internal users who should receive that level of outbound sharing with this partner.
3. Create one XTAP Calendar Sharing capability object per detail level, scoping `resourceScopes.included` to the matching security group rather than `All` users.
4. This is the one scenario where XTAP requires more setup steps than the legacy model — the old Sharing Policy assignment-per-mailbox model doesn't have a 1:1 XTAP equivalent, and security-group scoping is the only way to replicate differentiated detail levels.

**Rollback:** remove or disable the newly created group-scoped capability objects; legacy Sharing Policies remain unaffected until explicitly disabled.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Read-only evidence collector for Cross-Tenant Calendar/Free-Busy/MailTips (EWS→XTAP) escalations.
#>
$OutputPath = "C:\XTAP-Migration-Evidence"
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

Get-OrganizationRelationship | Format-List Name, DomainNames, Enabled, FreeBusyAccessEnabled, FreeBusyAccessLevel, MailTipsAccessEnabled, MailTipsAccessLevel, TargetSharingEpr |
    Out-File "$OutputPath\OrganizationRelationships.txt"

Get-AvailabilityAddressSpace | Format-List ForestName, AccessMethod, TargetServiceEpr, TargetTenantId |
    Out-File "$OutputPath\AvailabilityAddressSpaces.txt"

Get-SharingPolicy | Format-List Name, Enabled, Domains, Default |
    Out-File "$OutputPath\SharingPolicies.txt"

Get-EXOMailbox -ResultSize Unlimited -RecipientTypeDetails UserMailbox,SharedMailbox -Properties SharingPolicy |
    Group-Object SharingPolicy | Select-Object Name, Count |
    Export-Csv "$OutputPath\SharingPolicyAssignments.csv" -NoTypeInformation

Write-Host "Evidence exported to $OutputPath. Also manually capture, per relevant partner Tenant ID:" -ForegroundColor Yellow
Write-Host "  Invoke-MgGraphRequest GET .../policies/crossTenantAccessPolicy/partners/<id>" -ForegroundColor Yellow
Write-Host "  Invoke-MgGraphRequest GET .../policies/crossTenantAccessPolicy/partners/<id>/microsoft365CapabilitiesInbound" -ForegroundColor Yellow
Write-Host "  and confirmation from the partner admin of their own inbound-side configuration state." -ForegroundColor Yellow
```

---

## Command Cheat Sheet

| Command / Object | Purpose |
|---------|---------|
| `Get-OrganizationRelationship` | Inventory legacy Free/Busy + MailTips sharing config |
| `Get-AvailabilityAddressSpace` | Inventory legacy Free/Busy-only sharing config; check `AccessMethod` |
| `Get-SharingPolicy` | Inventory legacy external Calendar Sharing config |
| `Get-EXOMailbox -Properties SharingPolicy` | Blast-radius: which mailboxes use which Sharing Policy |
| `New-MgBetaPolicyCrossTenantAccessPolicyPartner` (with `m365CollaborationInbound`) | Create the prerequisite Entra trust relationship for a partner |
| `New-MgBetaPolicyCrossTenantAccessPolicyPartnerM365Capability` | Create a per-partner Free/Busy, MailTips, or Calendar Sharing capability |
| `New-MgBetaPolicyCrossTenantAccessPolicyDefaultM365Capability` | Create the wildcard/default Calendar Sharing capability (required for non-partner-specific sharing policies) |
| `crossTenantCalendarAvailabilityBasic` / `-LimitedDetails` | Replaces Org Relationship `FreeBusyAccessLevel` = AvailabilityOnly / LimitedDetails |
| `crossTenantMailTipsLimited` / `-All` | Replaces Org Relationship `MailTipsAccessLevel` = Limited / All |
| `crossTenantCalendarSharingFreeBusySimple` / `-Detail` / `-Reviewer` | Replaces Sharing Policy access levels `CalendarSharingFreeBusySimple` / `-Detail` / `-Reviewer` |
| `AnonymousCalendarFreeBusySimple` / `-Detail` / `-Reviewer` | Replaces Sharing Policy `Anonymous` entries — default policy only, never per-partner |
| `Set-OrganizationRelationship -Enabled $False` | Disable legacy config (non-destructive, reversible) |
| `Remove-AvailabilityAddressSpace` | Remove legacy config (back up with `Export-Clixml` first — no disable flag exists) |

---

## 🎓 Learning Pointers

- The single highest-value fact for this entire topic: **legacy configuration always takes precedence over XTAP while enabled.** A fully-built XTAP configuration with zero observable effect almost always means the corresponding legacy object hasn't been disabled yet — check that before assuming the XTAP config itself is wrong.
- M365 XTAP capabilities are **inbound-only and non-reciprocal** — there is no bidirectional configuration object, and no cmdlet in either tenant can confirm the partner's own inbound state. Coordination with the partner admin is not optional, it's structurally required.
- Free/Busy, MailTips, and Calendar Sharing are independent capability objects in XTAP even when a single legacy Organization Relationship carried more than one of them — migrating one does not migrate the others.
- Anonymous calendar-sharing capabilities can only be set on the **default** Cross-Tenant Access Policy, never a per-partner one — this is explicitly documented and easy to miss if you default to the per-partner cmdlet pattern used for everything else.
- This migration is driven by two converging Microsoft initiatives, not one: EWS deprecation in Exchange Online, and the broader retirement of High-Privilege Access authentication patterns across Outlook, Teams, and Dynamics 365 — see [Enhancing Microsoft 365 security by eliminating high-privilege access](https://www.microsoft.com/security/blog/2025/07/08/enhancing-microsoft-365-security-by-eliminating-high-privilege-access/) for the security rationale beyond "EWS is going away."
- Full official migration walkthrough, including PowerShell for every legacy-object variant not detailed here: [Migrate to Microsoft 365 Cross-Tenant Access Policy for sharing Free/Busy, Calendars, and MailTips](https://learn.microsoft.com/en-us/exchange/sharing/migrate-to-m365-xtap) (Microsoft Learn, last updated 2026-09-01).
- Rollout status varies by tenant as of this writing — confirm via Message Center before assuming the M365 XTAP capability objects are available to configure at all.
