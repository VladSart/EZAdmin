# Post-Quantum Hybrid TLS (ML-KEM) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why hybrid key exchange changes the TLS handshake, not just how to flip it on.

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

**In scope:**
- Hybrid post-quantum TLS 1.3 key exchange (ML-KEM/FIPS 203 combined with classical ECDH) as implemented by the Microsoft Schannel provider in Windows 11 24H2/25H2 and Windows Server 2025
- The three supported hybrid groups, their configuration surfaces (Group Policy, TLS PowerShell cmdlets), and default (disabled) state
- The middlebox/ClientHello-size compatibility risk that dominates real-world rollout friction
- FIPS mode interaction and current limitations

**Out of scope:**
- Post-quantum digital signatures (ML-DSA/SLH-DSA) and certificate-chain PQC — a related but architecturally separate migration surface not covered by this runbook
- Non-Windows TLS stacks (OpenSSL/BoringSSL/etc.) except where needed to explain interoperability
- The broader NIST PQC standardization timeline and cryptographic proofs — treated as settled background, not re-derived here

**Assumptions:**
- Reader has local admin (or GPO edit rights) and basic familiarity with TLS handshake mechanics (ClientHello/ServerHello, key exchange vs. authentication)
- Windows 11 24H2/25H2 (build 26100.33158+, KB5099536 or later) or Windows Server 2025 with the equivalent cumulative update
- **Source-confidence note:** the core GA facts (groups, minimum builds, disabled-by-default state) are corroborated directly from the Microsoft Learn "TLS Supported Groups" Win32 reference page (ms.date 2026-05-20, updated 2026-05-29) and Microsoft's own Security Blog post. The exact GPO-backed registry value name/path for ECC Curve Order is long-established (used since Windows 10/Server 2016 for classical curve prioritization, per `manage-tls` documentation) and is extended, not replaced, by the three new group strings — treat the registry-level detail as inference from that established mechanism rather than a value Microsoft has newly and explicitly documented for the ML-KEM groups specifically.

---

## How It Works

<details><summary>Full architecture</summary>

### The Threat Model: Harvest Now, Decrypt Later

Classical TLS key exchange (ECDHE using curves like X25519 or NIST P-256/P-384) is believed secure against any currently-existing computer, classical or otherwise. The threat hybrid PQC defends against is prospective: an adversary with the resources to record encrypted TLS traffic today, retained in storage, decrypted retroactively once a cryptographically-relevant quantum computer exists and can break the classical elliptic-curve discrete-log problem the key exchange relies on. Data with a long confidentiality shelf-life (medical records, trade secrets, long-term credentials, government/defense communications) is the primary risk category — an attacker doesn't need quantum capability *today*, only the patience to capture ciphertext now and decrypt it years later.

### Why Hybrid, Not Pure Post-Quantum

Windows does not simply replace classical key exchange with ML-KEM; it combines both in a single key exchange operation per the IETF's hybrid key exchange design for TLS 1.3. The combined shared secret is derived from BOTH the classical ECDH exchange and the ML-KEM encapsulation — security holds as long as **at least one** of the two underlying problems remains hard. This hedges against two distinct failure modes: a future quantum computer breaking the classical component, or an as-yet-undiscovered cryptanalytic weakness in ML-KEM itself (a comparatively new, less battle-tested standard relative to decades-old elliptic-curve cryptography). Neither algorithm alone is trusted to carry the full security burden during this transition period.

### The Three Windows Hybrid Groups

| Supported Group String | Classical Component | Post-Quantum Component | FIPS Mode (legacy) |
|---|---|---|---|
| `x25519_mlkem768` | X25519 (Curve25519 ECDH) | ML-KEM-768 | No |
| `secp256r1_mlkem768` | NIST P-256 ECDH | ML-KEM-768 | No |
| `secp384r1_mlkem1024` | NIST P-384 ECDH | ML-KEM-1024 | No |

