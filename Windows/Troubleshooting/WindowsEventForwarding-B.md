# Windows Event Forwarding (WEF/WEC) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes. Covers source-initiated subscriptions that receive nothing, sources stuck Inactive, Forwarding/Operational **Event 105**, error **2150859027** ("requested HTTP URL was not available"), missing Security-log events, and a full `ForwardedEvents` log.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage
Run the **collector** block on the WEC server and the **source** block on one affected client. Both elevated.

```powershell
# --- COLLECTOR (WEC server) ---
Get-Service Wecsvc, WinRM | Select-Object Name, Status, StartType
wecutil es                                    # list subscriptions
wecutil gr '<SubscriptionName>'               # runtime status + per-source Active/Inactive, LastError, LastHeartbeatTime
netsh http show urlacl url=http://+:5985/wsman/   # must list BOTH NT SERVICE\WinRM and NT SERVICE\Wecsvc
Get-WinEvent -ListLog ForwardedEvents | Select-Object RecordCount, FileSize, MaximumSizeInBytes, LogMode

# --- SOURCE (forwarding client) ---
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\EventLog\EventForwarding\SubscriptionManager' -ErrorAction SilentlyContinue
Test-WSMan -ComputerName '<collector FQDN>'
Get-WinEvent -LogName 'Microsoft-Windows-Forwarding/Operational' -MaxEvents 10 | Select-Object TimeCreated, Id, LevelDisplayName, Message
```

| Result | Meaning | Go to |
|---|---|---|
| `Wecsvc` Stopped / Disabled | Collector not running — nothing is accepted | Fix 1 |
| urlacl for `:5985/wsman/` shows **only** `NT SERVICE\WinRM` | WecSvc can't use the WinRM URL when it runs in its own svchost (Server 2019+ with >3.5 GB RAM) | Fix 2 |
| Source Event **105** with **2150859027** / "HTTP URL was not available" | Same URL ACL problem (seen from the source side) | Fix 2 |
| Source has no `SubscriptionManager` registry value | GPO not applied / wrong OU / security filtering | Fix 3 |
| `Test-WSMan` fails | Network, firewall 5985, DNS, or collector WinRM listener missing | Fix 3 |
| `wecutil gr` doesn't list the source at all | Source never checked in: GPO, allowed-source group, or Kerberos group membership not refreshed | Fix 3 / Fix 4 |
| Source listed **Inactive** with LastError | Source checked in but delivery fails — read the error code | Fix 4 |
| Source Active, System/App events arrive, **Security** events don't | NETWORK SERVICE can't read the Security channel | Fix 5 |
| `ForwardedEvents` `FileSize` ≈ `MaximumSizeInBytes`, LogMode Circular | Log default ~20 MB is wrapping — old events overwritten within hours | Fix 6 |
| Everything Active but events arrive ~15 min late | Normal delivery mode batching — expected | Fix 7 |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Event appears in collector's ForwardedEvents log
└── Collector (WEC server)
    ├── Wecsvc running (Automatic, Delayed Start)          <- `wecutil qc` sets this
    ├── WinRM running + HTTP listener on 5985 (or HTTPS 5986)
    ├── HTTP.sys URL ACL for /wsman/ grants BOTH WinRM and Wecsvc service SIDs
    ├── Subscription enabled, type SourceInitiated, query (XPath) valid
    ├── Subscription "Source computer groups" (AllowedSourceDomainComputers SDDL) includes the source's group
    ├── Inbound firewall 5985/5986 open
    └── Destination log (ForwardedEvents) sized for volume
└── Source (forwarder)
    ├── GPO: "Configure target Subscription Manager" = Server=http://<FQDN>:5985/wsman/SubscriptionManager/WEC,Refresh=<sec>
    ├── WinRM service RUNNING (the forwarder lives inside WinRM; no listener needed on source)
    ├── Computer account Kerberos ticket reflects the allowed group (reboot / klist purge after adding to group)
    ├── NETWORK SERVICE can read each queried channel
    │     └── Security log: Event Log Readers membership OR channel access SDDL includes (A;;0x1;;;S-1-5-20)
    └── DNS resolves collector FQDN; outbound 5985 reachable
```
</details>

---
## Diagnosis & Validation Flow

1. **Collector services**
   `Get-Service Wecsvc, WinRM` → both **Running**, `Wecsvc` StartType **Automatic**. Manual/Stopped usually means the subscription was created in Event Viewer but `wecutil qc` was never run.

2. **URL ACL (the #1 silent killer on Server 2019/2022/2025)**
   `netsh http show urlacl url=http://+:5985/wsman/` → good output lists `User: NT SERVICE\WinRM` **and** `User: NT SERVICE\Wecsvc`. Only WinRM listed = Fix 2. Confirm the process split: `Get-CimInstance Win32_Service -Filter "Name='Wecsvc' OR Name='WinRM'" | Select-Object Name, ProcessId` — different PIDs means the ACL matters.

