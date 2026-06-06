# Sensitivity Labels — Hotfix Runbook (Mode B: Ops)
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

Run these on a machine with the Compliance/Exchange PowerShell module. Use `Connect-IPPSSession` first.

```powershell
# 1. Check published label policies and their target users/groups
Connect-IPPSSession
Get-LabelPolicy | Select-Object Name, Enabled, ModifiedBy, LastModifiedBy |
    Format-Table -AutoSize

# 2. Check what labels exist and their parent/child hierarchy
Get-Label | Select-Object Name, ParentLabelDisplayName, IsEnabled, Priority,
    ContentType, Sensitivity | Sort-Object Priority | Format-Table -AutoSize

# 3. Check if a specific user is targeted by any policy
$upn = "<user@domain.com>"
Get-LabelPolicy | ForEach-Object {
    $policy = $_
    $included = (Get-LabelPolicy -Identity $policy.Name).ExchangeLocation
    [PSCustomObject]@{
        Policy = $policy.Name
        Enabled = $policy.Enabled
        TargetsUser = if ($included -eq 'All') {'All users'} else {$included -join ', '}
    }
} | Format-Table -Wrap

# 4. Check MIP client labels sync status (if using built-in labeling in M365 Apps)
# In Entra portal: Apps → Enterprise Apps → "Microsoft Information Protection Sync Service"
# Must exist and be enabled

# 5. Check label applied to a specific document (SharePoint/OneDrive)
Connect-PnPOnline -Url "https://<tenant>.sharepoint.com/sites/<site>" -Interactive
Get-PnPListItem -List "Documents" -Fields "OfficeSensitivityLabel","FileSensitivityLabelInfo" -PageSize 100 |
    Select-Object -ExpandProperty FieldValues |
    Select-Object FileLeafRef, OfficeSensitivityLabel |
    Where-Object OfficeSensitivityLabel -ne $null | Format-Table
```

**Interpretation:**

| Result | Action |
|--------|--------|
| Label not in `Get-Label` output | Label deleted or never created — check Purview portal |
| Policy `Enabled = False` | Policy disabled — re-enable or check if intentional |
| User not in any policy's `TargetsUser` | Add user/group to label policy |
| Label visible in Word but not Outlook | Check `ContentType` on label — must include `Email` |
| No labels visible in any M365 App | MIP Sync Service not enabled; policy not published |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
[Sensitivity Label defined in Microsoft Purview]
  requires:
    ├── Label created (Get-Label) with correct ContentType (File, Email, Site, etc.)
    ├── Label enabled (IsEnabled = True)
    └── Label has correct settings (encryption, marking, auto-labeling if used)
          │
          ▼
[Label Policy published to users]
  requires:
    ├── Label policy created (Get-LabelPolicy)
    ├── Policy enabled
    ├── Policy includes the label(s)
    └── Policy targets the user (All users, or specific group that user is in)
          │  Policy propagation: up to 24h for new policies
          ▼
[M365 App displays label to user]
  requires:
    ├── Microsoft 365 Apps (Word, Excel, Outlook, etc.) — built-in labeling
    │   └── Office version supports built-in labeling (M365 Apps 2209+)
    ├── OR Azure Information Protection (AIP) Unified Labeling client (legacy)
    └── MIP Sync Service enterprise app enabled in Entra ID
          │
          ▼
[Label applied to content]
  requires:
    ├── User selects label (manual labeling)
    ├── OR auto-labeling rule matches content (client-side or service-side)
    └── User has permissions to apply that specific label (policy scope)
          │
          ▼
[Label enforcement on SharePoint/OneDrive site]
  requires:
    ├── Site labels feature enabled (Set-SPOTenant -EnableAIPIntegration $true)
    └── Label published with scope: Groups & Sites (not just Files & Emails)
```

</details>

---

## Diagnosis & Validation Flow

**1. Confirm labels exist and are enabled**
```powershell
Connect-IPPSSession
Get-Label | Where-Object IsEnabled -eq $true |
    Select-Object Name, ContentType, Priority, ParentLabelDisplayName |
    Sort-Object Priority | Format-Table
