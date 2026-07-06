# Apple Business Manager Token Renewal — Hotfix Runbook (Mode B: Ops)
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

## ⚠️ Not the same as MDM certificate renewal

This runbook covers the **Apple Business Manager (ABM) / Apple School Manager (ASM) server token** used by Intune to sync device inventory (ADE) and VPP app licenses. This is a **completely separate credential** from the APNs push certificate (see `MDM-Certificate-Renewal-B.md`). Confusing the two wastes escalation time — check both, but they fail differently and are fixed in different places.

| | ABM/ASM Server Token | APNs Push Certificate |
|---|---|---|
| Renewed where | Intune > Devices > Enrollment > Apple > Enrollment Program Tokens | Intune > Tenant Administration > Connectors and tokens |
| Renewed how | Download new `.p7m` token from business.apple.com, upload to Intune | Renew CSR flow, re-sign at identity.apple.com/pushcert |
| Expiry | 1 year (server token) | 1 year (push cert) |
| Symptom of expiry | Devices stop appearing in Intune for ADE; VPP app assignments/licenses fail | Devices already enrolled stop checking in / receiving MDM commands |
| Impact scope | Only NEW device sync + VPP licensing | ALL enrolled device management (existing devices) |

---

## Triage

Run these first (from the Intune admin center, not the device — this is a tenant-side token, not device-side):

```
1. Intune portal > Devices > Enrollment > Apple > Enrollment Program Tokens
   → Check "Token expires" date for the affected token

2. Intune portal > Devices > Enrollment > Apple > Enrollment Program Tokens > [token] > Devices
   → Confirm whether device count/sync is stale (compare against Apple Business Manager device count)

3. Apps > Policies > App licenses (VPP)
   → Check if VPP token status shows "Active" or "Invalid"

4. Intune portal > Troubleshooting + support > select an affected device
   → Check "Last Intune check-in" — if fresh, existing devices are fine (rules out APNs cert issue)

5. business.apple.com > Preferences > MDM Server assignment
   → Confirm the token being renewed still shows the correct MDM server name (Intune)
```

| If | Then |
|----|------|
| Token "Expires" date is within 30 days or already past | Token expiring/expired → **Fix 1** |
| Existing devices check in fine, but new devices never appear for ADE | ABM token is the issue, not APNs → **Fix 1** |
| VPP app assignments fail with "license unavailable" but device management is fine | VPP-specific token issue → **Fix 2** |
| Both new device sync AND existing device management are broken | Check APNs cert too — likely both expired, or tenant-wide MDM issue → also check `MDM-Certificate-Renewal-B.md` |
| Sync shows errors like "token invalid" or "unauthorized" | Token was revoked, deleted from ABM, or wrong token uploaded → **Fix 3** |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Apple Business Manager (business.apple.com) — organization account
        │
MDM Server registered in ABM (e.g. "Contoso Intune")
        │  generates a Server Token (.p7m file), valid 1 year
        ▼
Server Token uploaded to Intune
   (Devices > Enrollment > Apple > Enrollment Program Tokens)
        │
Token used for TWO independent purposes:
        │
        ├──▶ Device Sync (ADE/DEP)
        │        │  polls ABM every ~15 min for devices assigned to this MDM server
        │        ▼
        │    New devices appear in Intune for enrollment profile assignment
        │
        └──▶ VPP (Volume Purchase Program) App Licensing
                 │  separate VPP token, same ABM portal, can be same or different token
                 ▼
             App license assignment to users/devices works
```

**Key fact:** device sync and VPP licensing can use the **same** token or **separate** tokens depending on how ABM was originally set up. Check both token entries in Intune if only one function is broken.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm which token is expiring/expired**
```
Intune portal > Devices > Enrollment > Apple > Enrollment Program Tokens
```
Note the exact token name, the Apple ID it's tied to, and the expiry date. Screenshot this before doing anything else — you'll need it for the evidence pack.

**Step 2 — Confirm impact scope**
- New device ADE sync broken only → device inventory/enrollment token issue
- VPP app assignment broken only → VPP token issue (may be a separate token entry)
- Both → likely the same underlying token serving both functions

**Step 3 — Confirm the Apple ID used originally**
The token can only be renewed by generating a new one in **business.apple.com** while signed in with the account that has access to that MDM server entry — this does NOT have to be the exact same Apple ID that created it originally (unlike the APNs push cert), but it must be an ABM admin/user with access to **MDM Server Assignment**.

```
business.apple.com > Preferences > MDM Server Assignment > [server name] > Download Token
```

**Step 4 — Confirm no devices were silently dropped from sync**
```
Compare device count in business.apple.com (Devices, filtered by MDM server assignment)
against Intune (Devices > Enrollment > Apple > Enrollment Program Tokens > [token] > Devices)
```
A gap here confirms the token has already stopped syncing correctly.

---

## Common Fix Paths

<details><summary>Fix 1 — Renew the expiring/expired ABM server token</summary>

**When to use:** Token shows expired or expiring soon in Intune; new device sync (ADE) is stale or stopped.

**Step 1 — Download a new token from Apple Business Manager:**
1. Sign in to [business.apple.com](https://business.apple.com) as an Administrator or the account with MDM Server Assignment access
2. Go to **Preferences** > **MDM Server Assignment**
3. Select the MDM server entry that matches your Intune tenant
4. Click **Download Token** (this generates a new `.p7m` server token file — it does not remove existing device assignments)

**Step 2 — Upload the new token to Intune:**
1. Intune portal > **Devices** > **Enrollment** > **Apple** > **Enrollment Program Tokens**
2. Select the existing (expiring) token entry
3. Click **Renew Token** (NOT "Add" — using Renew preserves the token's existing device assignments and enrollment profile links)
4. Upload the new `.p7m` file downloaded in Step 1
5. Confirm the new expiry date shows ~1 year out

**Step 3 — Force an immediate sync:**
```
Intune portal > Devices > Enrollment > Apple > Enrollment Program Tokens > [token] > Sync
```

**Step 4 — Verify:**
- Wait 15-30 minutes
- Confirm new/pending devices from ABM now appear in Intune
- Spot-check one enrolled device's Intune check-in timestamp to confirm nothing else broke

⚠️ **Do NOT click "Add" to create a brand-new token entry instead of renewing** — this creates a duplicate token that is not linked to existing enrollment profile assignments, and devices already assigned under the old token will need to be reassigned. Always use **Renew** on the existing entry.

**Rollback:** N/A — token renewal doesn't affect already-enrolled devices; it only restores forward sync capability.

</details>

<details><summary>Fix 2 — VPP token expired/invalid (app licensing broken)</summary>

**When to use:** Device management/enrollment is fine, but VPP app assignments show "license unavailable" or the VPP token shows "Invalid" in Intune.

```
Intune portal > Apps > Policies > App licenses (or Tenant administration > Connectors and tokens > Apple VPP Tokens)
```

1. Identify the affected VPP token and its expiry
2. Sign in to business.apple.com > Preferences > Payments and Billing / MDM Server Assignment (VPP tokens are managed alongside device tokens in modern ABM)
3. Download a new/renewed token
4. In Intune, select the existing VPP token entry and choose **Renew** (not Add)
5. Upload the new token file
6. Verify: Intune > Apps > [an app assigned via VPP] > Device install status — should resume progressing

**Rollback:** N/A.

</details>

<details><summary>Fix 3 — Token invalid/revoked (wrong file uploaded, or token deleted in ABM)</summary>

**When to use:** Sync shows explicit "token invalid" or "unauthorized" errors, not just an expiry warning.

```
1. Confirm in business.apple.com that the MDM Server Assignment entry still exists
   (Preferences > MDM Server Assignment — if the server entry itself was deleted, this is a bigger problem)

