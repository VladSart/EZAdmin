# Azure Key Vault — Agent Instructions

## What's in this folder

Runbooks and scripts for **Azure Key Vault** access and configuration troubleshooting — authorization model confusion (RBAC vs. legacy Access Policy), network/private-endpoint access denials, soft-delete and purge-protection recovery, and certificate auto-rotation failures. Scoped to Standard and Premium (software/HSM-backed) vaults, not Managed HSM (a separate resource type with its own RBAC model, out of scope here).

---

## Before responding, also check

- **EntraID/Troubleshooting/AppRegistrations** — client secrets/certificates on app registrations are an alternative credential store to Key Vault; a "where should this secret live" question may belong there instead
- **EntraID/Troubleshooting/WorkloadIdentity** — federated credentials remove the need for a stored secret entirely (in Key Vault or anywhere else) for supported CI/CD and workload scenarios
- **Security/Sentinel/DataConnectors** — Key Vault diagnostic logs (`AuditEvent`) are a common Sentinel ingestion source for access-anomaly detection; if the question is about *monitoring* vault access rather than fixing a denial, that folder covers the SIEM side
- **Azure/Backup**, **Security/Purview/RetentionLabels** — both contain the same "irreversible one-way-door" pattern (immutability lock, regulatory retention) as Key Vault purge protection; useful parallel when explaining irreversibility risk to a client

---

## Folder contents

| File | What it covers |
|------|----------------|
| `KeyVault-B.md` | Hotfix runbook — authorization model mismatch, firewall/private-endpoint/DNS denials, soft-delete recovery, certificate renewal failures, RBAC propagation delay |
| `KeyVault-A.md` | Deep dive — full RBAC-vs-Access-Policy architecture, network path evaluation, soft-delete/purge-protection lifecycle, certificate auto-rotation CA-partnership model, migration and recovery playbooks |
| `Scripts/Get-KeyVaultAccessAudit.ps1` | Read-only report across one or all vaults: authorization model + grants, network posture, soft-delete/purge-protection state, certificate expiry vs. auto-renew capability, diagnostic logging presence |

---

## Common entry points

- **"I have a role assignment but still get access denied"** → `KeyVault-B.md` Fix 1 (authorization model mismatch — check `EnableRbacAuthorization` first)
- **"403 from inside the VNet with a private endpoint"** → `KeyVault-B.md` Fix 2 — check DNS resolution before touching firewall rules
- **"I deleted a secret/key/cert/vault by mistake"** → `KeyVault-B.md` Fix 3 / `KeyVault-A.md` Playbook 3 (soft-delete recovery; vault recovery does NOT restore RBAC/Event Grid)
- **"A certificate stopped auto-renewing"** → `KeyVault-B.md` Fix 4 — confirm the issuer is Key-Vault-partnered (DigiCert/GlobalSign) before assuming a bug
- **"Should we move from access policies to RBAC?"** → `KeyVault-A.md` Playbook 1 — migration sequence, does not auto-migrate existing grants
- **"Client wants purge protection enabled"** → `KeyVault-A.md` Playbook 2 — irreversible, get explicit sign-off first
- **"Audit who has access to our vaults"** → `Scripts/Get-KeyVaultAccessAudit.ps1 -AllVaults`

---

## Key diagnostic commands

```powershell
# Authorization model — check this FIRST, before any permission troubleshooting
$vault = Get-AzKeyVault -VaultName "<vaultName>" -ResourceGroupName "<rg>"
$vault.EnableRbacAuthorization

# Who has access, in whichever model is active
Get-AzRoleAssignment -Scope $vault.ResourceId          # RBAC mode
$vault.AccessPolicies                                   # Access Policy mode

# Network posture
$vault.NetworkAcls
Get-AzPrivateEndpointConnection -PrivateLinkResourceId $vault.ResourceId

# Soft-deleted objects/vaults
Get-AzKeyVaultSecret -VaultName "<vaultName>" -Name "<secretName>" -InRemovedState -ErrorAction SilentlyContinue
Get-AzKeyVault -VaultName "<vaultName>" -InRemovedState

# Certificate renewal failure detail
Get-AzKeyVaultCertificateOperation -VaultName "<vaultName>" -Name "<certName>"
```

---

## Key dependency chain

```
Key Vault resource (control plane)
    │
    ├── EnableRbacAuthorization (true|false — exclusive switch, not additive)
    │       ├── RBAC → role assignment at vault/RG/sub scope
    │       └── Access Policy (legacy) → per-principal entry on the vault object itself
    │
    ├── Network path (independent of authorization — both must pass)
    │       └── Public+IP allow-list | Private Endpoint (+ correct DNS) | Trusted Services bypass
    │
    ▼
Data-plane operation on key/secret/certificate
    │
    └── Object lifecycle: active | soft-deleted (recoverable) | purge-protected (unrecoverable-early, permanent)
            │
            └── (Certificates) Partnered-CA issuer required for auto-rotation — else manual renewal only
```

---

## Response format reminder (always 3 layers)

1. **Immediate action** — unblock the specific denied request or failed renewal (Mode B)
2. **Root cause** — which layer actually failed: authorization model, network path, or object lifecycle (Mode A)
3. **Prevention** — confirm authorization model matches documentation, diagnostic logging is enabled, and purge protection intent is explicit and signed off before any irreversible change
