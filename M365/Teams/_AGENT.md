# Microsoft Teams — Agent Instructions

## What's in this folder
Runbooks and scripts for Microsoft Teams issues faced by MSP L2/L3 engineers. Covers calling/PSTN problems, device policies, meeting configuration, Teams-specific governance topics (external access/federation, guest access, shared channels, channel policies, retention), and the passwordless Entra Resource Accounts authentication transition for shared devices (GA August 2026). Also covers **Automatic/Compliance Recording for Call Queue** (GA-track August 2026, PowerShell-only configuration) — automatic inbound call-queue recording/transcription to SharePoint, distinct from general Teams meeting cloud recording and from per-user compliance recording policies. Also covers **Unified App & Agent Management** (Teams admin center ↔ Microsoft 365 admin center convergence, Phase A/availability GA + Phase B/installation rolling out late Aug-mid Sept 2026 per MC796790) — the phased architecture unifying app/agent availability and installation governance across TAC and MAC, including the permanent app-setup-policy installation exclusion. Also covers two September 2026 Message Center-only additions: **mandatory pre-meeting consent** (MC1454114, admin-authored join-flow acknowledgment gate applying to every participant including organizers, phased rollout by cloud through Dec 2026) and **outbound external messaging limits for MOERA-only tenants** (MC1463510, default-on abuse-protection throttle for tenants without a custom domain, GA worldwide 15 Sept 2026).

## Before responding, also check
- `M365/_AGENT.md` — M365-wide triage starting points and licensing checks
- `EntraID/` — if Teams sign-in is failing (token/conditional access), or for Entra cross-tenant access settings that govern guest access and shared channels
- `Security/ConditionalAccess/` — if devices are blocked from Teams, or if MFA/compliant-device trust is blocking external users despite B2B direct connect being enabled
- `M365/Exchange/` — if calendar integration or meeting invites are broken
- `Intune/` — if Teams app deployment or update issues on managed devices
- `M365/SharePoint-OneDrive/Permissions-A.md` — if a Teams guest can't see files despite guest access being enabled (SharePoint site-level sharing is a separate gate)

## Folder contents