2. If the server entry exists but the token was regenerated by someone else recently:
   Download Token again (this invalidates any previously downloaded but not-yet-uploaded copies)

3. Re-upload to Intune via Renew Token (not Add) as in Fix 1

4. If the MDM Server Assignment entry itself was deleted from ABM:
   - This is a significant incident — all ADE device assignments tied to that server entry are now orphaned
   - Escalate to a senior admin; recreating the server entry requires re-establishing device assignment,
     which may require Apple support involvement for bulk reassignment
```

**Rollback:** N/A — this is a recovery path, not a reversible change.

</details>

---

## Escalation Evidence

```
TICKET: Apple Business Manager Token Renewal / ADE Sync Issue
========================================================
Date/Time:                 _______________
Raised by:                 _______________
Tenant:                    _______________
Affected function:         [ ] Device sync (ADE)  [ ] VPP licensing  [ ] Both

Token name (Intune):       _______________
Token expiry (Intune):     _______________
ABM server entry name:     _______________
Apple ID used for renewal: _______________ (must have MDM Server Assignment access)

Device count comparison:
  Apple Business Manager (assigned to this MDM server): _______________
  Intune (Enrollment Program Tokens > Devices):          _______________
  Gap:                                                    _______________

Existing device check-ins normal? (rules out APNs cert issue): _______________

Steps taken:
[ ] Downloaded new token from business.apple.com
[ ] Used "Renew Token" (not "Add") in Intune
[ ] Forced manual sync
[ ] Verified new devices appear post-sync
[ ] Verified VPP app assignments resumed (if applicable)

Result:
_______________________________________________
========================================================
```

---

## 🎓 Learning Pointers

- **ABM/ASM server token and APNs push certificate are two different credentials that both expire annually and both cause "MDM is broken" symptoms — but they fail in opposite directions.** APNs cert expiry breaks management of **already-enrolled** devices. ABM token expiry breaks sync of **new** devices and VPP licensing while existing devices keep working normally. Always check both, and always confirm which one is actually the problem before escalating. [MS Docs: Apple MDM push certificate](https://learn.microsoft.com/en-us/mem/intune/enrollment/apple-mdm-push-certificate-get) · [MS Docs: Configure ADE](https://learn.microsoft.com/en-us/mem/intune/enrollment/device-enrollment-program-enroll-ios)

- **Always use "Renew Token," never "Add," when replacing an ABM/ASM token in Intune.** "Add" creates an entirely new, unlinked token entry — existing device-to-enrollment-profile assignments under the old token don't carry over automatically, creating a much bigger cleanup problem than the original expiry.

- **The ABM token does not require the same Apple ID that created it, unlike the APNs push certificate.** Any ABM admin/user with "MDM Server Assignment" permission can download a renewal token for an existing server entry. This makes ABM token renewal much more forgiving of admin turnover than APNs cert renewal — but document who has ABM admin access regardless, since losing all ABM admins entirely locks you out of the portal.

- **Set a calendar reminder at 60 days before ABM/ASM token expiry, separate from any APNs cert reminder** — Intune's UI does show expiry dates for both, but there's no native proactive alert for either. Treat them as two separate recurring maintenance tasks, not one.

- **A device count mismatch between Apple Business Manager and Intune's Enrollment Program Tokens view is the earliest warning sign of a sync problem** — often visible days before the token's hard expiry date, since sync can start degrading due to throttling or partial failures before the token is fully expired. Build this comparison into routine Intune health checks rather than only reacting to expiry-date warnings.