3. **Subscription runtime**
   `wecutil gr '<SubscriptionName>'` → `RunTimeStatus: Active`, then one block per `EventSource` with `RunTimeStatus: Active` and a recent `LastHeartbeatTime`. `Inactive` + `LastError` = delivery failing (note the code). Source missing entirely = it never enrolled (steps 4–5).

4. **Source policy**
   `gpresult /h $env:TEMP\gp.html` → "Configure target Subscription Manager" **Enabled** with the full `Server=...` string. The registry value under `...\EventForwarding\SubscriptionManager` must be exact — a typo in `/wsman/SubscriptionManager/WEC` makes the source talk to nothing.

5. **Source reachability**
   `Test-WSMan <collector FQDN>` → returns `ProductVendor : Microsoft Corporation`. On failure, `Test-NetConnection <collector FQDN> -Port 5985` splits firewall from WinRM.

6. **Source forwarding log**
   `Microsoft-Windows-Forwarding/Operational`: **105** = forwarder can't talk to the subscription manager (error code in the message). Empty log + no registry value = GPO problem. Subscription created on source but nothing at collector = allowed-group or channel-access problem.

7. **Channel access (only Security missing)**
   `wevtutil gl security` → `channelAccess:` contains `(A;;0x1;;;S-1-5-20)` **or** `net localgroup "Event Log Readers"` includes `NT AUTHORITY\NETWORK SERVICE`.

8. **Destination sizing**
   `Get-WinEvent -ListLog ForwardedEvents` — `FileSize` near `MaximumSizeInBytes` with high `RecordCount` means overwriting. Oldest event: `Get-WinEvent -LogName ForwardedEvents -Oldest -MaxEvents 1`.

---
## Common Fix Paths

<details><summary>Fix 1 — Collector service not configured</summary>

```powershell
wecutil qc /q                          # sets Wecsvc Automatic (Delayed) and starts it
winrm quickconfig -quiet               # HTTP listener + firewall rule (skip if WinRM is GPO-managed — see WinRM-B.md)
Get-Service Wecsvc, WinRM
```
Non-destructive. If WinRM is GPO-managed, `winrm quickconfig` may fail — fix the WinRM GPO instead.
</details>

<details><summary>Fix 2 — URL ACL missing Wecsvc (Event 105 / 2150859027)</summary>

Verified against Microsoft Learn KB 4494462. Elevated PowerShell on the collector:

```powershell
# Record current state for rollback
netsh http show urlacl url=http://+:5985/wsman/  | Out-File $env:TEMP\urlacl-before.txt
netsh http show urlacl url=https://+:5986/wsman/ | Out-File $env:TEMP\urlacl-before.txt -Append

$sddl = 'D:(A;;GX;;;S-1-5-80-569256582-2953403351-2909559716-1301513147-412116970)(A;;GX;;;S-1-5-80-4059739203-877974739-1245631912-527174227-2996563517)'
netsh http delete urlacl url=http://+:5985/wsman/
netsh http add urlacl url=http://+:5985/wsman/ sddl=$sddl
netsh http delete urlacl url=https://+:5986/wsman/
netsh http add urlacl url=https://+:5986/wsman/ sddl=$sddl

Restart-Service WinRM; Restart-Service Wecsvc
netsh http show urlacl url=http://+:5985/wsman/   # expect WinRM AND Wecsvc
```
First SID = `NT SERVICE\WinRM`, second = `NT SERVICE\Wecsvc`.
**Rollback:** delete and re-add with the WinRM-only SDDL `D:(A;;GX;;;S-1-5-80-569256582-2953403351-2909559716-1301513147-412116970)`. If there was no 5986 reservation (no HTTPS listener) the delete just errors — skip the HTTPS pair.
</details>

<details><summary>Fix 3 — Source never enrols (GPO / network)</summary>

```powershell
# On a source
gpupdate /target:computer /force
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\EventLog\EventForwarding\SubscriptionManager'
Restart-Service WinRM                  # forwarder re-reads policy
Test-WSMan '<collector FQDN>'
```
GPO: *Computer Configuration → Policies → Administrative Templates → Windows Components → Event Forwarding → Configure target Subscription Manager*. Value:
`Server=http://<collector FQDN>:5985/wsman/SubscriptionManager/WEC,Refresh=60`
Use the **FQDN** (Kerberos needs SPN `HTTP/<FQDN>`). Open inbound TCP 5985 on the collector (`Get-NetFirewallRule -DisplayGroup 'Windows Remote Management'`).
</details>

<details><summary>Fix 4 — Source not in allowed group / stale Kerberos membership / Inactive</summary>

