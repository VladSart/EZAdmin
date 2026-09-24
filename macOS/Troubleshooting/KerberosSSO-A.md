# macOS Kerberos SSO Extension (On-Prem AD & Entra Cloud Kerberos) — Reference Runbook (Mode A: Deep Dive)
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

**In scope**
- Apple's Kerberos SSO extension (`com.apple.AppSSOKerberos.KerberosExtension`) on Intune-managed Macs.
- Standalone mode (user signs in to the extension against on-prem AD).
- Platform SSO-integrated mode (Entra issues on-prem `tgt_ad` and cloud `tgt_cloud` TGTs, extension uses them via `usePlatformSSOTGT`).
- Access to SMB shares, Kerberos-protected intranet sites, and Azure Files with Entra Cloud Kerberos.

**Out of scope**
- Platform SSO registration/Secure Enclave key problems → `Platform-SSO-A.md`
- AD binding (`dsconfigad`) — deprecated approach, not covered
- Server-side SPN/delegation design beyond what a Mac client needs → `../../ActiveDirectory/_AGENT.md`
- iOS/iPadOS behaviour (the extension is challenge-driven there; this runbook is macOS)

**Assumptions**: on-prem AD domain(s) at Windows Server 2008 functional level or later; for PSSO mode, a Microsoft Entra Kerberos server object already deployed (as for WHfB cloud Kerberos trust).

---
## How It Works

<details><summary>Full architecture</summary>

### 1. Extensible SSO payload
Kerberos SSO is delivered as an **Extensible Single Sign-on** payload (`com.apple.extensiblesso`) with:

| Key | Value | Notes |
|---|---|---|
| `ExtensionIdentifier` | `com.apple.AppSSOKerberos.KerberosExtension` | Apple's built-in extension |
| `TeamIdentifier` | `apple` | |
| `Type` | `Credential` | Credential-type extensions intercept Kerberos/Negotiate for listed hosts |
| `Realm` | `CONTOSO.COM` | **Must be uppercase** — Kerberos realms are case-sensitive |
| `Hosts` | `.contoso.com`, `contoso.com` | Leading dot = all subdomains; bare entry = apex |
| `ExtensionData` | dictionary | Behaviour switches (below) |

Common `ExtensionData` keys:

| Key | Effect |
|---|---|
| `usePlatformSSOTGT` | Use the TGT that Platform SSO obtained for the same realm (default false) |
| `performKerberosOnly` | Skip password-expiry checks, external-password-change checks and home-directory lookup (default false) — recommended with PSSO |
| `allowPlatformSSOAuthFallback` | Allow falling back to PSSO authentication |
| `allowPasswordChange` / `pwReqComplexity` | Allow AD password change from the extension; enforce complexity hints |
| `syncLocalPassword` | Keep local account password in sync with AD (don't combine with PSSO password sync) |
| `allowAutomaticLogin` | Allow the "sign in automatically" (keychain-stored) option |
| `preferredKDCs` | Explicit KDC list — for Entra Cloud Kerberos, `kkdcp://login.microsoftonline.com/<tenantId>/kerberos` |
| `siteCode` / `useSiteAutoDiscovery` | Pin or auto-discover the AD site |
| `delayUserSetup` | Hold the first sign-in prompt until released (`app-sso -p <REALM>`) |
| `isDefaultRealm` | Make this realm the default for Kerberos requests |

### 2. Standalone flow (no Platform SSO)
1. Profile installs → if the domain is reachable, the user is prompted to sign in immediately (also via the menu extra, or when Safari hits a Negotiate challenge).
2. Extension performs an **LDAP ping** (`MS-ADTS 6.3.3`) to discover and cache the AD **site code**, then requests a TGT from a site-local KDC.
3. On macOS the extension is **proactive**: it refreshes the TGT on network changes and keeps it fresh; with "sign in automatically" it keeps renewing until the password expires, otherwise it re-prompts at TGT expiry (~10h).
4. It queries **password expiry** and notifies users, supports AD password change, and can sync the local password (date-based comparison to avoid lockouts).
5. Any Kerberos-aware client (Finder SMB, Safari, `curl --negotiate`, etc.) gets service tickets via the shared Heimdal credential cache.

### 3. Platform SSO-integrated flow
```
User signs in (PSSO: Secure Enclave key / password / smart card)
      │
      ▼
Entra ID ── issues PSSO PRT ──► Microsoft Enterprise SSO extension (Company Portal)
      │
      ├── on-prem partial TGT via Entra Kerberos server object ──► ticketKeyPath "tgt_ad"
      └── cloud TGT (KERBEROS.MICROSOFTONLINE.COM)              ──► ticketKeyPath "tgt_cloud"
                         │
                         ▼
     macOS native Kerberos (Heimdal) imports TGTs ("TGT mapping")
                         │
     Kerberos SSO extension profile(s) with usePlatformSSOTGT=true
     map realm + Hosts → the right TGT is used for cifs/HTTP service tickets
```
- The on-prem TGT is a **partial TGT** signed by the Entra Kerberos server object (`krbtgt_AzureAD`) and exchanged at a writable 2016+ DC for a full TGT — the same mechanism as WHfB cloud Kerberos trust. No Entra Kerberos object ⇒ no `tgt_ad`.
- Microsoft recommends **separate** profiles for on-prem and cloud realms, on-prem deployed first.
- `custom_tgt_setting` (Company Portal 2508+) in the Enterprise SSO extension data controls mapping: `0` both (default), `1` on-prem only, `2` cloud only, `3` none.
- Prereqs: macOS 14.6+, Company Portal 5.2408.0+, MDM enrolment, PSSO deployed.
- Microsoft owns TGT *issuance*; Apple owns the Kerberos extension. If `app-sso platform -s` shows the TGTs, Microsoft's part worked — further Kerberos behaviour is Apple-native.

### 4. Network considerations
- Needs DNS SRV (`_ldap._tcp.dc._msdcs`, `_kerberos._tcp`) and TCP/UDP 88, 389 to DCs; 445 to file servers.
- With a Network Extension VPN, authentication triggers the VPN automatically. With **per-app VPN**, the Kerberos processes (`com.apple.KerberosExtension`, `com.apple.AppSSOAgent`, `com.apple.KerberosMenuExtra`) must be in the App-to-App-Layer VPN mapping; the LDAP ping then keeps "reconnecting" the per-app VPN, which is expected behaviour.
- Cloud Kerberos uses KKDCP over HTTPS to `login.microsoftonline.com` — works without line-of-sight to a DC.

### 5. Accounts
The extension is designed for **local** accounts on unbound Macs. With legacy mobile accounts, password sync doesn't work and password-change URLs are unsupported — another reason to retire binding.
</details>

---
## Dependency Stack

```
[8] Resource access: SMB/HTTP/Azure Files open with no prompt
[7] Client behaviour: FQDN used; browsers allowlisted for Negotiate
[6] Service ticket: cifs/<fqdn> or HTTP/<fqdn> SPN exists in AD and is unique
[5] TGT: from extension sign-in OR PSSO tgt_ad/tgt_cloud (usePlatformSSOTGT)
[4] Time: client clock within max skew of DC
[3] Network: DNS SRV resolves; 88/389/445 reachable (LAN, full-tunnel, or mapped per-app VPN); KKDCP for cloud
[2] Profile: com.apple.extensiblesso Kerberos payload — UPPERCASE Realm, Hosts with and without leading dot
[1] Identity plumbing (PSSO mode): Entra Kerberos server object per AD domain; Company Portal 5.2408+; macOS 14.6+
[0] Platform: Mac MDM-enrolled (User Approved), local account
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| No Kerberos menu extra, `app-sso -l` empty | Profile not delivered | `profiles -P`, Intune assignment |
| Prompted for AD creds on every network change | "Sign in automatically" disabled/not allowed | `allowAutomaticLogin`, user choice |
| Menu extra "Not signed in" with PSSO | Expected — PSSO supplies TGT | `klist`, resource test |
| `tgt_ad` missing, `tgt_cloud` present | No Entra Kerberos server object, or `custom_tgt_setting=2` | `Get-AzureADKerberosServer`, extension data |
| Both TGTs missing | PSSO not registered, Company Portal too old, `custom_tgt_setting=3` | `app-sso platform -s` |
| `klist` shows TGT, SMB prompts | IP/alias used, missing/duplicate SPN, host not in `Hosts` | `klist` for cifs ticket, `setspn -Q` |
| Safari OK, Edge/Chrome prompt | Browser allowlist policies missing | `defaults read com.microsoft.Edge` |
| Works on office LAN only | VPN/DNS path; per-app VPN mapping | SRV lookups on VPN, VPN mapping |
| "Clock skew too great" | Time drift | `sntp` |
| Password-expiry warnings missing | `performKerberosOnly=true` (by design) | profile |
| Local password drifts from AD | `syncLocalPassword` off, or mobile account in use | profile, account type |
| Azure Files mount fails with Cloud TGT | Uppercase `CIFS` in app manifest; preview not enabled | storage app registration |

---
## Validation Steps

1. **Profile**: `sudo profiles -P -o stdout | grep -B5 -A25 AppSSOKerberos` — good: realm, hosts, extension data as designed. Bad: absent or duplicate profiles for the same realm.
2. **Realms**: `app-sso -l` — good: lists `CONTOSO.COM` (and `KERBEROS.MICROSOFTONLINE.COM` if cloud profile deployed).
3. **Realm info**: `app-sso -i CONTOSO.COM -j` — good: site code populated; standalone mode also shows user and password-expiry date.
4. **PSSO TGT hand-off**: `app-sso platform -s` — good: entries with `ticketKeyPath` `tgt_ad` / `tgt_cloud`.
5. **Ticket cache**: `klist` — good: `krbtgt/CONTOSO.COM@CONTOSO.COM` valid; after access, `cifs/<fqdn>@CONTOSO.COM`.
6. **Resource**: `open smb://<fqdn>/<share>` — good: mounts silently.
7. **Logs**: `log show --last 15m --predicate 'subsystem BEGINSWITH "com.apple.AppSSO"' --info` — good: TGT acquisition success lines; bad: KDC unreachable / principal unknown / preauth failed.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Delivery.** Intune profile status → `profiles -P` → realm casing and `Hosts` entries → conflicting legacy (Jamf-era) SSO profiles for the same realm.

**Phase 2 — TGT acquisition.** Standalone: `app-sso -a` and read the error. PSSO: prerequisites (macOS 14.6, Company Portal version) → `app-sso platform -s` → Entra Kerberos server object → `usePlatformSSOTGT` → `custom_tgt_setting`.

**Phase 3 — Network.** SRV lookups, port reachability, VPN mode/mapping, split DNS, clock skew.

**Phase 4 — Service tickets.** FQDN vs IP, SPN existence/duplicates (`setspn -Q cifs/<fqdn>` / `setspn -X` on a DC), DFS referrals, browser allowlists.

**Phase 5 — Lifecycle.** Password change/expiry, local password sync, user renames/UPN changes (`app-sso -d` then re-auth), stale cache (`app-sso -r`).

---
## Remediation Playbooks

<details><summary>Playbook 1 — Deploy Kerberos SSO for on-prem AD with Platform SSO (Microsoft reference pattern)</summary>

1. Ensure Entra Kerberos server object exists in each user domain (Windows admin host):
   ```powershell
   Import-Module AzureADHybridAuthenticationManagement
   $domain = "<ad-domain.com>"
   Get-AzureADKerberosServer -Domain $domain -UserPrincipalName "<admin@tenant.com>"
   # If missing (requires Domain Admin + Hybrid Identity Admin):
   # Set-AzureADKerberosServer -Domain $domain -UserPrincipalName "<admin@tenant.com>"
   ```
2. Build `on-prem-kerberos.mobileconfig` from Microsoft's sample (`Realm` uppercase, `Hosts` `.contoso.com` + `contoso.com`, `usePlatformSSOTGT` + `performKerberosOnly` true).
3. Intune → macOS → Templates → **Custom** → upload → device channel → assign to the **user** group already receiving Platform SSO.
4. Validate: `app-sso platform -s` shows `tgt_ad`; share opens silently.

Rollback: unassign the profile; tickets expire naturally or `kdestroy -A`.
</details>

<details><summary>Playbook 2 — Add Entra Cloud Kerberos (Azure Files) realm</summary>

Separate profile, deployed **after** the on-prem one:
- `Realm` = `KERBEROS.MICROSOFTONLINE.COM`
- `Hosts` = `windows.net`, `.windows.net`
- `preferredKDCs` = `kkdcp://login.microsoftonline.com/<tenant-id>/kerberos`
- `usePlatformSSOTGT` = true, `performKerberosOnly` = true

Ensure the storage account's app registration manifest uses lowercase `cifs`. Note Microsoft marks Mac PSSO → Azure Files as limited preview. See `../../Azure/Files/AzureFiles-A.md`.
</details>

<details><summary>Playbook 3 — Standalone Kerberos SSO for Macs without Platform SSO</summary>

Use Intune **Device features → Single sign-on app extension → Kerberos**: realm, domains/hosts, allow automatic login, password-change and sync settings as policy dictates. Users sign in once via the menu extra. Recommended when Macs are not (yet) Entra-joined but must reach AD file shares.

Rollback: unassign profile; optionally `app-sso -d CONTOSO.COM` per user.
</details>

<details><summary>Playbook 4 — Reset a user's Kerberos SSO state</summary>

```bash
app-sso -d CONTOSO.COM      # sign out of the realm
app-sso -r CONTOSO.COM      # reset realm cache (site code etc.)
app-sso -k CONTOSO.COM      # reset "login automatically" keychain option
kdestroy -A                 # destroy all ticket caches
app-sso -a CONTOSO.COM      # re-authenticate
```
Non-destructive to user data; the user must re-enter AD credentials in standalone mode.
</details>

<details><summary>Playbook 5 — Browser Negotiate policy for Edge & Chrome</summary>

Intune → macOS → Settings Catalog → **Microsoft Edge**: `AuthServerAllowlist` = `*.contoso.com`; `AuthNegotiateDelegateAllowlist` = `*.contoso.com` (delegation only if the web app needs to forward credentials). Equivalent Chrome policies via preference file for `com.google.Chrome`.
</details>

---
## Evidence Pack

```bash
# Run as the affected user (not root) so the user's ticket cache is visible
bash Get-KerberosSSOStatus.sh --realm CONTOSO.COM --test-host fs01.contoso.com
```
Add manually: Intune profile export(s), `Get-AzureADKerberosServer` output, DC-side Kerberos events (4768/4769/4771) for the user around the failure time.

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| List configured realms | `app-sso -l` |
| Realm info (JSON) | `app-sso -i CONTOSO.COM -j` |
| Authenticate / force | `app-sso -a CONTOSO.COM [-u user] [-f]` |
| Sign out realm | `app-sso -d CONTOSO.COM` |
| Reset realm cache | `app-sso -r CONTOSO.COM` |
| Site lookup | `app-sso -s CONTOSO.COM` |
| Release delayed setup | `app-sso -p CONTOSO.COM` |
| PSSO state / TGT mapping | `app-sso platform -s` |
| Ticket list | `klist` |
| Destroy tickets | `kdestroy -A` |
| Manual TGT (test) | `kinit user@CONTOSO.COM` |
| DC discovery | `dig +short -t SRV _ldap._tcp.dc._msdcs.contoso.com` |
| Logs | `log show --last 15m --predicate 'subsystem BEGINSWITH "com.apple.AppSSO"' --info` |
| Profile content | `sudo profiles -P -o stdout \| grep -A25 AppSSOKerberos` |
| Ticket Viewer GUI | `open "/System/Library/CoreServices/Applications/Ticket Viewer.app"` |

---
## 🎓 Learning Pointers

- **Read Apple's model first.** Proactive TGT refresh, LDAP-ping site discovery and date-based password sync explain most "why did it prompt?" questions. [Kerberos SSO extension — Apple Platform Deployment](https://support.apple.com/guide/deployment/kerberos-sso-extension-depe6a1cda64/web)
- **Microsoft's PSSO Kerberos guide is the reference pattern** for Entra-joined Macs, including the two-profile design and `custom_tgt_setting`. [Enable Kerberos SSO in Platform SSO](https://learn.microsoft.com/en-us/entra/identity/devices/device-join-macos-platform-single-sign-on-kerberos-configuration)
- **Every payload key is documented** — check before inventing values. [Extensible SSO Kerberos payload settings](https://support.apple.com/guide/deployment/extensible-single-sign-kerberos-payload-dep13c5cfdf9/web)
- **Cloud Kerberos trust is shared infrastructure** with Windows Hello for Business — one `AzureADKerberos` object per domain serves both platforms. [WHfB cloud Kerberos trust deployment](https://learn.microsoft.com/en-us/windows/security/identity-protection/hello-for-business/deploy/hybrid-cloud-kerberos-trust)
- **Graph can audit it**: Intune's Kerberos SSO profiles surface as `macOSKerberosSingleSignOnExtension` in the Graph beta device configuration resource — handy for fleet-wide realm/hosts audits. [macOSKerberosSingleSignOnExtension resource type](https://learn.microsoft.com/en-us/graph/api/resources/intune-deviceconfig-macoskerberossinglesignonextension?view=graph-rest-beta)
- Hotfix path: `KerberosSSO-B.md`. Related: `Platform-SSO-A.md`, `../../Azure/Files/AzureFiles-A.md`.
