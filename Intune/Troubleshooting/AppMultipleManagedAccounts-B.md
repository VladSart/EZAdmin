# Intune App Protection — Multiple Managed Accounts (MMA) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

> **Context:** Multiple Managed Accounts (MMA) lets a single app hold more than one Intune-MAM-managed identity at once, each governed by its own app protection policy — useful for consultants, M&A transitions, and shared-mailbox users. As of this writing it's rolling out gradually and only two apps support it: **Microsoft Teams for iOS/iPadOS (v8.10.0+)** and **Microsoft Outlook for iOS/iPadOS (v5.2626.0+)**; Outlook's MMA support (Intune Service Release week of 2026-07-13) is the newest addition. Source: [Multiple managed accounts for app protection policies](https://learn.microsoft.com/en-us/intune/app-management/protection/multiple-managed-accounts) (ms.date 2026-05-15, updated 2026-07-14).

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Run against the affected user/device via Microsoft Graph (`Microsoft.Graph.Authentication`, already connected):

```powershell
$upn = "<user@contoso.com>"

# 1. Find the device and confirm it's iOS/iPadOS (MMA is iOS/iPadOS-only as of this writing)
$device = (Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=userPrincipalName eq '$upn'").value |
    Where-Object { $_.operatingSystem -eq 'iOS' }
$device | Select-Object deviceName, operatingSystem, osVersion, managementAgent

# 2. Check the on-device Outlook/Teams version against the MMA floor
(Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($device.id)/detectedApps").value |
    Where-Object { $_.displayName -match 'Outlook|Teams' } |
    Select-Object displayName, version

# 3. Check for an app configuration policy carrying the IntuneMAMAllowedAccountsOnly key
(Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/beta/deviceAppManagement/targetedManagedAppConfigurations?`$expand=apps").value |
    ForEach-Object {
        $_.customSettings | Where-Object { $_.name -eq 'IntuneMAMAllowedAccountsOnly' } |
            Select-Object @{n='PolicyName';e={ $_.displayName }}, name, value
    }
```

| Observation | Meaning | Do |
|---|---|---|
| App version below the MMA floor (Outlook < 5.2626.0, Teams < 8.10.0) | Device hasn't picked up the MMA-capable build yet | Go to [Fix 1](#fix-1) |
| `IntuneMAMAllowedAccountsOnly` = `true` in an app config policy scoped to this user/app | Admin-side setting is forcing single-managed-account mode — expected, not a bug | Go to [Fix 2](#fix-2) |
| User reports copy/paste, screenshot, or screen capture blocked in Outlook's combined inbox even though their account's own policy allows it | Outlook is a **mixed view** app — full lockdown is enforced by design whenever 2+ accounts (managed or a managed+unmanaged mix) share one view | Go to [Fix 3](#fix-3) — not a bug |
| User trying to add a second account that is **also MDM-enrolled** | Only one MDM+MAM account is supported per device; additional accounts must be MAM-only | Go to [Fix 4](#fix-4) |
| App isn't Teams or Outlook, or is a wrapped/LOB app | MMA requires native Intune SDK integration in a supported app — not configurable, not a policy gap | Go to [Fix 5](#fix-5) |
| Everything above checks out and the behavior still looks wrong | Feature is "rolling out gradually" per Microsoft — may not be live in this tenant/app-store ring yet | Escalate — see [Escalation Evidence](#escalation-evidence) |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
App is Intune-SDK-integrated AND on the MMA-supported list
  (Teams iOS/iPadOS v8.10.0+, Outlook iOS/iPadOS v5.2626.0+ — wrapped apps excluded)
    └─ User holds 2+ MAM-eligible managed identities
          (max ONE may be MDM+MAM; every additional account must be MAM-only —
           multiple MDM-enrolled accounts on one device is unsupported)
              └─ No app-config policy sets IntuneMAMAllowedAccountsOnly = true for this app/user
                    (that key forces single-managed-account mode, silently defeating MMA)
                        └─ App protection policy evaluates INDEPENDENTLY per account
                              └─ Rendering model decides enforcement surface:
                                    ├─ Segmented view (Teams) — one account visible at a time,
                                    │   PIN/conditional-launch/data-transfer follow the ACTIVE account
                                    └─ Mixed view (Outlook combined inbox/calendar) — ALWAYS
                                        full lockdown regardless of any individual account's
                                        policy (copy/paste, screen capture, screenshots all blocked)
                                            └─ Mobile Threat Defense threat signal is evaluated at the
                                               DEVICE level (Entra device ID), not per account —
                                               same-tenant accounts share one device record's
                                               threat level; cross-tenant accounts get separate ones
```
</details>

---
## Diagnosis & Validation Flow

1. **Confirm the app and platform are in scope.** MMA is iOS/iPadOS-only, Teams and Outlook-only, as of this writing. Anything else (Android, other apps, wrapped LOB apps) is out of scope — no fix exists, only a feature-gap explanation.
   ```powershell
   # Expected: displayName in ('Microsoft Teams','Microsoft Outlook'), platform 'iOS'
   ```

2. **Confirm the installed app version meets the floor.** Use the Triage step 2 query. Expected good output: `version` ≥ `5.2626.0` (Outlook) or `8.10.0` (Teams). Bad output: an older version — the App Store/Company Portal update hasn't landed yet.

3. **Confirm the account mix is supported.** Ask the user (or check Entra sign-in logs for the app) how many accounts are signed in and whether more than one is MDM-enrolled. Expected good: 1 MDM+MAM account, N MAM-only accounts. Bad: 2+ MDM-enrolled accounts — unsupported configuration, not fixable via policy.

4. **Check for the `IntuneMAMAllowedAccountsOnly` override.** Use Triage step 3. Expected good (MMA should work): no policy sets this key, or it's explicitly `false`. Bad: `true` on a policy scoped to this user/app — this is an admin-side kill switch for MMA on iOS.

5. **If behavior looks like over-restriction, check the view type.** Segmented-view apps (Teams) enforce the active account's own policy. Mixed-view apps (Outlook) enforce full lockdown across the board the moment 2+ accounts (or one managed + one unmanaged) share a view — this is documented, expected behavior, not a policy misconfiguration.

---
## Common Fix Paths

<details><summary>Fix 1 — App version below the MMA floor</summary>

Confirm via Company Portal / App Store that an update is available and not blocked by an app deployment assignment. If Outlook/Teams is deployed via Intune as a required app, check the app's assignment and any version-pinning configuration; MMA support ships with the app binary, not a separate Intune policy, so there's nothing to toggle in Intune once the correct version installs.

```powershell
# Confirm the deployed app assignment isn't pinning an old version
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps?`$filter=displayName eq 'Microsoft Outlook'"
```
No rollback needed — this is a forward-only app update.
</details>

<details><summary>Fix 2 — IntuneMAMAllowedAccountsOnly is forcing single-account mode</summary>

This key is a documented, admin-intentional restriction — confirm with the policy owner before changing it; it may be deliberately set for compliance reasons (e.g., preventing personal-tenant account mixing).

```powershell
$policyId = "<targetedManagedAppConfiguration-policy-id>"
$policy = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/targetedManagedAppConfigurations/$policyId"
$newSettings = $policy.customSettings | Where-Object { $_.name -ne 'IntuneMAMAllowedAccountsOnly' }
Invoke-MgGraphRequest -Method PATCH `
    -Uri "https://graph.microsoft.com/beta/deviceAppManagement/targetedManagedAppConfigurations/$policyId" `
    -Body (@{ customSettings = $newSettings } | ConvertTo-Json -Depth 5)
```
**Rollback:** re-add the `{ name = 'IntuneMAMAllowedAccountsOnly'; value = 'true' }` entry to `customSettings` and PATCH again.
</details>

<details><summary>Fix 3 — Mixed-view lockdown is expected behavior, not a bug</summary>

No fix — this is by design. Explain to the user: Outlook's combined/mixed inbox view enforces the most restrictive controls across every account visible in that view, even if a single account's own policy would allow copy/paste or screenshots. Options: (a) accept the restriction while in the combined view, or (b) if the app/version supports it, switch to a per-account segmented view where each account's own policy applies.
</details>

<details><summary>Fix 4 — Second account is also trying to MDM-enroll</summary>

Only one account per device may be MDM+MAM; every additional managed account must sign in as MAM-only (no device enrollment). Direct the user to add the second account as a regular (non-enrolling) work account sign-in in the app, not through the Company Portal enrollment flow. If the app forces enrollment for any additional account, that's an app-side limitation for that specific app version — verify against the supported-apps table in [Learning Pointers](#-learning-pointers).
</details>

<details><summary>Fix 5 — App isn't MMA-eligible</summary>

No fix in Intune. Non-participating apps (anything other than Teams/Outlook iOS at the required versions, and all wrapped/LOB apps) enforce the pre-MMA single-managed-account-per-publisher model: adding a second managed account will either fail or prompt the user to remove the existing one. Set expectations rather than troubleshooting further; check Microsoft's supported-apps list periodically as "support for additional apps and platforms is coming soon" per Microsoft's own documentation.
</details>

---
## Escalation Evidence

```
MMA Escalation — Multiple Managed Accounts

User UPN: __________
Device ID (Entra): __________
App + version (from Triage step 2): __________
Number of managed accounts attempted: __________
Any account MDM-enrolled? Y/N: __________
IntuneMAMAllowedAccountsOnly present/value (Triage step 3): __________
View type observed (segmented / mixed) and exact restricted action: __________
Expected vs actual behavior: __________
Screenshot/recording attached: Y/N
```

---
## 🎓 Learning Pointers
- MMA is a **capability**, not a policy setting — it only works in apps that have completed the integration, and Microsoft explicitly does not offer a first-class "enable/disable MMA" toggle. Read the currently-supported-apps table before assuming a bug: [Multiple managed accounts for app protection policies](https://learn.microsoft.com/en-us/intune/app-management/protection/multiple-managed-accounts).
- The mixed-view full-lockdown behavior is the single biggest source of "policy suddenly got stricter" tickets from this feature — it fires even when only one of the accounts in the shared view is managed and the other is a personal/unmanaged account.
- Mobile Threat Defense threat level is a **device-level** signal (Entra device ID), not per-account — don't expect an MTD provider to isolate risk to a single managed identity when multiple accounts from the same tenant share a device.
- `IntuneMAMAllowedAccountsOnly` is an iOS app-configuration key (not an app protection policy setting) — check **App configuration policies**, not app protection policies, when this is suspected.
- Cross-reference [Managed-Apps-B.md](Managed-Apps-B.md) for general app protection policy delivery issues that are unrelated to the multi-account behavior covered here.
