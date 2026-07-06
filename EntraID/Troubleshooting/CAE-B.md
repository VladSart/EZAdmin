# Continuous Access Evaluation (CAE) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---

## What this is

**Continuous Access Evaluation (CAE)** lets Entra ID and CAE-enabled resource providers (Exchange Online, SharePoint Online, Teams, Microsoft Graph) revoke access **within minutes** instead of waiting for a token's normal 60-90 minute lifetime to expire, when a critical event happens — user disabled, password changed, high-risk sign-in detected, or a Conditional Access network location change. It also enables **strict location enforcement**, blocking token use from outside a named network location in near-real time.

The common ticket pattern: a user reports being **unexpectedly signed out**, or blocked mid-session with a "your session was ended" / "AADSTS...continuous access evaluation" style error, often right after an admin action (password reset, account disable, group removal) or a network change (VPN connect/disconnect, moving between office and home Wi-Fi).

---

## Triage

Run these first:

```
1. Entra admin center > Users > [affected user] > Sign-in logs
   → Filter to the time of the reported sign-out; look for "Continuous access evaluation" or
     "Session control" entries with a Status of Failure/Interrupted

2. Entra admin center > Users > [affected user] > Sign-in logs > click the failed sign-in
   → Check "Conditional Access" tab for a policy showing "Report-only" vs "On" with
     Session controls > "Sign-in frequency" or CAE-related enforcement

3. Ask the user: did anything change right before the sign-out?
   (password reset, MFA re-registration, VPN connect/disconnect, moved networks, admin removed from a group)

4. Check the user's recent Entra directory events
   Entra admin center > Identity > Monitoring & health > Audit logs
   → Filter by target user, look for password reset, account disable/enable, or group membership changes
     in the 5-15 minutes before the reported issue

5. Confirm whether this is affecting one user or many
   → If many users at once: check for a recent Conditional Access policy change or a broad
     risk-based Identity Protection event (mass token revocation), not a per-user CAE trigger
```

| If | Then |
|----|------|
| Sign-in log shows CAE-triggered revocation right after a password reset/account disable/MFA reset | Expected behavior — CAE did its job → **Fix 1** (explain + re-auth) |
| User moved networks (e.g. disconnected from corporate VPN) and a CA policy enforces a named location | Strict location enforcement triggered → **Fix 2** |
| Multiple users affected simultaneously, no individual account changes | Broad CA policy change or Identity Protection risk event → **Fix 3** |
| Error references `AADSTS window`/token replay or an app that doesn't support CAE cleanly | App/client compatibility gap, not a real security event → **Fix 4** |
| No CAE-related entries in sign-in logs at all despite the symptom | Likely NOT a CAE issue — check `PRT-Issues-B.md` or standard token expiry first |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Entra ID tenant
        │
        ▼
CAE-enabled resource provider (Exchange Online, SharePoint Online,
Teams, Microsoft Graph — CAE support varies by workload and client)
        │
        ▼
Client/app must support Continuous Access Evaluation
   (modern Office apps, browser sessions via Entra — legacy/basic auth clients CANNOT honor CAE)
        │
        ▼
Critical event stream feeding CAE:
   ├── User account disabled/deleted
   ├── Password changed/reset
   ├── MFA re-registered
   ├── Admin revokes all refresh tokens
   ├── Identity Protection: high user/sign-in risk detected
   └── (if configured) Conditional Access strict location enforcement —
        network location change detected mid-session
        │
        ▼
Resource provider receives near-real-time signal (not waiting for token expiry)
        │
        ▼
Access token revoked / re-evaluation forced within ~minutes
        │
        ▼
Client is prompted to re-authenticate against current CA policy state
```

**Key fact:** CAE is enabled by default at the tenant level for supported workloads — most orgs did not explicitly turn this on. If you didn't know CAE was active, that's normal; it doesn't require an admin opt-in for the baseline critical-event revocation, only for **strict location enforcement**, which does require an explicit Conditional Access configuration choice.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm a CAE event actually occurred**
```
Entra admin center > Users > [user] > Sign-in logs
→ Look for entries where "Client app" is a modern app, Status is Interrupted/Failure,
  and the Conditional Access tab shows session control enforcement
