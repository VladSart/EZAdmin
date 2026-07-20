# Delegated Managed Service Accounts (dMSA) — Reference Runbook (Mode A: Deep Dive)
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

**In scope:**
- Delegated Managed Service Accounts (dMSA) — Windows Server 2025's successor service-account model, both standalone use and migration-from-legacy-account use
- Schema/platform prerequisites, the two-phase migration mechanism (`Start-`/`Complete-ADServiceAccountMigration`), and the client-side `DelegatedMSAEnabled` gate
- The BadSuccessor privilege-escalation technique (CVE-2025-53779) as a security consideration directly tied to dMSA's own linking mechanism
- Common consumers: Windows services, scheduled tasks, IIS application pools — the same consumer surface as gMSA

**Out of scope:**
- Group Managed Service Accounts (gMSA) — the long-stable Windows Server 2012+ predecessor model; see `ActiveDirectory/Troubleshooting/gMSA/gMSA-A.md`. dMSA cannot be converted to/from gMSA.
- Standalone Managed Service Accounts (sMSA) — the single-host-only Windows Server 2008 R2 predecessor, superseded by gMSA long before dMSA existed
- Full incident-response procedure for confirmed BadSuccessor exploitation — this runbook covers detection/triage signals only; follow `Security/` domain incident-response guidance for the actual response
- Third-party credential vaulting/PAM as an alternative to dMSA/gMSA

**Assumptions:**
- You have Domain Admin or delegated rights sufficient to manage AD service account objects and KDS root keys
- At least one Windows Server 2025 domain controller exists in the domain (see Dependency Stack — this is a hard, non-negotiable platform gate)
- The `ActiveDirectory` PowerShell module (RSAT for Windows Server 2025 / Windows 11 24H2+) is available on at least one management host
- This is a genuinely new (2024/2025-era) feature under active security research — verify current Microsoft Learn guidance before treating any specific behavior as permanently settled

---
## How It Works

<details><summary>Full architecture — schema, migration linking, and the two-gate authorization model</summary>

### The Problem dMSA Solves

gMSA (Server 2012+) already solved auto-rotating, non-transmitted passwords for multi-host services — see `gMSA-A.md` for that architecture, which dMSA builds directly on top of (dMSA still depends on the KDS root key and Group Key Distribution Service for password derivation). What gMSA never solved is **migration**: converting a legacy, human-managed service account (with its accumulated SPNs, delegation configuration, and group memberships) into a managed account is a fully manual, error-prone, all-at-once cutover. dMSA adds a **first-class, AD-tracked migration state machine** on top of the gMSA password model, so a legacy account can be linked to a dMSA, observed in production for a controlled window, and then formally superseded — with AD itself tracking which state the pairing is in via `msDS-DelegatedMSAState`.

### Schema Extension, Not Functional Level

dMSA support is delivered via Windows Server 2025 AD schema extension (new schema log files add the `msDS-DelegatedManagedServiceAccount` object class and its supporting attributes, including `msDS-DelegatedMSAState`, `msDS-ManagedAccountPrecededByLink`, and `msDS-SupersededManagedServiceAccountLink`). Critically, **this is a schema-level requirement, not a forest/domain functional-level requirement** — an admin runs `adprep /forestprep` from Windows Server 2025 media (or promotes a 2025 DC, which does this automatically) to get the schema classes, without needing to raise the forest or domain functional level to Windows Server 2025's new level 10. Engineers who assume "we're not ready to raise functional levels yet" therefore sometimes incorrectly rule out dMSA as unavailable when it may already be schema-ready. The hard, non-negotiable requirement is simply: **at least one Windows Server 2025 domain controller, reachable by the client/server that will use the dMSA.**

### Two Ways to Use a dMSA

1. **Standalone** — create a brand-new dMSA with no legacy predecessor (`msDS-DelegatedMSAState = 3`). This is architecturally closest to just creating a gMSA, using the same `PrincipalsAllowedToRetrieveManagedPassword` delegation model and KDS-derived password mechanics.
2. **Migration from a legacy account** — link a dMSA to an existing standard user/service account so the dMSA can "learn" that account's usage pattern before formally taking over its identity (SPNs, delegation, group memberships).

