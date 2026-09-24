# Teams External Messaging Limits for MOERA-Only Tenants — Reference Runbook (Mode A: Deep Dive)
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

- **In scope:** the Teams outbound external-messaging throttle for tenants that have **only** the default `*.onmicrosoft.com` domain. This is **MC1463510**, published 28 Aug 2026, with worldwide GA from mid-September 2026. Office365ITPros expects deployment everywhere by the end of September 2026. The runbook also covers how this limit sits alongside the other "MOERA-only" restrictions an MSP will meet in the same tenant.
- **Out of scope:** general external access and federation configuration (see `ExternalAccess-A.md`), cross-tenant access policies (see `EntraID/`), and Exchange Online mail-flow troubleshooting beyond the MOERA recipient cap (see `M365/Exchange/Mail-Flow-A.md`).
- **Source confidence:** MC1463510 was read in full (mc.merill.net archive, single version, no revisions as of 25 Sept 2026). Context comes from Office365ITPros (2 Sept 2026). **No Microsoft Learn conceptual article and no published numeric threshold exist.** MC1463510 points admins to the general *Limits and specifications for Microsoft Teams* page. The companion hotfix is `ExternalMessagingLimits-B.md`.
- **Terminology:** Microsoft's MC post expands MOERA as "Microsoft Online **Email** Routing Address". Office365ITPros and older Exchange documentation use "Microsoft Online **Exchange** Routing Address". It's the same thing: the `<tenant>.onmicrosoft.com` initial domain.

---

## How It Works

<details><summary>Full architecture</summary>

### 1. The rule as published

From MC1463510:

- **Who:** "Organizations that use only the default onmicrosoft.com domain and have not configured a custom domain." The trigger is a *tenant-level* condition, not a per-user or per-sender one.
- **What:** "Outbound Teams messages sent to external users will be subject to messaging limits intended to reduce abusive or high-volume activity."
- **Effect:** the sender is temporarily unable to message external users and sees an in-product notification. **Internal messaging is unaffected.**
- **Recovery:** "External messaging capabilities will automatically resume when activity falls below the applicable threshold." No admin unblock action is documented.
- **Config:** "enabled by default and does not require administrator configuration". There is no opt-out.
- **Monitoring:** an optional **admin alert** for throttling events "will become available after the initial rollout". As of 25 Sept 2026 the post has not been updated with enablement details.

### 2. Why no threshold is published

Office365ITPros reads the behaviour as a background function watching federated-chat activity against internal, multi-signal thresholds. That is an inference, not a documented design. Leaving the number unpublished keeps spammers guessing and lets Microsoft tune it. The practical consequence for MSPs: **you cannot pre-calculate whether a customer will hit it.** The only deterministic control is leaving the scope by adding a custom domain.

### 3. Where it sits in the wider MOERA clampdown

Microsoft treats MOERA-only tenants as test tenants. Each workload has added its own guardrail, with different mechanics:

| Workload | Restriction | Trigger | Threshold | Admin control |
|---|---|---|---|---|
| Teams chat (MC1463510, Sept 2026) | Outbound external messages throttled | Tenant has **no** custom domain | **Unpublished** | None, except adding a custom domain |
| Exchange Online (announced Aug 2025) | External recipients capped | Mail sent from `onmicrosoft.com` addresses | **100 external recipients / 24 h** (per Exchange Team blog, as summarised by Office365ITPros) | Send from a verified custom domain |
| Teams federation (2024) | Trial-only tenants blocked from federated chat | Tenant has only trial licences | n/a | Buy a paid licence (widely bypassed with a cheap SKU) |

Two consequences:

1. **The Exchange cap is about the sender address, but the Teams limit is about the tenant.** A tenant that *has* a verified custom domain but still sends mail from `user@tenant.onmicrosoft.com` is **out** of the Teams limit yet can still hit the Exchange cap. The reverse doesn't happen: a MOERA-only tenant is in scope for both.
2. **The fixes converge.** Adding and verifying a custom domain, then making it the default and the users' primary SMTP/UPN, clears both.

