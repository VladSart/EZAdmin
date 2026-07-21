# DNSSEC for AD-Integrated Zones — Reference Runbook (Mode A: Deep Dive)
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
- DNSSEC zone signing, key management, and validation for AD-integrated DNS zones on Windows Server 2016–2025
- Key Master role architecture, key rollover mechanics (KSK/ZSK), NSEC vs. NSEC3, trust anchor distribution
- Secure delegation (DS records) between parent and child zones
- Client-side DNSSEC awareness (NRPT, DO/AD/CD flags) as it relates to validating vs. non-validating resolvers

**Out of scope:**
- General AD-integrated DNS availability — zone replication scope, DC Locator SRV records, scavenging/aging, forwarders/root hints, split-brain detection — see `AD-DNS-A.md`/`AD-DNS-B.md`. DNSSEC is an *integrity* control layered on top of a working DNS service, not a replacement for it.
- Client-side DNS resolver cache/config troubleshooting unrelated to DNSSEC — see `Windows/Troubleshooting/DNS-Client-A.md`
- DNSSEC for externally-hosted/public-facing domains registered with a third-party registrar (the mechanics of zone signing are the same, but the delegation chain to the root and registrar-side DS record publication introduce a different set of failure points not covered here)
- Azure/Entra-hosted DNS (Azure DNS Private Zones do not support DNSSEC signing at all as of this writing; Entra Domain Services DNS is a managed platform with no DNSSEC exposure) — see `EntraID/Troubleshooting/EntraDomainServices-A.md`
- Third-party/non-Microsoft validating resolvers (BIND, Unbound, Knot) beyond the general RFC 4033/4034/4035 mechanics they share with Windows DNS Server

**Assumptions:**
- DNS Server role is installed on one or more Domain Controllers, hosting AD-integrated primary zones
- You have Domain Admin or delegated DNSSEC-signing rights, and the `DnsServer` PowerShell module is available
- The zone(s) in question are primary and authoritative — DNSSEC properties cannot be viewed, signed, or edited on a secondary zone

---
## How It Works

<details><summary>Full architecture — DNSSEC signing internals on Windows Server</summary>

### What DNSSEC Actually Adds

DNSSEC (RFC 4033/4034/4035) does not change the basic DNS query/response mechanism — it adds a layer of cryptographic signatures (RRSIG records) alongside existing resource records, allowing a client or recursive resolver to verify that a response is authentic and unmodified. It is an **integrity and origin-authentication** control, not confidentiality — DNS responses are still sent in the clear; DNSSEC only lets a validator detect tampering or spoofing, most notably cache-poisoning attacks against recursive resolvers.

### The Resource Records DNSSEC Adds

| Record | Purpose |
|---|---|
| **RRSIG** | The digital signature itself, matched to another record type in the zone |
| **DNSKEY** | Stores the public key used to verify signatures — one flavor for the Zone Signing Key (ZSK), another for the Key Signing Key (KSK) |
| **NSEC** | Proves the *non-existence* of a name (prevents spoofing a "this name doesn't exist" response) |
| **NSEC3** | A privacy-preserving alternative to NSEC that prevents *zone walking* (repeated NSEC queries used to enumerate every name in a zone) — a signed zone uses NSEC or NSEC3, never both |
| **NSEC3PARAM** | Determines which NSEC3 records are returned for non-existent names |
| **DS** (Delegation Signer) | The one record type that is **not** auto-generated at signing time — it lives in the *parent* zone and creates the secure-delegation chain to a signed child zone |

Except for DS, all of these are generated automatically when a zone is signed.

### KSK vs. ZSK — Two Keys, Two Jobs

A signed zone requires at minimum one **Key Signing Key (KSK)** and one **Zone Signing Key (ZSK)** — up to three of each per cryptographic algorithm are supported:

- The **ZSK** signs the actual zone data (the RRSIG records over ordinary resource records). It rotates relatively frequently (default rollover: 90 days) using the **prepublish** method — the new key is published alongside the old one before the old one is retired, so validators always have a currently-valid key available.
- The **KSK** signs the DNSKEY RRSET itself (i.e., it signs the keys, not the data) and is what's referenced by a DS record in the parent zone. It rotates less frequently (default rollover: 755 days ≈ 2 years) using the **double-signature** method — both the old and new KSK sign the DNSKEY set simultaneously during the transition window, since a KSK rollover requires the parent's DS record to be updated too, and that update is a manual, out-of-band step.