### The Migration State Machine

Migration is a deliberate, two-step, AD-tracked process — not a single cutover:

- **`Start-ADServiceAccountMigration -Identity <dMSA> -SupersededAccount <LegacyAccountDN>`** links the dMSA to the legacy account (`msDS-DelegatedMSAState` moves to `1`). From this point, AD begins observing which computer accounts actually authenticate as the legacy account and **automatically adds them** to the dMSA's `PrincipalsAllowedToRetrieveManagedPassword` — this auto-discovery of consumers is a genuinely useful side effect for legacy accounts whose full consumer list was never accurately documented, but it also means the authorized-host list can grow silently during this window and should be reviewed before completing.
- **A deliberate observation window is expected, not skipped.** Microsoft's own guidance recommends waiting at least two Kerberos ticket lifetimes (roughly 14 days, using the default 10-hour ticket lifetime as the baseline unit) after any security-descriptor change before completing migration, and recommends keeping an account in the "start" (in-progress) state for around four ticket lifetimes (~28 days) in normal migration planning — this gives Kerberos ticket caches domain-wide time to expire and rules out stale cached tickets masking an incomplete cutover.
- **`Complete-ADServiceAccountMigration -Identity <dMSA> -SupersededAccount <LegacyAccountDN>`** finalizes the cutover: the dMSA inherits the legacy account's SPNs and delegation configuration, `msDS-DelegatedMSAState` moves to `2`, and the legacy account is disabled (not deleted — see Learning Pointers).
- **`Undo-ADServiceAccountMigration`** and **`Reset-ADServiceAccountMigration`** are both explicitly supported, documented rollback paths — `Undo` reverses an active or completed migration back to the legacy account being live; `Reset` clears the dMSA back to an unlinked state to start the pairing over. Neither is a workaround or an unsupported hack.

### The Two-Gate Authorization Model (an extra gate beyond gMSA)

Like gMSA, dMSA requires AD-side delegation (`PrincipalsAllowedToRetrieveManagedPassword`) before a host can retrieve the password. Unlike gMSA, dMSA **also** requires an explicit client-side Kerberos policy gate: the `DelegatedMSAEnabled` registry value (or, preferably, the **Computer Configuration\Administrative Templates\System\Kerberos\Enable Delegated Managed Service Account logons** Group Policy setting) must be set to `1` on the consuming host before the Kerberos client will honor dMSA logons at all. This value is **disabled by default everywhere**, specifically because Microsoft designed dMSA to fail closed on any host/DC that hasn't been deliberately upgraded and opted in — a host can be fully authorized in AD and still be unable to log on with the dMSA purely because this local policy switch was never flipped. This client-side requirement extends to Windows 11, version 24H2 and later as a supported dMSA-capable client OS, not just Windows Server 2025 — a detail worth confirming explicitly on both ends (DC and client) rather than assuming server-side readiness alone is sufficient.

### Migration Moves AD State, Never Touches the Consuming Service

`Complete-ADServiceAccountMigration` updates SPNs, delegation, and AD authorization — it does **not** reconfigure the Windows service, scheduled task, or app pool that actually authenticates. That remains a manual step on every consuming host, identical to the equivalent gMSA gap, and is the single most common "the migration says complete but the service is still broken" root cause.

### BadSuccessor (CVE-2025-53779) — Why This Feature's Own Mechanism Was a Security Finding

The same linking primitive that makes migration convenient — a dMSA can claim to "supersede" an arbitrary target account via `msDS-ManagedAccountPrecededByLink` — was the basis of a disclosed privilege-escalation technique publicly named "BadSuccessor." Before Microsoft's August 2025 cumulative update, a principal with `CreateChild` rights on **any OU** (a far more common and often overlooked delegation than most admins realize, frequently granted for mundane reasons like allowing helpdesk staff to create computer objects) could create a dMSA and set its predecessor link to point at an arbitrary account — including a Domain Admin — without ever needing write access to the target account itself, and Kerberos would honor the resulting ticket as if a genuine migration had occurred. The August 2025 patch closes the one-sided exploitation path by requiring genuine mutual linkage validated on both sides. Post-patch, the underlying primitive (pairing a dMSA you control with an account you already have some legitimate write access to) remains a documented technique worth continued monitoring — this is why Fix 6 in the companion hotfix runbook treats "account just created and immediately has elevated rights" as a security-triage signal, not a routine ticket.

