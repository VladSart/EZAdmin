# Intune App Protection — Multiple Managed Accounts (MMA) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---
## Skim Index (with jump links)
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
- Applies to **Intune mobile application management (MAM)** app protection policies on **iOS/iPadOS only**, for apps that have completed Microsoft's Multiple Managed Accounts (MMA) integration. As of this writing that list is exactly two apps: **Microsoft Teams (v8.10.0+)** and **Microsoft Outlook (v5.2626.0+)**; Microsoft states "support for additional apps and platforms is coming soon" with no committed date.
- MMA is explicitly **not a standalone admin policy setting** — it is an app-side capability. There is no Intune blade or app protection policy checkbox labeled "enable multiple managed accounts." Admin influence over MMA behavior is entirely indirect, via app configuration keys and app protection policy assignment per account.
- Out of scope: Android (no MMA support as of this writing), wrapped/LOB apps (Intune SDK integration is required — the App Wrapping Tool does not provide MMA), and PowerApps ("out of scope" per Microsoft's own documentation despite technically being an Intune-SDK app).
- Feature is explicitly marked as **rolling out gradually and may not yet be available in your tenant** — absence of expected behavior is not automatically a misconfiguration.
- Primary source throughout: [Multiple managed accounts for app protection policies](https://learn.microsoft.com/en-us/intune/app-management/protection/multiple-managed-accounts) (ms.date 2026-05-15, updated_at 2026-07-14), cross-referenced against the Outlook MMA entry in [What's new in Microsoft Intune](https://learn.microsoft.com/en-us/intune/whats-new/) (week of 2026-07-13, service release timing).

---
## How It Works
<details><summary>Full architecture</summary>

**Account model.** Before MMA, an Intune-SDK-integrated app enforced one managed account per app publisher on a device — attempting to add a second managed account would either fail outright or prompt removal of the first. MMA relaxes this at the app layer: a supported app can hold multiple simultaneously-signed-in managed identities, each independently evaluated against **its own** app protection policy, as assigned by whichever tenant/admin owns that account.

Account composition rules are fixed and not admin-configurable: at most **one** account on a device may be both MDM-enrolled and MAM-managed (MDM+MAM); every additional managed account must be **MAM-only** (no device enrollment). Multiple MDM-enrolled accounts on a single device is not supported under any configuration — this is a device-enrollment-model constraint, not an app-protection-policy constraint, so no app protection policy fix exists for it.

**Rendering models — the core operational distinction.** Microsoft defines two ways an MMA-enabled app can present multiple accounts, and the distinction drives almost every support ticket this feature generates:

- **Segmented view** (Teams is Microsoft's example): the UI shows exactly one account's data at a time; the user explicitly switches between accounts. Enforcement — PIN prompts, conditional launch, data transfer (copy/paste, "Open in", save-as) restrictions — applies to whichever account is currently active. Each account's policy is fully independent in this model; there's no cross-account bleed.

- **Mixed view** (Outlook is Microsoft's example — a combined inbox or calendar spanning multiple accounts): the UI shows data from multiple accounts in one shared view. Policy *evaluation* still happens per account independently at app-open/conditional-launch time, but policy *enforcement* for the shared view itself is hard-coded to the most restrictive behavior available, **regardless of what any individual account's own policy actually permits**. Microsoft's documentation is explicit: in a mixed view, cut/copy/paste is fully blocked (including within the app's own view), screen capture and screenshots are blocked, and other data-protection controls default to maximum restriction. Critically, this also applies when a single **managed** account shares a mixed view with an **unmanaged** personal account — the mere presence of a second, unmanaged identity in the same view triggers full lockdown for the managed one.

This mixed-view behavior is not a bug report waiting to happen — it is Microsoft's stated design, and the single most common source of "my app protection policy suddenly got more restrictive" tickets once MMA rolls out to a tenant's Outlook users.

**The admin's only lever: `IntuneMAMAllowedAccountsOnly`.** Microsoft does not provide a first-class MMA on/off switch. The one documented indirect control is the iOS app-configuration key `IntuneMAMAllowedAccountsOnly`. This key was not designed for MMA specifically, but setting it restricts the app to a single managed account on managed devices — its side effect is to disable MMA behavior even in an otherwise MMA-capable app. This is delivered the same way any other app configuration key is delivered to a managed app: via a **targeted app configuration policy** (`deviceAppManagement/targetedManagedAppConfigurations` in Graph), not via the app protection policy object itself. Admins and support engineers who only check app protection policies (not app configuration policies) when troubleshooting MMA will miss this setting entirely.

**Mobile Threat Defense (MTD) interaction.** MTD device threat level is evaluated at the **device** level, keyed to the Entra device record (device ID) — not per managed account. Practical effect: if two managed accounts from the *same tenant* share a device and both use the same MTD provider, they share one device record, and a threat signal reported by one account's MTD app can affect app-protection enforcement for the other account too, even though each account's app protection policy is still evaluated independently for the compliance/conditional-launch decision itself. If the two accounts are from *different tenants*, each tenant gets its own separate device record, and MTD threat reporting is correspondingly separate. This is a common source of confusion in MSP multi-tenant contexts specifically, since an MSP technician's own device may hold managed accounts from several client tenants simultaneously.

</details>

---
## Dependency Stack
```
Device enrollment / sign-in layer
  Entra ID device record (one device ID) ── shared MTD device-threat-level anchor
    ↑
App layer (Intune SDK integration required — not available to wrapped/LOB apps)
    ↑
MMA-capable app + version floor
  (Teams iOS/iPadOS 8.10.0+, Outlook iOS/iPadOS 5.2626.0+)
    ↑
Account composition constraint
  (max 1 MDM+MAM account; N MAM-only accounts; no multi-MDM)
    ↑
App configuration policy layer
  (IntuneMAMAllowedAccountsOnly key — the only admin-facing MMA lever, and it's a DISABLE switch)
    ↑
App protection policy layer
  (evaluated INDEPENDENTLY per account — PIN, conditional launch, data transfer)
    ↑
Rendering model (app-defined, not admin-configurable)
  ├─ Segmented view → per-active-account enforcement
  └─ Mixed view → hard-coded full lockdown across the shared view, overriding per-account policy
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| User can't add a second managed account to Outlook/Teams at all | App version below MMA floor, or `IntuneMAMAllowedAccountsOnly` set | App version + app config policy `customSettings` |
| Second account adds fine but the first one gets signed out | App/version isn't actually MMA-integrated for that account type, or app fell back to legacy single-account behavior | Confirm both apps are on the supported-list versions; confirm neither account is a second MDM-enrolled account |
| Copy/paste or screenshots blocked in Outlook combined inbox despite a permissive per-account policy | Mixed-view full-lockdown by design | Ask whether the user is in the combined/mixed view vs. a single-account view |
| Same restriction NOT seen in Teams for the same user | Expected — Teams is segmented view, Outlook is mixed view; they enforce differently by design | Confirm app + view type, not a cross-app inconsistency bug |
| MTD flags a device as high risk and blocks access for an account whose own MAM policy shouldn't trigger that | Device-level MTD threat signal shared across same-tenant accounts on one device | Check Entra device record and which account(s) reported the MTD signal |
| Feature "just isn't there" even on a fully updated, eligible app | Gradual rollout — tenant/ring hasn't received it yet | No fix; confirm eligibility and wait, or escalate to Microsoft if business-critical |
| User has 2 MDM-enrolled work accounts and wants MMA between them | Unsupported account composition | Convert one to MAM-only sign-in; MDM+MAM is capped at one account |

---
## Validation Steps

1. **Confirm app + platform eligibility.**
   ```powershell
   (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/<device-id>/detectedApps").value |
       Where-Object { $_.displayName -match 'Outlook|Teams' } | Select-Object displayName, version, platform
   ```
   Good: `platform` = iOS, `version` ≥ the documented floor. Bad: Android (out of scope) or a version below floor.

2. **Confirm account composition.** No direct Graph query enumerates "accounts signed into an app" — this requires user interview or on-device inspection (Settings inside the app, or MDM diagnostic log if the app surfaces it). Confirm at most one account is MDM-enrolled.

3. **Confirm no `IntuneMAMAllowedAccountsOnly` override.**
   ```powershell
   (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/targetedManagedAppConfigurations?`$expand=apps,assignments").value |
       ForEach-Object {
           $_.customSettings | Where-Object { $_.name -eq 'IntuneMAMAllowedAccountsOnly' } |
               Select-Object @{n='Policy';e={$_.displayName}}, name, value
       }
   ```
   Good: no result, or `value = 'false'`. Bad: `value = 'true'` scoped to the affected app/user's group.

4. **Confirm app protection policy assignment exists per account/tenant as expected.**
   ```powershell
   (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/iosManagedAppProtections?`$expand=assignments").value |
       Select-Object displayName, id, @{n='Assignments';e={$_.assignments.target.groupId -join ','}}
   ```

5. **Reproduce and classify the rendering model.** Ask the user (or, in a controlled test, reproduce directly) whether the restricted action happened in a single-account (segmented) view or a combined/shared (mixed) view. This determines whether the observed restriction is expected behavior.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Eligibility.** App on the supported list at/above the version floor, iOS/iPadOS platform, Intune-SDK-integrated (not wrapped). If any of these fail, MMA simply isn't available for this app/device — nothing further to check in Intune.

**Phase 2 — Admin-side blockers.** Check `IntuneMAMAllowedAccountsOnly` in every app configuration policy scoped to the user/app (not just app protection policies — this is a distinct policy object type). Also confirm the account attempting to add a second identity isn't itself trying to MDM-enroll.

**Phase 3 — Rendering-model classification.** Once eligibility and admin-side blockers are ruled out, any remaining "unexpected restriction" report almost always traces to the mixed-view full-lockdown behavior (Outlook) rather than a policy bug. Segmented-view apps (Teams) should show clean per-account enforcement; if they don't, that's a genuine anomaly worth escalating.

**Phase 4 — Cross-tenant / MTD signal review (MSP-specific).** For technicians or consultants holding managed accounts from multiple client tenants on one device, confirm whether an access block traces to a same-tenant MTD device-record threat signal versus a genuine per-account policy violation — pull the Entra device record and check which tenant(s) share it.

**Phase 5 — Rollout timing.** If everything above checks out clean and the behavior is simply absent, treat as a gradual-rollout gap, not a fault. Re-test after a known service-ring interval or escalate to Microsoft with tenant ID and app version if business-critical.

---
## Remediation Playbooks

<details><summary>Playbook A — Remove an unwanted IntuneMAMAllowedAccountsOnly restriction</summary>

```powershell
$policyId = "<targetedManagedAppConfiguration-policy-id>"
$policy = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/targetedManagedAppConfigurations/$policyId"
$newSettings = $policy.customSettings | Where-Object { $_.name -ne 'IntuneMAMAllowedAccountsOnly' }
Invoke-MgGraphRequest -Method PATCH `
    -Uri "https://graph.microsoft.com/beta/deviceAppManagement/targetedManagedAppConfigurations/$policyId" `
    -Body (@{ customSettings = $newSettings } | ConvertTo-Json -Depth 5)
```
**Rollback:** re-append `@{ name = 'IntuneMAMAllowedAccountsOnly'; value = 'true' }` to `customSettings` and PATCH again. Confirm with the policy owner before either direction — this key may be intentionally set for data-isolation/compliance reasons unrelated to the ticket at hand.
</details>

<details><summary>Playbook B — Convert a second MDM-enrolled account to MAM-only</summary>

No Graph/PowerShell remediation exists for this — it's a user-driven sign-in workflow change, not a policy object. Have the user remove the second account's device enrollment (via Settings > device management profile removal for that account, or unenroll via Company Portal for that identity), then re-add it as a MAM-only sign-in directly inside the target app rather than through an enrollment flow. Confirm the app's own account-add UI offers a "sign in" path distinct from "set up device management" — this varies slightly by app version.
</details>

<details><summary>Playbook C — Set expectations for mixed-view lockdown (no technical remediation)</summary>

Document in the ticket that this is expected behavior per Microsoft's own specification, cite the source, and close as "working as designed" rather than continuing to search for a policy fix. If the business genuinely needs less restrictive behavior in the combined view, the only lever is removing the second (managed or unmanaged) account from that mixed view entirely, which defeats the purpose of MMA for that account and should be escalated as a product feedback item, not chased as a support fix.
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects MMA-relevant evidence for one user/device ahead of an escalation.
#>
param(
    [Parameter(Mandatory)][string]$UserPrincipalName,
    [string]$OutputPath = ".\MMA-Evidence-$(Get-Date -Format yyyyMMdd-HHmm).json"
)

$device = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=userPrincipalName eq '$UserPrincipalName'").value |
    Where-Object { $_.operatingSystem -eq 'iOS' } | Select-Object -First 1

$apps = if ($device) {
    (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($device.id)/detectedApps").value |
        Where-Object { $_.displayName -match 'Outlook|Teams' }
} else { @() }

$appConfigHits = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/targetedManagedAppConfigurations?`$expand=apps,assignments").value |
    ForEach-Object {
        $match = $_.customSettings | Where-Object { $_.name -eq 'IntuneMAMAllowedAccountsOnly' }
        if ($match) { [pscustomobject]@{ Policy = $_.displayName; Setting = $match.name; Value = $match.value } }
    }

[pscustomobject]@{
    CollectedAt   = (Get-Date -Format 'o')
    User          = $UserPrincipalName
    Device        = $device
    RelevantApps  = $apps
    MMABlockingAppConfigPolicies = $appConfigHits
} | ConvertTo-Json -Depth 6 | Out-File -FilePath $OutputPath -Encoding utf8

Write-Host "Evidence written to $OutputPath"
```

---
## Command Cheat Sheet
```powershell
# App version on device
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/<id>/detectedApps").value

# All targeted app configuration policies + custom settings
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/targetedManagedAppConfigurations?`$expand=apps,assignments").value

# All iOS app protection policies + assignments
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/iosManagedAppProtections?`$expand=assignments").value

# Managed device record (for MTD/device-record cross-check)
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/<id>"

# Remove IntuneMAMAllowedAccountsOnly from a policy (see Playbook A for full rollback-safe version)
Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/beta/deviceAppManagement/targetedManagedAppConfigurations/<id>" -Body (@{customSettings=$newSettings}|ConvertTo-Json -Depth 5)
```

---
## 🎓 Learning Pointers
- Read [Multiple managed accounts for app protection policies](https://learn.microsoft.com/en-us/intune/app-management/protection/multiple-managed-accounts) end to end before your first MMA ticket — the FAQ section directly answers most "is this a bug" questions.
- Segmented vs. mixed view is the single most important mental model here — memorize which of your supported apps uses which (Teams = segmented, Outlook = mixed) since it predicts the entire support conversation.
- `IntuneMAMAllowedAccountsOnly` lives in **app configuration policies**, a different Graph resource (`targetedManagedAppConfigurations`) from app protection policies (`iosManagedAppProtections`/`androidManagedAppProtections`) — conflating the two is the most common diagnostic dead-end for this topic.
- Study [App protection policies overview](https://learn.microsoft.com/en-us/intune/app-management/protection/overview) and the [Intune App SDK](https://learn.microsoft.com/en-us/intune/developer/app-sdk/) docs to understand why MMA requires native SDK integration and can't be retrofitted onto a wrapped app.
- For MSP/multi-tenant technicians specifically: the device-level (not account-level) MTD threat signal is worth proactively explaining to client security teams before it causes a confusing cross-tenant access block.