`x25519_mlkem768` mirrors the combination most widely adopted across the broader TLS ecosystem (Chrome, Firefox, OpenSSL 3.2+) as of this writing, which makes it the most likely to actually negotiate successfully against non-Windows peers that have also enabled hybrid PQC. `secp384r1_mlkem1024` uses the higher-security-margin NIST P-384/ML-KEM-1024 pairing, relevant for environments with a NIST-curve-only cryptographic policy that also want the strongest available PQC parameter set.

All three groups are TLS 1.3-exclusive per the Supported Groups reference table — none are usable on TLS 1.0/1.1/1.2, which negotiate key exchange through an entirely different mechanism (cipher-suite-embedded key exchange, not the separate Supported Groups/`key_share` extension TLS 1.3 introduced). None are available under legacy Windows FIPS mode as of this writing.

### The Handshake Mechanics That Change

```
CLASSICAL TLS 1.3 ClientHello (key_share extension):
  Client sends: [X25519 ephemeral public key]  (~32 bytes of key material)
  Server responds: [X25519 ephemeral public key]  (ServerHello key_share)
  Both derive the same shared secret via ECDH

HYBRID TLS 1.3 ClientHello (key_share extension, e.g. x25519_mlkem768):
  Client sends: [X25519 ephemeral public key] + [ML-KEM-768 encapsulation key]
                 (~32 bytes)                    (~1,184 bytes)
  Server responds: [X25519 ephemeral public key] + [ML-KEM-768 ciphertext]
                 (~32 bytes)                    (~1,088 bytes)
  Shared secret = KDF(ECDH shared secret || ML-KEM shared secret)
```

The practical consequence: a classical ClientHello is typically a few hundred bytes total; a hybrid ClientHello grows to roughly 1,200-1,500+ bytes once the ML-KEM public key (and, if a client also advertises PQC signature algorithms, additional extension overhead) is included. This is the single most consequential architectural fact for real-world deployment — see the Dependency Stack and Fix 4 in the companion -B.md runbook.

### Negotiation Is Bilateral and Silent

TLS 1.3's Supported Groups negotiation works by the client advertising every group it supports (in priority order) and the server selecting the highest-priority group both sides share. If a client enables `x25519_mlkem768` but the server hasn't, or vice versa, negotiation simply proceeds using whatever classical group both DO support — no error, no downgrade warning, no client-visible indication that PQC was "available but unused." This is standard, correct TLS behavior (graceful capability negotiation), but it means enabling hybrid PQC on only one side of a connection produces a false sense of protection unless explicitly verified via packet capture.

### Configuration Surface: Same Mechanism, New Group Strings

Windows has offered ECC Curve Order configuration (independent of the broader cipher-suite order) since Windows 10/Server 2016, via:
1. **Group Policy** — Computer Configuration > Administrative Templates > Network > SSL Configuration Settings > **ECC Curve Order**, taking a comma-delimited priority list
2. **TLS PowerShell module** — `Get-TlsEccCurve`, `Enable-TlsEccCurve -Name <group> -Position <n>`, `Disable-TlsEccCurve -Name <group>`

The three ML-KEM hybrid groups are exposed through this exact same, pre-existing mechanism rather than a new, PQC-specific configuration surface — they are simply new entries in the same "Supported Group String" namespace the classical curves already occupy, not enabled by default the way the three baseline classical curves (`curve25519`, `nistP256`, `nistP384`) are. Microsoft's own documentation explicitly warns that directly editing the underlying registry values for default priority ordering is unsupported and may be reset by servicing updates — Group Policy and the TLS cmdlets are the only supported configuration paths, even though both are, under the hood, registry-backed.

</details>

---

## Dependency Stack

