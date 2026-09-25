# Windows Event Forwarding (WEF/WEC) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what. Companion to `WindowsEventForwarding-B.md` (hotfix) and `Scripts/Get-WEFHealth.ps1` (read-only audit).

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
**Covers:** built-in Windows Event Forwarding — source-initiated (GPO-pushed, the MSP default) and collector-initiated subscriptions; Windows Event Collector (Wecsvc) on Windows Server 2016–2025; HTTP/Kerberos transport in AD domains; HTTPS/certificate transport for workgroup/non-domain sources (overview); delivery modes; channel access; collector sizing and lifetime-source bloat; feeding a SIEM/Sentinel from the collector.

**Does not cover:** Azure Monitor Agent DCRs / Sentinel connectors in depth (only as the WEC → cloud hop); third-party agents (Splunk UF, NXLog); event log corruption/sizing on a single host (`EventLog-A.md`); general WinRM/remoting failures (`WinRM-A.md`); audit policy design (what to *generate*) beyond what WEF needs.

**Assumed role:** L2/L3 engineer with Domain Admin or delegated GPO rights and local admin on the collector.

---
## How It Works
<details><summary>Full architecture</summary>

### Roles
- **Source (forwarder):** any Windows machine whose events you want. The forwarding client is hosted inside the **WinRM service** — WinRM must be *running* on the source, but a WinRM *listener* is only needed for collector-initiated subscriptions.
- **Collector (WEC server):** runs **Wecsvc** (Windows Event Collector) and WinRM. Wecsvc owns subscriptions; WinRM/HTTP.sys terminates the connections; received events are written to a destination log (default `ForwardedEvents`).

### Two subscription models

```
SOURCE-INITIATED (push, GPO-driven — recommended for fleets)
 Source                                         Collector
 ─────────────────────────────────────────────  ───────────────────────────────
 GPO: SubscriptionManager =                     Wecsvc: subscription "DC-Security"
   Server=http://wec.contoso.com:5985/            AllowedSourceDomainComputers =
   wsman/SubscriptionManager/WEC,Refresh=60         SDDL of "WEF-DCs" group
 WinRM (forwarder, runs as NETWORK SERVICE)
   1. every Refresh sec: "what subscriptions   ──►  HTTP.sys :5985 /wsman/
      apply to me?" (Kerberos, computer acct)        └─ Wecsvc checks computer acct's
                                                        group SIDs vs Allowed SDDL
   2. receives XPath query + delivery policy   ◄──  subscription XML
   3. reads local channels as NETWORK SERVICE
   4. batches + pushes events                  ──►  Wecsvc writes to ForwardedEvents
   5. heartbeats at the subscription interval  ──►  LastHeartbeatTime updated

COLLECTOR-INITIATED (pull — small, fixed lists)
 Collector connects to each named source over WinRM with a configured credential
 (default: collector computer account). That credential must be in the SOURCE's
 "Event Log Readers" group, and every source needs a WinRM listener + firewall rule.
 Doesn't scale and doesn't follow machines around — use only for a handful of servers.
```

