# Microsoft 365 Copilot — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
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

**In scope:**
- Microsoft 365 Copilot licensing stack (base license + add-on)
- Tenant, group, and per-app Copilot policy enablement (Word, Excel, PowerPoint, Outlook, Teams)
- Microsoft Graph grounding (how Copilot decides what content it's allowed to reference)
- Semantic Index / Microsoft Search indexing behavior
- Conditional Access and DLP interactions with the Copilot service principal
- Copilot Studio / plugin and connector grounding (brief, cross-reference only)

**Out of scope:**
- Azure OpenAI Service / Copilot Studio agent-building specifics (separate product surface)
- GitHub Copilot, Security Copilot, Sales/Service Copilot (different licensing SKUs entirely)
- Billing and CSP-level SKU procurement disputes
- Data security/oversharing risk assessment, prompt/response DLP, and AI-interaction monitoring for Copilot — see `Security/Purview/DSPM-for-AI-A.md`/`-B.md` (this file covers Copilot licensing/enablement/grounding; DSPM covers what Copilot can see and expose, and how that risk is monitored/remediated)

**Assumptions:**
- Global Reader or Global Administrator role for read operations; License Administrator + User Administrator for write operations
- Microsoft Graph PowerShell SDK (`Microsoft.Graph`) v2.x installed
- Microsoft Teams PowerShell module (`MicrosoftTeams`) installed for Copilot policy cmdlets
- Tenant has at least one Microsoft 365 Copilot add-on SKU purchased

---

## How It Works

<details><summary>Full architecture</summary>

Microsoft 365 Copilot is not a single service — it's an orchestration layer that sits on top of three independent systems: the licensing/entitlement layer, the Microsoft Graph permission layer, and the LLM orchestration layer itself.

```
User Prompt (Word / Excel / PowerPoint / Outlook / Teams / Copilot Chat)
        │
        ▼
[Entitlement Check]
  - Base M365 license (E3/E5/Business Premium/Business Standard)
  - Microsoft 365 Copilot add-on SKU
  - Tenant-level and per-app Copilot policy state
        │
        ▼
[Conditional Access Gate]
  - Evaluates sign-in to the Copilot / Microsoft 365 Chat service principal
  - Same CA engine as any other cloud app — device compliance, location, MFA can all apply
        │
        ▼
[Orchestrator]
  - Decomposes the prompt into sub-tasks
  - Decides which "skills" to invoke (calendar lookup, document search, web grounding if enabled)
        │
        ▼
[Microsoft Graph Grounding]
  - Queries Microsoft Search / Semantic Index for relevant SharePoint, OneDrive, Exchange,
    and Teams content
  - CRITICAL: only returns content the calling USER already has permission to see —
    Copilot inherits the requesting user's effective permissions, it does not have its own
    elevated access
        │
        ▼
[Purview / DLP Check]
  - Sensitivity-label-aware policies can restrict Copilot from summarizing or referencing
    labeled content (a distinct DLP policy type: "Microsoft 365 Copilot")
        │
        ▼
[LLM Processing]
  - Retrieved content + prompt sent to the underlying model
  - Response generated with citations back to source documents
        │
        ▼
[Response rendered in host app, with grounding citations]
```

**Why grounding failures are the #1 support ticket type:**
Copilot does not have a service account with broad read access. Every grounding query executes in the context of the calling user via delegated Graph permissions. This means:
- If SharePoint site permissions were tightened (oversharing remediation), Copilot answers get worse — this is *expected*, not a regression.
- If a user is a guest or has restricted external sharing settings, Copilot for that user only sees what they can already see.
- Search index visibility settings (site-level "hide from search") also hide content from Copilot.

**Semantic Index:**
Microsoft 365 Copilot builds a semantic index of tenant content in the background (distinct from classic keyword-based SharePoint search). New or recently modified documents may take time to appear in Copilot answers even if permissions are correct — this is an indexing lag, not a permissions or licensing fault.

**Licensing layers, precisely:**
| Layer | SKU/Object | Required? |
|-------|-----------|-----------|
| Base productivity license | Microsoft 365 E3, E5, Business Standard, Business Premium | Yes — Copilot cannot function without underlying Word/Excel/Outlook/Teams entitlement |
| Copilot add-on | `Microsoft_365_Copilot` SKU | Yes — the specific paid add-on |
| Teams Copilot policy | `TeamsCopilotPolicy` | Governs Copilot in Teams meetings/chat specifically |
| Microsoft 365 Apps admin center Copilot controls | Org-wide toggle | Can override per-app availability independent of licensing |

</details>

---

## Dependency Stack

```
Tenant-level Microsoft 365 Copilot enablement (admin center toggle)
└── SKU pool: Microsoft_365_Copilot add-on licenses purchased
    └── Base productivity license per user (E3/E5/Business Premium/Business Standard)
        └── Copilot add-on license assigned to specific user
            └── Per-app Copilot policy (TeamsCopilotPolicy / app-specific toggles) not disabled
                └── Conditional Access allows sign-in to Copilot/M365 Chat service principal
                    └── User's effective Microsoft Graph permissions (SharePoint/OneDrive/Exchange/Teams)
                        └── Purview DLP policy targeting "Microsoft 365 Copilot" does not block the content
                            └── Content is indexed by Microsoft Search / Semantic Index
                                └── Copilot returns a grounded, cited response
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Copilot icon missing from ribbon entirely | No Copilot SKU assigned, or client not yet updated | `Get-MgUserLicenseDetail`; confirm Click-to-Run channel and build |
| Copilot icon present but greyed out / errors on click | Base license missing or downgraded | Confirm base SKU (E3/E5/SPB) alongside Copilot SKU |
| "You don't have access to Copilot" at sign-in | Tenant or per-app policy disables Copilot for the user's group | `Get-CsTeamsCopilotPolicy`; Microsoft 365 admin center Copilot settings |
| Sign-in blocked / CA challenge fails repeatedly | Conditional Access policy scoped to "All cloud apps" or the Copilot app ID | `Get-MgAuditLogSignIn` filtered to the Copilot app, check `ConditionalAccessStatus` |
| Copilot responds but omits known internal documents | Grounding permission gap — user lacks direct/group SharePoint access to the file | Verify actual site/library permission, not assumed access |
| Copilot gives outdated answers for a recently edited file | Semantic Index lag | Wait for indexing cycle; confirm via a control document that indexes normally |
| Copilot silently skips summarizing a labeled document | Purview DLP policy targeting Copilot activities | Review DLP policies with location = "Microsoft 365 Copilot" |
| Works in Word/Excel but not Teams meetings | `TeamsCopilotPolicy` disabled or not assigned to the user's group | `Get-CsTeamsCopilotPolicy -Identity <policyName>` |
| Works for internal users, breaks for guests | Guest/external sharing restrictions apply the same way to Copilot grounding | Confirm guest's actual permission scope on referenced content |
| Answer quality dropped after a SharePoint sharing review | Oversharing remediation intentionally narrowed what's visible | Expected behavior — confirm with the SharePoint admin, not a Copilot bug |

---

## Validation Steps

**Step 1 — Confirm full license stack**
```powershell
Connect-MgGraph -Scopes "User.Read.All","Organization.Read.All"
Get-MgUserLicenseDetail -UserId '<UPN>' | Select-Object SkuPartNumber, SkuId
```
*Good:* Both a base SKU (`SPE_E3`, `SPE_E5`, `SPB`, etc.) and `Microsoft_365_Copilot` present.
*Bad:* Copilot SKU present without a base SKU, or base SKU present without Copilot SKU.

---

**Step 2 — Confirm tenant and per-app Copilot enablement**
```powershell
Connect-MicrosoftTeams
Get-CsTeamsCopilotPolicy -Identity Global | Select-Object Identity, CopilotEnabled
Get-CsTeamsCopilotPolicy | Select-Object Identity, CopilotEnabled
```
*Good:* Global (or the user's assigned) policy shows `CopilotEnabled: Enabled`.
*Bad:* A custom policy assigned to the user's group shows `Disabled`.

Also check: Microsoft 365 admin center > Settings > Org settings > Copilot — a tenant-wide or per-app (Word/Excel/PowerPoint/Outlook) toggle can independently override policy state.

---

**Step 3 — Confirm Conditional Access is not blocking sign-in**
```powershell
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<UPN>' and appDisplayName eq 'Microsoft 365 Copilot'" -Top 10 |
    Select-Object CreatedDateTime, ConditionalAccessStatus, AppliedConditionalAccessPolicies
```
*Good:* `ConditionalAccessStatus: success`.
*Bad:* `failure` — inspect `AppliedConditionalAccessPolicies` for the specific policy causing the block.

---

**Step 4 — Confirm actual Graph grounding permission on a specific test document**
```powershell
Connect-MgGraph -Scopes "Sites.Read.All"
Get-MgSitePermission -SiteId '<SiteId>' | Select-Object Roles, GrantedToV2
```
*Good:* The user (directly or via group) appears with read/write roles on the site containing the test document.
*Bad:* No permission entry — Copilot cannot and should not surface this content; this is expected, not a bug.

---

**Step 5 — Confirm content is indexed by Microsoft Search**
There is no direct cmdlet to query Semantic Index state per-document. Practical validation:
1. Search for the exact document title in SharePoint/OneDrive search (not Copilot) — if it doesn't appear there either, it's an indexing/visibility issue, not Copilot-specific.
2. Check the site's search visibility setting (Site Settings > Search and offline availability > "Allow this site to appear in search results").

---

**Step 6 — Confirm no Purview DLP policy is restricting Copilot**
```powershell
Connect-IPPSSession
Get-DlpCompliancePolicy | Where-Object { $_.Workload -match "Copilot" -or $_.Mode -ne $null } |
    Select-Object Name, Mode, Workload
```
*Good:* No enabled policy targeting Copilot workload for the affected content type/label.
*Bad:* An enabled policy with `Mode: Enable` scoped to Copilot and the sensitivity label on the test document.

---

## Troubleshooting Steps (by phase)

### Phase 1: Copilot Not Visible/Available At All
1. Run Step 1 — confirm both license layers are present and `ProvisioningStatus: Success`
2. Confirm the client application is on a supported, current Click-to-Run channel (Copilot features require recent monthly channel builds)
3. Run Step 2 — confirm tenant and per-app policy enablement
4. If licensed and enabled but still missing: force a Microsoft 365 Apps update and full sign-out/sign-in cycle — client-side caching of entitlement state is common

### Phase 2: Copilot Available but Blocked at Runtime
1. Run Step 3 — check sign-in logs specifically for the Copilot/M365 Chat application ID
2. Identify the specific CA policy via `AppliedConditionalAccessPolicies`
3. Confirm whether the block is intentional (e.g., unmanaged device policy) before adjusting
4. If unintentional, scope an exclusion or adjust the policy's device/location conditions

### Phase 3: Copilot Responds but Grounding Is Wrong/Incomplete
1. Run Step 4 against the specific document/mailbox/chat the user expected referenced
2. If permission is genuinely missing: this is a SharePoint/OneDrive/Exchange permissions task, not a Copilot fix
3. If permission exists but content still isn't surfaced: run Step 5 to rule out indexing/search-visibility
4. Run Step 6 to rule out a DLP policy silently suppressing the content
5. As a last resort, test with a brand-new, deliberately simple document to isolate whether the issue is content-specific or systemic

### Phase 4: Copilot Works Inconsistently Across Apps
1. Confirm per-app admin center toggles (Word/Excel/PowerPoint/Outlook can be independently disabled)
2. For Teams specifically, run Step 2's `Get-CsTeamsCopilotPolicy` — Teams uses its own policy object distinct from the general M365 Copilot toggle
3. Confirm the user isn't in two conflicting policy groups (direct assignment vs. group-based policy assignment — direct wins)

---

## Remediation Playbooks

<details><summary>Fix 1 — Full license stack repair</summary>

```powershell
Connect-MgGraph -Scopes "User.ReadWrite.All","Organization.Read.All"

$userUpn = "<UPN>"

# Confirm pool availability
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "Microsoft_365_Copilot|SPE_E3|SPE_E5|SPB" } |
    Select-Object SkuPartNumber, ConsumedUnits, @{N='Available';E={$_.PrepaidUnits.Enabled - $_.ConsumedUnits}}

