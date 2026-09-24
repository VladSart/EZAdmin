# Microsoft Graph PowerShell SDK — Auth Changes, WAM & Windows PowerShell 5.1 Retirement — Reference Runbook (Mode A: Deep Dive)
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
- **In scope:** the `Microsoft.Graph` / `Microsoft.Graph.Beta` PowerShell SDK (v2.x → v3) as the automation layer MSP engineers use against Entra ID, Intune, Exchange-via-Graph and more. Three overlapping 2025–2026 changes: WAM becoming the default on Windows (v2.34, Dec 2025), the service-side cut-off for pre-2.36.1 interactive-browser delegated auth on the default app, and the Windows PowerShell 5.x retirement period (from 16 Sep 2026) ahead of PS7-only v3 (Q4 CY2026).
- **Out of scope:** Graph REST semantics and batching (`GraphAPI-BatchOperations-A.md`), and individual permission-scope changes (`ReadBasicAllScopeChange-B.md`). ExchangeOnlineManagement/MicrosoftTeams module internals are covered only where they collide with Graph (MSAL/WAM).
- **Assumes:** Windows admin workstations or automation hosts, and in places Azure Automation. macOS/Linux have no WAM, so interactive sign-in there uses the browser or device code. The PS 5.1 retirement is Windows-only by definition.
- **Source currency (2026-09-24):** Microsoft 365 Developer Blog, *Investing in a more reliable Microsoft Graph PowerShell experience* (16 Sep 2026), including Microsoft engineer replies in its comments. SDK v2.34.0 release notes and the SDK `docs/authentication.md` (via MSEndpointMgr, 9 Aug 2026). GitHub issue #3629 *Delegated Authentication changes* (via Office365ITPros, 28 Aug 2026). Current gallery release was **2.40.0** on 16 Sep 2026. **No enforcement date** for the pre-2.36.1 cut-off had been published at build time. Re-check #3629.

---
## How It Works

<details><summary>Full architecture</summary>

### Module anatomy
`Microsoft.Graph` is a meta-module over ~40 submodules (`Microsoft.Graph.Users`, `.Identity.SignIns`, `.DeviceManagement`, …). **Every** submodule depends on `Microsoft.Graph.Authentication`, which carries `Connect-MgGraph`, `Invoke-MgGraphRequest`, the MSAL/Azure.Identity assemblies and the token cache. Two rules fall out of this:
1. **All loaded submodules must be the same version as the loaded Authentication module.** PowerShell will happily auto-load `Users 2.25` next to `Authentication 2.40` if both are on disk, and you get *"Could not load file or assembly"* / *"Method not found"* errors.
2. **Only one version of a .NET assembly loads per process** (per Assembly Load Context on PS7). If ExchangeOnlineManagement or MicrosoftTeams loaded a different `Microsoft.Identity.Client` (MSAL) first, Graph auth can break, and vice versa. Microsoft's engineers acknowledge Assembly Load Contexts on PS7 are "not a perfect solution", and this is ongoing work.

### Auth flows and what `Connect-MgGraph` picks
| Parameters | Flow | Identity/app | Affected by 2026 changes? |
|---|---|---|---|
| `-Scopes` only | Interactive delegated | Default app **Microsoft Graph Command Line Tools** `14d82eec-204b-4c2f-b7e8-296a70dab67e` | **Yes.** WAM forced on Windows (v2.34+). Pre-2.36.1 browser flow to be blocked service-side |
| `-ClientId -TenantId -Scopes` | Interactive delegated | Your app registration | WAM default, but `DisableLoginByWAM` honoured on ≥2.35.1. Not affected by the default-app cut-off |
| `-UseDeviceCode` | Device code delegated | Default or own app | Continues to work (subject to your CA device-code-flow policy) |
| `-ClientId -TenantId -CertificateThumbprint`/`-Certificate` | App-only | Own app | Unaffected |
| `-ClientSecretCredential` | App-only | Own app | Unaffected (but secrets are weaker than certs) |
| `-Identity` (`-ClientId` for user-assigned) | Managed identity | Azure resource | Unaffected |
| `-AccessToken` | Bring-your-own token | Whatever minted it | Unaffected |