### Authentication and encryption
In a domain, the source authenticates with its **computer account via Kerberos** to SPN `HTTP/<collector FQDN>`, and the payload is encrypted by Kerberos even over "HTTP" port 5985 (Microsoft's own WEF guidance states this; NTLM is the fallback and can be disabled). Consequences:
- Always use the collector's **FQDN** in the SubscriptionManager string; a short name or IP drops you to NTLM or fails.
- Authorisation is by **group SID in the computer's Kerberos ticket**. Adding a computer to the allowed group does nothing until the ticket renews (reboot, or `klist -li 0x3e7 purge`).
- Non-domain sources use **HTTPS/5986 with client certificates** (`Server=https://<FQDN>:5986/wsman/SubscriptionManager/WEC,Refresh=60,IssuerCA=<CA thumbprint>`), a certificate mapping on the collector, and NETWORK SERVICE read access to the client cert's private key. It's a separate project — scope it as such.

### The HTTP.sys URL ACL trap
WinRM and Wecsvc share the URL reservations `http://+:5985/wsman/` and `https://+:5986/wsman/`. The default ACL on Server 2016+ grants only `NT SERVICE\WinRM`. That worked when both services shared one svchost process. With svchost splitting (Server 2019+ on hosts with >3.5 GB RAM), Wecsvc runs in its own process, isn't permitted on the URL, and sources log **Forwarding/Operational 105** with error **2150859027** ("requested HTTP URL was not available"). The fix adds the Wecsvc service SID to the ACL (KB 4494462). **Implication:** a collector that "worked for years" can break after a RAM upgrade or migration to a bigger VM.

### Delivery modes (verified against Microsoft's WEF guidance)
| Mode | Behaviour | Use for |
|---|---|---|
| Normal | Reliable; batches, max latency ~15 min | Default for bulk workstation logs |
| Minimize Bandwidth | Batches up to ~6 h; heartbeat 6 h | WAN-constrained branches |
| Minimize Latency | Pushes within ~30 s | Small high-value sets (DC Security, Sysmon on servers) |
| Custom | Only via `wecutil` — set `DeliveryMaxItems` / `DeliveryMaxLatencyTime` / heartbeat | Tuning at scale |

Event format: the default `RenderedText` includes the localized message text, making each event larger; `Events` (raw) is smaller and suits collectors that feed a SIEM which renders itself (`wecutil ss <sub> /cf:Events`).

### Collector state and scale limits
- Per subscription, Wecsvc keeps a **registry key per source FQDN** (bookmark + heartbeat) under the EventCollector subscriptions key. It isn't pruned automatically. Microsoft notes that past **~1000 lifetime sources per subscription**, Event Viewer's subscription UI can become unresponsive — manage with `wecutil`, and split subscriptions (e.g. by OU/role).
- Concurrent connections are bounded by available TCP ports / HTTP.sys on the collector; sources don't disconnect immediately after sending.
- `ForwardedEvents` defaults to a small size (~20 MB). A busy collector overwrites hours of data. Size deliberately, or use one destination log per subscription.
- Microsoft's sizing guidance by volume: SQL/SEM up to ~5,000 events/sec class, a SEM for 5,000–50,000, big-data stores beyond — i.e. WEC is a **transport and buffer**, not a long-term store.

### What WEF can't give you
- **No events that were never generated.** Audit policy (advanced audit, Sysmon, PowerShell logging) has to be enabled on the source first.
- **No retro-collection beyond the source log.** On first subscription a source can send existing events (`ReadExistingEvents`), limited by what its own log still holds.
- **No health alerting.** An Inactive source is silent unless you monitor `wecutil gr` / the collector's EventCollector log.
</details>

---
## Dependency Stack
```
Layer 7  SIEM / Sentinel / analyst query             (consumes ForwardedEvents via AMA/UF/etc.)
Layer 6  Destination log sized + on suitable volume   ForwardedEvents or custom log
Layer 5  Subscription: enabled, XPath valid, mode, AllowedSourceDomainComputers SDDL
Layer 4  Wecsvc running (Automatic Delayed) + EventCollector state healthy
Layer 3  HTTP.sys URL ACL on /wsman/ grants WinRM AND Wecsvc SIDs
Layer 2  WinRM listener on collector (HTTP 5985 / HTTPS 5986) + inbound firewall
Layer 1  Kerberos: SPN HTTP/<collector FQDN>, source computer ticket carries allowed-group SID
Layer 0  Source: GPO SubscriptionManager string → WinRM service running → NETWORK SERVICE
         can read each channel (Security needs Event Log Readers / channel SDDL) → audit
         policy actually generates the events → DNS + route to collector
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| No source ever appears in `wecutil gr` | GPO not applied / typo in Server= string / firewall | `gpresult`, SubscriptionManager registry, `Test-WSMan <FQDN>` |
| Sources log Event 105, error 2150859027 | URL ACL lacks Wecsvc SID (svchost split) | `netsh http show urlacl url=http://+:5985/wsman/` |
| Worked until collector got more RAM / was rebuilt | Same URL ACL trap | Compare Wecsvc vs WinRM PID |
| New PCs added to group never show | Kerberos ticket not refreshed | `klist -li 0x3e7` on source; reboot |
| Source Active, System events arrive, Security doesn't | NETWORK SERVICE lacks Security channel read | `wevtutil gl security`; Event Log Readers |
| Source Inactive after working | Source offline/decommissioned, or cert/Kerberos change | `wecutil gr` LastError, LastHeartbeatTime |
| Events ~15 min late | Normal mode batching | `wecutil gs <sub>` ConfigurationMode |
| Only newest events on collector, old ones gone | ForwardedEvents wrapping | `Get-WinEvent -ListLog ForwardedEvents` |
| Event Viewer hangs on Subscriptions | Thousands of lifetime sources on one subscription | `wecutil gr` count; split subscriptions |
| Specific event IDs missing, others arrive | XPath filter excludes them, or audit policy not generating them | Test XPath locally with `Get-WinEvent -FilterXml`; `auditpol /get` on source |
| Collector CPU/disk pegged | RenderedText format + MinLatency on large fleet, huge single log | Switch to `Events` format, Normal/Custom, split logs |
| Workgroup/DMZ source can't connect | HTTP/Kerberos impossible off-domain | Needs HTTPS + client certificate model |

---
## Validation Steps
1. **Collector baseline** — `Get-Service Wecsvc, WinRM` → both Running; Wecsvc Automatic. Bad: Wecsvc Manual/Stopped → `wecutil qc`.
2. **Listener** — `winrm enumerate winrm/config/listener` → `Transport = HTTP`, `Port = 5985`, `Enabled = true`. Bad: no listener → `winrm quickconfig` / WinRM GPO.
3. **URL ACL** — `netsh http show urlacl url=http://+:5985/wsman/` → both `NT SERVICE\WinRM` and `NT SERVICE\Wecsvc`. Bad: WinRM only.
4. **Subscriptions** — `wecutil es` lists names; `wecutil gs <sub>` → `Enabled: true`, `SubscriptionType: SourceInitiated`, expected `ConfigurationMode`, `LogFile`, `AllowedSourceDomainComputers` SDDL containing the group's SID. Bad: wrong group SID (e.g. group recreated with same name → new SID).
5. **Runtime** — `wecutil gr <sub>` → sources `Active` with a heartbeat within the mode's interval. Bad: `Inactive`/`Trying` + LastError.
6. **Source policy** — SubscriptionManager registry value exactly matches the collector FQDN form. Bad: short name, IP, missing `/WEC`.
7. **Source transport** — `Test-WSMan <collector FQDN>` succeeds. Bad: WinRM client error → WinRM-A.md.
8. **Source channel access** — `wevtutil gl security` channelAccess contains `S-1-5-20` read ACE, or NETWORK SERVICE in Event Log Readers.
9. **End-to-end** — on a source: `eventcreate /T INFORMATION /ID 999 /L APPLICATION /SO WEFTest /D "WEF test <timestamp>"` (subscription must include Application). On the collector after one delivery interval: `Get-WinEvent -LogName ForwardedEvents -FilterXPath "*[System[EventID=999]]" -MaxEvents 5`.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Enrolment (source → "what subscriptions apply to me?")**
Look at the source's `Microsoft-Windows-Forwarding/Operational`. Nothing at all = the forwarder has no SubscriptionManager configured (GPO). Event 105 = it tried and failed; the error code tells you whether it's HTTP.sys (2150859027 — URL ACL), a network/WinRM client failure (test with `Test-WSMan`), or authentication.

**Phase 2 — Authorisation (collector decides "is this computer allowed?")**
Source reaches the collector but never appears in `wecutil gr`. Compare the source's group membership (`whoami /groups` won't help — use `Get-ADComputer <name> -Properties MemberOf`) against the subscription's AllowedSourceDomainComputers SDDL. Translate SIDs in the SDDL: `(New-Object System.Security.Principal.SecurityIdentifier '<SID>').Translate([System.Security.Principal.NTAccount])`. Then refresh the source's ticket.

