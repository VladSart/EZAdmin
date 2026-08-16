# Teams External Access, Guest Access & Shared Channels — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains the three distinct external-collaboration architectures in Teams, why they're commonly confused, and how to design/troubleshoot each correctly.

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
- Teams external access / federation (`CsTenantFederationConfiguration`, `CsExternalAccessPolicy`)
- Teams guest access (Entra B2B invite flow into full Team membership)
- Shared channels / Teams Connect via Entra B2B direct connect
- Entra ID cross-tenant access settings (inbound/outbound trust, B2B collaboration, B2B direct connect)
- Multi-tenant organization (MTO) considerations where they intersect with these three modes

**Out of scope:**
- Teams Consumer (personal Microsoft account) federation specifics beyond the on/off switch
- SharePoint/OneDrive external sharing link policies (separate runbook — `Permissions-A.md`)
- Entra ID B2B collaboration for non-Teams SaaS apps
- Multi-tenant organization (MTO) tenant-to-tenant sync setup (separate scope — cross-tenant sync, not access policy)

**Assumptions:**
- Admin has Teams Administrator (or Global Administrator) and Global Administrator or Security Administrator (for cross-tenant access policy) roles
- PowerShell: `MicrosoftTeams` module v6.x+ and `Microsoft.Graph.Identity.SignIns` module
- Tenant is running Teams-only mode (not Skype for Business hybrid)

---

## How It Works

<details><summary>Full architecture</summary>

### The Three Collaboration Models

Microsoft Teams supports three architecturally distinct ways for someone outside your organization to interact with your users. They are frequently confused because they all appear under "external collaboration" in admin conversations, but each has its own trust boundary, its own configuration surface, and its own failure modes.

**1. External Access (Federation)**
The oldest model, inherited from Skype for Business. Two organizations mutually agree (via DNS federation / Teams service discovery) to let their users chat, audio/video call, and see presence for each other — with **no** file sharing, **no** team membership, and **no** identity crossing tenant boundaries. Each user stays entirely within their own tenant's control plane. Controlled by `CsTenantFederationConfiguration` (tenant-wide) and increasingly `CsExternalAccessPolicy` (per-user/group, rolling out).

**2. Guest Access (B2B Collaboration → Team Membership)**
Built on Entra ID B2B collaboration. An external user is invited, redeems an invitation, and a **guest object is created in YOUR tenant's directory** (`userType = Guest`). That guest is then added as a member of a specific Team, gaining access to the Team's standard channels, files (via SharePoint guest permissions), and chat — essentially becoming a lightweight member of your tenant. The guest authenticates against YOUR tenant's guest object (backed by their home credentials via B2B redemption), meaning your Conditional Access policies apply to them as tenant objects.

**3. Shared Channels / Teams Connect (B2B Direct Connect)**
The newest model (GA 2022+). A specific **channel** — not a whole Team — is shared with people in another tenant using **B2B direct connect**, a cross-tenant trust mechanism that does NOT create any object in either tenant's directory. The external user authenticates entirely against their OWN home tenant and simply gets a token trusted by your tenant for that one channel's resources. No guest account, no tenant switching in the client, no B2B invite/redemption flow.

```
                    EXTERNAL ACCESS          GUEST ACCESS              SHARED CHANNELS
Object created?     None                     Guest user object         None
                                              in YOUR tenant            (federated trust only)
Identity used?       Home tenant identity      Redeemed B2B guest        Home tenant identity
                                              identity (hybrid)          (never switches)
Scope of access?     Chat/call/meet only       Full Team (all            One channel only
                                              standard channels + SP)
Config surface?       CsTenantFederation-       Entra B2B invite          Entra cross-tenant
                     Configuration /            settings + Teams          access — B2B direct
                     CsExternalAccessPolicy     Admin Center guest        connect (mutual)
                                                access toggle
Mutual required?      Yes (both tenants          No (issuing tenant       Yes (both tenants
                     must allow federation)     controls fully)          must configure)
```