### WAM (Web Account Manager)
WAM is the Windows authentication broker (the same component behind Windows SSO/PRT). From **v2.34.0 (20 Dec 2025)** the SDK routes interactive delegated sign-in on Windows through WAM by default: you get a Windows account picker instead of a browser tab, and it can reuse accounts known to the Windows session. The v2.34 release notes said it "cannot be disabled". **v2.35.x** restored `Set-MgGraphOption -DisableLoginByWAM $true`, but **only when you connect with your own `-ClientId`**. With the default app the option is saved and ignored. Diagnostics: `Get-MgContext` exposes `WamEnabled`. `TokenCredentialType` still reads `InteractiveBrowser` under WAM, so don't use it to detect WAM.

Why admins resist WAM: PAWs and jump boxes where the Windows logon identity differs from the admin identity, shared admin VMs, and VS Code terminals where the WAM prompt opens behind the window. Why Microsoft is pushing it: the broker supports device-bound tokens and plays properly with Conditional Access device-state and token-protection controls (`Security/ConditionalAccess/TokenProtection-A.md`).

### The pre-2.36.1 delegated-auth cut-off (service-side)
Per GitHub #3629 and a Microsoft engineer's reply on the 16 Sep 2026 devblog: when the change lands, SDK versions **prior to 2.36.1** will no longer complete **interactive browser** delegated authentication. **App-only and device code continue to work.** This is enforced by the service, so keeping an old SDK on a jump box does *not* preserve the old browser flow. Upgrade target: ≥2.36.1 (Office365ITPros quotes ≥2.37.0 from the issue text; current is 2.40.0). The devblog replies say this is independent of the 12-month PS 5.1 timeline, with similar timing, and "should be performed sooner rather than later".

### Windows PowerShell 5.x retirement for Graph modules
- **16 Sep 2026:** 12-month retirement period starts. "Retirement refers to maintenance, not compatibility." v2.x keeps declaring 5.1 compatibility and in most cases keeps working. 5.1-specific issues won't be investigated or fixed. Security fixes continue.
- **Q4 CY2026:** **v3.0.0** ships, supported on **PowerShell 7.x only**. After v3.0.0, no new v2 releases except security fixes. v3 aims to be "minimally disruptive" (same cmdlet usage) and mainly changes the code generator, but will "intentionally diverge" in some places, with documented changes.
- **Practical consequence:** every scheduled task, RMM script, Azure Automation 5.1 runbook and `powershell.exe` wrapper that imports Graph modules is on a clock. Some Microsoft modules are still 5.1-bound in practice (WebAdministration/IIS, some legacy cmdlets). Split them out, don't keep Graph on 5.1 for their sake.

### Permission creep on the default app
Every admin who ever consented a scope to *Microsoft Graph Command Line Tools* adds to that one service principal's delegated grants. Over time it holds a large union of scopes, and any user permitted to sign in to it can request them. Tenant-specific app registrations per team or function (with only the scopes they need, plus assignment-required and CA targeting) fix both this and the WAM/default-app coupling.
</details>

