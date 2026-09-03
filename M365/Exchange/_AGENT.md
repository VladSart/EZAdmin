# Exchange Online — Agent Instructions

## What's in this folder

Exchange Online — cloud-hosted email, calendar, and messaging within Microsoft 365.

Covers:
- **Mail flow** — inbound/outbound delivery, NDRs, bounces, stuck messages, transport rules, connectors
- **Shared mailboxes** — access, permissions, AutoMapping, Send As, Send On Behalf, calendar delegates
- **Calendars** — delegate access, room/resource mailboxes, free/busy visibility, calendar sharing
- **Hybrid coexistence** — on-prem Exchange routing through Exchange Online, Hybrid Configuration Wizard, hybrid connectors, certificate issues
- **Spam and phishing** — EOP (Exchange Online Protection) policies, Safe Sender lists, quarantine, anti-phishing rules
- **Connectors** — inbound/outbound connectors, partner connectors, on-prem relay, TLS enforcement
- **Outlook desktop client** — classic Outlook vs. New Outlook architecture split, Autodiscover resolution, connection status states, OST corruption, credential/token loops, COM add-in conflicts
- **Direct Send abuse** — unauthenticated SMTP delivery to the tenant's own MX endpoint spoofing internal senders, `RejectDirectSend` mitigation, SPF/anti-phishing hardening — distinct from the unrelated "direct send" hybrid outbound-routing term used in `Mail-Flow-A.md` (see that file's disambiguation note)
- **Mailbox migration batches** — Cutover, Staged (legacy Exchange 2003/2007 only), IMAP (incl. Google Workspace), Remote Move (hybrid onboarding/offboarding), and Cross-tenant (tenant-to-tenant) migration batch mechanics, throttling, and cross-tenant organization-relationship prerequisites — distinct from `Hybrid-Coexistence-A.md`, which covers the hybrid topology/HCW/mail-routing side, not batch migration internals
- **Cloud-managed remote mailboxes** — `IsExchangeCloudManaged` per-mailbox Exchange-attribute SOA transfer to Exchange Online (the "retire the Last Exchange Server" on-ramp), writeback to on-prem AD via Microsoft Entra Cloud Sync, and the tenant-wide SOA default — distinct from object-level SOA (identity attributes), which this topic explicitly does not cover
- **Cross-tenant Calendar/Free-Busy/MailTips sharing (EWS → M365 XTAP)** — migrating tenant-to-tenant Organization Relationship, Availability Address Space (OrgWideFBToken), and Sharing Policy configurations to Microsoft 365 Cross-Tenant Access Policy ahead of the October 1, 2026 EWS deprecation deadline in Exchange Online — distinct from `EntraID/Troubleshooting/CrossTenant-B.md` (B2B guest collaboration), which the new XTAP capability layer builds on top of rather than replaces

---

## Before responding, also check

- `EntraID/` — authentication failures, SSO issues, OAuth token errors affecting Outlook and OWA
- `Security/Defender/` (when built) — Defender for Office 365, Safe Links, Safe Attachments, ZAP policies
- `M365/Licensing/` — missing Exchange Plan 1 or Plan 2 service plan; shared mailbox licensing for archiving
- `Security/ConditionalAccess/` — CA policies blocking Outlook (modern auth) or ActiveSync (legacy auth)

---

## Folder contents