### 4. What "external user" means here

MC1463510 lists "External chat and messaging". In Teams terminology, that is **external access (federation)**: chats with users in other Entra tenants and, where enabled, Teams (free)/consumer accounts. **Guests** are members of your own tenant in a guest context, and MC1463510 doesn't mention them. Treat guest chat as *probably* unaffected, but it isn't confirmed. Log it if you observe otherwise.

### 5. Detection gap

- No Teams PowerShell cmdlet or Graph property exposes throttle state.
- The admin alert isn't available yet.
- The only signals are the user's report (with the in-product notice text) and your domain configuration. Your evidence is therefore a **scope proof** (MOERA-only yes/no) plus the user's screenshot and timestamps.

</details>

---

## Dependency Stack

```
Layer 5  User experience   — in-product "external messaging temporarily limited" notice; internal chat fine
Layer 4  Throttle          — unpublished, activity-based, auto-lifting
Layer 3  Message type      — outbound to EXTERNAL (federated) users only
Layer 2  Tenant scope      — no verified custom domain in the tenant (only *.onmicrosoft.com)
Layer 1  Tenant provisioning — MOERA initial domain created at sign-up; custom domain optional
```

Remove Layer 2 (verify a custom domain) and nothing above it applies.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| User sees a notice that external messaging is temporarily limited; internal chat works | MC1463510 throttle | `Get-MgDomain`: only an `*.onmicrosoft.com` domain is verified |
| Same symptom, tenant **has** a verified custom domain | Not MC1463510. Look at external access policy, the other tenant's blocks, or trust indicators | `Get-CsTenantFederationConfiguration`, `Get-CsExternalAccessPolicy` |
| User can't message *anyone* | Not this feature. Licence, account or service issue | Sign-in logs, licence, service health |
| Mail to external recipients bouncing after about 100 recipients/day | Exchange MOERA recipient cap (separate feature) | Sender address domain; NDR text; `Get-MessageTraceV2` |
| Customer on a new trial tenant can't federate at all | 2024 trial-tenant federation block | Licence state (trial only?) |
| Throttle "keeps coming back" for one user | Bulk or scripted external outreach pattern (bot, mass DM) | Ask the user; review app or bot sending on their behalf |

---

## Validation Steps

1. **Tenant scope**
   ```powershell
   Connect-MgGraph -Scopes "Domain.Read.All"
   Get-MgDomain | Select-Object Id, IsVerified, IsDefault, IsInitial, AuthenticationType
   ```
   Out of scope: at least one row where `IsVerified = True` and `IsInitial = False`. In scope: the only verified domain is the `IsInitial = True` onmicrosoft.com one.

2. **Default domain is not MOERA**
   The same output, `IsDefault = True` row: Good is a custom domain. Bad is `*.onmicrosoft.com`. New users will be created on MOERA, which keeps the Exchange cap in play.

3. **Users still on MOERA addresses** (Exchange cap exposure, even if Teams-scope is clear)
   ```powershell
   Connect-ExchangeOnline
   Get-EXOMailbox -ResultSize Unlimited -Properties PrimarySmtpAddress |
       Where-Object { $_.PrimarySmtpAddress -like '*.onmicrosoft.com' } | Measure-Object
   ```
   Good: `0` (or only service/test mailboxes). Bad: production users sending as MOERA.

4. **Federation actually enabled**, so a "can't message external" report isn't a policy block
   ```powershell
   Connect-MicrosoftTeams
   Get-CsTenantFederationConfiguration | Select-Object AllowFederatedUsers, AllowTeamsConsumer, AllowedDomains, BlockedDomains
   ```

5. **Scripted:** run `Scripts/Get-MOERAOnlyTenantExposure.ps1` for all of the above in one CSV.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Scope.** Validation 1. If the tenant isn't MOERA-only, stop and follow `ExternalAccess-B.md`.

