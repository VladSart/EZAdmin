# AD Domain & Forest Trust Failures — Hotfix Runbook (Mode B: Ops)
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

Run these from an elevated PowerShell session on a DC in the domain reporting the problem:

```powershell
# 1. List all trusts this domain has and their basic health
Get-ADTrust -Filter * | Select-Object Name, Direction, TrustType, ForestTransitive, SIDFilteringForestAware

# 2. Validate a specific trust's secure channel (the single best "is it broken" command)
netdom trust <ThisDomain> /Domain:<TrustedDomain> /verify

# 3. Test the trust's secure channel from a domain-member perspective
Test-ComputerSecureChannel -Server <TrustedDomainDC> -Verbose

# 4. Check the Netlogon event log for trust-relevant failures
Get-WinEvent -LogName "System" -MaxEvents 50 |
  Where-Object { $_.ProviderName -eq "NETLOGON" } |
  Select-Object TimeCreated, Id, Message

# 5. Confirm DNS can resolve the remote domain/forest
Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.<TrustedDomain>" -Type SRV
```

| What you see | What it means |
|---|---|
| `netdom trust /verify` returns "completed successfully" | Secure channel is healthy — problem is likely authentication scope, SID filtering, or selective auth, not the trust link itself |
| `netdom trust /verify` fails with "trust relationship failed" | Trust password/secure channel is broken — go to Fix 1 |
| `Test-ComputerSecureChannel` returns `False` | The **local machine's** secure channel to its own domain is broken, not the inter-domain trust — different problem, see `EntraID/`/`Windows/` for computer-account secure channel repair |
| DNS SRV lookup for the trusted domain fails | Conditional forwarder or DNS delegation is missing/broken — go to Fix 2 |
| Netlogon event ID 5719 | Cannot locate a DC in the trusted domain — usually DNS or network path |
| Netlogon event ID 5722 | Secure channel authentication failure — password mismatch between trust objects |
| Access denied on trusted-domain resources despite trust showing healthy | Likely SID filtering (quarantine) or selective authentication scoping — go to Fix 3 or Fix 4 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
DNS resolution between the two domains/forests (conditional forwarders or delegation)
  └── Network path reachable (same ports as intra-domain: 88, 389, 445, 135+dynamic RPC)
        └── Trusted Domain Object (TDO) exists correctly on both sides with matching password
              └── Netlogon secure channel established using the TDO password
                    └── Kerberos referral ticket path (client domain → trust → resource domain KDC)
                          └── SID filtering / quarantine evaluated (external trusts filter SID history by default)
                                └── Selective authentication evaluated, if enabled (explicit per-resource ACE required)
                                      └── Resource-domain DC issues service ticket → access granted/denied
```

Key failure points:
- TDO password out of sync between the two sides (trust "half-broken" — one side reports healthy, the other doesn't)
- DNS conditional forwarder missing, wrong, or pointing at decommissioned DCs
- SID filtering silently strips SID history on external trusts (by design) — breaks access that depends on migrated SIDs
- Selective authentication enabled but the specific computer/user ACE was never granted on the target resource

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the trust exists and note its type/direction**
```powershell
Get-ADTrust -Filter * | Format-List Name, Direction, TrustType, ForestTransitive, SIDFilteringForestAware, SelectiveAuthentication
```
`Direction` matters: `Bidirectional`, `Inbound` (they trust us), or `Outbound` (we trust them) — a one-way trust configured backwards looks identical to "broken" from the wrong side.

**Step 2 — Verify the secure channel from both sides**
```powershell
# From a DC in this domain
netdom trust <ThisDomain> /Domain:<TrustedDomain> /verify

