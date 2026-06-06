# DLP Policy Troubleshooting — Hotfix Runbook (Mode B: Ops)
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

Run these within the first 60 seconds to classify the problem:

```powershell
# Connect to Security & Compliance PowerShell
Connect-IPPSSession -UserPrincipalName <adminUPN>

# 1. What policies exist and are they active?
Get-DlpCompliancePolicy | Select-Object Name, Mode, Enabled, Workload | Format-Table -AutoSize

# 2. Are rules within the policy enabled?
Get-DlpComplianceRule -Policy "<PolicyName>" | Select-Object Name, Disabled, BlockAccess, NotifyUser | Format-Table -AutoSize

# 3. What did the policy do in the last 24 hours?
Get-DlpDetailReport -StartDate (Get-Date).AddDays(-1) -EndDate (Get-Date) -PageSize 100 |
    Select-Object Date, Policy, Rule, SensitiveType, Action, UserName, ObjectId |
    Sort-Object Date -Descending | Format-Table -AutoSize

# 4. Recent DLP alerts
Get-ProtectionAlert | Where-Object { $_.AlertType -eq "DLP" -and $_.LastUpdatedTime -gt (Get-Date).AddHours(-24) } |
    Select-Object Name, Severity, Count, LastUpdatedTime | Format-Table -AutoSize
```

**Interpretation:**

| Result | Likely cause | Go to |
|--------|-------------|-------|
| Policy `Mode = TestWithNotifications` or `TestWithoutNotifications` | Policy is in TEST mode — not enforcing | Fix 5 (enable policy) |
| Policy `Enabled = False` | Policy disabled entirely | Fix 5 |
| Rule `Disabled = True` | Individual rule turned off | Fix 5 |
| `Action = BlockAccess` appearing for legitimate content | False positive — SIT matching too broadly | Fix 1 |
| No entries in DlpDetailReport | Workload scoping wrong OR DLP not enabled for that workload | Fix 3 |
| Hundreds of alerts in 24 hours | Alert storm — SIT too broad or threshold too low | Fix 3 |
| Endpoint workload showing in policy but not enforcing on devices | MDE onboarding missing | Fix 4 |
| Users report block but no policy/rule matches them | User not in scope, or exclusion rule missing | Fix 2 |

---

## Dependency Cascade

<details><summary>What must be true for DLP to work</summary>

```
[DLP Policy — Enabled, Enforce mode]
    │
    ├── Policy scoped to correct workload
    │     (Exchange, SharePoint, OneDrive, Teams, Endpoint)
    │
    ├── Policy scoped to correct users/groups
    │     └── Entra groups synced and membership correct
    │
    ├── Rules within policy — at least one enabled
    │     └── Sensitive Information Type (SIT) configured correctly
    │           └── SIT has sufficient confidence level & instance count
    │
    ├── For Endpoint DLP:
    │     └── Microsoft Defender for Endpoint — device onboarded
    │           └── Windows 10 21H2+ or Windows 11
    │                 └── MDE policy: "Endpoint DLP" enabled
    │
    └── For label-based conditions:
          └── Sensitivity label published to users
                └── Label applied to content (manually or auto-labeling)
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm the policy is in Enforce mode**
```powershell
Get-DlpCompliancePolicy -Identity "<PolicyName>" | Select-Object Name, Mode, Enabled
```
Expected: `Mode = Enforce`, `Enabled = True`
Bad: `Mode = TestWithNotifications` → policy is NOT blocking, only notifying

---

**Step 2 — Confirm the rule is enabled and check its conditions**
```powershell
Get-DlpComplianceRule -Policy "<PolicyName>" | Format-List Name, Disabled, ContentContainsSensitiveInformation, BlockAccess, NotifyUser, StopPolicyProcessing
```
Expected: `Disabled = False`, `BlockAccess = True` (if blocking is intended)
Bad: `Disabled = True` → rule is off despite policy being enabled

---

**Step 3 — Check what SITs are defined in the rule**
```powershell
$rule = Get-DlpComplianceRule -Identity "<PolicyName>/<RuleName>"
$rule.ContentContainsSensitiveInformation | ConvertTo-Json -Depth 5
```
Expected: SIT name, MinCount, MaxConfidence values you recognize
Bad: Overly broad SIT (e.g. "All Full Names") with MinCount = 1 → will match almost everything

---

**Step 4 — Confirm content that triggered the rule (false positive investigation)**
In the Compliance portal: **Purview → Data Loss Prevention → Activity Explorer**
- Filter by: Policy, Date, Action
- Click individual events to see which SIT matched, what text triggered it, and the confidence score

Or via PowerShell:
```powershell
Get-DlpDetailReport -StartDate (Get-Date).AddDays(-7) -EndDate (Get-Date) -PageSize 200 |
    Where-Object { $_.UserName -eq "<user@tenant.com>" } |
    Select-Object Date, Policy, Rule, SensitiveType, Action, ObjectId | Format-Table -AutoSize