```
Windows 11 24H2/25H2 (build 26100.33158+, KB5099536+) or
Windows Server 2025 with the equivalent cumulative update
   │
TLS 1.3 negotiated for the connection (hard prerequisite — hybrid groups have
zero effect on TLS 1.0/1.1/1.2, a structurally different key-exchange mechanism)
   │
Not running under legacy Windows FIPS mode
   (FipsAlgorithmPolicy Enabled=1 excludes all three hybrid groups)
   │
At least one hybrid group explicitly enabled via Group Policy (ECC Curve Order)
or TLS PowerShell cmdlets (Enable-TlsEccCurve) — disabled by default, no
automatic opt-in on a freshly patched machine
   │
Reboot completed (GPO-delivered curve-order changes take effect on next boot
per Microsoft's own "Manage TLS ECC order" guidance)
   │
BOTH the client and server independently support AND have enabled a
mutually-shared hybrid group — negotiation is bilateral; a mismatch falls
back silently to classical, with no error on either side
   │
Network path tolerates the enlarged ClientHello (~1,200-1,500+ bytes vs.
~300 bytes classical) — legacy middleboxes assuming single-TCP-segment
handshakes are the dominant real-world compatibility failure mode
   │
Successful hybrid negotiation: shared secret derived from BOTH the classical
ECDH exchange AND the ML-KEM encapsulation — secure as long as at least
one of the two underlying hard problems remains unbroken
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Enabled hybrid PQC, no observable change in any connection | TLS 1.2 or earlier still in use for the connection(s) being tested | Confirm negotiated TLS version via packet capture or target service logs |
| Enabled on server, client-side reports show classical-only negotiation | Client hasn't independently enabled a matching group — this is bilateral, not inherited | Check `Get-TlsEccCurve` on the CLIENT specifically |
| Config applied but reset after a reboot/policy refresh | A GPO-delivered ECC Curve Order list without the ML-KEM strings is overriding local cmdlet changes | `gpresult /r`, check the actual GPO's curve list content |
| Intermittent handshake timeouts/resets, worse through specific network paths | Middlebox ClientHello-size intolerance | Test the same connection bypassing each network appliance individually |
| Works internally, fails for external/internet-facing connections specifically | The external path likely traverses a TLS-inspection proxy, WAF, or older load balancer not present on the internal path | Map the actual network path for both scenarios and diff the appliances involved |
| FIPS-mode device can't enable any hybrid group | Documented current limitation — no hybrid group is available in legacy FIPS mode | `Get-ItemProperty ...FipsAlgorithmPolicy` |
| Works for some peer services, not others, all internally | Peer-side hybrid PQC support/enablement varies — this is expected, not a Windows-side fault | Confirm peer-side TLS stack version and configuration independently |

---

## Validation Steps

**1. Confirm OS/build eligibility:**
```powershell
[System.Environment]::OSVersion.Version
Get-HotFix | Where-Object { $_.HotFixID -eq "KB5099536" }
```

**2. Confirm current enabled groups and their priority order:**
```powershell
Get-TlsEccCurve | Format-Table Name, Position -AutoSize
```

**3. Confirm no GPO conflict:**
```powershell
gpresult /r | Select-String "SSL Configuration" -Context 2,4
```

**4. Confirm FIPS mode state:**
```powershell
Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\FipsAlgorithmPolicy" -Name Enabled -ErrorAction SilentlyContinue
```

**5. Confirm actual negotiated group for a live connection (authoritative proof):**
Packet capture of the TLS ClientHello/ServerHello `key_share` and `supported_groups` extensions is the only fully authoritative method. `curl.exe` with a PQC-aware TLS backend and `--curves` support can approximate this for outbound test connections; for production traffic, a network trace remains the ground truth.

**6. Confirm both peer endpoints independently, not just the one under investigation:**
Hybrid negotiation is bilateral — validating only one side of a connection cannot confirm hybrid PQC is actually in effect.

---

## Troubleshooting Steps (by phase)

### Phase 1: Eligibility Gate
1. Confirm build/hotfix level meets the GA floor (26100.33158 / KB5099536).
2. Confirm the connection in question actually uses TLS 1.3 — this single check resolves the largest share of "enabled it, nothing changed" tickets.

### Phase 2: Local Configuration State
1. Confirm which groups are currently enabled and in what priority order via `Get-TlsEccCurve`.
2. Confirm no conflicting GPO is silently overriding local state on refresh/reboot.
3. Confirm FIPS mode isn't excluding all three groups outright.

### Phase 3: Bilateral Negotiation Verification
1. Independently check both the client and server (or both peers in a service-to-service connection) — never assume one side's configuration implies the other's.
2. Capture the actual handshake if a definitive answer is required for escalation or compliance evidence.

### Phase 4: Network Path Compatibility
1. If handshake failures/timeouts appear specifically after enabling hybrid PQC, map every network appliance in the connection's actual path.
2. Test with hybrid PQC temporarily disabled on one endpoint to confirm/rule out the ClientHello-size theory before engaging a network vendor.
3. Scope enablement to exclude paths through confirmed-incompatible appliances rather than abandoning the rollout entirely.

### Phase 5: Compliance/FIPS Edge Cases
1. For FIPS-mode-required environments wanting hybrid PQC, document the current incompatibility explicitly rather than searching for a workaround that doesn't exist as of this writing.
2. Track Microsoft's roadmap for FIPS-mode PQC support as a future revisit item.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Piloted GPO rollout of hybrid PQC across a fleet</summary>

```
Group Policy Management Console >
Computer Configuration > Administrative Templates > Network > SSL Configuration Settings >
ECC Curve Order → Enabled

