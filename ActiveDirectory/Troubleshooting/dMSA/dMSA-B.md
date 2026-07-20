# Delegated Managed Service Accounts (dMSA) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

dMSA is a **Windows Server 2025** feature — distinct from gMSA (see `ActiveDirectory/Troubleshooting/gMSA/gMSA-B.md`). Confirm you're actually looking at a dMSA-related ticket before proceeding: dMSA object names commonly appear as standalone service accounts or as the target of a migration from a legacy service account, and the migration state lives in `msDS-DelegatedMSAState`, not in any gMSA property.

Run these from an elevated PowerShell session on a Windows Server 2025 DC (or a Windows Server 2025 management host with RSAT for WS2025):

```powershell
# 1. Confirm at least one Windows Server 2025 DC exists and is discoverable — hard prerequisite, nothing works without it
Get-ADDomainController -Filter * | Select-Object HostName, OperatingSystem, Site

# 2. Confirm the KDS root key exists and has converged — same shared dependency as gMSA
Get-KdsRootKey | Select-Object KeyId, EffectiveTime, CreationTime

# 3. Look up the dMSA object and its migration state
Get-ADServiceAccount -Identity "<dMSAName>" -Properties msDS-DelegatedMSAState, msDS-ManagedAccountPrecededByLink, PrincipalsAllowedToRetrieveManagedPassword |
  Select-Object Name, Enabled, msDS-DelegatedMSAState, msDS-ManagedAccountPrecededByLink, PrincipalsAllowedToRetrieveManagedPassword

# 4. If migrating from a legacy account, confirm ITS state too
Get-ADServiceAccount -Identity "<LegacyServiceAccountName>" -Properties Enabled, msDS-SupersededManagedServiceAccountLink, msDS-SupersededServiceAccountState |
  Select-Object Name, Enabled, msDS-SupersededManagedServiceAccountLink, msDS-SupersededServiceAccountState

# 5. From the AFFECTED HOST — confirm dMSA logons are actually permitted (registry policy, not just AD authorization)
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Kerberos\Parameters" -Name DelegatedMSAEnabled -ErrorAction SilentlyContinue
```

| What you see | What it means |
|---|---|
| `Get-ADDomainController` shows no `OperatingSystem` containing "2025" | dMSA cannot be created or used anywhere in this domain yet — this is the #1 wrong-ticket cause; stop here and confirm the requester actually means gMSA |
| `msDS-DelegatedMSAState = 0` (or absent) | Not a valid/initialized dMSA — likely a naming confusion with a legacy account or a creation that never completed |
| `msDS-DelegatedMSAState = 1` | Migration in progress (`Start-ADServiceAccountMigration` ran, `Complete-ADServiceAccountMigration` has not) — the *legacy* account is still what services authenticate as during this window |
| `msDS-DelegatedMSAState = 2` | Migration completed — legacy account is now disabled and superseded; the dMSA is authoritative |
| `msDS-DelegatedMSAState = 3` | Standalone dMSA, never linked to a legacy account |
| `DelegatedMSAEnabled` registry value missing/`0` on the client | The client-side Kerberos policy that permits dMSA logon hasn't been set — this is a separate switch from AD-side authorization and is a very common first-deployment miss (Fix 3) |
| Service still authenticates as the legacy account after "migration complete" | The service itself was never reconfigured to log on as the dMSA — migration moves AD state, not the service's own logon configuration (Fix 4) |
| Ticket mentions an account "was just created and immediately has Domain Admin rights" or similarly implausible privilege | **Stop and treat as a security incident, not a break-fix ticket** — this is the signature of BadSuccessor-style dMSA privilege-escalation abuse (see Fix 6) |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Forest schema extended to Windows Server 2025 (adds msDS-DelegatedManagedServiceAccount class + 8 attributes)
  └── At least one Windows Server 2025 DC exists AND is discoverable by the requesting client/server
        └── KDS Root Key created (Add-KdsRootKey) AND past its EffectiveTime — same shared prerequisite as gMSA
              └── dMSA object created (New-ADServiceAccount -CreateDelegatedServiceAccount $true)
                    └── PrincipalsAllowedToRetrieveManagedPassword grants the target machine identity
                          └── (Migration path only) Start-ADServiceAccountMigration links dMSA ↔ legacy account
                                └── Client/server OS supports dMSA AND has DelegatedMSAEnabled registry policy set to 1
                                      └── Service/task/app pool reconfigured to log on as the dMSA (never happens automatically)
                                            └── Complete-ADServiceAccountMigration disables the legacy account and copies SPNs/delegation/AuthN policy
