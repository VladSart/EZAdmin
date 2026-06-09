# Microsoft Purview Insider Risk Management — Hotfix Runbook (Mode B: Ops)
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

Run these first to determine alert category and blast radius.

```powershell
# Connect to Security & Compliance PowerShell
$session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri "https://ps.compliance.protection.outlook.com/powershell-liveid/" -Credential (Get-Credential) -Authentication Basic -AllowRedirection
Import-PSSession $session -DisableNameChecking

# 1. Check IRM license status
Get-MgSubscribedSku | Where-Object {$_.SkuPartNumber -match "COMPLIANCE|E5|EMS"} | Select-Object SkuPartNumber, CapabilityStatus

# 2. Check IRM policy count and status
# (Requires Compliance portal or Graph — see Diagnosis section)
Invoke-RestMethod -Uri "https://compliance.microsoft.com/api/insiderrisks/policies" -Headers @{Authorization="Bearer <token>"}

# 3. Check audit log connectivity (IRM depends on Unified Audit Log)
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled

# 4. Check user scope — is the flagged user in the policy scope?
# Get-InsiderRiskPolicy is not available in PS — use Compliance portal:
# https://compliance.microsoft.com → Insider risk management → Policies
```

**Interpretation:**

| Result | Action |
|--------|--------|
| `UnifiedAuditLogIngestionEnabled = False` | Fix 1 — Enable audit log |
| Missing E5/Compliance licence on affected user | Fix 2 — Assign licence |
| Policy shows "Off" in portal | Fix 3 — Activate policy |
| No indicators triggering in portal | Fix 4 — Verify indicator configuration |
| User not in policy scope | Fix 5 — Add user to policy scope |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft 365 E5 / E5 Compliance licence assigned to users in scope
        │
Unified Audit Log ENABLED (Security & Compliance)
        │
Insider Risk Management ENABLED in tenant
  └── Roles: Insider Risk Management Admin assigned in Compliance portal
        │
IRM Policy CREATED and ACTIVE
  ├── Policy template selected (data theft, leaks, violations, etc.)
  ├── Users in scope (individuals, groups, or All users)
  ├── Indicators ENABLED in IRM settings (at least some)
  └── Triggering event configured (HR connector, policy violation, etc.)
        │
Content sources connected (must match indicators)
  ├── SharePoint Online — accessible by Compliance
  ├── Teams messages — accessible by Compliance
  ├── Exchange email — accessible by Compliance (E3+)
  ├── Endpoint DLP — MDE onboarded devices (for device indicators)
  └── HR Connector — optional, for resignation/termination triggers
        │
Alerts generated when user activity matches policy threshold
        │
Analyst/Admin reviews alert in Compliance portal
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm Unified Audit Log is enabled**
```powershell
# Run in Exchange Online PowerShell
Connect-ExchangeOnline -UserPrincipalName <admin@tenant.com>
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled
```
Expected: `True`. If `False` — proceed to Fix 1.

**Step 2 — Confirm licences**
```powershell
# Check specific user licence
Connect-MgGraph -Scopes "User.Read.All", "Organization.Read.All"
$user = Get-MgUser -Filter "userPrincipalName eq '<user@domain.com>'" -Property AssignedLicenses,DisplayName
$user.AssignedLicenses | ForEach-Object {
    Get-MgSubscribedSku | Where-Object {$_.SkuId -eq $_.SkuId} | Select-Object SkuPartNumber
}
```
Expected: E5, E5 Compliance, or Microsoft 365 E5 Compliance add-on assigned.
Bad: No Compliance licence → Fix 2.

**Step 3 — Confirm IRM policy is active**
Navigate to: `https://compliance.microsoft.com` → **Insider risk management** → **Policies**

Check: Policy status = **Active**. If **Off** or **Draft** → Fix 3.

**Step 4 — Confirm indicators are enabled**
Navigate to: **Insider risk management** → **Settings** → **Indicators**

At least one indicator group must be enabled (Office indicators, Device indicators, Security violation indicators, HR indicators). If all unchecked → Fix 4.