</details>

---
## Dependency Stack

```
Forest schema extended to Windows Server 2025 level (adprep /forestprep from 2025 media —
does NOT require raising forest/domain functional level)
  └── At least one Windows Server 2025 DC exists AND is discoverable by the requesting client/server
        └── KDS Root Key created (Add-KdsRootKey) AND past its EffectiveTime — same shared
            prerequisite as gMSA (default 10-hour convergence delay)
              └── dMSA object created:
                  New-ADServiceAccount -CreateDelegatedServiceAccount -KerberosEncryptionType AES256
                    └── PrincipalsAllowedToRetrieveManagedPassword grants the target machine identity
                          (standalone path — jump straight to client policy below)
                          (migration path — continue down)
                                └── Start-ADServiceAccountMigration links dMSA ↔ legacy account
                                    (msDS-DelegatedMSAState = 1; AD auto-discovers consuming hosts)
                                      └── Observation window elapses (~14 days min after any ACL
                                          change; ~28 days typical "start" state duration recommended)
                                            └── Complete-ADServiceAccountMigration — dMSA inherits
                                                SPNs/delegation; legacy account disabled
                                                (msDS-DelegatedMSAState = 2)
  └── Client/server OS supports dMSA (Windows Server 2025 or Windows 11 24H2+)
        AND has DelegatedMSAEnabled registry/GPO policy set to 1 — DISABLED BY DEFAULT EVERYWHERE
              └── Service/task/app pool manually reconfigured to log on as the dMSA
                  (never happens automatically, identical gap to gMSA migration)
```

Key failure points:
- No Windows Server 2025 DC anywhere in the domain — dMSA is architecturally unavailable, not merely misconfigured (schema extension alone via adprep is not sufficient without an actual 2025 DC to serve requests)
- KDS root key convergence delay (default 10 hours) — identical trap to gMSA
- `DelegatedMSAEnabled` defaults to off on every host and DC — this is a deliberate fail-closed design choice, not an oversight, and is the single most common first-deployment miss
- Migration moves AD object state only; the consuming service/task/app pool logon configuration is always a separate manual step
- Mixed-OS environments: every client/server actually consuming the dMSA must independently support it (Windows Server 2025, or Windows 11 24H2+ for client-side use) — a supported-but-unpatched client OS with the policy unset will simply fail to authenticate

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| `New-ADServiceAccount -CreateDelegatedServiceAccount` fails outright | No Windows Server 2025 DC/schema present, or command run against a down-level DC | `Get-ADDomainController -Filter *` for an `OperatingSystem` containing "2025" |
| dMSA object exists, `Test-ADServiceAccount` (or actual logon) fails on every host | KDS root key hasn't converged, OR `DelegatedMSAEnabled` was never set anywhere | `Get-KdsRootKey`; `Get-ItemProperty ...DelegatedMSAEnabled` on the affected host |
| Works on one host, fails on a supposedly identical peer | Peer host is a down-level client OS (pre-24H2) or its own `DelegatedMSAEnabled` policy was never applied | Confirm build number and registry/GPO state independently per host |
| `msDS-DelegatedMSAState` stuck at `1` far longer than planned | Team is (correctly) honoring the observation window, or forgot to run `Complete-ADServiceAccountMigration` | Confirm elapsed time since `Start-` vs. the ~14/28-day guidance; confirm intent |
| Migration shows `msDS-DelegatedMSAState = 2` but the service still authenticates as the legacy (now-disabled) account and fails | Service/task/app pool logon was never manually repointed at the dMSA — migration doesn't touch it | `Get-CimInstance Win32_Service` → `StartName` on the affected host |
| `PrincipalsAllowedToRetrieveManagedPassword` list grew with hosts nobody remembers adding | Expected side effect of `Start-ADServiceAccountMigration`'s auto-discovery of legacy-account consumers — review before completing, don't treat as tampering | Cross-reference the list against known/expected consuming hosts before `Complete-` |
| Attempting to log on with a gMSA-to-dMSA "conversion" | Not supported — Microsoft's own FAQ explicitly states there is no gMSA→dMSA migration path | Re-scope the request as a fresh dMSA rollout, not a conversion |
| An account was "just created" and immediately holds unexplained elevated/Domain Admin-equivalent rights | Possible BadSuccessor-style dMSA privilege-escalation abuse (CVE-2025-53779) | **Stop routine troubleshooting — engage security/incident response; see Fix 6 in the hotfix runbook** |
| Legacy account was deleted (not just disabled) shortly after migration, and something now breaks unexpectedly | Microsoft explicitly warns against deleting a superseded account — the dMSA retains forward/backward links to it | Confirm whether the deleted account's SID appeared in any ACL, delegation, or group membership still expected to resolve |
| Migration behaves inconsistently across a multi-domain forest | Every domain the consuming hosts live in needs its own Windows Server 2025 DC reachability and its own `DelegatedMSAEnabled` rollout — no forest-wide auto-propagation of readiness | Confirm DC OS version and policy state per domain, not just forest-wide |

