# PAC Requestor Validation / sAMAccountName Spoofing (noPac) — Hotfix Runbook (Mode B: Ops)
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

Three tickets land in this bucket: (1) a pentest/vulnerability-scan report flags "noPac" / "sAMAccountName spoofing" / "missing PAC validation" against a DC, (2) a legacy or non-Windows Kerberos client suddenly fails to authenticate after DC patching, or (3) someone wants to know whether their environment is actually protected. Run this first, on a DC:

```powershell
# 1. Confirm every DC is patched for CVE-2021-42278/CVE-2021-42287 (Nov 2021 or later cumulative update)
Get-ADDomainController -Filter * | ForEach-Object {
    $os = Get-CimInstance -ComputerName $_.HostName -ClassName Win32_OperatingSystem
    [PSCustomObject]@{ DC = $_.HostName; Build = $os.BuildNumber; InstallDate = $os.InstallDate }
}

# 2. Current MachineAccountQuota — the enabling misconfiguration for the FIRST step of the attack chain
(Get-ADDomain).Name
Get-ADObject (Get-ADDomain).DistinguishedName -Property ms-DS-MachineAccountQuota |
    Select-Object -ExpandProperty ms-DS-MachineAccountQuota

# 3. Any non-Domain-Admin accounts that have created computer objects recently (Event 4741)
Get-WinEvent -LogName Security -FilterXPath "*[System[(EventID=4741)]]" -MaxEvents 50 |
    Select-Object TimeCreated, @{n='Actor';e={$_.Properties[4].Value}}, @{n='NewComputer';e={$_.Properties[0].Value}}

# 4. Recent sAMAccountName renames on computer objects (Event 4781) — the noPac fingerprint
Get-WinEvent -LogName Security -FilterXPath "*[System[(EventID=4781)]]" -MaxEvents 50 |
    Select-Object TimeCreated, @{n='OldName';e={$_.Properties[1].Value}}, @{n='NewName';e={$_.Properties[2].Value}}

# 5. Enforcement-transition-era diagnostic events (only useful on DCs patched between Nov 2021 and Oct 2022, or in forensic log review)
Get-WinEvent -LogName "Microsoft-Windows-Kerberos-Key-Distribution-Center/Operational" -MaxEvents 50 -ErrorAction SilentlyContinue |
    Where-Object { $_.Id -in 35,36,37,38 }
```

