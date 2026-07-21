# DNSSEC for AD-Integrated Zones — Hotfix Runbook (Mode B: Ops)
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

Run these from an elevated PowerShell session on a primary, authoritative DNS server (ideally the Key Master):

```powershell
# 1. Is this zone actually signed with DNSSEC at all?
Get-DnsServerDnsSecZoneSetting -ZoneName "<zone.contoso.com>" -ErrorAction SilentlyContinue

# 2. Who is the Key Master, and is it reachable?
Get-DnsServerDnsSecZoneSetting -ZoneName "<zone.contoso.com>" |
    Select-Object ZoneName, IsKeyMasterServer, KeyMasterServer, KeyMasterStatus, ParentHasSecureDelegation

# 3. Are trust anchors present for this zone (needed by validating resolvers)?
Get-DnsServerTrustAnchor -Name "<zone.contoso.com>" -ErrorAction SilentlyContinue

# 4. Does a query actually come back with DNSSEC data? (never use nslookup.exe for this — it is NOT DNSSEC-aware)
Resolve-DnsName -Name "<host>.<zone.contoso.com>" -Type A -Server <DC-IP> -DnssecOk

# 5. Is validation being REQUIRED for this namespace via the client's Name Resolution Policy Table (NRPT)?
(Get-DnsClientNrptPolicy -Namespace ".<zone.contoso.com>" -ErrorAction SilentlyContinue).DnsSecValidationRequired
```

| What you see | What it means |
|---|---|
| Command 1 errors "zone is not signed" / returns nothing | Zone was never signed — this isn't a DNSSEC fault, it's DNSSEC-not-configured. Confirm that's actually the expectation before treating it as a fault. |
| `KeyMasterStatus: Offline` | The DC holding the signing role is unreachable — signing/key-rollover operations are stalled. Go to Fix 3. |
| `Get-DnsServerTrustAnchor` returns nothing but the zone IS signed | Trust anchor distribution was never enabled, or hasn't replicated yet — validating resolvers can't build a chain of trust. Go to Fix 2. |
| Step 4 returns the record but **no RRSIG** | You queried a non-authoritative/secondary server for this zone, or `-DnssecOk` wasn't honored — DNSSEC properties can only be viewed/signed on the primary. Re-run directly against a signing DC. |
| Step 4 fails with `DNS_ERROR_UNSECURE_PACKET` | NRPT requires validation for this namespace but the recursive server has no valid trust anchor, or the zone's signatures have expired. Go to Fix 1/Fix 2. |
| `ParentHasSecureDelegation: False` on a signed child zone | No DS record exists in the parent zone — internal clients still resolve fine, but any strict external/downstream validator will treat this as an "island of trust" or fail closed. Go to Fix 4. |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Zone is primary, authoritative, and currently UNSIGNED (a signed zone must be
unsigned before it can be re-signed with new parameters)
  └── Key Master designated (one signing DNS server per zone — NOT every DC)
        └── >=1 KSK + >=1 ZSK generated (compatible crypto algorithm + NSEC/NSEC3 pairing —
            RSA/SHA-1 and RSA/SHA-1(NSEC3) cannot coexist in the same zone)
              └── (AD-integrated, default ON) private signing key replicates via AD DS
                  to every other primary DNS server authoritative for the zone
                    └── Zone is signed — RRSIG/DNSKEY/(NSEC or NSEC3) records generated
                          └── (AD-integrated zones ONLY) the signed copy lives IN MEMORY on
                              each signing DC — it is never committed to disk; only
                              file-backed zones write a signed copy to disk
                                └── Trust anchor (DNSKEY/DS) distributed:
                                    ├── On a DC — forest directory partition, replicates
                                    │   forest-wide via normal AD DS replication
                                    └── On a standalone DNS server — TrustAnchors.dns file
                                          └── (child zone only, NOT automatic) a DS record is
                                              manually created in the PARENT zone to form a
                                              secure delegation chain
                                                └── Recursive/validating resolver has the
                                                    trust anchor AND supports the signing
                                                    algorithm used
                                                      └── (optional) NRPT rule sets
                                                          DnsSecValidationRequired=True for
                                                          the namespace on DNSSEC-aware clients
                                                            └── Windows DNS Client is a
                                                                NON-VALIDATING stub resolver —
                                                                it trusts the AD=1 bit the
                                                                server sends, it never
                                                                independently validates
