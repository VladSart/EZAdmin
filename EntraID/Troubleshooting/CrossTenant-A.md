# Cross-Tenant Access Settings — Reference Runbook (Mode A: Deep Dive)
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
- Entra ID External Identities → Cross-Tenant Access Settings (XTAS)
- Inbound and outbound B2B collaboration controls
- B2B direct connect (Teams Shared Channels)
- Cross-tenant synchronisation (multi-tenant org / XTS)
- Conditional Access policies interacting with cross-tenant users
- Trust settings (MFA claims, compliant device, Hybrid-Joined device)

**Not in scope:**
- Azure AD B2C (separate product)
- Classic Azure AD B2B (legacy policies pre-XTAS)
- Azure Lighthouse (separate cross-tenant delegation model)

**Assumed knowledge:**
- Comfortable with Entra ID admin portal and Graph API
- Understands B2B invitation flow at concept level
- Has Global Admin or Security Admin rights

---

## How It Works

<details><summary>Full architecture</summary>

Cross-Tenant Access Settings (XTAS) replaced the legacy External Collaboration Settings as the primary control plane for B2B traffic in 2022. It operates at two layers:

```
┌─────────────────────────────────────────────────────────────────┐
│  Tenant A (Home / Resource Tenant — depends on scenario)        │
│                                                                 │
│  ┌─────────────────────┐    ┌──────────────────────────────┐   │
│  │  Default Policy     │    │  Partner-Specific Policy      │   │
│  │  (Org-level)        │    │  (per tenant GUID)            │   │
│  │  • Inbound B2B      │    │  • Overrides default          │   │
│  │  • Outbound B2B     │    │  • Can be more OR less        │   │
│  │  • Direct Connect   │    │    permissive than default    │   │
│  │  • Trust settings   │    │  • Applied by tenantId match  │   │
│  └─────────────────────┘    └──────────────────────────────┘   │
│                                                                 │
│  Evaluation order:                                              │
│  1. Is there a partner-specific policy for homeTenantId?        │
│     YES → use that policy entirely (no merging with default)    │
│     NO  → use default policy                                    │
└─────────────────────────────────────────────────────────────────┘
```

### Inbound vs. Outbound — which tenant controls what