```
Expected: A clear timestamp correlating with the user's reported symptom.
Bad/inconclusive: No matching entry — reconsider whether this is actually a CAE issue.

**Step 2 — Correlate against directory audit events**
```
Entra admin center > Identity > Monitoring & health > Audit logs
→ Filter: Target = affected user, Date range = ±15 minutes of the sign-in log event
```
Look for: password reset, account disable, MFA method changes, group removal (if group feeds a CA policy).

**Step 3 — Check for strict location enforcement**
```
Entra admin center > Protection > Conditional Access > [relevant policy]
→ Session > Conditional Access App Control OR check for "Continuous access evaluation" 
  strict enforcement mode under Session controls
```
If enabled: any network location change (VPN toggling, switching from office to mobile hotspot) can trigger a near-instant re-evaluation and sign-out if the new location fails a Named Location check.

**Step 4 — Check for a tenant-wide risk event (multi-user impact)**
```
Entra admin center > Protection > Identity Protection > Risky sign-ins / Risky users
→ Check for a spike in risk detections around the same time window
```
A mass token revocation event (e.g., a leaked credentials alert, or an admin bulk-action) will show here, not as isolated per-user CAE triggers.

---

## Common Fix Paths

<details><summary>Fix 1 — Expected revocation after a legitimate admin action</summary>

**When to use:** Sign-in logs confirm CAE revoked the session within minutes of a password reset, account disable/enable cycle, or MFA re-registration performed by IT.

```
1. Confirm with the user that the admin action (password reset, etc.) was expected
2. Have the user simply sign in again — this is CAE working as designed, not a bug
3. If the user is stuck in a re-auth loop, clear cached credentials in the client:
   - Outlook/Office: File > Account > Sign out, then sign back in
   - Browser: clear the site's Entra session cookie or use an InPrivate/Incognito window to confirm clean sign-in works
4. No policy change needed — document as expected behavior in the ticket
```

**Rollback:** N/A — this is intended security behavior, not a fault to roll back.

</details>

<details><summary>Fix 2 — Strict location enforcement triggering on legitimate network changes</summary>

**When to use:** Users on laptops that roam between trusted (office/VPN) and untrusted (home, mobile hotspot) networks are getting signed out mid-session when the underlying Conditional Access policy has strict CAE location enforcement enabled.

```
1. Entra admin center > Protection > Conditional Access > Named locations
   → Confirm the affected user's typical remote-work networks (home broadband, etc.)
     are NOT expected to be in the trusted/named location list — if strict enforcement
     is on, this is by design for untrusted networks

2. If this is causing excessive false-positive sign-outs for legitimate remote workers:
   - Review whether strict location enforcement is the right session control for this
     policy's target population, or whether it should be scoped to only the highest-risk
     apps/groups
   - Consider whether the affected users need a named location added
     (e.g., a known-good branch office IP range) rather than disabling enforcement entirely

3. To adjust scope (requires Conditional Access Administrator):
   Entra admin center > Protection > Conditional Access > [policy] > Session >
   review "Customize continuous access evaluation" settings
```

⚠️ **Do not disable strict location enforcement tenant-wide as a quick fix** — it was likely enabled deliberately for a compliance or security reason. Scope the fix to the specific population/app experiencing false positives, and involve whoever owns the CA policy design before changing enforcement mode.

**Rollback:** If a Named Location was added in error, remove it from Conditional Access > Named locations and re-test.

</details>

<details><summary>Fix 3 — Broad multi-user impact from a policy change or risk event</summary>

**When to use:** Many users report sign-outs at the same time, with no individual account changes correlating.

```
1. Check Conditional Access change history:
   Entra admin center > Protection > Conditional Access > [policy] > check "Modified date"
   for any policies with session controls, compared against when symptoms started

2. Check Identity Protection for a bulk risk event:
   Entra admin center > Protection > Identity Protection > Risky sign-ins
   → Sort by detection time, look for a spike affecting multiple accounts

3. If a policy change is the cause:
   - Coordinate with whoever made the change before reverting —
     it may have been an intentional security tightening
   - If confirmed unintended, revert the specific session control setting that changed

