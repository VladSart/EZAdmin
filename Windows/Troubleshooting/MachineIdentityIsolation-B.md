# Machine Identity Isolation Domain Trust Failures (Sept 2026 CU) — Hotfix Runbook (Mode B: Ops)
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

**Trigger:** the September 2026 cumulative update — `KB5124008` (Windows 11 24H2/25H2) or `KB5124012` (Windows 11 26H1) — or any later CU. Confirmed by Microsoft as a known issue on the Windows release health dashboard. Affected devices lose their secure channel with an on-premises Active Directory domain, usually after the first reboot following the update.

```powershell
# 1. Confirm the device has the triggering CU (or later) installed
Get-HotFix | Where-Object { $_.HotFixID -in @('KB5124008','KB5124012') } |
    Select-Object HotFixID, InstalledOn

# 2. Confirm this looks like the known issue, not a real password/DES problem —
#    cached-credential logon should still work OFFLINE even though domain logon fails
Get-WinEvent -LogName 'System' -MaxEvents 50 |
    Where-Object { $_.ProviderName -eq 'Netlogon' -or $_.Id -in @(5719,5723) } |
    Select-Object TimeCreated, Id, Message

# 3. Read the current Machine Identity Isolation state — check BOTH locations,
#    a policy-provisioned value overrides a direct/local one
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard' -Name MachineIdentityIsolation -ErrorAction SilentlyContinue
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name MachineIdentityIsolation -ErrorAction SilentlyContinue

# 4. Confirm the domain's functional level — this decides whether the feature is even
#    SUPPORTED here, not just whether it's currently broken
Get-ADDomain | Select-Object DomainMode

# 5. Quick secure-channel health check (read-only, does not repair)
Test-ComputerSecureChannel
```