---
## Dependency Stack
```
[L7] Script / runbook / RMM job logic
[L6] Microsoft.Graph.<Workload> submodules  ── must equal L5 version
[L5] Microsoft.Graph.Authentication  (MSAL + Azure.Identity + token cache)
        └─ co-loaded ExchangeOnlineManagement / MicrosoftTeams / Az.Accounts MSAL versions (first loaded wins)
[L4] Auth flow: WAM | browser | device code | cert | secret | managed identity
[L3] Entra app: default Command Line Tools (14d82eec-…) or tenant app (redirect URIs: http://localhost, ms-appx-web://Microsoft.AAD.BrokerPlugin/<AppId>)
[L2] Entra policy: consent/admin consent, assignment required, Conditional Access (device code flow, token protection, compliant device)
[L1] PowerShell host: 7.x (Core, target) | 5.1 (Desktop, retiring for Graph; not supported by v3)
[L0] OS: Windows (WAM available) | macOS/Linux (no WAM; PS7 only)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| `Could not load file or assembly 'Microsoft.Graph.Authentication…'` / `Method not found` | Mixed submodule versions, or an older copy auto-loaded from another module path | Validation 2, 3 |
| Graph connect fails only after `Connect-ExchangeOnline` (or reverse) | MSAL assembly clash | Validation 4 |
| Account picker instead of browser, wrong account chosen | WAM default (v2.34+) using Windows session accounts | `Get-MgContext`.WamEnabled |
| `DisableLoginByWAM` set, WAM still appears | Ignored with the default app | ClientId = 14d82eec-… |
| `AADSTS50011` with own ClientId | Missing redirect URI for the chosen flow | App registration → Authentication |
| `Connect-MgGraph` "hangs" in VS Code | WAM prompt behind the editor window | Alt-Tab |
| Interactive sign-in suddenly fails on an old jump box, device code still works | Pre-2.36.1 cut-off enforced | `(Get-Command Connect-MgGraph).Version` |
| Runbook fine interactively, fails in Azure Automation | Runbook on 5.1 runtime with different module versions, or relies on delegated auth | Runtime environment + auth pattern |
| New cmdlet or fix "not available" on the automation host | Host pinned to PS 5.1 / old v2. After v3, v2 gets security-only updates | Validation 1 |
| Colleague gets "Need admin approval" on the same script | Scope not consented on the default app for that user/tenant | Enterprise apps → Command Line Tools → Permissions |

---
## Validation Steps

1. **Host edition and version.**
   `$PSVersionTable | Select PSEdition, PSVersion` → Good: `Core 7.4+/7.5+`. Needs a plan: `Desktop 5.1`.
2. **Installed versions (all paths).**
   ```powershell
   Get-Module Microsoft.Graph.Authentication -ListAvailable | Select Version, ModuleBase
   $env:PSModulePath -split [IO.Path]::PathSeparator
   ```
   Good: a single version ≥ 2.36.1. Bad: several versions, or copies under both `Documents\WindowsPowerShell\Modules` and `Documents\PowerShell\Modules` at different versions (5.1 and 7 use different user paths).
3. **Loaded versions in the failing session.**
   `Get-Module Microsoft.Graph* | Select Name, Version` → Good: every row the same version.
4. **Co-loaded modules.**
   `Get-Module ExchangeOnlineManagement, MicrosoftTeams, Az.Accounts | Select Name, Version` → reproduce in a clean `pwsh -NoProfile` loading Graph first, then the other module, then the reverse order.
5. **Session identity.**
   `Get-MgContext | Format-List AuthType, TokenCredentialType, WamEnabled, ClientId, AppName, Account, Scopes` → For automation, `AuthType` should be `AppOnly`. Delegated on an unattended host is a design defect.
6. **Automation surface.**
   ```powershell
   Get-ScheduledTask | Where-Object { $_.Actions.Execute -match 'powershell(\.exe)?$' } |
       Select TaskPath, TaskName, @{n='Args';e={$_.Actions.Arguments}}
   ```
   Azure Automation: Portal → Automation account → Runbooks → *Runtime environment* column. Anything on PowerShell 5.1 that imports Microsoft.Graph is a migration item.
7. **Script corpus.** `Get-GraphSDKReadinessAudit.ps1 -ScanPath <repo>` classifies every `Connect-MgGraph` by auth pattern and flags `#Requires -PSEdition Desktop`, `-RequiredVersion` pins below 2.36.1, and delegated interactive use in files that look like automation.