| Scenario | Controlling tenant | Policy type |
|---|---|---|
| External user (from Tenant B) signing into Tenant A resource | **Tenant A** | Inbound |
| Tenant A user signing into Tenant B resource | **Tenant B** | Inbound (from Tenant B's view) / Tenant A controls with Outbound |
| Tenant A admin limits where their users can go | **Tenant A** | Outbound |

Key insight: **both the resource tenant (inbound) and the home tenant (outbound) can block a cross-tenant session independently.** A failure can come from either side.

### Trust settings — what they mean

Trust settings tell the resource tenant to honour claims from the home tenant rather than re-challenging:

| Trust setting | What it skips |
|---|---|
| Trust MFA | Does not issue a new MFA challenge if home tenant already completed MFA |
| Trust compliant device | Accepts Intune compliance claim from home tenant without re-checking |
| Trust Hybrid-Joined | Accepts AADJ/HAADJ claim from home tenant |

**If trust is NOT set:** The resource tenant may issue an MFA/compliance prompt the guest cannot satisfy (e.g. their device is enrolled only in the home tenant's Intune).

### Direct Connect (B2B Direct Connect)

Used by Teams Shared Channels. Unlike B2B collaboration, the external user **never gets a guest object in the resource tenant**. Authentication happens entirely in the home tenant; Entra ID in the resource tenant verifies via a federated token. Requires:
- Inbound Direct Connect allowed for the partner tenant
- Outbound Direct Connect allowed from the home tenant
- Teams policy in both tenants permitting Shared Channels

### Cross-Tenant Synchronisation (XTS / Multi-Tenant Org)

XTS pushes user objects from a source tenant into a target tenant as B2B members (not guests). Used in multi-subsidiary orgs. Requires:
- Inbound policy in target tenant with "Allow cross-tenant sync" enabled (separate toggle from B2B collab)
- A Sync configuration app/service principal in source tenant
- Provisioning scope rules defining which users sync

</details>

---

## Dependency Stack

```
Microsoft Teams Shared Channels
        │
        ▼
B2B Direct Connect (XTAS)
        │
        ▼
Cross-Tenant Access Settings (partner-specific OR default policy)
        │
        ├── Inbound controls (resource tenant)
        │       ├── B2B Collaboration allowed users/groups/all
        │       ├── B2B Direct Connect allowed (org-level toggle)
        │       └── Trust settings (MFA / compliant device / HAADJ)
        │
        ├── Outbound controls (home tenant)
        │       ├── B2B Collaboration allowed users/groups/all
        │       ├── B2B Direct Connect allowed
        │       └── Application scope (all apps / specific app IDs)
        │
        ├── Entra ID External Collaboration Settings (legacy override)
        │       └── Guest invite restrictions (still applies to invitations)
        │
        └── Conditional Access Policies
                ├── Applied at resource tenant sign-in
                ├── May require MFA / compliant device
                └── Trust settings determine if home-tenant claims satisfy these
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Guest gets AADSTS50020 "User from identity provider does not exist" | Guest object not in resource tenant / invitation not redeemed | Check guest object in resource tenant Entra portal |
| Guest gets AADSTS165000 "Cross-tenant access blocked by policy" | Inbound XTAS blocks the home tenant OR outbound policy blocks leaving | Check both tenants' XTAS default + partner-specific policies |
| Teams Shared Channel shows error "This channel isn't available" to external member | B2B Direct Connect not enabled in one or both tenants | Verify inbound + outbound Direct Connect for partner TenantId |
| MFA loop for guest (keeps asking MFA every session) | Trust MFA not enabled in resource tenant's inbound policy | Enable "Trust MFA from Microsoft Entra multifactor authentication" in inbound settings |
| Guest compliant-device CA policy blocks them | Intune compliance not trusted cross-tenant | Enable "Require device to be marked as compliant" trust in inbound settings |
| Cross-tenant sync users appear as External instead of Member | XTS "userType" override not set to Member | Check provisioning attribute mapping in source tenant XTS app |
| XTS provisioning shows errors in audit log | Inbound XTAS in target doesn't have "Allow cross-tenant sync" enabled | Enable cross-tenant sync toggle in target tenant inbound settings |
| External user can access some apps but not others | Application scope in outbound policy restricts specific app IDs | Review outbound application scope — may be limited to specific apps |
| Guest invited but can't redeem link | External Collaboration Settings → guest invite restrictions | Check if invite redemption requires internal sponsor or is blocked |

---

## Validation Steps

### Step 1 — Enumerate current XTAS policies

```powershell
Connect-MgGraph -Scopes "Policy.Read.All"

# Get default policy
$default = Get-MgPolicyCrossTenantAccessPolicyDefault
$default | ConvertTo-Json -Depth 10

# Get all partner-specific policies
$partners = Get-MgPolicyCrossTenantAccessPolicyPartner
$partners | Select-Object TenantId, DisplayName | Format-Table
```

**Good output:** Default policy shows explicit allow/block settings. Partners list shows any tenant-specific overrides.
**Bad output:** Error `Insufficient privileges` — need `Policy.Read.All` or Global Reader. Blank inbound/outbound objects mean "inherits default" (which may itself be unset/block-all).

---

### Step 2 — Check a specific partner policy

```powershell
$partnerTenantId = "<partnerTenantId>"
$partner = Get-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerTenantId $partnerTenantId
$partner | ConvertTo-Json -Depth 10
```

**Good output:** `b2bCollaborationInbound.usersAndGroups.accessType = "allowed"` and relevant sections populated.
**Bad output:** 404 → no partner-specific policy exists, default applies. Null sections → unset (inherits default — verify default).

---

### Step 3 — Verify trust settings

```powershell
$inbound = $partner.InboundTrust
$inbound | Format-List
# Or for default:
$default.InboundTrust | Format-List
```

**Good:** `IsMfaTrusted = True`, `IsCompliantDeviceTrusted = True` (if your CA requires compliance).
**Bad:** All false while CA policy at resource tenant demands MFA/compliant device → guest MFA/compliance loop.

---

### Step 4 — Confirm Direct Connect status

```powershell
# Check inbound Direct Connect for a partner
$partner.B2bDirectConnectInbound | ConvertTo-Json
# Should show usersAndGroups.accessType = "allowed" and applications.accessType = "allowed"
```

**Good:** Both `usersAndGroups` and `applications` accessType = "allowed".
**Bad:** Either is "blocked" or null → Teams Shared Channels will fail for this partner.

---

### Step 5 — Check sign-in logs for blocked cross-tenant attempts

```powershell
Connect-MgGraph -Scopes "AuditLog.Read.All"

$filter = "crossTenantAccessType ne 'none' and status/errorCode ne 0"
Get-MgAuditLogSignIn -Filter $filter -Top 50 |
    Select-Object CreatedDateTime, UserPrincipalName, 
                  @{N="HomeTenant";E={$_.HomeTenantId}},
                  @{N="ResourceTenant";E={$_.ResourceTenantId}},
                  @{N="Error";E={$_.Status.FailureReason}},
                  CrossTenantAccessType |
    Format-Table -AutoSize
```

**Good:** No failures or failures for known unrelated users.
**Bad:** Repeated AADSTS165000 / AADSTS50020 for specific home tenant IDs → review XTAS policy for that TenantId.

---

### Step 6 — Verify XTS (Cross-Tenant Sync) provisioning config (if applicable)

```powershell
# In the SOURCE tenant — list XTS service principals
Get-MgServicePrincipal -Filter "tags/any(t: t eq 'WindowsAzureActiveDirectoryIntegratedApp')" -All |
    Where-Object { $_.DisplayName -match "Cross-Tenant" } |
    Select-Object DisplayName, Id, AppId
```

In the **target tenant**, confirm the inbound sync toggle via portal: Entra ID → External Identities → Cross-tenant access → partner row → Inbound → Cross-tenant sync → "Allow users sync into this tenant" = Enabled.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Identify which side is blocking

1. Ask the affected user for the full error code (AADSTS code) from the browser.
2. AADSTS165000 = resource tenant (inbound) or home tenant (outbound) XTAS blocking.
3. AADSTS50020 = user object problem (not invited / invitation not redeemed).
4. Access the **resource tenant's** Entra sign-in logs — find the failed sign-in, note `homeTenantId`.
5. Check resource tenant XTAS for that `homeTenantId` → is inbound allowed?
6. If inbound is fine, the block may be in the **home tenant's outbound** policy — requires an admin from the home tenant to check.

### Phase 2 — Fix inbound policy (resource tenant)

If the resource tenant is blocking:
- If the partner has no specific policy → update the **default** inbound policy, or add a partner-specific entry.
- If the partner has a specific policy → update that entry's inbound section.
- After saving, test can take 5–15 minutes to propagate.

### Phase 3 — Fix outbound policy (home tenant)

The home tenant admin must:
- Check Entra ID → External Identities → Cross-tenant access → Outbound.
- Verify the target tenant's partner-specific entry (or default outbound) allows the application being accessed.
- If "All applications" is set, all apps are allowed. If specific apps are listed, the target app's `clientId` must be included.

### Phase 4 — Fix MFA / compliance trust loops

1. In the **resource tenant**, navigate to the partner's inbound settings → Trust settings.
2. Enable: "Trust multifactor authentication from Microsoft Entra multifactor authentication" — resolves MFA loops.
3. Enable: "Require device to be marked as compliant" trust — resolves Intune compliance loops for cross-tenant users.
4. Note: enabling trust doesn't lower security; it just accepts the home tenant's already-performed enforcement.

### Phase 5 — Fix Teams Shared Channels (Direct Connect)

Both tenants must have Direct Connect enabled for each other:

**Resource tenant (inbound):**
1. Entra ID → External Identities → Cross-tenant access → partner row → Inbound → B2B direct connect.
2. Set "External users and groups" = Allow all, "External applications" = Allow all (or scope to Teams app ID: `cc15fd57-2c6c-4117-a88c-83b1d56b4bbe`).

**Home tenant (outbound):**
1. Same path → Outbound → B2B direct connect.
2. Set both sections to Allow (or allow Teams specifically).

---

## Remediation Playbooks

<details><summary>Playbook 1 — Add partner-specific inbound B2B collaboration policy</summary>

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.CrossTenantAccess"

$partnerTenantId = "<partnerTenantId>"

$params = @{
    TenantId = $partnerTenantId
    B2bCollaborationInbound = @{
        UsersAndGroups = @{
            AccessType = "allowed"
            Targets    = @(@{ Target = "AllUsers"; TargetType = "user" })
        }
        Applications = @{
            AccessType = "allowed"
            Targets    = @(@{ Target = "AllApplications"; TargetType = "application" })
        }
    }
    InboundTrust = @{
        IsMfaTrusted                       = $true
        IsCompliantDeviceTrusted           = $true
        IsHybridAzureADJoinedDeviceTrusted = $true
    }
}

# Check if partner policy already exists
$existing = Get-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerTenantId $partnerTenantId -ErrorAction SilentlyContinue

if ($existing) {
    Write-Host "Updating existing partner policy for $partnerTenantId" -ForegroundColor Yellow
    Update-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerTenantId $partnerTenantId -BodyParameter $params
} else {
    Write-Host "Creating new partner policy for $partnerTenantId" -ForegroundColor Green
    New-MgPolicyCrossTenantAccessPolicyPartner -BodyParameter $params
}

Write-Host "Done. Allow 5–15 minutes for propagation." -ForegroundColor Cyan
```

**Rollback:**
```powershell
Remove-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerTenantId $partnerTenantId
# This removes the partner-specific policy; default policy applies again.
```

</details>

<details><summary>Playbook 2 — Enable B2B Direct Connect for Teams Shared Channels</summary>

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.CrossTenantAccess"

$partnerTenantId = "<partnerTenantId>"
# Teams application ID (constant across all tenants)
$teamsAppId = "cc15fd57-2c6c-4117-a88c-83b1d56b4bbe"

$directConnectParams = @{
    B2bDirectConnectInbound = @{
        UsersAndGroups = @{
            AccessType = "allowed"
            Targets    = @(@{ Target = "AllUsers"; TargetType = "user" })
        }
        Applications = @{
            AccessType = "allowed"
            Targets    = @(@{ Target = $teamsAppId; TargetType = "application" })
        }
    }
    B2bDirectConnectOutbound = @{
        UsersAndGroups = @{
            AccessType = "allowed"
            Targets    = @(@{ Target = "AllUsers"; TargetType = "user" })
        }
        Applications = @{
            AccessType = "allowed"
            Targets    = @(@{ Target = $teamsAppId; TargetType = "application" })
        }
    }
}

$existing = Get-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerTenantId $partnerTenantId -ErrorAction SilentlyContinue

if ($existing) {
    Update-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerTenantId $partnerTenantId -BodyParameter $directConnectParams
    Write-Host "Direct Connect enabled for $partnerTenantId" -ForegroundColor Green
} else {
    $directConnectParams["TenantId"] = $partnerTenantId
    New-MgPolicyCrossTenantAccessPolicyPartner -BodyParameter $directConnectParams
    Write-Host "Partner policy created with Direct Connect for $partnerTenantId" -ForegroundColor Green
}
```

**Note:** The home tenant admin must perform the equivalent outbound change for Teams Shared Channels to work. This script handles the resource/inbound side only.

</details>

<details><summary>Playbook 3 — Audit all XTAS policies and export report</summary>

```powershell
Connect-MgGraph -Scopes "Policy.Read.All"

$report = [System.Collections.Generic.List[PSCustomObject]]::new()

# Default policy
$default = Get-MgPolicyCrossTenantAccessPolicyDefault
$report.Add([PSCustomObject]@{
    TenantId        = "DEFAULT"
    DisplayName     = "Default Policy"
    InboundB2B      = $default.B2bCollaborationInbound.UsersAndGroups.AccessType
    OutboundB2B     = $default.B2bCollaborationOutbound.UsersAndGroups.AccessType
    InboundDC       = $default.B2bDirectConnectInbound.UsersAndGroups.AccessType
    OutboundDC      = $default.B2bDirectConnectOutbound.UsersAndGroups.AccessType
    TrustMFA        = $default.InboundTrust.IsMfaTrusted
    TrustCompliant  = $default.InboundTrust.IsCompliantDeviceTrusted
    TrustHAADJ      = $default.InboundTrust.IsHybridAzureADJoinedDeviceTrusted
})

# Partner policies
$partners = Get-MgPolicyCrossTenantAccessPolicyPartner
foreach ($p in $partners) {
    $report.Add([PSCustomObject]@{
        TenantId        = $p.TenantId
        DisplayName     = $p.DisplayName
        InboundB2B      = $p.B2bCollaborationInbound.UsersAndGroups.AccessType
        OutboundB2B     = $p.B2bCollaborationOutbound.UsersAndGroups.AccessType
        InboundDC       = $p.B2bDirectConnectInbound.UsersAndGroups.AccessType
        OutboundDC      = $p.B2bDirectConnectOutbound.UsersAndGroups.AccessType
        TrustMFA        = $p.InboundTrust.IsMfaTrusted
        TrustCompliant  = $p.InboundTrust.IsCompliantDeviceTrusted
        TrustHAADJ      = $p.InboundTrust.IsHybridAzureADJoinedDeviceTrusted
    })
}

$outputPath = "C:\Temp\XTAS-Report-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
$report | Export-Csv -Path $outputPath -NoTypeInformation
Write-Host "Report saved to $outputPath" -ForegroundColor Green
$report | Format-Table -AutoSize
```

</details>

<details><summary>Playbook 4 — Fix cross-tenant sync (XTS) provisioning errors</summary>

**In the TARGET tenant — enable cross-tenant sync inbound:**

```powershell
# This must be done in the TARGET tenant where users will be synced into
Connect-MgGraph -Scopes "Policy.ReadWrite.CrossTenantAccess"

$sourceTenantId = "<sourceTenantId>"

$params = @{
    CrossTenantSyncPolicy = @{
        AllowedToSync  = $true
        UserSyncInbound = @{
            IsSyncAllowed = $true
        }
    }
}

$existing = Get-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerTenantId $sourceTenantId -ErrorAction SilentlyContinue
if ($existing) {
    Update-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerTenantId $sourceTenantId -BodyParameter $params
    Write-Host "XTS inbound sync enabled for source tenant $sourceTenantId" -ForegroundColor Green
} else {
    $params["TenantId"] = $sourceTenantId
    New-MgPolicyCrossTenantAccessPolicyPartner -BodyParameter $params
    Write-Host "Partner policy created with XTS inbound sync for $sourceTenantId" -ForegroundColor Green
}
```

**Then in SOURCE tenant:** Navigate to Entra ID → External Identities → Cross-tenant synchronization → Configurations → select your config → Provisioning → Start provisioning.

</details>

---

## Evidence Pack

```powershell
# Run in the RESOURCE tenant to collect full evidence for escalation or ticket
Connect-MgGraph -Scopes "Policy.Read.All","AuditLog.Read.All"

$partnerTenantId = "<partnerTenantId>"
$affectedUPN     = "<affectedUserUPN@externalDomain>"
$outputDir       = "C:\Temp\XTAS-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm')"
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

# 1. Default XTAS policy
$default = Get-MgPolicyCrossTenantAccessPolicyDefault
$default | ConvertTo-Json -Depth 10 | Out-File "$outputDir\01-DefaultPolicy.json"

# 2. Partner-specific policy
try {
    $partner = Get-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerTenantId $partnerTenantId
    $partner | ConvertTo-Json -Depth 10 | Out-File "$outputDir\02-PartnerPolicy-$partnerTenantId.json"
} catch {
    "No partner-specific policy found for $partnerTenantId" | Out-File "$outputDir\02-PartnerPolicy-NOTFOUND.txt"
}

# 3. Recent failed cross-tenant sign-ins
$failedSignIns = Get-MgAuditLogSignIn -Filter "crossTenantAccessType ne 'none' and status/errorCode ne 0" -Top 100
$failedSignIns | Select-Object CreatedDateTime, UserPrincipalName, HomeTenantId, ResourceTenantId,
    @{N="Error";E={$_.Status.ErrorCode}}, @{N="Reason";E={$_.Status.FailureReason}}, CrossTenantAccessType |
    Export-Csv "$outputDir\03-FailedCrossTenantSignIns.csv" -NoTypeInformation

# 4. All partner policies summary
$allPartners = Get-MgPolicyCrossTenantAccessPolicyPartner
$allPartners | Select-Object TenantId, DisplayName | Export-Csv "$outputDir\04-AllPartnerPolicies.csv" -NoTypeInformation

# 5. System info
[PSCustomObject]@{
    CollectedAt         = (Get-Date).ToString("u")
    ResourceTenantId    = (Get-MgContext).TenantId
    TargetPartnerTenant = $partnerTenantId
    AffectedUser        = $affectedUPN
} | ConvertTo-Json | Out-File "$outputDir\00-CollectionMetadata.json"

Write-Host "`nEvidence collected to: $outputDir" -ForegroundColor Green
Write-Host "Files:" -ForegroundColor Cyan
Get-ChildItem $outputDir | Select-Object Name, Length | Format-Table
```

---

## Command Cheat Sheet

| Task | Command |
|---|---|
| Get default XTAS policy | `Get-MgPolicyCrossTenantAccessPolicyDefault \| ConvertTo-Json -Depth 10` |
| List all partner policies | `Get-MgPolicyCrossTenantAccessPolicyPartner` |
| Get specific partner policy | `Get-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerTenantId <tid>` |
| Create partner policy | `New-MgPolicyCrossTenantAccessPolicyPartner -BodyParameter $params` |
| Update partner policy | `Update-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerTenantId <tid> -BodyParameter $params` |
| Delete partner policy | `Remove-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerTenantId <tid>` |
| Search sign-in logs for XTAS failures | `Get-MgAuditLogSignIn -Filter "crossTenantAccessType ne 'none' and status/errorCode ne 0" -Top 50` |
| Check current Graph context/tenant | `Get-MgContext` |
| Find partner tenant ID from domain | `(Invoke-RestMethod "https://login.microsoftonline.com/<domain>/.well-known/openid-configuration").issuer` |

---

## 🎓 Learning Pointers

- **XTAS evaluation is not additive:** A partner-specific policy completely replaces the default for that tenant — there is no merging. If you create a partner entry for Tenant B with only inbound settings, the outbound settings for Tenant B revert to default (not the other way around). Document this clearly in change records. [MS Docs: Overview of cross-tenant access settings](https://learn.microsoft.com/en-us/entra/external-id/cross-tenant-access-overview)

- **Trust settings ≠ bypassing CA:** Enabling "Trust MFA" means the resource tenant accepts MFA already completed in the home tenant. The guest still authenticated with MFA — the resource tenant just doesn't re-challenge. CAPs still run at the resource tenant and still enforce their requirements. [MS Docs: Configure cross-tenant access settings for B2B collaboration](https://learn.microsoft.com/en-us/entra/external-id/cross-tenant-access-settings-b2b-collaboration)

- **Direct Connect requires both sides independently:** Even if you configure both inbound and outbound on your side, the partner tenant must do the same on their side. There's no "push" mechanism — both admins need to act. Test with the `What If` tool for sign-in or review Teams Shared Channel creation errors which surface as `DirectConnectNotEnabled`. [MS Docs: B2B direct connect overview](https://learn.microsoft.com/en-us/entra/external-id/b2b-direct-connect-overview)

- **Cross-tenant sync userType matters:** By default XTS syncs users as `Guest` members. If your target tenant needs them as `Member` (for full collaboration), you must override the `userType` attribute mapping in the source tenant's provisioning app. Changing after provisioning requires re-provisioning those users. [MS Docs: Configure cross-tenant synchronization](https://learn.microsoft.com/en-us/entra/identity/multi-tenant-organizations/cross-tenant-synchronization-configure)

- **Tenant ID lookup tip:** External users in your directory include their `homeTenantId` in sign-in logs and on the user object as `externalUserState`. You can also derive a tenant ID from a domain via the OpenID configuration endpoint: `https://login.microsoftonline.com/<domain>/.well-known/openid-configuration` — the `issuer` field contains the GUID.

- **Policy propagation delay is real:** XTAS policy changes can take 5–20 minutes to propagate. Always ask the user to wait, clear browser cache/cookies, and retry in a private window before concluding the fix didn't work. Clearing the token cache with `dsregcmd /leave` + rejoin is not applicable here (that's for device state) — just a new browser session is sufficient for guest token refresh.