| File | What it covers |
|------|---------------|
| `Calling-B.md` | Teams PSTN calling issues — no dial tone, call quality, direct routing, Operator Connect |
| `Calling-A.md` | Teams calling deep dive — voice routing architecture, dial plans, PSTN gateway/Operator Connect internals |
| `Device-Policies-B.md` | Teams device policies — meeting room devices, IP phones, update rings, Teams Rooms |
| `Device-Policies-A.md` | Teams device policy deep dive — policy architecture, precedence, direct vs. group assignment, MTR/IP phone management planes |
| `Meeting-Policies-B.md` | Meeting policy hotfix — recording/lobby/screen-share restrictions not applying |
| `Meeting-Policies-A.md` | Meeting policy deep dive — policy sync, group assignment rank conflicts, organizer-vs-attendee precedence |
| `Teams-Rooms-A.md` | Teams Rooms (MTR) deep dive — resource account model, licensing, device management plane |
| `Teams-Rooms-B.md` | Teams Rooms hotfix — device not signing in, offline, wrong meeting policy |
| `PasswordlessResourceAccounts-A.md` | Passwordless Entra Resource Accounts deep dive (GA Aug 2026) — device-bound credential architecture, migration mechanics, hybrid-sync password limitations, WHfB-equivalent trust model |
| `PasswordlessResourceAccounts-B.md` | Passwordless Entra Resource Accounts hotfix — migration eligibility failures, stuck-on-sign-in-screen, device reset/replacement recovery |
| `ExternalAccess-B.md` | External collaboration hotfix — federation blocked, guest invite stuck, shared channel/B2B direct connect failures |
| `ExternalAccess-A.md` | External collaboration deep dive — the three distinct architectures (federation, guest access, Teams Connect shared channels), cross-tenant access precedence, mutual B2B direct connect config |
| `Scripts/Get-TeamsCallQuality.ps1` | Call quality dashboard (CQD-style) for a user or fleet |
| `Scripts/Get-TeamsMeetingPolicyAudit.ps1` | Meeting policy + group assignment rank-conflict audit, optional per-user effective policy resolution |
| `Scripts/Get-TeamsRoomDeviceHealth.ps1` | Teams Rooms resource account and licensing health fleet report |
| `Scripts/Get-TeamsDevicePolicyAudit.ps1` | Device account health, update/IP-phone policy assignment, and calendar auto-accept audit for resource accounts |
| `Scripts/Get-TeamsExternalAccessAudit.ps1` | Tenant-wide federation, guest invite, and cross-tenant B2B direct connect posture audit — flags stale invites, dormant guests, incomplete partner overrides |
| `CallQueueRecording-A.md` | Automatic/Compliance Recording for Call Queue deep dive — the three separate recording mechanisms (Automatic, Compliance for Call Queue, per-user Compliance Recording Policy), SharePoint provisioning coupling, immutable template fields |
| `CallQueueRecording-B.md` | Call Queue recording hotfix — template not assigned, Conference mode/routing prerequisites, agents can't view recordings, SharePoint site drift, outbound calls not recorded |
| `Scripts/Get-CallQueueRecordingAudit.ps1` | Fleet audit of call queues for Automatic Recording template assignment, prerequisite gaps, and SharePoint site-admin resilience; optional Queues App license check |
| `Scripts/Get-PasswordlessMigrationReadiness.ps1` | Entra ID-side readiness audit for passwordless resource-account migration — license eligibility, hybrid-sync password-cleanup path, password-expiration policy, sign-in staleness heuristic |
| `UnifiedAppAgentManagement-A.md` | Unified App & Agent Management deep dive — TAC/MAC convergence architecture, Phase A (availability, GA)/Phase B (installation, rolling Aug-Sept 2026) split, the permanent app-setup-policy exclusion, Global-Admin-only consent wizard mechanics |
| `UnifiedAppAgentManagement-B.md` | Unified App & Agent Management hotfix — TAC/MAC availability mismatches, un-unified tenant wizard walkthrough, app-setup-policy exclusion triage, stuck-wizard/Global-Admin-consent-gate tickets |
| `Scripts/Get-UnifiedAppManagementAudit.ps1` | Teams app setup policy audit — flags every app pinned/installed via a setup policy as permanently excluded from Phase B unified installation sync, with optional app-name filter for ticket-specific checks |
| `PreMeetingConsent-A.md` | Mandatory pre-meeting consent deep dive (MC1454114) — join-flow acknowledgment gate architecture, universal no-exemption participant model, multi-language content/fallback, audit log recording, three-ring cloud rollout timing |
| `PreMeetingConsent-B.md` | Mandatory pre-meeting consent hotfix — disambiguating from recording consent, policy authored-vs-enabled triage, language fallback, rollout-ring "missing entirely" checks |
| `ExternalMessagingLimits-B.md` | External messaging limits hotfix (MC1463510) — MOERA-only tenant scope check via `Get-MgDomain`, unpublished-threshold triage, custom-domain fix to permanently exit scope |

## Common entry points

