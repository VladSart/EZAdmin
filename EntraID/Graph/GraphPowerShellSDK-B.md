# Microsoft Graph PowerShell SDK — Auth Changes, WAM & Windows PowerShell 5.1 Retirement — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

**Covers three changes that land on the same MSP scripts:**
1. **Service-side delegated-auth change.** SDK versions **older than 2.36.1** lose interactive-browser delegated sign-in through the default *Microsoft Graph Command Line Tools* app. App-only and device code keep working. No enforcement date published as of 2026-09-24; Microsoft advises upgrading "sooner rather than later".
2. **WAM by default.** Since **v2.34** (Dec 2025), interactive sign-in on Windows goes through the Web Account Manager broker, not a browser tab. ExchangeOnlineManagement 3.10 and MicrosoftTeams 7.9 also use WAM.
3. **Windows PowerShell 5.1 retirement for Graph modules.** A 12-month retirement period started on **16 Sep 2026**. **v3.0.0 (Q4 CY2026) will support PowerShell 7.x only.** v2 keeps working on 5.1 but gets security fixes only.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [🎓 Learning Pointers](#-learning-pointers)

---
## Triage

```powershell
# 1. Which PowerShell am I in? (Desktop = Windows PowerShell 5.1, Core = PowerShell 7)
$PSVersionTable.PSEdition, $PSVersionTable.PSVersion.ToString()

# 2. Which Graph SDK versions are installed — and are there several side by side?
Get-Module Microsoft.Graph.Authentication -ListAvailable | Select-Object Version, ModuleBase

# 3. What is loaded in THIS session right now (mixed versions = assembly errors)
Get-Module Microsoft.Graph*, ExchangeOnlineManagement, MicrosoftTeams | Select-Object Name, Version

# 4. How is the current session authenticated?
Get-MgContext | Select-Object AuthType, TokenCredentialType, WamEnabled, ClientId, AppName, Account, TenantId
(Get-Command Connect-MgGraph).Version      # the version THIS host actually loaded

# 5. Is WAM switched off for this user profile?
Get-MgGraphOption
```

| Result | Meaning | Action |
|---|---|---|
| `Microsoft.Graph.Authentication` newest version **< 2.36.1** | Interactive-browser delegated sign-in with the default app will stop working once Microsoft enforces the change | → Fix 1 |
| Several `Microsoft.Graph.*` versions installed, or the loaded Graph submodules differ in version | Classic cause of *"Could not load file or assembly 'Microsoft.Graph.Authentication'"* / *"Method not found"* | → Fix 2 |
| Sign-in window is a Windows account picker that picks the wrong account (e.g. your daily driver instead of the admin account), or `DisableLoginByWAM` is set but WAM still appears | WAM using the Windows session account. The disable option is ignored for the default app | → Fix 3 |
| `AADSTS50011` redirect URI mismatch with your own `-ClientId` | App registration is missing the WAM broker redirect URI | → Fix 3 |
| `Connect-MgGraph` fails after `Connect-ExchangeOnline` in the same session (or the reverse), with MSAL/`Microsoft.Identity.Client` errors | MSAL assembly clash between modules | → Fix 4 |
| `PSEdition = Desktop` on an automation host, Azure Automation runbook on a 5.1 runtime, or a scheduled task calling `powershell.exe` | Runs on the platform being retired | → Fix 5 |
| `ClientId = 14d82eec-204b-4c2f-b7e8-296a70dab67e` (Microsoft Graph Command Line Tools) in unattended automation | Delegated interactive auth used for unattended work. It'll break under the changes above, and it's poor practice | → Fix 6 |
| Script works for you but not for a colleague: "needs admin approval" / missing scope | Default app's delegated consent differs per user or scope | → Fix 6 (tenant-specific app) |

---
## Dependency Cascade

<details><summary>What must be true for Connect-MgGraph + cmdlets to work</summary>

```
[PowerShell host]
  ├─ PS 7.x (Core)  ── supported for v2 and v3
  └─ PS 5.1 (Desktop) ── v2 only; retirement period from 16 Sep 2026; v3 will not support it
       │
[Microsoft.Graph.Authentication  ==  every other Microsoft.Graph.* submodule version]
  │   (mismatched versions → assembly load failures; always pin the SAME version)
  │
[Auth flow chosen by Connect-MgGraph parameters]
  ├─ Interactive, default app (no -ClientId) → Microsoft Graph Command Line Tools 14d82eec-…
  │     ├─ Windows ≥2.34: WAM broker (account picker, can reuse the Windows session account)
  │     └─ < 2.36.1: interactive browser — WILL BE BLOCKED service-side
  ├─ Interactive, own app (-ClientId -TenantId) → unaffected by the default-app change
  ├─ Device code (-UseDeviceCode)               → continues to work
  └─ App-only (cert / secret / -Identity)       → continues to work; the right choice for automation
       │
[Entra: consent for requested scopes / app roles + Conditional Access satisfied]
       │
[Co-loaded modules (EXO 3.10+, Teams 7.9+) using compatible MSAL — else load-order clashes]
```
</details>

---
## Diagnosis & Validation Flow

1. **Host check.** `$PSVersionTable.PSEdition`
   `Core` is fine. `Desktop` means plan the move (Fix 5), and v3 won't install or run there.

2. **Version inventory.** `Get-InstalledModule Microsoft.Graph* -AllVersions | Group-Object Version | Select Name, Count`
   Good: one version, ≥ 2.36.1 (current release 2.40.0 as of 16 Sep 2026). Bad: multiple versions, or anything < 2.36.1.
   Note: `Get-InstalledModule` only sees PowerShellGet-installed modules. Also run `Get-Module Microsoft.Graph.Authentication -ListAvailable` to find copies dropped in manually or installed by PSResourceGet.

3. **Session auth type.** `Get-MgContext`
   Check `AuthType` (`Delegated`/`AppOnly`), `TokenCredentialType` (`InteractiveBrowser`, `DeviceCode`, `ClientCertificate`, `ClientSecret`, `UserManagedIdentity`/`SystemManagedIdentity`, …), and `ClientId`.
   Delegated + `InteractiveBrowser` + default ClientId on an old SDK is exactly the combination being cut off.

4. **Load order.** Open a fresh session. Import `Microsoft.Graph.Authentication` **first**, connect, then import EXO/Teams. If the error goes away, it's an assembly clash (Fix 4).

5. **Automation hosts.** `Get-ScheduledTask | ? { $_.Actions.Execute -match 'powershell\.exe' }` lists tasks bound to 5.1. For Azure Automation, check each runbook's **Runtime environment** / runtime version.

6. **Fleet-wide.** Run `EntraID/Scripts/Get-GraphSDKReadinessAudit.ps1 -ScanPath <scripts-folder>` to inventory module versions per host and the `Connect-MgGraph` auth pattern in every script.

---
## Common Fix Paths

<details><summary>Fix 1 — Upgrade the SDK to ≥ 2.36.1 (clean, single version)</summary>

```powershell
# Run in each PowerShell edition you use (5.1 and 7 have separate module paths for CurrentUser/AllUsers)
Get-Module Microsoft.Graph* | Remove-Module -Force            # unload first
# PowerShellGet v2:
Install-Module Microsoft.Graph -Scope CurrentUser -Force -AllowClobber
# or PSResourceGet (PS 7.4+):
# Install-PSResource Microsoft.Graph -Scope CurrentUser -TrustRepository
# Beta cmdlets, if used — must match the same version:
# Install-Module Microsoft.Graph.Beta -Scope CurrentUser -Force -AllowClobber

(Get-Module Microsoft.Graph.Authentication -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1).Version
```
Then remove older versions (Fix 2). **Rollback:** `Install-Module Microsoft.Graph -RequiredVersion <old> -Scope CurrentUser`. Only do this if a specific cmdlet regressed, and never go below 2.36.1 for interactive use.
</details>

<details><summary>Fix 2 — Remove side-by-side / mismatched versions</summary>

```powershell
$keep = (Get-InstalledModule Microsoft.Graph.Authentication).Version     # newest installed
Get-InstalledModule Microsoft.Graph* -AllVersions |
    Where-Object { $_.Version -ne $keep } |
    ForEach-Object { Uninstall-Module -Name $_.Name -RequiredVersion $_.Version -Force -ErrorAction Continue }
# AllUsers copies (Program Files) need an elevated session.
Get-Module Microsoft.Graph* -ListAvailable | Group-Object Version | Select-Object Name, Count
```
Uninstalling 38+ submodules is slow. On a jump host, deleting the old version folders under the module paths (after closing all sessions) is faster. **Rollback:** reinstall the version you need with `-RequiredVersion`.
</details>

<details><summary>Fix 3 — WAM signs in with the wrong account</summary>

**Key fact:** with the **default** Command Line Tools app (`14d82eec-…`), `Set-MgGraphOption -DisableLoginByWAM $true` is **ignored** on Windows. The option gets saved and shows in `Get-MgGraphOption`, but WAM is still used. It's only honoured with **your own app registration** on **≥ 2.35.1**.

```powershell
Disconnect-MgGraph -ErrorAction SilentlyContinue
# Option A — stay on WAM: in the picker choose "Use another account" and pick the admin identity
Connect-MgGraph -Scopes 'User.Read.All' -NoWelcome
Get-MgContext | Select-Object Account, AppName, ClientId, WamEnabled

# Option B — browser sign-in (explicit account entry) via a tenant-specific app, SDK >= 2.35.1
Set-MgGraphOption -DisableLoginByWAM $true
Connect-MgGraph -ClientId '<AppId>' -TenantId '<tenant-id>' -Scopes 'User.Read.All' -NoWelcome
Get-MgContext | Select-Object AppName, ClientId, TokenCredentialType, WamEnabled     # expect WamEnabled False
```
The app registration needs **Authentication → Mobile and desktop applications** redirect URIs: `http://localhost` (browser flow) and `ms-appx-web://Microsoft.AAD.BrokerPlugin/<AppId>` (WAM). If the broker URI is missing, WAM sign-in fails with **AADSTS50011**.
Note: `TokenCredentialType : InteractiveBrowser` shows up even when WAM was used. Check `WamEnabled` instead.
VS Code / embedded terminals: the WAM dialog can open **behind** the editor, so `Connect-MgGraph` looks hung. Alt-Tab to find it.
**Rollback:** `Set-MgGraphOption -DisableLoginByWAM $false`.
</details>

<details><summary>Fix 4 — Assembly/MSAL clash with ExchangeOnlineManagement / MicrosoftTeams</summary>

```powershell
# Start a NEW session, then load Graph first:
Import-Module Microsoft.Graph.Authentication
Connect-MgGraph -Scopes 'User.Read.All' -NoWelcome
Import-Module ExchangeOnlineManagement
Connect-ExchangeOnline -ShowBanner:$false
```
If one order doesn't work, try the reverse. The modules ship different MSAL versions, and whichever loads first wins. For scheduled or unattended work, use **app-only** auth for each module in a **separate process** (`pwsh -File`), or use PowerShell 7, where Graph v2 already uses Assembly Load Contexts. Keep all three modules current: most clashes get fixed on the module side over time.
</details>

<details><summary>Fix 5 — Move scripts and runbooks off Windows PowerShell 5.1</summary>

```powershell
# Install PowerShell 7 (LTS) on the automation host
winget install --id Microsoft.PowerShell --source winget
# Scheduled tasks: repoint the action to pwsh.exe
$t = Get-ScheduledTask -TaskName '<TaskName>'
$a = $t.Actions[0]
$new = New-ScheduledTaskAction -Execute "$env:ProgramFiles\PowerShell\7\pwsh.exe" -Argument $a.Arguments -WorkingDirectory $a.WorkingDirectory
Set-ScheduledTask -TaskName '<TaskName>' -Action $new
# Install the Graph SDK in the PS7 scope (separate from 5.1 CurrentUser/AllUsers paths)
pwsh -NoProfile -Command "Install-Module Microsoft.Graph -Scope AllUsers -Force"
```
- Remove `#Requires -PSEdition Desktop` and `-UseWindowsPowerShell` wrappers where they only existed for Graph.
- **Azure Automation:** create a PowerShell 7.x runtime environment, import Microsoft.Graph into it, and relink the runbook. Test before switching schedules.
- Modules that are still 5.1-only in practice (e.g. some IIS/WebAdministration or legacy scheduled-task cmdlets): split them out, don't block the Graph move on them.
**Rollback:** re-apply the original task action (`Set-ScheduledTask -Action $t.Actions`) or relink the runbook to the 5.1 runtime. This is fine during the retirement period, but not beyond v3.
</details>

<details><summary>Fix 6 — Stop using the default app for automation / shared admin work</summary>

```powershell
# App-only (certificate) — unaffected by the delegated-auth and WAM changes
Connect-MgGraph -ClientId '<AppId>' -TenantId '<tenant-id>' -CertificateThumbprint '<thumbprint>' -NoWelcome

# Managed identity (Azure Automation / Azure VM)
Connect-MgGraph -Identity -NoWelcome

# Interactive, but with a tenant-specific app you control (scoped permissions, own CA targeting)
Connect-MgGraph -ClientId '<AppId>' -TenantId '<tenant-id>' -Scopes 'User.Read.All'

# Device code (headless/jump boxes) — continues to work
Connect-MgGraph -UseDeviceCode -Scopes 'User.Read.All'
```
A tenant-specific app also stops **permission creep** on the shared Command Line Tools service principal. Consider blocking device code flow with Conditional Access where it isn't needed (`Security/ConditionalAccess/`).
</details>

---
## Escalation Evidence

```
GRAPH POWERSHELL SDK — ESCALATION
Host / OS                          : <name>  <Windows build / macOS / Linux>
PSEdition / PSVersion              : <Desktop 5.1 | Core 7.x.y>
Microsoft.Graph.Authentication (loaded / all installed): <x.y.z> / <list>
Other modules loaded (name+version): <ExchangeOnlineManagement x, MicrosoftTeams y, Az.Accounts z>
Get-MgContext (AuthType / TokenCredentialType / ClientId / AppName): <paste>
Get-MgGraphOption                  : <paste>
Exact error + stack (Get-Error)    : <paste>
Reproduces in a clean session loading Graph first? : <Y/N>
Reproduces on PS 7 with SDK ≥2.36.1?               : <Y/N>
Correlation/Request ID (from error) : <guid>   Timestamp UTC: <time>
GitHub issue reference (if any)    : https://github.com/microsoftgraph/msgraph-sdk-powershell/issues/<n>
```

---
## 🎓 Learning Pointers
- **Retirement here means maintenance, not a kill switch.** v2 keeps running on 5.1, but 5.1-specific bugs won't be fixed and v3 won't run there. Source: [Investing in a more reliable Microsoft Graph PowerShell experience](https://devblogs.microsoft.com/microsoft365dev/investing-in-a-more-reliable-microsoft-graph-powershell-experience/) (16 Sep 2026).
- **The < 2.36.1 cut-off is a separate, service-side change.** Pinning an old SDK won't save browser sign-in. App-only and device code are unaffected, according to the Graph SDK engineering manager's replies on that post and GitHub issue #3629 ([summary](https://office365itpros.com/2026/08/28/interactive-graph-sessions-wam/)).
- **"Could not load file or assembly" is nearly always versions or load order**, not a broken install. Keep one version per module and load Graph first. Background: [Microsoft Starts Twelve-Month Retirement of Windows PowerShell Support](https://office365itpros.com/2026/09/17/microsoft-graph-powershell-sdkv3/).
- **`DisableLoginByWAM` only works with your own app.** Ben Whitmore's [WAM Bam](https://msendpointmgr.com/2026/08/09/microsoft-graph-sdk-wam/) walks through `WamEnabled`, the 2.34 → 2.35.1 timeline and the two redirect URIs.
- **Unattended automation should never ride on a delegated interactive session.** Use certificates or managed identity: [Use app-only authentication with the Microsoft Graph PowerShell SDK](https://learn.microsoft.com/powershell/microsoftgraph/app-only).
- **Get off Task Scheduler while you're moving runtimes.** Azure Automation with managed identity is easier to secure and monitor. [Azure Automation runtime environments](https://learn.microsoft.com/azure/automation/runtime-environment-overview).
- Deep dive: `GraphPowerShellSDK-A.md` · fleet inventory: `../Scripts/Get-GraphSDKReadinessAudit.ps1`.