| File | What it covers |
|------|---------------|
| `Mail-Flow-B.md` | Hotfix: email not arriving, bouncing, stuck, going to spam, NDR codes |
| `Mail-Flow-A.md` | Deep dive: mail flow architecture, transport rules, connectors, DMARC |
| `SharedMailbox-B.md` | Hotfix: can't access shared mailbox, Send As failing, AutoMapping, calendar permissions |
| `SharedMailbox-A.md` | Deep dive: shared mailbox object model, delegation mechanics, licensing rules, hybrid mastering |
| `Hybrid-Coexistence-B.md` | Hotfix: on-prem to EXO routing, hybrid connector failures, certificate expiry |
| `Hybrid-Coexistence-A.md` | Deep dive: hybrid topology, centralised vs decentralised routing, HCW internals |
| `TransportRules-B.md` | Hotfix: rule doesn't fire, wrong rule fires, priority/StopRuleProcessing conflicts, DLP overlap |
| `TransportRules-A.md` | Deep dive: ETR evaluation order, condition/exception AND/OR logic, multi-rule action stacking, DLP boundary |
| `Outlook-Client-B.md` | Hotfix: profile/Autodiscover failures, Disconnected/Trying-to-connect/Needs-Password loops, OST corruption, COM add-in conflicts, New Outlook cache issues |
| `Outlook-Client-A.md` | Deep dive: classic Outlook vs. New Outlook architecture split, Autodiscover v2/v1/SCP resolution chain, Cached Exchange Mode/OST model, modern-auth token caching |
| `DirectSendAbuse-B.md` | Hotfix: unauthenticated Direct Send abuse — confirm RejectDirectSend state, spot a spoofed message via headers, harden SPF, migrate legitimate dependents |
| `DirectSendAbuse-A.md` | Deep dive: why Direct Send bypasses the intra-org SPF exemption, the 2025–2026 abuse campaign and Microsoft's architectural-limitation stance, RejectDirectSend mechanics, KQL detection query |
| `MigrationBatches-B.md` | Hotfix: stalled/failed migration batches, WLM/MRS throttling vs. real failure, AutoSuspended/Synced stuck users, MRSProxy connection limit, cutover single-batch limit, cross-tenant org-relationship pre-checks |
| `MigrationBatches-A.md` | Deep dive: Cutover/Staged/IMAP/Remote Move/Cross-tenant migration architecture, MRS/MRSProxy/WLM throttling stack, Data Consistency Score skipped-item handling, cross-tenant pre-staging playbook |
| `CloudManagedMailboxes-B.md` | Hotfix: SOA transfer command fails/reverts, writeback not reaching on-prem, race condition from flipping the flag too soon, tenant-wide SOA enabled too early, offboarding a cloud-managed mailbox |
| `CloudManagedMailboxes-A.md` | Deep dive: `IsExchangeCloudManaged` architecture, identity vs. Exchange attribute model, writeback-supported attribute allow-list, Cloud Sync writeback configuration, tenant-wide SOA sequencing risk, LES decommission on-ramp |
| `Scripts/Get-MessageTrace.ps1` | Mail flow trace wrapper for stuck/bounced messages |
| `Scripts/Get-DirectSendExposureAudit.ps1` | RejectDirectSend state, per-domain SPF enforcement qualifier, anti-phish spoof intelligence, message-trace sweep flagging candidate Direct Send senders |
| `Scripts/Get-OutlookClientHealth.ps1` | Device-local Outlook client diagnostic — client type, profile, OST freshness, Autodiscover DNS, cached credentials, COM add-ins, optional CA sign-in check |
| `Scripts/Get-ExchangeHybridHealth.ps1` | Hybrid connector/certificate health check |
| `Scripts/Get-MailboxAuditReport.ps1` | General mailbox permissions/forwarding/audit-log report |
| `Scripts/Get-DKIMDMARCReport.ps1` | Per-domain SPF/DKIM/DMARC audit |
| `Scripts/Get-EOPQuarantineReport.ps1` | Quarantine + Tenant Allow/Block List audit |
| `Scripts/Get-ArchiveRetentionAudit.ps1` | Fleet-wide archive/retention/litigation hold audit |
| `Scripts/Get-OMEConfigurationAudit.ps1` | Message encryption (IRM/OME) configuration audit |
| `Scripts/Get-PublicFolderHealthReport.ps1` | Public folder hierarchy sync/permission audit |
| `Scripts/Get-RoomMailboxAudit.ps1` | Room mailbox booking/calendar/sign-in audit |
| `Scripts/Get-SharedMailboxAudit.ps1` | Fleet-wide shared mailbox type/delegation/licensing/quota/sign-in audit |
| `Scripts/Get-TransportRuleConflictAudit.ps1` | Tenant-wide ETR conflict audit — stuck test mode, priority short-circuits, broad conditions, unscoped high-impact actions, DLP overlap review |
| `Scripts/Get-MigrationBatchHealth.ps1` | Tenant-wide migration batch/user health audit — real failures vs. throttling, skipped-item approval status, cutover limit risk, optional cross-tenant org-relationship and post-migration licensing checks |
| `Scripts/Get-CloudManagedMailboxAudit.ps1` | Read-only audit of `IsExchangeCloudManaged` fleet state, tenant-wide SOA default, on-prem Connect Sync build compliance, and recent-on-prem-change race-condition flagging |
| `CrossTenantCalendarSharing-B.md` | Hotfix: EWS-dependent legacy config inventory, Entra M365 Collaboration trust + XTAP capability precedence checks, migrating a partner before the Oct 1 2026 EWS deprecation deadline, MailTips-vs-Free/Busy independent capability gotcha, inbound-only/non-reciprocal bidirectional gap |
| `CrossTenantCalendarSharing-A.md` | Deep dive: legacy object-per-relationship vs. new capability-per-partner architecture, two-layer Entra-trust + M365-capability model, inbound-only non-reciprocal design, legacy-always-wins precedence rule, multi-domain Sharing Policy security-group-scoping migration playbook |
| `Scripts/Get-CrossTenantSharingMigrationAudit.ps1` | Read-only inventory of legacy Organization Relationship/Availability Address Space/Sharing Policy objects, mailbox blast-radius sizing, and Entra Cross-Tenant Access Policy partner trust/XTAP capability presence check |

