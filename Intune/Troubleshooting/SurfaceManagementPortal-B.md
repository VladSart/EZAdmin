# Surface Management Portal — Hotfix Runbook (Mode B: Ops)
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
## Triage

Surface Management Portal is a **workspace inside the Intune admin center** (All services > Surface Management Portal), not a separate product with its own license or its own RBAC model — it rides entirely on Intune enrollment plus Microsoft 365 admin-role assignment. If a ticket sounds like "portal is broken," it is almost always one of: the tenant has no enrolled Surface device yet, the signed-in admin has the wrong role combination, or the requester is looking for warranty/support data that has no Graph API and genuinely can only be read from the portal UI.

```powershell
# 1. Confirm at least one Surface device is actually Intune-enrolled (portal won't appear without this)
Get-MgDeviceManagementManagedDevice -Filter "contains(model,'Surface')" -All |
    Select-Object DeviceName, Model, SerialNumber, ComplianceState, ManagementState

# 2. Confirm the signed-in admin's Entra role assignments (Hardware Warranty roles need Global Reader too — see Fix 1)
Get-MgUserMemberOf -UserId "<UPN>" | Select-Object -ExpandProperty AdditionalProperties |
    Select-Object displayName, roleTemplateId

# 3. Confirm Intune tenant admin center is reachable at all (portal is a page inside it, not a separate URL to firewall/proxy-allow separately)
# Sign-in test: https://intune.microsoft.com > All services > search "Surface"

# 4. Confirm the Security Copilot plugin state if the complaint is "Copilot doesn't know about my Surface devices"
# Portal check only — no Graph/PowerShell read for plugin enablement state as of this writing
# Security Copilot portal > prompt bar > Sources > Manage Sources > "Surface Management Portal" toggle

# 5. Confirm device model string actually contains "Surface" — OEM-rebranded or generically-named devices won't self-identify
Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'Windows'" -All |
    Where-Object { $_.Manufacturer -notlike "*Microsoft*" -and $_.Model -like "*Surface*" } |
    Select-Object DeviceName, Manufacturer, Model
```

| If... | Then... |
|---|---|
| "Surface Management Portal" doesn't appear under **All services** at all | No Surface device is enrolled in Intune yet, or the tenant has no Intune subscription. See Fix 1. |
| Portal loads but shows **zero devices** despite Surface hardware being enrolled | First-sign-in data-population delay — Surface telemetry only flows into the portal after the *user* signs in on the device post-enrollment, not at enrollment time itself. See Fix 2. |
| Admin was assigned **Microsoft Hardware Warranty Administrator** (or Specialist) but still can't see warranty/support data in the portal | Missing co-requirement — those two roles need **Global Reader** assigned *in addition*, specifically for Surface Management Portal access (not required for every Surface-portal surface). See Fix 1. |
| Admin can't find where to even assign the role | Roles are assigned in the **Microsoft 365 admin center** (`admin.microsoft.com` > Roles > Role assignments), not Intune RBAC and not directly in the Entra admin portal's Roles blade. See Fix 3. |
| "We gave the tech Global Admin so they could use the portal" | Works, but Microsoft explicitly discourages it for this use case — least-privilege alternative exists. See Fix 4. |
| Support/service-order ticket data doesn't match what's in Intune device inventory | Expected — support requests and service orders are a **separate Microsoft backend** (warranty/repair system), not derived from or synced with Intune's own device records beyond the initial device identity match. See Fix 5. |
| "Why can't I pull warranty data with PowerShell/Graph?" | There is no documented Graph API for Surface Management Portal's warranty, support-request, or Insights data — it is a portal-only UI surface (the separate **Surface API Management Service** is a distinct product for entitlement/coverage lookups, not a Graph extension). See Fix 6. |
| Security Copilot gives no useful answers about Surface devices | The **Surface Management Portal plugin** in Security Copilot isn't enabled, or the tenant has insufficient Security Compute Units provisioned. See Fix 7. |
| New support request or service order form won't submit | Missing required field (Ship-to address, Billing address for paid orders, or Contact details) — walk the wizard back to the flagged step rather than assuming a platform bug. |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
[Tenant has an Intune subscription / admin center access]
        |
        ▼
[At least one Surface-model device is enrolled in Intune]
        |
        ▼
