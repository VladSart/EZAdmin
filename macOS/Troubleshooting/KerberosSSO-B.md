# macOS Kerberos SSO Extension (On-Prem AD & Entra Cloud Kerberos) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate "Mac keeps prompting for credentials on file shares / intranet sites" in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

The Kerberos SSO extension (`com.apple.AppSSOKerberos.KerberosExtension`) is Apple's built-in way for an
**unbound** Mac (local account, Entra-joined via Platform SSO, or neither) to get Kerberos tickets for
on-prem Active Directory resources — SMB file shares, intranet sites, print servers. It is **separate**
from Platform SSO: Platform SSO can *supply* the TGT (`usePlatformSSOTGT`), but the Kerberos extension
profile is what maps hosts/realms. Run as the affected user:

```bash
# 1. Which Kerberos realms are configured on this Mac?
app-sso -l
# Bad: empty / "no realms" → the Kerberos SSO profile never landed (Fix 1)

# 2. Does the user hold tickets right now?
klist
# Good: krbtgt/CONTOSO.COM@CONTOSO.COM listed and not expired
# Bad: "klist: krb5_cc_get_principal: No credentials cache" → no TGT (Fix 2/3)

# 3. If Platform SSO is deployed: did Entra hand over TGTs?
app-sso platform -s | grep -iE "tgt_ad|tgt_cloud|ticketKeyPath"
# Good: tgt_ad (on-prem) and/or tgt_cloud (Entra Cloud Kerberos) present

# 4. Can the Mac find a domain controller at all?
dig +short -t SRV _ldap._tcp.dc._msdcs.<ad-domain.com>
# Bad: no answer → DNS / VPN / network path problem, not Kerberos (Fix 4)
```

**Interpretation table:**

| Finding | Action |
|---|---|
| `app-sso -l` shows no realms | Fix 1 — profile missing/mis-scoped |
| Realm listed but `klist` empty, menu extra says "Not signed in", **no** Platform SSO | Fix 2 — user must sign in once to the extension (or `app-sso -a`) |
| Platform SSO in use, `app-sso platform -s` shows **no** `tgt_ad` | Fix 3 — Entra Kerberos server object / `usePlatformSSOTGT` / Company Portal version |
| Menu extra says "Not signed in" but `klist` shows valid tickets and shares open | Not a fault — expected with Platform SSO; tell user to ignore the menu extra |
| SRV lookup fails | Fix 4 — network path / VPN / DNS |
| TGT present, Finder SMB still prompts | Fix 5 — host not covered by `Hosts`, SPN/DNS name mismatch, or connecting by IP |
| TGT present, Safari works but Edge/Chrome prompts | Fix 6 — browser Negotiate allowlists |
| Works on LAN, fails on per-app VPN | Fix 7 — missing Kerberos processes in App-to-App-Layer VPN mapping |
| `klist` errors about clock skew / tickets rejected | Fix 8 — time sync |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Mac enrolled in MDM (User Approved) — Extensible SSO payloads need it
 └─ Kerberos SSO profile (com.apple.extensiblesso, Type=Credential,
    ExtensionIdentifier=com.apple.AppSSOKerberos.KerberosExtension) delivered
     ├─ Realm = UPPERCASE AD realm (e.g. CONTOSO.COM)
     └─ Hosts = ".contoso.com" AND "contoso.com" (leading-dot entry covers subdomains)
         └─ Network path to a writable DC (LAN / VPN) + DNS SRV records resolvable
             └─ Clock within 5 minutes of the DC (Kerberos default max skew)
                 └─ TGT obtained by ONE of:
                     ├─ user signs in to the extension (password / smart card), OR
                     └─ Platform SSO hands over tgt_ad (usePlatformSSOTGT=true)
                          └─ requires: macOS 14.6+, Company Portal 5.2408.0+,
                             Microsoft Entra Kerberos server object in the AD domain
                 └─ Service ticket requested for cifs/<fqdn> or HTTP/<fqdn>
                     └─ Client uses FQDN (not IP / not unregistered alias)
                         └─ Browser allowlists (Edge/Chrome/Firefox) where applicable
