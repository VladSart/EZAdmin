# Teams External Access, Guest Access & Shared Channels — Hotfix Runbook (Mode B: Ops)
> Fix or escalate external-collaboration failures — federation, guest invites, and Teams Connect shared channels — in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

**First — identify which of the three collaboration modes the user actually needs.** These are three different features with three different fix paths, and mixing them up is the #1 cause of wasted troubleshooting time:

| User says... | They mean... |
|---|---|
| "I can't chat/call someone at another company" | **External access** (federation) |
| "I invited someone to my Team and they can't accept / can't see files" | **Guest access** (B2B invite into a full Team) |
| "I want to share one channel with a partner company without inviting them as a guest" | **Shared Channels / Teams Connect** (B2B direct connect) |

```powershell
# Connect to Teams PowerShell
# Install-Module MicrosoftTeams -Force
Connect-MicrosoftTeams
Connect-MgGraph -Scopes "Policy.Read.All","CrossTenantInformation.Read.All"

# 1. Tenant-wide federation (external access) posture
Get-CsTenantFederationConfiguration | Select-Object AllowFederatedUsers, AllowTeamsConsumer, AllowTeamsConsumerInbound, BlockedDomains, AllowedDomains

# 2. Tenant-wide guest access posture (Teams-level, separate from Entra B2B)
# Teams Admin Center → Org-wide settings → Guest access → Allow guest access to Teams: ON/OFF
# No direct Get- cmdlet for this toggle — must confirm in Teams Admin Center or via Graph teamsAdminCenter policy

# 3. Cross-tenant access settings (governs both guest invites AND shared channels)
Get-MgPolicyCrossTenantAccessPolicyDefault | Select-Object B2bCollaborationInbound, B2bCollaborationOutbound, B2bDirectConnectInbound, B2bDirectConnectOutbound

# 4. Partner-specific override (if the other org has an explicit partner entry)
Get-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerId "<partnerTenantId>"
```