```

Key failure points:
- No Windows Server 2025 DC anywhere in the domain — dMSA is architecturally unavailable, not merely misconfigured
- KDS root key convergence delay (default 10 hours) — identical trap to gMSA, easy to misdiagnose as a dMSA-specific bug
- The client-side `DelegatedMSAEnabled` registry policy is a **separate gate** from AD-side authorization — a host can be fully authorized in AD and still fail to log on with the dMSA if this registry value was never set
- Migration moves AD object state; it does **not** reconfigure the consuming service — that's always a manual step (Fix 4)
- Mixed-OS environments: every client/server actually consuming the dMSA must itself support dMSA (Windows Server 2025 or a client OS with the relevant update) — legacy OS members fail authentication once the old account is disabled at `Complete-ADServiceAccountMigration`

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm a Windows Server 2025 DC exists and is discoverable**
```powershell
Get-ADDomainController -Filter * | Select-Object HostName, OperatingSystem
```
Expected: at least one DC with an `OperatingSystem` string containing "2025". If none, dMSA is not usable in this domain — redirect the ticket rather than continuing diagnosis.

**Step 2 — Confirm KDS root key convergence (shared prerequisite with gMSA)**
```powershell
Get-KdsRootKey | Select-Object KeyId, EffectiveTime
```
Expected: at least one key with `EffectiveTime` in the past.

**Step 3 — Inspect the dMSA object's full migration state**
```powershell
Get-ADServiceAccount -Identity "<dMSAName>" -Properties * |
  Select-Object Name, Enabled, DNSHostName, msDS-DelegatedMSAState, msDS-ManagedAccountPrecededByLink,
    msDS-SupersededServiceAccountState, PrincipalsAllowedToRetrieveManagedPassword
```
Cross-reference `msDS-DelegatedMSAState` against the table above.

**Step 4 — If mid-migration, check the legacy account side**
```powershell
Get-ADServiceAccount -Identity "<LegacyServiceAccountName>" -Properties Enabled, msDS-SupersededManagedServiceAccountLink |
  Select-Object Name, Enabled, msDS-SupersededManagedServiceAccountLink
```
Expected during an in-progress migration: legacy account still `Enabled = True`, linked back to the dMSA. After `Complete-ADServiceAccountMigration`: `Enabled = False`.

**Step 5 — On the affected host: confirm the registry policy is set**
```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Kerberos\Parameters" -Name DelegatedMSAEnabled -ErrorAction SilentlyContinue
```
Expected: `DelegatedMSAEnabled = 1`. This is required both for standalone dMSA use and for any host consuming a dMSA that superseded a legacy account it previously used from multiple servers.

**Step 6 — On the affected host: confirm the consuming service is actually configured for the dMSA**
```powershell
Get-CimInstance Win32_Service -Filter "Name='<ServiceName>'" | Select-Object Name, StartName
```
Expected: `StartName` shows `DOMAIN\dMSAName$`. If it still shows the legacy account name, the service was never reconfigured (Fix 4) — this is independent of whether the AD-side migration completed.

**Step 7 — Check dMSA-specific Kerberos operational events**
```powershell
# Enable once if not already active:
wevtutil sl Microsoft-Windows-Security-Kerberos/Operational /e:true
Get-WinEvent -LogName "Microsoft-Windows-Security-Kerberos/Operational" -MaxEvents 30 |
  Where-Object { $_.Id -in 307, 308, 309 } | Select-Object TimeCreated, Id, Message