# Repeat from a DC in the other domain, pointing back
netdom trust <TrustedDomain> /Domain:<ThisDomain> /verify
```
Expected: both directions report success. A trust that verifies one way but not the other means the TDO password is out of sync — reset it (Fix 1).

**Step 3 — Check DNS resolution both ways**
```powershell
Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.<TrustedDomain>" -Type SRV
nslookup <TrustedDomainDC.fqdn>
```
Expected: SRV records resolve to live, reachable DCs in the trusted domain.

**Step 4 — Check for SID filtering impact (cross-forest / external trusts)**
```powershell
Get-ADTrust -Filter * | Select-Object Name, TrustType, SIDFilteringForestAware, SIDFilteringQuarantined
```
If a migrated user's old-domain SID history is required for access (common right after a domain migration) and `SIDFilteringQuarantined` is `True` on an external trust, that history is being stripped — this is default, secure behavior, not a bug.

**Step 5 — Check selective authentication scope, if enabled**
```powershell
(Get-ADTrust -Filter * | Where-Object Name -eq "<TrustedDomain>").SelectiveAuthentication
```
If `True`, every user/computer needs an explicit "Allowed to Authenticate" permission on the target computer object in the resource domain — a healthy trust with selective auth enabled will still deny everyone by default until that ACE is granted.

**Step 6 — Confirm Kerberos referral path**
```powershell
klist tickets
# Look for a krbtgt/<TrustedDomain> referral ticket after attempting resource access
```
Missing referral ticket after an access attempt indicates the client never got past the trust boundary — usually DNS or Kerberos SPN resolution, not permissions.

**Step 7 — Full trust object comparison (advanced)**
```powershell
nltest /trusted_domains
nltest /dsgetdc:<TrustedDomain>
```

---
## Common Fix Paths

<details><summary>Fix 1 — Secure channel / trust password out of sync</summary>

**Cause:** The Trusted Domain Object (TDO) password on one side no longer matches the other — often after a trust was recreated on only one side, or after a long outage during a scheduled password rollover.

```powershell
# Reset the trust password from a DC in this domain (requires credentials for the other side)
netdom trust <ThisDomain> /Domain:<TrustedDomain> /ResetPWD /UserD:<ThisDomainAdmin> /PasswordD:* /UserO:<OtherDomainAdmin> /PasswordO:*

# Re-verify both directions after reset
netdom trust <ThisDomain> /Domain:<TrustedDomain> /verify
```

**Rollback note:** Resetting the trust password is safe and non-destructive — it does not affect existing resource ACLs or SID history. If both sides can't be reset simultaneously (e.g., no admin creds for the other domain), coordinate with the other domain's admin team before running.

</details>

<details><summary>Fix 2 — DNS resolution to the trusted domain is broken</summary>

**Cause:** Conditional forwarder missing/stale, or DNS delegation points at decommissioned DCs in the trusted domain.

```powershell
# Check existing conditional forwarders
Get-DnsServerZone | Where-Object ZoneType -eq "Forwarder"

# Add or fix a conditional forwarder to the trusted domain's DNS servers
Add-DnsServerConditionalForwarderZone -Name "<TrustedDomain>" -MasterServers <TrustedDomainDNS-IP1>,<TrustedDomainDNS-IP2>

# Verify resolution
Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.<TrustedDomain>" -Type SRV
```

**Rollback note:** Safe — conditional forwarders only affect name resolution scope, not trust security state. Remove with `Remove-DnsServerZone` if it needs reverting.

</details>

<details><summary>Fix 3 — SID filtering blocking access after a migration</summary>

**Cause:** External (non-forest-transitive) trusts filter SID history by default (quarantine). Access that depends on a migrated user's SID history from the old domain will silently fail.

```powershell
# Check current quarantine state
Get-ADTrust -Filter * | Select-Object Name, SIDFilteringQuarantined

# Disable quarantine ONLY if you fully trust the other domain's SID history integrity —
# this re-enables privilege-escalation risk via forged SID history, so scope and time-box it
netdom trust <ThisDomain> /Domain:<TrustedDomain> /quarantine:No /UserD:<Admin> /PasswordD:*