```

---

**Step 5 — Check user scope (is the affected user in/out of the policy scope?)**
```powershell
$policy = Get-DlpCompliancePolicy -Identity "<PolicyName>"
$policy.ExchangeSenderMemberOf      # Groups whose members ARE included
$policy.ExchangeSenderMemberOfException  # Groups whose members are EXCLUDED
```
Check group membership:
```powershell
Connect-MgGraph -Scopes "Group.Read.All" -NoWelcome
Get-MgGroupMember -GroupId "<groupId>" | Select-Object AdditionalProperties
```

---

**Step 6 — Endpoint DLP: confirm device is onboarded**
In MDE portal → Device inventory → find device → check "Onboarding status = Onboarded"
Or via Compliance portal: **Purview → Data Loss Prevention → Endpoint DLP settings → Device onboarding**

```powershell
# Check Intune-managed device compliance (proxy check for MDE onboarding)
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<deviceName>'" | 
    Select-Object DeviceName, ComplianceState, LastSyncDateTime, OperatingSystem
```

---

## Common Fix Paths

<details>
<summary>Fix 1 — False positive: DLP blocking legitimate content</summary>

**Symptoms:** Users report they can't send emails or share files that should be allowed. The content looks legitimate but matches a SIT.

**Step 1 — Identify the matching SIT and why it matched**
In Activity Explorer (Purview portal), view the flagged item and note:
- Which SIT matched
- The confidence level (High/Medium/Low)
- What text/pattern triggered it

**Step 2 — Raise the confidence threshold**
```powershell
Connect-IPPSSession -UserPrincipalName <adminUPN>

# Get current rule definition
$rule = Get-DlpComplianceRule -Identity "<PolicyName>/<RuleName>"
$sitConfig = $rule.ContentContainsSensitiveInformation | ConvertFrom-Json

# Increase minConfidence from 65 (Medium) to 85 (High) for the noisy SIT
# Then apply via Set-DlpComplianceRule
Set-DlpComplianceRule -Identity "<PolicyName>/<RuleName>" `
    -ContentContainsSensitiveInformation @{
        Name       = "<SIT Display Name>"
        minCount   = 1
        minConfidence = 85   # Was 65 (medium) — now only high-confidence matches
    }
```

**Step 3 — Raise the instance count**
If one match is too sensitive, require 2+ instances:
```powershell
Set-DlpComplianceRule -Identity "<PolicyName>/<RuleName>" `
    -ContentContainsSensitiveInformation @{
        Name       = "<SIT Display Name>"
        minCount   = 3   # Now requires 3+ instances to trigger
        minConfidence = 75
    }
```

**Step 4 — Add a user/domain exception**
If a specific team or partner domain should be excluded:
```powershell
# Exclude a specific sender group from the rule
Set-DlpComplianceRule -Identity "<PolicyName>/<RuleName>" `
    -ExceptIfSentToMemberOf "<GroupDisplayName>"

# Exclude a recipient domain
Set-DlpComplianceRule -Identity "<PolicyName>/<RuleName>" `
    -ExceptIfRecipientDomainIs "trustedpartner.com"
```

**Rollback:** If changes cause a compliance gap, revert minConfidence to its original value. Always document original values before changing.

</details>

<details>
<summary>Fix 2 — User incorrectly blocked (scope/exception issue)</summary>

**Symptoms:** A specific user (or team) is blocked by DLP but should be exempt.

**Step 1 — Identify the policy and rule blocking them**
Activity Explorer → filter by user → find the event → note policy and rule name

**Step 2 — Create an exclusion group in Entra ID**
```powershell
# In Entra portal: create a group "DLP-Exclusion-Finance" and add the users

