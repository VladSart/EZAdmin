# Entra ID — Agent Instructions

## What's in this folder

Microsoft Entra ID (formerly Azure Active Directory) — the identity foundation everything else depends on.

Covers:
- **Device join** — Entra join, Hybrid join, PRT (Primary Refresh Token) issues
- **User identity** — UPN conflicts, sync issues, guest accounts, B2B
- **Conditional Access** — policy design, break-glass, legacy auth, named locations
- **App registrations + service principals** — OAuth flows, client secrets, API permissions
- **Entra Connect / Sync** — attribute conflicts, password hash sync, staging mode
- **Privileged Identity Management (PIM)** — role activation, access reviews
- **Graph API** — scripting against Entra, batch queries, permissions model

---

## Before responding, also check

- `Security/ConditionalAccess/` — CA policy is a sub-domain of Entra but complex enough to have its own module
- `Intune/` — most device compliance issues loop back to Entra join state
- `Autopilot/` — Autopilot enrollment failures are almost always Entra + Intune combined
- `EntraID/Graph/` — for automating anything against Entra via PowerShell or flows

---

## Key first commands (always run first)

```powershell
# On the device — everything about device identity
dsregcmd /status

# Key fields:
#   AzureAdJoined      = YES/NO (direct Entra join)
#   DomainJoined       = YES/NO (on-prem AD)
#   AzureAdPrt         = YES/NO (token for SSO — if NO, user can't SSO)
#   AzureAdPrtExpiry   = token expiry time
#   DeviceId           = Entra device object ID

# Force PRT refresh (if AzureAdPrt = NO)
# Lock screen → unlock → PRT refreshes on sign-in

# Check sign-in logs for a user (requires Graph or Entra portal)
Get-MgAuditLogSignIn -Filter "userPrincipalName eq 'user@contoso.com'" -Top 10 |
  Select CreatedDateTime, AppDisplayName, Status, ConditionalAccessStatus
```

---

## Folder contents

| File | What it covers |
|------|---------------|
| `Troubleshooting/HybridJoin-B.md` | Hotfix: HAADJ failures, Entra Connect sync |
| `Troubleshooting/PRT-Issues-B.md` | Hotfix: PRT missing, SSO broken, CA failing |
| `Troubleshooting/DynamicGroups-B.md` | Hotfix: dynamic group membership rule not evaluating, paused processing, sync lag |
| `Troubleshooting/DynamicGroups-A.md` | Deep dive: dynamic group evaluation pipeline, rule syntax engine, downstream consumer lag |
| `Troubleshooting/PasswordProtection-B.md` | Hotfix: Smart Lockout, banned password rejections, hybrid writeback/on-prem agent issues |
| `Troubleshooting/CAE-B.md` | Hotfix: Continuous Access Evaluation — unexpected sign-outs, strict location enforcement |
| `Troubleshooting/CAE-A.md` | Deep dive: CAE architecture, critical event revocation, claims challenges, strict location enforcement |
| `Scripts/Get-EntraDeviceHealth.ps1` | Device join state, PRT, compliance across fleet |
| `Scripts/Get-EntraConnectSyncErrors.ps1` | Export sync errors, attribute conflicts |
| `Graph/Useful-Queries.md` | Common Graph API queries for MSP reporting |

---

## Common entry points

- "User getting MFA prompt every time / SSO not working" → `Troubleshooting/PRT-Issues-B.md`
- "Hybrid join not completing" → `Troubleshooting/HybridJoin-B.md`
- "Device in Entra but Intune shows not enrolled" → `Intune/Troubleshooting/Enrollment-B.md`
- "Conditional Access blocking access incorrectly" → `Security/ConditionalAccess/`
- "Entra Connect attribute conflict / user not syncing" → `Troubleshooting/HybridJoin-B.md`
- "Service principal client secret expired (flow/app broken)" → `Scripts/` + rotate secret in Entra App Registrations
- "Guest user can't access SharePoint" → `EntraID/` B2B guest redemption + `M365/SharePoint-OneDrive/`
- "Dynamic group not picking up new members / license not assigning" → `Troubleshooting/DynamicGroups-B.md`
- "User locked out repeatedly / new password keeps getting rejected" → `Troubleshooting/PasswordProtection-B.md`
- "User randomly signed out mid-session" / "session ended after password reset or VPN change" → `Troubleshooting/CAE-B.md`

---

## Response format reminder

Always respond with all three layers:
1. **Hotfix** — `dsregcmd /status` → identify the broken Entra layer → fix → validate
2. **Deep Dive** — identity architecture, token model, sync topology
3. **Learning Pointers** — what to go deeper on after the ticket is closed