```

Key failure points:
- Key Master is tied to a specific DC's identity — decommissioning that DC without first moving the role strands all signing/key-rollover capability for the zone
- The DS record for secure delegation to a parent zone is **never** created automatically — a signed child zone with no DS record in its parent is a silent "island of trust"
- `nslookup.exe` is explicitly documented as NOT DNSSEC-aware — using it to "test" DNSSEC produces a false negative every time
- KSK setting changes don't take effect until the next KSK rollover, and ZSK changes don't take effect until the next ZSK rollover — this is by design, not a stuck change
- Windows DNS Client never validates independently; it only ever trusts what the upstream recursive/caching server tells it via the `AD` bit

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the zone's actual signed state and Key Master**
```powershell
Get-DnsServerDnsSecZoneSetting -ZoneName "<zone.contoso.com>"
```
Expected: a populated object (empty/error means unsigned). Note `KeyMasterServer` and `KeyMasterStatus` for the next step.

**Step 2 — If Key Master is offline, decide Move vs. Seize**
```powershell
# Key Master is online but you want to relocate the role (planned):
Move-DnsServerZoneKeyMasterRole -ZoneName "<zone.contoso.com>" -KeyMasterServer "<NewKeyMasterFQDN>"

# Key Master is OFFLINE and unreachable (emergency):
Reset-DnsServerZoneKeyMasterRole -ZoneName "<zone.contoso.com>" -KeyMasterServer "<NewKeyMasterFQDN>" -SeizeRole -Force
```
⚠️ Seizing only succeeds cleanly if the new Key Master already has access to the private key material (i.e., private key replication was enabled). If it doesn't, all signing keys must be replaced and the zone re-signed — see Fix 3.

**Step 3 — Confirm trust anchors exist and are current**
```powershell
Get-DnsServerTrustAnchor -Name "<zone.contoso.com>"
Get-DnsServerDnsSecZoneSetting -ZoneName "<zone.contoso.com>" | Select-Object DistributeTrustAnchor, EnableRfc5011KeyRollover
```
Expected: at least one trust anchor entry. `DistributeTrustAnchor` should not be `{None}` if downstream validators depend on this zone.

**Step 4 — Test resolution the correct way (never `nslookup.exe`)**
```powershell
Resolve-DnsName -Name "<host>.<zone.contoso.com>" -Type A -Server <DC-IP> -DnssecOk
```
Expected: the answer record plus a companion RRSIG record. No RRSIG means either the zone isn't signed, or you queried a server that isn't authoritative/signing for it.

**Step 5 — Check whether validation is actually being required anywhere**
```powershell
Get-DnsClientNrptPolicy | Where-Object Namespace -like "*<zone.contoso.com>*"
```
Expected: if no NRPT rule exists, DNSSEC is protecting downstream validating resolvers only — Windows clients querying that server benefit passively but never enforce validation themselves.

**Step 6 — For a child zone, confirm the secure delegation chain to the parent**
```powershell
(Get-DnsServerDnsSecZoneSetting -ZoneName "<child.zone.contoso.com>").ParentHasSecureDelegation
```
Expected: `True` only if a matching DS record was manually created in the parent zone. `False` is normal/expected if the parent is intentionally unsigned (island of trust) — not itself a bug.

**Step 7 — Confirm signature freshness (expired signatures = hard validation failure)**
```powershell
Resolve-DnsName -Name "<host>.<zone.contoso.com>" -Type A -Server <DC-IP> -DnssecOk |
    Where-Object QueryType -eq 'RRSIG' | Select-Object Expiration, Signed
```
Expected: `Expiration` is in the future. An expired signature with automatic key rollover disabled/broken is a common, quiet failure mode.

---
## Common Fix Paths

<details><summary>Fix 1 — Zone was never signed, or needs re-signing with defaults</summary>

**Cause:** DNSSEC was never configured, or a prior signing was removed and needs to be restored quickly with sane defaults.

```powershell
# Sign with Microsoft's recommended defaults (fastest safe path)
Invoke-DnsServerZoneSign -ZoneName "<zone.contoso.com>" -SignWithDefault -Force