[End user signs in on that device at least once post-enrollment]
        |   (this is what actually triggers Surface telemetry/warranty data
        |    to start flowing into the portal — enrollment alone is not enough)
        ▼
[Surface Management Portal populates: Monitor / Warranty and coverage /
 Support / Service orders / Insights / Carbon emissions tabs]
        |
        ▼
[Admin has an appropriate Microsoft 365 admin role assigned]
        |
        ├── Global Admin (works everywhere, discouraged for this specific task)
        ├── Microsoft Hardware Warranty Administrator  + Global Reader  ← both required, Surface Mgmt Portal only
        ├── Microsoft Hardware Warranty Specialist      + Global Reader  ← both required, Surface Mgmt Portal only
        ├── Service Support Administrator (view + create/manage replacement requests)
        ├── Billing Administrator (view + create/manage + ship-to addresses)
        └── Global Reader (view-only across the board)
        |
        ▼
[Roles assigned via Microsoft 365 admin center > Roles > Role assignments]
        |
        ▼
[Optional: Security Copilot integration — separate enablement step]
        |
        ├── Security Copilot licensed + sufficient Security Compute Units (SCUs)
        └── "Surface Management Portal" plugin activated under Manage Sources
```

If any ticket is being diagnosed against Intune device-compliance mechanics (CSP, policy assignment, sync cadence) rather than the portal's own warranty/support/role layer, you're likely troubleshooting a different Intune topic — cross-check `Enrollment-B.md`/`Policy-Conflict-B.md` first.

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm a Surface device is actually enrolled**
```powershell
Get-MgDeviceManagementManagedDevice -Filter "contains(model,'Surface')" -All | Measure-Object
```
Expected: count ≥ 1. Zero results explains a missing/empty portal completely — nothing further to diagnose until a Surface device enrolls.

**Step 2 — Confirm the device has actually reported in (not just enrolled)**
```powershell
Get-MgDeviceManagementManagedDevice -Filter "contains(model,'Surface')" -All |
    Select-Object DeviceName, EnrolledDateTime, LastSyncDateTime, UserPrincipalName
```
A device enrolled minutes ago with no completed first user sign-in will not yet show warranty/coverage data in the portal — this is a timing gap, not a fault.

**Step 3 — Confirm the admin's actual role assignments (not what they were told they have)**
Portal: **Microsoft 365 admin center > Roles > Role assignments** → search the admin's name across each Surface-relevant role, or via Graph:
```powershell
$user = Get-MgUser -UserId "<UPN>"
Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '$($user.Id)'" |
    ForEach-Object {
        $def = Get-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId $_.RoleDefinitionId
        [PSCustomObject]@{ Role = $def.DisplayName; TemplateId = $def.TemplateId }
    }
```
Expected for a warranty-focused technician: **both** `Microsoft Hardware Warranty Administrator` (or `Specialist`) **and** `Global Reader` present. One without the other is the single most common "role was assigned but portal still doesn't work" root cause for this feature specifically.

**Step 4 — Confirm portal reachability itself**
Sign in to `https://intune.microsoft.com`, select **All services**, search "Surface." If the search returns nothing for an account that does hold Global Admin, treat as a genuine service issue and escalate — do not keep re-checking role assignments once Global Admin has already been ruled out as insufficient.