```
Expected: Your expected labels listed with `IsEnabled = True`  
If empty or missing: Labels deleted or never created — recreate in Purview portal

**2. Confirm a label policy targets the affected user**
```powershell
$upn = "<user@domain.com>"
# Find what groups the user is in (label policies often target groups)
Connect-MgGraph -Scopes "GroupMember.Read.All","User.Read.All"
$user = Get-MgUser -Filter "userPrincipalName eq '$upn'"
$groups = Get-MgUserMemberOf -UserId $user.Id | Select-Object -ExpandProperty AdditionalProperties |
    Select-Object displayName, id
Write-Host "User's groups:"
$groups | Format-Table

# Now check which label policies exist and their targets
Get-LabelPolicy | Select-Object Name, Enabled | Format-Table
# For each policy, check Exchange/SharePoint locations in Purview portal
# or via: (Get-LabelPolicy -Identity "<policyName>").ExchangeLocation
```
Expected: At least one policy is `Enabled = True` and targets "All" or a group the user is in  
If no policy targets user: Add user/group to existing policy, or create new policy

**3. Check label propagation delay**
```powershell
# New or modified policies can take up to 24h to propagate to clients
# Check when the policy was last modified
Get-LabelPolicy | Select-Object Name, LastModifiedBy, WhenChangedUTC | Format-Table
```
If modified recently: Wait up to 24h, or force refresh in Office app: File → Account → Update Options → Update Now

**4. Check AIP/MIP integration for SharePoint**
```powershell
Connect-SPOService -Url https://<tenant>-admin.sharepoint.com
(Get-SPOTenant).EnableAIPIntegration
```
Expected: `True`  
If `False`: Labels will not appear on SharePoint files/sites. Enable:
```powershell
Set-SPOTenant -EnableAIPIntegration $true
```

**5. Check the MIP Sync Service in Entra ID (M365 Apps built-in labeling)**

Navigate to: Entra admin center → Enterprise applications → Search "Microsoft Information Protection Sync Service" → Properties: Enabled for users to sign in = Yes

If disabled: Enable it. This is required for Office apps to retrieve label policies.

**6. Force policy refresh on a client**
```powershell
# On the affected user's Windows machine
# For M365 Apps built-in labeling:
# Close all Office apps, then open Word/Outlook — labels reload on start

# If using AIP Unified Labeling Client (legacy):
Set-AIPAuthentication -Reset
```

---

## Common Fix Paths

<details><summary>Fix 1 — User sees no labels in Office apps</summary>

**Most likely cause:** User not targeted by any label policy, or MIP Sync Service disabled.

```powershell
Connect-IPPSSession

# Step 1: List all label policies and check if any target this user
Get-LabelPolicy | Format-Table Name, Enabled

# Step 2: Add user to an existing policy
# (Cannot be done via PowerShell directly — use Purview portal)
# Purview portal → Information protection → Label policies → select policy → Edit → Choose users and groups

# OR — if scripting via PowerShell (existing policy, add a group):
# Note: You can set policy to "All" to include everyone:
Set-LabelPolicy -Identity "<PolicyName>" -AddExchangeLocation "All"

# Step 3: After policy change, wait up to 24h or have user restart Office apps
Write-Host "Policy updated. User should restart Office apps and wait up to 24h for full propagation."
```

**Rollback:** Remove the user/group from the policy if the change was made in error.

</details>

<details><summary>Fix 2 — Labels visible in Word/Excel but NOT in Outlook</summary>

**Most likely cause:** Label's `ContentType` does not include `Email`.

```powershell
Connect-IPPSSession

# Check label ContentType
Get-Label -Identity "<LabelName>" | Select-Object Name, ContentType

# If ContentType = "File" only, it won't appear in Outlook
# ContentType should include "Email" for Outlook visibility
# Fix: Edit label in Purview portal → Scope → check "Emails" checkbox