**Phase 2 — Confirm the pattern.** Confirm with the user: they can't send to externals, internal chat works, and they saw the notice. Get a screenshot, a timestamp, and a rough count of recent external chats. Ask about bulk activity: onboarding blasts, a sales campaign run through Teams chat, or a bot.

**Phase 3 — Contain.** There's no admin unblock. Set expectations that it resumes automatically. For urgent external comms in the meantime, use email *from a custom-domain address if one exists*. A MOERA sender hits the Exchange cap instead.

**Phase 4 — Permanent fix.** Playbook 1 (custom domain). For customers who can't buy a domain today, Playbook 3 documents the risk acceptance.

**Phase 5 — Monitor.** Watch MC1463510 for the admin-alert update, then Playbook 4.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Exit MOERA-only scope (add, verify and adopt a custom domain)</summary>

```powershell
Connect-MgGraph -Scopes "Domain.ReadWrite.All","User.ReadWrite.All"

New-MgDomain -Id "<customDomain>"
Get-MgDomainVerificationDnsRecord -DomainId "<customDomain>" |
    Select-Object RecordType, Label, Text, Ttl      # publish the TXT at the DNS host
# ... wait for DNS propagation ...
Confirm-MgDomain -DomainId "<customDomain>"
Get-MgDomain -DomainId "<customDomain>" | Select-Object Id, IsVerified

# Make it the default for new objects
Update-MgDomain -DomainId "<customDomain>" -IsDefault
```
Verification alone takes the tenant out of MC1463510 scope. For the Exchange cap and a clean identity story, also:

- Set up the service records for Exchange (MX, SPF, autodiscover, DKIM). See `M365/Exchange/DMARC-DKIM-A.md`.
- Change users' UPN and primary SMTP to the custom domain. **Rollback note:** a UPN change affects sign-in names, OneDrive URLs (renamed), and cached credentials on devices. Schedule it and communicate. Don't mass-change on the same day as verification.

**Rollback:** removing a verified domain is disruptive (every object using it must be moved first). There's no reason to roll back this playbook.

</details>

<details><summary>Playbook 2 — Reduce external-chat volume from bots and scripts</summary>

If one user or app repeatedly trips the throttle:
- Inventory Teams apps and bots that post to external chats. See `UnifiedAppAgentManagement-A.md` and `Get-UnifiedAppManagementAudit.ps1`.
- Move bulk external outreach to proper channels: email from a custom domain, a shared channel with the partner, or a Teams webinar or town hall.
- Put rate limiting into any in-house automation that sends 1:1 external chats via Graph.

</details>

<details><summary>Playbook 3 — Risk acceptance for a customer staying MOERA-only</summary>

Document it in the ticket or CMDB:

- The tenant is MOERA-only by choice.
- External Teams chat can be throttled without notice.
- The threshold is unpublished.
- There is no admin override.
- Mail is capped at 100 external recipients per 24 h per the Exchange limit.
- Microsoft's direction is more restriction, not less.

Review quarterly. This is the MSP's cover when the customer complains later.

</details>

<details><summary>Playbook 4 — Enable the throttling admin alert (when it ships)</summary>

MC1463510 promises an optional alert "after the initial rollout". When the post is updated:

1. Record where the alert lives. Likely candidates are Teams admin center notifications and alerts, or Microsoft 365 admin center alert policies, but this is unconfirmed.
2. Route it to the MSP's PSA mailbox.
3. Update this playbook and `ExternalMessagingLimits-B.md` with the exact path.

</details>

---

## Evidence Pack