**Phase 3 — Delivery (events flow)**
Source is Active but specific events don't arrive: validate the XPath on the source with `Get-WinEvent -FilterXml` (copy the `<QueryList>` from `wecutil gs <sub> /f:xml`). If the query returns nothing locally, it's the query or audit policy — not WEF. If it returns events locally but not on the collector, check channel access (Security) and delivery mode latency.

**Phase 4 — Retention (events arrive but disappear)**
Destination log sizing, SIEM ingestion lag, or a second subscription writing to the same log and crowding it out.

**Phase 5 — Scale (collector degrades)**
Count sources per subscription, check event format (RenderedText vs Events), delivery mode, disk queue on the log volume. Split by role (DCs / servers / workstations) onto separate subscriptions and, if needed, separate collectors pointed to by separate GPOs.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Stand up a collector correctly (greenfield)</summary>

```powershell
# On the collector (Windows Server, domain-joined, static IP, dedicated data volume)
wecutil qc /q
winrm quickconfig -quiet            # skip if WinRM is GPO-managed
# Pre-empt the svchost/URL ACL trap
$sddl = 'D:(A;;GX;;;S-1-5-80-569256582-2953403351-2909559716-1301513147-412116970)(A;;GX;;;S-1-5-80-4059739203-877974739-1245631912-527174227-2996563517)'
netsh http delete urlacl url=http://+:5985/wsman/
netsh http add urlacl url=http://+:5985/wsman/ sddl=$sddl
Restart-Service WinRM, Wecsvc
# Size destination log
wevtutil sl ForwardedEvents /ms:4294967296 /lfn:D:\EventLogs\ForwardedEvents.evtx
Restart-Service Wecsvc
```
Then create the subscription (Event Viewer → Subscriptions → Create → *Source computer initiated* → Select Computer Groups → add an AD group such as `WEF-Sources-Workstations`), or import XML with `wecutil cs <file.xml>`.
GPO for sources (linked to the OUs holding them):
- *Event Forwarding → Configure target Subscription Manager* = `Server=http://<collector FQDN>:5985/wsman/SubscriptionManager/WEC,Refresh=60`
- *System Services → Windows Remote Management (WS-Management)* = Automatic
- Restricted Groups / GPP: `NT AUTHORITY\NETWORK SERVICE` into `Event Log Readers` (if Security is collected)
**Rollback:** `wecutil ds <sub>`, unlink GPO; URL ACL rollback per `WindowsEventForwarding-B.md` Fix 2.
</details>