# If it was previously signed and unsigned, reuse the exact prior parameters instead:
Invoke-DnsServerZoneSign -ZoneName "<zone.contoso.com>" -DoResign -Force
```

**Rollback note:** Unsigning is non-destructive to normal DNS resolution — `Invoke-DnsServerZoneUnsign -ZoneName "<zone.contoso.com>"` removes DNSSEC records only, zone continues answering normally.

</details>

<details><summary>Fix 2 — `DNS_ERROR_UNSECURE_PACKET` / validation required but failing</summary>

**Cause:** NRPT requires validation for this namespace, but the recursive DNS server the client is using has no valid trust anchor for the zone, or the trust anchor is stale after a key rollover.

```powershell
# Confirm the recursive server the client actually uses has a trust anchor
Get-DnsServerTrustAnchor -Name "<zone.contoso.com>" -ComputerName <RecursiveServerFQDN>

# If missing, re-import it (must be run on the recursive/validating server, not just the Key Master)
# — export the current trust anchor set from the signing DC first (dsset-<zone>.<domain> in
#   %windir%\System32\dns\ on the Key Master), then import on the validator:
Add-DnsServerTrustAnchor -Name "<zone.contoso.com>" -DigestType Sha256 -KeyProtocol Dnssec -Digest "<digest>" -KeyTag <tag> -Algorithm <alg>
```

**Rollback note:** Adding a trust anchor is additive and safe. If validation should not be strictly required yet (e.g., during initial rollout), the faster/safer short-term mitigation is removing the NRPT requirement rather than force-fitting trust anchors under time pressure — revisit once key rollover/distribution is confirmed stable.

</details>

<details><summary>Fix 3 — Key Master is offline / decommissioned without a handoff</summary>

**Cause:** The DC that held the Key Master role for a zone was demoted, rebuilt, or is simply down, and nobody moved the role first.

```powershell
# Confirm it's genuinely unreachable, not just slow
Test-Connection -ComputerName <OldKeyMasterFQDN> -Count 2 -Quiet

# Seize the role onto a healthy, currently-authoritative primary DNS server
Reset-DnsServerZoneKeyMasterRole -ZoneName "<zone.contoso.com>" -KeyMasterServer "<NewKeyMasterFQDN>" -SeizeRole -Force

# Verify
Get-DnsServerDnsSecZoneSetting -ZoneName "<zone.contoso.com>" | Select-Object KeyMasterServer, KeyMasterStatus
```
⚠️ If the new Key Master did **not** have private key material replicated to it (private key replication was disabled at signing time), seizing forces a full re-sign with brand-new keys — any previously-distributed trust anchors and any DS record in a parent zone are now stale and must be manually updated/regenerated.

**Rollback note:** Not reversible in the sense of restoring the old keys — treat a forced re-sign as a one-way operation and communicate the trust-anchor/DS-record refresh requirement to anyone depending on this zone's validation chain.

</details>

<details><summary>Fix 4 — Secure delegation to the parent zone missing (`ParentHasSecureDelegation: False`)</summary>

**Cause:** The child zone is correctly signed, but no DS record was ever created in the parent zone — the DS record is documented as never automatic.

```powershell
# On the Key Master for the CHILD zone, locate the generated DS record data
Get-Content "$env:windir\System32\dns\dsset-<child.zone.contoso.com>."

# Add the corresponding DS record to the PARENT zone (run on the parent zone's primary server)
Add-DnsServerResourceRecord -ZoneName "<zone.contoso.com>" -DS -Name "<child>" `
    -DigestType Sha256 -Digest "<digest-from-dsset-file>" -KeyTag <tag> -Algorithm <alg>

# Verify the parent now reports a secure delegation
(Get-DnsServerDnsSecZoneSetting -ZoneName "<child.zone.contoso.com>").ParentHasSecureDelegation
```

**Rollback note:** Removing a DS record is safe and simply breaks the secure-delegation chain back down to an unsigned-parent "island of trust" state — no data loss.

</details>

<details><summary>Fix 5 — You tested with `nslookup` and got confusing/negative results</summary>