```powershell
# Read-only evidence collection for a suspected MC1463510 throttle
param([string]$AffectedUpn = "<UPN>",
      [string]$OutDir = "$env:TEMP\TeamsExtMsgLimit_$(Get-Date -f yyyyMMdd_HHmm)")
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

Connect-MgGraph -Scopes "Domain.Read.All","Organization.Read.All" -NoWelcome
Get-MgDomain | Select-Object Id, IsVerified, IsDefault, IsInitial |
    Export-Csv "$OutDir\domains.csv" -NoTypeInformation
Get-MgOrganization | Select-Object Id, DisplayName, CreatedDateTime |
    Export-Csv "$OutDir\org.csv" -NoTypeInformation

try {
    Connect-MicrosoftTeams | Out-Null
    Get-CsTenantFederationConfiguration | Select-Object AllowFederatedUsers, AllowTeamsConsumer,
        AllowTeamsConsumerInbound, AllowedDomains, BlockedDomains |
        Export-Csv "$OutDir\federation.csv" -NoTypeInformation
    Get-CsOnlineUser -Identity $AffectedUpn | Select-Object UserPrincipalName, ExternalAccessPolicy, TeamsUpgradeEffectiveMode |
        Export-Csv "$OutDir\user.csv" -NoTypeInformation
} catch { "Teams module step failed: $($_.Exception.Message)" | Out-File "$OutDir\teams-error.txt" }

@"
Affected user     : $AffectedUpn
Notice text       : <paste from screenshot>
First seen (UTC)  : <timestamp>
Resolved (UTC)    : <timestamp or 'ongoing'>
Recent external chats (approx count / pattern): <description>
Internal chat OK  : <yes/no>
MC1463510 revision date checked: <date>
"@ | Out-File "$OutDir\narrative.txt"

Compress-Archive -Path "$OutDir\*" -DestinationPath "$OutDir.zip" -Force
Write-Host "Evidence: $OutDir.zip"
```

---

## Command Cheat Sheet

| Task | Command |
|---|---|
| List domains | `Get-MgDomain \| select Id,IsVerified,IsDefault,IsInitial` |
| MOERA-only test | `@(Get-MgDomain \| ? { $_.IsVerified -and -not $_.IsInitial }).Count -eq 0` |
| Add domain | `New-MgDomain -Id <customDomain>` |
| Verification record | `Get-MgDomainVerificationDnsRecord -DomainId <customDomain>` |
| Verify | `Confirm-MgDomain -DomainId <customDomain>` |
| Make default | `Update-MgDomain -DomainId <customDomain> -IsDefault` |
| Federation config | `Get-CsTenantFederationConfiguration` |
| User's external access policy | `Get-CsOnlineUser <UPN> \| select ExternalAccessPolicy` |
| MOERA mailboxes | `Get-EXOMailbox -ResultSize Unlimited \| ? PrimarySmtpAddress -like '*.onmicrosoft.com'` |
| Full exposure audit | `.\Get-MOERAOnlyTenantExposure.ps1 -IncludeExchange -IncludeTeams` |

---

## 🎓 Learning Pointers

- **This is a scope problem, not a policy problem.** No Teams policy is involved and there's nothing to toggle. The fix lives in domain management: [Add a domain to Microsoft 365](https://learn.microsoft.com/en-us/microsoft-365/admin/setup/add-domain).
- **The MC post is the only primary source.** Track revisions at the [MC1463510 archive](https://mc.merill.net/message/MC1463510), especially for the promised admin alert.
- **The same pressure applies across workloads.** Read [Office365ITPros — MOERA-Only Tenants To Face Restricted Federated Chat](https://office365itpros.com/2026/09/02/moera-only-tenants-external-collab/) for the Exchange 100-recipient cap and the 2024 trial-tenant federation block in one place.
- **Know the general Teams limits page** Microsoft points to: [Limits and specifications for Microsoft Teams](https://learn.microsoft.com/en-us/microsoftteams/limits-specifications-teams). It doesn't list the MOERA threshold, so don't quote a number to a customer.
- **External access concepts:** [Manage external meetings and chat with people and organizations using Microsoft identities](https://learn.microsoft.com/en-us/microsoftteams/trusted-organizations-external-meetings-chat). Use it to separate federation blocks from throttling.
- When onboarding a new SMB customer, check `IsInitial`-only domains in the first hour. Running `Scripts/Get-MOERAOnlyTenantExposure.ps1` as part of onboarding catches Teams, Exchange and default-domain exposure together.
