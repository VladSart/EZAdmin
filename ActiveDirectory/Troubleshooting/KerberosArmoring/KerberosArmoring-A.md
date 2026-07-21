# Kerberos Armoring (FAST) — Reference Runbook (Mode A: Deep Dive)
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
- Kerberos Armoring / FAST (Flexible Authentication Secure Tunneling) — the Windows Server 2012+ extension that wraps the pre-authentication exchange in an encrypted, integrity-protected "armor" channel
- The three governing GPOs (two client-side, one KDC-side) and the domain-functional-level gate that determines whether stricter enforcement options actually take effect
- Armoring as a prerequisite for Dynamic Access Control (claims-based authorization, compound/user+device authentication) and AD FS device claims
- Diagnosing intermittent, DC-dependent failures caused by mixed-OS-version domain controllers

**Out of scope:**
- Dynamic Access Control configuration itself — Central Access Policies, claim type definitions, resource property lists, and file classification. This topic covers only the Kerberos-layer prerequisite DAC depends on, not DAC's own policy authoring and enforcement
- Windows Hello for Business Cloud Kerberos Trust and Microsoft Entra Kerberos — an architecturally separate feature that uses Entra ID as a Kerberos trust anchor for hybrid passwordless SSO scenarios; shares the word "Kerberos" and nothing else with this topic's on-prem KDC-side armoring feature
- AD FS relying party trust, claims rule authoring, and federation troubleshooting generally — see `Troubleshooting/ADFS/ADFS-A.md`; this topic covers only the fact that AD FS device claims require a working armored Kerberos exchange as a prerequisite, not AD FS configuration itself
- NTLM relay mitigations (LDAP signing, certificate mapping, NTLM relay to AD CS) — architecturally unrelated hardening topics that happen to also live in the Kerberos/NTLM neighborhood; see `Troubleshooting/LDAPSigning/`, `Troubleshooting/CertificateMapping/`, and `Windows/Troubleshooting/NTLMRelayADCS-A.md`

**Assumptions:**
- Domain controllers are Windows Server 2016 or later (all currently-supported DC OS versions natively support armoring; the domain-functional-level gate, not the DC OS version, is the practical constraint in most environments today)
- You have access to Group Policy Management and the ability to run `gpresult` on both DCs and affected client machines
- No `pwsh`/live lab environment was available to execute-test the commands in this runbook against a real domain functional level transition; every command here is standard, well-documented PowerShell/AD-module syntax, but always test a `Set-ADDomainMode` change's blast radius in a non-production forest first if at all possible

---
## How It Works

<details><summary>Full architecture — why armoring exists and what it actually protects</summary>

### The Problem It Addresses

A standard Kerberos AS-REQ (the initial "I want a Ticket Granting Ticket" request) includes a pre-authentication data block, typically a timestamp encrypted with a key derived from the requesting user's long-term secret (their password hash). This exchange happens in the clear, over the network, before any session-level protection exists — there is no established secure channel yet at this point in the protocol, because establishing that channel is exactly what the exchange is for. That creates two related exposure classes: an on-path observer can potentially collect material useful for later offline analysis, and — because the exchange itself isn't integrity-protected end-to-end before armoring — the KDC has no independently verifiable way to confirm the pre-authentication data hasn't been tampered with in transit.

Kerberos Armoring (FAST) closes this by wrapping the entire pre-authentication conversation inside a second, already-established Kerberos session — the "armor" — built from the requesting **computer's own machine account ticket** (its machine TGT). Because the computer already holds a valid TGT from a prior, independent authentication (its own domain join/machine logon), that ticket's session key can be used to encrypt and sign the *user's* pre-authentication exchange, giving the user-level exchange the same cryptographic protection the machine's own authentication already had. This is why armoring is sometimes described as "a TGT protecting the TGT request" — it's a chained trust: the device authenticates first (machine TGT), and that established trust then shields the user's subsequent authentication.

### Why This Matters Beyond Plain Sign-In

Armoring isn't purely a confidentiality/integrity hardening measure for its own sake — it's the **foundational transport** a set of higher-level Windows Server identity features are built on top of:

- **Dynamic Access Control (DAC)** — claims-based authorization (user claims, device claims, resource properties) requires the claims to be carried inside an armored exchange, since claims data needs the same tamper-protection the armor channel provides
- **Compound authentication** — the ability for a KDC to evaluate *both* the user's identity *and* the device's identity together in a single authorization decision (used by DAC and some Conditional Access-adjacent on-prem scenarios) structurally depends on the armored channel to carry both identities' claims safely
- **AD FS device claims** — when AD FS issues claims based on the requesting device's identity/compliance state (not just the user), that device claim similarly depends on a working armored Kerberos exchange as its transport

If any of those three scenarios fail, and the underlying Kerberos armoring configuration is misconfigured or gated by domain functional level, the DAC/compound-auth/AD FS-device-claims layer will fail in ways that look like a policy authoring problem but are actually a transport prerequisite problem — always confirm armoring itself first (Validation Steps 1-3) before investigating DAC/AD FS configuration.

### The Three Governing Policies

**KDC-side (DC):** `Support Dynamic Access Control and Kerberos armoring` (Computer Configuration > Administrative Templates > System > KDC). This is what a domain controller *advertises* and *enforces*:
- **Not Configured / Supported** — the DC will use armoring opportunistically if a client requests it, but accepts unarmored requests without complaint. This has historically been the common baseline posture.
- **Always provide claims** — the DC actively includes claims/compound-auth data in armored exchanges whenever the client supports it, but still accepts unarmored requests from clients that don't.
- **Fail unarmored authentication requests** — the DC rejects any AS-REQ that isn't armored, outright. This is the actual enforcement boundary; the two options above are permissive/opportunistic states, not hard controls.

**Client-side (workstation/member server), two separate settings under System > Kerberos:**
- `Kerberos client support for claims, compound authentication, and Kerberos armoring` — enables the client to *use* FAST when a KDC advertises support. Without this enabled client-side, a client will not request armoring even if every DC in the domain would happily provide it.
- `Fail authentication requests when Kerberos armoring is not available` — a stricter client-side setting that makes the *client* refuse to authenticate unarmored, even against a DC that doesn't require armoring. This is the client-side mirror of the KDC's "Fail unarmored" option, and the two can be configured independently of each other.

These three settings are genuinely independent — a domain can have the KDC actively requiring armoring while a specific client has never been configured to attempt it (producing a hard failure for that client), or a client can be configured to require armoring while reaching a DC that doesn't support it (same result, opposite direction). Diagnosing an armoring issue always means checking both sides, not assuming the DC-side setting alone tells the whole story.

### The Domain Functional Level Gate

This is the single most consequential, least obvious constraint in this entire topic: **the KDC-side "Always provide claims" and "Fail unarmored authentication requests" options do not take effect until the domain is at Windows Server 2012 domain functional level or higher.** Below that level, every DC in the domain behaves as if the option were set to "Supported" — armoring is available opportunistically, but nothing is actively enforced or provided, regardless of what the GPO says. This produces one of the most confusing classes of ticket in this topic: an administrator correctly configures the GPO, confirms it applied via `gpresult`, and the behavior simply doesn't change — because the domain functional level, a completely separate setting with its own change-control implications (functional level increases are one-way), is the actual blocker.

A related, narrower version of the same problem: even at DFL 2012+, if a single down-level domain controller (pre-Server-2012) is still present in the domain, clients that happen to authenticate against that specific DC will not get an armored exchange, while clients hitting any 2012+ DC will. This produces symptoms that look intermittent and random until someone correlates the failures against which DC actually answered each request — Event 4768's `Client Address`/DC identity fields, or simply which DC the affected client's `Get-ADDomainController -Discover` currently resolves to, is the way to catch this.

### Why There's No Single Documented Rejection Event ID