---
## Troubleshooting Steps (by phase)

**Phase A — Install/load failures.** Work L6 → L5 → co-loaded modules: unify versions, clear old copies from every module path, then test load order in a clean `-NoProfile` session.

**Phase B — Sign-in failures.** Identify the flow from the `Connect-MgGraph` parameters and `Get-MgContext`. Default app + old SDK means upgrade. WAM problems mean either living with WAM (pick the account) or moving to your own app with `DisableLoginByWAM`. `AADSTS50011` means redirect URIs. `AADSTS65001`/consent means scopes. CA blocks mean checking sign-in logs for the app ID `14d82eec-…` or your own app.

**Phase C — Platform migration.** Inventory 5.1 dependencies (tasks, runbooks, RMM, wrappers). Install PS7 LTS, install Graph into the PS7 scope, run the script under `pwsh`, then fix incompatibilities (usually other modules, rarely Graph cmdlets). Switch the scheduler or runtime last.

**Phase D — v3 readiness (Q4 2026 onward).** Pin production to a tested v2 until v3 has been validated against your scripts in a lab. v3 is PS7-only. Read the v3 divergence notes when published.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Standardise a jump box / admin workstation</summary>

```powershell
# Elevated, in pwsh (PS7)
Get-Module Microsoft.Graph* | Remove-Module -Force
$paths = $env:PSModulePath -split [IO.Path]::PathSeparator
Get-ChildItem $paths -Directory -Filter 'Microsoft.Graph*' -ErrorAction SilentlyContinue |
    Select-Object FullName | Export-Csv .\graph-module-folders-before.csv -NoTypeInformation   # rollback reference
Install-Module Microsoft.Graph -Scope AllUsers -Force -AllowClobber
$keep = (Get-Module Microsoft.Graph.Authentication -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1).Version
Get-InstalledModule Microsoft.Graph* -AllVersions | Where-Object Version -ne $keep |
    ForEach-Object { Uninstall-Module $_.Name -RequiredVersion $_.Version -Force -ErrorAction Continue }
Get-Module Microsoft.Graph* -ListAvailable | Group-Object Version | Select-Object Name, Count
```
Repeat under Windows PowerShell 5.1 **only** if 5.1 must still run Graph during the retirement period. Otherwise uninstall Graph from 5.1 to prevent accidental use.
**Rollback:** `Install-Module Microsoft.Graph -RequiredVersion <old>` (never below 2.36.1 for interactive use).
</details>

<details><summary>Playbook 2 — Tenant-specific app for interactive admin sessions (WAM + browser capable)</summary>

```powershell
Connect-MgGraph -Scopes 'Application.ReadWrite.All' -NoWelcome
$app = New-MgApplication -DisplayName 'MSP-Graph-Interactive-<Team>' -SignInAudience 'AzureADMyOrg' `
        -IsFallbackPublicClient:$true -PublicClient @{ RedirectUris = @('http://localhost') }
Update-MgApplication -ApplicationId $app.Id -PublicClient @{
    RedirectUris = @('http://localhost', "ms-appx-web://Microsoft.AAD.BrokerPlugin/$($app.AppId)") }
