# AD FS DKM Container ACL Hardening (CVE-2026-56155) — Hotfix Runbook (Mode B: Ops)
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

> **Deadline context:** Microsoft's **October 13, 2026** security update flips this from opt-in to **default-on Enforcement**. Audit mode has been live since the **July 14, 2026** update. If today is before Oct 13, 2026, treat this as a planned-remediation window, not a fire — but do not let it slide past the deadline unaddressed.

Run on **any one AD FS server** in the farm (config is farm-wide via the shared configuration database, not per-node).

```powershell
# 1. Is the July 2026+ security update installed? (KB5121391 or later cumulative)
Get-HotFix | Where-Object { $_.InstalledOn -ge '2026-07-14' } | Select-Object HotFixID, InstalledOn

# 2. What does AD FS currently report about the DKM container ACL? (events 1132-1136)
Get-WinEvent -LogName 'AD FS/Admin' -FilterXPath "*[System[(EventID=1132 or EventID=1133 or EventID=1134 or EventID=1135 or EventID=1136)]]" -MaxEvents 10 |
    Select-Object TimeCreated, Id, LevelDisplayName, Message

# 3. Current remediation opt-in/opt-out state
Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ADFS' -Name 'RemediateDkmAcl' -ErrorAction SilentlyContinue |
    Select-Object RemediateDkmAcl

# 4. Windows Server version on this node — determines which remediation path applies
(Get-CimInstance Win32_OperatingSystem).Caption

# 5. Find the DKM container itself, for reference in later steps
(Get-AdfsProperties).CertificateSharingContainer
```