Unlike some of this repo's other hardening topics (LDAP signing's Event 2887/2889, certificate mapping's Event 39/40/41), Kerberos armoring rejections don't have one consistently-documented Windows Security event ID across all supported OS builds. The KDC's rejection surfaces as a Kerberos protocol-level error returned directly to the requesting client (in the same family as other pre-authentication failures), and the most reliable way to confirm a specific rejection is either correlating the failure time against Event 4768 (TGT request)/4771 (pre-authentication failed) on the DC that handled the request and inspecting its Result/Failure Code field, or capturing a network trace of the actual AS-REQ/AS-REP exchange when the failure is reproducible. Do not rely on memory of a specific hex failure code as a diagnostic shortcut — verify against the actual event or trace each time.

</details>

---
## Dependency Stack

```
Domain functional level >= Windows Server 2012
  (hard gate — "Always provide claims"/"Fail unarmored" are no-ops below this level)
  └── Every DC a client might reach is Server 2012+ (down-level DC = per-DC intermittent failure)
        └── KDC-side GPO: Support Dynamic Access Control and Kerberos armoring
              ├── Not Configured/Supported  — opportunistic, unarmored still accepted
              ├── Always provide claims     — claims/compound-auth added opportunistically,
              │                               unarmored still accepted
              └── Fail unarmored authentication requests — hard rejection of unarmored AS-REQ
                    └── Client-side GPO: Kerberos client support for claims, compound
                        authentication, and Kerberos armoring (must be independently enabled)
                          └── (Optional, stricter) Client-side: Fail authentication requests
                              when Kerberos armoring is not available
                                └── Consumers requiring a working armored exchange:
                                      ├── Dynamic Access Control (claims, compound auth)
                                      └── AD FS device claims
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| GPO configured, `gpresult` confirms it applied, but behavior is unchanged (unarmored requests still accepted despite "Fail unarmored" being set) | Domain functional level is below Windows Server 2012 | `(Get-ADDomain).DomainMode` |
| Some clients/users fail intermittently, seemingly at random, no consistent pattern by user or app | A down-level DC is present and some requests happen to land on it | `Get-ADDomainController -Filter * \| Select Name, OperatingSystem`; correlate failures against handling DC |
| DAC/claims-based file access denied even though NTFS/share permissions look correct | Armoring not actually enabled/working — DAC's claims transport prerequisite is unmet | Confirm both KDC-side and client-side armoring policies via `gpresult`, before investigating Central Access Policies |
| AD FS issues a token but device-claims-based conditional rules never fire | Same transport prerequisite gap, one layer up in the federation stack | Confirm armoring is working end-to-end before investigating AD FS claims rule authoring |
| A single legacy device/OS/non-Windows Kerberos client is hard-rejected after a KDC-side policy change to "Fail unarmored authentication requests" | Working as designed — that client's Kerberos stack doesn't support FAST | Confirm via a scoped test GPO reverting just that OU/device to "Supported" |
| Client-side "Fail authentication requests when armoring is not available" is enabled, and the client fails only against certain DCs | The client hard-requires FAST but some DCs in the domain aren't advertising support (down-level DC, or KDC policy not configured there) | Compare KDC-side policy and OS version across every DC the client might reach |
| No dedicated "armoring rejected" event found anywhere in the Security log | Expected — there is no single universally-documented event ID for this; correlate 4768/4771 by time instead | Event 4768/4771 Result/Failure Code, or a network trace of the AS-REQ/AS-REP |

---
## Validation Steps

**Step 1 — Confirm domain functional level (the most common blocker)**
```powershell
(Get-ADDomain).DomainMode
```
Expected: `Windows2012Domain` or higher for stricter KDC-side options to have any effect at all.

**Step 2 — Inventory every DC's OS version**
```powershell
Get-ADDomainController -Filter * | Select-Object Name, OperatingSystem, OperatingSystemVersion, Site
```
Expected: every DC Server 2012 or newer; note the `Site` column if failures correlate with a specific physical location.

**Step 3 — Confirm the KDC-side policy's effective value on the DCs actually in use**
```
gpresult /h C:\Temp\gpresult_dc.html /scope:computer   (run on each DC or a representative sample)
```
Expected: "Support Dynamic Access Control and Kerberos armoring" shows a deliberate, documented value.

**Step 4 — Confirm the client-side policy on the affected machine**
```
gpresult /h C:\Temp\gpresult_client.html /scope:computer
```
Expected: both "Kerberos client support for claims..." and (if relevant to the scenario) "Fail authentication requests when Kerberos armoring is not available" show the intended configured state.

**Step 5 — Correlate the reported failure against Event 4768/4771 on the handling DC**
```powershell
Get-WinEvent -LogName Security -FilterXPath "*[System[(EventID=4768 or EventID=4771)]]" -MaxEvents 50 |
  Where-Object { $_.TimeCreated -gt (Get-Date).AddHours(-2) } |
  Select-Object TimeCreated, Id, Message