$sp = New-MgServicePrincipal -AppId $app.AppId -AppRoleAssignmentRequired:$true   # only assigned admins may sign in
"AppId: $($app.AppId)"
# Assign admins/groups to $sp (Enterprise apps → Users and groups), grant only needed delegated scopes, target with CA.
# Use:
# Connect-MgGraph -ClientId <AppId> -TenantId <tenantId> -Scopes 'User.Read.All'
```
**Rollback:** `Remove-MgApplication -ApplicationId $app.Id` (soft-deleted for 30 days; restore with `Restore-MgDirectoryDeletedItem`).
</details>

<details><summary>Playbook 3 — Convert an unattended script from delegated to app-only (certificate)</summary>

```powershell
# On the automation host (Windows): create a cert in LocalMachine\My, export the public part
$cert = New-SelfSignedCertificate -Subject 'CN=MSP-Graph-Automation' -CertStoreLocation 'Cert:\LocalMachine\My' `
        -KeyExportPolicy NonExportable -KeySpec Signature -KeyLength 2048 -NotAfter (Get-Date).AddMonths(12)
Export-Certificate -Cert $cert -FilePath .\MSP-Graph-Automation.cer
# Upload .cer to the app registration (Certificates & secrets), grant APPLICATION permissions + admin consent.
# In the script, replace Connect-MgGraph -Scopes ... with:
Connect-MgGraph -ClientId '<AppId>' -TenantId '<tenantId>' -CertificateThumbprint $cert.Thumbprint -NoWelcome
```
Grant the task account read access to the private key if it doesn't run as SYSTEM. Track cert expiry (`EntraID/Scripts/Get-AppRegistrationCredentialAudit.ps1`).
**Rollback:** keep the old delegated script version side by side until the app-only run has succeeded on schedule.
</details>

<details><summary>Playbook 4 — Move scheduled tasks and Azure Automation runbooks to PowerShell 7</summary>

```powershell
winget install --id Microsoft.PowerShell --source winget --accept-package-agreements --accept-source-agreements
$pwsh = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
Get-ScheduledTask | Where-Object { $_.Actions.Execute -match 'powershell(\.exe)?$' } | ForEach-Object {
    $t = $_; $a = $t.Actions[0]
    $t | Export-ScheduledTask | Out-File ".\TaskBackup-$($t.TaskName).xml"            # rollback copy
    if ($a.Arguments -match 'Graph|Mg') {                                                  # crude filter — review list first
        $new = New-ScheduledTaskAction -Execute $pwsh -Argument $a.Arguments -WorkingDirectory $a.WorkingDirectory
        Set-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Action $new
        "Repointed: $($t.TaskPath)$($t.TaskName)"
    }
}
```
Test-run each task (`Start-ScheduledTask`) and check `LastTaskResult`. For **Azure Automation**, create a *PowerShell 7.x* runtime environment, add `Microsoft.Graph.Authentication` + the needed submodules **at the same version**, update each runbook to that environment, and prefer `Connect-MgGraph -Identity`.
**Rollback:** `Register-ScheduledTask -Xml (Get-Content .\TaskBackup-<name>.xml -Raw) -TaskName <name> -Force`, or relink the runbook to its old runtime.
</details>

---
## Evidence Pack

