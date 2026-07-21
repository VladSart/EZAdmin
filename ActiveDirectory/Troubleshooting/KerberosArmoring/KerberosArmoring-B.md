# Kerberos Armoring (FAST) — Hotfix Runbook (Mode B: Ops)
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

Run these from an elevated PowerShell session on a DC (setting #1) and, separately, on the affected client (settings #2/#3):

```powershell
# 1. Domain functional level — armoring enforcement options do NOT take effect below Server 2012
(Get-ADDomain).DomainMode

# 2. DC-side (KDC) policy — is armoring supported/required domain-wide?
#    GPO: Computer Configuration > Policies > Admin Templates > System > KDC >
#         "Support Dynamic Access Control and Kerberos armoring"
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\KDC" -ErrorAction SilentlyContinue

# 3. Client-side policy — is this specific machine configured to USE armoring, and does it REQUIRE it?
#    GPO: Computer Configuration > Admin Templates > System > Kerberos >
#         "Kerberos client support for claims, compound authentication, and Kerberos armoring"
#         "Fail authentication requests when Kerberos armoring is not available"
#    Registry value names for these two client policies are not consistently documented across
#    sources — treat gpresult as authoritative over any single reference for the exact value name.
gpresult /r /scope:computer | Select-String -Pattern "Kerberos", "KDC"

# 4. Confirm at least one Windows Server 2012+ DC is reachable and advertising armoring support
Get-ADDomainController -Filter * | Select-Object Name, OperatingSystem

# 5. Correlate the reported failure time against Kerberos pre-auth failures (context, not a direct
#    "armoring rejected" indicator — see Learning Pointers on why there's no dedicated event ID)
Get-WinEvent -LogName Security -FilterXPath "*[System[(EventID=4768 or EventID=4771)]]" -MaxEvents 20 |
  Select-Object TimeCreated, Id, Message
```

| What you see | What it means |
|---|---|
| `DomainMode` is below `Windows2012Domain` | **This is almost always the root cause.** "Always provide claims" and "Fail unarmored authentication requests" silently degrade to the permissive "Supported" behavior until the domain functional level is raised — go to Fix 1 |
| Domain functional level is 2012+, but `Get-ADDomainController -Filter *` shows any DC running Server 2008 R2 or earlier | A down-level DC in the mix can still produce intermittent, DC-dependent failures for compound-authentication/claims scenarios — go to Fix 2 |
| KDC policy is `Not Configured` or `Supported`, and the failing scenario is Dynamic Access Control / claims / AD FS device claims | Armoring is present but not required — that's expected for plain sign-in, but DAC/claims scenarios need it actively supported and the client configured to request it — go to Fix 3 |
| KDC policy is `Fail unarmored authentication requests`, and a specific device/app/OS suddenly can't authenticate at all | That device's Kerberos client doesn't support FAST (very old client, or a non-Windows/embedded Kerberos stack) and is being rejected outright, by design — go to Fix 4 |
| Client-side "Fail authentication requests when Kerberos armoring is not available" is enabled, and the client fails intermittently depending on which DC it happens to hit | The client is hard-requiring FAST but is reaching a DC that isn't advertising support (down-level DC, or DFL not yet raised) — go to Fix 2 |
| Nothing above looks wrong, but DAC/claims-based resource access is still denied | Armoring itself may be healthy — the actual failure could be in claims/compound-auth configuration one layer up (Central Access Policies, resource property definitions), not armoring itself — treat as a separate DAC-specific investigation |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Domain functional level >= Windows Server 2012
  └── (Prerequisite for "Always provide claims" / "Fail unarmored" to take effect at all —
       below this level, DCs behave as "Supported" regardless of configured GPO option)
        └── Every DC that a client might reach is Windows Server 2012+ and running the KDC
            service with armoring support compiled in (all supported DCs today qualify;
            this only bites environments with a lingering down-level DC)
              └── KDC-side GPO ("Support Dynamic Access Control and Kerberos armoring")
                  advertises support via a capability flag in the AS-REQ/AS-REP exchange
                    ├── Not Configured / Supported — armoring used opportunistically if the
                    │     client asks for it; unarmored requests still accepted
                    ├── Always provide claims — armoring + claims included whenever the
                    │     client supports it, but unarmored requests are still accepted
                    └── Fail unarmored authentication requests — unarmored AS-REQs are
                          REJECTED outright (KDC_ERR_POLICY-class rejection)
                            └── Client-side policy must independently enable FAST support
                                ("Kerberos client support for claims, compound
                                authentication, and Kerberos armoring")
                                  └── (Optional, stricter) "Fail authentication requests
                                      when Kerberos armoring is not available" — the CLIENT
                                      refuses to authenticate unarmored even if a DC would
                                      have allowed it
                                        └── (Downstream consumer) Dynamic Access Control
                                            claims, compound (user+device) authentication,
                                            and AD FS device claims all REQUIRE a working
                                            armored exchange as their own prerequisite
```

Key failure points:
- The domain functional level gate is the single most common cause of "I configured this and it's doing nothing" — the GPO applies, the registry value is set, and it still behaves as if unconfigured
- KDC-side and client-side policies are two **independently configured** settings — enabling one without the other produces "supported but never actually used" behavior, not a hard failure
- A single down-level DC left in an otherwise-2012+-forest can cause purely intermittent failures that look random until someone correlates them to which DC handled the request
- This is architecturally distinct from Windows Hello for Business Cloud Kerberos Trust (Entra ID as the Kerberos trust anchor) — same protocol family, unrelated feature and configuration surface; do not conflate the two when triaging

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the domain functional level first, before anything else**
```powershell
(Get-ADDomain).DomainMode
```
Expected: `Windows2012Domain` or higher. If lower, stop here — this is very likely the whole story (Fix 1).

**Step 2 — Inventory every DC's OS version**
```powershell
Get-ADDomainController -Filter * | Select-Object Name, OperatingSystem, OperatingSystemVersion
```
Expected: every DC is Server 2012 or newer. Any down-level DC is a candidate root cause for intermittent, DC-dependent failures.

**Step 3 — Confirm the KDC-side policy's actual configured value**
```
On any DC: gpresult /h C:\Temp\gpresult.html /scope:computer
```
Open the report and locate "Support Dynamic Access Control and Kerberos armoring" under Administrative Templates. Expected: a deliberate, known value — not an accidental "Fail unarmored authentication requests" left over from a DAC pilot.

**Step 4 — Confirm the client-side policy on the affected machine**
```
gpresult /h C:\Temp\gpresult_client.html /scope:computer
```
Look for "Kerberos client support for claims, compound authentication, and Kerberos armoring" and "Fail authentication requests when Kerberos armoring is not available." Expected: enabled if the scenario (DAC, AD FS device claims) requires it; the "Fail" option should only be enabled deliberately, since it turns a soft compatibility gap into a hard authentication failure.

**Step 5 — Reproduce and capture the exact rejection**
There is no single, universally-documented Windows Security event ID that flags "unarmored request rejected" distinctly across all builds — the KDC returns a Kerberos protocol-level error (commonly surfaced to the client as a pre-authentication/armoring-related failure) rather than a dedicated event. Correlate the user's reported failure time against Event 4768 (TGT request)/4771 (pre-auth failed) on the DC that handled it, and if the Result/Failure Code doesn't clearly explain it, capture a network trace of the AS-REQ/AS-REP exchange for the exact protocol-level error.

---
## Common Fix Paths

<details><summary>Fix 1 — Domain functional level is below Windows Server 2012</summary>

**Cause:** "Always provide claims" and "Fail unarmored authentication requests" are silently no-ops below DFL 2012 — the domain behaves as "Supported" no matter what the GPO says.

```powershell
# Confirm current level
(Get-ADDomain).DomainMode

# Raising the domain functional level is a one-way operation for anything below the target level —
# confirm every DC in the domain (and, for forest-level changes, every domain in the forest) is
# already running a qualifying OS version before proceeding. This is a planned change, not a
# same-ticket hotfix — coordinate a maintenance window.
Set-ADDomainMode -Identity <domainDN> -DomainMode Windows2012Domain
```

**Rollback note:** Raising the domain (or forest) functional level cannot be undone. Do not attempt this as an urgent fix without confirming every DC qualifies first — treat as a scheduled change, not an in-ticket remediation.

</details>

<details><summary>Fix 2 — A down-level DC is causing intermittent, DC-dependent failures</summary>

**Cause:** Even with DFL at 2012+, an individual DC still running an unsupported OS can't participate in armored exchanges, producing failures that correlate with which DC happened to answer the request.

```powershell
Get-ADDomainController -Filter * | Select-Object Name, OperatingSystem

# There is no registry/GPO workaround for a DC that structurally cannot support armoring —
# the DC itself must be decommissioned or upgraded. As an interim mitigation, you can steer
# affected clients away from the down-level DC using site/subnet placement, but this treats
# the symptom, not the cause.
```

**Rollback note:** N/A — this is an infrastructure lifecycle issue (decommission/upgrade the DC), not a reversible configuration change.

</details>

<details><summary>Fix 3 — DAC/claims/AD FS device claims failing even though armoring itself looks configured</summary>

**Cause:** The KDC and client policies control whether an armored exchange *can* happen — they don't by themselves configure Dynamic Access Control (Central Access Policies, resource properties, claim types) or AD FS device registration/claims rules. A DAC failure with healthy armoring settings usually means the DAC configuration layer itself, not this topic.

```powershell
# Confirm both KDC and client policies are at least "Supported"/enabled (not Not Configured)
gpresult /r /scope:computer | Select-String "Kerberos", "KDC"

# If both are configured correctly and the failure persists, the issue is one layer up —
# Central Access Policies, claim type definitions, or resource property targeting are out of
# scope for this topic; escalate to whoever owns the DAC design, or consult Microsoft's Dynamic
# Access Control documentation directly.
```

**Rollback note:** N/A — diagnostic fix path only, no destructive change made.

</details>

<details><summary>Fix 4 — A specific device/client is hard-rejected after enabling "Fail unarmored authentication requests"</summary>

**Cause:** This KDC option is a genuine security boundary, not a soft warning — any Kerberos client that cannot speak FAST is rejected outright, by design. This most commonly hits very old clients, embedded devices, or non-Windows Kerberos stacks with an outdated library.

```powershell
# Confirm this is really the cause: temporarily test the DC-side policy at "Supported" instead
# of "Fail unarmored authentication requests" against a single test DC/OU via a scoped GPO, and
# confirm the previously-failing client now succeeds.

# If the device genuinely cannot be upgraded to support FAST, the KDC-side "Fail unarmored
# authentication requests" option cannot be scoped per-client — it is a DC-wide setting. Options:
#   1. Revert to "Always provide claims" or "Supported" domain/OU-wide (re-opens the compatibility
#      gap this was meant to close, but restores access) — track as a documented risk acceptance
#   2. Isolate the legacy client to a specific DC pinned at a less strict setting via a scoped GPO
#      (same pattern used for LDAP signing legacy-device exceptions)
```

**Rollback note:** Reverting "Fail unarmored authentication requests" to "Supported"/"Always provide claims" restores compatibility but removes the hard-enforcement boundary — document as a time-boxed, owned exception rather than a silent permanent rollback.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — Kerberos Armoring (FAST) Issue

Domain functional level: ____________
KDC-side policy value (Not Configured/Supported/Always provide claims/Fail unarmored): ____________
Client-side "Kerberos client support for claims..." enabled (Yes/No): ____________
Client-side "Fail authentication requests when armoring not available" enabled (Yes/No): ____________
Affected client(s)/device(s): ____________
DC that handled the failing request (if known): ____________
Scenario involved (plain sign-in / DAC-claims / AD FS device claims / other): ____________
Any down-level (pre-2012) DCs present in the domain (Yes/No): ____________

Steps already attempted:
[ ] Confirmed domain functional level
[ ] Inventoried all DC OS versions
[ ] Confirmed KDC-side and client-side policy values via gpresult
[ ] Correlated failure time against Event 4768/4771 on the handling DC
[ ] Tested against a DC/OU with a relaxed KDC-side setting to isolate the cause
```

---
## 🎓 Learning Pointers

- **The domain functional level gate is the #1 "why isn't this doing anything" cause.** A correctly configured GPO that targets a domain below DFL 2012 silently degrades to permissive behavior — always check `(Get-ADDomain).DomainMode` before assuming the policy itself is broken.
- **KDC-side and client-side armoring policies are independently configured, and both need to agree** for anything beyond opportunistic best-effort use. A KDC that "provides" armoring does nothing if no client ever asks for it, and a client that "requires" armoring will fail against any DC that doesn't advertise support.
- **There is no single, well-documented Windows Security event ID for "unarmored request rejected."** Don't waste time pattern-matching a specific hex failure code from memory — correlate the reported failure time against Event 4768/4771 and, if that's inconclusive, capture a network trace of the actual AS-REQ/AS-REP exchange.
- **Kerberos Armoring/FAST is architecturally unrelated to Windows Hello for Business Cloud Kerberos Trust**, despite both involving "Kerberos" and modern authentication — Cloud Trust uses Entra ID as a trust anchor for a completely different scenario (passwordless SSO to on-prem resources). Don't conflate the two when a ticket mentions "Kerberos trust issues."
- **This is a documented prerequisite for Dynamic Access Control (claims, compound authentication) and AD FS device claims** — if either of those scenarios is failing, confirm armoring is actually enabled and working *before* digging into DAC-specific configuration (Central Access Policies, claim types, resource properties), since a DAC investigation on top of broken armoring will never resolve.
- Public security research has explored abuse/downgrade techniques against armored Kerberos exchanges (e.g., the community "BreakFAST" proof-of-concept) — worth a read for anyone hardening a Tier 0 environment, though this is offensive-security background rather than a routine troubleshooting concern.
- Related: [Microsoft Entra Kerberos FAQ](https://learn.microsoft.com/en-us/entra/identity/authentication/kerberos-faq), [Windows Hello for Business hybrid Cloud Kerberos trust deployment guide](https://learn.microsoft.com/en-us/windows/security/identity-protection/hello-for-business/deploy/hybrid-cloud-kerberos-trust), [Dynamic Access Control Overview](https://learn.microsoft.com/en-us/windows-server/identity/solution-guides/dynamic-access-control-overview)
