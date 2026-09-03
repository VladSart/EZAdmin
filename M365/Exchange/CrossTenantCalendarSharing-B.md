# Exchange Online Cross-Tenant Calendar Sharing (EWS → M365 XTAP Migration) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [🎓 Learning Pointers](#-learning-pointers)

---

> **Time-sensitive:** Exchange Web Services (EWS) deprecation in Exchange Online begins **October 1, 2026**. Free/Busy, MailTips, and external Calendar Sharing configured via **Organization Relationship**, **Availability Address Space** (OrgWideFBToken method), or **Sharing Policy** all ride on EWS today and will break once EWS is removed for the affected mechanism, unless migrated to the new **Microsoft 365 Cross-Tenant Access Policy (M365 XTAP)** first. Microsoft 365 Cross-Tenant Access Policy for these three scenarios began rolling out September 2026 and may not have reached every tenant yet — check Message Center. This is distinct from `EntraID/Troubleshooting/CrossTenant-B.md`, which covers Entra ID B2B collaboration/direct connect cross-tenant access (guest sign-in, external collaboration settings) — M365 XTAP for calendar/Free-Busy/MailTips is a **new, separate policy layer that builds on top of** the Entra Cross-Tenant Access Policy trust relationship, not a replacement for it.

---

## Triage

Run these in Exchange Online PowerShell (Organization Management role) to find out fast whether a tenant is exposed and what's actually broken:

```powershell
Connect-ExchangeOnline -UserPrincipalName <adminUPN>

# 1. Inventory legacy EWS-dependent configurations — the "are we exposed at all" check
$FormatEnumerationLimit = -1
Write-Host "--- Organization Relationships (Free/Busy + MailTips) ---" -ForegroundColor Cyan
Get-OrganizationRelationship | Where-Object { $_.Enabled -eq $true } |
    Format-List Name, DomainNames, FreeBusyAccessEnabled, FreeBusyAccessLevel, MailTipsAccessEnabled, MailTipsAccessLevel, TargetSharingEpr

Write-Host "--- Availability Address Spaces (Free/Busy) ---" -ForegroundColor Cyan
Get-AvailabilityAddressSpace | Format-List ForestName, AccessMethod, TargetServiceEpr, TargetTenantId

Write-Host "--- Sharing Policies (Calendar Sharing) ---" -ForegroundColor Cyan
Get-SharingPolicy | Where-Object { $_.Enabled -eq $true } | Format-List Name, Domains, Default

# 2. Which users are actually assigned an enabled Sharing Policy (blast-radius sizing)
Get-EXOMailbox -ResultSize Unlimited -RecipientTypeDetails UserMailbox,SharedMailbox -Properties SharingPolicy |
    Group-Object SharingPolicy | Select-Object Name, Count

# 3. Has this tenant already received the M365 XTAP capability? (no direct switch — inferred by whether any
#    partner-scoped M365 capability exists yet)
Connect-MgGraph -Scopes "Policy.Read.All" -ContextScope Process
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners" |
    Select-Object -ExpandProperty value | ForEach-Object { $_.tenantId }
```

**Interpretation:**