### Cross-Tenant Access Settings — the Shared Backbone

Entra ID's **cross-tenant access settings** (`Get/Update-MgPolicyCrossTenantAccessPolicy*`) is the single control surface that governs BOTH guest access (B2B collaboration) AND shared channels (B2B direct connect) — but NOT external access/federation, which is governed separately by Teams' own federation configuration.

```
Cross-Tenant Access Policy
    ├── Default policy (applies to ALL external tenants unless overridden)
    │       ├── b2bCollaborationInbound / Outbound   (governs guest invites)
    │       ├── b2bDirectConnectInbound / Outbound   (governs shared channels)
    │       ├── inboundTrust (MFA / compliant device / hybrid-joined device claims)
    │       └── tenantRestrictions (outbound — what your users can access elsewhere)
    │
    └── Partner-specific policy (per external tenant ID — OVERRIDES default entirely
        for that tenant, does not merge with it)
            └── Same setting shape as default, scoped to one tenant
```

**Critical nuance:** a partner-specific entry does not layer on top of the default — it **replaces** it wholesale for that tenant. If an admin creates a partner entry that only sets `b2bCollaborationInbound` and leaves `b2bDirectConnectInbound` unset, the unset value does NOT inherit from the default policy — it typically resolves to the platform default (blocked), not your tenant's default policy. Always set every dimension explicitly in a partner override.

### B2B Direct Connect Mutuality

For a shared channel to work between Tenant A (host) and Tenant B (external members):
- Tenant A must set `b2bDirectConnectOutbound` = allowed (for the Office 365 application target, at minimum) toward Tenant B
- Tenant B must set `b2bDirectConnectInbound` = allowed toward Tenant A

Both directions are configured independently and both must be true. Neither tenant can unilaterally enable a shared channel relationship — this is a deliberate security design so that no organization can pull in resources from another without that organization's explicit consent.

### Trust Settings (inboundTrust)

When your tenant enforces Conditional Access (MFA, compliant device, hybrid Azure AD join) for guest/external users, by default an external user's claims from THEIR home tenant are not automatically honored — they'd be forced to re-satisfy your CA requirements from scratch, which often isn't possible for a B2B direct connect user who never signs into your tenant. `inboundTrust` settings let you explicitly say "trust that this partner's MFA/device compliance claim is good enough," avoiding a hard block.

### Federation vs. Guest Access — Overlapping But Independent

A common misconception: "we already have federation with Partner X, so guest access should just work." False. Federation only permits chat/call/meet presence — it does nothing for B2B guest invitations or team membership. These are configured, governed, and audited completely separately. A tenant can have federation fully open while guest access is completely disabled tenant-wide, or vice versa.

</details>

---

## Dependency Stack