---
## Validation Steps

**Step 1 — Confirm the platform prerequisite (Windows Server 2025 DC)**
```powershell
Get-ADDomainController -Filter * | Select-Object HostName, OperatingSystem, Site
```
Expected: at least one DC with `OperatingSystem` containing "2025". This is a hard gate — nothing below matters until this passes.

**Step 2 — Confirm KDS root key convergence (shared prerequisite with gMSA)**
```powershell
Get-KdsRootKey | Select-Object KeyId, EffectiveTime, CreationTime
```
Expected: at least one key with `EffectiveTime` in the past.

**Step 3 — Confirm the dMSA object's full migration state**
```powershell
Get-ADServiceAccount -Identity "<dMSAName>" -Properties * |
  Select-Object Name, Enabled, DNSHostName, msDS-DelegatedMSAState, msDS-ManagedAccountPrecededByLink,
    PrincipalsAllowedToRetrieveManagedPassword, KerberosEncryptionType
```
Cross-reference `msDS-DelegatedMSAState` against the Symptom → Cause Map above.

**Step 4 — If mid-migration, confirm the legacy account side**
```powershell
Get-ADServiceAccount -Identity "<LegacyServiceAccountName>" -Properties Enabled, msDS-SupersededManagedServiceAccountLink, msDS-SupersededServiceAccountState |
  Select-Object Name, Enabled, msDS-SupersededManagedServiceAccountLink, msDS-SupersededServiceAccountState
```
Expected during an in-progress migration: `Enabled = True`, linked back to the dMSA. After `Complete-ADServiceAccountMigration`: `Enabled = False`.

**Step 5 — On the affected host: confirm the client-side policy gate**
```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Kerberos\Parameters" -Name DelegatedMSAEnabled -ErrorAction SilentlyContinue
```
Expected: `DelegatedMSAEnabled = 1`. Also confirm build number is Windows Server 2025 or Windows 11 24H2+ — an unsupported OS will never honor this policy regardless of value.

**Step 6 — On the affected host: confirm the consuming service is actually pointed at the dMSA**
```powershell
Get-CimInstance Win32_Service -Filter "Name='<ServiceName>'" | Select-Object Name, StartName
```
Expected: `StartName` shows `DOMAIN\dMSAName$`.