SSL ECC Curves list (comma-delimited, append to existing classical list, do not replace):
curve25519,nistP256,nistP384,x25519_mlkem768,secp256r1_mlkem768,secp384r1_mlkem1024

Link the GPO to a PILOT OU first — include representative devices for every network
egress path (internal-only, VPN, and internet-facing/behind any WAF or TLS-inspection
proxy in use) before wider deployment.
```

**Verify:** `gpupdate /force` + reboot on pilot devices, then `Get-TlsEccCurve` to confirm the groups landed with the expected priority order; packet-capture a sample connection through each represented network path.

**Expand:** only after the pilot OU shows clean handshakes across every represented network path for a full patch cycle.

**Rollback:** set the GPO back to Not Configured (or remove the hybrid group strings from the list) and `gpupdate /force` + reboot.

</details>

<details><summary>Playbook 2 — Scoped exclusion for a network path with an incompatible middlebox</summary>

Use when the broader rollout is proceeding but one specific path (e.g., a legacy WAF in front of one internet-facing service) can't yet tolerate the enlarged ClientHello.

```
Create a separate GPO/OU (or local PowerShell exclusion for standalone servers) that
excludes the affected server(s) from the hybrid-PQC-enabled ECC Curve Order list,
while the rest of the fleet proceeds normally.
```

**Verify:** confirm the excluded server(s) negotiate classical-only and function normally; confirm all other servers retain hybrid PQC capability.

**Rollback:** once the middlebox vendor ships compatible firmware/software, move the excluded server(s) back into the standard hybrid-PQC GPO scope and re-validate via packet capture.

</details>

<details><summary>Playbook 3 — Emergency rollback after a widespread handshake-failure incident</summary>

```
Group Policy Management Console > [Hybrid PQC GPO] >
Set ECC Curve Order back to Not Configured, or remove the *_mlkem* strings
from the SSL ECC Curves list
gpupdate /force across affected devices; reboot required
```

**Verify:** confirm affected connections recover using classical-only negotiation; capture a sample handshake to confirm no hybrid groups remain advertised if full rollback is intended.

**Rollback of the rollback:** re-pilot on a smaller, better-instrumented device/path subset once the specific incompatible network element is identified and addressed.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect hybrid post-quantum TLS configuration evidence for escalation
.NOTES     Read-only. Some checks (FIPS registry read) benefit from elevation.
#>

$OutputDir = "C:\Temp\PQCTLS-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# 1. OS build and hotfix currency
[System.Environment]::OSVersion.Version | Out-File "$OutputDir\OSVersion.txt"
Get-HotFix | Where-Object { $_.HotFixID -eq "KB5099536" } | Out-File "$OutputDir\KB5099536.txt"

# 2. Currently enabled ECC/hybrid groups and priority order
Get-TlsEccCurve | Format-Table Name, Position -AutoSize | Out-File "$OutputDir\TlsEccCurves.txt"

# 3. Applied Group Policy result (SSL Configuration Settings section)
gpresult /r | Out-File "$OutputDir\GPResult.txt"

# 4. FIPS mode state
Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\FipsAlgorithmPolicy" -ErrorAction SilentlyContinue |
    Out-File "$OutputDir\FipsMode.txt"

Write-Host "Evidence collected: $OutputDir" -ForegroundColor Green
Compress-Archive -Path "$OutputDir\*" -DestinationPath "$OutputDir.zip"
Write-Host "Archive: $OutputDir.zip" -ForegroundColor Green
Write-Host "NOTE: this evidence pack does not include a packet capture. For authoritative proof of the actually-negotiated group on a live connection, capture the ClientHello/ServerHello separately (Wireshark/netsh trace) and attach alongside this archive." -ForegroundColor Yellow
```

