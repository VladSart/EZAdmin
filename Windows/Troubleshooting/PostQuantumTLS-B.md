# Post-Quantum Hybrid TLS (ML-KEM) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate a hybrid post-quantum TLS ticket in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

> **Source note:** Hybrid TLS 1.3 key exchange using ML-KEM (FIPS 203) groups reached General Availability for Windows 11 24H2/25H2 and Windows Server 2025 with the July 14, 2026 update (KB5099536, OS build 26100.33158), per Microsoft's Security Blog and the Win32 "TLS Supported Groups" Learn reference. The three groups (`x25519_mlkem768`, `secp256r1_mlkem768`, `secp384r1_mlkem1024`) are **disabled by default** — nothing changes on an eligible, patched machine until an admin explicitly enables them.

Run these first — results tell you which fix path to follow:

```powershell
# 1. Is this machine even eligible (build + hotfix)?
[System.Environment]::OSVersion.Version
Get-HotFix | Where-Object { $_.HotFixID -eq "KB5099536" }
# Need build 26100.33158+ (Windows 11 24H2/25H2, or Windows Server 2025 with the equivalent CU)

# 2. Are the ML-KEM hybrid groups currently enabled on this machine, and in what order?
Get-TlsEccCurve | Select-Object Name, Position
# Look for x25519_mlkem768 / secp256r1_mlkem768 / secp384r1_mlkem1024 in the list.
# If the TLS module cmdlets aren't found, install: Add-WindowsCapability -Online -Name Tls.ECC.PowerShell~~~~0.0.1.0 (if applicable) or confirm the "TLS" PowerShell module is present.

# 3. Is a Group Policy pushing an ECC Curve Order that overrides local state?
gpresult /r | Select-String "SSL Configuration" -Context 2,4

# 4. Confirm the connection is actually TLS 1.3 — hybrid PQC is TLS 1.3-only and silently
#    has no effect on TLS 1.2 or earlier connections
# (No single built-in cmdlet reports negotiated TLS version for an arbitrary remote endpoint;
#  use a packet capture or the target service's own connection log for this — see Diagnosis Step 4)
```

**Interpretation table:**

| Finding | Action |
|---|---|
| Build below 26100.33158 / KB5099536 missing | Not eligible — patch first. Close as "not eligible" until updated |
| `Get-TlsEccCurve` doesn't list any `*_mlkem*` group | Hybrid PQC not yet enabled on this machine (expected — disabled by default) — Fix 1 |
| Enabled locally but GPO keeps resetting it | A GPO-pushed ECC Curve Order list doesn't include the ML-KEM groups and is overriding local config on next `gpupdate`/reboot — Fix 2 |
| Enabled on server, but client connections still show classical-only negotiation | Both ends must support AND enable a matching group — check the client side, not just the server — Fix 3 |
| Handshake failures/timeouts through a firewall, load balancer, or TLS-inspection proxy after enabling | Middlebox ClientHello-size intolerance — a well-documented compatibility risk with hybrid PQC groups — Fix 4 |
| FIPS-mode device needs both FIPS compliance and PQC | Not currently supported together — none of the three hybrid groups are available in legacy FIPS mode — Fix 5 |
| Org wants to pilot hybrid PQC before a fleet-wide push | Enable via PowerShell on a pilot set first, not GPO — Fix 1, scoped |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Windows 11 24H2/25H2 (build 26100.33158+, KB5099536 or later) OR
Windows Server 2025 with the equivalent cumulative update
        │
TLS 1.3 in use for the connection
   Hybrid ML-KEM groups are TLS 1.3-ONLY — they have zero effect on TLS 1.0/1.1/1.2
   connections, which negotiate exclusively among the pre-existing classical groups
        │
At least one hybrid group explicitly ENABLED (all three are OFF by default):
   x25519_mlkem768 | secp256r1_mlkem768 | secp384r1_mlkem1024
   via Group Policy (SSL Configuration Settings > ECC Curve Order) OR the
   TLS PowerShell module (Enable-TlsEccCurve)
        │
NOT running in legacy FIPS mode
   (none of the three hybrid groups are available in FIPS mode as of this writing)
        │
BOTH ends of the connection support AND have enabled a matching hybrid group
   Enabling only on the server (or only on the client) does not force hybrid PQC —
   the connection silently falls back to whatever classical group both sides
   DO support, with no error and no obvious client-side symptom
        │
Network path (firewalls, load balancers, TLS-inspection/SSL-offload proxies)
tolerates an enlarged ClientHello (~1,200-1,500 bytes vs. ~300 bytes classical)
   Legacy middleboxes assuming a single-TCP-segment ClientHello can stall or
   silently drop the enlarged handshake — the dominant real-world failure mode
        │
Reboot completed after enabling (recommended — new/changed ECC curve priority
order is documented to take effect on next boot for GPO-delivered changes)
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm eligibility**
```powershell
[System.Environment]::OSVersion.Version
Get-HotFix | Where-Object { $_.HotFixID -eq "KB5099536" }
```
Below build 26100.33158 → not eligible, stop here and patch.

