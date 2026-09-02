# Global Secure Access Client (Windows) — Hotfix Runbook (Mode B: Ops)
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

```powershell
# 1. Installed client version (many features/behaviors below are version-gated)
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
  Where-Object { $_.DisplayName -match "Global Secure Access" } | Select-Object DisplayName, DisplayVersion

# 2. Both core services -- use CURRENT names, older docs may reference renamed predecessors
Get-Service -Name "*Global Secure Access*"

# 3. NRPT rules (Private Access DNS routing -- stale rules from an old client are a common cause)
Get-DnsClientNrptPolicy

# 4. Hyper-V virtual switch type, if this is a Hyper-V host
Get-VMSwitch -ErrorAction SilentlyContinue | Select-Object Name, SwitchType

# 5. Entra join/registration state (GSA requires Entra-joined, hybrid-joined, or
#    Entra-registered -- not just domain-joined)
dsregcmd /status | Select-String "AzureAdJoined|DomainJoined|EnterpriseJoined"
```

| Triage result | Interpretation | Do this |
|---|---|---|
| Client version well below current (check release history) | Missing version-gated fixes/features -- often the root cause of "worked before, broken now" | Fix 1 |
| Engine Service or Forwarding Profile Service not `Running` | Core tunneling or profile-retrieval broken | Fix 2 |
| Client UI shows "Disconnected" despite services running | Authentication or forwarding profile issue, not a service issue | Fix 3 |
| Local printing/casting broken with GSA active, client is v2.32.294+ | Overlapping local/private-app subnet -- Prefer Local Network is the fix | Fix 4 |
| Stale/unexpected NRPT rules present | Leftover from an older client's incomplete "Disable Private Access" cleanup | Fix 5 |
| Hyper-V guest traffic tunneling behaves unexpectedly | Internal vs. external virtual switch mismatch with install location | Fix 6 |
| Client hasn't auto-upgraded despite Windows Update running | Below the 2.31.125 (x64)/2.32.294 (Arm) eligibility floor, or installed with `EnableWindowsUpdates=0` | Fix 7 |
| Multiple concurrent Windows sessions, only one seems protected | Documented single-session limitation, not a bug | Fix 8 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
User's traffic is tunneled/protected by Global Secure Access on Windows
        |
        v
Device is Entra-joined / hybrid-joined / Entra-registered (dsregcmd /status)
        |
        v
Global Secure Access Engine Service: Running
        |
        v
Global Secure Access Forwarding Profile Service: Running
(auto-restarts on failure since client v2.31.125 -- NOT on older clients)
        |
        v
At least one traffic forwarding profile enabled tenant-wide
("Disabled by your organization" = expected break-glass state, not a bug)
        |
        v
Client UI Connections tab shows expected active channels
        |
        v
Version-gated features behave as expected for THIS client version
(Prefer Local Network v2.32.294+, interactive policy sign-in v2.22.90+,
 auto-restart v2.31.125+, Windows Update delivery v2.31.125+/2.32.294+ Arm)
        |
        v
No conflicting local topology issue (Hyper-V external switch install location,
overlapping subnet without Prefer Local Network, multi-session host)
```

</details>

---
## Diagnosis & Validation Flow

1. **Get the client version first.** Almost every fix path below branches on version.
2. **Confirm both services by their current names** (`*Global Secure Access*` wildcard, not "Policy Retriever" or "Auto Upgrade").
3. **Check the Connections tab for active channel status**, not just service running-state -- a running service with a stale/failed-to-retrieve profile looks healthy at the service level.
4. **Run the client's own Advanced Diagnostics → Health Check** and resolve failing tests top to bottom.
5. **For a local-connectivity complaint (printing/casting), check client version against 2.32.294 before assuming a policy problem.**
6. **For a Hyper-V host, confirm switch type before assuming a client bug.**

---
## Common Fix Paths

<details><summary>Fix 1 -- Client is significantly out of date</summary>

```powershell
# Confirm current version against the official release history, then upgrade
# via MDM (Intune Win32 app reassignment) or manual installer re-run
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
  Where-Object { $_.DisplayName -match "Global Secure Access" } | Select-Object DisplayVersion
```
Reference: https://learn.microsoft.com/en-us/entra/global-secure-access/reference-windows-client-release-history

**Rollback:** none needed -- client upgrades are forward-only and don't remove tenant-side configuration.
</details>

<details><summary>Fix 2 -- A core service isn't running</summary>

```powershell
Get-Service -Name "*Global Secure Access*" | Where-Object { $_.Status -ne 'Running' } |
  Start-Service