| Result | Next Step |
|--------|-----------|
| `MachineIdentityIsolation` = `2` (either location) AND domain is below **Windows Server 2025** functional level | → [Fix 1 — Disable Machine Identity Isolation (unsupported DFL)](#fix-1--disable-machine-identity-isolation-unsupported-dfl) |
| `MachineIdentityIsolation` = `2` AND domain **is** at Windows Server 2025 DFL or above | → [Fix 2 — Supported Environment, Repair Secure Channel Only](#fix-2--supported-environment-repair-secure-channel-only) |
| Value not present anywhere, but symptoms match | → [Fix 3 — Confirm It's Not a Different Trust Failure](#fix-3--confirm-its-not-a-different-trust-failure) |
| Already disabled the setting and trust is now broken worse than before | → [Fix 4 — Post-Disable Break: Unjoin/Rejoin Required](#fix-4--post-disable-break-unjoinrejoin-required) |
| Fleet-wide, dozens/hundreds of devices affected at once | → [Escalation Evidence](#escalation-evidence) — pause the CU rollout ring before touching individual devices |

---
## Dependency Cascade

<details><summary>What must be true for a domain-joined device to authenticate normally</summary>

```
Domain Controller reachable + healthy
        │
        ▼
Machine account secret known to BOTH the device and AD, in sync
        │
        ├── Classic model: secret cached in LSA (Local Security Authority)
        │
        └── Machine Identity Isolation ENFORCEMENT mode (MachineIdentityIsolation = 2):
                secret moved into Credential Guard (VBS-isolated), LSA copy deleted
                        │
                        ▼
                Requires: VBS + Credential Guard fully functional on THIS device
                Requires (per Microsoft, Sept 2026): DCs at Windows Server 2025
                Domain Functional Level or above — unsupported below that
                        │
                        ▼
                September 2026 CU (KB5124008 / KB5124012) makes Windows start
                HONORING an existing/policy-provisioned enforcement setting that
                may have been dormant since KB5055523 (Apr 2026) temporarily
                disabled the whole feature tenant-wide
                        │
                        ▼
                If Credential Guard cannot complete machine authentication
                after reboot → secure channel fails → "trust relationship
                between this workstation and the primary domain failed"
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm the update is present.**
   ```powershell
   Get-HotFix -Id KB5124008,KB5124012 -ErrorAction SilentlyContinue
   ```
   Expected (affected device): one of these two IDs returned with a recent `InstalledOn` date. Neither present → this is **not** the September 2026 known issue; troubleshoot as a standard trust-relationship failure instead.

2. **Rule out a genuine password/DES problem.** Try a cached-credential (offline) logon on the same device — disconnect from the network or use "Sign in options" if available.
   Expected if this IS the known issue: cached logon **succeeds**. Bad sign (real problem): cached logon also fails — stop here and escalate as a standard machine-account password mismatch instead of following this runbook further.

3. **Check both registry locations for the enforcement value.**
   ```powershell
   'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard','HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' |
       ForEach-Object { Get-ItemProperty $_ -Name MachineIdentityIsolation -ErrorAction SilentlyContinue }
   ```
   Expected: at least one location returns `2` (enforcement). If both are absent or `0`, the device was never configured for this feature — symptoms have a different cause.

4. **Check the domain's functional level.**
   ```powershell
   (Get-ADDomain).DomainMode
   ```
   `Windows2025Domain` or higher → environment is **supported**; the underlying feature should work once the secure channel is repaired (Fix 2). Anything lower → environment is **not supported** for this feature per Microsoft's own guidance; the setting must be disabled, not just repaired around (Fix 1).

5. **Identify how the setting was originally provisioned**, since the fix must be removed the same way it was applied:
   ```powershell
   # Intune-managed devices: check for the DeviceGuard/MachineIdentityIsolation policy CSP
   Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*' -ErrorAction SilentlyContinue | Select-Object -First 1
   # GPO-managed: check applied GPOs touching Device Guard settings
   gpresult /h C:\Temp\gpresult.html
   ```
   A value present under `HKLM:\SOFTWARE\Policies\...` (not the bare `HKLM:\SYSTEM\CurrentControlSet\...` path) means it is policy-provisioned (GPO or Intune) — editing the registry directly will be **overwritten on next policy sync** unless the source policy is also changed.

---
## Common Fix Paths

<details><summary>Fix 1 — Disable Machine Identity Isolation (unsupported DFL)</summary>

Use this when the domain is below Windows Server 2025 functional level — per Microsoft, the feature must be disabled here, not merely worked around.

**If provisioned via Intune policy** (policy CSP `DeviceGuard/MachineIdentityIsolation`): edit the source Intune Settings Catalog / Endpoint security policy and set the value to `0` (disabled), then let the device sync — do **not** hand-edit the registry on an Intune-managed device, the policy will simply reapply `2` on the next check-in.

**If provisioned via Group Policy:** edit the source GPO's Device Guard setting to disabled, then force policy refresh:
```powershell
gpupdate /force
```

**If provisioned directly in the registry** (no GPO/Intune managing it — confirm this first, see Diagnosis step 5):
```powershell
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name MachineIdentityIsolation -Value 0 -Type DWord
Restart-Computer -Confirm
```

**After disabling, on ALL paths — reboot, then repair the secure channel:**
```powershell
Test-ComputerSecureChannel -Repair -Credential (Get-Credential)
```

**Rollback / caution:** Microsoft's own documentation warns that toggling this setting from enforcement mode straight to disabled can itself break domain authentication further, requiring the device to be **unjoined and rejoined** to the domain — see [Fix 4](#fix-4--post-disable-break-unjoinrejoin-required) if the repair command above does not restore access. Have local administrator credentials confirmed working on the device before starting this fix on a production machine.

</details>

<details><summary>Fix 2 — Supported Environment, Repair Secure Channel Only</summary>

Domain is already at Windows Server 2025 DFL or above — leave Machine Identity Isolation enabled (it is a supported, intentional hardening feature here) and just repair the broken secure channel:

```powershell
Test-ComputerSecureChannel -Repair -Credential (Get-Credential)
Restart-Computer -Confirm
```

If repair fails, fall back to the Fix 4 unjoin/rejoin path — Credential Guard-protected machine secrets do not always allow an in-place repair once the LSA copy has been deleted.

**No rollback needed** — this path does not change the feature's configuration, only the broken trust state.

</details>

<details><summary>Fix 3 — Confirm It's Not a Different Trust Failure</summary>

If `MachineIdentityIsolation` is not set anywhere on the device but symptoms otherwise match (trust-relationship error, cached logon still works), this is a **different, unrelated** secure-channel problem — most commonly a stale computer account password after an offline/cloned VM, or a computer account that was deleted/reset in AD.

```powershell
# Standard (non-CU-related) secure channel repair
Test-ComputerSecureChannel -Repair -Credential (Get-Credential)
# If that fails, confirm the computer object still exists and isn't disabled in AD
Get-ADComputer $env:COMPUTERNAME -Properties Enabled
```

No rollback notes — this is standard secure-channel remediation, not specific to this known issue.

</details>

<details><summary>Fix 4 — Post-Disable Break: Unjoin/Rejoin Required</summary>

Use when Fix 1's repair command fails to restore the secure channel after disabling Machine Identity Isolation — this is the scenario Microsoft's documentation explicitly warns about.

```powershell
# 1. Unjoin from the domain (requires a local admin account with a cached/known password)
Remove-Computer -UnjoinDomainCredential (Get-Credential) -PassThru -Verbose -Restart

# 2. After reboot into workgroup mode, rejoin the domain
Add-Computer -DomainName '<yourdomain.com>' -Credential (Get-Credential) -Restart
```

**Rollback:** none — this is itself the destructive-but-necessary recovery step. Confirm you have a working local administrator account on the device (or out-of-band access, e.g. remote KVM/Autopilot reset) before starting; a device with no reachable local admin and a broken secure channel may require full re-imaging or Autopilot re-enrollment instead.

</details>

---
## Escalation Evidence

```
MACHINE IDENTITY ISOLATION DOMAIN TRUST FAILURE — Escalation Package
=====================================================================
Device name:                 <hostname>
Windows version/build:       <e.g. 25H2, build 26200.9445>
Triggering CU installed:     <KB5124008 / KB5124012 / other, + InstalledOn date>
Domain:                      <domain FQDN>
Domain Functional Level:     <output of (Get-ADDomain).DomainMode>
MachineIdentityIsolation
  (policy path) value:       <value or "not set">
  (local/LSA path) value:    <value or "not set">
Provisioning source:         <Intune policy CSP / GPO / direct registry / unknown>
Cached (offline) logon test: <succeeded / failed>
Test-ComputerSecureChannel:  <output>
Repair attempted:            <yes/no — outcome>
Number of devices affected:  <count, if fleet-wide>
Business impact:             <e.g. helpdesk unable to remote in, users locked out>
```

---
## 🎓 Learning Pointers

- This is a **currently unfolding known issue** (first reported mid-September 2026, Microsoft acknowledged and published a workaround on 2026-09-17) — check the [Windows release health dashboard](https://learn.microsoft.com/en-us/windows/release-health/) for the latest status before assuming the registry workaround in this runbook is the final, permanent fix; Microsoft has stated it is working on a Windows update that will temporarily prevent enforcement automatically.
- The September 2026 CU did **not** newly enable Machine Identity Isolation — it made Windows start honoring a setting that may have been configured (via GPO, Intune, or registry) months earlier and was dormant because `KB5055523` (April 2026) had temporarily disabled the whole feature tenant-wide due to an unrelated Kerberos machine-password-rotation bug. A device can therefore break in September for a policy decision made much earlier in the year — check GPO/Intune change history, not just recent changes, when hunting for "who turned this on."
- Cached-credential logon continuing to work while domain logon fails is the fastest way to distinguish this issue from a genuine password/trust problem in the field — lead with that check on every ticket that mentions "trust relationship failed" this month.
- The fix must be removed through the **same mechanism** it was applied with. A hand-edited registry value on an Intune- or GPO-managed device will simply be reapplied on the next policy sync — always confirm the provisioning source (Diagnosis step 5) before editing anything directly.
- See also: [`ADCSTemplateMisconfiguration-B.md`](ADCSTemplateMisconfiguration-B.md) and [`CertificateServices-B.md`](CertificateServices-B.md) for other AD trust/authentication hotfix runbooks in this folder if the symptoms don't match after Triage step 2.
- Source: [BleepingComputer — Windows 11 KB5124008 update breaks domain trust for some users](https://www.bleepingcomputer.com/news/microsoft/windows-11-kb5124008-update-breaks-domain-trust-for-some-users/) and [Microsoft shares workaround for Windows domain login issues](https://www.bleepingcomputer.com/news/microsoft/microsoft-releases-workaround-for-windows-domain-login-authentication-issues/); background architecture at [Credential Guard protected machine accounts — Microsoft Learn](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/delegated-managed-service-accounts/credential-guard-protected-machine-accounts).