**Step 5 — Confirm target user is in policy scope**
In policy settings, check if user is:
- In the "All users" scope, OR
- In a specified group or explicit user list

If not → Fix 5.

**Step 6 — Check audit log is capturing the relevant activities**
```powershell
# Search audit log for recent user activities (last 24h)
$endDate = Get-Date
$startDate = $endDate.AddHours(-24)
Search-UnifiedAuditLog -StartDate $startDate -EndDate $endDate -UserIds "<user@domain.com>" -ResultSize 50 |
    Select-Object CreationDate, UserIds, Operations, RecordType | Format-Table -AutoSize
```
Expected: Entries visible for SharePoint, Teams, Exchange activities.
Bad: No entries for a user who is active — audit log pipeline delay (up to 48h for full ingestion) or tenant audit issue.

---

## Common Fix Paths

<details>
<summary>Fix 1 — Enable Unified Audit Log</summary>

**Required for IRM to function. Without this, zero signals reach the policy engine.**

```powershell
Connect-ExchangeOnline -UserPrincipalName <admin@tenant.com>

# Enable audit log
Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true

# Verify
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled
```

> Note: New tenants created after 2019 have audit log enabled by default. If it was disabled deliberately (compliance team decision), confirm with stakeholder before re-enabling.

**Rollback:** `Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $false` — but don't do this in production without approval.

</details>

<details>
<summary>Fix 2 — Assign Microsoft 365 E5 Compliance licence</summary>

**IRM requires E5 Compliance for each user in scope. Without it, the user's activities are not evaluated.**

```powershell
Connect-MgGraph -Scopes "User.ReadWrite.All", "Organization.Read.All"

# Find the E5 Compliance SKU ID
$sku = Get-MgSubscribedSku | Where-Object {$_.SkuPartNumber -eq "INFORMATION_PROTECTION_COMPLIANCE"}
# Common alternatives: "M365_E5_COMPLIANCE", "SPE_E5"
Write-Host "SKU ID: $($sku.SkuId)"

# Assign to user
$userId = (Get-MgUser -Filter "userPrincipalName eq '<user@domain.com>'").Id
$params = @{
    AddLicenses = @(@{SkuId = $sku.SkuId})
    RemoveLicenses = @()
}
Set-MgUserLicense -UserId $userId -BodyParameter $params
Write-Host "Licence assigned" -ForegroundColor Green
```

**Rollback:** Remove licence with `RemoveLicenses = @($sku.SkuId)`. Removing licence disables IRM evaluation for the user — data is not deleted, just no longer monitored.

</details>

<details>
<summary>Fix 3 — Activate or recreate IRM policy</summary>

**This must be done in the Microsoft Purview Compliance portal — no PowerShell equivalent for IRM policy management.**

1. Navigate to: `https://compliance.microsoft.com` → **Insider risk management** → **Policies**
2. If policy status is **Off**: Click policy name → **Edit** → scroll to last step → set **Policy status = On** → Save
3. If policy is in **Draft**: Complete all required fields (template, users, indicators) and publish
4. If policy was deleted: Re-create from template (Data theft, Data leaks, Security policy violations, etc.)

> **Note:** After activating a policy, it takes **24 hours** for the first alerts to appear. IRM is not real-time.

</details>

<details>
<summary>Fix 4 — Enable risk indicators</summary>

**No indicators = no signals = no alerts. This is the most common misconfiguration in new IRM deployments.**

1. Navigate to: **Insider risk management** → **Settings** (gear icon) → **Indicators**
2. Expand **Office indicators**: Enable at minimum — SharePoint file download, Teams message sends, Email forwarding to external
3. Expand **Device indicators** (requires MDE): Enable file copy to USB, browser upload to cloud
4. Click **Save**

> Indicators are tenant-wide and apply to all policies. Changes take effect immediately for new activity, but don't backfill historical signals.

**Common mistake:** Enabling device indicators without having MDE onboarded devices. This will show indicators enabled but no device signals will appear.