```
Entra ID Tenant (yours)
    │
    ├── PATH 1 — External Access / Federation
    │     └── CsTenantFederationConfiguration (AllowFederatedUsers, allow/block domain lists)
    │           └── CsExternalAccessPolicy (per-user/group override, preview rollout)
    │                 └── Partner tenant's OWN federation config must also allow you (mutual)
    │                       └── Presence/chat/call/meet — NO file, NO membership
    │
    ├── PATH 2 — Guest Access
    │     └── Entra ID: External collaboration settings (AllowInvitesFrom)
    │           └── Teams Admin Center: Org-wide → Guest access = ON
    │                 └── Cross-tenant access: b2bCollaborationInbound/Outbound = allowed
    │                       └── Guest invited → B2B invitation → redemption
    │                             └── Guest object created (userType=Guest) in YOUR tenant
    │                                   └── Added as Team member
    │                                         └── SharePoint guest permission on Team's site
    │                                               └── FULL TEAM ACCESS (files, chat, channels)
    │
    └── PATH 3 — Shared Channels / Teams Connect
          └── Cross-tenant access: b2bDirectConnectOutbound = allowed (YOUR tenant, toward partner)
                └── Partner tenant: b2bDirectConnectInbound = allowed (toward you) — MUTUAL, INDEPENDENT CONFIG
                      └── inboundTrust settings (if CA requires MFA/compliant device)
                            └── Channel shared via "Share this channel" → partner user added by email
                                  └── External user authenticates via OWN home tenant
                                        └── SINGLE CHANNEL ACCESS — no guest object, no membership elsewhere
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Can't chat/call anyone at another company at all | `AllowFederatedUsers = $false` tenant-wide | `Get-CsTenantFederationConfiguration` |
| Federation works with most orgs but not one specific domain | Domain in `BlockedDomains`, or `AllowedDomains` in restrictive mode | `Get-CsTenantFederationConfiguration \| Select BlockedDomains,AllowedDomains` |
| Guest invite email never arrives / guest stuck "Pending" | `AllowInvitesFrom` too restrictive, or partner tenant blocking inbound B2B collaboration | `Get-MgPolicyAuthorizationPolicy`; ask partner to check their outbound B2B collab setting |
| Guest redeemed invite but can't see Team files | SharePoint site-level guest sharing disabled independently of Teams guest toggle | Check `Get-SPOSite` `SharingCapability` on the Team's backing site |
| Can't add external user to a shared channel at all | B2B direct connect not enabled on YOUR outbound side | `Get-MgPolicyCrossTenantAccessPolicyPartner` → `B2bDirectConnectOutbound` |
| Shared channel invite sent, partner user never appears | Partner tenant hasn't reciprocated inbound B2B direct connect | Confirm with partner admin — this is external to your tenant, cannot fix unilaterally |
| Someone tried adding a guest account to a shared channel | Unsupported operation — guests only work in regular Team membership | Rebuild via B2B direct connect ("Share this channel"), not guest invite |
| External user blocked despite B2B direct connect enabled | Conditional Access MFA/device compliance not trusted via `inboundTrust` | `(Get-MgPolicyCrossTenantAccessPolicyPartner ...).InboundTrust` |
| A specific partner tenant blocked even though default policy is open | Partner-specific override exists and replaces (not merges with) default | `Get-MgPolicyCrossTenantAccessPolicyPartner -All` — check for that tenant ID |
| Guest access "works for some users, not others" | Per-user Teams guest policy or Conditional Access targeting a subset of users/groups | Check any user/group-scoped CA policies targeting guests specifically |
| Federation open, but Teams Consumer (personal accounts) users can't be reached | `AllowTeamsConsumer`/`AllowTeamsConsumerInbound` not separately enabled | `Get-CsTenantFederationConfiguration \| Select AllowTeamsConsumer*` |

---

## Validation Steps

**1. Confirm federation posture (Path 1)**
```powershell
Connect-MicrosoftTeams
Get-CsTenantFederationConfiguration | Format-List AllowFederatedUsers, AllowPublicUsers, AllowTeamsConsumer, AllowTeamsConsumerInbound, AllowedDomains, BlockedDomains
```
Expected for open collaboration: `AllowFederatedUsers = True`, empty `BlockedDomains` unless deliberately restricted.

**2. Confirm guest access posture (Path 2)**
```powershell
Connect-MgGraph -Scopes "Policy.Read.All"
Get-MgPolicyAuthorizationPolicy | Select-Object AllowInvitesFrom
```
Also manually confirm in Teams Admin Center → Org-wide settings → Guest access — no Graph/PowerShell cmdlet directly exposes this specific Teams-level toggle; it is a Teams service configuration, not an Entra policy object.

**3. Confirm cross-tenant access default policy (Paths 2 & 3)**
```powershell
$default = Get-MgPolicyCrossTenantAccessPolicyDefault
$default | Select-Object -ExpandProperty B2bCollaborationInbound
$default | Select-Object -ExpandProperty B2bCollaborationOutbound
$default | Select-Object -ExpandProperty B2bDirectConnectInbound
$default | Select-Object -ExpandProperty B2bDirectConnectOutbound
```

**4. Confirm partner-specific overrides don't silently conflict**
```powershell
$partners = Get-MgPolicyCrossTenantAccessPolicyPartner -All
$partners | Select-Object TenantId, `
  @{N='B2BCollabInAllowed';E={$_.B2bCollaborationInbound.UsersAndGroups.AccessType}}, `
  @{N='B2BDirectInAllowed';E={$_.B2bDirectConnectInbound.UsersAndGroups.AccessType}}