| Result | Action |
|--------|--------|
| `AllowFederatedUsers: False` | → [Fix 1 — Enable external access (federation)](#fix-1--enable-external-access-federation) |
| Partner domain in `BlockedDomains` | → [Fix 2 — Allow/block a specific external domain](#fix-2--allowblock-a-specific-external-domain) |
| Guest access toggle OFF in Teams Admin Center | → [Fix 3 — Enable Teams guest access](#fix-3--enable-teams-guest-access) |
| Guest invited but stuck "Pending" in Entra | → [Fix 4 — Fix a stuck guest invite](#fix-4--fix-a-stuck-guest-invite) |
| Shared channel invite fails / partner can't be added | → [Fix 5 — Enable B2B direct connect for shared channels](#fix-5--enable-b2b-direct-connect-for-shared-channels) |
| Guest added directly to a shared channel (unsupported) | → [Fix 6 — Correct a shared-channel guest mistake](#fix-6--correct-a-shared-channel-guest-mistake) |
| Cross-tenant partner setting blocks the org entirely | → [Fix 7 — Fix cross-tenant access partner trust](#fix-7--fix-cross-tenant-access-partner-trust) |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Three independent collaboration paths — each has its OWN on/off switch:

┌─ PATH 1: EXTERNAL ACCESS (federation) ─────────────────────────┐
│  Set-CsTenantFederationConfiguration (BOTH tenants)             │
│    └── AllowFederatedUsers = $true                              │
│        └── Domain not in BlockedDomains (or in AllowedDomains   │
│            if AllowedDomains list is in use)                    │
│            └── Chat / call / meet across orgs                   │
│                (NO file access, NO team membership)              │
└───────────────────────────────────────────────────────────────┘

┌─ PATH 2: GUEST ACCESS (B2B invite into a Team) ─────────────────┐
│  Teams Admin Center → Org-wide → Guest access = ON               │
│    └── Entra ID: External collaboration settings allow B2B       │
│        invites (Guest invite settings)                           │
│        └── Guest redeems invite → Entra B2B guest account        │
│            created in YOUR tenant                                │
│            └── Added as member of a Team (full channel access,   │
│                file access via SharePoint guest permissions)      │
└───────────────────────────────────────────────────────────────┘

┌─ PATH 3: SHARED CHANNELS / TEAMS CONNECT (B2B direct connect) ──┐
│  Entra Cross-tenant access settings (BOTH tenants, MUTUAL)       │
│    ├── Organization A: Outbound B2B direct connect = Allow       │
│    └── Organization B: Inbound B2B direct connect = Allow        │
│        └── Trust settings: MFA/compliant device trusted           │
│            from partner IF partner enforces them                 │
│            └── External user joins ONE channel using THEIR       │
│                home-tenant identity — no guest account created,   │
│                no tenant switch                                  │
└───────────────────────────────────────────────────────────────┘

Guests CANNOT be added directly to a shared channel — shared channels
only accept members via B2B direct connect (or internal members).
```

**Key principle:** these three toggles do not depend on each other. Federation being ON does not enable guest access. Guest access being ON does not enable shared channels. Each must be checked and fixed independently.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm which collaboration mode is actually broken**
Ask: "Are they in a full Team, or just one channel? Do they have a guest account, or are they using their own company login?" This single question routes you to the right fix path.

**Step 2 — Check tenant federation (Path 1 — external access)**
```powershell
Get-CsTenantFederationConfiguration | Format-List AllowFederatedUsers, AllowTeamsConsumer, AllowedDomains, BlockedDomains
```
- `AllowFederatedUsers: False` = federation off entirely
- Check `BlockedDomains` for the partner's domain
- If `AllowedDomains` has entries, only those domains are trusted — everything else is blocked by default

**Step 3 — Check tenant-level guest access (Path 2)**
```
Teams Admin Center → Org-wide settings → Guest access → Allow guest access to Teams
```
This is a Teams-specific switch, separate from Entra ID's B2B invite settings. Both must be ON.

**Step 4 — Check Entra ID external collaboration settings (governs Path 2 invite issuance)**
```powershell
Get-MgPolicyAuthorizationPolicy | Select-Object AllowInvitesFrom
# Expected for open collaboration: "everyone" or "adminsGuestInvitersAndAllMembers"
# "none" or "adminsAndGuestInviters" will block regular users from inviting guests
```

**Step 5 — Check cross-tenant access settings (governs Path 2 AND Path 3)**
```powershell
Connect-MgGraph -Scopes "Policy.Read.All"
$default = Get-MgPolicyCrossTenantAccessPolicyDefault
$default | Select-Object B2bCollaborationInbound, B2bCollaborationOutbound, B2bDirectConnectInbound, B2bDirectConnectOutbound

# Check for a partner-specific override that takes precedence over the default
Get-MgPolicyCrossTenantAccessPolicyPartner -All | Select-Object TenantId, B2bCollaborationInbound, B2bDirectConnectInbound
```
If a partner-specific entry exists for the target tenant, IT governs — not the default policy.

**Step 6 — For shared channels specifically, confirm BOTH tenants configured B2B direct connect**
B2B direct connect is mutual: Organization A must allow outbound, and Organization B must allow inbound, for their respective directions. If the partner admin hasn't reciprocated, the invite will fail or the channel will show the external user as unable to join — even though your side is fully configured.
```powershell
# Your outbound setting (are you allowed to reach out to them?)
(Get-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerId "<partnerTenantId>").B2bDirectConnectOutbound

# Your inbound setting (are you allowed to receive their users?)
(Get-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerId "<partnerTenantId>").B2bDirectConnectInbound
```

**Step 7 — Check trust settings if MFA/compliant-device is enforced**
If your Conditional Access requires MFA or a compliant device, and the external user's home tenant enforces MFA at their end, you must explicitly trust the partner's claims — otherwise the external user will be blocked at authentication even with B2B direct connect enabled.
```powershell
(Get-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerId "<partnerTenantId>").InboundTrust
# Expect IsMfaAccepted / IsCompliantDeviceAccepted = $true if you want to honour the partner's own MFA/device compliance
```

---

## Common Fix Paths

<details><summary>Fix 1 — Enable external access (federation)</summary>

**Use when:** Users report they cannot chat, call, or meet with anyone outside the organization.

```powershell
Connect-MicrosoftTeams

# Enable federation with all other Teams orgs
Set-CsTenantFederationConfiguration -AllowFederatedUsers $true

# If Teams Consumer (personal Microsoft accounts) collaboration is also needed:
Set-CsTenantFederationConfiguration -AllowTeamsConsumer $true -AllowTeamsConsumerInbound $true
```

**Rollback:**
```powershell
Set-CsTenantFederationConfiguration -AllowFederatedUsers $false
```

</details>

<details><summary>Fix 2 — Allow/block a specific external domain</summary>

**Use when:** Federation is enabled tenant-wide but one specific partner domain is blocked, or you need to restrict to an allow-list.

```powershell
Connect-MicrosoftTeams

# Block a single domain (all other domains remain allowed)
$blocked = New-CsEdgeDomainPattern -Domain "blockedpartner.com"
Set-CsTenantFederationConfiguration -BlockedDomains @{Add=$blocked}

# Remove a domain from the block list
Set-CsTenantFederationConfiguration -BlockedDomains @{Remove=$blocked}

# Switch to allow-list mode (only listed domains are trusted — use with care, this changes the whole model)
$allowed = New-CsEdgeDomainPattern -Domain "trustedpartner.com"
Set-CsTenantFederationConfiguration -AllowedDomains @{Add=$allowed}
```

> ⚠️ Once `AllowedDomains` has any entries, federation switches from "allow all except blocked" to "block all except allowed." Confirm this is the intended posture change before adding the first entry.

**Rollback:** `Set-CsTenantFederationConfiguration -BlockedDomains @{Remove=$blocked}` or clear `AllowedDomains` to return to allow-all-except-blocked.

</details>

<details><summary>Fix 3 — Enable Teams guest access</summary>

**Use when:** Federation works, but users can't invite external people into a Team as guests.

Guest access has two independent switches that must BOTH be on:

```
1. Teams Admin Center → Org-wide settings → Guest access → Allow guest access to Teams: ON
```

```powershell
# 2. Entra ID: confirm guest invites are permitted
Connect-MgGraph -Scopes "Policy.ReadWrite.Authorization"
Update-MgPolicyAuthorizationPolicy -AllowInvitesFrom "everyone"
# Options: none | adminsAndGuestInviters | adminsGuestInvitersAndAllMembers | everyone
```

**Rollback:** Toggle Teams Admin Center guest access to OFF, and/or set `AllowInvitesFrom` to `adminsAndGuestInviters`.

</details>

<details><summary>Fix 4 — Fix a stuck guest invite</summary>

**Use when:** A guest was invited but shows `PendingAcceptance` in Entra ID indefinitely, or the invite email never arrived.

```powershell
Connect-MgGraph -Scopes "User.Read.All","User.Invite.All"

# Find the guest object
$guest = Get-MgUser -Filter "userType eq 'Guest' and mail eq '<guest@partner.com>'"
$guest | Select-Object DisplayName, UserPrincipalName, ExternalUserState, ExternalUserStateChangeDateTime

# Resend the invitation (creates a new redemption email)
Invoke-MgInvitationAcceptInvite -InvitationId "<invitationId>"
# Simpler path: re-invite via Teams Admin Center or Entra portal — it re-sends without duplicating the object

# If the guest never received the email, send them the direct redemption URL instead
# (found on the original invitation object's InviteRedeemUrl property)
```

**Also check:** the partner tenant's own cross-tenant access settings may be silently blocking inbound B2B collaboration from your tenant — see [Fix 7](#fix-7--fix-cross-tenant-access-partner-trust).

</details>

<details><summary>Fix 5 — Enable B2B direct connect for shared channels</summary>

**Use when:** You try to add an external user to a shared channel and it fails, or the invited organization can't be found/selected.

B2B direct connect is **mutual** — both tenants must configure their side.

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.CrossTenantAccess"

# On YOUR tenant: allow outbound B2B direct connect to the partner tenant
$params = @{
    b2bDirectConnectOutbound = @{
        usersAndGroups = @{
            accessType = "allowed"
            targets = @(@{ target = "AllUsers"; targetType = "user" })
        }
        applications = @{
            accessType = "allowed"
            targets = @(@{ target = "Office365"; targetType = "application" })
        }
    }
}
Update-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerId "<partnerTenantId>" -BodyParameter $params

# Mirror the equivalent INBOUND config on the PARTNER tenant (they must run this on their side, not you):
# b2bDirectConnectInbound = allowed, for the same AllUsers / Office365 application target
```

**Verify after both sides configure:**
```powershell
$partner = Get-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerId "<partnerTenantId>"
$partner.B2bDirectConnectOutbound.UsersAndGroups.AccessType   # expect "allowed"
```

**Rollback:** set `accessType` back to `"blocked"` (or remove the partner-specific entry to fall back to the tenant default).

</details>

<details><summary>Fix 6 — Correct a shared-channel guest mistake</summary>

**Use when:** Someone tried to add an external user to a shared channel the same way they'd add a guest to a regular Team, and it failed or behaved unexpectedly.

Teams does **not** support adding a B2B guest account directly to a shared channel. Shared channels only accept external members via B2B direct connect (using the external user's home-tenant identity) — never a guest account provisioned in your tenant.

```
Correct flow:
1. Confirm B2B direct connect is mutually enabled (Fix 5) between both tenants
2. In the shared channel → Manage channel → Share this channel
3. Enter the external user's email — Teams resolves them via their HOME tenant, no invite/redemption step
4. They appear in the channel roster as an "External" member, still signed in to their own org
```

If a guest account was already created for this person in your tenant (from a failed earlier attempt), it can coexist harmlessly, but it will not grant shared-channel access — remove it only if it's not needed elsewhere:
```powershell
Connect-MgGraph -Scopes "User.ReadWrite.All"
Remove-MgUser -UserId "<guestObjectId>"   # only if confirmed unused elsewhere
```

</details>

<details><summary>Fix 7 — Fix cross-tenant access partner trust</summary>

**Use when:** Federation, guest access, and B2B direct connect all look correctly enabled, but the specific partner tenant is still blocked.

A **partner-specific** cross-tenant access entry always overrides the **default** policy for that tenant. If someone created a restrictive partner entry (intentionally or by accident), it silently overrides an otherwise-open default.

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.CrossTenantAccess"

# List all partner-specific overrides
Get-MgPolicyCrossTenantAccessPolicyPartner -All |
    Select-Object TenantId, @{N='B2BCollabIn';E={$_.B2bCollaborationInbound.UsersAndGroups.AccessType}}, `
                  @{N='B2BDirectIn';E={$_.B2bDirectConnectInbound.UsersAndGroups.AccessType}}

# If the specific partner is blocked, either fix the override or delete it to fall back to default
Remove-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerId "<partnerTenantId>"
```

**Also check trust settings** — if you require MFA or compliant device via Conditional Access, and you have NOT set inbound trust for the partner, their users will be challenged for MFA/device compliance they can't satisfy from your tenant's perspective (even if they satisfied it in their own tenant):
```powershell
$params = @{ inboundTrust = @{ isMfaAccepted = $true; isCompliantDeviceAccepted = $true } }
Update-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerId "<partnerTenantId>" -BodyParameter $params
```

**Rollback:** revert `inboundTrust` flags to `$false` to require your own tenant's MFA/device compliance from external users again.

</details>

---

## Escalation Evidence

```
=== Teams External Collaboration Escalation Pack ===
Date/Time:              _______________
Engineer:               _______________
Tenant ID:               _______________

Collaboration mode affected:  [ ] External access (federation)  [ ] Guest access  [ ] Shared channel (B2B direct connect)

Affected user UPN (internal):     _______________
External party email/domain:      _______________
Partner tenant ID (if known):     _______________

Get-CsTenantFederationConfiguration output attached:      [ ] Yes
Cross-tenant access default policy output attached:       [ ] Yes
Partner-specific override present:                        [ ] Yes  [ ] No  [ ] Unknown
Guest object ExternalUserState (if guest invite):          _______________

Confirmed partner tenant has reciprocated their side (B2B direct connect / federation): [ ] Yes  [ ] No  [ ] Unable to confirm — needs partner admin
Conditional Access MFA/compliant-device required for external users: [ ] Yes  [ ] No
Inbound trust configured for partner tenant:                [ ] Yes  [ ] No  [ ] N/A

Steps already taken:
[ ] Confirmed which of the three collaboration modes applies
[ ] Checked Get-CsTenantFederationConfiguration
[ ] Checked Teams Admin Center guest access toggle
[ ] Checked Entra cross-tenant access default + partner override
[ ] Confirmed with partner org whether they've configured their side (mutual requirement)

Support tier:  [ ] L2 → L3  [ ] L3 → Microsoft
```

---

## 🎓 Learning Pointers

- **Three features, three switches — don't conflate them.** External access (federation) is chat/call/meet only, no file access. Guest access provisions a B2B guest account with full Team membership. Shared channels (Teams Connect) use B2B direct connect so the external user never leaves their home tenant. Fixing the wrong switch is the most common time-waster in these tickets. [Communicate with users from other organizations](https://learn.microsoft.com/en-us/microsoftteams/communicate-with-users-from-other-organizations)

- **Guests cannot be added directly to shared channels — this trips up even experienced admins.** If someone already has a guest account in your tenant, that does not grant them shared-channel access. Shared channels require B2B direct connect specifically; guest accounts and B2B direct connect are two separate trust mechanisms that happen to both live under "External Identities" in Entra. [Guests and shared channels](https://support.microsoft.com/en-us/office/guests-and-shared-channels-in-microsoft-teams-612de4ce-e7a3-4579-b086-bb8ff9f2d11e)

- **B2B direct connect is always mutual — you cannot force it unilaterally.** Both the resource organization (hosting the channel) and the external organization must independently enable their respective outbound/inbound settings in cross-tenant access settings. If a partner ticket says "it's not working on our side," always ask them to confirm THEY configured inbound trust — it's very often the missing half. [B2B direct connect overview](https://learn.microsoft.com/en-us/entra/external-id/b2b-direct-connect-overview)

- **Partner-specific cross-tenant access entries silently override the tenant default.** An admin who created a one-off restrictive entry for a specific partner tenant (maybe during a security review) can leave that tenant blocked even after the org-wide default is opened up. Always check `Get-MgPolicyCrossTenantAccessPolicyPartner` for the specific tenant ID before assuming the default policy applies.

- **Granular per-user external access control is rolling out (public preview as of late 2025).** Historically, `Set-CsTenantFederationConfiguration` was the only lever — a single tenant-wide allow/block list. Microsoft is introducing `Set-CsExternalAccessPolicy`-based per-user/per-group federation control, letting different user populations have different trusted-domain lists. If a client asks for "some users can federate with Partner X, others can't," check whether this policy type is available in their tenant before building a workaround. [Granular external access control](https://learn.microsoft.com/en-us/microsoftteams/manage-external-access)

- **Inbound trust settings are commonly forgotten when Conditional Access requires MFA.** If your CA policy demands MFA for all users including guests/external, and you haven't configured `inboundTrust` to accept the partner's own MFA claim, external users get double-challenged or blocked outright — even with B2B direct connect fully enabled. This is a frequent "everything looks right but it still doesn't work" root cause.
