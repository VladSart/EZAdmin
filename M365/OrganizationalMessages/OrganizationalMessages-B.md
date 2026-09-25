# Organizational Messages (Microsoft 365 admin center) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

> **Context:** Organizational messages send admin-authored or Microsoft template messages to users. The Windows 11 channels are **Spotlight (lock screen), Taskbar, and Notification Center**. There are also **Teams** popovers and **email** (email is limited to 8 fixed Copilot templates). Messages are authored in the **Microsoft 365 admin center > Reports > Organizational messages**. The old Intune authoring experience was removed in 2024; Intune's remaining job is **the device policies that allow delivery**. Sources: [Organizational messages in the Microsoft 365 admin center](https://learn.microsoft.com/en-us/microsoft-365/admin/misc/organizational-messages-microsoft-365?view=o365-worldwide) (`ms.date` 2026-07-22, `updated_at` 2026-08-18), [FAQ](https://learn.microsoft.com/en-us/microsoft-365/admin/misc/organizational-messages-microsoft-365-faq?view=o365-worldwide) (`updated_at` 2026-06-12), and [Policy CSP – Experience](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-experience). All were fetched live on 2026-09-25.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Run these **on an affected device, in the affected user's session**. Several of the policies are user-scoped.

```powershell
# 1. OS build + edition  (Windows channels need Windows 11 24H2 [26100] / 25H2 [26200] ENTERPRISE per the product page)
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' | Select-Object ProductName, EditionID, DisplayVersion, CurrentBuild, UBR

# 2. Join state (only Entra joined / Entra hybrid joined supported)
dsregcmd /status | Select-String 'AzureAdJoined|DomainJoined|TenantName'

# 3. MDM-delivered Experience policies (user + device scopes)
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current' -ErrorAction SilentlyContinue | ForEach-Object {
  $k = Join-Path $_.PSPath 'Experience'
  if (Test-Path $k) { Get-ItemProperty $k | Select-Object @{n='Scope';e={$_.PSParentPath.Split('\')[-1]}}, EnableOrganizationalMessages, AllowWindowsSpotlight, AllowWindowsSpotlightOnActionCenter, AllowWindowsTips, ConfigureWindowsSpotlightOnLockScreen, DisableCloudOptimizedContent }
}

# 4. GPO blockers (CloudContent)
Get-ItemProperty 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent','HKLM:\Software\Policies\Microsoft\Windows\CloudContent' -ErrorAction SilentlyContinue |
  Select-Object PSPath, DisableWindowsSpotlightFeatures, DisableWindowsSpotlightOnActionCenter, ConfigureWindowsSpotlight, DisableSoftLanding, DisableCloudOptimizedContent

# 5. Service endpoints
'fd.api.orgmsg.microsoft.com','ris.prod.api.personalization.ideas.microsoft.com' | ForEach-Object { Test-NetConnection $_ -Port 443 -InformationLevel Quiet }
```