```

**5. Validate a specific guest object's state**
```powershell
$guest = Get-MgUser -Filter "userType eq 'Guest' and mail eq '<guest@partner.com>'"
$guest | Select-Object DisplayName, ExternalUserState, ExternalUserStateChangeDateTime, CreatedDateTime
# ExternalUserState should be "Accepted" — "PendingAcceptance" means the invite hasn't been redeemed
```

**6. Validate shared channel membership**
```powershell
# Team-level shared channel listing (requires Teams PowerShell or Graph)
Get-Team -GroupId "<teamGroupId>" | Get-TeamChannel | Where-Object MembershipType -eq "Shared"
```

---

## Troubleshooting Steps (by phase)

### Phase 1 — Classify the Failure

1. Ask the reporting engineer/user: is the external person a) chatting/calling only, b) a member of a full Team, or c) a member of one channel only?
2. This single answer determines which of the three dependency chains to trace. Do not proceed until this is confirmed — the three paths share no common root cause.

### Phase 2 — External Access (Federation) Path

3. Check `Get-CsTenantFederationConfiguration` on YOUR tenant.
4. If open on your side but still failing, this is very likely a **mutual** requirement — the partner org's federation config also matters, and you cannot see their configuration. Ask them to confirm `AllowFederatedUsers = $true` on their end and that your domain isn't in their `BlockedDomains`.
5. If using the newer per-user `CsExternalAccessPolicy` (preview), confirm the affected user isn't assigned a restrictive policy that overrides the tenant-wide federation config for their specific case.

### Phase 3 — Guest Access Path

6. Confirm Entra `AllowInvitesFrom` isn't set to `none` or `adminsAndGuestInviters` if a regular member (not admin) is trying to invite.
7. Confirm Teams Admin Center guest access toggle is ON — this is easy to miss since it's a Teams-specific setting, not an Entra one.
8. Check the guest object's `ExternalUserState`. `PendingAcceptance` for more than a few days usually means the invite email was filtered/lost, or the partner's own inbound B2B collaboration setting is blocking your invite from ever reaching them.
9. If the guest redeemed successfully but can't see files, check the SharePoint site's own `SharingCapability` — Teams guest access being ON does not override a restrictive SharePoint-level sharing policy on that specific site.

### Phase 4 — Shared Channels Path

10. Confirm your tenant's `b2bDirectConnectOutbound` allows the partner tenant (either via default policy or an explicit partner entry).
11. This is where most tickets stall: your side being correctly configured does NOT mean the channel will work — the partner tenant must independently configure `b2bDirectConnectInbound` toward you. There is no way to verify their configuration from your tenant; you must ask them directly or have them attempt to join and report the exact error.
12. If Conditional Access requires MFA/compliant device, check `inboundTrust` for that partner. Without it, the external user may get an access-denied error that looks like a permissions problem but is actually an authentication-claims trust gap.
13. If someone attempted to add a guest account (not B2B direct connect) to the shared channel, this will fail or silently not appear — walk them through "Share this channel" with the external user's email instead.

### Phase 5 — Cross-Tenant Access Precedence Check (any path involving B2B)

14. Always check for a partner-specific override before troubleshooting the default policy further — `Get-MgPolicyCrossTenantAccessPolicyPartner -All` — a stale restrictive entry from a past security review is a very common silent blocker.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Stand up a new federated partner relationship (external access)</summary>

```powershell
Connect-MicrosoftTeams

# Ensure tenant-wide federation is enabled
Set-CsTenantFederationConfiguration -AllowFederatedUsers $true