# Re-enable once the migration cutover window is closed
netdom trust <ThisDomain> /Domain:<TrustedDomain> /quarantine:Yes /UserD:<Admin> /PasswordD:*
```

⚠️ Disabling SID filtering is a security-relevant change — only do this for a controlled migration window with a trusted source domain, and re-enable immediately after.

**Rollback note:** Reversible — re-run with `/quarantine:Yes` to restore filtering.

</details>

<details><summary>Fix 4 — Selective authentication denying access despite a healthy trust</summary>

**Cause:** Selective authentication is enabled on the trust, and the user or computer account was never granted the "Allowed to Authenticate" permission on the specific target computer object.

```powershell
# On the resource-domain computer object, grant the permission (run in the resource domain)
$computer = Get-ADComputer -Identity "<TargetServer>"
$acl = Get-Acl "AD:\$($computer.DistinguishedName)"
$identity = New-Object System.Security.Principal.NTAccount("<TrustedDomain>\<UserOrGroup>")
$sid = $identity.Translate([System.Security.Principal.SecurityIdentifier])
$ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
    $sid, "ExtendedRight", "Allow", [GUID]"68b1d179-0d15-4d4f-ab71-46152e79a7bc")  # Allowed-To-Authenticate right
$acl.AddAccessRule($ace)
Set-Acl "AD:\$($computer.DistinguishedName)" -AclObject $acl
```

**Rollback note:** Safe, additive ACE — remove the specific `AccessRule` from the ACL to revert if access was granted too broadly.

</details>

<details><summary>Fix 5 — One-way trust configured in the wrong direction</summary>

**Cause:** Trust exists but was created (or is being tested) in the wrong direction for the intended use case — e.g., Domain A needs to trust Domain B's users, but the trust was only set up as Domain B trusting Domain A.

```powershell
# Confirm current direction
Get-ADTrust -Filter * | Select-Object Name, Direction

# Convert to bidirectional if that's the intended state (requires creds for both sides)
netdom trust <ThisDomain> /Domain:<TrustedDomain> /twoway /UserD:<Admin> /PasswordD:* /UserO:<OtherAdmin> /PasswordO:*
```

**Rollback note:** Changing trust direction is a design decision, not a routine rollback — confirm with whoever owns the trust relationship (often a separate business unit in an M&A or multi-forest MSP scenario) before converting.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — AD Trust Failure

This domain: ___________________
Trusted domain/forest: _________
Trust type (External/Forest/Realm): ____
Direction (Inbound/Outbound/Bidirectional): ____
Forest transitive: (Yes/No)
SID filtering (quarantine) state: ____
Selective authentication enabled: (Yes/No)

netdom trust /verify (this → trusted): ____________
netdom trust /verify (trusted → this): ____________

DNS SRV resolution to trusted domain: (OK / Failed)
Relevant Netlogon event IDs seen: ____________

Steps already attempted:
[ ] Get-ADTrust reviewed for direction/type/SID filtering/selective auth
[ ] netdom trust /verify run from both sides
[ ] DNS conditional forwarder/delegation checked
[ ] SID filtering state checked (if migration-related access issue)
[ ] Selective authentication ACE checked (if enabled)
[ ] Trust password reset attempted (if secure channel broken)
```

---
## 🎓 Learning Pointers

- **A trust that "verifies successfully" doesn't mean access will work.** `netdom trust /verify` only confirms the secure channel — SID filtering and selective authentication are separate, independent gates evaluated after the trust link itself is healthy. Always check both when the trust reports fine but users still get denied. [Trust technologies overview](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/understand-domain-and-forest-trusts)
- **External trusts filter SID history by default; forest trusts don't (unless explicitly forced).** This trips up post-migration access constantly — a user works fine until SID-history-dependent access hits a filtered SID. Understand which trust type you have before assuming a permissions bug. [SID filtering explained](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2003/cc835085(v=ws.10))
- **Selective authentication changes trust behavior from "trust but scope by ACL" to "deny by default, allow by explicit grant."** If it's enabled, expect every new cross-forest use case to need a manual "Allowed to Authenticate" ACE — this is easy to forget when scoping a new integration.
- **A trust can be healthy in one direction and broken in the other.** Always run `/verify` from both sides — checking only from "your" domain can miss a one-sided TDO password desync.
- **Netlogon event IDs 5719 and 5722 point at different layers.** 5719 = can't locate a DC (DNS/network problem); 5722 = secure channel authentication failed (password/trust-object problem). Don't treat them as interchangeable.
- Community resource: r/sysadmin threads on cross-forest access failures after a migration consistently trace back to SID filtering being left enabled past the intended migration window — treat quarantine state as a checklist item, not an afterthought.
