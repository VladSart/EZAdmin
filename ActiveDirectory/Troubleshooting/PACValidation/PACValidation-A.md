# PAC Requestor Validation / sAMAccountName Spoofing (noPac) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---
## Skim Index (with jump links)
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

This topic covers the Kerberos PAC (Privileged Attribute Certificate) requestor-validation hardening Microsoft shipped in November 2021 and made permanently mandatory in October 2022, and the attack chain it closes: **CVE-2021-42278** (sAMAccountName spoofing on computer accounts) chained with **CVE-2021-42287** (KDC name-confusion / PAC construction gap), publicly known as **noPac**. The chain let a standard, unprivileged domain user escalate to full domain compromise using only default AD permissions — no existing admin rights, no social engineering, no malware.

This is **not** the same control as:
- **Certificate-Based Authentication Mapping (KB5014754)** — a separate hardening for PKINIT/Schannel certificate-to-account binding (see `Troubleshooting/CertificateMapping/`). Both are KDC-side hardening items shipped around the same era, but they protect different authentication paths (certificate mapping vs. standard Kerberos PAC construction) and are tracked by entirely different CVEs and registry keys.
- **LDAP Signing / Channel Binding** (see `Troubleshooting/LDAPSigning/`) — protects the LDAP bind path, not Kerberos ticket issuance.
- **Kerberos Delegation abuse** (unconstrained/constrained/RBCD, see `Troubleshooting/KerberosDelegation/`) — a related but architecturally distinct privilege-escalation surface. A pentest report may bundle delegation findings and noPac findings together; they require separate remediation.
- **AdminSDHolder/SDProp** (see `Troubleshooting/AdminSDHolder/`) — ACL enforcement on already-privileged accounts; noPac is about an *unprivileged* account acquiring privilege in the first place.

Assumes: a standard multi-DC AD forest, at least one domain running functional level 2008 or higher (no functional-level gate applies to this particular hardening, unlike Kerberos Armoring), and a mix of Windows and possibly non-Windows Kerberos clients (NAS appliances, Linux/Samba hosts, network devices).

---
## How It Works

<details><summary>Full architecture</summary>

**The pre-patch vulnerability chain:**

1. **CVE-2021-42278 (sAMAccountName spoofing).** Active Directory's validation of a computer account's `sAMAccountName` attribute was insufficiently strict. A standard domain user with the default `ms-DS-MachineAccountQuota` (10, unless already hardened to 0) can create a computer object, then rename its `sAMAccountName` to strip the trailing `$` and match the name of an existing account — including a Domain Controller's own computer account name. AD did not block this rename or detect the resulting name collision the way it should have.

2. **CVE-2021-42287 (KDC name confusion).** When a client requests a Ticket Granting Ticket (TGT) using an identity that doesn't cleanly resolve, the KDC's fallback name-resolution logic, combined with a gap in how the PAC was constructed for the resulting ticket, could produce a TGT that — when subsequently used to request a service ticket — carried privilege associated with the impersonated account rather than the actual (unprivileged) requestor. Chained with step 1's DC-name impersonation, this let the attacker obtain a ticket effectively equivalent to Domain Controller privilege, enabling DCSync-style extraction of every credential hash in the domain.

**The fix — PAC_REQUESTOR and enforcement:**

The November 9, 2021 update (KB5008380 / KB5008602, addressing CVE-2021-42287; a companion update hardens the sAMAccountName validation for CVE-2021-42278) introduced two new PAC data structures: `PAC_ATTRIBUTES_INFO` and `PAC_REQUESTOR`. `PAC_REQUESTOR` carries the SID of the account that actually originated the request. From that point forward, when a client and the KDC servicing it are in the **same domain**, the KDC validates that the client name (`cname`) presented resolves to the **same SID** as the one embedded in `PAC_REQUESTOR`. A mismatch causes the KDC to reject/revoke the ticket outright — the spoofing step in CVE-2021-42278 no longer produces a usable elevated ticket, because the identity claimed by the ticket and the identity that actually asked for it are cryptographically tied together and checked.

**Deployment phases (this is the same three-phase rollout pattern Microsoft has used for other post-issuance AD security hardening, including the Certificate Mapping/KB5014754 hardening elsewhere in this folder):**

| Phase | Date | Behavior |
|---|---|---|
| Initial Deployment | Nov 9, 2021 update | DCs begin adding `PAC_REQUESTOR`/`PAC_ATTRIBUTES_INFO` to issued TGTs. Validation is **not yet mandatory** — compatibility mode, controlled by the `PACRequestorEnforcement` registry value (`HKLM\SYSTEM\CurrentControlSet\Services\Kdc`, DWORD). `0` = disabled/reverted, `1` = deployment/compatibility default (validate only if the new structure is present), `2` = enforcement (opt in early). |
| Second Deployment | Jul 12, 2022 update | The `0` (fully disabled) setting is removed from supported behavior — compatibility narrows ahead of full enforcement. |
| Enforcement | Oct 11, 2022 update, and permanently thereafter | Enforcement (equivalent to the old value `2`) becomes the unconditional default on every patched DC. `PACRequestorEnforcement` is deprecated — the KDC simply stops reading it. There is no supported registry path to revert this behavior on a current DC. |