---

## Common entry points

- "User not receiving emails / emails bouncing" → `Mail-Flow-B.md`
- "Email going to spam / quarantine incorrectly" → `Mail-Flow-B.md` (spam filter section)
- "Email stuck in transit / delayed hours/days" → `Mail-Flow-B.md` (4.4.7 NDR section)
- "Can't open shared mailbox in Outlook" → `SharedMailbox-B.md`
- "Shared mailbox not showing in Outlook left-pane" → `SharedMailbox-B.md` (AutoMapping)
- "Send As / Send On Behalf not working from shared mailbox" → `SharedMailbox-B.md`
- "Shared mailbox calendar permissions broken" → `SharedMailbox-B.md` (calendar delegate section)
- "Fleet audit of all shared mailboxes for hygiene issues" → `Scripts/Get-SharedMailboxAudit.ps1`
- "On-prem users can't email cloud users or vice versa" → `Hybrid-Coexistence-B.md`
- "Hybrid connector certificate expired" → `Hybrid-Coexistence-B.md`
- "SPF / DKIM / DMARC failing, email rejected by recipient" → `Mail-Flow-B.md`
- "Transport rule blocking legitimate email" → `Mail-Flow-B.md` (transport rules section)
- "Transport rule doesn't seem to do anything" / "rule stuck in test mode" → `TransportRules-B.md` (Fix 1)
- "Two transport rules conflicting / wrong one firing / priority order" → `TransportRules-B.md` (Fix 3/4)
- "Transport rule and DLP policy both acting on same message" → `TransportRules-B.md` (Fix 6)
- "Fleet audit of all transport rules for conflict risks" → `Scripts/Get-TransportRuleConflictAudit.ps1`
- "Outlook shows Disconnected / Trying to connect / Needs Password" → `Outlook-Client-B.md`
- "Can't create Outlook profile / new profile builds as IMAP" → `Outlook-Client-B.md` (Fix 1)
- "Outlook folders won't expand, search broken, random crashes" → `Outlook-Client-B.md` (Fix 5 — OST rebuild)
- "New Outlook missing calendar/delegates for an on-prem or hosted mailbox" → `Outlook-Client-A.md` (New Outlook treats non-EXO mailboxes as generic IMAP — expected, not a bug)
- "Outlook hangs on launch or on send/print/invite" → `Outlook-Client-B.md` (Fix 6 — COM add-in isolation)
- "Device-local Outlook client diagnostic before escalating" → `Scripts/Get-OutlookClientHealth.ps1`
- "Getting phishing reports of mail that looks like it's from a coworker/executive, no external banner" → `DirectSendAbuse-B.md` (confirm via headers before assuming mailbox compromise)
- "Should we turn on RejectDirectSend / will it break anything" → `DirectSendAbuse-B.md` Triage step 5 + `Scripts/Get-DirectSendExposureAudit.ps1` (inventory before blocking)
- "Migration batch stuck at Syncing / mailboxes stalled" → `MigrationBatches-B.md` Triage (rule out WLM/MRS throttling before escalating)
- "Cutover migration says a batch already exists" → `MigrationBatches-B.md` Fix 5
- "Cross-tenant mailbox migration batch won't create / fails pre-check" → `MigrationBatches-B.md` Fix 6, `MigrationBatches-A.md` Playbook 3 (pre-staging is the most common cause)
- "Migration report shows skipped items / data loss warning" → `MigrationBatches-B.md` Fix 4
- "Fleet audit of all migration batches before/after a cutover weekend" → `Scripts/Get-MigrationBatchHealth.ps1`
- "Can't edit a mailbox's custom attribute / proxy address from Exchange Online, only works on-prem" → `CloudManagedMailboxes-B.md` Fix 1/2 (confirm `IsExchangeCloudManaged` state and sync timing first)
- "Edited an attribute in EXO and it reverted back" → `CloudManagedMailboxes-B.md` Fix 2 (race condition — flipped SOA too soon after last on-prem change)
- "Attribute change in Exchange Online isn't showing up in on-prem AD" → `CloudManagedMailboxes-B.md` Fix 3 (writeback configuration or attribute not on the writeback allow-list)
- "Can't change a cloud-managed user's display name / title from Exchange Online" → `CloudManagedMailboxes-B.md` Fix 5 (expected — identity attributes are always on-prem-only)
- "New on-prem mailboxes broken after turning on cloud-managed-by-default" → `CloudManagedMailboxes-B.md` Fix 6 (unsupported sequencing — escalate to Microsoft Support, do not self-remediate)
- "Fleet audit of cloud-managed mailbox state / SOA rollout readiness" → `Scripts/Get-CloudManagedMailboxAudit.ps1`
- "Calendar Free/Busy or MailTips broken with an external partner after Sept/Oct 2026" → `CrossTenantCalendarSharing-B.md` Triage (check legacy-object precedence and Entra trust layer first)
- "Need to migrate cross-tenant calendar/Free-Busy/MailTips sharing before EWS deprecation" → `CrossTenantCalendarSharing-B.md` Fix 1, `CrossTenantCalendarSharing-A.md` Playbook 1
- "Fleet audit of legacy EWS-dependent sharing config before the Oct 2026 deadline" → `Scripts/Get-CrossTenantSharingMigrationAudit.ps1`