# Verify after change (allow up to 24h):
Get-Label -Identity "<LabelName>" | Select-Object Name, ContentType
```

**Note:** Label scope changes require all users to restart Outlook to pick up the new scope.

</details>

<details><summary>Fix 3 — Label applied in Word but encryption breaks opening the file</summary>

**Most likely cause:** Encryption configured to apply but user's account lacks the Rights Management license, or the label encrypts to a specific user/group the current user is not in.

```powershell
Connect-IPPSSession

# Check what encryption settings the label applies
Get-Label -Identity "<LabelName>" | Select-Object Name, EncryptionEnabled, EncryptionRightsDefinitions,
    EncryptionOfflineAccessDays, EncryptionDoNotForward

# EncryptionRightsDefinitions shows who can access encrypted content
# If the user opening the file is not in that list, they will be denied

# Check if user has RMS/AIP license
Connect-MgGraph -Scopes "User.Read.All"
$user = Get-MgUser -Filter "userPrincipalName eq '<user@domain.com>'" -Property AssignedLicenses
# Look for Azure Information Protection Plan 1/2 or M365 E3/E5 (includes AIP)

# Temporary workaround: Have file owner re-save with a less restrictive label
# Permanent fix: Add affected user/group to the label's encryption rights in Purview portal
```

</details>

<details><summary>Fix 4 — SharePoint site label not applying / sharing settings not enforced</summary>

**Most likely cause:** AIP integration not enabled on tenant, or label not configured with Groups & Sites scope.

```powershell
Connect-SPOService -Url https://<tenant>-admin.sharepoint.com

# Check if AIP integration is enabled
$aip = (Get-SPOTenant).EnableAIPIntegration
Write-Host "AIP Integration: $aip"

if (-not $aip) {
    Write-Host "Enabling AIP integration..." -ForegroundColor Yellow
    Set-SPOTenant -EnableAIPIntegration $true
    Write-Host "Done. Allow up to 24h for labels to appear on sites."
}

# Verify label has Groups & Sites scope (check in Purview portal):
# Information protection → Labels → select label → Edit → Scope → Groups & Sites must be checked

# To apply a sensitivity label to an existing SharePoint site:
Connect-PnPOnline -Url "https://<tenant>.sharepoint.com/sites/<sitename>" -Interactive
Set-PnPSite -SensitivityLabel "<LabelGUID>"
# Get label GUID from: Get-Label | Select-Object Name, ImmutableId
```

**Rollback:**
```powershell
# Remove label from site:
Set-PnPSite -SensitivityLabel $null
```

</details>

<details><summary>Fix 5 — Auto-labeling policy not applying labels</summary>

**Most likely cause:** Policy in simulation mode; conditions not matching; policy scope issue.

```powershell
Connect-IPPSSession

# Check auto-labeling policies and their mode
Get-AutoSensitivityLabelPolicy | Select-Object Name, Enabled, Mode, Priority | Format-Table
# Mode: TestWithoutNotifications / TestWithNotifications = simulation mode (does not apply labels)
# Mode: Enable = active

# If policy is in simulation mode and ready to enable:
Set-AutoSensitivityLabelPolicy -Identity "<PolicyName>" -Mode Enable

# Check policy simulation results in Purview portal:
# Information protection → Auto-labeling → select policy → Simulation results

# Check what conditions the policy uses:
Get-AutoSensitivityLabelRule -Policy "<PolicyName>" |
    Select-Object Name, SensitiveInformationTypes, ContentContainsSensitiveInformation | Format-List
```

**Note:** Auto-labeling policies operate as background service-side scanning. For new content, labels apply within minutes to hours. For existing content, a "crawl all existing items" must be triggered.

</details>

---

## Escalation Evidence

Copy and fill in for a ticket to Microsoft Support or internal escalation:

```
SENSITIVITY LABELS — ESCALATION EVIDENCE
==========================================
Date/Time:          ___________________
Tenant ID:          ___________________  (Get from Entra ID → Overview)
Affected User(s):   ___________________
Issue Description:  ___________________

