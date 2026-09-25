# Quick Assist (Remove / Block / Investigate) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

> **Use when:** (a) a client wants Quick Assist gone or blocked because they standardise on Intune Remote Help or a third-party RMM, (b) Quick Assist "won't connect" for a legitimate helpdesk, or (c) you suspect a user was socially engineered into a Quick Assist session (the "fake IT helpdesk" pattern used by Storm-1811 before Black Basta ransomware). Deep dive: `QuickAssist-A.md`. Remote Help side: `Intune/Troubleshooting/RemoteHelp-B.md`.

**Three facts that settle most tickets:**
1. **Quick Assist has no admin policy.** No CSP, no ADMX, no tenant switch. You control it by **removing the app**, **blocking the app** (AppLocker/WDAC packaged-app rule), or **blocking its network endpoint**.
2. **Blocking `remoteassistance.support.services.microsoft.com` also breaks Intune Remote Help.** Never use the network block in a tenant that uses Remote Help.
3. **The sharer doesn't authenticate.** Anyone who gets a user to type in a 6-character code can view the screen and, if the user clicks **Allow**, control it. That's why removing it matters.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage
```powershell
# 1. Is the Store version of Quick Assist installed (any user)?  (elevated)
Get-AppxPackage -AllUsers -Name MicrosoftCorporationII.QuickAssist | Select-Object Name, Version, PackageFamilyName

# 2. Is it provisioned for new user profiles?
Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq 'MicrosoftCorporationII.QuickAssist'

# 3. Legacy inbox (Windows capability) version still present? (older Windows 10 builds)
Get-WindowsCapability -Online -Name 'App.Support.QuickAssist*' | Select-Object Name, State

# 4. Running right now? (live session in progress)
Get-Process -Name QuickAssist -ErrorAction SilentlyContinue | Select-Object Id, StartTime, Path

# 5. Can the device reach the session broker? (also used by Remote Help)
Test-NetConnection remoteassistance.support.services.microsoft.com -Port 443 | Select-Object TcpTestSucceeded
```

| Result | Meaning | Do |
|---|---|---|
| #1 returns a package, client wants QA gone | Store app present | Fix 1 (remove) + Fix 2 (block reinstall) |
| #1 empty but #2 returns a package | New profiles will get it | Fix 1 step 2 (deprovision) |
| #3 `State = Installed` | Old inbox build | Fix 1 step 3 (remove capability) |
| #4 returns a process and the user didn't call IT | **Possible live social-engineering session** | Fix 5 **now** (contain), then investigate |
| #5 `False` and QA/Remote Help "won't connect" | Firewall/proxy/DNS block | Fix 4 (allow endpoints) |
| #5 `False` and client *uses* Remote Help | Someone applied the endpoint block | Remove the block — use Fix 2 instead |

---
## Dependency Cascade
<details><summary>What must be true for a Quick Assist session to work</summary>

```
Quick Assist session established
├── App present on BOTH devices
│   ├── Store app  MicrosoftCorporationII.QuickAssist  (current)
│   │   └── Edge WebView2 runtime  (inbox on Win11; auto-installed on Win10 at first launch)
│   └── NOT blocked by AppLocker / WDAC packaged-app rule
├── Helper signed in  (Microsoft account OR Entra ID — on-prem AD auth NOT supported)
├── Sharer: no sign-in required  ← the social-engineering risk
├── Network (both sides, TCP 443 outbound)
│   ├── *.support.services.microsoft.com  (remoteassistance… = session broker; shared with Remote Help)
│   ├── Azure Communication Services: *.trouter/*.registrar/*.flightproxy/*.cc.skype.com, edge.skype.com,
│   │   remoteassistanceprodacs.communication.azure.com, turn.azure.com
│   ├── Sign-in: login.microsoftonline.com, aadcdn.msauth.net, *.live.com
│   └── Telemetry: *.aria.microsoft.com, *.events.data.microsoft.com, *.monitor.azure.com
├── Security code (time-limited) passed helper → sharer
├── Sharer clicks Allow (screen share)  →  optional Request control → sharer clicks Allow
└── UAC prompts on sharer's desktop still need the SHARER to answer (helper = sharer's rights)
```
</details>

---
## Diagnosis & Validation Flow
1. **Which Quick Assist is it?**
   `Get-AppxPackage -AllUsers -Name MicrosoftCorporationII.QuickAssist`
   - Package returned → Store app (the only current version).
   - Nothing, but `Get-WindowsCapability -Online -Name App.Support.QuickAssist*` = `Installed` → legacy inbox app (old Windows 10 builds). Remove both variants when retiring QA.
