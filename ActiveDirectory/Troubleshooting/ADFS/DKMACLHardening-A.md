# AD FS DKM Container ACL Hardening (CVE-2026-56155) — Reference Runbook (Mode A: Deep Dive)
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

This covers the **Distributed Key Manager (DKM) container Access Control List (ACL) hardening** rollout for on-premises AD FS, tracked as [CVE-2026-56155](https://msrc.microsoft.com/update-guide/vulnerability/CVE-2026-56155) and documented in [KB5121391](https://support.microsoft.com/en-us/servicing/os/windows/docs/2026/07/kb5121391-cve-2026-56155-ad-fs-dkm-container-acl-hardening). This is a **phased security-hardening change with a published enforcement date**, not a conventional bug fix: the July 14, 2026 update introduces detection-only Audit mode, and the October 13, 2026 update flips the default to automatic remediation (Enforcement mode) on Windows Server 2016 and later.

Applies to Windows Server 2012 ESU, Windows Server 2012 R2 ESU, Windows Server 2016, Windows Server 2019, Windows Server 2022, Windows Server version 23H2, and Windows Server 2025 — any AD FS farm still receiving security updates.

Out of scope: the broader AD FS certificate lifecycle, relying party trust model, and farm topology — see `ADFS-A.md`, which this runbook assumes as prerequisite context. Also out of scope: Entra ID's own cloud-side token issuance (unaffected — this is purely an on-prem AD FS/DKM concern) and general AD object ACL hardening unrelated to the DKM container specifically (see `ActiveDirectory/_AGENT.md` for the wider AD hardening surface — AdminSDHolder, LDAP signing, PAC validation, etc.).

---
## How It Works

<details><summary>Full architecture</summary>

**What the DKM container actually is.** AD FS's Token-Signing and Token-Decrypting certificates have private keys, and those private keys are themselves encrypted at rest — AD FS doesn't store the raw private key material directly in the configuration database or on disk in a simply-readable form. Instead, it uses the **Distributed Key Manager (DKM)**, a symmetric-key wrapping mechanism that stores its own keys in a dedicated container object in Active Directory (under the AD FS service's configuration partition, identified by `(Get-AdfsProperties).CertificateSharingContainer`). When `adfssrv` starts, it reads the DKM keys from this AD container and uses them to decrypt the certificate private keys into memory. This design lets every node in a multi-node farm decrypt the same certificates without each node needing its own copy of the raw private key on local disk — the AD container is the shared secret-distribution point for the whole farm.

**The vulnerability.** The DKM container's ACL governs who can *read* those symmetric keys. If the ACL is overly permissive — a broad group like Authenticated Users was granted read access, a legacy delegation was never cleaned up, or a misconfigured GPO/script touched AD permissions upstream of the container — then **any principal with read access to the container can retrieve the DKM key material and decrypt the Token-Signing certificate's private key entirely offline**, without ever touching the AD FS servers themselves or triggering AD FS's own audit logging. With that private key, an attacker can forge SAML or WS-Federation tokens asserting any identity, for any relying party that trusts the farm — bypassing MFA, Conditional Access, and every other control that sits downstream of "AD FS says this token is valid," because from the relying party's perspective the forged token is cryptographically indistinguishable from a legitimate one. This is the same attack class publicly known as **Golden SAML**, historically associated with the SolarWinds/Nobelium campaign, except here the ACL misconfiguration is itself the delivery mechanism for the key material rather than a separate compromise of the AD FS server or configuration database.

**Why this wasn't already locked down.** AD FS has existed since Windows Server 2012, and DKM container permissions were never subject to Microsoft-enforced baseline validation — they inherited whatever the deploying admin's AD delegation model produced at install time, and drift (a broad group added for a "temporary" troubleshooting need, an over-scoped GPO, an incomplete decommission of a monitoring tool) accumulates silently over years with no built-in detection. CVE-2026-56155 formalizes both a **defined secure baseline** (the four-principal table below) and an **automated detection-and-remediation mechanism** to close that drift gap tenant-wide.

**The phased rollout mechanics:**

1. **Audit mode (July 14, 2026 update onward).** After installing, `adfssrv` runs a detection task ~1 minute after service start and every 24 hours thereafter, comparing the live DKM container ACL against the expected secure baseline. It logs Event 1132 (Warning — ACL does not match baseline) or 1133 (Information — ACL is already correct) to the `AD FS/Admin` event log. **No changes are made automatically in this phase**, regardless of what detection finds.

2. **Opt-in remediation (available throughout Audit mode).** An admin can set `HKLM\SOFTWARE\Microsoft\ADFS\RemediateDkmAcl` (DWORD) to `1` on any one farm node (the config applies farm-wide via the shared configuration database, not per-node) to enable remediation before Enforcement mode arrives. This is the recommended path specifically because it lets the org discover and resolve compatibility issues — e.g. a legitimate but undocumented service that relied on a now-removed ACE — under controlled, chosen timing rather than having remediation triggered automatically for every farm on the same October date.

3. **Enforcement mode (October 13, 2026 update onward, Windows Server 2016+).** If `RemediateDkmAcl` has not been explicitly set, the update changes the *default* behavior to remediate automatically — functionally equivalent to the registry key being `1`. Setting the key to `0` remains a supported, explicit opt-out, but from this point forward that opt-out is a deliberate, auditable decision to remain in an insecure state rather than a passive default.

4. **Windows Server 2012 / 2012 R2 — permanently manual.** These platforms cannot participate in Enforcement mode's automatic remediation at all, on any date. The reason is that automated remediation itself needs `WriteOwner`/`WriteDacl` rights on the DKM container to modify its own ACL, and on these older platforms the AD FS service account was never automatically granted that self-modification right the way newer platforms' remediation task provisions it. An admin must manually grant `WriteOwner`/`WriteDacl` to the service account first (a one-time step), then opt in via the same registry key — after which remediation behaves the same as WS2016+'s opt-in path, just never becoming a silent default.

**Remediation behavior.** When remediation runs (whether opt-in during Audit mode or automatic in Enforcement mode), it: disables ACL inheritance on the DKM container, removes every explicit Allow ACE not in the secure baseline table, and logs the prior ACL in SDDL format to Event 1135 for rollback reference before discarding it. If remediation fails for any reason (e.g. the service account itself lacks sufficient rights, or an AD replication/connectivity issue), it logs Event 1136 and retries on the next 24-hour detection cycle rather than failing silently forever.

```
                  ┌───────────────────────────────────────┐
                  │  Active Directory                      │
                  │  ┌───────────────────────────────────┐│
                  │  │  DKM container                     ││
                  │  │  (CertificateSharingContainer)     ││
                  │  │  stores: symmetric keys that        ││
                  │  │  decrypt cert private keys          ││
                  │  │  ACL: who can READ those keys       ││
                  │  └──────────────┬──────────────────────┘│
                  └─────────────────┼──────────────────────┘
                                    │ read (gated by ACL)
                                    ▼
                         adfssrv service (per farm node)
                         decrypts Token-Signing /
                         Token-Decrypting private keys
                                    │
                                    ▼
                    AD FS issues signed/encrypted tokens
                                    │
                                    ▼
                    Relying party (Entra ID / SAML app)
                    trusts the signature — cannot tell a
                    forged token (signed with a key derived
                    from leaked DKM material) from a real one
```

</details>

---
## Dependency Stack

```
Active Directory (domain, forest — DKM container lives here)
        │
        ▼
DKM container ACL  ◄── THIS TOPIC: hardening target
        │  gates read access to the symmetric key material
        ▼
AD FS Configuration Database (WID or SQL)
  stores encrypted cert private keys, decryptable only
  via DKM keys pulled from the AD container above
        │
        ▼
adfssrv service (every farm node)
  reads DKM keys at start, decrypts certs into memory
        │
        ▼
Token-Signing / Token-Decrypting certificates (live, in-memory)
        │
        ▼
Relying Party Trusts (Entra ID, SAML apps)
  trust tokens signed with the above certificate — this is
  the layer that a forged token via a leaked DKM key would exploit
```

The DKM container sits **below** the certificate layer covered in `ADFS-A.md` — a fully healthy, non-expiring, properly-rolling-over certificate provides zero protection against this specific attack path if the DKM container ACL that guards its private key is itself overly permissive. The two topics are complementary, not overlapping: `ADFS-A.md` assumes the certificate's confidentiality is intact and focuses on availability/trust-chain issues; this topic is specifically about whether that assumption holds.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Event 1132 logged repeatedly, no remediation configured | Admin hasn't opted in yet, or is deliberately waiting | Confirm `RemediateDkmAcl` registry state and current date vs. Oct 13, 2026 |
| Event 1134 (detection error) instead of 1132/1133 | AD FS service account lost LDAP read access to the DKM container, or LDAP connectivity issue | Verify service account permissions and DC reachability |
| Event 1136 (remediation failed) recurring every 24h | Service account lacks `WriteOwner`/`WriteDacl` (common on WS2012/2012R2 without the manual grant step) | Confirm platform version and whether the manual pre-grant (Fix 2b in Mode B) was completed |
| No detection events at all in the log | Server predates the July 14, 2026 update — detection isn't installed | Check patch level (`Get-HotFix`) |
| Sign-in breaks for a specific integration shortly after remediation | A legitimate direct ACE (monitoring/backup tooling) on the DKM container was removed as part of baseline enforcement | Compare pre- and post-remediation SDDL; re-provision that tool's access through a supported path, not a direct ACE |
| Security team asks "were we ever exposed, and for how long" | This is a forensic/retrospective question distinct from remediation itself | Correlate the farm's patch history against Event 1132 first-occurrence timestamps and any available AD object ACL change history (if auditing was enabled on the container) |
| WS2012/2012R2 farm shows Enforcement-era default behavior expectations but nothing changed | Expected — Enforcement mode never applies automatic remediation to these platforms | Manual remediation only (Fix 2b); flag for OS upgrade planning |

---
## Validation Steps

1. **Confirm detection is running and current.**
   ```powershell
   Get-WinEvent -LogName 'AD FS/Admin' -FilterXPath "*[System[(EventID=1132 or EventID=1133)]]" -MaxEvents 1 |
       Select-Object TimeCreated, Id
   ```
   Good: an event within the last 24-25 hours. Bad: nothing found, or the most recent event is older than ~25 hours with the service running — detection may have stalled; restart `adfssrv` and recheck.

2. **Confirm the live ACL matches the secure baseline directly**, independent of what AD FS's own event log reports (a second, independent check).
   ```powershell
   $dkmDn = (Get-AdfsProperties).CertificateSharingContainer
   $acl = (Get-Acl "AD:\$dkmDn")
   $acl.Access | Where-Object { $_.AccessControlType -eq 'Allow' } |
       Select-Object IdentityReference, ActiveDirectoryRights
   ```
   Good: only Domain Admins, Enterprise Admins, SYSTEM, and the AD FS service account appear, matching the rights table in the How It Works section. Bad: any additional principal, or a principal with rights beyond what's expected for its row.

3. **Confirm inheritance is disabled**, a required part of the secure baseline, not just the principal list.
   ```powershell
   $acl.AreAccessRulesProtected
   ```
   Good: `True` (protected/inheritance-disabled). Bad: `False` — even a correct-looking principal list with inheritance still enabled means a parent-container ACL change could silently reintroduce over-permissive access later.

4. **Confirm the registry opt-in/opt-out state is intentional, not accidental**, especially post-Enforcement.
   ```powershell
   $val = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ADFS' -Name 'RemediateDkmAcl' -ErrorAction SilentlyContinue
   if ($val) { "RemediateDkmAcl = $($val.RemediateDkmAcl)" } else { "Not set — using platform default for current date" }
   ```
   If the value is `0` and the date is on/after October 13, 2026, treat this as a flagged finding requiring documented justification, not a neutral default.

5. **For farms with a legitimate direct DKM ACE requirement** (rare — e.g. a bespoke backup/monitoring integration), confirm that access has been re-architected through a supported indirect path (membership in Domain Admins-delegated tooling, or a scheduled task running as the AD FS service account itself) rather than expecting a direct ACE to survive remediation.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Inventory and current-state assessment (do this first, farm-wide)**

- Enumerate every AD FS farm and every node's OS version and patch level — this determines which of the three remediation paths (WS2016+ opt-in, WS2016+ Enforcement-default, or WS2012/2012R2 manual) applies to each.
- Pull the current DKM container ACL for each farm via Validation step 2, independent of event-log state, since a farm that's never been restarted since patching may not have run detection yet.
- Identify any third-party tooling with a plausible reason to hold a direct DKM ACE (backup software, security monitoring agents that read AD FS configuration directly) before remediating anywhere — this is the one category of "legitimate compatibility issue" this rollout is explicitly designed to surface.

**Phase 2 — Audit-mode remediation (target: complete before October 13, 2026)**

- Opt in via `RemediateDkmAcl = 1` on WS2016+ farms per Mode B Fix 2, on a maintenance window if the org prefers, though remediation itself does not require an outage — the DKM keys and certificates already in memory are unaffected, only the container's ACL changes.
- Complete the manual `WriteOwner`/`WriteDacl` pre-grant for any WS2012/2012R2 farm nodes before attempting remediation there (Mode B Fix 2b) — remediation will fail with Event 1136 without it.
- Capture and archive the pre-remediation SDDL from Event 1135 for every farm, outside the AD FS event log itself (which rolls over), as a durable rollback record.

**Phase 3 — Post-remediation validation and monitoring**

- Re-run Validation steps 2 and 3 against the live ACL after each remediation to confirm the baseline was actually achieved, not just that Event 1135 was logged.
- Monitor for any access-denied symptoms in dependent tooling over the following days/weeks — a direct-ACE dependency may not surface immediately if the tool only polls infrequently.
- For farms deliberately left on `RemediateDkmAcl = 0` past October 13, 2026, schedule a recurring review (quarterly, minimum) rather than treating the opt-out as a one-time decision — it should be revisited as compatibility blockers get resolved.

**Phase 4 — Retrospective exposure assessment (security-driven, optional but recommended for higher-sensitivity environments)**

- If AD object-level auditing was enabled on the DKM container prior to this rollout, review Directory Service Access audit events for read operations against it, cross-referenced against the list of principals that historically had access beyond the secure baseline — this can reveal whether the historical over-permissive ACL was ever actually exercised by an unexpected principal, not just theoretically present.
- If no such auditing exists, this question generally cannot be answered retroactively — treat the finding as "risk window closed," not "confirmed no exposure occurred," and communicate that distinction accurately to stakeholders.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Standard opt-in remediation, single farm, Windows Server 2016+</summary>

```powershell
# 1. Snapshot current ACL for rollback record
$dkmDn = (Get-AdfsProperties).CertificateSharingContainer
(Get-Acl "AD:\$dkmDn").Sddl | Out-File "C:\ADFSBackup\dkm-pre-$(Get-Date -Format yyyyMMdd-HHmm).sddl.txt"

# 2. Opt in on one farm node
if (-not (Test-Path 'HKLM:\SOFTWARE\Microsoft\ADFS')) {
    New-Item -Path 'HKLM:\SOFTWARE\Microsoft' -Name 'ADFS' -Force | Out-Null
}
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ADFS' -Name 'RemediateDkmAcl' -Value 1 -PropertyType DWord -Force

# 3. Trigger immediately rather than waiting for the 24h cycle
Restart-Service adfssrv
Start-Sleep -Seconds 90

# 4. Confirm success
Get-WinEvent -LogName 'AD FS/Admin' -MaxEvents 5 | Where-Object { $_.Id -in 1135,1136 } | Format-List TimeCreated, Id, Message

# 5. Independently verify the live ACL (don't just trust the event log)
(Get-Acl "AD:\$dkmDn").Access | Where-Object AccessControlType -eq 'Allow' | Select-Object IdentityReference, ActiveDirectoryRights
```

**Rollback:** restore from the SDDL captured in step 1 using `SetSecurityDescriptorSddlForm` (see Mode B Fix 5), then set `RemediateDkmAcl = 0` to prevent immediate re-remediation while investigating.
</details>

<details><summary>Playbook 2 — Windows Server 2012/2012 R2, manual permission grant then remediate</summary>

```powershell
$dkmContainerDn = (Get-AdfsProperties).CertificateSharingContainer
$serviceAccount = (Get-CimInstance Win32_Service -Filter "Name='adfssrv'").StartName

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

if (-not (Test-Path 'HKLM:\SOFTWARE\Microsoft\ADFS')) {
    New-Item -Path 'HKLM:\SOFTWARE\Microsoft' -Name 'ADFS' -Force | Out-Null
}
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ADFS' -Name 'RemediateDkmAcl' -Value 1 -PropertyType DWord -Force
Restart-Service adfssrv
```

**Rollback:** if the manual `WriteOwner`/`WriteDacl` grant itself needs reverting (e.g. remediation isn't going to proceed after all), remove that specific ACE via `$entry.ObjectSecurity.RemoveAccessRule($rule)` / `$entry.CommitChanges()` using the same `$rule` object, before it's committed elsewhere. Once actual DKM remediation has run, use the Event-1135 SDDL restore path (Mode B Fix 5) rather than trying to reverse this preliminary step.
</details>

<details><summary>Playbook 3 — Fleet-wide rollout across multiple farms (MSP / multi-tenant)</summary>

```powershell
# Run from a management workstation with AD FS PowerShell module and rights on each target farm's node
$farms = @(
    @{ Node = 'adfs01.contoso.com' },
    @{ Node = 'adfs01.fabrikam.com' }
    # add one entry per farm — only one node per farm needed, config is farm-wide
)

foreach ($farm in $farms) {
    Invoke-Command -ComputerName $farm.Node -ScriptBlock {
        $dkmDn = (Get-AdfsProperties).CertificateSharingContainer
        (Get-Acl "AD:\$dkmDn").Sddl | Out-File "C:\ADFSBackup\dkm-pre-$(Get-Date -Format yyyyMMdd-HHmm).sddl.txt"

        if (-not (Test-Path 'HKLM:\SOFTWARE\Microsoft\ADFS')) {
            New-Item -Path 'HKLM:\SOFTWARE\Microsoft' -Name 'ADFS' -Force | Out-Null
        }
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ADFS' -Name 'RemediateDkmAcl' -Value 1 -PropertyType DWord -Force
        Restart-Service adfssrv
        Start-Sleep -Seconds 90
        Get-WinEvent -LogName 'AD FS/Admin' -MaxEvents 3 | Where-Object { $_.Id -in 1135,1136 } |
            Select-Object @{N='ComputerName';E={$env:COMPUTERNAME}}, TimeCreated, Id, Message
    } -ErrorAction Continue
}
```

Deliberately does **not** attempt the WS2012/2012R2 manual pre-grant automatically — that platform check and the AD-permission-granting step should stay a reviewed, per-farm manual action rather than a scripted bulk operation, since it modifies AD delegation directly.

**Rollback:** per-farm, using each farm's own captured SDDL file, following the Mode B Fix 5 procedure.
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS    Collects AD FS DKM container ACL hardening state for escalation or audit.
.DESCRIPTION Read-only. Run on a farm node with AD FS PowerShell module and the ActiveDirectory
             module available. Does not modify the DKM container or the registry.
#>
$out = [ordered]@{}
$out.HostName        = $env:COMPUTERNAME
$out.OSCaption       = (Get-CimInstance Win32_OperatingSystem).Caption
$out.RelevantHotfix  = Get-HotFix | Where-Object { $_.InstalledOn -ge '2026-07-14' } | Select-Object -First 1 HotFixID, InstalledOn
$out.RemediateDkmAcl = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ADFS' -Name 'RemediateDkmAcl' -ErrorAction SilentlyContinue).RemediateDkmAcl
$dkmDn               = (Get-AdfsProperties).CertificateSharingContainer
$out.DkmContainerDn  = $dkmDn
$acl                 = Get-Acl "AD:\$dkmDn"
$out.InheritanceDisabled = $acl.AreAccessRulesProtected
$out.CurrentAllowAces = $acl.Access | Where-Object AccessControlType -eq 'Allow' |
    Select-Object IdentityReference, ActiveDirectoryRights
$out.RecentDkmEvents = Get-WinEvent -LogName 'AD FS/Admin' -FilterXPath "*[System[(EventID=1132 or EventID=1133 or EventID=1134 or EventID=1135 or EventID=1136)]]" -MaxEvents 10 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, Message
$out | ConvertTo-Json -Depth 5 | Out-File ".\ADFS-DKMACL-EvidencePack-$(Get-Date -Format yyyyMMdd-HHmm).json"
Write-Host "Evidence pack written." -ForegroundColor Green
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `(Get-AdfsProperties).CertificateSharingContainer` | Returns the DKM container's distinguished name |
| `Get-Acl "AD:\<DKM DN>"` | Reads the live DKM container ACL via the AD PowerShell provider |
| `Get-WinEvent -LogName 'AD FS/Admin'` (filter EventID 1132-1136) | DKM detection/remediation event history |
| `Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ADFS' -Name RemediateDkmAcl` | Current opt-in/opt-out registry state |
| `New-ItemProperty ... RemediateDkmAcl -Value 1` | Opt in to remediation |
| `Set-ItemProperty ... RemediateDkmAcl -Value 0` | Opt out / pause remediation |
| `Restart-Service adfssrv` | Forces an immediate detection/remediation cycle instead of waiting up to 24h |
| `Get-HotFix` | Confirms whether the July 2026 (Audit) or October 2026 (Enforcement) update is installed |
| `(Get-CimInstance Win32_Service -Filter "Name='adfssrv'").StartName` | Identifies the AD FS service account for manual ACE grants |
| `$entry.ObjectSecurity.SetSecurityDescriptorSddlForm($sddl, ...)` | Restores a prior ACL from a saved SDDL string |
| `Get-AdfsCertificate` | Confirms the certificate layer this ACL protects (cross-reference with `ADFS-A.md`) |

---
## 🎓 Learning Pointers
- Read the primary source directly rather than relying on summaries — this KB is dense and precise about exact registry paths, event IDs, and platform-specific behavior differences that matter for correct remediation: [CVE-2026-56155: AD FS Distributed Key Manager container ACL hardening (KB5121391)](https://support.microsoft.com/en-us/servicing/os/windows/docs/2026/07/kb5121391-cve-2026-56155-ad-fs-dkm-container-acl-hardening).
- This is a good case study in the difference between "vulnerability disclosed" and "vulnerability exploitable here": CVE-2026-56155 describes a *possible* over-permissive default/drift state, not a guaranteed one — the actual risk in any given farm depends entirely on that farm's specific ACL history, which is exactly why the Audit-mode detection phase exists rather than Microsoft simply publishing a one-time cleanup script.
- The DKM key-wrapping architecture (symmetric keys in AD, protecting asymmetric cert private keys, so every farm node can decrypt without a locally-held copy) is the same general pattern .NET's `DPAPI-NG`/`CredSSP`-adjacent designs use for other Windows Server multi-node secret-sharing scenarios — recognizing the pattern helps when reasoning about *why* an AD container (rather than a local cert store) is the right architectural home for this key material.
- "Golden SAML" as an attack technique is broader than this one CVE — this hardening closes one specific delivery path (ACL-based DKM key exfiltration) but does not address other paths to the same outcome (e.g. an attacker with Domain Admin rights, who could always read DKM key material by design, since Domain Admins is in the secure baseline itself). Don't present this remediation as closing Golden SAML risk entirely — it closes the *unauthorized, sub-Domain-Admin* exposure path specifically. See MITRE ATT&CK's [Forge Web Credentials: SAML Tokens (T1606.002)](https://attack.mitre.org/techniques/T1606/002/) for the broader technique context.
- Windows Server 2012/2012 R2's permanent exclusion from automatic Enforcement is a useful, concrete data point for any "why are we still paying for ESU on this box" conversation — pair it with the fact that ESU covers security patches but clearly does not backport every hardening *mechanism*, only the vulnerability's patch where feasible.
- For the certificate and relying-party trust layer this ACL protects, and for general AD FS farm health troubleshooting unrelated to this specific hardening effort, see `ADFS-A.md` and `ADFS-B.md` in this same folder.