--- Label Details ---
Label Name:         ___________________
Label GUID (ImmutableId): ___________  (Get-Label -Identity "<name>" | Select ImmutableId)
Label ContentType:  ___________________  (Get-Label -Identity "<name>" | Select ContentType)
Label IsEnabled:    ___________________

--- Policy Details ---
Policy Name:        ___________________
Policy Enabled:     ___________________  (Get-LabelPolicy | Select Enabled)
Policy Targets:     ___________________ (All users / specific groups)
Policy LastModified: __________________

--- Environment ---
Office App version: ___________________  (File → Account → About Word/Outlook)
AIP Client installed? (Y/N / version): ___
Built-in labeling or AIP Client: _______
EnableAIPIntegration (SPO tenant): _____

--- Steps Already Tried ---
1. ___________________
2. ___________________
3. ___________________

--- Error Messages ---
(screenshot or exact text)
___________________

--- Purview Compliance portal URL of affected policy ---
https://compliance.microsoft.com/...
```

---

## 🎓 Learning Pointers

- **Label policies are the delivery mechanism — labels are the definitions.** A label can exist but be completely invisible if no policy publishes it to users. Every "user can't see labels" ticket starts with checking label policies (`Get-LabelPolicy`) and their scope. Creating a label in Purview without a policy is a silent no-op.  
  → [MS Docs: Publish sensitivity labels](https://learn.microsoft.com/en-us/purview/sensitivity-labels#what-label-policies-can-do)

- **Built-in labeling in M365 Apps replaced the AIP Unified Labeling client.** The AIP UL add-in is retired (April 2024 for mainstream, later for extended). Tenants still running the AIP add-in should plan migration to built-in labeling. Built-in labeling is natively in Office 2019/M365 Apps and requires no add-in installation.  
  → [MS Docs: AIP add-in retirement](https://learn.microsoft.com/en-us/purview/sensitivity-labels-office-apps#labeling-client-for-desktop-apps)

- **Encryption and external sharing interact.** A sensitivity label that applies encryption will prevent external users from opening encrypted files unless they are explicitly included in the label's Rights Management permissions or authenticate via a Microsoft account. Design label scopes carefully when external sharing is a business requirement.  
  → [MS Docs: Restrict access to content by using sensitivity labels to apply encryption](https://learn.microsoft.com/en-us/purview/encryption-sensitivity-labels)

- **Policy propagation can take up to 24 hours.** New or modified label policies do not appear instantly in Office apps. In urgent cases, have the user restart all Office apps and wait — do not pile on additional policy changes trying to "force" it faster. Multiple rapid policy changes can compound propagation delays.  
  → [MS Docs: How long does it take for labels to take effect](https://learn.microsoft.com/en-us/purview/sensitivity-labels-office-apps#how-long-before-label-changes-take-effect)

- **Site labels control SharePoint sharing behavior, not just visual classification.** A sensitivity label applied to a SharePoint site can enforce external sharing restrictions, Teams guest access settings, and device access policies — even if the user hasn't set those site settings manually. This makes site labels a powerful governance tool but also a source of "why can't I share this site?" tickets.  
  → [MS Docs: Use sensitivity labels to protect content in Microsoft Teams, M365 Groups, and SharePoint sites](https://learn.microsoft.com/en-us/purview/sensitivity-labels-teams-groups-sites)

- **Auto-labeling is not the same as mandatory labeling.** Mandatory labeling (label policy setting) requires users to apply a label before saving — it fires on the client. Auto-labeling (auto-sensitivity label policies) is a service-side scanner that applies labels to SharePoint/OneDrive/Exchange content in the background. They serve different purposes and must be configured separately.  
  → [MS Docs: Apply sensitivity labels automatically](https://learn.microsoft.com/en-us/purview/apply-sensitivity-label-automatically)