| Result | Meaning | Next step |
|--------|---------|-----------|
| No Organization Relationships, Availability Address Spaces (OrgWideFBToken), or Sharing Policies enabled | Tenant has no legacy EWS-based cross-tenant sharing configured — not exposed to this specific deprecation for these three features | No action needed for this topic; still confirm no other EWS-dependent app/script exists (see Learning Pointers) |
| Org Relationships or Sharing Policies enabled with real domains assigned to mailboxes | Genuinely exposed — must migrate before Oct 1 2026 | Go to Fix 1 |
| Availability Address Space present but `AccessMethod` is **not** `OrgWideFBToken` | Not EWS-dependent for this specific config (other AccessMethod values aren't functional for tenant-to-tenant M365 sharing anyway) — low priority, but still a candidate for the security/feature upgrade | Go to Fix 2 (optional) |
| Free/Busy or calendar sharing with a specific partner suddenly stopped working after Sept 2026 | Rollout of M365 XTAP reached one side only, or the M365 Collaboration trust wasn't enabled on the Entra Cross-Tenant Access Policy layer first | Go to Fix 3 |
| MailTips (out-of-office, large-audience warnings) missing for one external partner only | Per-partner Org Relationship not yet migrated, or MailTips capability not enabled in the new XTAP partner policy | Go to Fix 4 |
| Everything migrated but sharing still broken with one partner | Bidirectional requirement not met — the **other** tenant hasn't completed their own inbound XTAP configuration yet | Go to Fix 5 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
[Entra Cross-Tenant Access Policy — partner trust relationship]
        └── [Microsoft 365 Collaboration trust level enabled for the partner tenant]
              (New-MgBetaPolicyCrossTenantAccessPolicyPartner with m365CollaborationInbound)
              — this is a PREREQUISITE layer, distinct from and required before any of the below
              └── [Microsoft 365 Cross-Tenant Access Policy — per-capability config]
                    ├── crossTenantCalendarAvailabilityBasic / -LimitedDetails   (Free/Busy)
                    ├── crossTenantMailTipsLimited / -All                        (MailTips)
                    └── crossTenantCalendarSharingFreeBusySimple / -Detail / -Reviewer
                          (Calendar Sharing — default/wildcard, Anonymous, and per-partner variants)
                    ↑
                    Each capability is an INBOUND-only setting — each organization independently
                    controls what it exposes to the outside. Bidirectional sharing requires BOTH
                    tenants to configure their own inbound XTAP capability.
        ↑
        Legacy path (still evaluated FIRST — takes precedence over XTAP until disabled):
[Organization Relationship] → Free/Busy + MailTips, relies on EWS (TargetSharingEpr)
[Availability Address Space, AccessMethod=OrgWideFBToken] → Free/Busy, relies on EWS
[Sharing Policy] → external Calendar Sharing, relies on EWS
        ↓
[EWS in Exchange Online] — deprecation begins October 1, 2026
        (all three legacy mechanisms above depend on this; XTAP does not)
```

**Critical ordering fact:** as long as a legacy Organization Relationship / Availability Address Space / Sharing Policy remains **enabled**, it takes precedence over an equivalent XTAP configuration — the two are not additive. This is *why* Part 3 of Microsoft's own migration guidance requires temporarily disabling the legacy config to test the new one, and it's the single most common cause of "I configured XTAP and nothing changed."

</details>

---

## Diagnosis & Validation Flow

1. **Confirm what's actually configured today (Triage step 1).**
   *Good:* clear picture of which of the three legacy mechanisms are live and for which partner domains.
   *Bad:* nothing returned but users still report broken sharing — check for on-prem Exchange hybrid Organization Relationships instead (out of scope here; see `Hybrid-Coexistence-A.md`).

2. **Confirm the Entra Cross-Tenant Access Policy trust layer is set up for the partner FIRST.**
   ```powershell
   Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners/<partnerTenantId>"
   ```
   *Good:* `m365CollaborationInbound` block exists with `accessType: allowed`. *Bad:* missing entirely — this is the #1 root cause of "XTAP capability configured but still doesn't work." M365 XTAP is layered on top of, not a substitute for, this trust relationship.

3. **Confirm the specific M365 capability was created with the correct capability name.**
   ```powershell
   Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners/<partnerTenantId>/microsoft365CapabilitiesInbound"
   ```
   Match against: `crossTenantCalendarAvailabilityBasic`/`-LimitedDetails` (Free/Busy), `crossTenantMailTipsLimited`/`-All` (MailTips), `crossTenantCalendarSharingFreeBusySimple`/`-Detail`/`-Reviewer` (Calendar Sharing). A common mistake is creating the Entra trust relationship but never adding the M365-specific capability object — the trust alone grants nothing for these three scenarios.

4. **Confirm precedence — is a legacy config still enabled and shadowing the new one?**
   Re-run Triage step 1. If any Organization Relationship, Availability Address Space, or Sharing Policy touching this partner domain is still `Enabled: True`, it wins over XTAP every time.

5. **Confirm the partner side has done the same.**
   M365 XTAP capabilities are **inbound-only** and **not reciprocal automatically** — ask the partner admin to run the equivalent checks in their own tenant.

---

## Common Fix Paths

<details><summary>Fix 1 — Migrate a genuinely EWS-exposed configuration before the Oct 1 2026 deadline</summary>

1. Get the partner's Entra Tenant ID (their admin finds it under Entra ID > Overview in the Azure/Entra portal).
2. Enable Microsoft 365 Collaboration trust for that partner in your Entra Cross-Tenant Access Policy:
   ```powershell
   Connect-MgGraph -Scopes "Policy.ReadWrite.CrossTenantAccess,Policy.ReadWrite.CrossTenantCapability" -ContextScope Process
   $partnerId = "<partnerTenantId>"
   $body = @{
     tenantId = $partnerId
     m365CollaborationInbound = @{
       users = @{ accessType = "allowed"; targets = @(@{ target = "AllUsers"; targetType = "user" }) }
     }
   }
   New-MgBetaPolicyCrossTenantAccessPolicyPartner -BodyParameter $body
   ```
3. Create the matching M365 capability for whichever legacy feature you're replacing (Free/Busy shown; substitute the MailTips or Calendar Sharing capability name and matching `New-MgBetaPolicyCrossTenantAccessPolicy...` cmdlet per the Learning Pointers link for the other two):
   ```powershell
   $capability = "crossTenantCalendarAvailabilityBasic"   # or -LimitedDetails
   $group = @{ resourceId = "All"; resourceType = "user" }   # or scope to a specific group
   $capBody = @{
     "@odata.type" = "microsoft.graph.$capability"
     inboundAccess = @{ isAllowed = $true; resourceScopes = @{ included = @($group); excluded = @(@{}) } }
   }
   New-MgBetaPolicyCrossTenantAccessPolicyPartnerM365Capability -CrossTenantAccessPolicyConfigurationPartnerTenantId $partnerId -BodyParameter $capBody
   ```
4. Coordinate with the partner admin to disable their legacy config and confirm they've built the equivalent inbound XTAP capability on their side too.
5. Disable (don't delete yet) your own legacy configuration to let XTAP take precedence:
   ```powershell
   Set-OrganizationRelationship -Identity "<RelationshipName>" -Enabled $False
   Set-SharingPolicy -Identity "<PolicyName>" -Enabled $False
   # Availability Address Space has no disable switch — back it up then remove it:
   Get-AvailabilityAddressSpace <ForestName> | Export-Clixml .\AASBackup_<ForestName>.xml
   Remove-AvailabilityAddressSpace <ForestName>
   ```
6. Test Free/Busy, MailTips, and/or calendar sharing with the partner. If it works, proceed to permanently remove the legacy objects (`Remove-OrganizationRelationship` / `Remove-SharingPolicy`).

**Rollback:** re-enable with `Set-OrganizationRelationship -Enabled $True` / `Set-SharingPolicy -Enabled $True`, or re-import the Availability Address Space from the XML backup via `Add-AvailabilityAddressSpace`. Legacy precedence means re-enabling instantly restores old behavior without touching the new XTAP config.

</details>

<details><summary>Fix 2 — Non-EWS Availability Address Space (optional upgrade only)</summary>

An Availability Address Space with `AccessMethod` other than `OrgWideFBToken` isn't functional for tenant-to-tenant Microsoft 365 sharing regardless, and `OrgWideFBToken` itself does **not** depend on EWS — so this specific mechanism is not on the October 2026 deadline. Migrating it to XTAP anyway is optional, done only to gain XTAP's more granular security-group scoping. Do not treat this as urgent triage.

</details>

<details><summary>Fix 3 — Worked before September, broke after — trust layer or rollout gap</summary>

1. Confirm the tenant has actually received the M365 XTAP rollout — check Message Center for the relevant post; there is no portal toggle to force early access.
2. If present, re-run Diagnosis step 2 — a very common failure is that someone built the M365 capability object (step 3) without first creating the Entra `m365CollaborationInbound` partner trust (step 2). The capability object alone does nothing without it.
3. If the tenant hasn't received the rollout yet but a partner assumed it had and disabled their legacy Organization Relationship pointing at you, ask them to temporarily re-enable it until your tenant's rollout catches up.

</details>

<details><summary>Fix 4 — MailTips missing for one partner only</summary>

1. Confirm whether MailTips for this partner was previously carried by an Organization Relationship (`MailTipsAccessEnabled`) — if so it needs its own dedicated XTAP capability (`crossTenantMailTipsLimited` or `crossTenantMailTipsAll`), separate from the Free/Busy capability. Migrating Free/Busy does **not** automatically carry MailTips — they are independent capability objects even though they were bundled in the old Organization Relationship object.
2. Create the missing capability per Fix 1 step 3, substituting the MailTips capability name.

</details>

<details><summary>Fix 5 — Migrated on our side, partner still can't see anything</summary>

M365 XTAP capabilities are **inbound-only settings** — configuring your tenant's policy controls what *you* expose outward to them, and has no effect on what they expose to you. For working bidirectional Free/Busy, MailTips, or Calendar Sharing, **both** organizations must independently build the mirrored inbound configuration. This is the single most common post-migration confusion point — confirm with the partner admin that they've completed their own inbound side, not just yours.

</details>

---

## Escalation Evidence

```
=== Cross-Tenant Calendar/Free-Busy/MailTips (EWS→XTAP) — Escalation Packet ===
Tenant:
Ticket #:
Date/Time (UTC):
Partner tenant domain / Tenant ID:

1. Legacy config inventory (Organization Relationship / Availability Address Space / Sharing Policy — attach Triage step 1 output):
2. Entra Cross-Tenant Access Policy partner trust state for this partner (m365CollaborationInbound present? Y/N, attach Graph response):
3. M365 XTAP capability objects present for this partner (list capability names returned, attach):
4. Legacy config Enabled state at time of test (must be False for XTAP to take precedence):
5. Confirmation partner admin has completed their own inbound-side configuration: Y/N/Unknown
6. Message Center post reference confirming this tenant has received the XTAP rollout for these scenarios:
7. Specific symptom (Free/Busy blank, MailTips missing, calendar sharing invite fails) and affected mailbox(es):
8. Prior fix paths attempted from this runbook:
```

---

## 🎓 Learning Pointers

- This is a genuinely **time-boxed migration**, not an optional feature upgrade — EWS deprecation in Exchange Online begins **October 1, 2026**, and Organization Relationships, `OrgWideFBToken` Availability Address Spaces are *not* EWS-dependent themselves for Free/Busy but Sharing Policies and Org Relationship MailTips/Free-Busy retrieval are. Confirm exactly which of the three legacy mechanisms a given tenant actually uses before assuming full exposure. See [Deprecation of EWS in Exchange Online](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/deprecation-of-ews-exchange-online) and [Exchange Online EWS, Your Time is Almost Up](https://techcommunity.microsoft.com/blog/Exchange/exchange-online-ews-your-time-is-almost-up/4492361).
- M365 XTAP capabilities are **inbound-only and per-organization** — there is no single shared configuration object. Every migration is really two independent migrations that must be coordinated between both tenant admins.
- Free/Busy, MailTips, and Calendar Sharing are **three separate capability objects** in XTAP even though a single legacy Organization Relationship could carry both Free/Busy and MailTips together — don't assume migrating one carries the others.
- Legacy configuration **always wins** over XTAP while it remains enabled — this is by design, to let admins build and validate the new config before cutting over, but it's also the most common "why isn't XTAP working" support call.
- Full step-by-step migration guidance, including the wildcard/Anonymous/per-partner Calendar Sharing capability variants not detailed here: [Migrate to Microsoft 365 Cross-Tenant Access Policy for sharing Free/Busy, Calendars, and MailTips](https://learn.microsoft.com/en-us/exchange/sharing/migrate-to-m365-xtap).
- This is distinct from `EntraID/Troubleshooting/CrossTenant-B.md` (B2B guest collaboration) — but the two share the same underlying Entra Cross-Tenant Access Policy trust-relationship object, so a broken B2B guest scenario and a broken calendar-sharing scenario for the *same* partner can share a root cause worth checking in both directions.