**Cryptographic algorithm compatibility is a real constraint, not a formality:** RSA/SHA-1 and RSA/SHA-1 (NSEC3) cannot coexist as signing keys in the same zone, because the NSEC-vs-NSEC3 choice is zone-wide, not per-key. ECDSAP256/SHA-256, ECDSAP384/SHA-384, RSA/SHA-256, and RSA/SHA-512 all support both NSEC and NSEC3 and are the recommended modern choices.

### Why the Key Master Role Exists

Only **one** DNS server per zone acts as **Key Master** — the server responsible for actually performing signing operations and key rollovers. This is true even for AD-integrated zones with many authoritative DNS servers: every DC hosting the zone can *serve* the already-signed data, but only the Key Master *creates* signatures and manages keys.

For AD-integrated zones, the **private signing key material replicates automatically via normal AD DS replication** to every other primary DNS server authoritative for the zone — this is a checkbox at signing time ("Replicate this private key to all DNS servers authoritative for this zone"), enabled by default. If this option is disabled, only the Key Master itself ever holds the private key, which has serious operational consequences if the Key Master is later lost (see Seizing the Key Master Role, below).

**A subtlety specific to AD-integrated zones:** the signed copy of the zone is held **in memory only** on each signing DC — it is never committed to disk. This is a deliberate performance/size decision (committing full signed zone data to the NTDS database on every DC would meaningfully inflate `ntds.dit`). File-backed (non-AD-integrated) signed zones, by contrast, do write their signed copy to a `.dns` zone file on disk. An engineer looking for a signed zone file on an AD-integrated DC and not finding one is seeing expected behavior, not a fault.

### Trust Anchors — How a Validator Learns to Trust a Zone

A **trust anchor** (the DNSKEY or DS record for a zone) must be present on any resolver that will *validate* responses for that zone — this is distinct from merely being authoritative for it. Trust anchors are distributed two different ways depending on server role:

- **On a Domain Controller:** trust anchors are stored in the **forest directory partition** and replicate to every DC in the forest via normal AD DS replication — meaning enabling distribution for a zone signed on one DC eventually makes that trust anchor available forest-wide, not just domain-wide.
- **On a standalone (non-DC) DNS server:** trust anchors are stored in a local file, `TrustAnchors.dns`.

**RFC 5011 automated trust anchor rollover** (`Set-DnsServerDnsSecZoneSetting -EnableRfc5011KeyRollover $True`) allows validators to automatically pick up a new KSK during rollover without manual re-import — without it, every KSK rollover requires someone to manually push updated trust anchors to every validating resolver, a step that is very easy to forget and results in validation silently breaking at the next rollover.

### Secure Delegation — the Manual Step Nobody Remembers