# Then apply the exclusion to the policy
Set-DlpCompliancePolicy -Identity "<PolicyName>" `
    -ExchangeSenderMemberOfException "DLP-Exclusion-Finance"
```

**Step 3 — Alternatively, add an exception within the rule**
```powershell
Set-DlpComplianceRule -Identity "<PolicyName>/<RuleName>" `
    -ExceptIfSentToMemberOf "DLP-Exclusion-Finance"
```

**Note:** Policy-level exceptions apply to ALL rules. Rule-level exceptions are more targeted. For granular control, use rule-level.

**Rollback:** Remove the exception group from the policy/rule using the same `Set-DlpCompliancePolicy` command with `-ExchangeSenderMemberOfException @()` (empty array removes it).

</details>

<details>
<summary>Fix 3 — Alert storm (hundreds of alerts in short period)</summary>

**Symptoms:** Compliance portal flooded with DLP alerts. Users complaining about notifications.

**Step 1 — Identify the noisy rule**
```powershell
Get-DlpDetailReport -StartDate (Get-Date).AddDays(-1) -EndDate (Get-Date) -PageSize 500 |
    Group-Object Rule | Sort-Object Count -Descending | Select-Object -First 10 Name, Count
```

**Step 2 — Switch policy to Test mode temporarily**
```powershell
# IMMEDIATELY suppress enforcement while investigating
Set-DlpCompliancePolicy -Identity "<PolicyName>" -Mode TestWithNotifications
Write-Host "Policy switched to TEST mode — no longer blocking, only notifying" -ForegroundColor Yellow
```

**Step 3 — Investigate and tune (see Fix 1 for tuning steps)**

**Step 4 — Adjust alert threshold**
In Purview portal: **DLP → Policies → Edit → Policy tips and notifications**
- Set incident reports to aggregate: "Send alert when activity is aggregated over X instances"
- Increase the threshold from 1 event to 10+ events before alerting

**Step 5 — Re-enable enforcement after tuning**
```powershell
Set-DlpCompliancePolicy -Identity "<PolicyName>" -Mode Enforce
```

**Rollback:** If enforcement causes business disruption, revert to TestWithNotifications while continuing to tune.

</details>

<details>
<summary>Fix 4 — Endpoint DLP not enforcing on devices</summary>

**Symptoms:** DLP policy has Endpoint workload enabled, but devices aren't enforcing it. No events appearing from those devices.

**Step 1 — Confirm MDE is onboarded**
- Purview portal → **DLP → Endpoint DLP settings → Onboarded devices**
- Device must show `Onboarding status: Onboarded`
- If not onboarded: follow MDE onboarding runbook (see `Security/Defender/MDE-Onboarding-B.md`)

**Step 2 — Confirm Windows version compatibility**
```powershell
# Run on device (or via Intune device query)
[System.Environment]::OSVersion.Version
# Minimum: Windows 10 21H2 (Build 19044) for Endpoint DLP
```

**Step 3 — Check Endpoint DLP is enabled in policy**
```powershell
Get-DlpCompliancePolicy -Identity "<PolicyName>" | Select-Object Workload
# Must include "Devices" in the Workload list
```

**Step 4 — Verify Defender for Endpoint Advanced features**
In MDE portal → **Settings → Endpoints → Advanced features**
- Enable: **Microsoft Purview Data Loss Prevention** → toggle ON

**Step 5 — Check Endpoint DLP settings for browser/app restrictions**
In Purview: **DLP → Endpoint DLP settings → Browser and domain restrictions**
- Confirm restricted browsers are set correctly
- Confirm unallowed apps are listed if you want app-level control

**Rollback:** If Endpoint DLP is causing false positives on devices, switch the policy's Endpoint workload mode to Audit before going to Block.

</details>

<details>
<summary>Fix 5 — Policy in Test mode (not enforcing)</summary>

**Symptoms:** DLP policy exists, users match conditions, but nothing is being blocked. Only notifications sent.

```powershell
Connect-IPPSSession -UserPrincipalName <adminUPN>