By 2026, every phase above is years in the past. Any DC patched since October 2022 enforces PAC_REQUESTOR validation unconditionally — this hardening is now baseline, permanent behavior, not an optional setting to check or tune.

**Diagnostic events (Directory-Services-Kerberos-Key-Distribution-Center / Operational log)** introduced alongside the structures, useful mainly for forensic log review or diagnosing a legacy client breakage rather than for tuning enforcement itself:

| Event ID | Name | Meaning |
|---|---|---|
| 35 | PAC without Attributes | `PAC_ATTRIBUTES_INFO` structure missing from the PAC. |
| 36 | Ticket without a PAC | A service ticket was requested with no PAC present at all. |
| 37 | Ticket without Requestor | A service ticket was requested but `PAC_REQUESTOR` was missing. |
| 38 | Requestor Mismatch | `PAC_REQUESTOR` was present but the client name did not resolve to the SID it carried — the exact condition the hardening is designed to catch. |

**Scope limitation:** the cname-to-PAC_REQUESTOR-SID validation applies **only when the client and the servicing KDC are in the same domain**. Cross-trust scenarios — a forged (golden) ticket presented across a trust boundary for a non-existent account — are not covered by this specific check, since the validating DC cannot authoritatively resolve an identity that belongs to a different domain's directory. This is a real, documented scope boundary, not an implementation bug — don't represent this control as closing every Kerberos forgery vector in a security assessment response.

</details>

---
## Dependency Stack