<details><summary>Playbook 2 — Re-scope a subscription to a new group</summary>

```powershell
wecutil gs '<sub>' /f:xml > "$env:TEMP\<sub>-backup.xml"      # rollback copy
$sid = (Get-ADGroup '<NewGroup>').SID.Value
# Allow domain computers in that group (GA = generic all)
wecutil ss '<sub>' /adc:"O:NSG:BAD:P(A;;GA;;;$sid)S:"
wecutil gs '<sub>' | Select-String AllowedSourceDomainComputers
```
Sources in the new group must refresh their Kerberos ticket. **Rollback:** `wecutil ds '<sub>'` then `wecutil cs "$env:TEMP\<sub>-backup.xml"` (removing and recreating discards per-source bookmarks — sources may resend existing events if `ReadExistingEvents` is true).
</details>

<details><summary>Playbook 3 — Reduce collector load</summary>

```powershell
wecutil ss '<sub>' /cf:Events          # raw events, no rendered text
wecutil ss '<sub>' /cm:Normal          # stop using MinLatency for bulk subscriptions
# Custom batching (example: 500 items or 5 min, whichever first)
wecutil ss '<sub>' /cm:Custom /dmi:500 /dmlt:300000
```
Split large subscriptions: create `WS-Baseline` (workstations, Normal) and `DC-Security` (DCs, MinLatency) with separate groups and destination logs. Check your SIEM parser handles `Events` format before switching — some rely on rendered text.
</details>

<details><summary>Playbook 4 — Prune stale lifetime sources</summary>

Decommissioned machines leave per-source state on the collector forever. Safest approach — recreate the subscription during a quiet window:

```powershell
wecutil gs '<sub>' /f:xml > "$env:TEMP\<sub>-backup.xml"
wecutil ds '<sub>'
wecutil cs "$env:TEMP\<sub>-backup.xml"
```
**Risk:** all sources re-enrol on their next Refresh; with `ReadExistingEvents=true` each resends what its local log still holds (duplicate burst). Set `ReadExistingEvents` to false in the XML before re-creating if duplicates matter. Avoid hand-deleting EventCollector registry keys.
</details>

<details><summary>Playbook 5 — Collector migration without losing sources</summary>

1. Build the new collector (Playbook 1), import subscription XML from the old one (`wecutil gs <sub> /f:xml` → `wecutil cs`).
2. Change the GPO `Server=` string to the new FQDN (or, to avoid touching GPO, move a DNS CNAME — but Kerberos then needs SPN `HTTP/<cname>` registered to the new collector account: `setspn -S HTTP/<cname FQDN> <NEWWEC$>`).
3. Watch `wecutil gr` on the new collector fill; keep the old one read-only until sources stop reporting there.
**Rollback:** revert the GPO/DNS change; sources return on next Refresh.
</details>

