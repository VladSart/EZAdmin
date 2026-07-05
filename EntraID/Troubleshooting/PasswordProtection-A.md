# Entra Password Protection & Smart Lockout — Reference Runbook (Mode A: Deep Dive)
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
- [Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

This covers Entra ID's two native credential-protection controls: **Smart Lockout** (brute-force/spray mitigation via progressive lockout) and **Password Protection** (global + custom banned password lists, cloud and hybrid/on-prem enforcement). Both are enabled by default on every Entra tenant at no additional license cost for the cloud-only baseline; on-premises enforcement requires the DC Agent/Proxy components and applies to any password change made against on-prem AD (including Ctrl+Alt+Del changes, `net user`, ADUC resets).

Assumes: tenant is not using a third-party IdP as the primary authentication surface (federation changes where lockout logic lives), and any hybrid components discussed (DC Agent, Proxy, password writeback) refer to Entra Connect Sync topology, not Entra Connect cloud sync's more limited writeback support.

Out of scope: Conditional Access risk-based policies (Identity Protection), which are a separate control layer that can also block sign-ins and is easy to confuse with Smart Lockout — see `EntraID/Troubleshooting/IdentityProtection-A.md`.

---

## How It Works

<details><summary>Full architecture</summary>

**Smart Lockout** tracks failed sign-in attempts per user, independently bucketed by whether the client location is "familiar" (previously seen for that user) or "unfamiliar." This prevents an attacker spraying from a random IP from tripping the same counter a legitimate user typing a wrong password from their normal laptop would use — familiar-location attempts get more leeway before lockout.

Default policy: lockout threshold = 10 failed attempts, initial lockout duration = 60 seconds. After the first lockout clears, subsequent lockouts within a rolling window increase in duration (up to a capped ceiling), which is why "the same user keeps getting locked out for longer each time" is expected behavior during an active retry storm, not a bug. The counter and lockout state live entirely in Entra ID's authentication service — there is no on-prem component for Smart Lockout itself, even in hybrid environments (unlike Password Protection).

Threshold and duration are tunable per tenant (Entra ID → Security → Authentication methods → Password protection), but Microsoft explicitly discourages tightening the threshold below 10 or shortening duration below 60s — over-tightening is one of the most common self-inflicted causes of "users get locked out constantly" tickets, because it removes the buffer for normal typo bursts.

**Password Protection** operates at password-set time (registration, self-service reset, admin reset, on-prem change), not at sign-in time. It has two layers:

1. **Global banned password list** — Microsoft-maintained, continuously updated from telemetry on passwords actually used in successful breach/spray attacks. Cannot be disabled or viewed directly. Uses fuzzy matching: character substitutions (`@`→`a`, `0`→`o`, `3`→`e`), sequential character removal, and case normalization all fold into the same comparison, so "P@ssw0rd1" and "password" hit the same ban.
2. **Custom banned password list** — tenant-defined, up to 1000 terms, admin-maintained via portal only (no Graph API surface for reading or writing this list as of 2026). Common entries: company name, product names, city/office names, local sports teams — anything an attacker targeting this specific org would guess first.

Both lists are evaluated together and fuzzy-matched against every substring the user attempts, which is why seemingly-unrelated legitimate passwords occasionally get rejected (a false positive against a short common-word fragment).

**Hybrid/on-premises enforcement extension:** the cloud policy (global + custom lists) does nothing to on-prem AD password changes by default — a user could set a fully cloud-compliant password in Entra self-service but still be allowed to set "Company123!" via Ctrl+Alt+Del on a domain-joined machine, because that change never touches Entra ID at all. To close this gap:
- **Password Protection Proxy** — one or more domain-joined servers that relay policy requests from DC Agents to the cloud service. Not installed on DCs.
- **Password Protection DC Agent** — must be installed on *every* writable domain controller. Each DC Agent caches the current policy locally (refreshed periodically via the Proxy), so enforcement continues to work even during a brief cloud/proxy outage — but a DC that never received the agent is a silent, permanent gap, not a temporary one.
- **Mode**: Audit (logs would-be rejections without blocking) or Enforced (actually blocks). New deployments should run Audit for 1-2 weeks to gauge false-positive impact on the custom list before flipping to Enforced.

**Password writeback** is a related but distinct hybrid feature: when a user changes/resets their password in the cloud (SSPR or admin reset), writeback pushes that change back to on-prem AD so the user doesn't end up with two different passwords for cloud vs. on-prem resources. Writeback failures are a top cause of "I reset my password and now nothing works" tickets — the user's cloud identity has the new password, VPN/file shares/RDP against on-prem AD still expect the old one.

</details>

---

## Dependency Stack

```
On-prem writable Domain Controllers (multiple, in hybrid environments)
  │
  ├── Password Protection DC Agent (MUST be on every writable DC — no exceptions)
  │     └── Caches policy locally; periodic refresh from Proxy
  │
  ├── Password Protection Proxy (one or more, relays cloud policy to DC Agents)
  │     └── Requires outbound HTTPS to Entra ID endpoints (no inbound ports needed)
  │
  └── Entra Connect Sync (separate component — enables password writeback, distinct from Password Protection)
        └── Password writeback toggle (Entra Connect config wizard)
              └── Entra Connect Health sync error reporting (surfaces writeback failures)

Entra ID (cloud, always authoritative for the policy definition)
  │
  ├── Global banned password list (Microsoft-maintained, fuzzy matching engine, cannot disable)
  ├── Custom banned password list (tenant-defined, portal-only CRUD, up to 1000 terms)
  ├── Smart Lockout engine (per-user counters, familiar vs unfamiliar location buckets)
  └── Authentication Methods policy (lockout threshold/duration tuning, Audit/Enforced mode for on-prem)
```

**Key interlock:** Smart Lockout has zero on-prem dependency — it is purely a cloud sign-in control and applies identically whether the user authenticates via a synced or cloud-only identity. Password Protection's *on-prem enforcement* is entirely dependent on the DC Agent/Proxy chain; without it, the cloud policy is cosmetic for on-prem password changes. These two facts get conflated constantly in escalations — always identify which of the two controls is actually in play before troubleshooting.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Sign-in fails with error `50053` | Smart Lockout triggered by repeated bad attempts | Sign-in log burst of `50126` immediately before |
| Password reset rejected, generic "doesn't meet requirements" | Global or custom banned list fuzzy match | Reproduce with user watching for exact on-screen message |
| Password accepted in Entra but rejected/reverted on-prem | On-prem AD complexity/history policy conflict, or DC Agent not enforcing at all | Compare cloud vs on-prem policy; check DC Agent service state |
| User resets cloud password, VPN/file share still uses old one | Password writeback failure or disabled | Entra Connect Health → Sync Errors → Password writeback |
| Same user locked out every 20-30 minutes for days | Stale cached credential retry storm (mapped drive, mobile app, scheduled task, printer) | Sign-in log `AppDisplayName`/`ResourceDisplayName` on the `50126` burst |
| New DC promoted, users on that site suddenly can set weak on-prem passwords | DC Agent never installed on the new DC | `Get-Service AzureADPasswordProtectionDCAgent` on that DC |
| Custom banned list blocking legitimate business terms tenant-wide | Overly broad custom term (e.g. a common word added without considering substring matches) | Review custom list entries in portal |
| Lockouts happening to many users simultaneously, not just one | Active password spray attack against the tenant, not a config issue | Identity Protection risky sign-ins report, source IP clustering |

---

## Validation Steps

**1. Confirm current lockout policy configuration**
Portal only: `Entra ID → Security → Authentication methods → Password protection`.
*Good:* Threshold ≥ 8-10, duration ≥ 60s (Microsoft defaults or close to them).
*Bad:* Threshold set below 5 or duration set unusually long — indicates over-tightening likely causing excess legitimate-user lockouts.

**2. Confirm DC Agent presence and health on every writable DC**
```powershell
# Run against each DC — script this across all DCs for a fleet-wide check
$DCs = Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName
foreach ($dc in $DCs) {
    Invoke-Command -ComputerName $dc -ScriptBlock {
        Get-Service AzureADPasswordProtectionDCAgent -ErrorAction SilentlyContinue |
            Select-Object @{N="DC";E={$env:COMPUTERNAME}}, Name, Status, StartType
    }
}
```
*Good:* Every DC returns `Running` / `Automatic`.
*Bad:* Any DC missing from the output entirely (agent never installed) or showing `Stopped`.

**3. Confirm Proxy connectivity to cloud**
```powershell
Get-Service AzureADPasswordProtectionProxy | Select-Object Name, Status
Get-WinEvent -LogName "Microsoft-AzureADPasswordProtection-Proxy/Admin" -MaxEvents 20 |
    Select-Object TimeCreated, Id, Message
```
*Good:* Recent successful policy sync events, no repeated connection-failure events.
*Bad:* Gaps of days between successful syncs, or repeated TLS/auth failures against the cloud endpoint.

**4. Confirm writeback health (hybrid only)**
Portal: `Entra Connect Health → Synchronization Service → Errors`, filter for password writeback type.
*Good:* Zero unresolved writeback errors, or errors are isolated and explained (e.g. disabled on-prem account).
*Bad:* Recurring writeback failures correlated with helpdesk password-reset tickets — indicates a systemic issue (e.g. on-prem password policy stricter than cloud, causing every writeback to fail the on-prem complexity check).

**5. Reproduce a banned-password rejection to classify it**
Have the user (or a test account) attempt the exact rejected password. Cloud rejection explicitly references Microsoft's policy language; if the error instead comes from a Windows-native "does not meet the password policy requirements of your organization" dialog while the machine is domain-joined and offline from Entra, that's on-prem Group Policy password complexity, a separate control entirely.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Classify the complaint.** Is this a sign-in failure (Smart Lockout, wrong error code territory: `50053`) or a password-set-time failure (Password Protection, no numeric error code — a UI-level rejection message)? These require entirely different remediation paths and conflating them wastes the first 10 minutes of most tickets.

**Phase 2 — Single user vs. multiple users.** One user locked out repeatedly → likely stale credential source (Fix territory covered in the -B runbook). Multiple users locked out simultaneously, especially from varied/unfamiliar IPs → treat as a potential password spray attack first, config troubleshooting second. Pull Identity Protection risky sign-ins for the same time window before assuming it's a policy bug.

**Phase 3 — Cloud-only vs. hybrid.** If the tenant is hybrid, always ask whether the failing password change happened via a cloud surface (myaccount.microsoft.com, SSPR) or an on-prem surface (Ctrl+Alt+Del, ADUC, `net user`). This determines whether DC Agent/Proxy health is even relevant to the ticket.

**Phase 4 — Isolate configuration drift from genuine incident.** Check whether tenant lockout threshold/duration or the custom banned list changed recently (no built-in audit log entry for banned-list changes as of 2026 — rely on change management records/tickets) before assuming this is new attacker activity.

---

## Remediation Playbooks

<details><summary>Playbook — Deploy DC Agent to a newly promoted or rebuilt DC</summary>

**When to use:** A DC was promoted, rebuilt from an image, or restored from backup and is missing the Password Protection DC Agent — a silent enforcement gap.

1. Confirm the gap:
```powershell
Get-Service AzureADPasswordProtectionDCAgent -ErrorAction SilentlyContinue
# No output / error = not installed
```
2. Download the DC Agent installer (`AzureADPasswordProtectionDCAgentSetup.msi`) from the same source used for the original hybrid deployment — Microsoft Download Center, package name "Azure AD Password Protection DC Agent."
3. Install silently:
```powershell
msiexec /i AzureADPasswordProtectionDCAgentSetup.msi /quiet /qn
```
4. Reboot is typically NOT required but restart the service to force an immediate policy pull:
```powershell
Restart-Service AzureADPasswordProtectionDCAgent
```
5. Verify policy retrieval:
```powershell
Get-WinEvent -LogName "Microsoft-AzureADPasswordProtection-DCAgent/Admin" -MaxEvents 5
```

**Rollback:** Uninstall via `msiexec /x` reverts this DC to unprotected for on-prem password changes — only do this if the agent is causing an active production issue, and treat the resulting gap as a known risk requiring re-remediation.

**Add to standard operating procedure:** every DC promotion/rebuild runbook should include a DC Agent verification step going forward — this is the single most common recurring gap in hybrid Password Protection deployments.

</details>

<details><summary>Playbook — Move a tenant from Audit to Enforced mode</summary>

**When to use:** Initial hybrid deployment has been running in Audit mode for 1-2+ weeks and false-positive rate on the custom banned list is acceptable.

1. Review Audit-mode logs for false-positive volume:
```powershell
Get-WinEvent -LogName "Microsoft-AzureADPasswordProtection-DCAgent/Admin" -MaxEvents 500 |
    Where-Object { $_.Message -match "would have been rejected" } |
    Group-Object -Property Message | Sort-Object Count -Descending
```
2. If false-positive rate is low and explainable (expected banned terms firing correctly), switch mode:
Portal: `Entra ID → Security → Authentication methods → Password protection → Enforce password protection on Windows Server Active Directory → Enabled`.
3. Communicate the change to helpdesk before flipping — expect a short-term uptick in password-change rejection tickets as users with previously-tolerated weak on-prem passwords are now blocked from reusing them at next change.

**Rollback:** Set the toggle back to Audit; on-prem enforcement becomes advisory-only again immediately, no agent reinstall needed.

</details>

<details><summary>Playbook — Repair a systemic writeback failure pattern</summary>

**When to use:** Multiple hybrid users report cloud password reset succeeded but on-prem resources still reject the new password.

1. Check Entra Connect Health for a pattern (not just one-off failures):
Portal: `Entra Connect Health → Synchronization Service → Errors`, filter type = password writeback, sort by frequency.
2. Common systemic cause: on-prem AD fine-grained password policy or default domain policy complexity/history requirements are stricter than the cloud policy, so writeback silently fails the on-prem complexity check even though the cloud accepted the password.
```powershell
# Compare on-prem policy against what was accepted in the cloud
Get-ADDefaultDomainPasswordPolicy
Get-ADFineGrainedPasswordPolicy -Filter * | Select-Object Name, MinPasswordLength, PasswordHistoryCount, ComplexityEnabled
```
3. Align policies (either relax on-prem complexity to match cloud minimums, or communicate the stricter effective requirement to users) — do not simply retry writeback repeatedly, it will fail identically each time until the underlying policy mismatch is resolved.

**Rollback:** N/A — this is policy alignment, not a destructive change. Document the chosen resolution in change management since it affects domain-wide password policy.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Password Protection / Smart Lockout diagnostic evidence for escalation.
.DESCRIPTION
    Gathers sign-in log errors for a target user, DC Agent/Proxy service health across
    all writable DCs, and recent DC Agent event log entries. Exports to CSV for ticket attachment.
    Requires Microsoft.Graph module (Connect-MgGraph) and RSAT AD tools if run against on-prem DCs.
#>
param(
    [Parameter(Mandatory)][string]$UPN,
    [string]$OutputPath = "$env:TEMP\PasswordProtectionEvidence_$(Get-Date -Format yyyyMMdd_HHmmss)"
)
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

Connect-MgGraph -Scopes "AuditLog.Read.All","Directory.Read.All" -NoWelcome

Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$UPN'" -Top 50 |
    Select-Object CreatedDateTime, @{N="ErrorCode";E={$_.Status.ErrorCode}},
        @{N="Reason";E={$_.Status.FailureReason}}, AppDisplayName, ResourceDisplayName, IpAddress |
    Export-Csv "$OutputPath\SignInLogs.csv" -NoTypeInformation

if (Get-Module -ListAvailable -Name ActiveDirectory) {
    $DCs = Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName
    $DCs | ForEach-Object {
        Invoke-Command -ComputerName $_ -ScriptBlock {
            Get-Service AzureADPasswordProtectionDCAgent -ErrorAction SilentlyContinue |
                Select-Object @{N="DC";E={$env:COMPUTERNAME}}, Name, Status, StartType
        }
    } | Export-Csv "$OutputPath\DCAgentStatus.csv" -NoTypeInformation
}

Write-Host "Evidence pack written to $OutputPath" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Command | Purpose |
|---------|---------|
| `Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<UPN>'"` | Pull sign-in error codes for a user |
| `Get-Service AzureADPasswordProtectionDCAgent` | Check DC Agent status on a DC |
| `Get-Service AzureADPasswordProtectionProxy` | Check Proxy service status |
| `Get-WinEvent -LogName "Microsoft-AzureADPasswordProtection-DCAgent/Admin"` | DC Agent policy sync/rejection events |
| `Get-WinEvent -LogName "Microsoft-AzureADPasswordProtection-Proxy/Admin"` | Proxy sync events |
| `Get-ADDomainController -Filter *` | Enumerate all DCs to check for agent coverage gaps |
| `Get-ADDefaultDomainPasswordPolicy` | On-prem baseline password policy |
| `Get-ADFineGrainedPasswordPolicy -Filter *` | On-prem PSOs that may conflict with cloud policy |
| `Unlock-ADAccount -Identity <sam>` | Unlock an on-prem AD account independent of Entra |
| `Get-ADUser -Identity <sam> -Properties LockedOut,PasswordExpired` | Check on-prem account state |
| Portal: Password protection blade | View/edit threshold, duration, custom banned list, Audit/Enforced toggle |
| Portal: Entra Connect Health → Sync Errors | Writeback failure detail (no Graph API equivalent) |

---

## 🎓 Learning Pointers

- **Smart Lockout counters are cloud-only and location-aware — there is no on-prem component to troubleshoot for lockout itself.** Don't waste time checking DC Agent health for a pure lockout complaint; that chain only matters for banned-password enforcement. [MS Docs: Smart Lockout](https://learn.microsoft.com/en-us/entra/identity/authentication/howto-password-smart-lockout)
- **The DC Agent must be deployed to every writable DC individually — there's no tenant-wide "on" switch that propagates automatically.** Treat this as a standing configuration-drift risk any time a DC is promoted, rebuilt, or restored from an older backup image. [MS Docs: Deploy on-premises](https://learn.microsoft.com/en-us/entra/identity/authentication/howto-password-ban-bad-on-premises-deploy)
- **Password writeback and Password Protection are two independent hybrid features that get bundled together in most people's mental model.** Writeback failures produce "my reset didn't work" tickets; Password Protection gaps produce "my weak password was accepted on-prem" gaps. Diagnosing the wrong one wastes an escalation cycle. [MS Docs: SSPR writeback](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-sspr-writeback)
- **Run new on-prem enforcement in Audit mode first and actually review the false-positive volume before flipping to Enforced.** Skipping this step is the most common cause of a flood of helpdesk tickets in the week after a hybrid Password Protection rollout. [MS Docs: Password Protection overview](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-password-ban-bad-overview)
- **Simultaneous lockouts across many users is a security signal, not a config bug — check Identity Protection risky sign-ins before touching lockout policy.** Tightening the lockout threshold in response to what's actually an active password spray does nothing to stop the attack and makes legitimate users collateral damage. [MS Docs: Identity Protection risk detections](https://learn.microsoft.com/en-us/entra/id-protection/concept-identity-protection-risks)