```
Domain functional level (any supported level — no functional-level gate on this hardening,
  unlike Kerberos Armoring's Server 2012 requirement)
  └── Every DC patched with the November 2021+ cumulative update (KB5008380/KB5008602 or later)
        └── PAC_REQUESTOR/PAC_ATTRIBUTES_INFO structures populated on every issued TGT
              └── (same-domain client/KDC only) cname-to-PAC_REQUESTOR-SID validation enforced
                    └── Mismatched ticket rejected — breaks the CVE-2021-42278 spoofing step
                          before it can be leveraged into the CVE-2021-42287 privilege gain
  (independent, parallel hardening layer — not itself patched by the above)
  └── ms-DS-MachineAccountQuota controls whether the FIRST step (creating a spoofable
      computer object at all) is even possible for an unprivileged user — default 10,
      recommended hardened value 0 with delegated provisioning instead
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Pentest/vuln scan flags "sAMAccountName spoofing possible" or "noPac" | One or more DCs missing the Nov 2021+ cumulative update | `Get-ADDomainController -Filter * \| Select OperatingSystemVersion` — compare build against KB5008380 baseline |
| Same finding, but all DCs confirmed patched | Scanner is flagging `ms-DS-MachineAccountQuota` > 0 as a *precondition* risk, not confirming actual exploitability | Check quota value; this is a hardening recommendation, not proof of vulnerability on a patched domain |
| Legacy NAS/Linux/Samba/network-appliance Kerberos auth broke after a DC patch cycle | Non-Windows client doesn't construct/send `PAC_REQUESTOR` — breaks once the domain's DCs are in Enforcement | Correlate failure timing with Events 35/37/38 for that client's source IP/service account |
| Unexplained new computer object with a renamed sAMAccountName resembling a DC | Active or attempted noPac exploitation | Correlate Event 4741 (creation) with Event 4781 (rename) on the same object, tight time window |
| Golden ticket forged for a non-existent user still works across a trust | Expected scope boundary — same-domain-only validation, not a bug | Confirm the ticket was presented cross-trust; document as a known limitation, not a regression |
| `PACRequestorEnforcement` registry value present and non-zero on a modern (2022+) DC | Leftover from the transition window — harmless, key is no longer read | No action needed; safe to leave or clean up during general hygiene |

---
## Validation Steps

1. **Confirm patch baseline across every DC.**
   ```powershell
   Get-ADDomainController -Filter * | ForEach-Object {
       Get-HotFix -Id KB5008380 -ComputerName $_.HostName -ErrorAction SilentlyContinue
   }
   ```
   Good: every DC returns a hotfix entry (or a later cumulative superseding it). Bad: any DC returns nothing — that DC is exploitable today.

2. **Confirm Enforcement is active (implicit on any Oct 2022+ build — this step is mainly for DCs patched in the Nov 2021–Oct 2022 window or for documentation completeness).**
   ```powershell
   Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Kdc" -Name PACRequestorEnforcement -ErrorAction SilentlyContinue
   ```
   Good: absent (key retired, Enforcement is unconditional) or explicitly `2`. Bad: explicitly `0` on an old, still-in-transition-window build — close this immediately, it disables the protection entirely.

3. **Review `ms-DS-MachineAccountQuota`.**
   ```powershell
   Get-ADObject (Get-ADDomain).DistinguishedName -Properties ms-DS-MachineAccountQuota
   ```
   Good: `0`, with a documented delegated-provisioning process in its place. Acceptable-but-notable: default `10`. Bad: raised above default with no compensating monitoring.

4. **Sweep the Security log for the attack signature over a meaningful retention window (30–90 days if available).**
   ```powershell
   Get-WinEvent -LogName Security -FilterXPath "*[System[(EventID=4741 or EventID=4781)]]" -MaxEvents 500 |
       Group-Object { $_.Properties[0].Value } | Where-Object Count -gt 1
   ```
   Good: no computer object shows both a creation and a rename event from a non-provisioning actor. Bad: any such correlation — escalate as a possible incident (see Mode B Fix 3).

---
## Troubleshooting Steps (by phase)

**Phase 1 — Confirm exposure.** Patch level sweep + MachineAccountQuota check (Validation Steps 1 and 3). This alone tells you whether a pentest finding reflects an actual live gap or a hardening-recommendation-level finding on an already-patched domain.

**Phase 2 — Rule out active exploitation.** Event 4741/4781 correlation sweep (Validation Step 4) before doing anything else — patching and quota changes don't undo damage that may have already occurred.

**Phase 3 — Isolate legacy-client breakage, if reported.** Confirm the affected system is genuinely non-Windows or a very old Windows/Samba-based appliance; correlate KDC operational log Events 35/37/38 against that system's authentication attempts specifically. Do not chase this as a DC-side misconfiguration — it is a client-side protocol gap that only a vendor update resolves.

**Phase 4 — Remediate.** Patch any lagging DC, harden MachineAccountQuota, and (if Phase 2 found evidence) run incident response per Remediation Playbook 2 below.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Close a fresh pentest/vuln-scan finding</summary>

1. Run Validation Steps 1–3 and capture output as evidence.
2. Patch any DC found lagging; reboot; re-verify with `Get-HotFix`.
3. Harden `ms-DS-MachineAccountQuota` to `0` (see Mode B Fix 4) unless a documented business process depends on self-service computer object creation — in that case, note the accepted-risk decision explicitly in the response rather than silently leaving it.
4. Deliver the evidence pack (below) as the closure artifact — auditors and pentest firms generally want proof of patch level and quota configuration, not just an assertion.

</details>

<details><summary>Playbook 2 — Suspected or confirmed exploitation (incident response)</summary>

1. Contain: disable the suspect computer/user account immediately (`Disable-ADAccount`). Do not delete — you need it for forensics.
2. Invalidate outstanding tickets: reset the `krbtgt` password **twice**, allowing full replication convergence between resets. A single reset is insufficient — Kerberos ticket validity windows mean a second reset is required to guarantee all forged/elevated tickets are invalidated.
3. Hunt for downstream impact: any new privileged group membership changes, new/modified GPOs, new trust relationships, or DCSync-pattern replication requests (`Get-ADReplicationAttributeMetadata` anomalies, unusual `Directory Service Changes` audit events) in the incident window.
4. Close the entry point: patch (Playbook 1, step 2) and harden MachineAccountQuota (step 3).
5. Root-cause and after-action: document how the account was compromised in the first place (this hardening prevents the *escalation*, not the initial unprivileged foothold) — noPac is a post-compromise privilege-escalation technique, not an initial-access vector.

</details>

<details><summary>Playbook 3 — Vendor remediation for a broken legacy Kerberos client</summary>

1. Confirm scope: identify every legacy/non-Windows system authenticating via Kerberos against this domain (NAS appliances, older SIEM/monitoring collectors, print/scan appliances, some Linux/Samba file servers).
2. For each, check vendor documentation/support for a `PAC_REQUESTOR`-aware firmware or software update — this is the only durable fix, since Enforcement on the DC side is permanent and unconditional.
3. If no fix is available and the system is business-critical, evaluate a non-Kerberos authentication path for that specific integration (local accounts, LDAPS simple bind, a modern replacement product) as an interim or permanent measure — do not attempt to "fix" this by degrading DC-side enforcement; there is no supported mechanism to do so on a current build.
4. Track each affected system to closure; this class of finding tends to recur with every legacy-appliance refresh cycle, so document it for future hardware/software lifecycle planning.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS Collects noPac/PAC-validation posture evidence for escalation or audit response.
#>
$report = [ordered]@{
    GeneratedAt = Get-Date
    Domain = (Get-ADDomain).DNSRoot
    MachineAccountQuota = (Get-ADObject (Get-ADDomain).DistinguishedName -Properties ms-DS-MachineAccountQuota).'ms-DS-MachineAccountQuota'
    DomainControllers = Get-ADDomainController -Filter * | ForEach-Object {
        [PSCustomObject]@{
            HostName = $_.HostName
            OSVersion = $_.OperatingSystemVersion
            KB5008380Present = [bool](Get-HotFix -Id KB5008380 -ComputerName $_.HostName -ErrorAction SilentlyContinue)
        }
    }
    Recent4741 = Get-WinEvent -LogName Security -FilterXPath "*[System[(EventID=4741)]]" -MaxEvents 200 -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, @{n='Actor';e={$_.Properties[4].Value}}, @{n='NewComputer';e={$_.Properties[0].Value}}
    Recent4781 = Get-WinEvent -LogName Security -FilterXPath "*[System[(EventID=4781)]]" -MaxEvents 200 -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, @{n='OldName';e={$_.Properties[1].Value}}, @{n='NewName';e={$_.Properties[2].Value}}
}
$report | ConvertTo-Json -Depth 4
```
(See also `Scripts/Get-PACValidationAudit.ps1` for the standalone, packaged version of this collection with CSV export.)