---

## Key diagnostic commands

```powershell
# Connect to Exchange Online
Connect-ExchangeOnline -UserPrincipalName admin@contoso.com

# Mail flow trace — covers last 10 days, 250 results max per query
Get-MessageTrace `
  -SenderAddress sender@contoso.com `
  -RecipientAddress recipient@contoso.com `
  -StartDate (Get-Date).AddDays(-2) `
  -EndDate (Get-Date) |
  Select Received, SenderAddress, RecipientAddress, Subject, Status, ToIP, FromIP

# Detailed trace for a specific message (get MessageTraceId from above)
Get-MessageTraceDetail -MessageTraceId <guid> -RecipientAddress recipient@contoso.com

# Check mailbox existence and properties
Get-Mailbox -Identity shared@contoso.com |
  Select DisplayName, PrimarySmtpAddress, RecipientTypeDetails, IsShared, LitigationHoldEnabled

# Check mobile device sync state (ActiveSync / Outlook Mobile)
Get-MobileDeviceStatistics -Mailbox user@contoso.com |
  Select DeviceFriendlyName, LastSyncAttemptTime, Status, DeviceOS

# Test client connectivity (MAPI/RPC)
Test-MAPIConnectivity -Identity user@contoso.com

# Check mailbox permissions (for shared mailbox issues)
Get-MailboxPermission -Identity shared@contoso.com |
  Where-Object { $_.User -notlike "NT AUTHORITY*" } |
  Select User, AccessRights, IsInherited

# Check transport rules (mail flow rules)
Get-TransportRule | Select Name, State, Priority, Description | Sort-Object Priority

# Check connectors
Get-InboundConnector | Select Name, Enabled, ConnectorType, TlsSenderCertificateName
Get-OutboundConnector | Select Name, Enabled, ConnectorType, SmartHosts

# Check anti-spam / quarantine policies
Get-HostedContentFilterPolicy | Select Name, SpamAction, HighConfidenceSpamAction, BulkSpamAction
```

---

## Key dependency chain

```
[User identity in Entra ID]
         │
         ▼
[Exchange Online mailbox provisioned]
  (requires Exchange Plan 1 or Plan 2 licence)
         │
         ▼
[DNS: MX record → *.mail.protection.outlook.com]
[DNS: Autodiscover CNAME → autodiscover.outlook.com]
         │
         ▼
[Exchange Online Protection (EOP)]
  Anti-spam → Anti-phishing → Safe Attachments/Links
         │
         ▼
[Transport Rules evaluated]
  (org-level rules, then connector rules)
         │
         ▼
[Mailbox Rules evaluated]
  (user-level Inbox rules — run AFTER transport rules)
         │
         ▼
[Delivery to mailbox]
  (subject to mailbox quota, litigation hold, archive policy)
         │
         ▼
[Client authentication]
  Modern Auth (MAPI/OAuth) → Outlook, OWA, Outlook Mobile
  Legacy Auth (Basic/NTLM) → blocked by Conditional Access in most tenants
```

**Hybrid add-on (when on-prem Exchange exists):**
```
[On-prem Exchange] → [Hybrid Send Connector] → [EXO Protection] → [Cloud mailbox]
                  ← [Hybrid Receive Connector] ←
  (certificate on hybrid connector must be valid and match TLS name)
```

---

## Response format reminder

Always respond with all three layers:
1. **Hotfix** — `Get-MessageTrace` → identify failure point in the chain → fix → validate delivery
2. **Deep Dive** — mail flow architecture, EOP pipeline, transport rule evaluation order, hybrid topology
3. **Learning Pointers** — what to go deeper on after the ticket is closed
