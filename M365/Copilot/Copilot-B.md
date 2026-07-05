# Microsoft 365 Copilot — Hotfix Runbook (Mode B: Ops)
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

Run these first to locate the failure layer.

```powershell
# 1. Confirm the user has a Copilot license assigned
Connect-MgGraph -Scopes "User.Read.All"
Get-MgUserLicenseDetail -UserId '<UPN>' | Where-Object { $_.SkuPartNumber -match "Microsoft_365_Copilot" }

# 2. Confirm prerequisite base license is present (Copilot requires an underlying M365 E3/E5/BP license)
Get-MgUserLicenseDetail -UserId '<UPN>' | Select-Object SkuPartNumber

# 3. Check whether Copilot is disabled at the tenant or app level
Connect-MicrosoftTeams
Get-CsTeamsCopilotPolicy -Identity Global | Select-Object Identity, CopilotEnabled

# 4. Check Semantic Index / Graph-grounding readiness (content must be indexed to be referenced)
# (No direct cmdlet — verify via a known test file/email the user has access to)

# 5. Check for Conditional Access blocking the Copilot service principal / M365 app
Get-MgIdentityConditionalAccessPolicy | Where-Object { $_.DisplayName -like "*Copilot*" -or $_.Conditions.Applications.IncludeApplications -contains "<CopilotAppId>" }
```

| Result | Action |
|--------|--------|
| No Copilot SKU on user | → Fix 1: Assign Copilot license |
| Base license missing/downgraded | → Fix 2: Restore prerequisite license |
| Tenant/app policy disables Copilot for the user's group | → Fix 3: Adjust Copilot policy assignment |
| Copilot responds but ignores organizational content | → Fix 4: Fix permissions/indexing gap (oversharing lockdown or missing access) |
| Copilot blocked entirely at sign-in | → Fix 5: Adjust Conditional Access scoping |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
[Base M365 License]
  └─ Microsoft 365 E3/E5, Business Premium, or Business Standard (as eligible)
         |
[Microsoft 365 Copilot add-on license]
  └─ Assigned to the specific user
         |
[Tenant-level Copilot enablement]
  └─ Not blocked by admin at the Microsoft 365 apps admin center / Copilot Studio
         |
[App-specific Copilot policy]
  └─ TeamsCopilotPolicy / Copilot for specific apps (Word, Excel, Outlook, Teams) not disabled for the user's group
         |
[Conditional Access]
  └─ Not blocking the Copilot/M365 Chat service principal for the user/device/location
         |
[Microsoft Graph grounding data]
  └─ User has underlying permission to the SharePoint/OneDrive/Exchange content Copilot references
  └─ Content is indexed by Microsoft Search / Semantic Index
         |
[Copilot responds with organizationally-grounded answers]
```

</details>

---
## Diagnosis & Validation Flow

**1. Confirm license stack (base + Copilot add-on)**
```powershell
Get-MgUserLicenseDetail -UserId '<UPN>' | Select-Object SkuPartNumber, SkuId
```
*Good:* Both a base M365 SKU (`SPE_E3`, `SPE_E5`, etc.) and `Microsoft_365_Copilot` present.
*Bad:* Copilot SKU present but base SKU missing/suspended — Copilot won't function without the underlying app licenses (Word, Excel, Outlook, Teams).

**2. Confirm tenant-level and policy-level enablement**
Portal: Microsoft 365 admin center > Copilot > Overview — check tenant-wide status.
```powershell
Get-CsTeamsCopilotPolicy -Identity Global
Get-CsTeamsCopilotPolicy | Select-Object Identity, CopilotEnabled
```
*Bad:* A custom policy assigned to the user's group has `CopilotEnabled: Disabled`.

**3. Confirm no Conditional Access block**
```powershell
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<UPN>' and appDisplayName eq 'Microsoft 365 Copilot'" -Top 5 |
    Select-Object CreatedDateTime, ConditionalAccessStatus, AppliedConditionalAccessPolicies
```
*Bad:* `ConditionalAccessStatus: failure` — a CA policy scoped to "All cloud apps" or the specific Copilot app ID is blocking.

**4. Confirm grounding/permission behavior (most common "Copilot gives wrong/no answer" root cause)**
Ask the user to reference a document they know they have access to. If Copilot can't find it:
- Confirm the user actually has direct or group-based SharePoint/OneDrive permission to the file (Copilot only surfaces what the user could already access — it does not bypass permissions).
- Confirm the content isn't excluded from Microsoft Search indexing (site-level search visibility settings).

**5. Confirm Copilot isn't restricted by a data loss prevention / sensitivity label block**
Check Purview DLP policies scoped to Copilot activities (a relatively new DLP target type) that might silently prevent Copilot from summarizing labeled-sensitive content.

---
## Common Fix Paths

<details><summary>Fix 1 — Assign Copilot license</summary>

```powershell
Connect-MgGraph -Scopes "User.ReadWrite.All","Organization.Read.All"