# Check current mode
Get-DlpCompliancePolicy -Identity "<PolicyName>" | Select-Object Name, Mode

# Switch from Test to Enforce
# WARNING: This will start blocking — confirm scope is correct first
if ($PSCmdlet.ShouldProcess("<PolicyName>", "Enable DLP enforcement")) {
    Set-DlpCompliancePolicy -Identity "<PolicyName>" -Mode Enforce
    Write-Host "Policy is now enforcing." -ForegroundColor Green
}

# To enable a completely disabled policy
Set-DlpCompliancePolicy -Identity "<PolicyName>" -Enabled $true
```

**Before enabling enforcement:**
1. Review Activity Explorer in Test mode — understand who/what would be blocked
2. Confirm user communications have been sent (DLP enforcement affects productivity)
3. Confirm exceptions are in place for any known legitimate use cases
4. Have Fix 3 (alert storm) ready if the policy triggers high volume

</details>

---

## Escalation Evidence

```
TICKET ESCALATION — DLP Policy Issue
=======================================
Tenant:               [tenant name / domain]
Policy Name:          [policy name]
Rule Name:            [rule name]
Issue Type:           [False positive / Not enforcing / Alert storm / Endpoint not working]
Workload affected:    [Exchange / SharePoint / OneDrive / Teams / Endpoint]
User(s) affected:     [UPNs or group name]
First observed:       [date/time]

Policy mode:          [Enforce / TestWithNotifications / TestWithoutNotifications]
Policy enabled:       [True / False]
Rule disabled:        [True / False]

SIT triggering:       [SIT display name]
Confidence level:     [High 85 / Medium 75 / Low 65]
Instance count:       [min count configured]

Sample blocked item:  [email subject / file name / URL — anonymised]
Activity Explorer URL: [link to filtered view in Purview portal]

Actions taken so far:
  □ Checked policy mode
  □ Reviewed Activity Explorer for matching events
  □ Confirmed user is/isn't in policy scope
  □ Reviewed SIT configuration
  □ [Other]

Next recommended action: [your assessment]
```

---

## 🎓 Learning Pointers

- **Policy mode vs. rule disabled are separate controls.** A policy in `Enforce` mode with a disabled rule does nothing. A policy in `TestWithNotifications` mode with all rules enabled still doesn't block. Both must be correct. MS Docs: [Create and deploy DLP policies](https://learn.microsoft.com/en-us/purview/dlp-create-deploy-policy)

- **Activity Explorer is your best diagnostic tool.** It shows exactly which SIT matched, the confidence score, and the matched text excerpt (redacted). Use it before touching any rule settings. Access: **Purview portal → Data Loss Prevention → Activity explorer**. MS Docs: [Activity explorer](https://learn.microsoft.com/en-us/purview/data-classification-activity-explorer)

- **Endpoint DLP requires MDE onboarding — Intune enrollment is not enough.** A device can be Intune-compliant but not MDE-onboarded, meaning Endpoint DLP won't apply. The two systems overlap but are independent. MS Docs: [Get started with Endpoint DLP](https://learn.microsoft.com/en-us/purview/endpoint-dlp-getting-started)

- **SIT confidence levels exist for a reason.** Medium confidence (75) catches more but has more false positives. High confidence (85) is more precise. In regulated industries, it's tempting to set low confidence + low count — but this creates alert fatigue. Start with High confidence and tune down only with evidence. MS Docs: [Sensitive information type entity definitions](https://learn.microsoft.com/en-us/purview/sensitive-information-type-entity-definitions)

- **DLP policy priority matters when multiple policies apply.** Lower priority number = higher precedence. If a `StopPolicyProcessing` action fires in a high-priority policy, lower-priority policies won't evaluate. Use `Get-DlpCompliancePolicy | Sort-Object Priority` to understand the evaluation order. MS Docs: [DLP policy priority](https://learn.microsoft.com/en-us/purview/dlp-policy-reference#policy-priority)

- **Put policies in test mode first — always.** Even for simple policies. Run in `TestWithoutNotifications` for 3-5 days, review Activity Explorer, then switch to `TestWithNotifications` for 2-3 days, then to `Enforce`. This is the standard rollout pattern that prevents alert storms and business disruption.