</details>

<details>
<summary>Fix 5 — Add user to policy scope</summary>

**If user is not in the policy's user scope, their activities are never evaluated — no alerts will fire regardless of activity.**

1. Navigate to: **Insider risk management** → **Policies** → Click relevant policy → **Edit**
2. On the **Users and groups** step: Add the user by name/group or switch to "All users"
3. Save and allow 24h for evaluation to begin

> For large organisations, scoping to "All users" is common but has licensing implications — every user in scope needs E5 Compliance.

</details>

---

## Escalation Evidence

Copy, fill, and attach to your escalation ticket:

```
=== INSIDER RISK MANAGEMENT — ESCALATION PACK ===
Date/Time:          ___________________________
Tenant ID:          ___________________________
Affected User UPN:  ___________________________
Policy Name:        ___________________________
Alert ID (if any):  ___________________________
Raised by:          ___________________________

--- DIAGNOSTIC CHECKLIST ---
[ ] Unified Audit Log enabled:   Yes / No
[ ] User has E5 Compliance lic:  Yes / No
[ ] IRM policy status:           Active / Off / Draft
[ ] Indicators enabled:          Yes / No / Partial
[ ] User in policy scope:        Yes / No
[ ] Audit log showing activity:  Yes / No / Delayed

--- ISSUE DESCRIPTION ---
Expected behaviour:  ___________________________
Actual behaviour:    ___________________________
First occurrence:    ___________________________
Steps already tried: ___________________________

--- SCREENSHOTS / EXPORTS ---
[ ] Compliance portal screenshot of policy settings
[ ] Audit log search result CSV (Search-UnifiedAuditLog export)
[ ] User licence assignment screenshot
[ ] Any error messages from Compliance portal

--- MICROSOFT SUPPORT LINKS ---
Open ticket at: https://admin.microsoft.com → Support → New service request
Category: Compliance → Insider Risk Management
Tenant ID required (Get-MgOrganization | Select-Object Id)
```

---

## 🎓 Learning Pointers

- **IRM is not real-time.** Alerts typically take 24–48 hours to fire after a triggering event. Engineers expecting immediate alerts after policy activation will be disappointed — build this expectation into communication with stakeholders. See: [Insider risk management alerts](https://learn.microsoft.com/en-us/purview/insider-risk-management-alerts)

- **The Unified Audit Log is the single data pipe for IRM.** If audit log ingestion is delayed or disabled, IRM is blind. Always validate UAL first before debugging policy configuration. See: [Turn auditing on or off](https://learn.microsoft.com/en-us/purview/audit-log-enable-disable)

- **Indicator thresholds are adjustable.** Out-of-the-box thresholds are conservative. Organisations with high normal file activity (e.g. data engineering teams) will generate false positives. Tune thresholds in IRM Settings → Intelligent detections before rollout to avoid analyst fatigue. See: [Insider risk management settings](https://learn.microsoft.com/en-us/purview/insider-risk-management-settings)

- **Privacy by design — IRM has a two-stage anonymisation.** User identities are anonymised by default in the analyst view; only admins with the "Insider Risk Management" role can de-anonymise. Understand this role split before assigning access to your helpdesk team. See: [Privacy controls for IRM](https://learn.microsoft.com/en-us/purview/insider-risk-management-settings#privacy)

- **HR Connector unlocks the most powerful triggers.** Termination/resignation events from HR systems (via the HR data connector) enable the "Departing employee data theft" template's full capabilities. Without it, IRM can only use policy-based triggers. See: [HR data connector setup](https://learn.microsoft.com/en-us/purview/import-hr-data)

- **Device indicators require Defender for Endpoint (MDE) onboarding.** IRM's device-side signals (USB copies, browser uploads) flow through MDE. If MDE is not onboarded, device indicators will show as enabled but produce no data. Confirm MDE device onboarding status before scoping device-indicator-heavy policies. See: [Get started with Insider risk management](https://learn.microsoft.com/en-us/purview/insider-risk-management-configure)