2. **Is anything already blocking it?**
   `(Get-AppLockerPolicy -Effective -Xml) -match 'QuickAssist'`
   - `True` → an AppLocker packaged-app rule mentions it (check it's a Deny, and that AppIDSvc is running: `Get-Service AppIDSvc`).
   - `False` → no AppLocker rule. WDAC: check `CiTool --list-policies` (Win11 22H2+) for a custom deny policy.
3. **Network path** — run Triage #5. Also resolve DNS: `Resolve-DnsName remoteassistance.support.services.microsoft.com`.
   - Resolves to `0.0.0.0`/`127.0.0.1` → hosts-file or DNS-filter sinkhole (check `Get-Content $env:windir\System32\drivers\etc\hosts`).
   - Timeout → firewall/proxy. TLS-inspecting proxies can also break the ACS media relay (connects, then drops at "Connecting…").
4. **Was there a session?** Quick Assist writes **no local session log** by design. Evidence lives in:
   - Defender for Endpoint Advanced Hunting (process + network):
     ```kusto
     DeviceProcessEvents
     | where Timestamp > ago(7d)
     | where FileName =~ "QuickAssist.exe"
     | project Timestamp, DeviceName, AccountName, ProcessCommandLine, InitiatingProcessFileName
     ```
   - Prefetch (`C:\Windows\Prefetch\QUICKASSIST.EXE-*.pf`) timestamp = last run time.
   - Firewall/proxy logs showing `remoteassistance.support.services.microsoft.com`.
5. **Validate after a fix** — rerun Triage #1–#3 (all empty / NotPresent) and, if blocked via AppLocker, launch it as a standard user: expect "This app has been blocked by your system administrator".

---
## Common Fix Paths

<details><summary>Fix 1 — Remove Quick Assist (Store app + provisioned + legacy)</summary>

```powershell
# Elevated. 1) Remove for all existing users
Get-AppxPackage -AllUsers -Name MicrosoftCorporationII.QuickAssist | Remove-AppxPackage -AllUsers

# 2) Stop it being provisioned into new profiles
Get-AppxProvisionedPackage -Online |
  Where-Object DisplayName -eq 'MicrosoftCorporationII.QuickAssist' |
  Remove-AppxProvisionedPackage -Online

# 3) Legacy inbox version (older Windows 10 only)
Get-WindowsCapability -Online -Name 'App.Support.QuickAssist*' |
  Where-Object State -eq 'Installed' | Remove-WindowsCapability -Online
```
**Intune at scale:** deploy as a **Remediation** (detection = Triage #1–#3 non-empty → exit 1; remediation = the block above), run as SYSTEM, 64-bit, daily. A remediation catches reinstalls; a one-shot platform script doesn't.
**Rollback:** reinstall from the Store (`winget install 9P7BP5VNWKX5 --source msstore`) or deploy it as a Microsoft Store app (new) in Intune.
**Caveat:** removal alone doesn't stop a user reinstalling it from the Store — pair with Fix 2.
</details>

<details><summary>Fix 2 — Block execution with an AppLocker packaged-app rule (Remote Help-safe)</summary>

Blocks Quick Assist without touching the network endpoint Remote Help needs.

1. Build the rule on a reference device that still has QA installed:
   ```powershell
   Get-AppxPackage -Name MicrosoftCorporationII.QuickAssist |
     Get-AppLockerFileInformation | New-AppLockerPolicy -RuleType Publisher -User Everyone -Xml |
     Out-File .\QA-Allow.xml   # generates an ALLOW rule — edit Action="Allow" to Action="Deny" before use
   ```
   Or in the GPO editor: *Packaged app Rules* → **Create Default Rules** (so other Store apps still run) → **Create New Rule** → **Deny** → Everyone → *Use an installed packaged app as a reference* → Quick Assist.
2. **Default rules are mandatory.** Enabling Packaged-app enforcement with only a Deny rule blocks *every* packaged app (Start menu, Settings components, Store apps). Keep the default "allow all signed packaged apps" rule and add the Deny.
3. Deploy: GPO, or Intune **AppLocker CSP** (`./Vendor/MSFT/AppLocker/ApplicationLaunchRestrictions/<Grouping>/StoreApps/Policy`).
4. AppLocker only enforces while the **Application Identity** service (`AppIDSvc`) runs — set it to Automatic via GPO (*System Services → Application Identity*) or confirm it's trigger-starting after the policy lands (`Get-Service AppIDSvc`). Intune AppLocker CSP handles this for you.
5. WDAC shops: add a deny rule by **Package Family Name** `MicrosoftCorporationII.QuickAssist_8wekyb3d8bbwe` to a supplemental/base policy instead. See `AppLocker-B.md`.

**Rollback:** remove the Deny rule (or set Packaged-app rules back to Audit only).
</details>

<details><summary>Fix 3 — Network block (ONLY if no Remote Help in the tenant)</summary>

Microsoft's documented disable method: block `https://remoteassistance.support.services.microsoft.com` at the firewall / secure web gateway / DNS filter.
- Works regardless of what's installed, including BYOD on the corporate network.
- **Breaks Intune Remote Help** — confirm first: Intune admin center → *Tenant administration* → *Remote Help* → Settings = Disabled and no `RemoteHelp.exe` deployed (`Test-Path "$env:ProgramFiles\Remote Help\RemoteHelp.exe"`).
- Doesn't protect devices off-network (use Fix 1/2 for roaming laptops).
**Rollback:** remove the block rule/URL category entry.
</details>

<details><summary>Fix 4 — Quick Assist is wanted but won't connect</summary>

```powershell
$hosts = 'remoteassistance.support.services.microsoft.com','remoteassistanceprodacs.communication.azure.com',
         'edge.skype.com','turn.azure.com','login.microsoftonline.com','aadcdn.msauth.net'
foreach ($h in $hosts) { [pscustomobject]@{ Host=$h; TCP443=(Test-NetConnection $h -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded } }
```
- Any `False` → allow the full wildcard list from Learn (see Dependency Cascade) and **exclude those FQDNs from TLS inspection**.
- Win10 "WebView2 missing" → deploy the Evergreen WebView2 Runtime.
- Helper sign-in fails with an on-prem-only account → helper needs an Entra ID or MSA identity.
- Helper cannot click UAC prompts → by design (secure desktop); the sharer must approve, or use Remote Help with elevation support.
- Store app reinstalled but old version launches → remove legacy capability (Fix 1 step 3).
</details>

<details><summary>Fix 5 — Suspected social-engineering session (contain first)</summary>

1. **Kill the session now:** `Stop-Process -Name QuickAssist -Force` (or pull network / MDE **Isolate device**).
2. Preserve evidence *before* cleanup: collect the MDE investigation package (device page → *Collect investigation package*) or run the Escalation Evidence block below.
3. Hunt what happened after the session started — the Storm-1811 pattern was: email-bomb the user → call/Teams message posing as IT → Quick Assist → download RMM/tools via `curl`/PowerShell → persistence → ransomware.
   ```kusto
   let t0 = datetime(<session start UTC>);
   DeviceProcessEvents
   | where DeviceName == "<device>" and Timestamp between (t0 .. t0 + 4h)
   | project Timestamp, FileName, ProcessCommandLine, InitiatingProcessFileName, AccountName
   | order by Timestamp asc
   ```
4. Reset the user's password + revoke sessions (`Revoke-MgUserSignInSession -UserId <upn>`), check for new MFA methods, inbox rules, and newly installed remote tools (AnyDesk, ScreenConnect, etc.).
5. Then apply Fix 1 + Fix 2 tenant-wide, and review Teams external access (`M365/Teams/ExternalAccess-A.md`) — unrestricted external chat is how the fake-helpdesk contact usually lands.
6. Escalate to the security team / client's incident process — this is an incident, not a helpdesk ticket.
</details>

---
## Escalation Evidence
```
QUICK ASSIST ESCALATION
Ticket: ____________   Tenant: ____________   Device: ____________   User: ____________
Scenario:  [ ] Remove/block request  [ ] Won't connect  [ ] Suspected malicious session
OS build (winver): ____________
Store app present (Get-AppxPackage -AllUsers): [ ] Yes ver ______  [ ] No
Provisioned: [ ] Yes [ ] No      Legacy capability: [ ] Installed [ ] NotPresent
AppLocker/WDAC rule for QuickAssist: [ ] Deny present [ ] None
Remote Help in use in tenant: [ ] Yes [ ] No     Endpoint block in place: [ ] Yes [ ] No
TCP443 remoteassistance.support.services.microsoft.com: [ ] OK [ ] Fail
Suspected session start (UTC): ____________   Helper display name shown to user: ____________
MDE isolation performed: [ ] Yes at ______ [ ] No     Investigation package collected: [ ] Yes [ ] No
Password reset / sessions revoked: [ ] Yes [ ] No
Get-QuickAssistExposureAudit.ps1 CSV attached: [ ] Yes
Notes: ______________________________________________
```

---
## 🎓 Learning Pointers
- Quick Assist isn't a managed product — it's a consumer-grade tool with **no admin policy surface**, so "disable" always means app removal, app control, or network block. Microsoft's own page recommends Remote Help for single-tenant orgs: [Use Quick Assist to help users](https://learn.microsoft.com/windows/client-management/client-tools/quick-assist).
- The endpoint block and Remote Help share `remoteassistance.support.services.microsoft.com` — the most common self-inflicted Remote Help outage in MSP tenants comes from a well-meaning "block Quick Assist" firewall rule. See `Intune/Troubleshooting/RemoteHelp-A.md`.
- AppLocker packaged-app rules are all-or-nothing once enforced; always create the default rules first. [AppLocker packaged apps](https://learn.microsoft.com/windows/security/application-security/application-control/app-control-for-business/applocker/manage-packaged-apps-with-applocker).
- The threat model is real and documented: Microsoft Threat Intelligence, *"Threat actors misusing Quick Assist in social engineering attacks leading to ransomware"* (May 2024, Storm-1811/Black Basta). Pair app removal with Teams external-access hardening and user awareness.
- No local session log exists — MDE `DeviceProcessEvents`/`DeviceNetworkEvents` and proxy logs are your only reliable timeline. Make sure MDE is onboarded *before* you need it.