```powershell
# Collect-GraphSDKEvidence.ps1 — read-only, run in the failing host/edition
$ts = Get-Date -Format yyyyMMdd-HHmm; $out = Join-Path $PWD "GraphSDK-Evidence-$ts"
New-Item -ItemType Directory -Path $out -Force | Out-Null
$PSVersionTable | Out-String | Out-File "$out\PSVersionTable.txt"
$env:PSModulePath -split [IO.Path]::PathSeparator | Out-File "$out\PSModulePath.txt"
Get-Module Microsoft.Graph*, ExchangeOnlineManagement, MicrosoftTeams, Az.Accounts -ListAvailable |
    Select-Object Name, Version, ModuleBase | Export-Csv "$out\Modules-Available.csv" -NoTypeInformation
Get-Module | Select-Object Name, Version, ModuleBase | Export-Csv "$out\Modules-Loaded.csv" -NoTypeInformation
if (Get-Command Get-MgContext -ErrorAction SilentlyContinue) {
    Get-MgContext | Select-Object * -ExcludeProperty CertificateThumbprint | Out-String | Out-File "$out\MgContext.txt"
    Get-MgGraphOption | Out-String | Out-File "$out\MgGraphOption.txt"
}
[AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.FullName -match 'Identity\.Client|Azure\.Identity|Microsoft\.Graph' } |
    Select-Object FullName, Location | Export-Csv "$out\Loaded-Assemblies.csv" -NoTypeInformation
if ($Error.Count) { $Error | Select-Object -First 5 | ForEach-Object { $_ | Format-List * -Force | Out-String } | Out-File "$out\LastErrors.txt" }
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force; "Evidence: $out.zip"
```
The `Loaded-Assemblies.csv` MSAL (`Microsoft.Identity.Client`) version list is what settles module-clash arguments.

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Edition/version | `$PSVersionTable.PSEdition; $PSVersionTable.PSVersion` |
| Version actually loaded | `(Get-Command Connect-MgGraph).Version` |
| All Graph versions on disk | `Get-Module Microsoft.Graph.Authentication -ListAvailable` |
| Loaded Graph modules | `Get-Module Microsoft.Graph*` |
| Install/upgrade | `Install-Module Microsoft.Graph -Scope CurrentUser -Force` / `Update-Module Microsoft.Graph` |
| Remove old versions | `Get-InstalledModule Microsoft.Graph* -AllVersions \| ? Version -ne <keep> \| Uninstall-Module -Force` |
| Session identity | `Get-MgContext \| fl AuthType,TokenCredentialType,WamEnabled,ClientId,AppName,Account` |
| WAM option | `Get-MgGraphOption` / `Set-MgGraphOption -DisableLoginByWAM $true` (own app only) |
| Own app, interactive | `Connect-MgGraph -ClientId <id> -TenantId <tid> -Scopes <s>` |
| Device code | `Connect-MgGraph -UseDeviceCode -Scopes <s>` |
| App-only cert | `Connect-MgGraph -ClientId <id> -TenantId <tid> -CertificateThumbprint <tp>` |
| Managed identity | `Connect-MgGraph -Identity` |
| 5.1-bound tasks | `Get-ScheduledTask \| ? { $_.Actions.Execute -match 'powershell' }` |
| Install PS7 | `winget install --id Microsoft.PowerShell --source winget` |
| Fleet/script audit | `.\Get-GraphSDKReadinessAudit.ps1 -ScanPath <folder>` |

---
## 🎓 Learning Pointers
- **Retirement means maintenance, not a kill switch.** Read Microsoft's own wording before telling a customer "Graph stops working on 5.1": [Investing in a more reliable Microsoft Graph PowerShell experience](https://devblogs.microsoft.com/microsoft365dev/investing-in-a-more-reliable-microsoft-graph-powershell-experience/).
- **The default app is a shared, over-consented identity.** Tenant apps per team give you least privilege, CA targeting and control over the WAM/browser choice. See [MSEndpointMgr: WAM Bam](https://msendpointmgr.com/2026/08/09/microsoft-graph-sdk-wam/) and [Office365ITPros: WAM for interactive Graph sessions](https://office365itpros.com/2026/08/28/interactive-graph-sessions-wam/).
- **One process, one MSAL.** Module clashes are .NET assembly-loading problems, not bugs in your script. Separate processes or app-only auth per module are the reliable workaround.
- **Unattended = app-only.** [App-only authentication for the Microsoft Graph PowerShell SDK](https://learn.microsoft.com/powershell/microsoftgraph/app-only) and [Authentication commands](https://learn.microsoft.com/powershell/microsoftgraph/authentication-commands).
- **Moving runtimes is the moment to leave Task Scheduler.** See [Azure Automation runtime environments](https://learn.microsoft.com/azure/automation/runtime-environment-overview) and Tony Redmond's case in [Microsoft Starts Twelve-Month Retirement of Windows PowerShell Support for Graph SDK](https://office365itpros.com/2026/09/17/microsoft-graph-powershell-sdkv3/).
- Watch GitHub issue #3629 in `microsoftgraph/msgraph-sdk-powershell` for the enforcement date of the pre-2.36.1 cut-off.