---

## Command Cheat Sheet

```powershell
# OS build / hotfix eligibility
[System.Environment]::OSVersion.Version
Get-HotFix | Where-Object { $_.HotFixID -eq "KB5099536" }

# Current enabled groups and priority
Get-TlsEccCurve | Format-Table Name, Position -AutoSize

# Enable a hybrid group (highest priority)
Enable-TlsEccCurve -Name x25519_mlkem768 -Position 0

# Disable a hybrid group
Disable-TlsEccCurve -Name x25519_mlkem768

# Confirm GPO-managed curve order
gpresult /r | Select-String "SSL Configuration" -Context 2,4

# FIPS mode state
Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\FipsAlgorithmPolicy" -Name Enabled

# Approximate outbound negotiation test (requires PQC-aware curl build)
curl.exe -v --tlsv1.3 --curves x25519_mlkem768 https://<endpoint>

# GPO path (GUI)
gpedit.msc / gpmc.msc
# Computer Configuration > Administrative Templates > Network >
#   SSL Configuration Settings > ECC Curve Order
```

---

## 🎓 Learning Pointers

- **Hybrid, not pure post-quantum, is the deliberate design choice.** Understanding why (hedging against both a future quantum break of ECDH AND an undiscovered weakness in the newer ML-KEM standard) is the fastest way to correctly explain this topic to a client asking "why not just switch to post-quantum entirely?"

- **The negotiation is bilateral and fails silently to classical.** This is standard, correct TLS behavior, not a bug — but it means "I enabled it and nothing broke" is not evidence hybrid PQC is actually in use. Always verify both ends, and use a packet capture for anything that matters for compliance evidence.

- **The enlarged ClientHello, not the cryptography, is what breaks production networks.** Budget real testing time against every network appliance in a path before a broad rollout — this is a documented, cross-vendor, cross-platform issue (Go, browsers, and other TLS stacks report the identical class of failure), not something specific to or fixable purely within Windows. [TLS Supported Groups in Windows 11 24H2, Windows Server 2025, and later — Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/secauthn/tls-supported-groups-in-windows-11-24h2-and-later)

- **Never edit the registry directly for default TLS priority ordering** — Microsoft's own `manage-tls` documentation explicitly flags this as unsupported and subject to being reset by servicing updates, even though Group Policy achieves the same underlying registry state through a supported path. [Manage Transport Layer Security (TLS) in Windows Server — Microsoft Learn](https://learn.microsoft.com/en-us/windows-server/security/tls/manage-tls)

- **FIPS mode and hybrid PQC are currently mutually exclusive on Windows.** This is a genuine, current product limitation worth flagging early to any client operating under a FIPS 140 validation requirement — don't let this surface for the first time during a compliance audit.

- **"Harvest now, decrypt later" reframes urgency correctly.** The relevant question for a client isn't "do we have quantum computers capable of breaking TLS today" (no) but "does any of our currently-encrypted traffic need to remain confidential for the 5-15+ year horizon some quantum-readiness estimates project" — that's the actual business case for prioritizing this rollout ahead of an imminent, concrete threat.