---
## Command Cheat Sheet

```powershell
# Patch level per DC
Get-ADDomainController -Filter * | Select HostName, OperatingSystemVersion
Get-HotFix -Id KB5008380 -ComputerName <dc>

# MachineAccountQuota — read and harden
Get-ADObject (Get-ADDomain).DistinguishedName -Properties ms-DS-MachineAccountQuota
Set-ADObject -Identity (Get-ADDomain).DistinguishedName -Replace @{'ms-DS-MachineAccountQuota' = 0}

# Registry enforcement state (legacy/transition-window builds only)
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Kdc" -Name PACRequestorEnforcement -ErrorAction SilentlyContinue

# Attack signature sweep
Get-WinEvent -LogName Security -FilterXPath "*[System[(EventID=4741)]]"
Get-WinEvent -LogName Security -FilterXPath "*[System[(EventID=4781)]]"

# KDC operational diagnostic events (Enforcement-era client compatibility issues)
Get-WinEvent -LogName "Microsoft-Windows-Kerberos-Key-Distribution-Center/Operational" |
    Where-Object { $_.Id -in 35,36,37,38 }

# Incident response — krbtgt double reset (space apart for replication convergence)
Set-ADAccountPassword -Identity krbtgt -Reset -NewPassword (ConvertTo-SecureString -AsPlainText "<temp>" -Force)

# Delegate computer-object creation to a specific group/OU instead of quota-wide self-service
dsacls "OU=<Target>,DC=<domain>,DC=<tld>" /I:S /G "<DOMAIN>\<Group>:CC;computer"
```

---
## 🎓 Learning Pointers

- Primary source: [KB5008380 — Authentication updates (CVE-2021-42287)](https://support.microsoft.com/en-us/topic/kb5008380-authentication-updates-cve-2021-42287-9dafac11-e0d0-4cb8-959a-143bd0201041) — the phased-rollout structure, registry key behavior, and enforcement timeline.
- Community deep dive on the registry key values, the full Event ID table (35/36/37/38), and Golden Ticket implications: [Netwrix — PACRequestorEnforcement and Kerberos Authentication](https://netwrix.com/en/resources/blog/pacrequestorenforcement-and-kerberos-authentication/).
- This is the third Microsoft AD hardening in this folder that follows the same "phased rollout → permanent unconditional enforcement, several years later" pattern — compare against `Troubleshooting/CertificateMapping/` (KB5014754) and `Troubleshooting/LDAPSigning/`. Recognizing this pattern helps triage similar future advisories: expect a compatibility window, then a point of no return.
- `ms-DS-MachineAccountQuota` hardening is the single highest-value, lowest-effort companion action to patching — it removes the *precondition* for step one of the chain (and several other AD attack techniques that also rely on unrestricted computer-object creation), independent of patch level.
- Remember the scope boundary: same-domain client/KDC only. Don't overstate this control's coverage in a security assessment response — cross-trust forged-ticket scenarios need separate mitigations (SID filtering/selective authentication, see `Troubleshooting/Trusts/`).
- noPac is one of the most consistently re-discovered findings in AD security assessments years after patching, precisely because the underlying preconditions (unpatched DCs somewhere in a large estate, default MachineAccountQuota) are common defaults that nobody revisits without a reason to look.
