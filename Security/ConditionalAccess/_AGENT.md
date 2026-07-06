# Conditional Access — Agent Instructions

## What's in this folder

Microsoft Entra Conditional Access — policy design, conflict diagnosis, and break-glass management.

CA is the policy engine that decides: **given who you are, what device you're on, where you are, and what you're accessing — should we allow, block, or require more proof?**

Getting CA wrong silently breaks access for users or silently allows access that should be blocked. Both are bad.

---

## Before responding, also check

- `EntraID/` — device registration, PRT state, join type (CA evaluates all of this)
- `Intune/` — compliance state (CA can require compliant device — Intune is the source of truth)
- `M365/` — if access to a specific app (Exchange, SharePoint, Teams) is blocked

---

## The CA evaluation model (always understand this first)

```
Request arrives → Entra evaluates ALL applicable CA policies simultaneously
Each policy: IF [conditions match] → enforce [controls]

Conditions:
  Users / Groups / Roles
  Cloud apps (which app is being accessed)
  Device platforms
  Device state (compliant, Entra joined, Hybrid joined)
  Sign-in risk / User risk (Identity Protection)
  Named locations (IP ranges, countries)
  Client apps (browser, legacy auth, modern auth)

Controls (grant):
  Require MFA
  Require compliant device
  Require Hybrid joined device
  Require approved app
  Block

Result: ALL matching policies' controls must be satisfied
  → If policy A requires MFA and policy B requires compliant device, user needs BOTH
  → Block always overrides Allow
```

---

## Folder contents

| File | What it covers |
|------|---------------|
| `CA-Troubleshooting-B.md` | Hotfix: CA blocking access, identifying the policy |
| `CA-Design-A.md` | Deep dive: CA architecture, design principles, common patterns |
| `CA-Design-B.md` | Hotfix: new/edited policy rollout gone wrong — rollback, pilot scoping, break-glass, overlap conflicts |
| `CA-Filters-B.md` | Hotfix: device filter unexpected include/exclude behaviour |
| `CA-Filters-A.md` | Deep dive: filter query language, physicalIds/extensionAttribute targeting, evaluation engine |
| `Named-Locations-B.md` | Hotfix: named location / IP-based CA condition issues |
| `Scripts/Get-CASignInAnalysis.ps1` | Analyse sign-in logs for CA failures across users |
| `Scripts/Get-NamedLocationAudit.ps1` | Named Location CIDR overlap/orphan/reference audit |
| `Scripts/Get-CADeviceFilterAudit.ps1` | Device filter mode/expression risk, orphaned extensionAttribute, Autopilot coverage audit |
| `Scripts/Get-CAPolicyDesignAudit.ps1` | Break-glass exclusion, pilot-scoping, legacy-auth-gap, recently-enabled, and cross-policy grant-conflict audit |

---

## Common entry points

- "User suddenly can't access Teams/Outlook/SharePoint" → `CA-Troubleshooting-B.md`
- "New policy deployed, now some users are locked out" → `CA-Troubleshooting-B.md`
- "Device shows compliant but CA still requires MFA" → check PRT state in `EntraID/`
- "Legacy app stopped working after CA change" → CA blocking legacy auth
- "Need break-glass accounts / emergency access" → `CA-Design-A.md`
- "Designing CA policy for a new client" → `CA-Design-A.md`
- "Just deployed/edited a policy and now users are locked out" → `CA-Design-B.md`
- "Device filter applying to wrong/no devices" → `CA-Filters-B.md` + `Scripts/Get-CADeviceFilterAudit.ps1`

---

## Response format reminder

Always respond with all three layers:
1. **Hotfix** — Sign-in logs → identify blocking policy → targeted fix → validate
2. **Deep Dive** — full CA evaluation chain, policy interaction, legacy auth implications
3. **Learning Pointers** — what to study to get better at CA design