| Result | Interpretation |
|---|---|
| Any DC build older than Nov 2021 CU | **Vulnerable to the full noPac chain.** Patch immediately — this is not a config issue, it's a missing security update. |
| `ms-DS-MachineAccountQuota` > 0 (default 10) | Any authenticated domain user (including guests-turned-users) can create up to that many computer objects — the precondition for the spoofing step, independent of patch level. Defense-in-depth: set to 0. |
| Event 4741 spikes from a non-admin/non-provisioning account, especially off-hours | Investigate — could be legitimate device onboarding (Autopilot, hybrid join) or could be attack staging. Correlate with Event 4781 on the same account within minutes. |
| Event 4781 renaming a computer account's sAMAccountName to strip the trailing `$` or resemble a DC name | **Strong noPac indicator.** Treat as a security incident, not routine hygiene — see Fix 3. |
| Events 35/36/37/38 present and DCs are fully patched (Oct 2022+ builds) | Expected background noise from legacy/non-Windows clients that don't send `PAC_REQUESTOR` — not itself an attack signal on a modern, enforced DC. See Fix 2. |
| All DCs patched, MachineAccountQuota reviewed, no anomalous 4741/4781 | Environment is not exploitable via noPac. Close the pentest finding with evidence, or move to Fix 4 if a scanner still flags it. |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Attacker has ANY authenticated domain account (standard user, no special rights)
  └── ms-DS-MachineAccountQuota > 0 on the domain (default 10 — attacker can create a computer object)
        └── (CVE-2021-42278) sAMAccountName of the new computer object can be renamed to
            impersonate an existing account name (e.g. a DC's name minus the trailing $) —
            AD did not adequately validate this before the Nov 2021 patch
              └── Attacker requests a TGT as the spoofed identity
                    └── (CVE-2021-42287) KDC name-resolution fallback + PAC construction gap
                        lets the resulting ticket carry Domain Controller-equivalent privilege
                        before the Nov 2021 patch — this is the actual privilege escalation
                          └── Attacker requests a service ticket using the elevated TGT
                                └── Full domain compromise (DCSync-equivalent access) from a
                                    single unprivileged starting account

PATCHED (Nov 2021 CU+, in Enforcement phase since Oct 11 2022):
  KDC now validates that the client name (cname) resolves to the SAME SID carried in the
  ticket's PAC_REQUESTOR structure — mismatch = ticket rejected outright, chain broken at
  the TGT stage regardless of MachineAccountQuota
    (validation applies ONLY when client and KDC are in the SAME domain — cross-trust golden
    tickets for non-existent users are a separate, still-open consideration, see Learning Pointers)
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm patch level on every DC** (not just one — noPac only requires ONE unpatched, reachable DC to succeed).
   ```powershell
   Get-ADDomainController -Filter * | Select-Object HostName, OperatingSystem, OperatingSystemVersion
   ```
   Expected: every DC on a build with the November 9, 2021 cumulative update (KB5008380 / KB5008602) or later. Anything older is exploitable today, not theoretically.

2. **Check the registry enforcement state directly (only meaningful on Nov 2021–Oct 2022-era builds; on anything patched after October 2022 the key is deprecated and ignored — the behavior is unconditionally Enforcement).**
   ```powershell
   Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Kdc" -Name PACRequestorEnforcement -ErrorAction SilentlyContinue
   ```
   `0` = disabled/reverted (never leave this set — re-opens the hole even on a patched build). `1` = deployment/compatibility default. `2` = enforcement (recommended if you must set it manually pre-Oct 2022). Absent on a fully current DC = expected, the key is retired.

3. **MachineAccountQuota review** — this is independent of patching and is the actual finding most pentest reports lead with today, since the CVE patch alone doesn't touch this default.
   ```powershell
   Get-ADObject (Get-ADDomain).DistinguishedName -Properties ms-DS-MachineAccountQuota |
       Select-Object DistinguishedName, ms-DS-MachineAccountQuota
   ```
   Default is `10`. Any value above `0` means every authenticated user can self-service-create that many computer objects.

4. **Look for the attack signature in the Security log**, correlating Event 4741 (computer account created) with Event 4781 (account renamed) on the same object within a short window. A legitimate device onboarding creates the account and never renames it; noPac tooling creates then immediately renames.

---
## Common Fix Paths

<details><summary>Fix 1 — DC still unpatched</summary>

There is no configuration workaround for an unpatched DC — this is a straight patching gap.

```powershell
# Confirm current patch level
Get-HotFix -Id KB5008380 -ComputerName <dc-name> -ErrorAction SilentlyContinue
# If not present, patch via your normal update process (WSUS/Autopatch/manual), then reboot.
```
No rollback needed — this is a strict security fix with no known compatibility break for standard Windows clients (see Fix 2 for the non-Windows exception).

</details>

<details><summary>Fix 2 — Legacy/non-Windows Kerberos client broke after DCs entered Enforcement</summary>

Symptom: a NAS (older NetApp ONTAP 7-Mode CIFS), Linux/Samba box, or other non-Windows Kerberos implementation authenticated fine before a DC patching cycle and now fails, with Events 35/37/38 in the KDC operational log correlating to that client's requests. This is the same class of gotcha as LDAP channel binding and certificate mapping hardening elsewhere in this folder — a third-party client that doesn't speak the new protocol structure.

1. Confirm the failure correlates to a specific non-Windows source IP/service account, not a Windows client (if it's Windows, this is not the cause — look elsewhere).
2. Check the vendor's support site for a firmware/software update that adds `PAC_REQUESTOR` support (this is the durable fix — Microsoft's Enforcement phase is permanent and is not going to be relaxed).
3. If no vendor fix exists and the device is business-critical short-term, the only interim options are: isolate the device's authentication to a dedicated, scoped service account with tightly controlled permissions, or move the device off Kerberos onto an alternative auth method it supports (e.g., local auth, LDAP simple bind over TLS) while a vendor fix or replacement is sourced. **There is no supported registry rollback on a modern DC** — `PACRequestorEnforcement=0` is not read anymore.

</details>

<details><summary>Fix 3 — Suspected active noPac exploitation (Event 4741 + 4781 correlation, or an unexplained new Domain Admin-equivalent object)</summary>

**Stop — treat as a security incident, not routine cleanup.**

1. Identify and disable the account that performed the computer-object creation/rename (do not delete yet — evidence).
   ```powershell
   Disable-ADAccount -Identity <suspect-computer-object>
   ```
2. Reset the krbtgt account password **twice**, spaced by the domain's replication convergence time (this invalidates all outstanding TGTs, including any forged/elevated ones already issued):
   ```powershell
   Set-ADAccountPassword -Identity krbtgt -Reset -NewPassword (ConvertTo-SecureString -AsPlainText "<complex-temp-value>" -Force)
   # wait for replication to converge across all DCs, THEN repeat once more
   ```
3. Audit for any NEW privileged group membership changes or ACL changes in the same time window (SDProp/AdminSDHolder cross-check — see `Troubleshooting/AdminSDHolder/`).
4. Confirm every DC is patched (Fix 1) and drop `ms-DS-MachineAccountQuota` to `0` (Fix 4) to close the entry point permanently.
5. Preserve Security log events (4741, 4781, 4768/4769 Kerberos ticket events) for the affected accounts before log rollover — export to a SIEM or offline archive.

</details>

<details><summary>Fix 4 — Harden MachineAccountQuota (recommended regardless of patch status)</summary>

```powershell
# Remove the default self-service computer-account-creation right
Set-ADObject -Identity (Get-ADDomain).DistinguishedName -Replace @{'ms-DS-MachineAccountQuota' = 0}

# Then delegate account creation to a specific group on a specific OU instead, e.g.:
dsacls "OU=Workstations,DC=contoso,DC=com" /I:S /G "CONTOSO\Device-Provisioning-Group:CC;computer"
```
Rollback: set `ms-DS-MachineAccountQuota` back to its prior value (`10` if default) — but this reopens self-service computer object creation for every user, so only do this if a specific legacy provisioning workflow depends on it and hasn't yet been migrated to a delegated group.

</details>

---
## Escalation Evidence

```
=== PAC Validation / noPac Escalation Packet ===
Domain:                          <domain FQDN>
DC patch level (all DCs):        <build numbers, oldest first>
ms-DS-MachineAccountQuota:       <value>
Event 4741 hits (last 7 days):   <count, top actors>
Event 4781 on computer objects:  <count, correlated with 4741? Y/N>
KDC Enforcement-era events (35/36/37/38): <count, correlated non-Windows client? Y/N>
Suspected incident (Y/N):        <Y/N — if Y, krbtgt reset status and disabled accounts listed below>
Disabled/quarantined accounts:   <list>
Non-Windows clients affected:    <device, vendor, firmware version, ticket with vendor open? Y/N>
Requested action:                <patch approval / MachineAccountQuota change window / vendor escalation / IR engagement>
```

---
## 🎓 Learning Pointers

- This is the "noPac" chain — CVE-2021-42278 (sAMAccountName spoofing) + CVE-2021-42287 (KDC name confusion) — patched together via [KB5008380](https://support.microsoft.com/en-us/topic/kb5008380-authentication-updates-cve-2021-42287-9dafac11-e0d0-4cb8-959a-143bd0201041). Patching only one CVE does not close the chain; both updates must be present.
- The fix rolled out in three phases (Initial Deployment Nov 9 2021 → Second Deployment Jul 12 2022 → Enforcement Oct 11 2022) — the exact same phased-rollout pattern used for the LDAP Channel Binding and Certificate Mapping (KB5014754) hardening already documented in this folder. By 2026 every phase is long past and Enforcement is the unconditional, permanent baseline on any patched DC — there is no supported way to revert it.
- The PAC validation check only applies when the client and KDC are in the **same domain** — cross-trust scenarios (a golden ticket forged for a non-existent user, presented across a trust) are not covered by this specific control. Don't over-claim protection in a pentest response.
- `ms-DS-MachineAccountQuota` is a separate, independent hardening item from the patch itself — a fully patched domain with the default quota of `10` is still handing out free computer-object creation to every authenticated user, which is exactly the precondition attackers (and pentesters) look for first. Treat patching and quota hardening as two separate remediation items.
- Community reference for the registry key values, the Event ID table (35/36/37/38), and Golden Ticket implications: [Netwrix — PACRequestorEnforcement and Kerberos Authentication](https://netwrix.com/en/resources/blog/pacrequestorenforcement-and-kerberos-authentication/).
- noPac remains a standard technique in offensive-security tooling and pentest methodology years after the patch, precisely because unpatched DCs and default MachineAccountQuota values are still common findings — this is why the topic keeps resurfacing in security assessments long after the CVE itself is "old news."