```
Expected: an entry matching the user/time in question; inspect the Result Code/Failure Code for the actual protocol-level reason.

**Step 6 — If DAC/AD FS device claims are the actual failing scenario, confirm armoring in isolation first**
Reproduce a plain interactive sign-in for the same user/device and confirm it succeeds normally — this isolates whether the failure is armoring-transport-level (affects everything) or DAC/AD FS-configuration-level (affects only the claims-dependent scenario).

**Step 7 — Post-remediation validation**
Re-run Steps 3-4 after any GPO change and confirm the new value is actually applied (not just configured) via `gpresult`, then re-test the originally failing scenario.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Confirm the Foundational Gate
1. Check domain functional level — this alone explains the majority of "configured but not working" tickets in this topic
2. If below Windows Server 2012 domain functional level, stop investigating GPO values further until this is addressed (Playbook 1)

### Phase 2 — Confirm Domain Controller Homogeneity
1. Inventory every DC's OS version
2. If any down-level DC exists, determine whether the affected users/devices' authentication traffic could be reaching it (site/subnet placement)

### Phase 3 — Confirm Both Sides of the Policy Pair
1. KDC-side: confirm the actual configured/applied value via `gpresult` on the DC(s) in scope
2. Client-side: confirm both relevant policies via `gpresult` on the affected machine
3. Remember these are independent — a healthy KDC-side setting says nothing about client-side configuration and vice versa

### Phase 4 — Isolate Transport-Level vs. Consumer-Level Failure
1. If the failing scenario is DAC, compound auth, or AD FS device claims, first confirm plain sign-in works normally for the same identity/device
2. If plain sign-in also fails, this is a transport-level armoring issue — continue in this topic
3. If only the claims-dependent scenario fails, the transport is likely healthy and the issue is in DAC/AD FS configuration — hand off accordingly

### Phase 5 — Reproduce and Capture Protocol-Level Evidence
1. Correlate the failure time against Event 4768/4771 on the DC that handled it
2. If inconclusive, capture a network trace of the AS-REQ/AS-REP exchange during a reproduction window

### Phase 6 — Remediate and Validate
1. Apply the appropriate fix (functional level raise, DC decommission, GPO correction, scoped exception)
2. Re-validate via `gpresult` that the change actually applied, then re-test the original failing scenario

---
## Remediation Playbooks

<details><summary>Playbook 1 — Raising domain functional level to unblock stricter armoring enforcement</summary>

**Scenario:** KDC-side policy is correctly configured to "Fail unarmored authentication requests" or "Always provide claims," but the domain functional level is below Windows Server 2012, so nothing is actually being enforced.

**Step 1 — Confirm every DC in the domain qualifies for the target functional level**
```powershell
Get-ADDomainController -Filter * | Select-Object Name, OperatingSystem, OperatingSystemVersion
```

**Step 2 — Confirm current functional level and plan the change as a scheduled maintenance activity**
```powershell
(Get-ADDomain).DomainMode
```
This is a one-way operation — once raised, the domain functional level cannot be lowered again without a domain rebuild. Coordinate a change window and stakeholder sign-off; this is not an in-ticket hotfix.

**Step 3 — Raise the domain functional level**
```powershell
Set-ADDomainMode -Identity <domainDN> -DomainMode Windows2012Domain
```
If the forest itself is also below the required forest functional level (relevant for some multi-domain claims scenarios), a corresponding `Set-ADForestMode` may also be required — confirm forest-wide DC readiness first, using the same inventory command against every domain in the forest.

**Step 4 — Validate**
```powershell
(Get-ADDomain).DomainMode
```
Then re-test the originally-configured "Fail unarmored"/"Always provide claims" behavior against a test client.

**Rollback note:** None available — domain (and forest) functional level increases are permanent. This is the primary reason this playbook frames the change as scheduled, sign-off-gated work rather than a routine fix.

</details>

<details><summary>Playbook 2 — Decommissioning or isolating a down-level domain controller</summary>

**Scenario:** Domain functional level is already 2012+, but one or more DCs are still running an unsupported, pre-2012 OS, causing per-DC intermittent armoring failures.

**Step 1 — Confirm which DC(s) are down-level**
```powershell
Get-ADDomainController -Filter * | Select-Object Name, OperatingSystem, Site
```

**Step 2 — Assess whether decommissioning is feasible in the near term**
If the down-level DC is scheduled for retirement, prioritize that over any interim workaround — there is no registry/GPO setting that makes a structurally unsupported DC participate in armored exchanges.

**Step 3 — If immediate decommissioning isn't possible, steer affected clients away via site/subnet topology**
Adjust AD Sites and Services subnet-to-site mappings so clients preferentially locate a 2012+ DC. This reduces but does not eliminate exposure (referral/fallback logic can still occasionally reach the down-level DC).

**Step 4 — Validate**
Re-run the DC inventory and confirm the affected clients' `Get-ADDomainController -Discover` output no longer resolves to the down-level DC under normal conditions.

**Rollback note:** N/A — this is an infrastructure lifecycle change (decommission or site topology adjustment), not a reversible configuration toggle.

</details>

<details><summary>Playbook 3 — Scoped exception for a legacy device that cannot support FAST</summary>

**Scenario:** The KDC-wide "Fail unarmored authentication requests" setting is the desired end state, but one legacy device/OS/non-Windows Kerberos client cannot be upgraded to support armoring, and it needs continued access in the interim.

**Step 1 — Confirm this is genuinely unfixable**
Check for a firmware/OS/client-library update that adds FAST support before treating this as permanent legacy debt.

**Step 2 — Scope the exception as narrowly as possible**
The KDC-side policy is DC-wide, not per-client — there is no way to exempt a single device from a DC's enforcement setting directly. Options, in order of preference:
```
1. Pin the legacy device's authentication to a specific, isolated DC (via its own configuration,
   if the device supports specifying a preferred DC) and apply a scoped GPO — via WMI filtering
   targeting only that DC's computer object — holding just that DC at "Supported" instead of
   "Fail unarmored authentication requests"