- "User can't make calls / no dial tone" → `Calling-B.md` Triage — check license, number assignment, dial plan
- "Poor call quality / choppy audio" → `Calling-B.md` Fix 3 (QoS / network)
- "Teams Room device not signing in" → `Device-Policies-B.md` Fix 1
- "IP phone showing as offline" → `Device-Policies-B.md` Triage
- "Teams device won't update firmware" → `Device-Policies-B.md` Fix 4
- "Room shows wrong meeting info / calendar not auto-accepting" → `Device-Policies-B.md` Fix 6, or `Scripts/Get-TeamsDevicePolicyAudit.ps1` for a fleet-wide check
- "Can't record / different users get different meeting features" → `Meeting-Policies-B.md`, use `Scripts/Get-TeamsMeetingPolicyAudit.ps1` for rank-conflict detection
- "Call queue calls aren't being recorded / agents can't see recordings" → `CallQueueRecording-B.md` Triage — confirm template assignment and Conference mode first
- "Agent's outbound calls from a recorded queue aren't recorded" → `CallQueueRecording-B.md` Fix 7 (expected — needs a separate per-user compliance recording policy)
- "App/agent shows different availability or install state in Teams admin center vs. Microsoft 365 admin center" → `UnifiedAppAgentManagement-B.md` Triage — check unification phase and app-setup-policy exclusion first, `Scripts/Get-UnifiedAppManagementAudit.ps1` for setup-policy cross-reference
- "Meeting requires me to click agree/consent before I can even join" → `PreMeetingConsent-B.md` Triage — first confirm this is the new join-flow gate, not the existing recording-consent banner
- "User temporarily can't message an external contact / Teams shows an external-messaging-limited notification" → `ExternalMessagingLimits-B.md` Triage — confirm tenant is MOERA-only via `Get-MgDomain` before assuming this feature is the cause
- "User can't join meetings" → check `EntraID/` for auth, then CA policy
- "Teams not syncing calendar" → `M365/Exchange/` — EWS and Autodiscover
- "Can't chat/call someone at another company" → `ExternalAccess-B.md` Fix 1/2 (federation)
- "Guest can't access team" / guest invite stuck pending → `ExternalAccess-B.md` Fix 3/4 (guest access)
- "Can't add external partner to a shared channel" / "Teams Connect not working" → `ExternalAccess-B.md` Fix 5/6 (B2B direct connect)
- "Can't record meetings" → check Teams meeting policy (AllowCloudRecording)
- "Room won't migrate to passwordless / migration option missing in PMP" → `PasswordlessResourceAccounts-B.md` Triage — check license SKU and PMP Migration tab
- "Teams Rooms on Windows stuck on sign-in screen after migration" → `PasswordlessResourceAccounts-B.md` Fix 5
- "Device was reset/replaced and now needs a password again" → `PasswordlessResourceAccounts-B.md` Fix 6 — this is expected, not a bug

## Key diagnostic commands

```powershell
# Connect to Teams PowerShell
Connect-MicrosoftTeams

# Check user's Teams calling configuration
Get-CsOnlineUser -Identity <UPN> | Select-Object DisplayName, LineUri, EnterpriseVoiceEnabled, HostedVoiceMail, TeamsUpgradeMode, OnlineVoiceRoutingPolicy, DialPlan

# Check assigned calling license
Get-MgUserLicenseDetail -UserId <UPN> | Select-Object SkuPartNumber

# List all Teams policies assigned to user
Get-CsUserPolicyAssignment -Identity <UPN> | Format-Table PolicyType, PolicyName

# Check Teams Rooms / device accounts
Get-CsOnlineUser -Filter {InterpretedUserType -eq "SfbOnpremUser" -or InterpretedUserType -eq "TeamsOnlyUser"} | Where-Object {$_.DisplayName -like "*room*"} | Select-Object DisplayName, LineUri, TeamsUpgradeMode

# Test PSTN connectivity (requires Teams admin)
# Get-CsOnlinePstnUsage | Select-Object -ExpandProperty Usage
# Get-CsVoiceRoute | Select-Object Name, NumberPattern, PstnGatewayList | Format-Table -AutoSize

# Check external access / federation posture
Get-CsTenantFederationConfiguration | Select-Object AllowFederatedUsers, AllowedDomains, BlockedDomains

# Check cross-tenant access settings (governs guest access + shared channels)
Get-MgPolicyCrossTenantAccessPolicyDefault | Select-Object B2bCollaborationInbound, B2bDirectConnectInbound
```

## Key dependency chain

```
Entra ID identity (not blocked, MFA working)
    └── Teams license assigned (Teams Essentials / M365 E3 / Teams Phone add-on)
        └── Teams upgrade mode (TeamsOnly for full features)
            └── Teams meeting policy (recording, transcription, guest join)
                └── Teams app setup policy (pinned apps, side-loading)
                    └── Calling policy (PSTN calling enabled)
                        └── Voice routing policy (direct routing or Operator Connect)
                            └── Dial plan (E.164 normalization)
                                └── Phone number assigned (LineUri)
                                    └── PSTN CALLING FUNCTIONAL
```

## Response format reminder (always 3 layers)

1. **Triage** — identify the failure layer (license? policy? number? routing?) in 60 seconds
2. **Fix** — targeted PowerShell remediation, least-privilege changes
3. **Validate** — confirm with test call or policy re-read before closing