# Assign both base and Copilot SKUs together to avoid a mid-state where Copilot has no base license
$baseSku    = "<BaseSkuId-GUID>"
$copilotSku = "<CopilotSkuId-GUID>"

Set-MgUserLicense -UserId $userUpn `
    -AddLicenses @(@{SkuId=$baseSku}, @{SkuId=$copilotSku}) `
    -RemoveLicenses @()
```

**Rollback:** `Set-MgUserLicense -UserId $userUpn -AddLicenses @() -RemoveLicenses @($copilotSku)` (leave base license in place unless the removal was in error).

</details>

---

<details><summary>Fix 2 — Correct tenant/per-app policy blocking Copilot</summary>

```powershell
Connect-MicrosoftTeams

# Confirm existing policies and identify the one applied to the affected group
Get-CsTeamsCopilotPolicy | Select-Object Identity, CopilotEnabled

# Grant the enabling (usually Global) policy to the user
Grant-CsTeamsCopilotPolicy -Identity "<UPN>" -PolicyName "Global"
```

Also check Microsoft 365 admin center > Settings > Org settings > Copilot for per-app (Word/Excel/PowerPoint/Outlook) toggles — these are separate from the Teams policy object and are UI-only (no dedicated cmdlet as of this writing).

**Rollback:** Re-grant the previous restrictive policy name if the block was intentional.

</details>

---

<details><summary>Fix 3 — Resolve Conditional Access block</summary>

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess"

# Identify policies scoped to all apps or the Copilot service principal
Get-MgIdentityConditionalAccessPolicy |
    Where-Object { $_.Conditions.Applications.IncludeApplications -contains "All" -or
                   $_.Conditions.Applications.IncludeApplications -contains "<CopilotAppId>" } |
    Select-Object Id, DisplayName, State

# Example: add a group-based exclusion for a specific policy
$policyId = "<PolicyId>"
Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policyId -BodyParameter @{
    Conditions = @{
        Users = @{
            ExcludeGroups = @("<ExclusionGroupObjectId>")
        }
    }
}
```