```
Event 307 = migration state change, 308 = a machine added itself to `PrincipalsAllowedToRetrieveManagedPassword` during migration, 309 = a Kerberos client fetched dMSA keys from the DC.

---
## Common Fix Paths

<details><summary>Fix 1 — No Windows Server 2025 DC in the domain</summary>

**Cause:** dMSA requires at least one Windows Server 2025 DC that the requesting client/server can discover. This is not a per-object misconfiguration — it's a hard platform prerequisite.

There is no workaround short of standing up (or upgrading) a DC to Windows Server 2025. If the client is unmanaged as to which DC it talks to, confirm site/subnet coverage puts a Windows Server 2025 DC in scope for the affected client's site once one exists.

**Rollback note:** N/A — this is infrastructure planning, not a reversible fix.

</details>

<details><summary>Fix 2 — KDS root key hasn't converged yet</summary>

**Cause:** Identical shared dependency to gMSA — see `gMSA-B.md` Fix 1 for the full explanation. A freshly created root key has a default 10-hour `EffectiveTime` delay.

```powershell
Get-KdsRootKey | Select-Object KeyId, EffectiveTime
```

**In production:** wait it out. **In a lab/single-DC environment only:**
```powershell
Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10))
```

**Rollback note:** Additional root keys are non-destructive; nothing to roll back.

</details>

<details><summary>Fix 3 — Client-side DelegatedMSAEnabled registry policy not set</summary>

**Cause:** AD-side authorization (`PrincipalsAllowedToRetrieveManagedPassword`) is necessary but not sufficient — the client also needs a local Kerberos policy value permitting dMSA logon. This is most commonly missed on the very first host in an environment, or on hosts joined outside the GPO/Intune baseline that sets it.

```powershell
$params = @{
  Path  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Kerberos\Parameters"
  Name  = "DelegatedMSAEnabled"
  Value = 1
  Type  = "DWORD"
}
Set-ItemProperty @params
```
Prefer setting this via the **Computer Configuration\Administrative Templates\System\Kerberos\Enable Delegated Managed Service Account logons** Group Policy setting for anything beyond a one-off test host, so it survives re-imaging and applies consistently across the fleet.

**Rollback note:** Set the value back to `0` (or remove the key) to disable dMSA logon on that specific host — does not affect the dMSA object itself or any other host.

</details>

<details><summary>Fix 4 — Service/task never reconfigured to log on as the dMSA</summary>

**Cause:** `Complete-ADServiceAccountMigration` moves AD object state (SPNs, delegation, AuthN policy) from the legacy account to the dMSA — it does **not** touch the actual service, scheduled task, or app pool logon configuration on any consuming host. That's always a manual step, and it's the single most common "migration completed but the service broke" root cause.

```powershell
# Windows service
sc.exe config "<ServiceName>" obj= "DOMAIN\dMSAName$" password= ""
Restart-Service -Name "<ServiceName>"

# Scheduled task
$principal = New-ScheduledTaskPrincipal -UserId "DOMAIN\dMSAName$" -LogonType Password -RunLevel Highest
Set-ScheduledTask -TaskName "<TaskName>" -Principal $principal
```

**Rollback note:** Revert `StartName`/principal to the legacy account name — only safe while the legacy account is still enabled (i.e., before `Complete-ADServiceAccountMigration`, or immediately after using `Undo-ADServiceAccountMigration`/`Reset-ADServiceAccountMigration`).

</details>

<details><summary>Fix 5 — Migration needs to be undone or reset</summary>

**Cause:** Wrong account was migrated, migration was started prematurely, or testing needs to restart from scratch. Microsoft explicitly supports backing out.

```powershell
# Undo a completed or in-progress migration, restoring the legacy account to active use
Undo-ADServiceAccountMigration -Identity "<dMSAName>" -SupersededAccount "<DN of legacy account>"

# Or fully reset the dMSA to an unlinked state to start over
Reset-ADServiceAccountMigration -Identity "<dMSAName>" -SupersededAccount "<DN of legacy account>"
```

**Never delete the original service account**, even long after a successful migration — Microsoft's own guidance explicitly warns this causes issues, since the dMSA retains forward/backward links to it.

**Rollback note:** These commands *are* the rollback path — safe to run as documented. Confirm which one you need: `Undo` reverses an active/completed migration; `Reset` clears a dMSA back to a clean unlinked state.

</details>

<details><summary>Fix 6 — Suspected BadSuccessor-style dMSA privilege escalation abuse</summary>

**Cause:** dMSA's migration-linking mechanism (`msDS-ManagedAccountPrecededByLink` / `msDS-DelegatedMSAState`) was the basis of a disclosed privilege-escalation technique (CVE-2025-53779, "BadSuccessor") in which any principal with `CreateChild` rights on **any OU** — a permission far more common than most admins realize — could create a dMSA and link it to simulate having migrated from an arbitrary target account, including a Domain Admin, gaining that account's effective privileges without ever touching the target account directly. Microsoft's August 2025 patch closed the original one-sided exploitation path by requiring a genuine mutual link on both sides, but the underlying primitive (pairing a controlled dMSA with a target account you already have some write access to) remains a documented credential/privilege-acquisition technique post-patch.

**This is not a break-fix task — engage your security/incident response process.** Do not attempt to quietly delete the suspicious object before evidence is captured.

Immediate containment/triage steps once authorized:
```powershell
# 1. Confirm DC patch level — August 2025 cumulative update or later closes the one-sided exploitation path
Get-HotFix | Where-Object { $_.InstalledOn -gt (Get-Date "2025-08-01") } | Sort-Object InstalledOn