| Observation | Meaning | Do |
|---|---|---|
| `EditionID` = `Professional` | The Experience CSPs for these channels are **Enterprise/Education only**. Pro isn't supported | [Fix 6](#fix-6) |
| `CurrentBuild` below 26100 | The product page requires Windows 11 24H2/25H2 for Windows channels | Upgrade the OS, or use the Teams/email channels |
| `AzureAdJoined : NO` (workgroup or AD-only) | Not a supported device | Entra join or hybrid join first |
| `EnableOrganizationalMessages` missing or `0` | **Default is disabled.** There's no GPO equivalent. It must come from MDM | [Fix 1](#fix-1) |
| `AllowWindowsSpotlight = 0`, or GPO `DisableWindowsSpotlightFeatures = 1` | **Master kill switch.** The Tips/ActionCenter/LockScreen policies all depend on it | [Fix 2](#fix-2) |
| `DisableCloudOptimizedContent = 1` (MDM or GPO) | Cloud content is blocked | [Fix 2](#fix-2) |
| Endpoint test = `False` | Proxy or firewall is blocking the pull channel | [Fix 3](#fix-3) |
| Everything above is good, and the message was only scheduled today | Normal latency. Windows **pulls** messages, so expect "a few hours" plus up to 24 h or more | [Fix 4](#fix-4) |
| Taskbar messages never show, but Spotlight/Notification Center do | Taskbar needs **KB5094126** on 24H2/25H2 | [Fix 5](#fix-5) |
| Admin can't see Organizational messages, or can't create custom messages | Missing Entra role, or the tenant lacks E3/E5 licensing for custom/advanced features | [Fix 6](#fix-6) |
| Some users get it, others don't, same device config | **Locale mismatch.** A custom message only reaches users whose Windows display language matches the author's admin-center display language | [Fix 7](#fix-7) |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Tenant: commercial cloud (GCC / GCC-High NOT supported)
 ├─ Author: Entra role "Organizational Messages Writer"
 ├─ Custom msgs: Entra role "Organizational Messages Approver" (≠ author) approves before End date
 │     (else auto-rejected); tenant needs M365/O365/Windows E3/E5 for custom + advanced targeting
 ├─ Advanced targeting (Company/Department/Location): Adoption Score group-level insights ON
 │     (Usage targeting doesn't need this)
 └─ Message state: Scheduled → Active   (Failed = copy & recreate)
        │
Device (Windows channels only)
 ├─ Windows 11 24H2/25H2, Enterprise/Education edition
 ├─ Entra joined or Entra hybrid joined
 ├─ MDM policy (user scope unless noted):
 │     EnableOrganizationalMessages = 1   (default 0, MDM-only, no GPO)
 │     AllowWindowsSpotlight = 1  ── parent of ──┬─ AllowWindowsSpotlightOnActionCenter = 1
 │                                              ├─ ConfigureWindowsSpotlightOnLockScreen = 1|2
 │                                              └─ AllowWindowsTips = 1 (DEVICE scope)
 │     DisableCloudOptimizedContent = 0 (DEVICE scope)
 ├─ No blocking GPO (Software\Policies\Microsoft\Windows\CloudContent) / legacy Device restrictions
 ├─ HTTPS to fd.api.orgmsg.microsoft.com + ris.prod.api.personalization.ideas.microsoft.com
 ├─ Taskbar channel: KB5094126
 └─ User's Windows display language ∈ supported locales (and = author locale for custom msgs)
        │
Pull-based delivery (hours → 24h+; urgent = best-effort, cached 24h if offline)
```
</details>

---
## Diagnosis & Validation Flow

1. **Check message state in the admin center** (**Manage messages**, filter by Status).
   - `Pending approval` means the approver hasn't acted (custom messages only). `Rejected` means withdraw, edit, and resubmit. `Failed` means the service couldn't register it; **Copy** the message to retry. `Scheduled` means the start time hasn't arrived. `Active` means delivery is under way, so look at the device.

2. **Check the device policy result** (Triage 3). Expected: `EnableOrganizationalMessages = 1` in a user-SID scope key, `AllowWindowsSpotlight = 1`, and `DisableCloudOptimizedContent = 0`. If the Intune profile reports **Succeeded** but the value is missing, the profile was probably assigned to a **device** group. User-scoped settings need a **user** assignment, or a device assignment with a signed-in user.

3. **Check for conflicting sources.** A legacy Intune **Device restrictions** profile (Windows Spotlight section set to Block) or an on-prem GPO in `CloudContent` can override the allow policy. In the Intune admin center, filter **Configuration** by *Device restrictions* and check the **Windows Spotlight** section.

4. **Check the network** (Triage 5). Both must return `True`. If you use a proxy, run the test in the user context. Check SSL inspection bypass lists too.

5. **Check the locale.** Run `Get-WinUserLanguageList | Select-Object -First 1 LanguageTag` on the device, then compare it with the author's M365 admin-center display language (custom messages) or the supported locale list (pre-made).

6. **Check timing.** For a message that became Active less than 24 h ago with everything else correct, it's too early to say it's failed.

---
## Common Fix Paths

<details><summary id="fix-1">Fix 1 — Enable delivery policy (Intune Settings catalog)</summary>

1. **Intune > Devices > Configuration > Create > New policy > Windows 10 and later > Settings catalog.**
2. Category **Experience**. Add **Enable delivery of organizational messages (User)** = *Allow*, **Allow Windows Spotlight (User)** = *Allow*, **Allow Windows Spotlight on Action Center (User)** = *Allow*, **Allow Windows Tips** = *Allow*, **Configure Windows Spotlight on Lock Screen (User)** = *Windows spotlight enabled* (or *always enabled*), and **Disable Cloud Optimized Content** = *Disabled*.
3. Assign to **user groups** that should receive messages. Device groups work only for the device-scope settings.
4. Force a sync and verify with Triage 3:
   ```powershell
   Get-ScheduledTask -TaskName 'PushLaunch' | Start-ScheduledTask
   ```
**Rollback:** unassign or delete the profile. `EnableOrganizationalMessages` goes back to its default (0).
</details>

<details><summary id="fix-2">Fix 2 — Remove a Spotlight/cloud-content block</summary>

- **Intune Device restrictions:** edit the profile. Under **Windows Spotlight**, change *Windows Spotlight*, *Spotlight on lock screen*, *Windows Tips*, *Spotlight in action center*, and *Spotlight personalization* from **Block** to **Not configured**.
- **Settings catalog:** another profile setting `Allow Windows Spotlight = Block` or `Disable Cloud Optimized Content = Enabled` will conflict. Check the per-setting status on the device's **Configuration** tab for *Conflict*.
- **GPO:** unlink or edit the **Windows Components > Cloud Content** settings (*Turn off all Windows spotlight features*, *Do not show Windows tips*, *Turn off cloud optimized content*) for the affected OU. Then:
  ```powershell
  gpupdate /target:user /force; gpupdate /target:computer /force
  ```
**Rollback:** re-link or re-enable the original settings. Record the previous values before you change them. Some security baselines deliberately block consumer content, so get security sign-off first.
</details>

<details><summary id="fix-3">Fix 3 — Network allow-list</summary>

Allow HTTPS (443) to `fd.api.orgmsg.microsoft.com` and `ris.prod.api.personalization.ideas.microsoft.com` through the proxy/firewall, and exclude both from TLS inspection where possible. Re-run Triage 5 in the user context.
</details>

<details><summary id="fix-4">Fix 4 — "It's Active but nobody sees it" (timing)</summary>

- Non-urgent: "a few hours" before devices are eligible, then pull cadence. Allow **24 h or more**. A tenant with no message in the past 30 days can take **24–48 h** to initialise. A newly onboarded Entra tenant can take **36–64 h**.
- Spotlight: a user who **selects** the message won't see it again for **12 months**. For testing, use a fresh user.
- Urgent messages go to Taskbar/Notifications only and target Entra groups only. They're best-effort. Offline devices cache the message for 24 h.
</details>

<details><summary id="fix-5">Fix 5 — Taskbar channel missing</summary>

Install the cumulative update that contains **KB5094126** (or later) on Windows 11 24H2/25H2. Check with:
```powershell
Get-HotFix | Where-Object HotFixID -eq 'KB5094126'
(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR   # compare with the KB's documented build
```
A later cumulative update replaces the KB, so `Get-HotFix` can come back empty on a fully patched device. Compare the build/UBR against the KB article.
</details>

<details><summary id="fix-6">Fix 6 — Admin access / licensing / edition</summary>

```powershell
# Who holds the roles (Graph)
Connect-MgGraph -Scopes RoleManagement.Read.Directory
'Organizational Messages Writer','Organizational Messages Approver' | ForEach-Object {
  $r = Get-MgDirectoryRole -Filter "displayName eq '$_'"
  if ($r) { Get-MgDirectoryRoleMember -DirectoryRoleId $r.Id | Select-Object @{n='Role';e={$r.DisplayName}}, Id, @{n='UPN';e={$_.AdditionalProperties.userPrincipalName}} }
  else { "$_ : role not activated in tenant (no members yet)" }
}
```
- Assign the roles through **M365 admin center > Users > Active users > Manage roles > Other**, or through PIM. An approver **can't approve their own message**.
- Custom Windows messages need Windows or Microsoft 365 **E3/E5**. Custom Teams messages need Office 365 or Microsoft 365 **E3/E5**. Pre-made messages may work without them.
- **Windows Pro devices aren't supported** by these Experience CSPs. Upgrade the edition (Windows Enterprise E3 subscription activation) or use Teams/email.
</details>

<details><summary id="fix-7">Fix 7 — Locale mismatch (custom messages)</summary>

A custom message is created only in the author's **admin-center display language** (My Account > Settings & Privacy > Language). It reaches only users whose **Windows display language** maps to that locale. Fallback works within a language (fr-CA → fr-FR). Unsupported locales (for example lv-LV) get nothing. Fix: author one copy per language, with the author switching display language each time, or use pre-made templates, which are created in all 15 supported locales.
</details>

---
## Escalation Evidence

```
ORGANIZATIONAL MESSAGES — ESCALATION
=====================================
Ticket #: <>
Tenant ID: <>             Cloud: <Commercial>  (GCC/GCC-H unsupported)
Message name / ID: <>     Channel: <Spotlight / Taskbar / Notification Center / Teams / Email>
Pre-made or custom: <>    Urgent: <yes/no>
Message state + since (UTC): <Active / Failed / Pending ...>
Author role / Approver role confirmed: <yes/no>
Target: <Entra group / advanced: dept/location/company/usage>
Device: OS build+UBR <>   Edition <>   Join <Entra/Hybrid>
EnableOrganizationalMessages value (user scope): <>
AllowWindowsSpotlight / DisableCloudOptimizedContent: <> / <>
Blocking GPO / Device restrictions found: <>
Endpoint reachability (fd.api.orgmsg / ris.prod.api...): <True/False>
User Windows display language: <>   Author admin-center language: <>
Feedback Hub Device ID / User ID: <>
MDM diagnostics zip attached (C:\Users\Public\Documents\MDMDiagnostics): <yes/no>
Get-OrgMessagesDeviceReadiness.ps1 CSV attached: <yes/no>
```

---
## 🎓 Learning Pointers
- **`EnableOrganizationalMessages` is MDM-only, user-scoped, and off by default.** GPO can block delivery (CloudContent) but can't enable it. On a GPO-only estate, org messages won't work until Intune or another MDM delivers this CSP. [Experience CSP: EnableOrganizationalMessages](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-experience#enableorganizationalmessages).
- **`AllowWindowsSpotlight` is the parent switch.** The Tips, Action Center, and lock-screen CSPs declare a `DependsOn` on it. A security baseline that turns off "all Windows spotlight features" breaks every Windows channel, however the child policies are set.
- **These policies used to only affect Microsoft consumer content.** Now the same service delivers admin messages, which is why hardening from years ago silently blocks them. [FAQ: Why do I need to update my MDM policies?](https://learn.microsoft.com/en-us/microsoft-365/admin/misc/organizational-messages-microsoft-365-faq?view=o365-worldwide#why-do-i-need-to-update-my-mobile-device-management-mdm-policies).
- **To send your org's messages without Microsoft's**, turn off *Allow Microsoft messages to display* in the Organizational messages **Settings** gear. That's the supported way to allow Spotlight for org messages without re-enabling consumer promotions.
- **Doc discrepancy to be aware of:** the CSP page lists `EnableOrganizationalMessages` as applicable from Windows 10 22H2 and Windows 11 22H2 (with specific KBs). The product page requires **Windows 11 24H2/25H2 Enterprise** for Windows channels. Support the product page's baseline.
- Deep dive: [OrganizationalMessages-A.md](OrganizationalMessages-A.md). Device check: `Scripts/Get-OrgMessagesDeviceReadiness.ps1`.
