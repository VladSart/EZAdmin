# Teams External Messaging Limits for MOERA-Only Tenants — Hotfix Runbook (Mode B: Ops)
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

> **Source-confidence note:** this is a Message Center-only feature (MC1463510, general availability worldwide 15 September 2026) with no Microsoft Learn conceptual page as of this writing. Microsoft has **not published an exact numeric threshold** for this Teams-side limit (contrast with the analogous, already-documented Exchange Online outbound-external-recipient limit of 100/24h for MOERA-only tenants — a related but separate abuse-protection feature on a different service). Do not tell a client "the limit is X messages" — the correct, accurate statement is that an unpublished threshold exists and the only guaranteed way to avoid it entirely is adding a verified custom domain.

---

## Triage

**First — confirm the tenant is actually in scope.** This limit applies **only** to tenants using solely the default onmicrosoft.com (MOERA) domain with **no custom domain configured**. A tenant with any verified custom domain is not subject to this limit at all.

```
# No PowerShell cmdlet is documented for reading this feature's state directly.
# Confirm domain configuration instead — this determines applicability:
Connect-MgGraph -Scopes "Domain.Read.All"
Get-MgDomain | Select-Object Id, IsDefault, IsInitial, IsVerified
```

**Interpretation:**

| Result | Meaning | Next step |
|--------|---------|-----------|
| Only one domain listed, ending in `.onmicrosoft.com`, `IsInitial = True` | Tenant is MOERA-only — **in scope** for this limit | Continue triage below |
| Any additional `IsVerified = True` custom domain exists | Tenant is **out of scope** — this limit does not apply | If a user still reports external-message blocking, look elsewhere (federation, cross-tenant access policy, recipient-side blocking) |
| User reports temporary inability to message external contacts, with an in-product notification | Expected behavior if tenant is MOERA-only and the (unpublished) threshold was reached | → [Fix 1 — Confirm and wait out the throttle](#fix-1--confirm-and-wait-out-the-throttle) |
| Business wants to permanently avoid this limit | → [Fix 2 — Add and verify a custom domain](#fix-2--add-and-verify-a-custom-domain) |
| Internal Teams messaging is also affected | **Not this feature** — this limit only affects outbound messages to external users; internal messaging is explicitly unaffected. Investigate as a separate issue. | Escalate as unrelated |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Tenant uses ONLY the default onmicrosoft.com (MOERA) domain
    (no verified custom domain configured)
        │
Feature is ENABLED BY DEFAULT for such tenants - no admin opt-in/opt-out exists
        │
User sends outbound Teams message(s) to EXTERNAL user(s)
        │
Cumulative outbound-external activity crosses an UNPUBLISHED threshold
        │
Sender is temporarily blocked from sending further external messages
    ├── In-product notification shown to the sender
    ├── Internal Teams messaging/collaboration UNAFFECTED
    └── External messaging capability auto-resumes once activity
        falls back below the threshold (no manual admin unblock action
        documented as of this writing)
        │
[Optional admin alert for throttling events - "will become available after
 initial rollout" per Microsoft's own post; not available at initial GA]
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm scope: is the tenant MOERA-only?**
```powershell
Get-MgDomain | Select-Object Id, IsDefault, IsInitial, IsVerified
```
If any verified custom domain exists, this feature does not apply — stop and investigate the report as something else (see Triage table).

**Step 2 — Confirm this is genuinely the messaging-limit behavior, not something else**
Confirm the block is specific to **outbound messages to external users** and that internal Teams messaging works normally for the same user. A user who cannot message anyone at all — internal or external — is experiencing a different problem (account, licensing, federation), not this feature.

**Step 3 — Confirm timing**
This is a temporary, activity-based throttle, not a permanent block. Confirm whether the affected user's external-messaging activity has been unusually high (mass messaging, bulk external outreach, scripted/bot-like sending patterns) in the recent window, consistent with the abuse-protection intent of this feature.

**Step 4 — Confirm rollout timing**
General availability is worldwide, rolling out and expected complete by **15 September 2026**. If the report predates this window, this feature is not the cause.

---

## Common Fix Paths

<details><summary>Fix 1 — Confirm and wait out the throttle</summary>

There is no documented manual override or admin unblock action for an individual user's throttle state as of this writing — the block is described by Microsoft as self-resolving once outbound-external activity drops back below the (unpublished) threshold.

```
1. Confirm the tenant is MOERA-only (Step 1 above).
2. Confirm the affected user's recent external-messaging volume/pattern with
   them directly - was this a genuine bulk-send scenario (mass external
   outreach, a script, a bot) or ordinary business use they believe should
   not have triggered a limit?
3. Set expectations: capability resumes automatically; there is no manual
   "unblock now" action published for admins to invoke.
4. If the volume was ordinary business use and the block seems disproportionate,
   treat this as a candidate for escalation to Microsoft support with the
   Escalation Evidence below, since Microsoft has not published exact
   thresholds for admins to self-diagnose against.
```

**Rollback:** N/A — no admin-initiated change was made; this is a wait-and-monitor fix path.

</details>

<details><summary>Fix 2 — Add and verify a custom domain</summary>

Adding and verifying any custom domain removes the tenant from MOERA-only scope entirely, permanently avoiding this limit going forward.

```powershell
# Requires Domain.ReadWrite.All
Connect-MgGraph -Scopes "Domain.ReadWrite.All"

# Add a new domain
New-MgDomain -Id "<yourcompany.com>"

# Retrieve verification DNS record to publish
Get-MgDomainVerificationDnsRecord -DomainId "<yourcompany.com>"

# After publishing the TXT/MX record at the DNS provider, verify:
Confirm-MgDomain -DomainId "<yourcompany.com>"

# Confirm verification succeeded
Get-MgDomain -DomainId "<yourcompany.com>" | Select-Object Id, IsVerified
```

This is a standard Microsoft 365 tenant domain-onboarding action — if the organization already has email flowing through a custom domain in Exchange Online, the domain is very likely already verified and this limit does not apply; re-run Step 1 of Diagnosis to confirm before assuming action is needed.

**Rollback:** removing a verified custom domain is a separate, higher-impact change (affects mail routing, UPNs, and more) — do not do this to "undo" adding a domain for this purpose alone; there is normally no reason to reverse a custom domain addition.

</details>

---

## Escalation Evidence

```
TICKET: Teams External Messaging Limit (MOERA-only Tenant)
=====================================================
Tenant domain configuration (Get-MgDomain output): <attach>
MOERA-only confirmed (yes/no): <value>
Affected user UPN: <upn>
Reported symptom: <temporarily blocked from external messages / in-product notification text>
Internal Teams messaging still working (yes/no): <value>
Approximate volume/pattern of recent outbound external messages: <description>
Time throttle first observed: <timestamp>
Time throttle resolved (if known): <timestamp>
Business impact: <e.g., blocked from messaging an active customer/partner>
Message Center post MC1463510 revision checked: <date>
```

---

## 🎓 Learning Pointers

- This limit is **enabled by default with no admin configuration surface** — unlike most Teams governance features in this repo, there is no policy to author or toggle; the only lever an admin has is removing the tenant from scope entirely by adding a verified custom domain.
- Microsoft has **not published an exact threshold** — resist the temptation to state a specific number to a client; the accurate answer is "an unpublished, activity-based limit."
- This is architecturally similar to, but a **separate feature from**, the Exchange Online outbound-external-recipient limit for MOERA-only tenants (a documented, specific 100-recipients-per-24-hours limit) — don't assume the two share a threshold or an admin control surface just because they target the same MOERA-only-tenant abuse pattern.
- Internal Teams messaging is explicitly unaffected — if internal messaging is also broken, this is not the cause.
- An optional admin alert for throttling events is planned but was **not available at initial rollout** — Microsoft's post states this "will become available after the initial rollout," so don't promise a client proactive admin notifications exist yet; confirm current availability directly if this becomes relevant.
- The single most durable fix for any tenant that wants to avoid this entirely is adding and verifying a custom domain — a change most production tenants have already made for other reasons (branded email addresses, UPN matching), making genuine MOERA-only exposure to this limit relatively rare outside of brand-new or lab/test tenants.