```
</details>

---
## Diagnosis & Validation Flow

1. **Profile present on device**
   ```bash
   sudo profiles -P -o stdout | grep -A3 -i "AppSSOKerberos"
   ```
   Expected: `ExtensionIdentifier = "com.apple.AppSSOKerberos.KerberosExtension"`, `Realm = "CONTOSO.COM"`.
   Missing → Intune assignment (Fix 1).

2. **Realm details & site discovery**
   ```bash
   app-sso -i CONTOSO.COM
   ```
   Expected: a populated realm dictionary incl. site code and, if signed in, `user_name` and password expiry.
   Empty site code → LDAP ping to DCs failing (network, Fix 4).

3. **Tickets**
   ```bash
   klist
   ```
   Expected: `krbtgt/CONTOSO.COM@CONTOSO.COM` plus service tickets (e.g. `cifs/fs01.contoso.com@CONTOSO.COM`) after accessing a share.

4. **Force a clean acquisition**
   ```bash
   app-sso -a CONTOSO.COM
   ```
   Expected: sign-in dialog (or silent success if already configured). Error text here is the most useful single clue — copy it into the ticket.

5. **Test the resource by FQDN**
   ```bash
   open "smb://fs01.contoso.com/share"
   klist | grep -i cifs
   ```
   Expected: share mounts without a prompt and a `cifs/fs01.contoso.com` ticket appears.

---
## Common Fix Paths

<details><summary>Fix 1 — Profile missing or mis-scoped</summary>

In Intune: **Devices → Configuration → macOS**, either
- **Templates → Device features → Single sign-on app extension → type Kerberos**, or
- a **Custom** template with a `.mobileconfig` (Microsoft publishes on-prem and Cloud Kerberos samples).

Check: realm is UPPERCASE; `Hosts` includes both `.contoso.com` and `contoso.com`; profile is assigned
to the correct group (Microsoft's Platform SSO Kerberos guide assigns to **user** groups and recommends
the device channel for the custom profile). Sync the device and re-run `app-sso -l`.
</details>

<details><summary>Fix 2 — Realm configured but user never signed in (no Platform SSO)</summary>

```bash
app-sso -a CONTOSO.COM -u <samAccountName>
```
Or have the user click the Kerberos menu extra → **Sign In**. Tick "sign in automatically" (if the
profile allows it) so the extension silently refreshes TGTs — otherwise the user is re-prompted when
the ticket expires (typically ~10 hours).
</details>

<details><summary>Fix 3 — Platform SSO present but no on-prem TGT (tgt_ad missing)</summary>

1. Confirm prerequisites: macOS ≥ 14.6 (`sw_vers`), Company Portal ≥ 5.2408.0, Platform SSO registration healthy (`Platform-SSO-B.md`).
2. Confirm the **Microsoft Entra Kerberos server object** exists in each AD domain users belong to (same object used for Windows Hello for Business cloud Kerberos trust):
   ```powershell
   # On a domain-joined Windows admin box
   Import-Module AzureADHybridAuthenticationManagement
   Get-AzureADKerberosServer -Domain <ad-domain.com> -UserPrincipalName <admin@tenant.com>
   ```
   No object → create it per the cloud Kerberos trust guide before anything else.
3. Confirm the Kerberos profile has `usePlatformSSOTGT = true` (and usually `performKerberosOnly = true`).
4. If the SSO extension data sets `custom_tgt_setting` (Company Portal 2508+): `1` = on-prem only, `2` = cloud only, `3` = none. A value of `2` or `3` explains a missing `tgt_ad`.
5. Sign out/in (or lock/unlock) to trigger a fresh PSSO token + TGT, then `app-sso platform -s`.
</details>

<details><summary>Fix 4 — DC discovery fails (DNS / VPN / network)</summary>

```bash
scutil --dns | grep -A3 "resolver #1"
dig +short -t SRV _kerberos._tcp.<ad-domain.com>
nc -vz <dc-fqdn> 88
nc -vz <dc-fqdn> 389
```
Fix the path first (VPN up, split-DNS forwarding the AD zone, firewall allowing TCP/UDP 88, 389, 445).
Then `app-sso -r CONTOSO.COM` to reset the realm's cached site info and re-authenticate.
</details>

<details><summary>Fix 5 — TGT present but SMB share still prompts</summary>

- Connect with the **FQDN** that has a matching SPN (`cifs/fs01.contoso.com`). IP addresses and unregistered DNS aliases fall back to NTLM/password prompts.
- Ensure the share's domain is covered by `Hosts` in the profile.
- For DFS namespaces, both the namespace FQDN and the target servers must be resolvable; see `../../DFS/_AGENT.md`.
- For **Azure Files with Entra Cloud Kerberos**: deploy the separate Cloud Kerberos profile (realm `KERBEROS.MICROSOFTONLINE.COM`, `preferredKDCs` = `kkdcp://login.microsoftonline.com/<tenant-id>/kerberos`, `Hosts` = `windows.net`, `.windows.net`) and make sure the storage account app registration manifest uses lowercase `cifs`. Microsoft lists Mac PSSO → Azure Files as limited preview.