When a parent zone is also signed, a **DS record** in the parent zone creates a cryptographic link ("secure delegation") down to the child zone's KSK, allowing a validator to walk an unbroken chain of trust from the parent down. Critically, **the DS record is never generated or published automatically** — the child zone's signing process produces the necessary digest data (written to a `dsset-<zone>.` file in `%windir%\System32\dns\` on the Key Master), but a human (or automation) must take that data and manually add it as a DS record to the parent zone, on the parent's own primary server.

Skip this step and the child zone is a **valid, correctly-signed "island of trust"**: internal resolvers with the child zone's trust anchor configured directly will validate it fine, but any validator relying purely on the delegation chain from the parent (the normal internet DNSSEC model) will not find a DS record and will simply treat the child as unsigned — no error, just silently reduced protection. `ParentHasSecureDelegation` on `Get-DnsServerDnsSecZoneSetting` reports this state directly and should always be checked, never assumed.

### Client-Side Awareness — DO / AD / CD Bits, and the NRPT

DNSSEC introduces flag bits in the DNS packet header:

- **DO** ("DNSSEC OK", set on a query): the querier is DNSSEC-aware and it's safe for the server to include DNSSEC records in the response
- **AD** ("Authenticated Data", set on a response): the response was successfully validated by the answering/recursive server
- **CD** ("Checking Disabled", set on a query): send the response regardless of whether validation succeeds — used by resolvers that intend to validate the data themselves further upstream/downstream

**The Windows DNS Client (since Windows 7 / Server 2008 R2) is a DNSSEC-aware, non-validating stub resolver.** It can request and display DNSSEC data, and it can be configured to *require* an `AD=1` response via the **Name Resolution Policy Table (NRPT)** — but it never performs cryptographic validation itself. All actual signature verification happens at the recursive/caching DNS server the client queries. This matters operationally: DNSSEC's real security boundary in a typical AD environment is the *recursive server*, not the endpoint — a compromised or misconfigured recursive server is in a position to simply lie about the AD bit, and no amount of client-side NRPT configuration changes that trust relationship.

The **NRPT** is configured per-namespace (e.g., via Group Policy) and its `DnsSecValidationRequired` property is the master switch: if `True`, a DNSSEC-aware client always sets `DO=1` for that namespace and rejects any response that doesn't come back with `AD=1`, even if the zone turns out to be unsigned. If `False` (the default, absent any NRPT rule), the client passively benefits from server-side validation if it happens, but never hard-fails resolution based on it.

### Testing Correctly — the `nslookup.exe` Trap

Microsoft's own documentation explicitly warns against using `nslookup.exe` to test DNSSEC: its internal DNS client implementation predates and is not aware of DNSSEC, so it will never show RRSIG records or surface `DNS_ERROR_UNSECURE_PACKET`-style failures, regardless of the zone's actual state. `Resolve-DnsName` (with the `-DnssecOk` switch, or implicitly when an NRPT rule requires validation) is the only supported way to observe DNSSEC behavior from a Windows client or server.

</details>

---
## Dependency Stack

```
Primary, authoritative DNS zone (AD-integrated or file-backed), currently unsigned
  └── Zone signing initiated — Key Master designated (one signing DNS server per zone)
        └── >=1 KSK (double-signature rollover) + >=1 ZSK (prepublish rollover) generated,
            compatible cryptographic algorithm + NSEC/NSEC3 choice (zone-wide, not per-key)
              └── (AD-integrated, default ON) private signing key replicates via AD DS to
                  every other primary DNS server authoritative for the zone
                    └── Zone signed — RRSIG/DNSKEY/(NSEC or NSEC3) generated automatically
                          ├── (AD-integrated) signed copy held IN MEMORY only on each
                          │   signing DC — never committed to disk
                          └── (file-backed) signed copy committed to the zone file on disk
                                └── Trust anchor (DNSKEY/DS) distribution:
                                    ├── DC — forest directory partition, forest-wide AD
                                    │   DS replication
                                    └── Standalone server — local TrustAnchors.dns file
                                          ├── (optional) RFC 5011 automatic trust anchor
                                          │   rollover enabled — validators self-update on
                                          │   KSK rollover with no manual step
                                          └── (child zone only, MANUAL, never automatic) DS
                                              record created in the PARENT zone from the
                                              child's dsset-<zone> data → secure delegation
                                                └── Recursive/validating resolver holds a
                                                    current trust anchor AND supports the
                                                    zone's signing algorithm
                                                      └── (optional, via NRPT/GPO) client
                                                          namespace rule sets
                                                          DnsSecValidationRequired=True
                                                            └── Windows DNS Client (non-
                                                                validating stub resolver)
                                                                trusts the server's AD bit —
                                                                it never validates itself
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| `Get-DnsServerDnsSecZoneSetting` errors or returns nothing for a zone | Zone was never signed — confirm this is actually unexpected before treating as a fault | `Invoke-DnsServerZoneSign -SignWithDefault` if signing is genuinely required |
| Zone signing wizard/`Invoke-DnsServerZoneSign` fails with "zone must be unsigned" | Zone is already signed (possibly with stale/undesired parameters) | `Invoke-DnsServerZoneUnsign` first, or use `-DoResign` to reuse existing parameters |
| Adding a second KSK/ZSK fails with an algorithm-compatibility error | RSA/SHA-1 and RSA/SHA-1 (NSEC3) mixed in the same zone, or an NSEC/NSEC3 mismatch | `Get-DnsServerSigningKey -ZoneName <zone>` — review `CryptoAlgorithm` and NSEC/NSEC3 setting per key |
| `KeyMasterStatus: Offline` | The DC holding the Key Master role is down, demoted, or unreachable | `Get-DnsServerDnsSecZoneSetting` → `KeyMasterServer`/`KeyMasterStatus` |
| DNS Manager shows "DNSSEC settings for the zone could not be loaded from the Key Master" | Same as above — Key Master genuinely offline (confirmed) vs. transient network blip (verify before seizing) | `Test-Connection` to the reported Key Master first |
| Seizing the Key Master role succeeds, but the zone silently starts using brand-new keys | The new Key Master never had the private key replicated to it (replication option was disabled at signing time) | Confirm with the client whether "Replicate this private key" was ever enabled; expect to redistribute trust anchors and update the parent DS record |
| Client gets `DNS_ERROR_UNSECURE_PACKET` resolving a name in a DNSSEC-required namespace | Recursive server has no valid trust anchor for the zone, OR the zone's signatures have expired | `Get-DnsServerTrustAnchor` on the recursive server; check RRSIG `Expiration` via `Resolve-DnsName -DnssecOk` |
| Signature expiration keeps recurring even though rollover looks "enabled" | ZSK/KSK rollover frequency configured but the Key Master itself has been offline/unreachable across a rollover boundary, so no new signature was ever generated | `Get-DnsServerSigningKey` → compare `NextRolloverAction`/`RolloverStatus` against `KeyMasterStatus` history |
| A signed child zone validates fine internally but fails/degrades for any external or strict validator | No DS record was ever created in the parent zone — the child is a valid but disconnected "island of trust" | `(Get-DnsServerDnsSecZoneSetting -ZoneName <child>).ParentHasSecureDelegation` |
| KSK setting change (e.g., algorithm, key length) was made but "didn't take effect" | Expected — KSK changes only apply at the *next* KSK rollover, not immediately; same applies to ZSK changes and ZSK rollover | `Get-DnsServerSigningKey` to view current vs. pending key state |
| Testing with `nslookup` shows no RRSIG / no error at all, even on a known-broken zone | `nslookup.exe` is not DNSSEC-aware — this is a testing-tool limitation, not a zone state | Re-test with `Resolve-DnsName -DnssecOk` |
| Different DCs authoritative for the same zone appear to have inconsistent signing behavior | Only the Key Master signs/rolls keys; other DCs serve whatever signed data has replicated to them — a replication lag or a private-key-replication-disabled configuration can make this look inconsistent | Confirm which DC is Key Master; check AD replication health for the zone's partition |

---
## Validation Steps

**Step 1 — Confirm signed state, Key Master identity, and current settings**
```powershell
Get-DnsServerDnsSecZoneSetting -ZoneName "<zone.contoso.com>"
```
Expected: a populated object. `IsKeyMasterServer`/`KeyMasterServer`/`KeyMasterStatus` identify the signing authority; `ParentHasSecureDelegation` reports the delegation-chain state.

**Step 2 — Inventory signing keys and their rollover configuration**
```powershell
Get-DnsServerSigningKey -ZoneName "<zone.contoso.com>"
```
Expected: at least one KSK and one ZSK, each showing a compatible `CryptoAlgorithm`, current `RolloverStatus`, and `NextRolloverAction` date.

**Step 3 — Confirm trust anchor presence on every server expected to validate**
```powershell
Get-DnsServerTrustAnchor -Name "<zone.contoso.com>"
# Repeat with -ComputerName against each relevant recursive/validating server
```
Expected: a trust anchor entry matching the zone's current active KSK.

**Step 4 — Confirm RFC 5011 automatic trust anchor rollover state, if in use**
```powershell
(Get-DnsServerDnsSecZoneSetting -ZoneName "<zone.contoso.com>").EnableRfc5011KeyRollover
```
Expected: `True` if the design intent is zero-touch trust anchor updates across KSK rollovers; `False` means someone must manually update every validator's trust anchor at each KSK rollover — confirm this is a known, owned process if so.

**Step 5 — Validate an actual query end-to-end, the correct way**
```powershell
Resolve-DnsName -Name "<host>.<zone.contoso.com>" -Type A -Server <DC-IP> -DnssecOk
```
Expected: the answer record plus a matching RRSIG record with a future `Expiration`.

**Step 6 — For a signed child zone, confirm the DS record actually exists in the parent**
```powershell
Resolve-DnsName -Name "<child.zone.contoso.com>" -Type DS -Server <ParentZoneDC-IP>
(Get-DnsServerDnsSecZoneSetting -ZoneName "<child.zone.contoso.com>").ParentHasSecureDelegation
```
Expected: a DS record returned from the parent, and `ParentHasSecureDelegation: True`.

**Step 7 — Confirm client-side enforcement expectations match reality**
```powershell
Get-DnsClientNrptPolicy | Where-Object Namespace -like "*<zone.contoso.com>*"
```
Expected: either no rule (validation not enforced client-side, by design) or a rule with `DnsSecValidationRequired: True` matching intended policy.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Signing State Layer
1. Confirm whether the zone is signed at all, and whether that matches design intent
2. If signed, confirm current KSK/ZSK inventory and cryptographic algorithm consistency
3. Confirm NSEC vs. NSEC3 choice is uniform across all signing keys in the zone

### Phase 2 — Key Master / Replication Layer
1. Identify the current Key Master and confirm it is online and reachable
2. Confirm whether private key replication to other authoritative DNS servers is enabled
3. If the Key Master was recently changed (moved or seized), confirm trust anchors and any parent DS record were updated to match

### Phase 3 — Trust Anchor / Validator Layer
1. Confirm trust anchors are present on every server expected to validate responses for the zone
2. Confirm RFC 5011 automatic rollover state matches the operational process in place (automatic vs. manual trust anchor updates)
3. Confirm signature expiration dates are comfortably in the future, not approaching or past

### Phase 4 — Secure Delegation Layer (child zones only)
1. Confirm whether the parent zone is itself signed (a prerequisite for secure delegation to mean anything)
2. Confirm a DS record matching the child's current KSK exists in the parent zone
3. Confirm `ParentHasSecureDelegation` reports `True`

### Phase 5 — Client Enforcement Layer
1. Confirm which namespaces, if any, have an NRPT rule requiring DNSSEC validation
2. Confirm the recursive server(s) those clients actually query are the same ones holding valid trust anchors
3. Re-test using `Resolve-DnsName -DnssecOk` — never `nslookup.exe`

### Phase 6 — Recovery Verification
1. Re-run `Get-DnsServerDnsSecZoneSetting` and confirm `KeyMasterStatus: Online`
2. Re-run `Resolve-DnsName -DnssecOk` and confirm a fresh, non-expired RRSIG is returned
3. If a Key Master seizure occurred, confirm downstream trust anchors and any parent DS record were refreshed to match the newly-generated keys

---
## Remediation Playbooks

<details><summary>Playbook 1 — Plan and execute a KSK/ZSK key rollover safely (including a Key Master change)</summary>

**Scenario:** A scheduled or emergency key rollover is needed — either the automatic rollover cadence is due, or the Key Master itself needs to move to a different, healthier DC.

**Step 1 — Move the Key Master role while the current one is still online (preferred over seizing)**
```powershell
Move-DnsServerZoneKeyMasterRole -ZoneName "<zone.contoso.com>" -KeyMasterServer "<NewKeyMasterFQDN>"
```
This requires private key replication to already be enabled — the new Key Master must have the private key material.

**Step 2 — Confirm rollover configuration on each key before it fires**
```powershell
Get-DnsServerSigningKey -ZoneName "<zone.contoso.com>" |
    Select-Object KeyId, KeyType, RolloverStatus, NextRolloverAction, CryptoAlgorithm
```

**Step 3 — For a KSK rollover specifically, plan the parent DS record update in advance**
KSK rollover uses the double-signature method — both old and new KSK sign the DNSKEY set during the transition, giving a window to update the parent's DS record before the old KSK retires. Do not wait until after rollover completes to update the parent.
```powershell
Get-Content "$env:windir\System32\dns\dsset-<zone.contoso.com>."
```
Take the new digest data to the parent zone's primary server and add/replace the DS record there.

**Step 4 — Verify post-rollover**
```powershell
Get-DnsServerSigningKey -ZoneName "<zone.contoso.com>"
Resolve-DnsName -Name "<host>.<zone.contoso.com>" -Type A -Server <DC-IP> -DnssecOk
```

**Rollback note:** A planned rollover using `Move-DnsServerZoneKeyMasterRole` (not `-SeizeRole`) does not generate new keys by itself and is low-risk. Forcing an unplanned key regeneration (e.g., via seizure without replicated private key material) is effectively one-way — treat it as a break-glass action, not a routine maintenance step.

</details>

<details><summary>Playbook 2 — Recover from a lost/decommissioned Key Master (seizure, worst case)</summary>

**Scenario:** The DC holding the Key Master role for a zone was demoted, wiped, or is permanently unreachable, and the role was never moved beforehand.

**Step 1 — Confirm the Key Master is genuinely, permanently unreachable — do not seize against a transient outage**
```powershell
Test-Connection -ComputerName <OldKeyMasterFQDN> -Count 4
Get-ADComputer -Identity <OldKeyMasterFQDN> -Properties Enabled -ErrorAction SilentlyContinue
```

**Step 2 — Seize the role onto a healthy, currently-authoritative primary DNS server**
```powershell
Reset-DnsServerZoneKeyMasterRole -ZoneName "<zone.contoso.com>" -KeyMasterServer "<NewKeyMasterFQDN>" -SeizeRole -Force
```

**Step 3 — Determine whether the new Key Master had the private key already (best case) or not (worst case)**
```powershell
Get-DnsServerSigningKey -ZoneName "<zone.contoso.com>" -ComputerName "<NewKeyMasterFQDN>"
```
If keys are present and usable, signing continues with the existing key material. If not, the zone is effectively re-signed with brand-new keys — treat every downstream trust anchor and any parent DS record as now stale.

**Step 4 — If new keys were generated, propagate the changes**
```powershell
# Re-export DS data for the parent zone
Get-Content "$env:windir\System32\dns\dsset-<zone.contoso.com>."

# Re-distribute trust anchors to every relevant validating resolver
Get-DnsServerTrustAnchor -Name "<zone.contoso.com>"
```

**Step 5 — Verify**
```powershell
Get-DnsServerDnsSecZoneSetting -ZoneName "<zone.contoso.com>" | Select-Object KeyMasterServer, KeyMasterStatus
Resolve-DnsName -Name "<host>.<zone.contoso.com>" -Type A -Server <DC-IP> -DnssecOk
```

**Rollback note:** Not reversible if new keys were generated — the old private key material is gone with the decommissioned server. Communicate the trust-anchor/DS-record refresh requirement to every stakeholder relying on validation for this zone before considering the incident closed.

</details>

<details><summary>Playbook 3 — Establish (or repair) a secure delegation chain to a child zone</summary>

**Scenario:** A child zone (e.g., `secure.contoso.com` under `contoso.com`) is correctly signed, but `ParentHasSecureDelegation` reports `False`, and downstream strict validators are not treating it as trusted via the delegation chain.

**Step 1 — Confirm the parent zone is itself signed (a prerequisite — delegation chains require both ends)**
```powershell
Get-DnsServerDnsSecZoneSetting -ZoneName "<zone.contoso.com>"
```
If the parent is intentionally unsigned, this is a deliberate "island of trust" design, not a defect — document it and rely on direct trust anchor distribution to internal validators instead of a delegation chain.

**Step 2 — Pull the DS digest data from the child zone's Key Master**
```powershell
Get-Content "$env:windir\System32\dns\dsset-<child.zone.contoso.com>."
```

**Step 3 — Add the DS record to the parent zone, on the parent's own primary server**
```powershell
Add-DnsServerResourceRecord -ZoneName "<zone.contoso.com>" -DS -Name "<child>" `
    -DigestType Sha256 -Digest "<digest-from-dsset-file>" -KeyTag <tag> -Algorithm <alg>
```

**Step 4 — Verify the chain from the parent's perspective**
```powershell
Resolve-DnsName -Name "<child.zone.contoso.com>" -Type DS -Server <ParentZoneDC-IP>
(Get-DnsServerDnsSecZoneSetting -ZoneName "<child.zone.contoso.com>").ParentHasSecureDelegation
```

**Rollback note:** Removing the DS record from the parent is safe and simply reverts the child to an "island of trust" state — no impact to the child zone's own signed data or ordinary resolution.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  DNSSEC (AD-Integrated Zone) Evidence Collector
.NOTES     Run from a Domain Controller hosting the DNS Server role, with rights to view DNSSEC
           zone properties (Domain Admin or delegated equivalent)
#>

param(
    [Parameter(Mandatory)]
    [string]$ZoneName
)

$reportPath = "C:\Temp\DnssecEvidence_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

"=== Zone DNSSEC Settings ===" | Out-File "$reportPath\01_ZoneSettings.txt"
Get-DnsServerDnsSecZoneSetting -ZoneName $ZoneName -ErrorAction SilentlyContinue |
    Out-File "$reportPath\01_ZoneSettings.txt" -Append

"=== Signing Keys (KSK/ZSK inventory + rollover state) ===" | Out-File "$reportPath\02_SigningKeys.txt"
Get-DnsServerSigningKey -ZoneName $ZoneName -ErrorAction SilentlyContinue |
    Format-List * | Out-File "$reportPath\02_SigningKeys.txt" -Append

"=== Trust Anchors ===" | Out-File "$reportPath\03_TrustAnchors.txt"
Get-DnsServerTrustAnchor -Name $ZoneName -ErrorAction SilentlyContinue |
    Out-File "$reportPath\03_TrustAnchors.txt" -Append

"=== Live Query Test (Resolve-DnsName -DnssecOk — never nslookup.exe) ===" |
    Out-File "$reportPath\04_LiveQuery.txt"
try {
    Resolve-DnsName -Name $ZoneName -Type SOA -DnssecOk -ErrorAction Stop |
        Out-File "$reportPath\04_LiveQuery.txt" -Append
} catch {
    "Query failed: $_" | Out-File "$reportPath\04_LiveQuery.txt" -Append
}

"=== Parent Secure Delegation Check (if this is a child zone) ===" |
    Out-File "$reportPath\05_ParentDelegation.txt"
try {
    (Get-DnsServerDnsSecZoneSetting -ZoneName $ZoneName -ErrorAction Stop).ParentHasSecureDelegation |
        Out-File "$reportPath\05_ParentDelegation.txt" -Append
} catch {
    "Could not determine: $_" | Out-File "$reportPath\05_ParentDelegation.txt" -Append
}

"=== NRPT Rules Matching This Namespace ===" | Out-File "$reportPath\06_NRPT.txt"
Get-DnsClientNrptPolicy -ErrorAction SilentlyContinue |
    Where-Object { $_.Namespace -like "*$ZoneName*" } |
    Out-File "$reportPath\06_NRPT.txt" -Append

Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "Evidence collected: $reportPath.zip" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Check zone's DNSSEC settings / Key Master | `Get-DnsServerDnsSecZoneSetting -ZoneName <zone>` |
| Sign a zone with defaults | `Invoke-DnsServerZoneSign -ZoneName <zone> -SignWithDefault -Force` |
| Re-sign reusing prior parameters | `Invoke-DnsServerZoneSign -ZoneName <zone> -DoResign -Force` |
| Unsign a zone | `Invoke-DnsServerZoneUnsign -ZoneName <zone>` |
| Inventory signing keys | `Get-DnsServerSigningKey -ZoneName <zone>` |
| Move Key Master (planned, current KM online) | `Move-DnsServerZoneKeyMasterRole -ZoneName <zone> -KeyMasterServer <FQDN>` |
| Seize Key Master (emergency, current KM offline) | `Reset-DnsServerZoneKeyMasterRole -ZoneName <zone> -KeyMasterServer <FQDN> -SeizeRole -Force` |
| Check trust anchors | `Get-DnsServerTrustAnchor -Name <zone>` |
| Add a trust anchor manually | `Add-DnsServerTrustAnchor -Name <zone> -DigestType Sha256 -KeyProtocol Dnssec -Digest <d> -KeyTag <t> -Algorithm <a>` |
| Enable RFC 5011 automatic trust anchor rollover | `Set-DnsServerDnsSecZoneSetting -ZoneName <zone> -EnableRfc5011KeyRollover $True` |
| Test resolution WITH DNSSEC data (correct method) | `Resolve-DnsName -Name <name> -Server <IP> -DnssecOk` |
| Never use for DNSSEC testing | `nslookup.exe` (not DNSSEC-aware — will not show RRSIG/errors) |
| Check NRPT enforcement for a namespace | `Get-DnsClientNrptPolicy -Namespace <namespace>` |
| Add a DS record to a parent zone | `Add-DnsServerResourceRecord -ZoneName <parent> -DS -Name <child> -DigestType Sha256 -Digest <d> -KeyTag <t> -Algorithm <a>` |
| View a child zone's DS export data | `Get-Content "$env:windir\System32\dns\dsset-<zone>."` |
| Check parent secure delegation state | `(Get-DnsServerDnsSecZoneSetting -ZoneName <child>).ParentHasSecureDelegation` |

---
## 🎓 Learning Pointers

- **DNSSEC is one of the few AD-adjacent controls where "not configured" is often the correct baseline, not a gap.** Unlike LDAP signing, channel binding, or Kerberos armoring — all hardening controls this repo treats as should-be-enabled-by-default — DNSSEC's value proposition is narrower for a purely internal AD zone that's never delegated externally. Understand *why* a client wants it (often a compliance/audit driver) before treating an unsigned zone as a finding. [Overview of DNSSEC](https://learn.microsoft.com/en-us/windows-server/networking/dns/dnssec-overview)
- **The Key Master role is a single point of operational failure that's easy to overlook because DNS itself stays highly available.** Every DC hosting the zone keeps answering queries fine if the Key Master goes down — only signing and key rollover stall, silently, until someone notices signatures approaching expiration. Treat Key Master identity as a tracked piece of infrastructure, the same way you'd track an FSMO role holder. [Sign DNS zones with DNSSEC](https://learn.microsoft.com/en-us/windows-server/networking/dns/sign-dnssec-zone)
- **The DS-record-to-the-parent step is manual by design and is the single most common reason a "correctly signed" zone doesn't actually protect anyone outside the local validator set.** This mirrors a pattern seen elsewhere in this repo (e.g., Kerberos Armoring's client-side-GPO-independent-of-KDC-side-GPO gotcha, or Certificate Mapping's SID-extension-vs-explicit-mapping split) — a feature that looks "done" from one vantage point can be structurally incomplete from another. Always check `ParentHasSecureDelegation` directly rather than inferring it from the child zone's own signed state.
- **Windows DNS Client has never validated DNSSEC signatures itself — this is worth internalizing precisely because it's counter-intuitive.** A DNSSEC-aware, non-validating stub resolver sounds like it should validate; it doesn't. All cryptographic verification happens at the recursive/caching server. If a client's security requirement genuinely needs endpoint-level validation (not just "the network path was protected"), DNSSEC alone does not satisfy that requirement — a validating local resolver would be needed. [DNSSEC in Windows DNS client](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/dn593685(v=ws.11))
- **`nslookup.exe`'s DNSSEC-blindness isn't folklore — it's explicitly documented by Microsoft, in the same official article that describes the validation process.** It's a good general reminder that a diagnostic tool's silence (no error) is not the same as confirmation of correctness — always confirm a tool is actually capable of observing the thing you're testing for. [Validate and secure DNS responses using DNSSEC](https://learn.microsoft.com/en-us/windows-server/networking/dns/validate-dnssec-responses)
- Community discussion of Windows DNSSEC in practice is comparatively sparse relative to BIND/Unbound (r/sysadmin, r/networking) — most real-world Windows DNSSEC deployment guidance still traces back to the original Windows Server 2012 R2-era TechNet documentation Microsoft has since archived to Previous Versions; treat those archived pages (Key Master seizure/move procedures in particular) as the authoritative procedural source even though they predate the current Learn site structure.
