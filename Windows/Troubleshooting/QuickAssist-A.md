# Quick Assist — Reference Runbook (Mode A: Deep Dive)
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
**In scope:** the Windows Quick Assist app (Store package `MicrosoftCorporationII.QuickAssist`, plus the legacy inbox capability `App.Support.QuickAssist` on older Windows 10 builds) on Windows 10/11 — how a session is brokered, what an MSP can and can't control, how to retire it safely, and how to investigate a suspected malicious session.

**Out of scope:** Intune Remote Help (the managed, tenant-scoped successor — `Intune/Troubleshooting/RemoteHelp-A.md`, `RemoteHelp-Unattended-A.md`), the legacy `msra.exe` Windows Remote Assistance (a separate DCOM/RDP-based tool), and Quick Assist for macOS (Microsoft states it's only available during Microsoft Support interactions — not something an MSP can deploy).

**Assumptions:** you're an L2/L3 engineer with local admin on the endpoint and (ideally) Defender for Endpoint Advanced Hunting access for investigations.

**Source of truth:** [Use Quick Assist to help users](https://learn.microsoft.com/windows/client-management/client-tools/quick-assist) (Learn, last updated 2025-09-30 at time of writing, 2026-09-25).

---
## How It Works
<details><summary>Full architecture</summary>

### The session model
Quick Assist is a **brokered, code-paired, outbound-only** remote-screen tool. Neither device listens for inbound connections; both call out over TCP 443.

```
 HELPER (signed in: MSA or Entra ID)                    SHARER (no sign-in)
 ┌──────────────────────┐                                ┌──────────────────────┐
 │ Quick Assist         │ 1. "Help someone"               │ Quick Assist         │
 │  (WebView2 UI)       │───────────┐                     │  (WebView2 UI)       │
 └──────────┬───────────┘           ▼                     └──────────┬───────────┘
            │          ┌──────────────────────────────┐              │
            │          │ Remote Assistance Service     │ 3. sharer    │
            │ 2. code  │ remoteassistance.support.     │◄─ enters code┤
            │◄─────────│ services.microsoft.com        │              │
            │          └──────────────┬───────────────┘              │
            │                         │ joins both to an RCC chat     │
            │          ┌──────────────▼───────────────┐   session via │
            └─────────►│ Azure Communication Services  │◄──────────────┘
                       │ (trouter/registrar/turn/...) │
                       └──────────────┬───────────────┘
                                      │ 4. sharer clicks Allow
                       ┌──────────────▼───────────────┐
                       │ RDP Relay service (443/TLS1.2)│  video: sharer → helper
                       │                               │  input: helper → sharer
                       └───────────────────────────────┘
```

1. Helper selects **Help someone** → QA contacts the Remote Assistance Service, obtains a **time-limited security code**, and joins an RCC (chat) session over Azure Communication Services.
2. Helper reads the code to the sharer (phone, Teams, etc.).
3. Sharer enters the code → joins the same session.
4. Sharer is prompted to **Allow** screen sharing.
5. QA starts the RDP control and connects to the **RDP Relay** service; video flows sharer → helper, input flows helper → sharer, all over 443.
6. Helper can **Request control**; sharer must Allow again. Otherwise view/annotate only.

### Identity asymmetry — the design choice that drives the risk
- **Helper** must authenticate (Microsoft account or Entra ID; on-prem AD auth isn't supported).
- **Sharer** does not authenticate at all and sees only the helper's abbreviated name (first name, last initial).
- There are **no roles, permissions or policies** in the product. Any Microsoft account holder anywhere can be a helper for any Windows user who will type in a code.

This is precisely why Remote Help exists: it adds tenant isolation, Intune RBAC, Conditional Access, session auditing and MDE integration — none of which Quick Assist can offer.

### Privilege model
The helper gets **the sharer's rights**. UAC prompts render on the secure desktop, which the helper can't interact with, so a standard user sharing their screen can't be elevated by the helper, and an admin user must still click the UAC prompt themselves. (Social engineers work around this by *telling* the user to click Yes.)

### Logging and data
Microsoft keeps only health telemetry (start/end time, app errors, features used) for ≤ 3 days. **No logs are created on either device.** Microsoft can't view session content. For an MSP this means: if you need a timeline, it must come from EDR (MDE process/network events), prefetch, or perimeter logs — not from Quick Assist.

### Packaging history
| Variant | How it's installed | How to detect | How to remove |
|---|---|---|---|
| Store app (current) | Microsoft Store / Intune Store app / inbox provisioned on current Win11 | `Get-AppxPackage -AllUsers MicrosoftCorporationII.QuickAssist` | `Remove-AppxPackage -AllUsers` + `Remove-AppxProvisionedPackage` |
| Legacy inbox app | Windows capability on older Win10 builds | `Get-WindowsCapability -Online -Name App.Support.QuickAssist*` | `Remove-WindowsCapability -Online` |

The Store app depends on the **Edge WebView2 runtime** (inbox on Windows 11; auto-installed on first launch on Windows 10). Keyboard shortcut: **Ctrl + Win + Q**.

### Control surfaces an MSP actually has
| Control | Scope | Stops reinstall? | Breaks Remote Help? | Works off-network? |
|---|---|---|---|---|
| Uninstall + deprovision (Intune Remediation) | Device | No (user can reinstall from Store) | No | Yes |
| AppLocker packaged-app Deny / WDAC PFN deny | Device | Yes (blocks launch) | No | Yes |
| Block Microsoft Store for users | Device | Partially | No | Yes |
| Network block of `remoteassistance.support.services.microsoft.com` | Network | n/a | **Yes** | **No** |

The best MSP default for a Remote Help tenant is **uninstall + AppLocker/WDAC deny**; for a tenant that uses neither and has a secure web gateway, the network block is the broadest single control.
</details>

---
## Dependency Stack
```
Layer 6  Human decision: sharer enters code + clicks Allow (+ Allow control)
Layer 5  Helper identity: MSA or Entra ID sign-in (login.microsoftonline.com / *.live.com / aadcdn.msauth.net)
Layer 4  Session broker: Remote Assistance Service (*.support.services.microsoft.com)  ← shared with Remote Help
Layer 3  Transport: Azure Communication Services (*.trouter/*.registrar/*.flightproxy/*.cc.skype.com,
         edge.skype.com, remoteassistanceprodacs.communication.azure.com, turn.azure.com) + RDP Relay, TCP 443, TLS 1.2
Layer 2  App execution: package present, not blocked by AppLocker/WDAC, WebView2 runtime present
Layer 1  OS: Windows 10/11 with Store app servicing (or legacy capability)
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| Client asks "turn off Quick Assist in Intune" and there's no setting | No policy surface exists | Explain; use remove + AppLocker |
| Quick Assist gone, reappears weeks later | User reinstalled from Store, or new profile got provisioned copy | `Get-AppxProvisionedPackage`, Store access policy |
| Intune Remote Help suddenly fails everywhere | Someone blocked `remoteassistance.support.services.microsoft.com` to kill QA | Firewall/SWG/DNS-filter rule history |
| All Store apps stop launching after "blocking Quick Assist" | AppLocker Packaged-app enforcement enabled without default rules | `Get-AppLockerPolicy -Effective -Xml` |
| QA stuck on "Connecting…" / drops after code entry | ACS or relay FQDNs blocked or TLS-inspected | `Test-NetConnection` to ACS hosts, proxy bypass list |
| Win10: "WebView2 not present" | Runtime missing and auto-install blocked | Evergreen WebView2 deployment |
| Helper can't click admin prompts | Secure desktop — by design | Sharer approves or use Remote Help elevation |
| Helper can't sign in with `DOMAIN\user` | On-prem AD auth not supported | Use Entra ID / MSA |
| User reports "IT called me and connected" but IT didn't | Social-engineering (Storm-1811 pattern) | MDE `DeviceProcessEvents` for QuickAssist.exe |
| Old Windows 10 box has QA even after Store app removal | Legacy capability still installed | `Get-WindowsCapability ... App.Support.QuickAssist*` |

---
## Validation Steps
1. **Package state**
   ```powershell
   Get-AppxPackage -AllUsers -Name MicrosoftCorporationII.QuickAssist
   ```
   Good (retired): no output. Bad: package listed with `PackageUserInformation` showing users.
2. **Provisioning state**
   ```powershell
   Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq 'MicrosoftCorporationII.QuickAssist'
   ```
   Good: no output. Bad: a provisioned package — every new profile gets QA.
3. **Legacy capability**
   ```powershell
   Get-WindowsCapability -Online -Name 'App.Support.QuickAssist*'
   ```
   Good: `NotPresent` (or no result on current builds). Bad: `Installed`.
4. **App-control block**
   ```powershell
   [xml]$p = Get-AppLockerPolicy -Effective -Xml
   $p.AppLockerPolicy.RuleCollection | Where-Object Type -eq 'Appx' | Select-Object EnforcementMode, @{n='Rules';e={$_.ChildNodes.Count}}
   ```
   Good: `Appx` collection `Enabled`, containing the default allow rule plus a Deny referencing `MICROSOFTCORPORATIONII.QUICKASSIST`. Bad: `Enabled` with a single Deny and no allow rule (breaks every packaged app).
5. **Network reachability (if QA or Remote Help should work)**
   ```powershell
   Test-NetConnection remoteassistance.support.services.microsoft.com -Port 443
   ```
   Good: `TcpTestSucceeded : True`. Bad: False → firewall/proxy/DNS.
6. **Remote Help coexistence**
   ```powershell
   Test-Path "$env:ProgramFiles\Remote Help\RemoteHelp.exe"
   ```
   True → do **not** use the network-block method on this estate.

---
## Troubleshooting Steps (by phase)
**Phase 1 — Classify the ticket.** Retirement request, connectivity failure, or security incident. A security incident skips straight to Playbook 4 (contain first, tidy later).

**Phase 2 — Inventory.** Run `Get-QuickAssistExposureAudit.ps1` (or Intune Remediation detection) fleet-wide. Expect three populations: Store app installed, provisioned-only, legacy capability. Each needs a different removal verb.

**Phase 3 — Decide the control.** Use the control-surface table in *How It Works*. The decision hinges on one question: *does this tenant use Intune Remote Help?* If yes, never block the endpoint.

**Phase 4 — Pilot.** AppLocker packaged-app rules are high-blast-radius. Deploy in **Audit only** first and read `Microsoft-Windows-AppLocker/Packaged app-Execution` (event 8024 = would have been blocked) for a week before enforcing.

**Phase 5 — Enforce and monitor.** Enforce app-control, deploy the removal remediation daily, and add an MDE custom detection for `QuickAssist.exe` process creation so reinstalls and any bypass attempts are visible.

**Phase 6 — Connectivity faults (when QA is wanted).** Work down the dependency stack: app present → WebView2 → helper sign-in → broker FQDN → ACS FQDNs → TLS inspection bypass. Most "Connecting…" hangs are a TLS-inspecting proxy on the ACS media relay.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Fleet retirement via Intune Remediation</summary>

**Detection script (exit 1 = non-compliant):**
```powershell
$found = @()
if (Get-AppxPackage -AllUsers -Name MicrosoftCorporationII.QuickAssist -ErrorAction SilentlyContinue) { $found += 'AppX' }
if (Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq 'MicrosoftCorporationII.QuickAssist') { $found += 'Provisioned' }
$cap = Get-WindowsCapability -Online -Name 'App.Support.QuickAssist*' -ErrorAction SilentlyContinue | Where-Object State -eq 'Installed'
if ($cap) { $found += 'Capability' }
if ($found) { Write-Output ("QuickAssist present: " + ($found -join ',')); exit 1 } else { Write-Output 'Clean'; exit 0 }
```
**Remediation script:**
```powershell
Get-AppxPackage -AllUsers -Name MicrosoftCorporationII.QuickAssist | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq 'MicrosoftCorporationII.QuickAssist' | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
Get-WindowsCapability -Online -Name 'App.Support.QuickAssist*' | Where-Object State -eq 'Installed' | Remove-WindowsCapability -Online -ErrorAction SilentlyContinue
```
Settings: run as SYSTEM, 64-bit PowerShell, schedule daily.
**Rollback:** unassign the remediation; deploy Quick Assist as a Microsoft Store app (new) (Store ID `9P7BP5VNWKX5`).
</details>

<details><summary>Playbook 2 — AppLocker packaged-app deny (Remote Help-safe block)</summary>

1. GPO: *Computer Configuration → Windows Settings → Security Settings → Application Control Policies → AppLocker → Packaged app Rules* → **Create Default Rules**.
2. **Create New Rule** → Deny → Everyone → reference installed app *Quick Assist* → publisher-level (Publisher + Package name, any version).
3. Set Packaged-app rules to **Audit only**; deploy; review event 8024 in `Microsoft-Windows-AppLocker/Packaged app-Execution`.
4. Switch to **Enforce rules**.
5. Intune alternative: export the rule collection XML and deploy through the AppLocker CSP (`./Vendor/MSFT/AppLocker/ApplicationLaunchRestrictions/<Grouping>/StoreApps/Policy`) as a custom OMA-URI (String/XML). Keep the default allow rule in the same XML.
6. WDAC/App Control for Business alternative: add a deny rule for PFN `MicrosoftCorporationII.QuickAssist_8wekyb3d8bbwe` in a supplemental policy (see `AppLocker-A.md` for policy layering).

**Rollback:** set the collection back to Audit only, or delete the Deny rule. Removing enforcement is immediate after policy refresh.
</details>

<details><summary>Playbook 3 — Network-level disable (no Remote Help in estate)</summary>

1. Confirm Remote Help isn't in use (Intune → Tenant administration → Remote Help; `RemoteHelp.exe` absent on sample devices).
2. Add `remoteassistance.support.services.microsoft.com` to the SWG/firewall/DNS-filter block list for all corporate egress and for any always-on client (GSA/Zscaler/etc.) so roaming devices are covered too.
3. Validate: launch QA on a test device — "Help someone" fails to obtain a code.
4. Document the dependency in the client's runbook so a future Remote Help rollout knows to remove it.

**Rollback:** remove the block entry.
</details>

<details><summary>Playbook 4 — Suspected malicious session (incident)</summary>

1. **Contain:** `Stop-Process -Name QuickAssist -Force`; MDE **Isolate device** if any tooling was downloaded.
2. **Preserve:** collect the MDE investigation package *before* uninstalling anything; export relevant hunting results.
3. **Timeline:** MDE `DeviceProcessEvents`/`DeviceNetworkEvents`/`DeviceFileEvents` for the 4 h after QuickAssist.exe started. Known Storm-1811 follow-on activity: `curl`/PowerShell downloads of RMM tools (ScreenConnect, NetSupport, AnyDesk), batch scripts, Qakbot/Cobalt Strike loaders, then ransomware.
4. **Identity:** reset password, `Revoke-MgUserSignInSession`, review authentication methods and inbox rules; check sign-ins from the helper's claimed location.
5. **Initial access vector:** look for email-bombing (sudden subscription/newsletter flood) and inbound Teams chats/calls from external tenants posing as helpdesk — harden Teams external access (`M365/Teams/ExternalAccess-A.md`).
6. **Eradicate:** remove installed remote tools, then apply Playbooks 1 + 2 tenant-wide.
7. Hand over to the client's security/IR process with the evidence pack.
</details>

---
## Evidence Pack
```powershell
# Run elevated. Writes to C:\Temp\QuickAssistEvidence_<host>_<timestamp>
$out = "C:\Temp\QuickAssistEvidence_$($env:COMPUTERNAME)_$(Get-Date -Format yyyyMMdd_HHmmss)"
New-Item -ItemType Directory -Path $out -Force | Out-Null
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
"$($cv.ProductName) $($cv.DisplayVersion) $($cv.CurrentBuild).$($cv.UBR)" | Out-File "$out\os.txt"
Get-AppxPackage -AllUsers -Name MicrosoftCorporationII.QuickAssist | Format-List * | Out-File "$out\appx.txt"
Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like '*QuickAssist*' | Format-List * | Out-File "$out\provisioned.txt"
Get-WindowsCapability -Online -Name 'App.Support.QuickAssist*' | Format-List * | Out-File "$out\capability.txt"
Get-Process -Name QuickAssist -ErrorAction SilentlyContinue | Select-Object Id, StartTime, Path | Out-File "$out\process.txt"
Get-ChildItem "$env:windir\Prefetch\QUICKASSIST.EXE-*.pf" -ErrorAction SilentlyContinue | Select-Object Name, CreationTime, LastWriteTime | Out-File "$out\prefetch.txt"
Get-AppLockerPolicy -Effective -Xml | Out-File "$out\applocker-effective.xml"
Get-WinEvent -LogName 'Microsoft-Windows-AppLocker/Packaged app-Execution' -MaxEvents 200 -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id, Message | Export-Csv "$out\applocker-appx-events.csv" -NoTypeInformation
Test-NetConnection remoteassistance.support.services.microsoft.com -Port 443 | Out-File "$out\net-broker.txt"
Get-Content "$env:windir\System32\drivers\etc\hosts" | Out-File "$out\hosts.txt"
Test-Path "$env:ProgramFiles\Remote Help\RemoteHelp.exe" | Out-File "$out\remotehelp-present.txt"
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
Write-Host "Evidence: $out.zip"
```

---
## Command Cheat Sheet
| Task | Command |
|---|---|
| Is QA installed (any user)? | `Get-AppxPackage -AllUsers -Name MicrosoftCorporationII.QuickAssist` |
| Provisioned? | `Get-AppxProvisionedPackage -Online \| ? DisplayName -eq 'MicrosoftCorporationII.QuickAssist'` |
| Legacy capability? | `Get-WindowsCapability -Online -Name App.Support.QuickAssist*` |
| Remove for all users | `Get-AppxPackage -AllUsers -Name MicrosoftCorporationII.QuickAssist \| Remove-AppxPackage -AllUsers` |
| Deprovision | `... \| Remove-AppxProvisionedPackage -Online` |
| Remove legacy | `Get-WindowsCapability -Online -Name App.Support.QuickAssist* \| Remove-WindowsCapability -Online` |
| Kill live session | `Stop-Process -Name QuickAssist -Force` |
| Last run time | `Get-ChildItem C:\Windows\Prefetch\QUICKASSIST.EXE-*.pf` |
| Broker reachable? | `Test-NetConnection remoteassistance.support.services.microsoft.com -Port 443` |
| AppLocker effective policy | `Get-AppLockerPolicy -Effective -Xml` |
| AppLocker Appx events | `Get-WinEvent -LogName 'Microsoft-Windows-AppLocker/Packaged app-Execution' -MaxEvents 50` |
| Remote Help present? | `Test-Path "$env:ProgramFiles\Remote Help\RemoteHelp.exe"` |
| Reinstall (rollback) | `winget install 9P7BP5VNWKX5 --source msstore` |
| Full audit | `.\Get-QuickAssistExposureAudit.ps1 -OutputPath C:\Temp` |

---
## 🎓 Learning Pointers
- The whole product is defined by an **identity asymmetry** — authenticated helper, anonymous sharer, no tenant boundary. Every enterprise control you add is compensating for that. [Use Quick Assist to help users](https://learn.microsoft.com/windows/client-management/client-tools/quick-assist).
- Remote Help is the like-for-like managed replacement and is now bundled into Microsoft 365 E3/E5 (rolling out from July 2026) — for most MSP clients the conversation is "switch", not "secure QA". See `Intune/Troubleshooting/RemoteHelp-A.md` and `IntuneSuiteBaseLicensing-A.md`.
- The shared broker endpoint is the trap: blocking it kills Remote Help too. App control (AppLocker/WDAC) is the precision tool. [Manage packaged apps with AppLocker](https://learn.microsoft.com/windows/security/application-security/application-control/app-control-for-business/applocker/manage-packaged-apps-with-applocker).
- Read Microsoft Threat Intelligence's Storm-1811 write-up (*Threat actors misusing Quick Assist in social engineering attacks leading to ransomware*, May 2024) — the kill chain (email bomb → fake helpdesk call/Teams → QA → RMM → ransomware) is still the template for helpdesk-impersonation attacks.
- No on-device session log exists, so EDR coverage *is* your audit trail. Create an MDE custom detection rule on `QuickAssist.exe` process creation for any estate where QA should be absent. [Custom detection rules](https://learn.microsoft.com/defender-xdr/custom-detection-rules).
- AppLocker packaged-app enforcement without default rules is a classic outage; always pilot in Audit mode and watch event 8024 first.