# Explicitly allow the specific partner domain (defensive, in case AllowedDomains restriction is later introduced)
$allowed = New-CsEdgeDomainPattern -Domain "partner.com"
Set-CsTenantFederationConfiguration -AllowedDomains @{Add=$allowed}

# Confirm
Get-CsTenantFederationConfiguration | Select-Object AllowFederatedUsers, AllowedDomains, BlockedDomains
```

**Coordinate with partner:** send them the equivalent request — they must independently confirm `AllowFederatedUsers = $true` and that your domain is not blocked on their side.

**Rollback:** `Set-CsTenantFederationConfiguration -AllowedDomains @{Remove=$allowed}`

</details>

<details><summary>Playbook 2 — Onboard a guest into a Team end-to-end</summary>

```powershell
Connect-MgGraph -Scopes "User.Invite.All","Policy.ReadWrite.Authorization"

# 1. Ensure Entra allows invites (if not already open tenant-wide)
Update-MgPolicyAuthorizationPolicy -AllowInvitesFrom "everyone"

# 2. Send the invitation
$invitation = New-MgInvitation -InvitedUserEmailAddress "<guest@partner.com>" `
    -InviteRedirectUrl "https://teams.microsoft.com" `
    -SendInvitationMessage:$true

$invitation | Select-Object Id, InviteRedeemUrl, Status

# 3. Once redeemed (poll or wait for confirmation), add to the Team
Connect-MicrosoftTeams
Add-TeamUser -GroupId "<teamGroupId>" -User "<guest@partner.com>" -Role Member
```

**Also confirm:** Teams Admin Center Org-wide guest access = ON (no PowerShell equivalent — must be checked/set in the portal).

**Rollback:**
```powershell
Remove-TeamUser -GroupId "<teamGroupId>" -User "<guest@partner.com>"
# To fully remove the guest object from the directory (if not needed elsewhere):
Remove-MgUser -UserId (Get-MgUser -Filter "mail eq '<guest@partner.com>'").Id
```

</details>

<details><summary>Playbook 3 — Establish mutual B2B direct connect with a partner tenant</summary>

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.CrossTenantAccess"

$partnerTenantId = "<partnerTenantId>"

# YOUR side — allow outbound (you can share channels TO the partner)
$outboundParams = @{
    b2bDirectConnectOutbound = @{
        usersAndGroups = @{ accessType = "allowed"; targets = @(@{ target = "AllUsers"; targetType = "user" }) }
        applications   = @{ accessType = "allowed"; targets = @(@{ target = "Office365"; targetType = "application" }) }
    }
}
Update-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerId $partnerTenantId -BodyParameter $outboundParams

# YOUR side — allow inbound (partner's users can join YOUR shared channels)
$inboundParams = @{
    b2bDirectConnectInbound = @{
        usersAndGroups = @{ accessType = "allowed"; targets = @(@{ target = "AllUsers"; targetType = "user" }) }
        applications   = @{ accessType = "allowed"; targets = @(@{ target = "Office365"; targetType = "application" }) }
    }
}
Update-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerId $partnerTenantId -BodyParameter $inboundParams

# If CA enforces MFA/compliant device, trust the partner's claims
$trustParams = @{ inboundTrust = @{ isMfaAccepted = $true; isCompliantDeviceAccepted = $true; isCompliantDeviceAccepted = $true } }
Update-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerId $partnerTenantId -BodyParameter $trustParams
```

**Send the partner admin the mirrored request** — they must configure the same four settings (outbound/inbound users+apps, inbound trust) pointing back at your tenant ID. Neither side can complete this alone.

**Rollback:**
```powershell
Remove-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerId $partnerTenantId
```

</details>

<details><summary>Playbook 4 — Audit all external collaboration exposure (security review prep)</summary>