```powershell
# Collector: which groups the subscription allows
wecutil gs '<SubscriptionName>' /f:xml | Select-String AllowedSourceDomainComputers
# Source: after adding the computer to the allowed group, refresh its ticket (or reboot)
klist -li 0x3e7 purge
Restart-Service WinRM
# Collector: force retry of inactive sources
wecutil rs '<SubscriptionName>'
```
Computer group membership lives in the machine's Kerberos ticket — adding it to a group does nothing until the ticket renews (reboot or `klist -li 0x3e7 purge`). Purging the SYSTEM session's tickets is safe; they're re-requested on demand.
</details>

<details><summary>Fix 5 — Security events missing (channel access)</summary>

Pick **one** approach and deploy by GPO:

- **Group:** add `NT AUTHORITY\NETWORK SERVICE` to built-in **Event Log Readers** (Restricted Groups "Member of", or GPP Local Users and Groups with *Update* — never *Replace*).
- **Channel SDDL:** *Administrative Templates → Windows Components → Event Log Service → Security → Configure log access* = the **existing** SDDL + `(A;;0x1;;;S-1-5-20)`.

```powershell
# Capture current SDDL first (rollback reference)
wevtutil gl security | Select-String channelAccess
# One-off local test only — GPO will overwrite it
net localgroup "Event Log Readers" "NT AUTHORITY\NETWORK SERVICE" /add
Restart-Service WinRM
```
**Rollback:** `net localgroup "Event Log Readers" "NT AUTHORITY\NETWORK SERVICE" /delete`. Never type a replacement Security SDDL from scratch — append only.
</details>

<details><summary>Fix 6 — ForwardedEvents log too small / wrapping</summary>

```powershell
wevtutil sl ForwardedEvents /ms:4294967296     # 4 GB — size to ingestion rate x retention target
Get-WinEvent -ListLog ForwardedEvents | Select-Object MaximumSizeInBytes, LogMode
```
Moving the file to a data volume: `wevtutil sl ForwardedEvents /lfn:D:\EventLogs\ForwardedEvents.evtx`, then restart Wecsvc. Multi-GB single .evtx files query slowly — beyond that, split subscriptions across destination logs/collectors or ship to a SIEM.
</details>

<details><summary>Fix 7 — Latency ("events arrive 15 minutes late")</summary>

```powershell
wecutil ss '<SubscriptionName>' /cm:MinLatency   # push within ~30 s
wecutil gs '<SubscriptionName>' | Select-String ConfigurationMode
```
`Normal` batches (~15 min), `MinBandwidth` ~6 h, `MinLatency` ~30 s. MinLatency across thousands of sources raises collector load — use it on a small, high-value subscription (e.g. DC Security events), not everything.
</details>

---
## Escalation Evidence
```
WEF/WEC ESCALATION
Collector FQDN / OS build:                <>
Wecsvc / WinRM status + PIDs:             <>
netsh http show urlacl (5985/5986):       <paste>
Subscription name / type / mode:          <> / SourceInitiated / <Normal|MinLatency|MinBandwidth|Custom>
wecutil gr <sub> (affected source block): <paste>
ForwardedEvents size / max / oldest:      <> / <> / <>
Affected source hostname / OS:            <>
SubscriptionManager registry value:       <paste>
Test-WSMan <collector> result:            <pass/fail + error>
Forwarding/Operational last 10 events:    <paste IDs + messages>
Security channelAccess / ELR membership:  <>
Scope (all sources / one OU / one):       <>
Changes in last 7 days (GPO, patches, collector RAM/rebuild): <>
Get-WEFHealth.ps1 CSV attached:           Y/N
```

---
## 🎓 Learning Pointers
- **Event 105 + 2150859027 on a healthy-looking collector is almost always the HTTP.sys URL ACL.** Svchost refactoring splits WinRM and Wecsvc into separate processes on Server 2019+ with >3.5 GB RAM, and the default ACL only trusts WinRM — adding RAM to a collector can break WEF. [KB 4494462 — Events are not forwarded if the collector is running Windows Server](https://learn.microsoft.com/en-us/troubleshoot/windows-server/admin-development/events-not-forwarded-by-windows-server-collector).
- **Source-initiated WEF reads logs as NETWORK SERVICE on the source**, which is why System/Application arrive while Security doesn't.
- **Computer group membership only changes on ticket renewal.** Adding a PC to "WEF Sources" and expecting it to appear instantly is the most common false "WEF is broken" ticket.
- **`wecutil gr` is the source of truth**, not Event Viewer's Subscriptions pane — it shows per-source heartbeat and last error. [wecutil reference](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/wecutil).
- Microsoft's WEF-for-security guidance: [Use Windows Event Forwarding to help with intrusion detection](https://learn.microsoft.com/en-us/windows/security/operating-system-security/device-management/use-windows-event-forwarding-to-assist-in-intrusion-detection). Community query packs: Palantir's `windows-event-forwarding` repo on GitHub.
- Source transport (listener, Kerberos, firewall) is shared with PowerShell remoting — see `WinRM-B.md`. Deep dive: `WindowsEventForwarding-A.md`; fleet audit: `Scripts/Get-WEFHealth.ps1`.