2. Revert the KDC-wide policy to "Always provide claims" domain-wide, accepting that unarmored
   requests remain possible, while pursuing device replacement/upgrade as the real fix
```

**Step 3 — Document the exception**
Record: device, owner, business justification, DC(s) affected, exact policy level held back, and a review/re-attempt date — the same documentation discipline used for legacy-device exceptions in the LDAP signing topic.

**Rollback note:** N/A — this produces a documented, scoped, reviewable risk acceptance rather than a technical rollback. Revisit on the documented review date.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Kerberos Armoring (FAST) Evidence Collector
.NOTES     Run with local admin rights; requires the ActiveDirectory module for DC inventory.
#>

$reportPath = "C:\Temp\KerberosArmoringEvidence_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

"=== Domain Functional Level ===" | Out-File "$reportPath\01_DomainMode.txt"
(Get-ADDomain).DomainMode | Out-File "$reportPath\01_DomainMode.txt" -Append

"=== Domain Controller Inventory ===" | Out-File "$reportPath\02_DCInventory.txt"
Get-ADDomainController -Filter * | Select-Object Name, OperatingSystem, OperatingSystemVersion, Site |
  Format-Table -AutoSize | Out-File "$reportPath\02_DCInventory.txt" -Append

"=== gpresult (this machine) ===" | Out-File "$reportPath\03_gpresult_note.txt"
"Run 'gpresult /h $reportPath\03_gpresult.html /scope:computer' manually and attach the HTML report." |
  Out-File "$reportPath\03_gpresult_note.txt" -Append
gpresult /h "$reportPath\03_gpresult.html" /scope:computer

"=== Recent Event 4768/4771 (last 2 hours) ===" | Out-File "$reportPath\04_KerberosEvents.txt"
Get-WinEvent -LogName Security -FilterXPath "*[System[(EventID=4768 or EventID=4771)]]" -MaxEvents 50 -ErrorAction SilentlyContinue |
  Where-Object { $_.TimeCreated -gt (Get-Date).AddHours(-2) } |
  Select-Object TimeCreated, Id, Message | Format-List | Out-File "$reportPath\04_KerberosEvents.txt" -Append

Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "Evidence collected: $reportPath.zip" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Check domain functional level | `(Get-ADDomain).DomainMode` |
| Raise domain functional level (one-way, plan as scheduled change) | `Set-ADDomainMode -Identity <domainDN> -DomainMode Windows2012Domain` |
| Inventory all DC OS versions | `Get-ADDomainController -Filter * \| Select Name, OperatingSystem, Site` |
| Generate a policy report (DC or client) | `gpresult /h report.html /scope:computer` |
| Quick text-based policy scan | `gpresult /r /scope:computer \| Select-String "Kerberos","KDC"` |
| View recent TGT request events | `Get-WinEvent -LogName Security -FilterXPath "*[System[(EventID=4768)]]"` |
| View pre-authentication failure events | `Get-WinEvent -LogName Security -FilterXPath "*[System[(EventID=4771)]]"` |
| Discover which DC a client currently resolves to | `Get-ADDomainController -Discover` (run on the client) |
| Force a Group Policy refresh after a change | `gpupdate /force` |

---
## 🎓 Learning Pointers

- **The domain functional level gate is architecturally separate from the GPO itself**, and is the single most common reason this feature appears to be "configured but doing nothing." Always check `(Get-ADDomain).DomainMode` as literally the first diagnostic step, before spending time on GPO troubleshooting.
- **Armoring is a chained-trust design** — the device's own machine TGT (obtained from its own, separate authentication) is what protects the subsequent user authentication exchange. Understanding this "device authenticates first, then shields the user's exchange" model makes the DAC/compound-authentication dependency much more intuitive.
- **KDC-side and client-side policies are independently configured and must both be deliberately set** for anything beyond opportunistic best-effort use — this is the same "two independent controls" pattern this repo documents for LDAP signing/channel binding; don't assume checking one side tells you about the other.
- **Domain functional level increases are one-way.** Never treat raising it as a routine, same-ticket fix — always confirm every DC in scope qualifies first and treat it as a planned change with stakeholder sign-off, exactly like the equivalent guidance for AD schema/forest-level changes elsewhere in this repo.
- **Don't conflate this feature with Windows Hello for Business Cloud Kerberos Trust or Microsoft Entra Kerberos** — both involve "Kerberos" and modern authentication concepts, but Cloud Trust uses Entra ID as a trust anchor for a completely different hybrid SSO scenario with its own separate configuration surface.
- **There's no shortcut event ID to memorize for armoring rejections** — unlike LDAP signing (Event 2887/2889) or certificate mapping (Event 39/40/41), correlate by time against Event 4768/4771, or capture a live trace, rather than assuming a specific well-known event number exists.
- Related: [Microsoft Entra Kerberos FAQ](https://learn.microsoft.com/en-us/entra/identity/authentication/kerberos-faq), [Dynamic Access Control Overview](https://learn.microsoft.com/en-us/windows-server/identity/solution-guides/dynamic-access-control-overview), [Windows Hello for Business hybrid Cloud Kerberos trust deployment guide](https://learn.microsoft.com/en-us/windows/security/identity-protection/hello-for-business/deploy/hybrid-cloud-kerberos-trust) (for the explicit disambiguation, not as armoring documentation itself)