# Confirm available Copilot licenses in the pool
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "Microsoft_365_Copilot" } |
    Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits

# Assign
Set-MgUserLicense -UserId '<UPN>' -AddLicenses @{SkuId = '<CopilotSkuId>'} -RemoveLicenses @()
```
Allow up to a few hours for full propagation across Word/Excel/PowerPoint/Outlook/Teams clients; a client restart or sign-out/in often speeds this up.

**Rollback:** `Set-MgUserLicense -UserId '<UPN>' -AddLicenses @() -RemoveLicenses @('<CopilotSkuId>')`

</details>

<details><summary>Fix 2 — Restore prerequisite base license</summary>

Use when: Copilot SKU is present but a base license (Word/Excel/Outlook/Teams-granting SKU) was removed or lapsed.

```powershell
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "SPE_E3|SPE_E5|SPB" } |
    Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits

Set-MgUserLicense -UserId '<UPN>' -AddLicenses @{SkuId = '<BaseSkuId>'} -RemoveLicenses @()
```

**Rollback:** Remove if assigned in error, but note this also removes the underlying Office apps.

</details>

<details><summary>Fix 3 — Adjust Copilot policy assignment</summary>

Use when: a Teams/M365 Copilot policy disables Copilot for the user's assigned group.

```powershell
Connect-MicrosoftTeams
Grant-CsTeamsCopilotPolicy -Identity '<UPN>' -PolicyName "Global"   # Or the correct enabling policy name
```

Also check per-app Copilot controls in Microsoft 365 admin center > Settings > Org settings > Copilot, which can independently toggle Copilot for Word/Excel/PowerPoint/Outlook.

**Rollback:** Re-apply the prior policy name if this was an intentional restriction.

</details>

<details><summary>Fix 4 — Fix grounding/permission gaps</summary>

Use when: Copilot works but doesn't reference expected organizational content, or gives incomplete answers.

1. Confirm actual SharePoint/OneDrive permission (not just "should have access" — verify directly):
```powershell
Connect-MgGraph -Scopes "Sites.Read.All"
Get-MgSitePermission -SiteId '<SiteId>' | Select-Object Roles, GrantedToV2
```
2. Check if the tenant has run a **SharePoint oversharing/restricted content discovery** review — Copilot respects any restricted access policies applied site-wide, including "restricted SharePoint search" scopes that intentionally limit what's surfaced.
3. Confirm the content type is supported (Copilot grounding covers Exchange mail/calendar, SharePoint/OneDrive files, Teams chats/meetings — not arbitrary external line-of-business data unless a Copilot connector/plugin is configured).

**Rollback:** N/A — this is a permissions/config correction, not a reversible action.

</details>

<details><summary>Fix 5 — Adjust Conditional Access scoping</summary>

Use when: sign-in logs show `ConditionalAccessStatus: failure` for the Copilot app.

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess"
Get-MgIdentityConditionalAccessPolicy | Where-Object { $_.Conditions.Applications.IncludeApplications -contains "All" } |
    Select-Object DisplayName, State
```
Confirm the user/device/location combination is intended to be blocked. If not intentional, add an exclusion group or adjust device compliance/location conditions for the affected policy.

**Rollback:** Reverse the policy exclusion/scope change once resolved.

</details>

---
## Escalation Evidence

```
MICROSOFT 365 COPILOT ESCALATION
======================================
Date/Time                :
Tenant ID                 :
User UPN                  :
Copilot License Assigned  : YES / NO
Base License Present      : YES / NO
Tenant Copilot Enabled    : YES / NO
Applicable Copilot Policy :
CA Policy Blocking        : YES / NO — Policy Name:
Symptom                   : (no response / blocked / missing content / wrong answer)
Test Document/Email Used  :
Steps Already Tried        :
```

---
## 🎓 Learning Pointers

- **Copilot never bypasses existing permissions** — if a user can't see a file in SharePoint directly, Copilot can't surface it either. "Copilot doesn't know about X" is very often a permissions problem in disguise, not a Copilot bug.
- **Two license layers are required, not one** — the Copilot add-on SKU rides on top of a base M365 license (E3/E5/Business Premium). Losing the base license silently breaks Copilot even if the add-on SKU is still assigned.
- **Oversharing remediation can look like a Copilot outage** — organizations that recently tightened SharePoint sharing/oversharing policies sometimes see Copilot "stop finding" content users previously could access broadly — this is often working as intended, not a fault.
- **Client-side propagation lag is real** — after any license or policy change, allow time (and a client restart) before concluding the fix didn't work.
- **MS Docs:** [Microsoft 365 Copilot requirements](https://learn.microsoft.com/en-us/copilot/microsoft-365/microsoft-365-copilot-requirements) | [Manage Copilot policies](https://learn.microsoft.com/en-us/microsoftteams/teams-copilot-policies) | [Data, privacy, and security for Copilot](https://learn.microsoft.com/en-us/copilot/microsoft-365/microsoft-365-copilot-privacy)