**Rollback:** Remove the exclusion group from the policy once the underlying access issue (e.g., unmanaged device) is resolved properly.

</details>

---

<details><summary>Fix 4 — Fix grounding/permission or indexing gaps</summary>

Use when licensing, policy, and CA all check out but Copilot gives wrong/incomplete answers.

```powershell
Connect-MgGraph -Scopes "Sites.ReadWrite.All"

# Confirm and, if needed, correct the user's actual site permission
Get-MgSitePermission -SiteId '<SiteId>'

# Grant read access if legitimately missing (do not use Copilot as the reason to over-grant access —
# grant only what the user should have per data governance policy)
```

If indexing is the suspected cause, there is no supported cmdlet to force re-indexing on demand; document the delay and re-test after 24-48 hours, escalating to Microsoft Support with the Evidence Pack if content still doesn't surface after that window.

**Rollback:** N/A — this is a permission/governance correction, reverse only if access was granted in error.

</details>

---

<details><summary>Fix 5 — Adjust a DLP policy suppressing Copilot access to labeled content</summary>

```powershell
Connect-IPPSSession

Get-DlpCompliancePolicy | Where-Object { $_.Workload -match "Copilot" } |
    Select-Object Name, Mode, Workload

# Review the specific rule blocking Copilot activity for the sensitivity label in question
Get-DlpComplianceRule -Policy "<PolicyName>" | Select-Object Name, ContentContainsSensitiveInformation, BlockAccess
```