```
If **Global Secure Access Forwarding Profile Service** repeatedly stops and this is a pre-2.31.125 client, upgrade -- auto-restart-on-failure is a version-gated fix, not something to keep working around manually.

**Rollback:** none -- starting a stopped service is non-destructive.
</details>

<details><summary>Fix 3 -- Services running but client shows Disconnected</summary>

Open the client UI → **Get policy** to force an immediate forwarding-profile pull rather than waiting for the next cycle. If still disconnected, confirm the tenant hasn't set all traffic forwarding profiles to disabled tenant-wide (break-glass) -- this shows as "Disabled by your organization" in the client, which is expected behavior, not a fault, and needs a tenant-admin conversation rather than a device-side fix.

**Rollback:** none -- forcing a policy pull is non-destructive.
</details>

<details><summary>Fix 4 -- Local printing/casting broken (overlapping subnet)</summary>

Confirm client is v2.32.294+, then enable **Prefer Local Network** in client settings (requires tenant admin to have exposed the option first). This is a targeted fix for a specific, documented conflict -- don't reach for a broader Private Access scope change first.

**Rollback:** disable Prefer Local Network if it causes unexpected routing elsewhere.
</details>

<details><summary>Fix 5 -- Stale NRPT rules</summary>

```powershell
Get-DnsClientNrptPolicy
```
Cleanup of NRPT rules on a "Private Access disabled" transition was added in client v2.20.56 -- a client older than this, or one that was upgraded across that boundary without a clean disable/re-enable cycle, can retain stale rules. Upgrading the client resolves this going forward; for an immediate fix, a full uninstall/reinstall of the client clears NRPT state.

**Rollback:** reinstalling is not destructive to tenant-side configuration, only to local client state.
</details>

<details><summary>Fix 6 -- Hyper-V guest traffic tunneling mismatch</summary>

```powershell
Get-VMSwitch | Select-Object Name, SwitchType
```
**Internal** switch: host-level client install is sufficient; guest traffic bypass is automatic -- don't also install inside guests unless there's a separate reason to. **External** switch: host-level bypass is NOT supported -- install the client inside each guest VM that needs coverage.

**Rollback:** n/a -- this is a topology correction, not a destructive change.
</details>

<details><summary>Fix 7 -- Client not receiving automatic Windows Update upgrades</summary>

```powershell
# Confirm version against the eligibility floor (2.31.125 x64 / 2.32.294 Arm)
# If below floor: upgrade manually/via MDM once to cross it.
# If at/above floor and still not auto-upgrading: confirm it wasn't installed
# with EnableWindowsUpdates=0
```
If the device was deliberately opted out, this is expected -- confirm with whoever manages the deployment before treating it as broken.

**Rollback:** reinstall/upgrade without the `EnableWindowsUpdates=0` parameter to opt back into automatic delivery.
</details>

<details><summary>Fix 8 -- Multi-session host, only one session protected</summary>

Confirm via the client's **Single Windows user session detected** health check test. This is a documented product limitation (one interactive session supported at a time) -- not a misconfiguration to chase further.

**Rollback:** n/a -- not a fixable condition on the current client; set expectations with the customer.
</details>

---
## Escalation Evidence

```
Device name: ____________________
Client version installed: ____________________
Windows Update-delivery eligible (Y/N, version checked against floor): ____________________
Engine Service status: ____________________
Forwarding Profile Service status: ____________________
Entra join state (Joined/Hybrid/Registered/None): ____________________
Active forwarding profile channels shown in client: ____________________
Health check failing test(s): ____________________
Hyper-V host (Y/N) and switch type, if applicable: ____________________
Symptom: ____________________
Fix(es) attempted: ____________________
```

---
## 🎓 Learning Pointers

- **Version first, every time.** This client has shipped meaningful behavior changes across nearly every release in 2025-2026 -- service renames, new health checks, new settings, a new upgrade-delivery model. A fix that's correct for one version can be irrelevant or wrong for another. [Global Secure Access client release notes (Windows)](https://learn.microsoft.com/en-us/entra/global-secure-access/reference-windows-client-release-history)
- **This is Windows-specific -- don't reach for the macOS runbook's fixes here.** See `macOS/Troubleshooting/GlobalSecureAccess-macOS-B.md` for that platform; the two share a tenant-side concept but almost nothing else operationally.
- **Prefer Local Network (v2.32.294+) is a real, narrow fix for a real, narrow problem.** Recognize the overlapping-subnet pattern behind a "GSA broke my printer" ticket rather than escalating it as a general Private Access misconfiguration.
- **The Windows Update auto-upgrade model (November 2026) has a version floor and an explicit opt-out flag.** Both details matter before concluding a device "should" have auto-upgraded.
- **Hyper-V's internal-vs-external switch distinction is not negotiable.** Getting the install location wrong for the switch type in use is the single most common Hyper-V-adjacent GSA ticket root cause.