**Step 7 — Review dMSA-specific Kerberos operational events for the exact failure/migration signal**
```powershell
wevtutil sl Microsoft-Windows-Security-Kerberos/Operational /e:true
Get-WinEvent -LogName "Microsoft-Windows-Security-Kerberos/Operational" -MaxEvents 50 |
  Where-Object { $_.Id -in 307, 308, 309 } | Select-Object TimeCreated, Id, Message
```
307 = migration state change, 308 = a machine added itself to `PrincipalsAllowedToRetrieveManagedPassword` during migration auto-discovery, 309 = a Kerberos client fetched dMSA keys from the DC.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Platform / Schema Layer
1. Confirm at least one Windows Server 2025 DC exists and is reachable by the specific client/server in question — reachability is per-site, not merely "exists somewhere in the forest"
2. If schema readiness is unclear, remember schema extension (`adprep /forestprep`) is independent of forest/domain functional level — don't assume "we haven't raised functional levels" means dMSA is unavailable; verify the schema and DC OS directly instead
3. For multi-domain forests, confirm readiness **per domain** the consuming hosts actually live in

### Phase 2 — KDS Root Key Layer (shared with gMSA)
1. Confirm at least one KDS root key exists and has passed its `EffectiveTime`
2. If genuinely new to both gMSA and dMSA in this forest, expect and communicate the 10-hour convergence wait

### Phase 3 — AD Delegation Layer
1. Confirm the specific failing host is listed in `PrincipalsAllowedToRetrieveManagedPassword`, directly or via group
2. For migration-in-progress dMSAs, remember the list can have grown via auto-discovery since `Start-ADServiceAccountMigration` ran — review it rather than assuming it only contains what was manually added

### Phase 4 — Client Policy Gate Layer (dMSA-specific, no gMSA equivalent)
1. Confirm `DelegatedMSAEnabled` is set to `1` on the affected host — this defaults to off everywhere and is the most common first-deployment miss for this feature specifically
2. Prefer the GPO setting (**Kerberos\Enable Delegated Managed Service Account logons**) over a manual registry edit for anything beyond a single test host, so it survives re-imaging
3. Confirm the host OS build actually supports dMSA (Windows Server 2025, or Windows 11 24H2+) — the policy setting existing in a GPO doesn't mean the client OS honors it

### Phase 5 — Migration State Layer (migration path only)
1. Confirm which `msDS-DelegatedMSAState` value is currently set and what it implies is authoritative right now
2. If migration seems "stuck" in state `1`, confirm whether the team is deliberately honoring the observation window (~14 days minimum after any security-descriptor change, ~28 days typical) versus having simply forgotten to complete it
3. After `Complete-ADServiceAccountMigration`, confirm the *consuming service* was also manually repointed — the migration state alone completing is not sufficient

### Phase 6 — Security Triage Layer (BadSuccessor)
1. If a ticket describes an account "just created" with implausible/elevated privilege, stop routine diagnosis immediately
2. Check DC patch level against the August 2025 cumulative update baseline
3. Inventory dMSA objects domain-wide and their claimed predecessor links for anything pointing at a privileged account with no legitimate migration history
4. Hand off to security/incident response — do not remediate unilaterally (see Fix 6 in the hotfix runbook and Playbook 4 below)

---
## Remediation Playbooks

<details><summary>Playbook 1 — First-time standalone dMSA rollout (no migration, no existing legacy account)</summary>

**Scenario:** Standing up a brand-new service with dMSA from day one — no legacy account to migrate from.

**Step 1 — Confirm platform prerequisites**
```powershell
Get-ADDomainController -Filter * | Select-Object HostName, OperatingSystem
Get-KdsRootKey | Select-Object KeyId, EffectiveTime
```
If no KDS root key exists: `Add-KdsRootKey` (defaults to `EffectiveTime` = now + 10 hours — plan around the wait).

**Step 2 — Create the standalone dMSA, delegated to a group (not individual hosts)**
```powershell
New-ADGroup -Name "dMSA-<ServiceName>-Hosts" -GroupScope DomainLocal -GroupCategory Security

$params = @{
    Name                           = "<dMSAName>"
    DNSHostName                    = "<dMSAName>.<domain.fqdn>"
    CreateDelegatedServiceAccount  = $true
    KerberosEncryptionType         = "AES256"
}
New-ADServiceAccount @params

Set-ADServiceAccount -Identity "<dMSAName>" -PrincipalsAllowedToRetrieveManagedPassword "dMSA-<ServiceName>-Hosts"

# Explicitly set standalone state
Set-ADServiceAccount -Identity "<dMSAName>" -Replace @{ "msDS-DelegatedMSAState" = 3 }
```

