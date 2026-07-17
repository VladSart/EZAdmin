# Azure Key Vault — Hotfix Runbook (Mode B: Ops)
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

Run these from an admin workstation with the `Az.KeyVault` / `Az.Resources` modules.

```powershell
# 1. Which authorization model is this vault actually using?
$vault = Get-AzKeyVault -VaultName "<vaultName>" -ResourceGroupName "<rg>"
$vault.EnableRbacAuthorization   # $true = RBAC-only, access policies are IGNORED entirely

# 2. If RBAC mode: does the caller have a role assignment AT OR ABOVE the vault scope?
Get-AzRoleAssignment -Scope $vault.ResourceId | Select-Object DisplayName, RoleDefinitionName, Scope

# 3. If Access Policy mode: does the caller have an explicit policy entry?
(Get-AzKeyVault -VaultName "<vaultName>" -ResourceGroupName "<rg>").AccessPolicies |
    Where-Object { $_.ObjectId -eq "<callerObjectId>" }

# 4. Is the vault firewall/private-endpoint blocking the caller's network path?
$vault.NetworkAcls

# 5. Is the vault (or the specific secret/key/cert) soft-deleted rather than genuinely missing?
Get-AzKeyVault -VaultName "<vaultName>" -InRemovedState
Get-AzKeyVaultSecret -VaultName "<vaultName>" -Name "<secretName>" -InRemovedState -ErrorAction SilentlyContinue
```

**Interpretation:**

