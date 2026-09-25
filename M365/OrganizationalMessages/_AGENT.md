# Organizational Messages — Agent Instructions

## What's in this folder

Microsoft 365 **Organizational messages**: admin-authored or Microsoft template in-product messages, sent to Windows 11 (Spotlight lock screen, Taskbar, Notification Center), Teams, and email. Authoring, approval, targeting, and reporting live in the **Microsoft 365 admin center** (Reports > Organizational messages), gated by the Entra roles *Organizational Messages Writer* / *Approver*. Whether Windows messages ever render depends on **device-side Experience Policy CSPs**, mostly deployed through Intune. The legacy Intune authoring UI was removed in 2024.

---

## Before responding, also check

- `Intune/Troubleshooting/` security baseline and device restriction runbooks: Spotlight/cloud-content blocks from baselines are the #1 device-side cause
- `M365/Copilot/_AGENT.md`: the Usage targeting segments (Inactive Copilot users) and the Copilot adoption templates
- `EntraID/Troubleshooting/PIM-*.md`: if Writer/Approver roles are PIM-eligible rather than active
- `Windows/_AGENT.md`: edition upgrade (Pro → Enterprise subscription activation), which Windows channels need

---

## Folder contents

| File | What it covers |
|------|---------------|
| `OrganizationalMessages-B.md` | Hotfix: "message is Active but nobody sees it", MDM-only `EnableOrganizationalMessages`, the Spotlight master switch and GPO CloudContent blockers, network endpoints, pull-delivery timing, Taskbar KB5094126, roles/licensing/Pro edition, locale mismatch |
| `OrganizationalMessages-A.md` | Deep dive: control plane (states, approval, targeting via Entra groups / Adoption Score group-level aggregates / Usage segments) vs data plane (pull-based Windows delivery, CSP dependency tree, Enterprise-only editions), Intune → M365 admin center history, localisation model, MSP playbooks |
| `Scripts/Get-OrgMessagesDeviceReadiness.ps1` | Device + user readiness check: edition, build, join state, MDM Experience CSP values, GPO blockers, endpoint reachability, Taskbar KB, display language. Exports CSV |

---

## Common entry points

- "We scheduled an org message and no one got it" → `OrganizationalMessages-B.md` Triage. Run `Scripts/Get-OrgMessagesDeviceReadiness.ps1` in a user session. Usually `EnableOrganizationalMessages` isn't deployed (default 0) or Spotlight is blocked by a baseline
- "Taskbar message never appears but Spotlight does" → B Fix 5 (KB5094126)
- "Can't find Organizational messages in Intune any more" → A § Scope. It moved to the M365 admin center, and Intune only deploys the enabling policies
- "Create your own is greyed out" / "no Department targeting" → B Fix 6 / A § Targeting (E3/E5 + Adoption Score group-level insights)
- "Only French users got it" / "German users didn't" → B Fix 7 (custom messages are locked to the author's display language)
- "Customer on Business Premium with Windows Pro" → A Playbook 3. Windows channels need Enterprise/Education
- "Allow our messages but not Microsoft's promotions" → Organizational messages Settings > turn off *Allow Microsoft messages to display*

---

## Key diagnostic commands

```powershell
# Edition / build (Enterprise|Education, 26100+)
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' | Select-Object EditionID, CurrentBuild, UBR
# MDM Experience values (user + device scopes)
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current' | ForEach-Object { $k = Join-Path $_.PSPath 'Experience'; if (Test-Path $k) { $_.PSChildName; Get-ItemProperty $k | Select-Object EnableOrganizationalMessages, AllowWindowsSpotlight, DisableCloudOptimizedContent } }
# GPO blockers
Get-ItemProperty HKCU:\Software\Policies\Microsoft\Windows\CloudContent, HKLM:\Software\Policies\Microsoft\Windows\CloudContent -ErrorAction SilentlyContinue
# Endpoints
Test-NetConnection fd.api.orgmsg.microsoft.com -Port 443
Test-NetConnection ris.prod.api.personalization.ideas.microsoft.com -Port 443
```

---

## Key dependency chain

```
Writer role → message (custom → Approver before End date) → Scheduled → Active
   → Windows pull (hours → 24h+) → endpoints reachable
   → Win11 24H2/25H2 Enterprise/Education, Entra/hybrid joined
   → EnableOrganizationalMessages=1 (user, MDM-only)
   → AllowWindowsSpotlight=1 (parent of Tips/ActionCenter/LockScreen) + DisableCloudOptimizedContent=0
   → no CloudContent GPO block → locale match → rendered
```

---

## Response format reminder (always 3 layers)

1. **Triage first.** Is it tenant-side (role, state, approval, targeting) or device-side (edition, build, CSP, GPO, network)?
2. **Fix the specific failure** using the B runbook fix path.
3. **Confirm resolution.** Re-run the readiness script, then allow for pull latency (24 h+) before calling it failed.