**Step 3 — Enable the client-side policy on every consuming host (GPO preferred over manual registry edit)**
```powershell
# GPO path: Computer Configuration\Administrative Templates\System\Kerberos\
#           Enable Delegated Managed Service Account logons  → Enabled
# One-off/manual fallback:
$params = @{
  Path  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Kerberos\Parameters"
  Name  = "DelegatedMSAEnabled"; Value = 1; Type = "DWORD"
}
Set-ItemProperty @params
```

**Step 4 — Add hosts to the group and configure the consuming service**
```powershell
Add-ADGroupMember -Identity "dMSA-<ServiceName>-Hosts" -Members "<Host1>$","<Host2>$"
sc.exe config "<ServiceName>" obj= "DOMAIN\dMSAName$" password= ""
Restart-Service -Name "<ServiceName>"
```

**Rollback note:** Nothing here is destructive until the service is actually repointed. Removing the dMSA object (`Remove-ADServiceAccount`) is clean and reversible-by-recreation as long as no live service depends on it at the time.

</details>

<details><summary>Playbook 2 — Migrating a legacy service account to dMSA (full state-machine walkthrough)</summary>

**Scenario:** An existing service currently runs under a traditional (or gMSA) account and needs to move to dMSA to gain the migration-tracked, more strongly-encrypted model.

**Step 1 — Create the dMSA (see Playbook 1, Steps 1-2) but do NOT set standalone state — leave state at its initial unlinked value**

**Step 2 — Start the migration, linking the dMSA to the legacy account**
```powershell
Start-ADServiceAccountMigration -Identity "<dMSAName>" -SupersededAccount "<LegacyAccountDN>"
```
`msDS-DelegatedMSAState` moves to `1`. AD begins auto-discovering computer accounts that authenticate as the legacy account and adding them to `PrincipalsAllowedToRetrieveManagedPassword`.

**Step 3 — Observe for the recommended window**
- Wait at least ~14 days (two Kerberos ticket lifetimes) after this step, or after any subsequent security-descriptor change, before completing
- A ~28-day (four ticket lifetime) total observation period in the "start" state is typical guidance for production migrations
- Periodically review the auto-discovered `PrincipalsAllowedToRetrieveManagedPassword` list — this is the moment to catch a host nobody expected still using the legacy account

**Step 4 — Enable the client-side policy gate on every discovered consuming host (Playbook 1, Step 3) — this must happen before those hosts can actually use the dMSA post-cutover**

**Step 5 — Complete the migration**
```powershell
Complete-ADServiceAccountMigration -Identity "<dMSAName>" -SupersededAccount "<LegacyAccountDN>"
```
`msDS-DelegatedMSAState` moves to `2`; SPNs/delegation transfer to the dMSA; the legacy account is disabled (never deleted by this step).

**Step 6 — Manually repoint every consuming service/task/app pool — migration does not do this**
```powershell
sc.exe config "<ServiceName>" obj= "DOMAIN\dMSAName$" password= ""
Restart-Service -Name "<ServiceName>"
```

**Rollback note:** Before `Complete-`, run `Reset-ADServiceAccountMigration -Identity "<dMSAName>" -SupersededAccount "<LegacyAccountDN>"` to unlink and start over. After `Complete-` (or mid-migration if something goes wrong), run `Undo-ADServiceAccountMigration -Identity "<dMSAName>" -SupersededAccount "<LegacyAccountDN>"` to restore the legacy account to active, authoritative use. **Never delete the legacy account**, even long after a successful migration — the dMSA retains forward/backward links to it and Microsoft explicitly warns deletion causes issues.

</details>

<details><summary>Playbook 3 — Standalone dMSA needs to absorb a legacy account discovered later</summary>

**Scenario:** A dMSA was deployed standalone (`msDS-DelegatedMSAState = 3`), but the team later decides it should formally supersede an existing legacy account instead of the two coexisting.