```powershell
Connect-MgGraph -Scopes "Policy.Read.All","User.Read.All"
Connect-MicrosoftTeams

# 1. Federation exposure
Get-CsTenantFederationConfiguration | Select-Object AllowFederatedUsers, AllowTeamsConsumer, AllowedDomains, BlockedDomains

# 2. All guest accounts and their last sign-in
Get-MgUser -Filter "userType eq 'Guest'" -All -Property DisplayName,Mail,ExternalUserState,CreatedDateTime,SignInActivity |
    Select-Object DisplayName, Mail, ExternalUserState, CreatedDateTime, @{N='LastSignIn';E={$_.SignInActivity.LastSignInDateTime}} |
    Export-Csv "$env:TEMP\GuestAccountAudit.csv" -NoTypeInformation

# 3. All cross-tenant partner overrides (default + explicit partners)
$default = Get-MgPolicyCrossTenantAccessPolicyDefault
$partners = Get-MgPolicyCrossTenantAccessPolicyPartner -All
$partners | Select-Object TenantId, `
    @{N='B2BCollabIn';E={$_.B2bCollaborationInbound.UsersAndGroups.AccessType}}, `
    @{N='B2BDirectIn';E={$_.B2bDirectConnectInbound.UsersAndGroups.AccessType}}, `
    @{N='InboundTrustMFA';E={$_.InboundTrust.IsMfaAccepted}} |
    Export-Csv "$env:TEMP\CrossTenantPartnerAudit.csv" -NoTypeInformation

