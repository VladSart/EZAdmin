# Organizational Messages (Microsoft 365 admin center) — Reference Runbook (Mode A: Deep Dive)
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

- **In scope:** the centralised Organizational messages experience in the **Microsoft 365 admin center** (Reports > Organizational messages). That covers authoring, approval, targeting, reporting, and the **Windows device-side prerequisites** that decide whether Windows 11 Spotlight, Taskbar, and Notification Center messages ever render. Teams and email channels are covered at the service level.
- **Out of scope:** Adoption Score Office/Outlook-channel messages. The FAQ says they aren't visible in the centralised experience. Also out of scope: Microsoft 365 Message Center (the admin-facing *service* notices, a different product with a confusingly similar name) and Windows "Enterprise spotlight" content services.
- **History:** Intune used to host the authoring UI (Tenant administration > Organizational messages). Microsoft removed it "no earlier than August 2024" and moved existing messages to the M365 admin center. Intune RBAC permissions for org messages and **scope tags don't carry over**. Access is now controlled by Entra roles. New **Get Started** messages can't be created any more, though existing ones keep running until cancelled. Source: [Intune Customer Success support tip](https://techcommunity.microsoft.com/blog/intunecustomersuccess/support-tip-organizational-messages-is-moving-to-microsoft-365-admin-center/4148332).
- **Sources fetched live 2026-09-25:** [product page](https://learn.microsoft.com/en-us/microsoft-365/admin/misc/organizational-messages-microsoft-365?view=o365-worldwide) (`ms.date` 2026-07-22), [FAQ](https://learn.microsoft.com/en-us/microsoft-365/admin/misc/organizational-messages-microsoft-365-faq?view=o365-worldwide), and [Policy CSP – Experience](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-experience).
- **No admin API.** Microsoft hasn't documented a Graph or PowerShell surface for creating, reading, or reporting on organizational messages. Scriptable checks here are limited to Entra roles (Graph) and device state (local PowerShell). Reporting is **Review activity > Export to CSV**.

---
## How It Works

<details><summary>Full architecture</summary>

### Control plane (tenant)

```
Author (Organizational Messages Writer)
   │ Create a message wizard: Objective → Location → Template → Customize → Recipients → Schedule → Finish
   ▼
┌─────────────────────────── Message ───────────────────────────┐
│ Pre-made (Microsoft template + logo/URL)  → no approval         │
│ Custom ("Create your own", E3/E5 only)    → Approver required   │
│   (approver ≠ author; not approved by End date = auto-rejected) │
└─────────────────────────────────────────────────────────────────┘
   ▼  states: Draft → Pending approval → Scheduled → Active → Completed
   │          Rejected (withdraw → Draft)   Failed (copy to retry)   Canceled
   ▼
Organizational messages service  ──► channel back-ends
   ├─ Windows (pull): Spotlight lock screen, Taskbar, Notification Center
   ├─ Teams notifications/popovers (Entra group targeting only)
   └─ Email (8 non-customisable Copilot templates; open tracking being removed)
```

**Targeting:**
- **Entra groups:** all channels.
- **Advanced targeting (Companies / Departments / Locations):** Windows channels only. Needs E3/E5 **and** Adoption Score **group-level insights** with *Organizational attributes* filters turned on. It works from Entra user attributes (department, officeLocation, companyName) aggregated by Adoption Score, so bad directory data means bad targeting.
- **Usage:** two predefined segments. *Inactive Copilot users* (licensed, no Copilot use in the prior **28 days**) and *Inactive Copilot users in Teams* (prior **30 days**). Available on Windows channels and Teams. Doesn't need group-level insights.

**Tenant setting:** the Settings gear has **Allow Microsoft messages to display**. Turn it off to let Spotlight/Tips surfaces show your messages only, without Microsoft's consumer content.

### Data plane (Windows device)

Windows **pulls** message payloads from the service on a per-channel buffered cadence. Nothing is pushed. That's why the FAQ gives "a few hours" before a message is eligible and "24 or more hours" before it renders. Urgent messages are best-effort, go to Taskbar/Notifications only, and are cached up to 24 h if the device is offline.

The device only renders a message if every surface gate is open. These are **Experience** Policy CSPs:

| CSP | Scope | Default | Needed | GPO equivalent (can block) |
|---|---|---|---|---|
| `EnableOrganizationalMessages` | **User** | **0** | 1 | **None.** MDM only |
| `AllowWindowsSpotlight` | User | 1 | 1 | `DisableWindowsSpotlightFeatures` (HKCU\…\CloudContent) |
| `AllowWindowsSpotlightOnActionCenter` | User | 1 | 1 (DependsOn AllowWindowsSpotlight=1) | `DisableWindowsSpotlightOnActionCenter` |
| `ConfigureWindowsSpotlightOnLockScreen` | User | 1 | 1 or 2 (DependsOn AllowWindowsSpotlight=1) | `ConfigureWindowsSpotlight` |
| `AllowWindowsTips` | **Device** | 1 | 1 (DependsOn AllowWindowsSpotlight=1) | `DisableSoftLanding` (HKLM\…\CloudContent) |
| `DisableCloudOptimizedContent` | **Device** | 0 | 0 | `DisableCloudOptimizedContent` (HKLM) |

All of these are **Enterprise / Education / IoT Enterprise only**. The CSP tables mark **Pro as unsupported**. That's the architectural reason Business Premium tenants on Windows Pro devices can't use Windows channels without an Enterprise upgrade (subscription activation).

**Why "security hardening from years ago" breaks it:** these CSPs were designed to throttle Microsoft's *consumer* content. Org messages reuse the same client and delivery service, so baselines, CIS benchmarks, and "turn off all Spotlight features" GPOs switch the admin channel off too. The FAQ says so directly.

**Where MDM values land on the device:** `HKLM:\SOFTWARE\Microsoft\PolicyManager\current\<scope>\Experience`. `<scope>` is `device` for device-scoped CSPs, and a per-user or per-enrollment key for user-scoped ones. Enumerate the subkeys rather than hard-coding a SID.

### Platform requirements (and a doc discrepancy)

- Product page: Windows channels need **Windows 11 24H2 or 25H2 Enterprise**, **Entra joined or hybrid joined**. **Taskbar** also needs **KB5094126**.
- CSP page: `EnableOrganizationalMessages` applies from Windows 10 22H2 (KB5041582, build 19045.4842) and Windows 11 22H2 (KB5020044, 22621.900).
- **Use the product page's stricter baseline** for support statements. The CSP can apply on older builds without the channel experiences existing there.

### Localisation
15 supported locales. Pre-made messages are created in all of them. **Custom messages are created only in the author's M365 admin-center display language**, and they reach only users whose Windows display language maps to it (fr-CA → fr-FR works; lv-LV gets nothing).

### Cloud availability
Commercial only. **GCC and GCC-High aren't supported.**
</details>

---
## Dependency Stack

```
[8] User sees message        — per-user frequency; Spotlight click = 12-month suppression
[7] Locale match             — Windows display language ↔ message locale
[6] Channel renderer         — Spotlight / Taskbar (KB5094126) / Notification Center
[5] Pull + network           — fd.api.orgmsg.microsoft.com, ris.prod.api.personalization.ideas.microsoft.com
[4] Device policy gates      — EnableOrganizationalMessages=1 (user, MDM-only) + Spotlight family + CloudOptimizedContent
[3] Device eligibility       — Win11 24H2/25H2, Enterprise/Education, Entra/hybrid joined
[2] Message lifecycle        — Draft → (Approval) → Scheduled → Active;   Failed → copy
[1] Targeting                — Entra groups | Adoption Score group-level aggregates | Usage segments
[0] Tenant                   — commercial cloud, Writer/Approver Entra roles, E3/E5 for custom/advanced
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Admin can't see the Organizational messages page | No Writer role | Entra role membership |
| "Create your own" greyed out | Tenant lacks M365/O365/Windows E3/E5 | Licensing |
| Companies/Departments/Locations missing in Recipients | Group-level insights / Organizational attributes not on | Org settings > Adoption Score |
| Custom message auto-rejected | No approver acted before End date | Message history |
| State **Failed** | Service registration failed | Copy the message and resubmit |
| Active, zero "Messages seen" after 48 h, all devices | `EnableOrganizationalMessages` not deployed, or a Spotlight master switch blocked by baseline/GPO | Device registry (Validation 3–4) |
| Works on some devices, not others | Pro edition, pre-24H2 build, workgroup/AD-only join | Edition/build/dsregcmd |
| Works for some users on a shared device | User-scoped policy assigned to the device group, or locale mismatch | PolicyManager user-scope keys; language |
| Spotlight + Notifications fine, Taskbar never | KB5094126 missing | Build/UBR |
| Message seen once, never again for a user | They clicked it (12-month suppression on Spotlight) | Expected |
| Old Intune scope-tag delegation stopped working | Scope tags don't apply after the move | Use the Entra Writer/Approver roles |
| Can't create Get Started messages | No longer supported. Existing ones still run | Expected |
| GCC tenant: feature missing | Not supported in government clouds | Expected |

---
## Validation Steps

1. **Roles** (Graph):
   ```powershell
   Connect-MgGraph -Scopes RoleManagement.Read.Directory
   Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq 'Organizational Messages Writer' or displayName eq 'Organizational Messages Approver'" | Select-Object Id, DisplayName
   Get-MgRoleManagementDirectoryRoleAssignment -Filter "roleDefinitionId eq '<roleDefinitionId>'" -All | Select-Object PrincipalId, DirectoryScopeId
   ```
   Good: at least one principal for each role, and the approver isn't the only writer. Bad: no approver means custom messages can't progress.

2. **Device eligibility:**
   ```powershell
   Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' | Select-Object EditionID, CurrentBuild, UBR, DisplayVersion
   ```
   Good: `Enterprise`/`Education`, build `26100`/`26200`. Bad: `Professional`, or a build below 26100.

3. **MDM gate values:**
   ```powershell
   Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current' | ForEach-Object {
     $k = Join-Path $_.PSPath 'Experience'; if (Test-Path $k) { [pscustomobject]@{ Scope = $_.PSChildName; Values = (Get-ItemProperty $k | Select-Object EnableOrganizationalMessages, AllowWindowsSpotlight, AllowWindowsTips, DisableCloudOptimizedContent) } } }
   ```
   Good: a scope key with `EnableOrganizationalMessages = 1`, and no scope with `AllowWindowsSpotlight = 0` or `DisableCloudOptimizedContent = 1`.

4. **GPO blockers:**
   ```powershell
   gpresult /scope user /v | Select-String -Pattern 'CloudContent|Spotlight' -Context 0,2
   ```
   Good: no CloudContent policies applied. Bad: *Turn off all Windows spotlight features* = Enabled.

5. **Network:** `Test-NetConnection fd.api.orgmsg.microsoft.com -Port 443` gives `TcpTestSucceeded : True` (also test `ris.prod.api.personalization.ideas.microsoft.com`).

6. **Locale:** `(Get-WinUserLanguageList)[0].LanguageTag` matches the message locale.

7. **All at once:** `Scripts\Get-OrgMessagesDeviceReadiness.ps1` (run in the user's session) exports a pass/fail CSV.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Authoring/approval.** Roles, licensing (custom/advanced), Adoption Score group-level insights (advanced targeting), and approval before End date. A Failed state always means copy and recreate.

**Phase 2 — Targeting.** Check group membership (nested groups: confirm by test rather than assuming). For advanced targeting, the Entra `department`/`officeLocation`/`companyName` attributes have to be populated. For Usage segments, the user must hold a Copilot licence and have been inactive for 28/30 days.

**Phase 3 — Device gates.** Edition, build, join state, MDM CSP values, GPO/baseline conflicts. This is where most "nobody sees it" tickets end up.

**Phase 4 — Delivery.** Network endpoints, time since Active (24 h+, or 24–48 h tenant initialisation after 30 idle days), KB5094126 for Taskbar.

**Phase 5 — Rendering.** Locale, Spotlight 12-month suppression after a click, frequency settings (a dismissed message comes back at the configured frequency).

---
## Remediation Playbooks

<details><summary>Playbook 1 — Standard MSP enablement profile (Intune Settings catalog)</summary>

Create **one** Settings catalog profile, "Org Messages – Enable", with the six Experience settings (see the B runbook Fix 1). Assign it to **All users**, or to a pilot user group first. Then:
1. Audit existing **Device restrictions** and **Security baseline** profiles for Spotlight blocks. Remove or exclude those settings. A security-baseline change needs a documented risk acceptance.
2. Leave **Allow Microsoft messages to display** **off** in Organizational messages settings. You re-enable Spotlight surfaces for org content without letting consumer promotions back in.
3. Pilot a **pre-made** message (no approval, all locales) to a test group before any custom campaign.
**Rollback:** unassign the profile. The CSPs go back to their defaults, and EnableOrganizationalMessages goes back to 0, which switches off delivery.
</details>

<details><summary>Playbook 2 — Hybrid estate with GPO hardening</summary>

1. Find the GPOs that set CloudContent values: `Get-GPOReport -All -ReportType Xml -Path "$env:TEMP\gpo.xml"`, then search for `CloudContent`. `Select-String` over individual `Get-GPOReport -Guid` outputs is faster in big domains.
2. Create an exception OU or security-filtered GPO, or set the offending settings to **Not configured** for the pilot population.
3. Deliver `EnableOrganizationalMessages` via Intune. GPO can't deliver it. For co-managed devices, make sure the **Device configuration** workload is on Intune (or pilot Intune) so the settings catalog profile applies.
4. Watch MDM/GPO precedence. Unless *ControlPolicyConflict/MDMWinsOverGP* is set, a GPO block usually wins for the ADMX-backed settings. Remove the GPO rather than trying to override it.
</details>

<details><summary>Playbook 3 — Pro-edition fleet (Business Premium)</summary>

Windows channels need Enterprise/Education. Options: (a) Windows Enterprise E3/E5 **subscription activation** (Pro → Enterprise step-up, no reinstall), or (b) use **Teams** and **email** channels only. Document the gap for the customer. Don't promise lock-screen messaging on Pro.
</details>

<details><summary>Playbook 4 — Multi-language workforce</summary>

For custom messages, the author switches the M365 admin-center display language (My Account > Settings & Privacy > Language) and creates one copy per locale, using **Copy** to keep images when the Location is unchanged. Target language-specific groups if you want to avoid fallback surprises. Pre-made templates are already localised into all 15 supported locales.
</details>

---
## Evidence Pack

```powershell
<# Org Messages device evidence — run in the affected user's session (elevation not required). #>
$out = "$env:TEMP\OrgMsgEvidence-$env:COMPUTERNAME-$(Get-Date -f yyyyMMdd-HHmmss)"
New-Item -ItemType Directory -Path $out -Force | Out-Null
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' | Select-Object ProductName,EditionID,DisplayVersion,CurrentBuild,UBR | Export-Csv "$out\os.csv" -NoTypeInformation
dsregcmd /status | Out-File "$out\dsregcmd.txt"
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current' -ErrorAction SilentlyContinue | ForEach-Object {
  $k = Join-Path $_.PSPath 'Experience'
  if (Test-Path $k) { Get-ItemProperty $k | Select-Object @{n='Scope';e={$_.PSParentPath.Split('\')[-1]}}, * -ExcludeProperty PS* }
} | Export-Csv "$out\mdm-experience.csv" -NoTypeInformation
foreach ($h in 'HKCU','HKLM') { $p = "${h}:\Software\Policies\Microsoft\Windows\CloudContent"; if (Test-Path $p) { Get-ItemProperty $p | Out-File "$out\gpo-cloudcontent-$h.txt" } }
gpresult /scope user /v > "$out\gpresult-user.txt"
'fd.api.orgmsg.microsoft.com','ris.prod.api.personalization.ideas.microsoft.com' | ForEach-Object {
  [pscustomobject]@{ Host = $_; Tcp443 = (Test-NetConnection $_ -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded } } | Export-Csv "$out\network.csv" -NoTypeInformation
(Get-WinUserLanguageList) | Select-Object LanguageTag | Export-Csv "$out\languages.csv" -NoTypeInformation
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 10 HotFixID, InstalledOn | Export-Csv "$out\hotfix.csv" -NoTypeInformation
Compress-Archive "$out\*" "$out.zip" -Force
Write-Host "Evidence: $out.zip  — also attach MDMDiagnostics export (Settings > Accounts > Access work or school > Export) and Feedback Hub Device/User ID."
```

---
## Command Cheat Sheet

| Purpose | Command |
|---|---|
| OS edition/build | `Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' \| Select EditionID,CurrentBuild,UBR` |
| Join state | `dsregcmd /status \| Select-String 'AzureAdJoined\|DomainJoined'` |
| MDM Experience values | `Get-ChildItem HKLM:\SOFTWARE\Microsoft\PolicyManager\current` → `\<scope>\Experience` |
| GPO CloudContent (user) | `Get-ItemProperty HKCU:\Software\Policies\Microsoft\Windows\CloudContent` |
| GPO CloudContent (machine) | `Get-ItemProperty HKLM:\Software\Policies\Microsoft\Windows\CloudContent` |
| RSoP user | `gpresult /scope user /v` |
| Force MDM sync | `Get-ScheduledTask -TaskName 'PushLaunch' \| Start-ScheduledTask` |
| Endpoint test | `Test-NetConnection fd.api.orgmsg.microsoft.com -Port 443` |
| User language | `(Get-WinUserLanguageList)[0].LanguageTag` |
| Taskbar KB | `Get-HotFix -Id KB5094126` |
| MDM diag export | `MdmDiagnosticsTool.exe -out C:\Users\Public\Documents\MDMDiagnostics` |
| Writer/Approver roles | `Get-MgRoleManagementDirectoryRoleDefinition -Filter "startswith(displayName,'Organizational Messages')"` |
| Full device check | `.\Get-OrgMessagesDeviceReadiness.ps1` |

---
## 🎓 Learning Pointers
- **Know where each control lives:** authoring and approval are in the **M365 admin center** (Entra roles), delivery permission is in **Intune** (Experience CSPs), targeting data comes from **Adoption Score** (group-level aggregates). A ticket nearly always belongs to exactly one of the three. [Product page](https://learn.microsoft.com/en-us/microsoft-365/admin/misc/organizational-messages-microsoft-365?view=o365-worldwide).
- **Read the CSP dependency metadata.** The `DependsOn: AllowWindowsSpotlight = 1` entries on the child CSPs explain why one baseline setting takes out three channels. [Policy CSP – Experience](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-experience).
- **The Pro edition gap matters for SMB/MSP tenants.** Every relevant CSP is Enterprise/Education only. Check the edition before you scope a lock-screen campaign.
- **Intune → M365 admin center move:** scope-tag delegation and Intune RBAC don't carry over, and Get Started messages can't be created any more. [Support tip](https://techcommunity.microsoft.com/blog/intunecustomersuccess/support-tip-organizational-messages-is-moving-to-microsoft-365-admin-center/4148332).
- **Custom-message localisation is tied to the author's display language.** Multilingual orgs must author one copy per locale. [FAQ – localization](https://learn.microsoft.com/en-us/microsoft-365/admin/misc/organizational-messages-microsoft-365-faq?view=o365-worldwide#how-does-localization-work-in-organizational-messages).
- Related repo content: `M365/Copilot/` (the Usage segments target inactive Copilot users) and `Intune/Troubleshooting/` security baseline runbooks (a common source of Spotlight blocks).