| Signal | Interpretation | Go to |
|---|---|---|
| No hotfix found ≥ 2026-07-14 | Server predates Audit mode entirely — no detection is even running yet | Fix 1 |
| Event 1132 present, no 1135 after it | ACL is insecure and **has not been remediated** | Fix 2 |
| Event 1133 only | ACL already matches the secure baseline — no action needed | No fix needed; confirm on every farm node |
| Event 1134 | Detection itself is failing (LDAP connectivity) — the farm has **no visibility** into its own ACL state | Fix 3 |
| `RemediateDkmAcl` not set, date is before Oct 13, 2026 | Still in the window to remediate on your own schedule | Fix 2 (opt in now) |
| `RemediateDkmAcl` not set, date is on/after Oct 13, 2026 | Enforcement is live — remediation runs automatically on WS2016+; **WS2012/2012R2 do not auto-remediate, ever** | Fix 2 (WS2012 path) if 2012/2012R2 |
| Event 1136 | An attempted remediation failed | Fix 4 |
| Users report broken sign-in shortly after a 1135 remediation event | Rare, but a legitimate custom ACE (e.g. a monitoring tool's service account) may have been stripped | Fix 5 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
AD FS Configuration Database (WID or SQL)
        │
        ▼
Distributed Key Manager (DKM) container in AD
  (stores symmetric keys that decrypt Token-Signing /
   Token-Decrypting certificate private keys)
        │  ACL on this container gates who can read those keys
        ▼
adfssrv service account ── reads DKM keys at service start
        │
        ▼
Token-Signing / Token-Decrypting certificates decrypted in memory
        │
        ▼
AD FS issues signed/encrypted tokens trusted by Entra ID / relying parties
```

If the DKM container's ACL is overly permissive (e.g. a broad group like Authenticated Users, or a legacy delegation that was never cleaned up), **any principal with read access can pull the DKM key material and decrypt the token-signing private key offline** — with that key, an attacker can forge SAML/WS-Fed tokens for any user, for any relying party that trusts the farm, entirely outside AD FS's own logging. This is the same impact class as a stolen token-signing certificate ("Golden SAML"), except the ACL misconfiguration is the thing that hands over the key material in the first place. See the base `ADFS-A.md` for the certificate/relying-party trust model this feeds into.

</details>

---
## Diagnosis & Validation Flow

1. **Confirm every farm node is patched**, not just the one you're checking — DKM detection is per-node, and an unpatched node gives false confidence.
   ```powershell
   Invoke-Command -ComputerName <FarmNode1>,<FarmNode2> -ScriptBlock {
       Get-HotFix | Where-Object { $_.InstalledOn -ge '2026-07-14' } | Select-Object -First 1
   }
   ```

2. **Pull the most recent detection result.** Detection runs ~1 minute after service start and every 24 hours after that — if you just patched, restart `adfssrv` to force an immediate check rather than waiting.
   ```powershell
   Restart-Service adfssrv
   Start-Sleep -Seconds 90
   Get-WinEvent -LogName 'AD FS/Admin' -MaxEvents 5 |
       Where-Object { $_.Id -in 1132,1133,1134 } | Format-List TimeCreated, Id, Message
   ```
   Good: Event 1133 (healthy) or a 1132 you're prepared to remediate. Bad: Event 1134 (detection error) — resolve LDAP connectivity to the DKM container's DN before trusting any ACL state.

3. **Before remediating, capture the current ACL for rollback safety** — remediation is generally safe (the prior state was insecure by definition), but a saved SDDL costs nothing and event logs roll over.
   ```powershell
   $dkmDn = (Get-AdfsProperties).CertificateSharingContainer
   $entry = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$dkmDn")
   $entry.ObjectSecurity.Sddl | Out-File "C:\ADFSBackup\dkm-acl-pre-remediation-$(Get-Date -Format yyyyMMdd-HHmm).txt"
   ```

4. **Confirm which principals should remain after remediation** (the only expected secure state):

   | Principal | Access |
   |---|---|
   | Domain Admins | Generic All (Full Control) |
   | Enterprise Admins | Generic All (Full Control) |
   | SYSTEM | Generic All (Full Control) |
   | AD FS service account | Read, Write, Create Child, Write Owner, Delete Tree |

   Inheritance is disabled and every other explicit Allow ACE — including any you added intentionally for a third-party monitoring or backup tool — is removed. If you have such a tool, plan its access path (e.g. via Domain Admins-scoped service, not a direct DKM ACE) **before** remediating.

---
## Common Fix Paths

<details><summary>Fix 1 — Server predates the Audit-mode update</summary>

No detection is running at all — this server is fully exposed with zero visibility, worse than a 1132 warning.

```powershell
# Confirm current patch level
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 5

# Install the latest cumulative update via your normal patch pipeline (WSUS/Intune/manual),
# then re-run Triage step 1 to confirm.
```

Escalate to patch management if the server is intentionally held back (e.g. a change-freeze) — this is a security-hardening rollout, not an optional feature update, and should be prioritized ahead of the Oct 13, 2026 Enforcement date.

**Rollback:** N/A — installing a cumulative update is not reversible in the normal sense; this step only enables detection, it does not itself change any ACL.
</details>

<details><summary>Fix 2 — Opt in to remediation (Windows Server 2016 and later)</summary>

```powershell
# Run on ANY ONE AD FS server in the farm — this is a farm-wide config, not per-node
if (-not (Test-Path 'HKLM:\SOFTWARE\Microsoft\ADFS')) {
    New-Item -Path 'HKLM:\SOFTWARE\Microsoft' -Name 'ADFS' -Force | Out-Null
}
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ADFS' -Name 'RemediateDkmAcl' -Value 1 -PropertyType DWord -Force

# Trigger remediation immediately instead of waiting up to 24h
Restart-Service adfssrv
Start-Sleep -Seconds 90
Get-WinEvent -LogName 'AD FS/Admin' -MaxEvents 5 | Where-Object { $_.Id -in 1135,1136 } | Format-List TimeCreated, Id, Message
```

Confirm Event 1135 (success) and that the previous ACL (SDDL) it logs matches what you captured in Diagnosis step 3.

**Rollback:** if sign-in breaks post-remediation, see Fix 5. If you simply want to pause remediation without reverting the ACL, set the registry value to `0` — this does **not** restore the old ACL, it only stops future auto-remediation cycles.
</details>

<details><summary>Fix 2b — Opt in to remediation (Windows Server 2012 / 2012 R2)</summary>

These platforms cannot auto-grant the permissions remediation itself needs — you must manually grant the AD FS service account `WriteOwner`/`WriteDacl` on the DKM container first, on **any one** farm node.

```powershell
# 1. Identify the DKM container DN
$dkmContainerDn = (Get-AdfsProperties).CertificateSharingContainer
$dkmContainerDn

# 2. Identify the AD FS service account
$serviceAccount = (Get-CimInstance Win32_Service -Filter "Name='adfssrv'").StartName
$serviceAccount

# 3. Grant explicit Allow ACEs for WriteOwner and WriteDacl
$sid = (New-Object System.Security.Principal.NTAccount($serviceAccount)).Translate([System.Security.Principal.SecurityIdentifier])
$entry = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$dkmContainerDn")
$rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
    $sid,
    ([System.DirectoryServices.ActiveDirectoryRights]::WriteOwner -bor [System.DirectoryServices.ActiveDirectoryRights]::WriteDacl),
    [System.Security.AccessControl.AccessControlType]::Allow,
    [System.DirectoryServices.ActiveDirectorySecurityInheritance]::All
)
$entry.ObjectSecurity.AddAccessRule($rule)
$entry.CommitChanges()
$entry.Close()