**Step 2 — Confirm current enabled groups and priority order**
```powershell
Get-TlsEccCurve | Format-Table Name, Position -AutoSize
```
No `*_mlkem*` entries → hybrid PQC is off (expected default state).

**Step 3 — Confirm no conflicting Group Policy is overriding local state**
```powershell
gpresult /r | Select-String "SSL Configuration" -Context 2,4
```
If a GPO-managed ECC Curve Order list is in effect and does NOT include the ML-KEM group strings, any local `Enable-TlsEccCurve` change will be reset on next Group Policy refresh/reboot — the GPO must be updated instead of (or in addition to) the local change.

**Step 4 — Confirm the actual negotiated group for a specific connection (when a handshake-level dispute needs proof)**
No single built-in PowerShell cmdlet reports the negotiated TLS group for an arbitrary connection. Use one of:
```powershell
# If curl.exe 8.x+ with a PQC-aware TLS backend is available:
curl.exe -v --tlsv1.3 --curves x25519_mlkem768 https://<endpoint> 2>&1 | Select-String "TLSv1.3|subject|SSL connection"
```
Or capture the handshake with a network trace (Wireshark/`netsh trace`) and inspect the ClientHello `supported_groups` extension and ServerHello's selected group directly — this is the only fully authoritative method and the one to use for escalation evidence.

**Step 5 — Confirm FIPS mode isn't the blocker**
```powershell
Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\FipsAlgorithmPolicy" -Name Enabled -ErrorAction SilentlyContinue
```
`Enabled = 1` (legacy FIPS mode on) → none of the three hybrid groups can be used on this device, regardless of any other configuration.

---

## Common Fix Paths

<details><summary>Fix 1 — Enable hybrid PQC groups (pilot or single-machine)</summary>

**Cause:** Groups are disabled by default; nothing enables them automatically on a patched machine.

```powershell
# Enable and prioritize (Position 0 = highest priority, tried first)
Enable-TlsEccCurve -Name x25519_mlkem768 -Position 0

# Verify
Get-TlsEccCurve | Format-Table Name, Position -AutoSize
```

Reboot recommended for the change to take full effect. For a broader pilot group (not GPO-managed), repeat via remote PowerShell (`Invoke-Command`) against each pilot machine rather than one at a time interactively.

**Rollback:**
```powershell
Disable-TlsEccCurve -Name x25519_mlkem768
```

</details>

<details><summary>Fix 2 — Local change keeps getting reset by Group Policy</summary>

**Cause:** A GPO under Computer Configuration > Administrative Templates > Network > SSL Configuration Settings > **ECC Curve Order** is pushing an explicit priority list that does not include the ML-KEM group strings — GPO-delivered curve order overrides local PowerShell-cmdlet changes on the next policy refresh/reboot.

**Remediation:**
1. Identify the GPO: `gpresult /r` (Step 3 of Diagnosis) or the Group Policy Management Console
2. Edit the GPO's ECC Curve Order list to append the desired hybrid group string(s) — `x25519_mlkem768,secp256r1_mlkem768,secp384r1_mlkem1024` — to the existing comma-delimited priority list (do not simply replace the whole list; preserve the existing classical curve order unless intentionally changing it)
3. `gpupdate /force` on a test machine, then reboot, then re-run `Get-TlsEccCurve` to confirm

**Rollback:** Revert the GPO's ECC Curve Order list to its prior value; `gpupdate /force`; reboot.

</details>

<details><summary>Fix 3 — Enabled on one end, but connections still negotiate classical-only</summary>

**Cause:** Hybrid PQC requires BOTH the client and the server (or, for Schannel-consuming services in the middle, whichever two endpoints are actually negotiating) to support and have enabled a matching group. Enabling only server-side (or only client-side) produces a silent, error-free fallback to a classical group — there is no failure, warning, or log entry by default.

**Remediation:**
1. Confirm the group is enabled on BOTH ends via `Get-TlsEccCurve` (or the equivalent for the non-Windows end, if applicable)
2. If testing against an external/public endpoint, confirm that endpoint's own PQC support independently — do not assume "I enabled it, so it should be using it" without confirming the peer
3. Use the packet-capture method (Diagnosis Step 4) to confirm the actual negotiated group when in doubt — do not rely on the absence of errors as proof hybrid PQC is active

**Rollback:** N/A — not a fault to roll back; expected behavior when one side lacks matching configuration.

</details>

<details><summary>Fix 4 — Handshake failures/timeouts after enabling (middlebox intolerance)</summary>

**Cause:** Hybrid ML-KEM key shares substantially enlarge the ClientHello message (roughly 300 bytes classical-only → 1,200-1,500+ bytes with hybrid groups and, if also present, PQ signature algorithms). Some legacy firewalls, load balancers, and TLS-inspection/SSL-offload proxies assume a TLS handshake fits in a single TCP segment and can silently drop, stall, or reset the connection when it doesn't — a well-documented, widely-reported compatibility issue independent of Windows specifically.