**Note:** dMSA does not support re-linking a standalone dMSA to a legacy account after the fact via a documented in-place conversion. The supported path is to `Reset-ADServiceAccountMigration` (which returns the dMSA to an unlinked state) and then treat it as a fresh migration per Playbook 2 — confirm this against current Microsoft Learn guidance before executing, since this is exactly the kind of lifecycle edge case likely to gain clearer first-party tooling as the feature matures.

**Rollback note:** N/A beyond the standard `Reset-`/`Undo-` cmdlets already covered in Playbook 2.

</details>

<details><summary>Playbook 4 — Suspected BadSuccessor-style dMSA privilege escalation (CVE-2025-53779)</summary>

**Scenario:** A dMSA-linked account shows implausible privilege, or a security review needs to proactively sweep for the technique.

**This is not a break-fix task — engage your security/incident response process before taking remediation action.**

```powershell
# 1. Confirm DC patch level — August 2025 cumulative update or later closes the one-sided exploitation path
Get-HotFix | Where-Object { $_.InstalledOn -gt (Get-Date "2025-08-01") } | Sort-Object InstalledOn

# 2. Inventory every dMSA in the domain and its claimed predecessor link
Get-ADServiceAccount -Filter { ObjectClass -eq 'msDS-DelegatedManagedServiceAccount' } -Properties msDS-ManagedAccountPrecededByLink, msDS-DelegatedMSAState, whenCreated |
  Select-Object Name, msDS-ManagedAccountPrecededByLink, msDS-DelegatedMSAState, whenCreated

# 3. Audit who holds CreateChild on OUs for the msDS-DelegatedManagedServiceAccount object class —
#    the specific permission the technique actually requires, far more commonly granted than admins expect
dsacls "<OU Distinguished Name>" | Select-String "Create Child"

# 4. Pull dMSA-specific Kerberos operational events for the suspect object
Get-WinEvent -LogName "Microsoft-Windows-Security-Kerberos/Operational" |
  Where-Object { $_.Id -in 307, 308, 309 -and $_.Message -match "<suspect dMSA name>" }
```

Preserve output from all four commands for the incident record before disabling/deleting the suspect object.

**Rollback note:** N/A — this playbook is investigation, not remediation. The actual remediation (revoking the offending OU delegation, disabling/removing the object) should follow your incident response runbook.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  dMSA Evidence Collector
.NOTES     Run from a DC (or host with RSAT for Windows Server 2025/Windows 11 24H2+) with rights
           to read the dMSA object, then separately from the affected host for the local-side checks.
#>

$reportPath = "C:\Temp\dMSAEvidence_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

"=== Windows Server 2025 DC Inventory ===" | Out-File "$reportPath\01_DCInventory.txt"
Get-ADDomainController -Filter * | Select-Object HostName, OperatingSystem, Site |
  Format-List | Out-File "$reportPath\01_DCInventory.txt" -Append

"=== KDS Root Key(s) ===" | Out-File "$reportPath\02_KdsRootKey.txt"
Get-KdsRootKey | Format-List | Out-File "$reportPath\02_KdsRootKey.txt" -Append

"=== dMSA Object ===" | Out-File "$reportPath\03_dMSAObject.txt"
Get-ADServiceAccount -Identity "<dMSAName>" -Properties * |
  Format-List | Out-File "$reportPath\03_dMSAObject.txt" -Append

"=== Legacy Account (if migration) ===" | Out-File "$reportPath\04_LegacyAccount.txt"
Get-ADServiceAccount -Identity "<LegacyServiceAccountName>" -Properties * -ErrorAction SilentlyContinue |
  Format-List | Out-File "$reportPath\04_LegacyAccount.txt" -Append