**Step 5 — Confirm Security Copilot plugin state (only if the complaint is Copilot-specific)**
Portal-only check: **Security Copilot portal > prompt bar > Sources > Manage Sources** → confirm the **Surface Management Portal** plugin shows enabled. Only certain roles can toggle this — see [Manage plugins in Microsoft Security Copilot](https://learn.microsoft.com/en-us/copilot/security/manage-plugins).

---
## Common Fix Paths

<details><summary>Fix 1 — Role assigned but portal still shows no warranty/support data</summary>

Confirmed root cause (per Microsoft's own documentation): **Microsoft Hardware Warranty Administrator** and **Microsoft Hardware Warranty Specialist** both require **Global Reader** to be assigned *in addition* — specifically for Surface Management Portal, not necessarily for every Surface-portal surface. Assigning only the Hardware Warranty role silently leaves the portal underpowered rather than throwing a clear access-denied error, which is what makes this the top misdiagnosis pattern for this feature.

1. Microsoft 365 admin center > **Roles > Role assignments**.
2. Confirm the affected admin already holds `Microsoft Hardware Warranty Administrator` or `Specialist`.
3. Search **Global Reader**, select **Assigned** tab, **Add users**, add the same admin.
4. Have the admin sign out/in (role propagation can take up to ~30 minutes; don't escalate before that window passes).

**Rollback:** remove the Global Reader assignment if it was added in error — it is read-only and low-risk to leave in place otherwise.

</details>

<details><summary>Fix 2 — Portal shows zero devices despite Surface hardware being enrolled</summary>

Enrollment alone does not populate the portal. Data begins flowing only after the **end user signs in on the device** for the first time post-enrollment.

1. Confirm via `Get-MgDeviceManagementManagedDevice` (Diagnosis Step 2) that `LastSyncDateTime` shows at least one completed check-in after `EnrolledDateTime`.
2. If the device was enrolled but never actually handed to/signed into by an end user (common with pre-staged bulk enrollment), the gap is expected — it will resolve once the device is actually used.
3. If sign-in has clearly occurred and the device still doesn't appear after 24 hours, escalate rather than continuing to wait.

**Rollback:** N/A — no configuration change involved, purely a data-population timing issue.

</details>

<details><summary>Fix 3 — Admin can't find where to assign the role</summary>

A common miss: technicians look in the **Intune admin center's** own RBAC (Roles/Scope Tags) or the **Entra admin center's** Roles blade — neither is where Surface portal roles live.

1. Go to **admin.microsoft.com** (Microsoft 365 admin center, not Intune, not Entra).
2. **Roles > Role assignments**.
3. Search the specific role name (e.g., "Microsoft Hardware Warranty Administrator").
4. **Assigned** tab > **Add users** > search and select > **Save**.

**Rollback:** remove the user from the role's Assigned tab the same way.

</details>

<details><summary>Fix 4 — Global Admin was used instead of a scoped role</summary>

Works technically (Global Admin can do everything the scoped roles can), but Microsoft explicitly recommends against it for this use case — Global Admin is a highly privileged, broad-blast-radius role that should be reserved for scenarios with no viable narrower alternative.

1. Identify the actual task the admin needs (warranty/service management vs. billing vs. read-only oversight) and map to the narrowest matching role from the Roles and Permissions table in `SurfaceManagementPortal-A.md`.
2. Assign the scoped role (+ Global Reader if it's a Hardware Warranty role) via Fix 3's steps.
3. Remove Global Admin from the user once the scoped role is confirmed working, unless they have a separate, legitimate reason to hold it.

**Rollback:** re-adding Global Admin is trivial if a genuine broader need surfaces later — don't leave it assigned "just in case" for a single-purpose warranty-tracking task.

</details>

<details><summary>Fix 5 — Support/service-order data looks disconnected from Intune's own device records</summary>

Support requests and service orders (repair/replacement) are handled by a **separate Microsoft backend system** for hardware service, matched to the device by serial number/model at the time a request is created — not continuously synced with Intune's device inventory beyond that initial lookup.

1. Confirm the serial number used when the support/service request was filed matches the device's actual serial in Intune (`Get-MgDeviceManagementManagedDevice` → `SerialNumber`).
2. If a device was re-imaged, re-enrolled, or its Intune object was deleted/recreated after a request was filed, expect the support-system record and the current Intune object to diverge — this is by design, not a sync bug to chase.
3. For a mismatch that blocks an active repair, use the **Case ID** or **service order ID** directly with Microsoft support rather than trying to reconcile it against the current Intune object.

**Rollback:** N/A — informational reconciliation, no configuration change.

</details>

<details><summary>Fix 6 — Requester wants to pull warranty/support data via PowerShell or Graph</summary>

There is currently no documented Graph API surfacing Surface Management Portal's warranty, coverage, support-request, or Insights data — it is a portal-only UI feature. The one legitimate programmatic path is the separate **Surface API Management Service**, a distinct Microsoft offering for coverage/entitlement lookups (its own onboarding, not a Graph permission you can add to an existing app registration).

1. Confirm the actual requirement: if it's device compliance/encryption/storage data (several items overlap with the portal's Insights list), that portion **is** available via standard Intune Graph endpoints — see `Get-SurfaceManagementPortalAudit.ps1`.
2. If it's specifically warranty/coverage/support-request data, point the requester at manual export from the portal UI (**Warranty and coverage > View report**) or the Surface API Management Service (separate product, see [Introducing the Surface API Management Service](https://techcommunity.microsoft.com/t5/surface-it-pro-blog/introducing-the-surface-api-management-service/ba-p/4107282)) rather than promising a Graph-based automation that doesn't exist for this data.

**Rollback:** N/A — informational.

</details>

<details><summary>Fix 7 — Security Copilot gives no useful Surface-specific answers</summary>

1. Confirm the tenant is actually licensed for Security Copilot and has provisioned Security Compute Units — Copilot for Surface Management Portal itself requires **no separate license** beyond Security Copilot, but SCU exhaustion will silently degrade or block responses.
2. Security Copilot portal > prompt bar > **Sources** button > **Manage Sources** > confirm the **Surface Management Portal** plugin is toggled on.
3. Only certain roles can enable/disable plugins — confirm the account attempting to toggle it actually holds one of those roles (see [Manage plugins in Microsoft Security Copilot](https://learn.microsoft.com/en-us/copilot/security/manage-plugins)).
4. Retry with one of Microsoft's documented sample prompts (e.g., "Generate a warranty coverage report for all devices") to rule out a phrasing/matching issue before escalating as broken.

**Rollback:** disabling the plugin removes Surface-specific Copilot answers with no other side effects.

</details>

---
## Escalation Evidence

```
Ticket: Surface Management Portal issue
─────────────────────────────────────────
Tenant ID:                         <____________________>
Admin UPN affected:                <____________________>
Admin's current role assignments (Get-MgRoleManagementDirectoryRoleAssignment output): <_______>
Surface device count enrolled in Intune (contains(model,'Surface')): <__>
Affected device name/serial (if device-specific):  <____________________>
EnrolledDateTime / LastSyncDateTime for affected device: <____________________>
Portal symptom (missing entirely / empty data / role-denied / support mismatch / Copilot no answer): <_______>
Security Copilot plugin state (if relevant, enabled/disabled): <_______>
Case ID / service order ID (if support-request related): <____________________>
Time issue first observed: <____________________>
```

---
## 🎓 Learning Pointers

- **The Global Reader co-requirement for the Hardware Warranty roles is the single most common misdiagnosis for this feature.** Microsoft's own documentation states it explicitly but it's easy to miss during role assignment since no error message calls it out — build "did you also add Global Reader?" into first-response triage before escalating. [Assign admin roles for Surface portals](https://learn.microsoft.com/en-us/surface/surface-portal-admin-roles)

- **Enrollment and data population are two different events.** A freshly-enrolled Surface device won't show warranty/coverage data until the assigned user actually signs in on it — don't treat an empty portal entry as broken until that first-sign-in gap has been ruled out. [Surface Management Portal overview](https://learn.microsoft.com/en-us/surface/surface-management-portal)

- **This is portal-only for its unique data (warranty, coverage, support requests, service orders, Insights) — there is no Graph API for it.** Only the device-compliance-adjacent slice of what Insights shows (compliance, encryption, storage, Windows 11 eligibility) can be independently derived via standard Intune Graph calls; don't promise a full Graph-based warranty automation. [Overview of Microsoft Surface Management Portal](https://learn.microsoft.com/en-us/intune/device-management/tools/surface-management-portal)

- **Roles live in the Microsoft 365 admin center, not Intune RBAC and not the Entra admin portal's Roles blade** — despite being real Entra role templates under the hood. Point technicians at `admin.microsoft.com > Roles > Role assignments` directly rather than letting them search Intune's own scope-tag/RBAC surface first. [Assign admin roles for Surface portals](https://learn.microsoft.com/en-us/surface/surface-portal-admin-roles)

- **Security Copilot integration for this portal is included at no additional license cost** beyond Security Copilot itself and consumes only Security Compute Units — a genuinely unusual, no-extra-purchase-needed position worth stating proactively to clients already on Security Copilot. [Security Copilot in Microsoft Surface Management Portal](https://learn.microsoft.com/en-us/intune/intune-service/copilot/security-copilot-surface-portal)

- **Support requests/service orders live in a separate backend from Intune's device inventory**, matched by serial number at request-creation time only — don't expect continuous sync, and use the Case ID/service order ID as the source of truth for an active repair rather than the current Intune device object. [Surface Management Portal overview](https://learn.microsoft.com/en-us/surface/surface-management-portal)