**Remediation:**
1. Confirm the failure correlates with enabling hybrid PQC — disable it temporarily (`Disable-TlsEccCurve`) on an affected client/server and retest; if the failure disappears, the middlebox theory is confirmed
2. Identify every network appliance in the connection path (firewall, load balancer, forward/reverse proxy, WAF) and check each vendor's current PQC/large-ClientHello support status
3. If a specific network path can't yet tolerate the larger handshake, scope hybrid PQC enablement to exclude traffic through that path (e.g., don't enable on internet-facing services behind an unpatched WAF) rather than disabling it fleet-wide
4. Engage the network appliance vendor for a firmware/software update roadmap if PQC support is business-critical

**Rollback:** `Disable-TlsEccCurve -Name <group>` on the affected endpoint(s); confirm connectivity restored before re-attempting.

</details>

<details><summary>Fix 5 — FIPS-mode device needs both FIPS compliance and hybrid PQC</summary>

**Cause:** As of this writing, none of the three ML-KEM hybrid groups are available under legacy Windows FIPS mode (`FipsAlgorithmPolicy` enabled) — this is a genuine, current product limitation, not a misconfiguration.

**Remediation:**
1. Confirm this is actually the blocker: `Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\FipsAlgorithmPolicy"`
2. Document as a known limitation for the client — do not spend time hunting for a FIPS-compatible enablement path that doesn't exist yet
3. Note Microsoft's own current guidance: the legacy FIPS mode setting itself is "no longer recommended nor required to operate with FIPS approval" — using FIPS-approved algorithms directly (which the classical curves already are) is the documented path to FIPS approval, independent of the legacy toggle; this may be a useful reframing for a client's compliance team, but confirm against their specific FIPS 140 validation requirements before treating it as a resolution

**Rollback:** N/A — not a fault to roll back.

</details>

---

## Escalation Evidence

```
ESCALATION TICKET — Post-Quantum Hybrid TLS Issue
=====================================
Device Name:               [hostname]
Role:                      [Client / Server / Both ends tested]
Windows Build:              [output of [System.Environment]::OSVersion.Version]
KB5099536 or later:         [Yes/No — Get-HotFix]
Enabled hybrid groups:      [output of Get-TlsEccCurve]
GPO-managed ECC Curve Order in effect: [Yes/No — gpresult /r]
FIPS mode enabled:          [Yes/No]
Remote endpoint tested:     [hostname/IP]
Confirmed negotiated group (packet capture): [group name / "not captured"]
Network path appliances in between: [firewall/LB/proxy vendor + version, if known]

Symptom description:
[what was reported — no PQC effect observed / handshake failures / timeouts]

Steps already attempted:
[ ] Confirmed build/hotfix eligibility
[ ] Confirmed Get-TlsEccCurve state on both client and server
[ ] Checked for a conflicting GPO-managed ECC Curve Order
[ ] Confirmed TLS 1.3 is actually in use for the affected connection
[ ] Ruled out FIPS mode as the blocker
[ ] Captured a packet trace of the ClientHello/ServerHello if handshake-level proof needed
[ ] Tested with hybrid PQC temporarily disabled to isolate middlebox involvement
```

---

## 🎓 Learning Pointers

- **Disabled by default means "enabled on the server" alone does nothing observable.** The single most common false "it's not working" report will be a server correctly configured with no matching client-side configuration — always check both ends before assuming a server-side fault.

- **TLS 1.3 is a hard prerequisite, not a suggestion.** Any connection still negotiating TLS 1.2 or earlier (common for legacy clients, some LOB apps, or intentionally-pinned TLS versions) will never use hybrid PQC regardless of how the groups are configured — confirm the TLS version in use before troubleshooting further.

- **The enlarged ClientHello is the real-world compatibility risk, not the cryptography itself.** Test hybrid PQC through every network appliance in a production path (firewalls, load balancers, TLS-inspection proxies) before broad rollout — this is a well-documented, cross-vendor issue, not Windows-specific. [TLS Supported Groups in Windows 11 24H2, Windows Server 2025, and later — Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/secauthn/tls-supported-groups-in-windows-11-24h2-and-later)

- **"Harvest now, decrypt later" is the actual threat this defends against** — an adversary capturing today's classically-encrypted traffic now, to decrypt once a cryptographically-relevant quantum computer exists. This is why hybrid (classical + PQ combined) matters even before quantum computers capable of breaking classical key exchange exist: security holds as long as at least one of the two combined algorithms remains unbroken. [New Windows Features to Secure Today's Data in a Post-Quantum World — Microsoft Security Blog](https://techcommunity.microsoft.com/blog/microsoft-security-blog/new-windows-features-to-secure-today%e2%80%99s-data-in-a-post-quantum-world/4523370)

- **Direct registry editing of the default TLS priority order is explicitly unsupported by Microsoft** and may be reset by servicing updates — use Group Policy or the TLS PowerShell cmdlets (`Enable-TlsEccCurve`/`Disable-TlsEccCurve`), never a raw registry edit, even though the GPO setting is itself registry-backed under the hood.