# 4. Now opt in exactly as WS2016+ (Fix 2)
if (-not (Test-Path 'HKLM:\SOFTWARE\Microsoft\ADFS')) {
    New-Item -Path 'HKLM:\SOFTWARE\Microsoft' -Name 'ADFS' -Force | Out-Null
}
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ADFS' -Name 'RemediateDkmAcl' -Value 1 -PropertyType DWord -Force
Restart-Service adfssrv
```

**Important:** Enforcement mode (auto-remediation without the registry key) **never applies** to Windows Server 2012/2012 R2 — this manual path is the only way these platforms get remediated, before or after Oct 13, 2026. Flag these servers for OS upgrade planning independent of this fix; they are past mainstream support and depend on ESU.

**Rollback:** removing the WriteOwner/WriteDacl ACE you added in step 3 is safe once remediation has succeeded and you don't intend to re-run it — the service account doesn't need standing WriteOwner/WriteDacl for normal operation.
</details>

<details><summary>Fix 3 — Detection itself is failing (Event 1134)</summary>

```powershell
# Confirm the AD FS service account can read the DKM container at all
$dkmDn = (Get-AdfsProperties).CertificateSharingContainer
Get-ADObject -Identity $dkmDn -Properties * -ErrorAction Stop

# Check basic LDAP reachability from this node to a DC
Test-NetConnection -ComputerName (Get-ADDomainController -Discover).HostName -Port 389
```

Common causes: the farm's service account (or gMSA) lost read permission on its own DKM container through unrelated AD cleanup/delegation changes, or the node can't reach a DC on LDAP (389/636). Fix the underlying AD permissions or network path, then restart `adfssrv` to force a fresh detection cycle.

**Rollback:** N/A — this fix restores read access, it doesn't change the ACL's write permissions.
</details>

<details><summary>Fix 4 — Remediation attempt failed (Event 1136)</summary>

```powershell
# Re-check the WriteOwner/WriteDacl grant if this is WS2012/2012R2 (Fix 2b, step 3)
# For WS2016+, confirm the AD FS service account itself hasn't lost the access it needs to modify its own container:
$serviceAccount = (Get-CimInstance Win32_Service -Filter "Name='adfssrv'").StartName
Write-Host "AD FS runs as: $serviceAccount — confirm this account isn't disabled, locked, or password-expired"