**Cause:** `nslookup.exe` uses an internal DNS client that is explicitly documented as NOT DNSSEC-aware — it will never show RRSIG data or DNSSEC errors, regardless of the zone's actual signed state.

```powershell
# Always use Resolve-DnsName with -DnssecOk instead
Resolve-DnsName -Name "<host>.<zone.contoso.com>" -Type A -Server <DC-IP> -DnssecOk
```

**Rollback note:** N/A — this is a testing-methodology correction, not a configuration change.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — DNSSEC (AD-Integrated Zone) Issue

Zone: ____________________________
Is zone AD-integrated: Yes / No
Key Master (Get-DnsServerDnsSecZoneSetting): ______________  Status: Online / Offline

Symptom: (won't sign / Key Master unreachable / DNS_ERROR_UNSECURE_PACKET / missing DS
          record at parent / signatures expired / other)

Get-DnsServerDnsSecZoneSetting output:
---
[paste here]
---

Get-DnsServerTrustAnchor output:
---
[paste here]
---

Resolve-DnsName -DnssecOk output (confirm RRSIG present, note Expiration):
---
[paste here]
---

NRPT rule for this namespace (Get-DnsClientNrptPolicy), if any:
---
[paste here]
---

Steps already attempted:
[ ] Confirmed test was done with Resolve-DnsName -DnssecOk, NOT nslookup.exe
[ ] Key Master reachability confirmed
[ ] Trust anchor presence confirmed on the relevant recursive/validating server
[ ] Parent zone DS record checked (if this is a child zone)
[ ] Signature expiration checked
```

---
## 🎓 Learning Pointers

- **DNSSEC and DNS availability are orthogonal concerns.** This topic covers response *integrity* (is the answer authentic and unmodified) — the DC Locator/SRV/scavenging mechanics that keep AD *functioning* live in `AD-DNS-A.md`/`AD-DNS-B.md`. A zone can be perfectly healthy for AD purposes and completely unsigned, or perfectly signed and still have broken SRV registration — the two are independent failure domains. [Overview of DNSSEC](https://learn.microsoft.com/en-us/windows-server/networking/dns/dnssec-overview)
- **Never use `nslookup.exe` to test DNSSEC — this is explicitly called out in Microsoft's own documentation, not a community myth.** Its internal resolver isn't DNSSEC-aware and will silently give you a "clean" result even against a completely broken signing configuration. Always use `Resolve-DnsName -DnssecOk`. [Validate and secure DNS responses using DNSSEC](https://learn.microsoft.com/en-us/windows-server/networking/dns/validate-dnssec-responses)
- **A signed AD-integrated zone is never committed to disk.** Only file-backed (non-AD-integrated) signed zones write signed data to a zone file — the AD-integrated signed copy exists only in memory on each signing DC, by design, to avoid bloating the AD database. Don't go looking for a signed `.dns` file on an AD-integrated DC; it doesn't exist. [Sign DNS zones with DNSSEC](https://learn.microsoft.com/en-us/windows-server/networking/dns/sign-dnssec-zone)
- **The DS record for a secure parent delegation is the single most commonly missed step in a DNSSEC rollout, because it is never automatic.** A team can correctly sign a child zone, verify it internally, and still have every external/strict validator treat it as untrusted because nobody manually created and propagated the DS record to the parent. Check `ParentHasSecureDelegation` explicitly, don't assume.
- **Windows DNS Client has never independently validated DNSSEC signatures — it is, and has always been, a non-validating stub resolver.** It trusts the `AD=1` bit the recursive server sends. This means DNSSEC's actual security value in most internal AD deployments comes from protecting the *recursive/caching server*, not the endpoint — understand who's actually doing the validating before assuming client-side protection exists. [DNSSEC in Windows DNS client](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/dn593685(v=ws.11))
- **In most MSP/internal-AD engagements, DNSSEC being unsigned is the normal, healthy baseline — not a finding.** Internal AD zones are rarely externally delegated, so the value of signing them is narrower than for a public-facing domain. Treat "not signed" as a design question to raise with the client (often driven by a compliance/security-audit requirement), not automatically as a misconfiguration to silently fix.