Write-Host "Default B2B collaboration inbound: $($default.B2bCollaborationInbound.UsersAndGroups.AccessType)"
Write-Host "Default B2B direct connect inbound: $($default.B2bDirectConnectInbound.UsersAndGroups.AccessType)"
```

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Teams external-collaboration evidence for an escalation
.NOTES     Requires MicrosoftTeams + Microsoft.Graph.Identity.SignIns modules
           Requires Teams Administrator + Global Reader (minimum) roles
#>

param(
    [string]$GuestEmail,
    [string]$PartnerTenantId
)

Connect-MicrosoftTeams -ErrorAction Stop
Connect-MgGraph -Scopes "Policy.Read.All","User.Read.All" -ErrorAction Stop

$OutputPath = "$env:TEMP\Teams-ExternalAccess-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# 1. Federation configuration
Get-CsTenantFederationConfiguration | Export-Csv "$OutputPath\01-FederationConfig.csv" -NoTypeInformation

# 2. Entra invite authorization policy
Get-MgPolicyAuthorizationPolicy | Select-Object AllowInvitesFrom |
    Export-Csv "$OutputPath\02-InviteAuthPolicy.csv" -NoTypeInformation

# 3. Cross-tenant access default policy
Get-MgPolicyCrossTenantAccessPolicyDefault |
    Export-Csv "$OutputPath\03-CrossTenantDefault.csv" -NoTypeInformation

# 4. Partner-specific override (if a partner tenant ID was supplied)
if ($PartnerTenantId) {
    Get-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerId $PartnerTenantId |
        Export-Csv "$OutputPath\04-PartnerOverride.csv" -NoTypeInformation
}

# 5. Guest object detail (if a guest email was supplied)
if ($GuestEmail) {
    Get-MgUser -Filter "mail eq '$GuestEmail'" -Property DisplayName,ExternalUserState,ExternalUserStateChangeDateTime,CreatedDateTime |
        Export-Csv "$OutputPath\05-GuestObjectDetail.csv" -NoTypeInformation
}

# 6. All partner overrides (context for precedence conflicts)
Get-MgPolicyCrossTenantAccessPolicyPartner -All |
    Export-Csv "$OutputPath\06-AllPartnerOverrides.csv" -NoTypeInformation

Write-Host "Evidence collected to: $OutputPath" -ForegroundColor Green
Compress-Archive -Path $OutputPath -DestinationPath "$OutputPath.zip" -Force
Write-Host "Zipped: $OutputPath.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check tenant federation config | `Get-CsTenantFederationConfiguration` |
| Enable federation | `Set-CsTenantFederationConfiguration -AllowFederatedUsers $true` |
| Block a domain | `Set-CsTenantFederationConfiguration -BlockedDomains @{Add=(New-CsEdgeDomainPattern -Domain "x.com")}` |
| Check Entra invite policy | `Get-MgPolicyAuthorizationPolicy \| Select AllowInvitesFrom` |
| Set invite policy | `Update-MgPolicyAuthorizationPolicy -AllowInvitesFrom "everyone"` |
| Invite a guest | `New-MgInvitation -InvitedUserEmailAddress <email> -InviteRedirectUrl <url> -SendInvitationMessage:$true` |
| Add guest to Team | `Add-TeamUser -GroupId <id> -User <upn> -Role Member` |
| Check guest redemption state | `Get-MgUser -Filter "userType eq 'Guest'" \| Select DisplayName,ExternalUserState` |
| Get cross-tenant default policy | `Get-MgPolicyCrossTenantAccessPolicyDefault` |
| Get partner-specific override | `Get-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerId <id>` |
| List all partner overrides | `Get-MgPolicyCrossTenantAccessPolicyPartner -All` |
| Enable B2B direct connect outbound | `Update-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerId <id> -BodyParameter @{b2bDirectConnectOutbound=...}` |
| Remove partner override (revert to default) | `Remove-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerId <id>` |
| List shared channels on a Team | `Get-Team -GroupId <id> \| Get-TeamChannel \| Where MembershipType -eq Shared` |

---

## 🎓 Learning Pointers

- **These are three separate trust architectures wearing the same "external collaboration" label.** Federation is presence/IM/call only with zero directory footprint. Guest access provisions a real directory object in your tenant. Shared channels use B2B direct connect with zero directory footprint but scoped to one resource, not org-wide presence. Engineers who treat these as "the same setting in different places" waste enormous time. Learn the three-way distinction once and every future ticket routes instantly. [Communicate with external users](https://learn.microsoft.com/en-us/microsoftteams/communicate-with-users-from-other-organizations)

- **Partner-specific cross-tenant access entries replace, not merge with, the default policy.** This is a common source of "it was working, then someone touched a security setting and it broke for exactly one partner." Any dimension left unconfigured on a partner override does not fall back to your tenant default — treat every partner override as a complete, from-scratch policy that needs every relevant field set explicitly. [Cross-tenant access overview](https://learn.microsoft.com/en-us/entra/external-id/cross-tenant-access-overview)

- **B2B direct connect cannot be diagnosed from one side alone.** Because it requires mutual, independent configuration in two different tenants that you likely don't have visibility into, roughly half of shared-channel tickets are actually "ask the partner to check their side" — not something fixable purely from your own tenant. Build this into your triage script so engineers don't spend an hour re-checking their own configuration when the partner never reciprocated.

- **`inboundTrust` is the most-forgotten setting in Conditional Access + external-collaboration environments.** Organizations that lock down with MFA/compliant-device Conditional Access frequently forget that B2B direct connect and guest users need an explicit trust decision for the partner's own MFA/device claims — otherwise external users hit a wall that looks like a permissions error but is actually an unsatisfiable authentication requirement. [Cross-tenant access trust settings](https://learn.microsoft.com/en-us/entra/external-id/cross-tenant-access-settings-b2b-collaboration)

- **Granular, per-user external access control is actively evolving — don't assume `CsTenantFederationConfiguration` is the only lever forever.** Microsoft has been rolling out `CsExternalAccessPolicy`-based per-user/group federation control (public preview as of late 2025) to let different populations of users have different trusted-domain sets, layered on top of the tenant-wide baseline. Check what's available in a given tenant before promising a client "it's all-or-nothing." [Manage external access in Teams](https://learn.microsoft.com/en-us/microsoftteams/manage-external-access)

- **SharePoint's own sharing policy is a second gate for guest file access.** A guest fully provisioned and added to a Team can still be unable to open files if the Team's backing SharePoint site has a more restrictive `SharingCapability` than the tenant default. Teams guest access being ON is necessary but not sufficient — always cross-check the site-level setting for file-access complaints specifically.