---
## Evidence Pack
```powershell
# Run elevated on the COLLECTOR. Output: $env:TEMP\WEF-Evidence-<timestamp>\
$out = Join-Path $env:TEMP ("WEF-Evidence-{0:yyyyMMdd-HHmmss}" -f (Get-Date))
New-Item -ItemType Directory -Path $out -Force | Out-Null
Get-CimInstance Win32_Service -Filter "Name='Wecsvc' OR Name='WinRM'" |
  Select-Object Name, State, StartMode, ProcessId | Export-Csv "$out\services.csv" -NoTypeInformation
netsh http show urlacl url=http://+:5985/wsman/  > "$out\urlacl-5985.txt"
netsh http show urlacl url=https://+:5986/wsman/ > "$out\urlacl-5986.txt"
winrm enumerate winrm/config/listener > "$out\listeners.txt" 2>&1
$subs = wecutil es
$subs | Out-File "$out\subscriptions.txt"
foreach ($s in $subs) {
    $safe = $s -replace '[^\w\-]', '_'
    wecutil gs "$s" /f:xml > "$out\sub-$safe.xml"
    wecutil gr "$s"        > "$out\runtime-$safe.txt"
}
Get-WinEvent -ListLog ForwardedEvents | Select-Object LogFilePath, RecordCount, FileSize, MaximumSizeInBytes, LogMode |
  Export-Csv "$out\forwardedevents.csv" -NoTypeInformation
Get-WinEvent -LogName 'Microsoft-Windows-EventCollector/Operational' -MaxEvents 200 -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id, LevelDisplayName, Message | Export-Csv "$out\eventcollector-log.csv" -NoTypeInformation
Get-NetFirewallRule -DisplayGroup 'Windows Remote Management' -ErrorAction SilentlyContinue |
  Select-Object DisplayName, Enabled, Profile, Direction, Action | Export-Csv "$out\firewall.csv" -NoTypeInformation
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
Write-Host "Evidence: $out.zip"
```
From an affected source, add: `Get-WEFHealth.ps1 -Role Source -CollectorFqdn <FQDN>` output, and `Microsoft-Windows-Forwarding/Operational` export (`wevtutil epl Microsoft-Windows-Forwarding/Operational $env:TEMP\fwd.evtx`).

---
## Command Cheat Sheet
| Command | Purpose |
|---|---|
| `wecutil qc /q` | Configure Wecsvc on the collector |
| `wecutil es` | List subscriptions |
| `wecutil gs <sub> [/f:xml]` | Subscription config (export XML for backup) |
| `wecutil gr <sub>` | Runtime status, per-source Active/Inactive, LastError, heartbeat |
| `wecutil ss <sub> /cm:MinLatency` | Change delivery mode |
| `wecutil ss <sub> /cf:Events` | Switch to raw event format |
| `wecutil rs <sub>` | Retry inactive sources |
| `wecutil cs <file.xml>` / `wecutil ds <sub>` | Create / delete subscription |
| `netsh http show urlacl url=http://+:5985/wsman/` | Check WinRM+Wecsvc URL ACL |
| `winrm enumerate winrm/config/listener` | Collector listener |
| `Test-WSMan <collector FQDN>` | Source → collector transport test |
| `klist -li 0x3e7 purge` | Refresh source computer's Kerberos tickets (group changes) |
| `wevtutil gl security` | Security channel access SDDL |
| `wevtutil sl ForwardedEvents /ms:<bytes>` | Resize destination log |
| `Get-WinEvent -LogName Microsoft-Windows-Forwarding/Operational -MaxEvents 20` | Source-side forwarder errors (105) |

---
## 🎓 Learning Pointers
- **Adding RAM to a WEC server can break it.** The svchost split on hosts >3.5 GB separates Wecsvc from WinRM, and the default URL ACL only trusts WinRM. Apply the ACL fix on every new collector build, not only after it breaks. [KB 4494462](https://learn.microsoft.com/en-us/troubleshoot/windows-server/admin-development/events-not-forwarded-by-windows-server-collector); background: [Changes to Service Host grouping](https://learn.microsoft.com/en-us/windows/application-management/svchost-service-refactoring).
- **Delivery modes, the per-source registry bloat, the >1000 lifetime-source Event Viewer slowdown, and Kerberos encryption over HTTP** are all documented in Microsoft's [Use Windows Event Forwarding to help with intrusion detection](https://learn.microsoft.com/en-us/windows/security/operating-system-security/device-management/use-windows-event-forwarding-to-assist-in-intrusion-detection) — the closest thing to an official WEF design guide.
- **Treat WEC as transport, not storage.** Pair it with a SIEM/Sentinel (via Azure Monitor Agent on the collector, or your SIEM's forwarder) and keep ForwardedEvents as a buffer sized for an outage of the downstream pipe.
- **Defender for Identity** can take Windows events via WEF when the sensor can't run on a server — see [Configure Windows event forwarding (MDI)](https://learn.microsoft.com/en-us/defender-for-identity/deploy/configure-event-forwarding) and cross-reference `Security/Defender/MDI-A.md`.
- The archived TechNet [Windows Event Forwarding: Survival Guide](https://learn.microsoft.com/en-us/archive/technet-wiki/33895.windows-event-forwarding-survival-guide) and Palantir's `windows-event-forwarding` GitHub repo (subscription XML packs, custom channels) are the community standards for large deployments.
- WEF only forwards what the source generates — audit policy lives in `Security/` and Group Policy; source-side transport faults overlap with `WinRM-A.md`.