# 2. Inventory every dMSA in the domain and its claimed predecessor link — look for anything linking to a privileged account with no legitimate migration history
Get-ADServiceAccount -Filter { ObjectClass -eq 'msDS-DelegatedManagedServiceAccount' } -Properties msDS-ManagedAccountPrecededByLink, msDS-DelegatedMSAState, whenCreated |
  Select-Object Name, msDS-ManagedAccountPrecededByLink, msDS-DelegatedMSAState, whenCreated

# 3. Audit who holds CreateChild on OUs for the msDS-DelegatedManagedServiceAccount object class — this is the permission the technique actually requires
dsacls "<OU Distinguished Name>" | Select-String "Create Child"

# 4. Pull the dMSA-specific Kerberos operational events for the suspect object
Get-WinEvent -LogName "Microsoft-Windows-Security-Kerberos/Operational" |
  Where-Object { $_.Id -in 307, 308, 309 -and $_.Message -match "<suspect dMSA name>" }
```
Preserve output from all four commands for the incident record before taking any remediation action (disable/delete the object) — see `Security/` domain incident-response guidance for the broader process.

**Rollback note:** N/A — this fix path is investigation, not remediation; the actual remediation (revoking the offending delegation, disabling/removing the object) should follow your incident response runbook, not be improvised here.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — dMSA Issue

dMSA name: ___________________
Legacy account (if migration): ___________________
Affected host(s): ____________
Service/task/app pool using it: ____________

Windows Server 2025 DC present in domain: (Yes/No) ____________
Get-KdsRootKey EffectiveTime: ____________ (past / future)
msDS-DelegatedMSAState value: ____________ (0=uninitialized / 1=in progress / 2=complete / 3=standalone)
DelegatedMSAEnabled registry value on affected host: ____________
Service StartName on affected host: ____________
Kerberos Operational log events (307/308/309) observed: ____________

Steps already attempted:
[ ] Confirmed a Windows Server 2025 DC exists and is discoverable
[ ] Get-KdsRootKey checked for convergence
[ ] msDS-DelegatedMSAState reviewed on the dMSA object
[ ] Legacy account state reviewed (if mid-migration)
[ ] DelegatedMSAEnabled registry policy verified on affected host
[ ] Service/task logon account format verified
[ ] Security/incident-response engaged (if BadSuccessor-style abuse suspected)
```

---
## 🎓 Learning Pointers

- **dMSA and gMSA are not the same thing and cannot be converted into each other.** Microsoft's own FAQ explicitly states you cannot migrate a gMSA to a dMSA — if the ticket assumes that path exists, correct the assumption before proceeding. See [Delegated Managed Service Accounts FAQ](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/delegated-managed-service-accounts/delegated-managed-service-accounts-faq).
- **Authorization, client policy, and service reconfiguration are three separate gates**, not one step: `PrincipalsAllowedToRetrieveManagedPassword` (AD-side), `DelegatedMSAEnabled` (client registry/GPO), and manually pointing the actual service at the new account (never automatic). Missing any one produces a different-looking failure.
- **Migration state, not account existence, tells you what's actually authoritative right now.** A dMSA object existing doesn't mean anything is using it yet — check `msDS-DelegatedMSAState` before assuming.
- **This is a very new (Windows Server 2025) feature under active security research.** A disclosed privilege-escalation technique (BadSuccessor, CVE-2025-53779) means dMSA-related tickets that look like unexplained privilege grants deserve security review, not routine troubleshooting — see Fix 6. See [Setting up delegated Managed Service Accounts](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/delegated-managed-service-accounts/delegated-managed-service-accounts-set-up-dmsa) and the [Akamai BadSuccessor research](https://www.akamai.com/blog/security-research/abusing-dmsa-for-privilege-escalation-in-active-directory) for background.
- **Never delete a superseded legacy service account**, even well after migration — Microsoft explicitly warns this causes issues due to retained forward/backward links.
- For the long-stable, cross-Windows-Server-2012+ managed service account model, see `gMSA-B.md`/`gMSA-A.md` — most environments will encounter gMSA far more often than dMSA until Windows Server 2025 DC adoption is widespread.