Adjust the rule scope in the Purview compliance portal (Data Loss Prevention > Policies) if the restriction is broader than intended — for example, blocking Copilot from referencing a label that should be summarizable internally.

**Rollback:** Revert to the previous rule configuration; DLP changes should go through the standard compliance change process, not be reversed casually.

</details>

---

## Evidence Pack

```powershell
<#
  Microsoft 365 Copilot Evidence Collector
  Run before escalating to Microsoft Support.
#>
Connect-MgGraph -Scopes "User.Read.All","Organization.Read.All","Sites.Read.All"

$userUpn = Read-Host "Enter UPN"
$outPath = "$env:TEMP\Copilot-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
$sb = [System.Text.StringBuilder]::new()

$null = $sb.AppendLine("=== MICROSOFT 365 COPILOT EVIDENCE PACK ===")
$null = $sb.AppendLine("UPN: $userUpn")
$null = $sb.AppendLine("Collected: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC")
$null = $sb.AppendLine("")

# License stack
$null = $sb.AppendLine("--- License Stack ---")
Get-MgUserLicenseDetail -UserId $userUpn | ForEach-Object {
    $null = $sb.AppendLine("SKU: $($_.SkuPartNumber)")
}
$null = $sb.AppendLine("")

# Recent sign-ins to Copilot app
$null = $sb.AppendLine("--- Recent Copilot Sign-Ins ---")
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$userUpn' and appDisplayName eq 'Microsoft 365 Copilot'" -Top 5 |
    ForEach-Object {
        $null = $sb.AppendLine("  $($_.CreatedDateTime) | CA: $($_.ConditionalAccessStatus)")
    }
$null = $sb.AppendLine("")

$sb.ToString() | Out-File $outPath -Encoding UTF8
Write-Host "Evidence written to: $outPath" -ForegroundColor Green
notepad $outPath
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check license stack | `Get-MgUserLicenseDetail -UserId <UPN>` |
| Check tenant/policy Copilot state | `Get-CsTeamsCopilotPolicy -Identity Global` |
| Grant Copilot policy to user | `Grant-CsTeamsCopilotPolicy -Identity <UPN> -PolicyName Global` |
| Check CA sign-in status for Copilot | `Get-MgAuditLogSignIn -Filter "appDisplayName eq 'Microsoft 365 Copilot'"` |
| Check site permission for grounding | `Get-MgSitePermission -SiteId <SiteId>` |
| Check DLP policies scoped to Copilot | `Get-DlpCompliancePolicy \| Where Workload -match "Copilot"` |
| Check available Copilot SKU units | `Get-MgSubscribedSku \| Where SkuPartNumber -match "Microsoft_365_Copilot"` |
| Assign Copilot + base license together | `Set-MgUserLicense -UserId <UPN> -AddLicenses @(@{SkuId=<Base>},@{SkuId=<Copilot>})` |
| Remove Copilot license | `Set-MgUserLicense -UserId <UPN> -AddLicenses @() -RemoveLicenses @(<CopilotSkuId>)` |
| List all Teams Copilot policies | `Get-CsTeamsCopilotPolicy` |
| Check DLP rule detail | `Get-DlpComplianceRule -Policy <PolicyName>` |

---

## 🎓 Learning Pointers

- **Copilot has no elevated service account.** Every grounding query runs as the calling user via delegated Graph permissions. If you find yourself wanting to "give Copilot access" to something, what you actually need to do is give the *user* access — Copilot is a lens, not an independent identity. [MS Docs: Microsoft 365 Copilot data, privacy, and security](https://learn.microsoft.com/en-us/copilot/microsoft-365/microsoft-365-copilot-privacy)

- **Two license layers, assigned together, avoid a broken mid-state.** Assigning the Copilot add-on SKU without a base productivity SKU (or vice versa) leaves the user in a state where the ribbon icon may appear but functionality silently fails. Always assign both in the same operation when provisioning new Copilot users. [MS Docs: Microsoft 365 Copilot requirements](https://learn.microsoft.com/en-us/copilot/microsoft-365/microsoft-365-copilot-requirements)

- **Oversharing remediation and Copilot rollout often collide.** Many organizations run a SharePoint oversharing review around the same time they roll out Copilot. A sudden drop in "Copilot knows about X" reports right after such a review is very often expected behavior, not a regression — confirm with the SharePoint admin before treating it as a bug. [MS Docs: Prepare your organization for Copilot](https://learn.microsoft.com/en-us/copilot/microsoft-365/microsoft-365-copilot-readiness)

- **Semantic Index lag is a real, separate failure mode from permissions.** A document can have perfectly correct permissions and still not surface in Copilot answers for a period after creation/modification. Rule this out with a search-visibility test before concluding it's a permissions bug.

- **DLP for Copilot is a distinct workload type in Purview**, not an extension of general SharePoint/Exchange DLP. If sensitivity-labeled content mysteriously stops being summarized, check `Get-DlpCompliancePolicy` for policies explicitly scoped to the Copilot workload. [MS Docs: Data loss prevention and Microsoft 365 Copilot](https://learn.microsoft.com/en-us/purview/dlp-microsoft-365-copilot)

- **`TeamsCopilotPolicy` is separate from the general M365 Copilot toggle.** A user can be fully licensed and enabled everywhere else but blocked specifically in Teams meetings/chat if this policy isn't assigned correctly — always check it independently rather than assuming Teams inherits the general Copilot state. [MS Docs: Manage Copilot policies in Teams](https://learn.microsoft.com/en-us/microsoftteams/teams-copilot-policies)