| Finding | Action |
|---|---|
| `EnableRbacAuthorization = $true` but caller only has an Access Policy entry | Fix 1 — policy is silently ignored, caller needs an actual RBAC role assignment |
| `EnableRbacAuthorization = $false` but caller only has an RBAC role | Fix 1 — same mismatch, inverted; vault is in legacy Access Policy mode |
| Error: `Caller is not authorized to perform action` | Fix 1 — insufficient permission in whichever model is active |
| Error: `This TCP connection does not allow access to <vault>.vault.azure.net` | Fix 2 — firewall/private endpoint block, check DNS resolution first |
| Error: `Public access is disabled and the request was not made from a trusted service or via an approved private link` | Fix 2 — same firewall family, confirm private endpoint approval state |
| Vault/object exists in `-InRemovedState` but not in normal listing | Fix 3 — soft-deleted, recoverable within retention window |
| Certificate stuck in `inProgress` past expected renewal window | Fix 4 — auto-rotation failure, check Certificate Operation error |
| Role assignment just created but access still denied | Fix 5 — RBAC propagation delay, not a real permission gap (wait, don't re-grant) |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Key Vault resource (control plane — ARM: create/delete vault, manage firewall/network rules)
    │
    ├── Authorization model switch: EnableRbacAuthorization (exclusive — pick one)
    │       │
    │       ├── RBAC mode  → Azure role assignment at vault/RG/sub scope
    │       │                 (Key Vault Administrator / Secrets User / Certificates Officer / etc.)
    │       │                 Access Policies block is present but 100% IGNORED
    │       │
    │       └── Access Policy mode (legacy) → per-principal policy entry on the vault object itself
    │                         (any Contributor-role holder can grant themselves data-plane access —
    │                          this is the core security weakness RBAC mode fixes)
    │
    ▼
Network path allowed (data plane request must physically reach the vault)
    │
    ├── Public network access enabled + caller IP/range allow-listed, OR
    ├── "Allow trusted Microsoft services to bypass this firewall" (for first-party Azure services), OR
    └── Private Endpoint: connection state = Approved, provisioning state = Succeeded,
        AND client DNS resolves <vault>.vault.azure.net to the PRIVATE IP (not public)
    │
    ▼
Data plane operation authorized by the active model (step 2) AND allowed by network path (step 3)
    │
    ▼
Object-level state: key/secret/certificate must not be soft-deleted, disabled, or expired
    │
    ▼
(Certificates only) Auto-rotation: valid CA issuer integration credentials still current
    → renewal request → new cert version → dependent app picks up new version
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm which authorization model is active (do this before touching any permissions)**
```powershell
(Get-AzKeyVault -VaultName "<vaultName>" -ResourceGroupName "<rg>").EnableRbacAuthorization
```
`$true` = RBAC-only. `$false`/`$null` = legacy Access Policy mode. **The two models cannot be mixed** — granting an Access Policy entry on an RBAC-mode vault does nothing, and vice versa. Since API version `2026-02-01`, new vaults default to RBAC unless `enableRbacAuthorization` was explicitly set `$false` at creation, so don't assume a vault's age tells you its mode.

**Step 2 — Confirm the caller's actual grant matches that model**
```powershell
# RBAC mode:
Get-AzRoleAssignment -ObjectId "<callerObjectId>" -Scope $vault.ResourceId

# Access Policy mode:
(Get-AzKeyVault -VaultName "<vaultName>" -ResourceGroupName "<rg>").AccessPolicies |
    Where-Object ObjectId -eq "<callerObjectId>"
```
Expected: a role/policy entry that covers the specific operation attempted (e.g. `Key Vault Secrets User` only grants read of secrets, not write — a common under-grant).

**Step 3 — If access was JUST granted, rule out propagation delay before re-troubleshooting**
RBAC role assignment writes are eventually consistent — allow several minutes and retry with backoff before assuming the grant didn't take. Re-running the same `New-AzRoleAssignment` command repeatedly does not speed this up and can create duplicate assignments to clean up later.

**Step 4 — Confirm network path if the error is firewall/connection-shaped, not permission-shaped**
```powershell
$vault.NetworkAcls.DefaultAction        # Allow or Deny
$vault.NetworkAcls.IpRules
$vault.PrivateEndpointConnections | Select-Object Name, PrivateLinkServiceConnectionState
```
Expected for private-endpoint-only access: `DefaultAction = Deny`, and the relevant `PrivateEndpointConnections` entry shows `Status = Approved`. From the client machine, `Resolve-DnsName <vaultName>.vault.azure.net` — if it resolves to a public IP instead of a `10.x`/`172.x`/`192.168.x` private address, DNS (not the firewall rule itself) is the actual root cause.

**Step 5 — Confirm the object isn't soft-deleted**
```powershell
Get-AzKeyVaultSecret -VaultName "<vaultName>" -Name "<secretName>" -InRemovedState -ErrorAction SilentlyContinue
```
A result here means the secret/key/cert was deleted but is still inside its recovery window (default 90 days, configurable 7-90) — recoverable, not gone. An empty vault-level `Get-AzKeyVault` combined with a hit on `Get-AzKeyVault -InRemovedState` means the whole vault was deleted, not just an object inside it.

**Step 6 — For certificate renewal failures, pull the operation-level error, not just "expired"**
```powershell
Get-AzKeyVaultCertificateOperation -VaultName "<vaultName>" -Name "<certName>"
```
The `Error` field on the operation object names the real cause (commonly an expired/revoked CA integration credential, e.g. a DigiCert API key or GlobalSign account password) — "renewal failed" alone is not enough to act on.

---
## Common Fix Paths

<details><summary>Fix 1 — Authorization model mismatch or under-grant</summary>

```powershell
# Confirm the model first — do not grant into the wrong system
$vault.EnableRbacAuthorization

# RBAC mode — grant the narrowest role that covers the need:
New-AzRoleAssignment -ObjectId "<callerObjectId>" -RoleDefinitionName "Key Vault Secrets User" `
    -Scope $vault.ResourceId
# Common roles: "Key Vault Administrator" (full data-plane control, avoid for app identities),
# "Key Vault Secrets User" / "Key Vault Certificates Officer" / "Key Vault Crypto User" (scoped)

# Access Policy mode (legacy) — only if the vault is confirmed NOT RBAC:
Set-AzKeyVaultAccessPolicy -VaultName "<vaultName>" -ObjectId "<callerObjectId>" `
    -PermissionsToSecrets get,list
```

**Rollback:** `Remove-AzRoleAssignment` (RBAC) or `Remove-AzKeyVaultAccessPolicy` (legacy) — removing an over-broad grant is safe and reversible; re-add if scoped too narrowly.

</details>

<details><summary>Fix 2 — Firewall / private endpoint / DNS block</summary>

```powershell
# Confirm private endpoint is actually approved (not Pending/Rejected/Disconnected)
Get-AzPrivateEndpointConnection -PrivateLinkResourceId $vault.ResourceId |
    Select-Object Name, PrivateLinkServiceConnectionState

# If a legitimate first-party Azure service (e.g. ARM template deployment, Azure Backup) needs access:
Update-AzKeyVaultNetworkRuleSet -VaultName "<vaultName>" -Bypass AzureServices

# If DNS is the root cause (client resolving to public IP instead of private):
# — confirm the client's DNS server forwards privatelink.vaultcore.azure.net queries to
#   Azure DNS (168.63.129.16) rather than answering from a public zone.
Resolve-DnsName "<vaultName>.vault.azure.net"
Resolve-DnsName "<vaultName>.privatelink.vaultcore.azure.net"
```

**Rollback:** none required for read-only diagnostic commands. `Update-AzKeyVaultNetworkRuleSet -Bypass None` reverts the trusted-services exception if it was added in error.

</details>

<details><summary>Fix 3 — Recover a soft-deleted object or vault</summary>

```powershell
# Recover a single deleted secret/key/certificate (object still exists in soft-delete state)
Undo-AzKeyVaultSecretRemoval -VaultName "<vaultName>" -Name "<secretName>"

# Recover an entire deleted vault
Undo-AzKeyVaultRemoval -VaultName "<vaultName>" -ResourceGroupName "<rg>" -Location "<region>"
```

**Rollback:** N/A — recovery is the fix. **Important:** recovering a vault restores the vault resource and its recoverable objects, but does **not** restore RBAC role assignments or Event Grid subscriptions that pointed at it — those must be manually recreated after recovery, or every caller will hit Fix 1's error again immediately post-recovery.

</details>

<details><summary>Fix 4 — Certificate auto-rotation failure</summary>

```powershell
# Pull the real error from the operation object
Get-AzKeyVaultCertificateOperation -VaultName "<vaultName>" -Name "<certName>"

# If the CA integration credential itself expired (DigiCert/GlobalSign), update it:
Set-AzKeyVaultCertificateIssuer -VaultName "<vaultName>" -Name "<issuerName>" `
    -IssuerProvider DigiCert -ApiKey "<newApiKey>"

# Manually trigger a renewal retry once the credential is fixed
$policy = Get-AzKeyVaultCertificatePolicy -VaultName "<vaultName>" -Name "<certName>"
Add-AzKeyVaultCertificate -VaultName "<vaultName>" -Name "<certName>" -CertificatePolicy $policy
```

**Rollback:** none needed — a failed renewal attempt does not affect the currently-active, still-valid certificate version. Note: autorotation only works for certificates issued through a Key Vault-partnered CA; self-signed or manually-imported certs from a non-partnered CA will never auto-renew regardless of policy settings.

</details>

<details><summary>Fix 5 — RBAC propagation delay mistaken for a permission gap</summary>

```powershell
# Confirm the assignment actually exists before assuming it needs to be re-created
Get-AzRoleAssignment -ObjectId "<callerObjectId>" -Scope $vault.ResourceId

# If present but access still fails within the first few minutes, wait and retry with backoff
# rather than deleting/re-creating the assignment (which restarts the propagation clock)
Start-Sleep -Seconds 120
Get-AzKeyVaultSecret -VaultName "<vaultName>" -Name "<secretName>"
```

**Rollback:** N/A — no change made, this fix path is "wait, don't churn the assignment."

</details>

---
## Escalation Evidence

```
=== Azure Key Vault Escalation Pack ===
Date/Time:                  _______________
Vault Name:                 _______________
Resource Group:             _______________
Subscription:                _______________

Authorization model:        RBAC / Access Policy (EnableRbacAuthorization = ___)
Caller identity (ObjectId): _______________
Role/Policy grant found:    _______________ (paste Get-AzRoleAssignment or AccessPolicies output)

Network ACL default action: Allow / Deny
Private endpoint state:     Approved / Pending / Rejected / Disconnected / N/A
Client DNS resolution test: Resolved to _______________ (public / private IP)

Error message (exact):      _______________
Object soft-delete check:   Present in -InRemovedState? Yes / No

Actions taken so far:
1.
2.
3.

Escalation contact: Microsoft Support via Azure Portal > Key Vault > Support + troubleshooting > New Support Request
Reference: https://learn.microsoft.com/en-us/azure/key-vault/general/troubleshooting-access-issues
```

---
## 🎓 Learning Pointers

- **The two authorization models are mutually exclusive, not layered.** If a vault has `EnableRbacAuthorization = $true`, its Access Policies block still displays in the portal/PowerShell output but is completely inert — granting a policy entry there does nothing. This is the single most common Key Vault access-denied root cause. See [Azure RBAC vs. access policies](https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-access-policy).
- **New vaults default to RBAC as of API version 2026-02-01 — don't assume based on vault age or org habit.** Older automation/IaC templates written before this change may still explicitly set `enableRbacAuthorization: false`, so always check the live property rather than assuming. See [Prepare for Key Vault API version 2026-02-01 and later](https://learn.microsoft.com/en-us/azure/key-vault/general/access-control-default).
- **A 403 from inside a VNet with a private endpoint is usually DNS, not the firewall rule.** If the client resolves the vault's FQDN to its public IP instead of the private endpoint IP, the request goes out to the public endpoint and gets blocked there — the private endpoint itself can be perfectly healthy. Always check DNS resolution before touching firewall rules. See [Troubleshoot 403 errors through an approved private endpoint](https://learn.microsoft.com/en-us/troubleshoot/azure/private-link/troubleshoot-403-access-denied-private-endpoint).
- **Recovering a deleted vault does not restore who could access it.** RBAC role assignments and Event Grid subscriptions are not part of the vault's soft-delete recovery — every downstream app/identity will hit an authorization error immediately after a vault recovery until those are manually recreated. Plan for this explicitly during any vault-recovery runbook, don't discover it live.
- **Purge protection is a genuine one-way door.** Once enabled, no role, no permission level, and no Microsoft support escalation can disable it or bypass the retention period — confirm this is actually wanted (usually yes, for production secrets) before enabling, since it cannot be undone. See [Key Vault soft-delete overview](https://learn.microsoft.com/en-us/azure/key-vault/general/soft-delete-overview).