"=== dMSA Kerberos Operational Events (307/308/309, last 100) ===" | Out-File "$reportPath\05_KerberosEvents.txt"
Get-WinEvent -LogName "Microsoft-Windows-Security-Kerberos/Operational" -MaxEvents 200 -ErrorAction SilentlyContinue |
  Where-Object { $_.Id -in 307, 308, 309 } |
  Select-Object TimeCreated, Id, Message | Format-List | Out-File "$reportPath\05_KerberosEvents.txt" -Append

Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "Evidence collected: $reportPath.zip" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Confirm a Windows Server 2025 DC exists | `Get-ADDomainController -Filter * \| Select HostName, OperatingSystem` |
| Check KDS root key state | `Get-KdsRootKey \| Select KeyId, EffectiveTime` |
| Create a standalone dMSA | `New-ADServiceAccount -CreateDelegatedServiceAccount -KerberosEncryptionType AES256 -Name "<Name>" -DNSHostName "<fqdn>"` |
| Set standalone dMSA state explicitly | `Set-ADServiceAccount -Identity "<Name>" -Replace @{ "msDS-DelegatedMSAState" = 3 }` |
| View/set delegation | `Get-`/`Set-ADServiceAccount -Identity "<Name>" -PrincipalsAllowedToRetrieveManagedPassword "<Group>"` |
| Start a migration | `Start-ADServiceAccountMigration -Identity "<dMSA>" -SupersededAccount "<LegacyDN>"` |
| Complete a migration | `Complete-ADServiceAccountMigration -Identity "<dMSA>" -SupersededAccount "<LegacyDN>"` |
| Undo an active/completed migration | `Undo-ADServiceAccountMigration -Identity "<dMSA>" -SupersededAccount "<LegacyDN>"` |
| Reset a dMSA to unlinked | `Reset-ADServiceAccountMigration -Identity "<dMSA>" -SupersededAccount "<LegacyDN>"` |
| Check migration state | `Get-ADServiceAccount -Identity "<Name>" -Properties msDS-DelegatedMSAState` |
| Enable client-side dMSA logon (one-off) | `Set-ItemProperty -Path "HKLM:\...\Kerberos\Parameters" -Name DelegatedMSAEnabled -Value 1 -Type DWORD` |
| Configure a Windows service to use a dMSA | `sc.exe config "<Service>" obj= "DOMAIN\Name$" password= ""` |
| Inventory all dMSAs domain-wide | `Get-ADServiceAccount -Filter { ObjectClass -eq 'msDS-DelegatedManagedServiceAccount' }` |
| View dMSA-specific Kerberos events | `Get-WinEvent -LogName "Microsoft-Windows-Security-Kerberos/Operational" \| Where Id -in 307,308,309` |

---
## 🎓 Learning Pointers

- **dMSA is a migration state machine layered on top of gMSA's password-derivation model, not a replacement for it.** Both still depend on the same forest KDS root key/GKDS mechanics — see `gMSA-A.md`'s architecture section for that shared foundation before assuming dMSA reinvents it. [Delegated Managed Service Accounts overview](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/delegated-managed-service-accounts/delegated-managed-service-accounts-overview)
- **Schema extension and forest/domain functional level are two different gates — dMSA needs only the former.** Don't assume a forest that hasn't raised its functional level to Windows Server 2025 is automatically dMSA-incapable; verify schema and DC OS version directly. [Setting up delegated Managed Service Accounts](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/delegated-managed-service-accounts/delegated-managed-service-accounts-set-up-dmsa)
- **`DelegatedMSAEnabled` is a deliberate fail-closed design choice, disabled by default everywhere, including Windows 11 24H2+ clients** — treat it as a required rollout step on every consuming host, not an edge-case setting.
- **The migration observation window (~14 days minimum, ~28 days typical) exists because Kerberos ticket caches need time to expire domain-wide** — don't treat a dMSA sitting in state `1` for two weeks as a stuck or forgotten migration without first confirming intent.
- **BadSuccessor (CVE-2025-53779) is a documented case of a feature's own core mechanism becoming a disclosed privilege-escalation technique.** Treat unexplained-privilege dMSA tickets as security triage, not routine break-fix — see the [Akamai BadSuccessor research](https://www.akamai.com/blog/security-research/abusing-dmsa-for-privilege-escalation-in-active-directory) and the [Delegated Managed Service Accounts FAQ](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/delegated-managed-service-accounts/delegated-managed-service-accounts-faq).
- **This is genuinely new technology under active industry security research** — most environments will encounter gMSA far more often than dMSA until Windows Server 2025 DC adoption is widespread; verify current Microsoft Learn guidance before treating any specific dMSA behavior documented here as permanently settled.