Clear stale tickets and retry:
```bash
kdestroy -A && app-sso -a CONTOSO.COM
```
</details>

<details><summary>Fix 6 — Browser prompts (Edge / Chrome / Firefox)</summary>

Safari works by default. Deploy browser policy via Intune (Settings Catalog / preference file):
- **Edge**: `AuthServerAllowlist` and `AuthNegotiateDelegateAllowlist` = `*.contoso.com`
- **Chrome**: same two policy names
- **Firefox**: `network.negotiate-auth.trusted-uris` (and `network.automatic-ntlm-auth.trusted-uris` if needed)

Quick check for Edge on the device:
```bash
defaults read com.microsoft.Edge AuthServerAllowlist 2>/dev/null || echo "not set"
```
</details>

<details><summary>Fix 7 — Fails over per-app VPN</summary>

Add these to the App-to-App-Layer VPN mapping (identifier + `anchor apple` designated requirement):
`com.apple.KerberosExtension`, `com.apple.AppSSOAgent`, `com.apple.KerberosMenuExtra`.
Without them the extension's LDAP ping and ticket requests don't use the tunnel.
</details>

<details><summary>Fix 8 — Clock skew</summary>

```bash
sntp -t 5 time.apple.com
sudo sntp -sS time.apple.com   # set clock if more than a few minutes off
```
Kerberos rejects requests where client and DC clocks differ by more than the domain's max skew (default 5 minutes).
</details>

---
## Escalation Evidence

```
Ticket: ______________________   Engineer: ______________   Date: ____________
Device / serial: ______________________   macOS: ________   Company Portal version: ________
User UPN / sAMAccountName: ______________________   AD realm: ______________________

Platform SSO deployed?  Y / N     Registration healthy (app-sso platform -s)?  Y / N
tgt_ad present?  Y / N     tgt_cloud present?  Y / N     custom_tgt_setting value: ____
app-sso -l output: ____________________________________________
app-sso -i <REALM> site code: __________   Signed in user: __________
klist output attached?  Y / N
DC SRV lookup result: ____________________________   Ports 88/389/445 reachable?  Y / N
Resource tested (FQDN): ______________________   Result: ______________________
Browser (if web): ________  Allowlists set?  Y / N
VPN type: [ ] none [ ] full-tunnel [ ] per-app (Kerberos processes mapped? Y / N)
Clock offset vs DC: ________
Get-KerberosSSOStatus.sh CSV attached?  Y / N
Fixes attempted + result: ____________________________________________
```

---
## 🎓 Learning Pointers

- **Two extensions, two jobs.** Platform SSO gets the user signed in to Entra (and can mint TGTs); the Kerberos SSO extension profile tells macOS which realm/hosts to use them for. You usually need both. [Enable Kerberos SSO in Platform SSO](https://learn.microsoft.com/en-us/entra/identity/devices/device-join-macos-platform-single-sign-on-kerberos-configuration)
- **The menu extra can lie (harmlessly).** With Platform SSO supplying tickets, "Not signed in" in the Kerberos menu extra is expected — validate with `klist` and real resource access instead.
- **No binding required.** Apple designed the extension for local accounts on Macs that are *not* AD-bound; if you're still binding Macs just for share access, this is the replacement. [Kerberos SSO extension — Apple Platform Deployment](https://support.apple.com/guide/deployment/kerberos-sso-extension-depe6a1cda64/web)
- **Entra Kerberos is shared plumbing.** The same `AzureADKerberos` server object powers Windows Hello for Business cloud Kerberos trust and Mac `tgt_ad` — check `../../EntraID/Troubleshooting/WHfB-A.md` if one platform works and the other doesn't.
- **`app-sso` is the Swiss-army knife** — `-l`, `-i`, `-a`, `-r`, and `platform -s` cover 90% of diagnostics. [app-sso(1) man page](https://keith.github.io/xcode-man-pages/app-sso.1.html)
- Deep dive: `KerberosSSO-A.md`. Evidence script: `../Scripts/Get-KerberosSSOStatus.sh`.