4. If a risk-based mass revocation is the cause:
   - This is Identity Protection doing its job in response to a detected threat
     (e.g., leaked credentials feed, impossible travel pattern across many accounts)
   - Do NOT mass-dismiss risk without investigating each flagged account individually
   - Escalate to whoever owns Identity Protection policy for this tenant
```

**Rollback:** Revert only the specific Conditional Access session control setting identified as the unintended change — do not disable CA policies wholesale.

</details>

<details><summary>Fix 4 — App/client compatibility gap (not a real security event)</summary>

**When to use:** The error pattern involves an older or third-party client that doesn't cleanly support CAE's re-authentication challenge, resulting in a generic failure instead of a smooth re-auth prompt.

```
1. Identify the client app from the sign-in log ("Client app" / "App used" columns)
2. Check whether it's a legacy authentication client (basic auth, older desktop client
   version, or a third-party app using an outdated auth library)
3. Legacy/basic auth clients cannot honor CAE at all — if legacy auth is still permitted
   for this user/app, that's a separate finding worth flagging (legacy auth is also a
   Conditional Access blind spot generally)
4. Recommend the user update to a current, CAE-aware client version
   (current Office apps, Edge/Chrome with modern auth, current Outlook mobile)
```

**Rollback:** N/A.

</details>

---

## Escalation Evidence

```
TICKET: Continuous Access Evaluation (CAE) Session Interruption
========================================================
Date/Time:                     _______________
Raised by:                     _______________
Affected user(s):               _______________
Single user or multiple?:       [ ] Single  [ ] Multiple (list count: ___)

Sign-in log timestamp of interruption:  _______________
Client app shown in sign-in log:        _______________
Conditional Access policy referenced (if any): _______________

Correlated directory audit event (if any):
  [ ] Password reset   [ ] Account disable/enable   [ ] MFA re-registration
  [ ] Group membership change   [ ] None found

Network location change reported by user?:  [ ] Yes  [ ] No
  If yes, describe: _______________

Identity Protection risk event around this time?:  _______________

Steps taken:
[ ] Reviewed sign-in logs for CAE-related entries
[ ] Correlated against audit logs
[ ] Checked for strict location enforcement in relevant CA policy
[ ] Checked for tenant-wide risk event / policy change
[ ] Confirmed client app CAE support

Result:
_______________________________________________
========================================================
```

---

## 🎓 Learning Pointers

- **CAE is on by default for supported workloads — most admins never explicitly enabled it, which is exactly why the first CAE-triggered sign-out often gets misreported as a bug.** Understanding that baseline critical-event revocation (password change, account disable, high risk) requires no configuration is the fastest way to correctly triage this class of ticket. [MS Docs: Continuous Access Evaluation](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-continuous-access-evaluation)

- **Strict location enforcement is the CAE feature that actually requires deliberate configuration — and it's the one most likely to generate legitimate-feeling false positives for remote/hybrid workers.** If you're seeing a pattern of sign-outs correlated with network changes rather than account changes, this is where to look first. [MS Docs: Continuous Access Evaluation strict enforcement](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-continuous-access-evaluation-strict-enforcement)

- **Not every client honors CAE the same way.** Legacy authentication and some third-party/older clients can't process the mid-session re-auth challenge cleanly, producing confusing generic errors instead of a smooth sign-in prompt. If legacy auth is still allowed anywhere in the tenant, that's worth flagging as a separate hardening opportunity beyond just this ticket.

- **CAE and Conditional Access sign-in frequency settings interact — don't confuse the two.** Sign-in frequency is a scheduled re-auth cadence you configure explicitly; CAE is event-driven and can trigger outside that schedule. A user can be well within their configured sign-in frequency window and still get a CAE-triggered re-auth prompt because of an account-level event.

- **When investigating multi-user impact, always check Identity Protection risk detections before assuming a Conditional Access misconfiguration.** A mass CAE-driven sign-out pattern across many accounts is a classic signature of Identity Protection responding to a leaked-credentials feed or a detected attack pattern — treat it as a potential security incident to investigate, not just a policy bug to revert.
