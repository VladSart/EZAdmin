# Just Enough Administration (JEA) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains the role-capability/session-configuration architecture, not just the fix commands.

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
- [Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

**In scope:**
- Role capability files (`.psrc`) — authoring, `VisibleCmdlets`/`VisibleFunctions`/`VisibleProviders`/`VisibleExternalCommands`, parameter/value scoping, custom functions
- Session configuration files (`.pssc`) — `RunAsVirtualAccount`/`RunAsVirtualAccountGroups`/`GroupManagedServiceAccount` identity models, `RoleDefinitions`, `RequiredGroups` conditional access, transcription, the user drive
- Single-machine registration (`Register-PSSessionConfiguration`) and multi-machine deployment via the JEA DSC resource
- Role-capability merge rules across multiple matching roles
- Auditing and reviewing what a JEA endpoint actually grants in practice

**Out of scope:**
- **WinRM listener/transport configuration itself** (ports, TrustedHosts, authentication mechanisms, HTTPS listener setup) — a prerequisite layer JEA sits on top of, fully covered in `WinRM-A.md`/`WinRM-B.md`. This topic assumes WinRM remoting already works and focuses purely on the JEA endpoint layered on top of it.
- **Desired State Configuration (DSC) internals beyond the JEA DSC resource's specific role in multi-machine deployment** — DSC's own broader configuration/pull-server architecture is a distinct topic.
- **AD FS PowerShell delegation and other product-specific JEA implementations** (e.g., Exchange Server's own long-standing RBAC-over-remoting model, which predates and is architecturally distinct from general-purpose JEA) — referenced only where useful for disambiguation.
- **Non-Windows JEA** (PowerShell 7+ on Linux/macOS technically supports the same JEA mechanism) — this topic is written for the Windows Server/Windows Pro-Enterprise MSP context and assumes a Windows-hosted endpoint.

**Assumptions:**
- PowerShell 5.0 or later (JEA requires no separate installation — a built-in PowerShell capability)
- Reader has local administrator rights on the target machine for registration/testing
- Familiarity with basic PowerShell remoting concepts (sessions, `Enter-PSSession`/`Invoke-Command`) — this topic does not re-explain WinRM remoting fundamentals, see `WinRM-A.md` for that layer

---

## How It Works

<details><summary>Full architecture</summary>

### The Problem JEA Solves

The canonical example Microsoft's own documentation leads with: a DNS Server role co-installed on a Domain Controller. DNS administrators need local admin rights to restart the DNS service or clear a poisoned cache — but the only practical way to grant that on a DC is Domain Admins membership, which hands them the entire domain. JEA exists to close exactly this gap: publish a narrow, role-scoped PowerShell endpoint that grants precisely the commands a role needs, under a temporary elevated identity that exists only for the session's duration, with every command logged.

### The Two Authoring Layers

JEA configuration is split across two distinct file types, each with a distinct extension and distinct responsibility:

**Role capability files (`.psrc`)** — a PowerShell data file answering "what can someone in this ROLE do." Created via `New-PSRoleCapabilityFile`. Defines, per role:
- `VisibleCmdlets` / `VisibleFunctions` — which commands are exposed, optionally scoped to specific parameters and specific allowed values (`ValidateSet`/`ValidatePattern`)
- `VisibleExternalCommands` — executables/scripts, always by **full path** (never a bare name, to prevent a same-named malicious binary elsewhere on the system path from being invoked instead)
- `VisibleProviders` — PowerShell providers (Registry, Certificate, FileSystem, etc.); **none** are available by default, a deliberate reduction of information-disclosure risk
- `FunctionDefinitions` — inline custom functions authored specifically for the role, useful for wrapping a complex or hard-to-constrain native command in simpler, validated logic

**Session configuration files (`.pssc`)** — a PowerShell data file answering "who can connect, as WHOM, and which roles do they get." Created via `New-PSSessionConfigurationFile -SessionType RestrictedRemoteServer`. Defines:
- The RunAs identity (virtual account, virtual account with specific group membership, or group-managed service account)
- `RoleDefinitions` — the user/group-to-role-capability mapping
- `RequiredGroups` — conditional access rules layered on top of role mapping
- `TranscriptDirectory` — session transcription for audit
- `MountUserDrive` — a constrained file-copy path that doesn't expose the full FileSystem provider

A role capability file has **no effect on its own** — it must be referenced by name (its filename minus the `.psrc` extension) from a session configuration file's `RoleDefinitions`, and that session configuration must itself be registered as an endpoint before any of it takes effect.

### RestrictedRemoteServer: The Locked-Down Starting Point

`New-PSSessionConfigurationFile -SessionType RestrictedRemoteServer` produces a session type running in **NoLanguage** mode with, by default, only eight built-in commands available (`Clear-Host`, `Exit-PSSession`, `Get-Command`, `Get-FormatData`, `Get-Help`, `Measure-Object`, `Out-Default`, `Select-Object` — plus their aliases), zero PowerShell providers, and zero external programs. Every capability beyond this bare minimum is additive, defined entirely by the role capability files referenced in `RoleDefinitions`. This "deny by default, allow explicitly" starting point is the architectural foundation the entire JEA security model rests on.

### Identity Models — Choosing What JEA Runs As

Three RunAs identity options, each suited to a different scenario:

- **Local Virtual Account** (`RunAsVirtualAccount = $true`) — a temporary account, unique per connecting user, that exists only for the session's duration. On a member server/workstation it belongs to the local **Administrators** group by default; on a Domain Controller it belongs to **Domain Admins** by default — a distinction worth internalizing, since the DC default is far more powerful than most JEA use cases actually need.
- **Scoped Virtual Account** (`RunAsVirtualAccount = $true` + `RunAsVirtualAccountGroups = @('GroupA','GroupB')`) — when one or more specific security groups are named, the virtual account belongs to ONLY those groups instead of the local/domain admin default. On a member server these must be **local** groups, not domain groups. This is the recommended pattern whenever the role's actual command set doesn't require full administrative rights.
- **Group Managed Service Account (GMSA)** — required when JEA users need to reach **network** resources (file shares, remote services) that a local/virtual account identity can't authenticate to across the domain. Trades auditability (every connecting user shares the same underlying GMSA identity in downstream logs, correlated back to the individual only via the JEA session transcript) for network reach. Domain-joined machines only, PowerShell 5.1+.

Virtual accounts are also transiently granted the "Logon as a service" right for the session's duration — Microsoft explicitly notes an exception for environments (domain controllers, notably) where security policy revisions are tightly audited: if a `RunAsVirtualAccountGroups` group already holds that right, individual virtual accounts stop being added/removed from the policy on every session, avoiding a stream of policy-change audit events.

### Role Capability Search and Deployment

For PowerShell versions before 6, and still the most common pattern, a role capability file must live in a `RoleCapabilities` subfolder inside a proper PowerShell module (a folder on `$Env:PSModulePath` containing at least one file matching the module folder's own name — typically a `.psd1` manifest). Starting in PowerShell 6, a session configuration file's `RoleDefinitions` can instead reference a role capability file by direct path via the newer `RoleDefinitions` property shape, bypassing the module-folder requirement — but the module-based pattern remains dominant in mixed PowerShell 5.1/7 fleets since it's the only form guaranteed to work on 5.1 endpoints.

**Search order across modules is explicitly documented as non-deterministic** when more than one module on `$Env:PSModulePath` contains a `RoleCapabilities` folder with a same-named `.psrc` file — Windows enumerates directory contents in an order that isn't guaranteed alphabetical, and JEA uses the first match found. The one documented exception is that role capabilities shipped with Windows itself take precedence over same-named custom ones. Microsoft's own guidance, given this non-determinism, is blunt: use globally unique role capability filenames, full stop.

### Merge Rules When a User Matches Multiple Roles

A connecting user is granted the union of every role capability their group memberships map to in `RoleDefinitions` — JEA does not pick one role, it merges all matching roles and, critically, **always resolves toward the most permissive combined result**:

1. A cmdlet visible in only one matching role is visible with that role's own constraints.
2. The same cmdlet with identical constraints across multiple matching roles stays constrained identically.
3. The same cmdlet with a **different parameter set** allowed across roles → the union of every parameter from every role becomes available; if even one role leaves a parameter unconstrained, it's unconstrained for the merged result.
4. A `ValidateSet`/`ValidatePattern` on one role's version of a parameter is **ignored entirely** if another matching role allows that same parameter with no value constraint at all.
5. Multiple `ValidateSet`s on the same parameter across roles → union of all listed values.
6. Multiple `ValidatePattern`s on the same parameter across roles → any value matching ANY of the patterns is allowed.
7. A `ValidateSet` and a `ValidatePattern` both present across roles for the same parameter → the `ValidateSet` is dropped, rule 6 governs the remaining patterns.

`VisibleExternalCommands`, `VisibleAliases`, `VisibleProviders`, and `ScriptsToProcess` have simpler, purely additive merge behavior — anything visible in ANY matching role is visible to the user, no constraint-narrowing logic applies at all. Microsoft's own security-considerations documentation flags the specific risk of one role granting a provider (e.g., the `FileSystem` provider) while a completely different, unrelated role grants a destructive cmdlet like `Remove-Item` — the merge makes the *combination* available to any user who happens to match both roles, even though neither role's author intended that pairing.

### Custom Functions Run Outside JEA's Constraints — By Design

A `FunctionDefinitions` entry's script block body executes in the **system's default language mode**, not the NoLanguage-mode constraints applied to the outer JEA session. This means a custom function can access the file system, registry, or run any command the RunAs identity is capable of — regardless of what's listed in `VisibleProviders` or `VisibleCmdlets` for that session. The security boundary is entirely in the decision to expose the function via `VisibleFunctions`, not in any runtime restriction on what the function's own code can do once exposed. This is also why constrained cmdlets referenced from inside a custom function still carry their JEA-session constraints when called by their short name (e.g., `Select-Object` inside a function respects the session's restricted proxy version) — accessing the genuinely unconstrained implementation requires the fully-qualified module name (e.g., `Microsoft.PowerShell.Utility\Select-Object`), a deliberate escape hatch role authors must invoke explicitly rather than get by accident.

### Registration and the WinRM Restart

`Register-PSSessionConfiguration` and `Unregister-PSSessionConfiguration` both restart the WinRM service as an unavoidable part of the operation — every active remoting session, DSC run, and management tool connection on the machine is dropped, with no documented quieter alternative for single-machine registration. This is a hard operational constraint: any JEA endpoint change is a maintenance-window activity, never an ad hoc same-ticket fix on a production system.

### Multi-Machine Deployment via the JEA DSC Resource

For anything beyond a handful of machines, Microsoft's documented pattern is the **JustEnoughAdministration** DSC resource rather than manually running `Register-PSSessionConfiguration` per machine. The DSC resource accepts the same core properties (RoleDefinitions, virtual account groups, GMSA name, TranscriptDirectory, user drive, RequiredGroups, startup scripts) in a configuration block, with role capability modules distributed via a `File` DSC resource pointing at a shared, read-only file share. A documented side effect worth knowing: the DSC resource can optionally **replace** the default `Microsoft.PowerShell` endpoint entirely — when it does, it automatically registers a backup endpoint named `Microsoft.PowerShell.Restricted` carrying the same default WinRM ACL (Remote Management Users + local Administrators) as an escape hatch, so replacing the default endpoint doesn't strand administrators without any working remoting path.

</details>

---

## Dependency Stack

```
PowerShell 5.0+ (built-in JEA support, no separate feature install)
        │
Role capability file(s) (.psrc) authored — VisibleCmdlets/Functions/Providers/ExternalCommands
   per role, with optional per-parameter/value scoping
        │
Role capability file(s) placed in a RoleCapabilities subfolder of a proper PowerShell module
   on $Env:PSModulePath — module folder name must match a root file inside it (.psd1/.psm1)
        │
   ⚠ Search order across MULTIPLE same-named .psrc files in different modules is NOT
     deterministic — Microsoft's own guidance is to keep filenames globally unique
        │
Session configuration file (.pssc) authored — RunAsVirtualAccount/GMSA identity,
   RoleDefinitions (user/group → role capability name mapping), RequiredGroups,
   TranscriptDirectory, MountUserDrive
        │
Test-PSSessionConfigurationFile validates .pssc syntax before registration
        │
Register-PSSessionConfiguration — endpoint becomes connectable
   ⚠ RESTARTS WinRM — drops every active remoting session on the machine, no quiet alternative
        │
Connecting user/group is an EXACT match in RoleDefinitions
   (COMPUTERNAME\LocalGroup for local groups — never "localhost" or a wildcard)
        │
[If RequiredGroups configured] user ALSO satisfies the conditional access rule independently
   of role mapping (e.g., JIT-elevation group membership, MFA/smartcard-logon group)
        │
Session opens: NoLanguage mode, RunAs identity assumed, MERGED (most-permissive-wins across
   every matching role) VisibleCmdlets/Functions/Providers/ExternalCommands become available
        │
[Custom FunctionDefinitions] function BODY runs in default language mode — NOT constrained by
   JEA's own restrictions, regardless of what VisibleProviders/Cmdlets otherwise limit
        │
[If TranscriptDirectory set] Local System writes the full session transcript for audit
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Endpoint doesn't appear in `Get-PSSessionConfiguration` at all | Never registered, or registered under a different name than expected | `Register-PSSessionConfiguration`; confirm exact `-Name` used |
| Access denied before a session even opens | User/group not an exact match in `RoleDefinitions`, or fails a `RequiredGroups` rule | `(Get-PSSessionConfiguration -Name <name>).RoleDefinitions` and `.RequiredGroups` |
| A cmdlet the role should grant isn't visible in the session | Not added to `VisibleCmdlets`/`VisibleFunctions` in the resolved `.psrc`, or a naming typo | `Get-Command` from inside a live session, compared against the `.psrc` source |
| A visible cmdlet rejects an expected parameter or value | `Parameters`/`ValidateSet`/`ValidatePattern` scoping in the `.psrc` doesn't include it | Inspect the cmdlet's entry in `VisibleCmdlets` |
| User has MORE access than the role author intended | Merge-across-roles resolves toward the most permissive combined result across every matching role | Enumerate every role the user's groups map to, not just the "intended" one |
| Behavior differs across servers with the "same" endpoint name | A different, same-named `.psrc` resolved due to non-deterministic search order across modules | Enumerate every module with a `RoleCapabilities` folder on each machine |
| A custom function appears to access resources not listed in `VisibleProviders` | Expected — `FunctionDefinitions` bodies run in default language mode, not JEA's constraints | Confirm via `about_Language_Modes`; not a bypass bug |
| All remoting/DSC/management-tool sessions on a machine dropped at a specific moment | `Register-`/`Unregister-PSSessionConfiguration` restarts WinRM as part of the operation | Correlate the drop time against any recent JEA registration change |
| A network share/remote resource is unreachable from inside the JEA session | Virtual account identity (local or scoped) has no domain network reach — GMSA is required for that | Confirm which identity model the session configuration uses |
| DC-hosted JEA endpoint grants far more than intended even with a narrow role | Default virtual account on a Domain Controller belongs to Domain Admins, not local Administrators | Confirm `RunAsVirtualAccountGroups` is explicitly scoped, don't rely on the bare default on a DC |
| Tab completion doesn't work in the JEA session | `TabExpansion2` wasn't added to `VisibleFunctions` | Add `'TabExpansion2'` to the role's `VisibleFunctions` list |

---

## Validation Steps

**1. Confirm the endpoint is registered and note its exact name:**
```powershell
Get-PSSessionConfiguration | Select-Object Name, Permission
```

**2. Confirm role capability file syntax before trusting its contents:**
```powershell
Test-PSSessionConfigurationFile -Path <pathToPsscFile>
```
Expected: `True`. A malformed `.pssc`/`.psrc` fails registration outright rather than registering a partially-broken endpoint.

**3. Confirm RoleDefinitions maps the intended user/group with the intended role capability name:**
```powershell
(Get-PSSessionConfiguration -Name <endpointName>).RoleDefinitions
```
Expected: exact group name (COMPUTERNAME\LocalGroup for local groups) mapped to the correct role capability name(s).

**4. Confirm RequiredGroups (if used) reflects the intended conditional access model:**
```powershell
(Get-PSSessionConfiguration -Name <endpointName>).RequiredGroups
```

**5. Connect as a representative user and confirm the ACTUAL effective command set:**
```powershell
Enter-PSSession -ComputerName <server> -ConfigurationName <endpointName>
Get-Command
$ExecutionContext.SessionState.LanguageMode  # expected: NoLanguage / ConstrainedLanguage per session type
```

**6. Confirm the RunAs identity actually in effect:**
```powershell
# Inside the JEA session
whoami /all
Get-Process -Id $PID | Select-Object -ExpandProperty StartInfo  # virtual account name is per-session, unique
```

**7. Confirm transcription is capturing sessions, if configured:**
```powershell
Get-ChildItem -Path (Get-PSSessionConfiguration -Name <endpointName>).TranscriptDirectory | Sort-Object LastWriteTime -Descending | Select-Object -First 5
```

---

## Troubleshooting Steps (by phase)

### Phase 1: Endpoint Existence and Registration

1. Confirm the endpoint name registered matches exactly what clients are targeting via `-ConfigurationName`.
2. Confirm `Test-PSSessionConfigurationFile` passed before the endpoint was registered — a syntax error in either file produces a registration failure, not a silently broken endpoint, so this is rarely the live-ticket cause but worth confirming during initial setup review.

### Phase 2: Access and Role Mapping

1. Confirm the connecting user's group membership resolves to an exact `RoleDefinitions` key (including nested AD group expansion if applicable).
2. If `RequiredGroups` is configured, confirm the user independently satisfies it — this is a separate gate from role mapping, not a substitute for it.
3. Confirm the WinRM-level endpoint permission itself doesn't separately deny the connecting identity, independent of the JEA-layer `RoleDefinitions`.

### Phase 3: Command Visibility and Scoping

1. Connect as the affected user (or an equivalent test account) and enumerate `Get-Command` from inside the live session — never troubleshoot this by reading the `.psrc` file alone.
2. If a cmdlet or parameter is missing, locate the SPECIFIC `.psrc` file that actually resolved for that role on that machine (see Phase 4 if search order is in question).
3. Confirm which roles the user's memberships map to in total — an over-permissioning symptom usually traces to a role capability the investigator wasn't initially looking at.

### Phase 4: Search Order / Cross-Server Consistency

1. If behavior differs across servers sharing an endpoint name, enumerate every module on each machine's `$Env:PSModulePath` containing a `RoleCapabilities` folder with a matching filename.
2. Confirm whether Windows-shipped role capabilities are unexpectedly taking precedence over a custom one with the same name.
3. Rename any colliding custom role capability files to guarantee uniqueness rather than relying on search-order behavior.

### Phase 5: Identity and Network Reach

1. Confirm which RunAs identity model is in use (local virtual account, scoped virtual account, or GMSA) and whether it matches the role's actual resource-access needs.
2. If network resource access is failing specifically inside the JEA session but works for the same user via a normal admin session, confirm the identity model — a virtual account (local or scoped) has no domain network reach by design; only GMSA does.
3. On a Domain Controller specifically, confirm `RunAsVirtualAccountGroups` is explicitly set rather than relying on the bare virtual-account default, which is Domain Admins on a DC (a materially different default than the local Administrators default on a member server).

---

## Remediation Playbooks

<details><summary>Playbook 1 — Author and register a new JEA endpoint from scratch (single machine)</summary>

```powershell
# 1. Create the role capability file and edit it to define VisibleCmdlets/Functions
New-PSRoleCapabilityFile -Path .\ContosoDnsOperator.psrc
# ... edit the file: VisibleCmdlets = @('Get-DnsServerZone', 'Restart-Service' with Name=Dns scoping, etc.)

# 2. Package it inside a proper PowerShell module
$modulePath = Join-Path $Env:ProgramFiles "WindowsPowerShell\Modules\ContosoJEA"
New-Item -ItemType Directory -Path $modulePath -Force
New-Item -ItemType File -Path (Join-Path $modulePath "ContosoJEA.psm1")
New-ModuleManifest -Path (Join-Path $modulePath "ContosoJEA.psd1") -RootModule "ContosoJEA.psm1"
$rcFolder = Join-Path $modulePath "RoleCapabilities"
New-Item -ItemType Directory -Path $rcFolder -Force
Copy-Item -Path .\ContosoDnsOperator.psrc -Destination $rcFolder

# 3. Create the session configuration file — scoped virtual account, NOT bare admin default
$roles = @{ 'CONTOSO\JEA-DNS-Operators' = @{ RoleCapabilities = 'ContosoDnsOperator' } }
New-PSSessionConfigurationFile -SessionType RestrictedRemoteServer -Path .\JEADnsConfig.pssc `
    -RunAsVirtualAccount -RunAsVirtualAccountGroups 'DnsAdmins' `
    -TranscriptDirectory 'C:\ProgramData\JEAConfiguration\Transcripts' `
    -RoleDefinitions $roles

# 4. Validate BEFORE registering
Test-PSSessionConfigurationFile -Path .\JEADnsConfig.pssc

# 5. Register (schedule for a maintenance window — this restarts WinRM)
Register-PSSessionConfiguration -Path .\JEADnsConfig.pssc -Name 'JEA-DnsOps' -Force
```

**Rollback:** `Unregister-PSSessionConfiguration -Name 'JEA-DnsOps' -Force` (also restarts WinRM); delete the module folder to remove the role capability entirely.

</details>

<details><summary>Playbook 2 — Deploy JEA to multiple machines via DSC</summary>

```powershell
# Prerequisite: role capability module staged on a read-only file share, JEA DSC resource downloaded

Configuration JEADnsOperators
{
    Import-DscResource -Module JustEnoughAdministration, PSDesiredStateConfiguration

    File RoleCapabilityModule
    {
        SourcePath      = "\\fileshare\JEA\ContosoJEA"
        DestinationPath = "C:\Program Files\WindowsPowerShell\Modules\ContosoJEA"
        Checksum        = "SHA-256"
        Ensure          = "Present"
        Type            = "Directory"
        Recurse         = $true
    }

    JeaEndpoint JEADnsEndpoint
    {
        EndpointName         = "JEA-DnsOps"
        RoleDefinitions      = "@{ 'CONTOSO\JEA-DNS-Operators' = @{ RoleCapabilities = 'ContosoDnsOperator' } }"
        TranscriptDirectory  = 'C:\ProgramData\JEAConfiguration\Transcripts'
        DependsOn            = '[File]RoleCapabilityModule'
    }
}

JEADnsOperators -OutputPath .\JEAConfig
Start-DscConfiguration -Path .\JEAConfig -Wait -Verbose
```

**Rollback:** Remove the `JeaEndpoint` resource from the configuration and re-apply, or `Unregister-PSSessionConfiguration` directly on affected machines for an immediate reversal outside the DSC pull cycle.

</details>

<details><summary>Playbook 3 — Audit an existing endpoint's actual effective access</summary>

```powershell
# Enumerate every role definition and the modules/files they resolve to
$config = Get-PSSessionConfiguration -Name <endpointName>
$config.RoleDefinitions

foreach ($roleName in ($config.RoleDefinitions.Values.RoleCapabilities | Select-Object -Unique)) {
    Write-Host "=== Role: $roleName ===" -ForegroundColor Cyan
    Get-Module -ListAvailable | ForEach-Object {
        $rcFile = Join-Path $_.ModuleBase "RoleCapabilities\$roleName.psrc"
        if (Test-Path $rcFile) {
            Write-Host "Resolved from: $rcFile"
            Get-Content $rcFile
        }
    }
}

# Connect as a representative test account to confirm real effective access
Enter-PSSession -ComputerName $Env:COMPUTERNAME -ConfigurationName <endpointName>
Get-Command | Select-Object Name, CommandType
```

**Rollback:** N/A — read-only audit.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect JEA endpoint evidence for escalation
.NOTES     Run as a user with local admin rights on the target machine
#>

$OutputDir = "C:\Temp\JEA-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# 1. All registered session configurations
Get-PSSessionConfiguration | Select-Object Name, Permission, Enabled |
    Export-Csv "$OutputDir\SessionConfigurations.csv" -NoTypeInformation

# 2. Detailed config for the endpoint in question
$config = Get-PSSessionConfiguration -Name $endpointName
$config | Select-Object Name, RunAsUser | ConvertTo-Json -Depth 6 | Out-File "$OutputDir\EndpointDetail.json"
$config.RoleDefinitions | ConvertTo-Json -Depth 6 | Out-File "$OutputDir\RoleDefinitions.json"

# 3. Resolved role capability file contents
foreach ($roleName in ($config.RoleDefinitions.Values.RoleCapabilities | Select-Object -Unique)) {
    Get-Module -ListAvailable | ForEach-Object {
        $rcFile = Join-Path $_.ModuleBase "RoleCapabilities\$roleName.psrc"
        if (Test-Path $rcFile) {
            Copy-Item -Path $rcFile -Destination "$OutputDir\$roleName.psrc.txt"
        }
    }
}

# 4. Recent session transcripts (if TranscriptDirectory is configured)
if ($config.TranscriptDirectory -and (Test-Path $config.TranscriptDirectory)) {
    Get-ChildItem -Path $config.TranscriptDirectory | Sort-Object LastWriteTime -Descending | Select-Object -First 20 |
        Export-Csv "$OutputDir\RecentTranscripts.csv" -NoTypeInformation
}

# 5. WinRM listener/service state (JEA's underlying transport)
winrm enumerate winrm/config/listener | Out-File "$OutputDir\WinRM-Listeners.txt"
Get-Service WinRM | Select-Object Status, StartType | Out-File "$OutputDir\WinRM-ServiceState.txt"

Write-Host "Evidence collected: $OutputDir" -ForegroundColor Green
Compress-Archive -Path "$OutputDir\*" -DestinationPath "$OutputDir.zip"
Write-Host "Archive: $OutputDir.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

```powershell
# All registered session configurations on this machine
Get-PSSessionConfiguration | Select Name, Permission

# Full detail for one endpoint — RunAs identity, RoleDefinitions, RequiredGroups, TranscriptDirectory
Get-PSSessionConfiguration -Name <endpointName> | Format-List *

# Validate a .pssc/.psrc BEFORE registering — catches syntax errors early
Test-PSSessionConfigurationFile -Path <pathToPsscFile>

# Register an endpoint (RESTARTS WinRM — maintenance window only)
Register-PSSessionConfiguration -Path <pathToPsscFile> -Name <endpointName> -Force

# Remove an endpoint (also RESTARTS WinRM)
Unregister-PSSessionConfiguration -Name <endpointName> -Force

# Connect and test as a representative user
Enter-PSSession -ComputerName <server> -ConfigurationName <endpointName>

# Inside a live session — the REAL effective command set (never trust the .psrc file alone)
Get-Command

# Inside a live session — confirm language mode and identity
$ExecutionContext.SessionState.LanguageMode
whoami /all

# Locate every module with a RoleCapabilities folder (search-order collision check)
Get-Module -ListAvailable | Where-Object { Test-Path (Join-Path $_.ModuleBase 'RoleCapabilities') }

# Create a new blank role capability template
New-PSRoleCapabilityFile -Path .\NewRole.psrc

# Create a new blank session configuration template (locked-down JEA starting point)
New-PSSessionConfigurationFile -SessionType RestrictedRemoteServer -Path .\NewConfig.pssc
```

---

## 🎓 Learning Pointers

- **JEA is a built-in PowerShell 5.0+ capability, not a separate feature to install** — the barrier to adopting it is authoring discipline (deciding exactly which commands a role needs), not deployment complexity. The `RestrictedRemoteServer` session type's locked-down, eight-command, zero-provider, zero-external-program starting point is the entire security model in miniature: deny by default, grant explicitly. [MS Docs: Just Enough Administration overview](https://learn.microsoft.com/en-us/powershell/scripting/security/remoting/jea/overview)

- **Role merging always resolves toward the MOST permissive combined result across every role a user's groups map to — there is no "most restrictive wins" option.** A single overly-broad role anywhere in an environment's JEA configuration widens access for every user who happens to belong to a group mapped to it, even if their "intended" role is narrow. Auditing a JEA endpoint means enumerating every role a user's memberships resolve to, not just the one that seems relevant to the ticket. [MS Docs: How role capabilities are merged](https://learn.microsoft.com/en-us/powershell/scripting/security/remoting/jea/role-capabilities#how-role-capabilities-are-merged)

- **A custom function's own script block body runs OUTSIDE JEA's language and provider constraints, by design** — the security boundary is entirely the decision to list it in `VisibleFunctions`, not any runtime sandboxing of what the function's code can subsequently do. Review custom function bodies in role capability files with the same scrutiny you'd apply to handing out the RunAs identity's full native capability, because that's effectively what exposing the function does.

- **`Register-PSSessionConfiguration`/`Unregister-PSSessionConfiguration` restart WinRM as an unavoidable side effect** — every active remoting session, DSC run, and remote management tool connection on the machine drops at that moment, with no quieter single-machine alternative documented. Treat any JEA endpoint change with the same maintenance-window discipline this repo already applies to other WinRM-restarting operations (see `WinRM-A.md`'s own service-restart caveats).

- **The default virtual-account identity is materially different on a Domain Controller than on a member server** — local Administrators on a member server, but **Domain Admins** on a DC. A JEA endpoint built on a DC using the bare `RunAsVirtualAccount = $true` default without also setting `RunAsVirtualAccountGroups` grants far more than most DC-hosted roles (DNS management, notably — the textbook JEA use case) actually require. Explicitly scope virtual account groups on any DC-hosted endpoint.

- **JEA and WinRM are distinct, layered technologies, and troubleshooting them requires knowing which layer owns a given symptom.** WinRM governs whether remoting can happen at all — listener configuration, ports, TrustedHosts, authentication mechanism — fully covered in `WinRM-A.md`/`WinRM-B.md`. JEA governs what a successfully-connected, specific user can do once inside a custom endpoint layered on top of a working WinRM transport. "Can't connect at all" is a WinRM ticket; "connected, but access doesn't match expectations" is a JEA ticket — don't debug role capability files when the actual fault is in the transport layer underneath them.