# Retry by forcing another detection/remediation cycle
Restart-Service adfssrv
```

If it fails again, remediate manually via ADSI Edit or PowerShell using the target-state table in Diagnosis step 4 — set the DACL directly rather than relying on the built-in remediation task, and disable auto-remediation (`RemediateDkmAcl = 0`) until the root cause is understood, so it doesn't retry-and-fail every 24 hours generating noise.

**Rollback:** if a manual ACL edit goes wrong, restore from the pre-remediation SDDL you captured in Diagnosis step 3.
</details>

<details><summary>Fix 5 — Something broke after remediation (rare)</summary>

Only expected if a legitimate third-party tool or custom delegation had a direct ACE on the DKM container that remediation removed.

```powershell
# Restore the full security descriptor from the SDDL logged in Event 1135 (or your Diagnosis-step-3 backup)
$dn = "<DKM container DN>"
$sddl = "<Previous ACL SDDL — from Event 1135 or your saved backup file>"

$entry = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$dn")
$entry.ObjectSecurity.SetSecurityDescriptorSddlForm($sddl, [System.Security.AccessControl.AccessControlSections]::All)
$entry.CommitChanges()
$entry.Close()

# Prevent immediate re-remediation while you investigate
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ADFS' -Name 'RemediateDkmAcl' -Value 0 -Type DWord
```

Requires `SeSecurityPrivilege` (Domain Admins have this by default). Run from an elevated session on a domain-joined machine.

**Rollback of the rollback:** once the legitimate access need is re-provisioned through a supported path (not a direct DKM ACE), re-enable remediation (`RemediateDkmAcl = 1`) so the container returns to the secure baseline.
</details>

---
## Escalation Evidence

```
AD FS DKM ACL Hardening — Escalation Template
================================================
Farm identifier:              <e.g. sts.contoso.com>
Windows Server version(s):    <per node>
Patch level (KB/date):        <from Triage step 1>
DKM container DN:             <from Get-AdfsProperties CertificateSharingContainer>
Last detection event:         <1132 / 1133 / 1134, with timestamp>
RemediateDkmAcl registry value: <0 / 1 / not set>
Remediation attempted?        <Y/N — event 1135 or 1136, with timestamp>
Pre-remediation SDDL backup:  <file path, if captured>
Current date vs. Oct 13, 2026 deadline: <days remaining / past>
Symptom (if escalating a failure): <e.g. sign-in broken post-remediation, remediation failing repeatedly, detection erroring>
Business impact:              <all users / specific relying party / none yet — proactive remediation>
```

---
## 🎓 Learning Pointers
- This is a **hardening rollout with a hard enforcement date**, not a routine hotfix — the right posture is to opt in during Audit mode on your own schedule rather than let Oct 13, 2026 force it on every unpatched farm simultaneously. See [CVE-2026-56155: AD FS Distributed Key Manager container ACL hardening (KB5121391)](https://support.microsoft.com/en-us/servicing/os/windows/docs/2026/07/kb5121391-cve-2026-56155-ad-fs-dkm-container-acl-hardening).
- The vulnerability class here is the same impact tier as a stolen token-signing certificate: read access to DKM key material lets an attacker decrypt the private key and forge tokens for any user AD FS federates — a classic "Golden SAML"-style attack, except delivered via an ACL misconfiguration rather than key exfiltration from the cert store. Treat any historical 1132 finding as a potential prior-exposure question worth a security-team conversation, not just a checkbox to clear.
- Windows Server 2012/2012 R2 **never** get automatic Enforcement-mode remediation, before or after Oct 13, 2026 — if you still run AD FS on either, this is manual-forever until you upgrade the OS, and a good forcing function to finally schedule that migration.
- Event 1135 logs the *previous* (insecure) ACL in SDDL format specifically so you have a rollback path — but AD FS/Admin event logs roll over on size, so export that SDDL to a file immediately after remediation rather than assuming it'll still be there next month if you need it.
- `RemediateDkmAcl = 0` has two different meanings depending on when you set it: before Oct 13, 2026 it simply means "don't remediate yet"; after Oct 13, 2026 it's an explicit, logged opt-out of a secure default — document *why* if you set it post-Enforcement, since it will look like an oversight to a future auditor otherwise.
- Cross-reference with `ADFS-A.md` for the broader certificate/relying-party trust model this protects, and confirm token-signing certificate rollover (`AutoCertificateRollover`) is also healthy — a hardened DKM ACL doesn't help if the certificate it's protecting is already compromised via a different path.
