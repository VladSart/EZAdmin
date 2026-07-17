# Azure Key Vault — Reference Runbook (Mode A: Deep Dive)
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

| Item | Detail |
|------|--------|
| Product | Azure Key Vault — data-plane access to keys, secrets, and certificates; vault-level network/soft-delete/purge-protection configuration |
| Applies to | Standard and Premium (HSM-backed) vaults. Managed HSM is a distinct dedicated resource with its own RBAC model — flagged separately below, not covered in depth |
| Authorization models | Both Azure RBAC (recommended, default for new vaults as of API version `2026-02-01`) and the legacy Access Policy model |
| Out of scope | Managed HSM (separate resource type, separate RBAC built-in roles, no access-policy legacy mode at all); Key Vault's use as a certificate source *inside* other services' own troubleshooting (e.g. App Service TLS binding, AKS CSI driver secrets store) — those are covered in each consuming service's own runbook where they exist; client-side SDK code issues (this repo covers admin/ops diagnosis, not application development) |
| Related | `Security/Sentinel/DataConnectors-A.md` (Key Vault diagnostic logs as a Sentinel data source), `EntraID/Troubleshooting/AppRegistrations-A.md` (client secrets/certificates as an alternative to storing credentials in Key Vault), `EntraID/Troubleshooting/WorkloadIdentity-A.md` (federated credentials as a Key-Vault-free alternative for workload auth) |

---
## How It Works

<details><summary>Full architecture</summary>

Azure Key Vault splits cleanly into a **control plane** (managing the vault resource itself — create, delete, configure network rules, configure the authorization model) and a **data plane** (reading/writing the keys, secrets, and certificates stored inside it). Every troubleshooting question in this domain starts by identifying which plane the failure is actually in — a control-plane-authorized user (e.g. `Contributor` on the resource group) can be completely unable to read a secret if they lack data-plane rights, which surprises engineers used to Azure's more unified RBAC story elsewhere.

**The two data-plane authorization models (mutually exclusive):**

1. **Azure RBAC** (recommended, and the default for new vaults created with API version `2026-02-01` or later). Built on Azure Resource Manager — the same role-assignment mechanism used everywhere else in Azure. A role assignment is `(security principal, role definition, scope)`. Built-in data-plane roles include `Key Vault Administrator` (full control), `Key Vault Secrets Officer`/`Key Vault Secrets User`, `Key Vault Certificates Officer`, `Key Vault Crypto Officer`/`Key Vault Crypto User`, and `Key Vault Reader`. Granting access requires `Microsoft.Authorization/roleAssignments/write`, which by default only `Owner` and `User Access Administrator` hold — a deliberate separation from vault management rights.
2. **Access Policy model (legacy)**. Native to Key Vault, operates purely on the data plane. Permissions are granted per-principal directly on the vault resource's `AccessPolicies` collection (`get`, `list`, `set`, `delete`, etc., independently per object type — keys/secrets/certificates). The critical weakness: anyone holding `Contributor`, `Key Vault Contributor`, or any role with `Microsoft.KeyVault/vaults/write` can edit the vault's access policies and grant themselves data-plane access — control-plane and data-plane authorization are not actually separated in this model.

**The `enableRbacAuthorization` boolean on the vault resource is the single switch between the two models, and it is exclusive — not additive.** If `true`, the vault ignores its `AccessPolicies` collection entirely, even if it's populated (often left over from before a migration). If `false`, RBAC role assignments scoped to the vault have zero effect on data-plane operations. This is the root cause of the majority of real-world "I have a role assignment but still get Forbidden" tickets — the caller has a grant in the *wrong* system for that specific vault.

**Network path (evaluated independently of authorization):**
Even a fully-authorized caller is denied if the request can't reach the vault's data-plane endpoint per its network ACLs:
- `NetworkAcls.DefaultAction = Allow` — open to any IP unless explicitly denied (rare in production).
- `DefaultAction = Deny` with `IpRules` — only listed public IP ranges permitted.
- `DefaultAction = Deny` with a **Private Endpoint** — the vault has a dedicated NIC inside a customer VNet; the client must both resolve the vault's FQDN to that private IP (via a `privatelink.vaultcore.azure.net` DNS zone) and have network line-of-sight to it.
- **Trusted Services bypass** — a curated allow-list of first-party Azure services (e.g. Azure Backup, ARM template deployment engine, Azure Resource Manager itself for certain operations) that can reach a firewalled vault without being on the VNet, provided the service instance's own managed identity is separately authorized on the vault.

A very common failure mode: the private endpoint is healthy and Approved, firewall rules are correct, but the client's DNS resolver answers the vault's public FQDN with its **public** IP instead of forwarding the `privatelink.*` zone to Azure DNS — the request then physically leaves toward the public endpoint and is blocked there, producing a firewall-shaped error that looks like a network ACL misconfiguration but is actually a DNS misconfiguration.

**Soft-delete and purge protection (object lifecycle, not just vault lifecycle):**
Soft-delete applies at both the vault level and the individual object level (keys/secrets/certificates). It has been on by default for all new vaults for years, and — critically — **once enabled on a vault, it cannot be disabled**. Default retention is 90 days, configurable at creation between 7 and 90. Purge protection is a separate, optional, additive control: it can only be enabled after soft-delete is already on, and once enabled, **no principal — including a vault Owner, a subscription Owner, or Microsoft Support — can disable it or bypass the retention window**. This is a deliberate design against both accidental and malicious/compromised-admin permanent deletion, and should be communicated to clients as a genuine one-way door before enabling.

Recovering a soft-deleted **vault** (not just an object inside it) restores the vault resource and its recoverable contents, but explicitly does **not** restore RBAC role assignments scoped to that vault, nor Event Grid subscriptions that were watching it — both must be manually recreated post-recovery, or every previously-authorized caller will immediately hit an authorization error against an otherwise-healthy, fully-recovered vault.

**Certificate lifecycle and auto-rotation:**
A Key Vault certificate is really three linked objects under one name: a secret (holding the private key + cert, PFX-formatted), a key, and the certificate metadata/policy itself. Auto-rotation (autorenewal) only functions for certificates issued through a CA **partnered** with Key Vault (currently DigiCert and GlobalSign via configured Issuer objects) — self-signed certificates and certificates imported from a non-partnered CA will never auto-renew regardless of the policy's `LifetimeAction` settings, since there's no integration path for Key Vault to actually request a new cert from that CA. When a partnered-CA renewal does fail, the specific failure reason lives on the **Certificate Operation** object, not on the certificate itself — common causes are an expired or revoked CA account credential (the DigiCert API key or GlobalSign account password stored as the Issuer's authentication), expired domain validation with the CA, or the `reuse key on renewal` advanced policy setting interacting unexpectedly with a CA-side key-reuse restriction.

</details>

---
## Dependency Stack

```
Key Vault resource (control plane, ARM)
    │  ├── enableRbacAuthorization: true|false  (exclusive switch — see below)
    │  ├── NetworkAcls: DefaultAction Allow|Deny, IpRules, VirtualNetworkRules, Bypass (AzureServices|None)
    │  ├── PublicNetworkAccess: Enabled|Disabled
    │  ├── EnableSoftDelete: true (cannot be disabled once on), SoftDeleteRetentionInDays: 7-90
    │  └── EnablePurgeProtection: true|false (one-way door once true — irreversible by anyone)
    │
    ├── Authorization model (pick exactly one; the other is inert regardless of content)
    │       │
    │       ├── RBAC mode → Azure role assignment(s) at vault / resource-group / subscription scope
    │       │      requires Owner or User Access Administrator to grant
    │       │      integrated with PIM for time-bound elevation
    │       │
    │       └── Access Policy mode (legacy) → per-object-type permission grants on the vault's own
    │              AccessPolicies collection; any Contributor-class role holder can self-grant
    │
    ├── Network path (independently evaluated — authorization success does not bypass this)
    │       │
    │       ├── Public + IP allow-list, OR
    │       ├── Private Endpoint (Approved connection state + correct client DNS resolution
    │       │      to privatelink.vaultcore.azure.net), OR
    │       └── Trusted Microsoft Services bypass (first-party service + its own separate auth)
    │
    ▼
Data-plane object operation (get/set/delete on a key, secret, or certificate)
    │
    ├── Object lifecycle state: active, disabled (NotBefore/Expires bounds), or soft-deleted
    │       └── Soft-deleted object recoverable within retention window (unless purge-protected AND
    │            retention hasn't expired, in which case it's recoverable but NOT purgeable early)
    │
    └── (Certificates only) Issuer integration for auto-rotation
           │  DigiCert / GlobalSign account credential — independently expirable, separate from
           │  the certificate's own validity period
           ▼
        Renewal request → new certificate version → dependent consumers must pick up the new
        version (Key Vault does not push updates to consumers — polling/event-driven refresh
        is the consuming application's own responsibility, e.g. Event Grid on SecretNewVersionCreated)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| `Caller is not authorized to perform action` despite a visible role/policy grant | Grant exists in the wrong authorization model for this vault | `Get-AzKeyVault ...`.`EnableRbacAuthorization` vs where the grant actually lives |
| Access worked yesterday, fails today with no config change reported | RBAC role assignment was removed/expired (PIM time-bound elevation lapsed), or vault was recreated (new `enableRbacAuthorization` default) | `Get-AzRoleAssignment` history / Entra PIM audit log |
| `This TCP connection does not allow access to <vault>.vault.azure.net` | Firewall/private-endpoint block — commonly DNS resolving to public IP instead of private | `Resolve-DnsName`, `PrivateEndpointConnections` state |
| `Public access is disabled and the request was not made from a trusted service or via an approved private link` | Public network access disabled and caller is neither on an approved private endpoint nor a Trusted Service | `PublicNetworkAccess`, `NetworkAcls.Bypass` |
| Object present via `Get-...-InRemovedState` but missing from normal listing | Soft-deleted, within recovery window | `Undo-AzKeyVault<Type>Removal` |
| Vault itself missing, `Get-AzKeyVault -InRemovedState` returns it | Whole vault soft-deleted | `Undo-AzKeyVaultRemoval` (RBAC/Event Grid must be manually re-created after) |
| Attempt to purge a deleted vault/object fails / purge option missing entirely | Purge protection enabled — this is permanent and by design | Confirm `EnablePurgeProtection`; there is no override |
| Certificate stuck in `inProgress`, never completes | Domain validation with CA lapsed, or CA account credential expired | `Get-AzKeyVaultCertificateOperation` → `.Error` field |
| Certificate silently never auto-renews despite `LifetimeAction` policy configured | Certificate was self-signed or imported from a non-partnered CA | `Get-AzKeyVaultCertificate` → `.Policy.IssuerName` (must be DigiCert/GlobalSign, not `Self` or `Unknown`) |
| Recovered vault works for admins but every app/service integration is broken | RBAC role assignments / Event Grid subscriptions not restored by vault recovery | `Get-AzRoleAssignment -Scope $vault.ResourceId` returns empty post-recovery |
| Role assignment just granted, access still denied minutes later | RBAC write propagation delay (eventually consistent) | Retry with backoff; do not delete/recreate the assignment |
| Vault deletion blocked | Purge-protected soft-deleted vault still inside retention, or active role assignments/locks | `Get-AzKeyVault -InRemovedState`, resource locks |
| App using a cached secret value after a rotation | Consuming app has no refresh trigger — Key Vault does not push changes | Confirm app's own polling interval or Event Grid `SecretNewVersionCreated` subscription |

---
## Validation Steps

**1 — Confirm the authorization model matches what documentation/runbooks assume**
```powershell
$vault = Get-AzKeyVault -VaultName "<vaultName>" -ResourceGroupName "<rg>"
$vault.EnableRbacAuthorization
```
Bad: assuming based on when the vault was created. Vaults provisioned via older Terraform/Bicep templates may explicitly pin `enableRbacAuthorization: false` even if created recently — always read the live property.

**2 — Enumerate every principal with data-plane access, in whichever model is active**
```powershell
# RBAC
Get-AzRoleAssignment -Scope $vault.ResourceId | Select-Object DisplayName, RoleDefinitionName, Scope

# Access Policy
$vault.AccessPolicies | Select-Object DisplayName, PermissionsToSecrets, PermissionsToKeys, PermissionsToCertificates
```
Bad: any principal with `Key Vault Administrator` or full `set,delete` policy permissions who isn't a designated vault owner — flag as an over-grant for cleanup.

**3 — Confirm network posture matches intent**
```powershell
$vault.NetworkAcls | Select-Object DefaultAction, Bypass, IpRules, VirtualNetworkRules
$vault.PublicNetworkAccess
Get-AzPrivateEndpointConnection -PrivateLinkResourceId $vault.ResourceId
```
Bad: `PublicNetworkAccess = Enabled` on a vault the client believes is private-endpoint-only — a common drift when a firewall rule was temporarily opened for troubleshooting and never reverted.

**4 — Confirm soft-delete and purge protection settings are intentional, not accidental**
```powershell
$vault.EnableSoftDelete
$vault.SoftDeleteRetentionInDays
$vault.EnablePurgeProtection
```
Bad: `EnablePurgeProtection = $false` on a production vault holding compliance-relevant secrets (no genuine downside to enabling it other than irreversibility itself — confirm client intent explicitly either way, since this is one-way once flipped).

**5 — Confirm certificate auto-rotation health across the vault**
```powershell
Get-AzKeyVaultCertificate -VaultName "<vaultName>" | ForEach-Object {
    $cert = Get-AzKeyVaultCertificate -VaultName "<vaultName>" -Name $_.Name
    [PSCustomObject]@{
        Name = $_.Name
        Expires = $cert.Expires
        Issuer = $cert.Policy.IssuerName
        AutoRenewCapable = $cert.Policy.IssuerName -in @("DigiCert","GlobalSign","OneCertV2-PublicCA","OneCertV2-PrivateCA")
    }
}
```
Bad: any certificate within 30 days of `Expires` where `AutoRenewCapable = $false` — this will not self-heal and needs a manual renewal/reimport process tracked separately.

**6 — Confirm diagnostic logging is actually flowing (needed for any real incident investigation)**
```powershell
Get-AzDiagnosticSetting -ResourceId $vault.ResourceId
```
Bad: no diagnostic setting configured — without `AuditEvent` logs shipped to a Log Analytics workspace, there is no way to retroactively determine who accessed what, when, which is frequently the actual ask during a security incident involving this vault.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Access Denied / Authorization Errors
1. Determine the active authorization model first — every subsequent step depends on this and guessing wastes time.
2. Confirm the caller's grant exists in the *correct* model, at a scope that covers the vault, with permissions that cover the specific operation (read vs. write vs. delete are independently grantable in both models).
3. If a grant was just created, rule out RBAC propagation delay (up to several minutes) before troubleshooting further — this is the single most common false-positive "still broken" report.
4. Only after ruling out 1-3, escalate to Entra sign-in logs / Key Vault diagnostic logs to see the actual denied request's principal and reason code.

### Phase 2 — Network/Connectivity Errors
1. Distinguish an authorization error (`Caller is not authorized...`) from a network error (`This TCP connection does not allow access...` / `Public access is disabled...`) — they require entirely different fixes and are easy to conflate from a generic "access denied" client report.
2. For private-endpoint scenarios, check DNS resolution from the actual client before touching firewall rules — a large fraction of "firewall" tickets are actually DNS forwarding misconfiguration for the `privatelink.vaultcore.azure.net` zone.
3. Confirm private endpoint connection state is `Approved`/`Succeeded`, not `Pending` (awaiting resource-owner approval) or `Rejected`/`Disconnected`.
4. For first-party Azure service integrations (Backup, ARM deployments, etc.), confirm both the Trusted Services bypass is enabled AND the service's own managed identity has a separate data-plane grant — bypass alone does not grant permission, it only clears the network gate.

### Phase 3 — Deleted/Missing Objects or Vaults
1. Always check `-InRemovedState` before treating an object or vault as genuinely gone — soft-delete is on by default and has been for years.
2. If recovering a whole vault, immediately plan to re-create RBAC role assignments and Event Grid subscriptions — the recovery operation does not restore either, and every downstream integration will otherwise fail right after a "successful" recovery.
3. If purge is being requested and purge protection is enabled, stop — there is no override, including via Microsoft Support. Set correct client expectations before spending time attempting workarounds that do not exist by design.

### Phase 4 — Certificate Renewal Failures
1. Pull the actual error from `Get-AzKeyVaultCertificateOperation`, not just the certificate's expiry status — "expired" is a symptom, the operation error is the cause.
2. Confirm the issuing CA is a Key-Vault-partnered issuer before investigating further — a self-signed or non-partnered cert failing to "auto-renew" is expected behavior, not a bug, and needs a manual process instead.
3. For partnered-CA failures, check the Issuer object's stored credential expiry independently of the certificate's own expiry — these are two separate clocks that are easy to conflate.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Migrate a vault from Access Policy to RBAC</summary>

```powershell
# 1. Inventory existing access policy grants before switching (RBAC does not inherit them)
$vault = Get-AzKeyVault -VaultName "<vaultName>" -ResourceGroupName "<rg>"
$vault.AccessPolicies | Select-Object DisplayName, ObjectId, PermissionsToSecrets, PermissionsToKeys, PermissionsToCertificates |
    Export-Csv "PreMigration-AccessPolicies.csv" -NoTypeInformation

# 2. Recreate each principal's access as an equivalent RBAC role assignment BEFORE flipping the switch
foreach ($policy in $vault.AccessPolicies) {
    New-AzRoleAssignment -ObjectId $policy.ObjectId -RoleDefinitionName "Key Vault Secrets User" `
        -Scope $vault.ResourceId
}

# 3. Only after confirming every principal has an equivalent RBAC grant, flip the vault's model
Update-AzKeyVault -VaultName "<vaultName>" -ResourceGroupName "<rg>" -EnableRbacAuthorization $true

# 4. Verify — the old AccessPolicies collection will still display but is now fully inert
(Get-AzKeyVault -VaultName "<vaultName>" -ResourceGroupName "<rg>").AccessPolicies
```

**Rollback:** `Update-AzKeyVault -EnableRbacAuthorization $false` reverts to Access Policy mode; since the `AccessPolicies` collection was never deleted, prior grants become active again immediately. Keep the pre-migration CSV until the RBAC side is confirmed stable in production for at least one full business cycle.

</details>

<details><summary>Playbook 2 — Enable purge protection with correct client sign-off (irreversible)</summary>

```powershell
# Soft-delete must already be enabled (it has been default for years, but confirm):
(Get-AzKeyVault -VaultName "<vaultName>" -ResourceGroupName "<rg>").EnableSoftDelete

# This action is PERMANENT and cannot be reversed by any principal, including Microsoft Support:
Update-AzKeyVault -VaultName "<vaultName>" -ResourceGroupName "<rg>" -EnablePurgeProtection $true
```

**Rollback:** **None exists.** This is a genuine one-way door, architecturally identical in irreversibility to Purview retention-label regulatory records and Azure Backup vault immutability lock (see `Security/Purview/RetentionLabels-A.md` and `Azure/Backup/AzureBackup-A.md` for the parallel pattern). Obtain explicit, documented client approval before running this command — do not enable it "just to be safe" without that sign-off, since a legitimate future need to fully purge a specific secret (e.g. an accidentally-committed production credential that must be provably destroyed for compliance) becomes impossible until the full retention window elapses.

</details>

<details><summary>Playbook 3 — Recover a deleted vault and restore full functionality (not just the vault shell)</summary>

```powershell
# 1. Confirm the vault is recoverable (soft-deleted, not purged)
Get-AzKeyVault -VaultName "<vaultName>" -InRemovedState

# 2. Recover the vault resource and its recoverable objects
Undo-AzKeyVaultRemoval -VaultName "<vaultName>" -ResourceGroupName "<rg>" -Location "<region>"

# 3. RBAC role assignments are NOT restored — recreate from a pre-deletion export if available,
#    or from documentation/change records if not
$vault = Get-AzKeyVault -VaultName "<vaultName>" -ResourceGroupName "<rg>"
Get-AzRoleAssignment -Scope $vault.ResourceId   # will be empty immediately post-recovery

New-AzRoleAssignment -ObjectId "<principalId>" -RoleDefinitionName "Key Vault Secrets User" `
    -Scope $vault.ResourceId
# repeat for every principal that previously had access

# 4. Event Grid subscriptions watching this vault (e.g. for SecretNewVersionCreated automation)
#    must also be manually recreated — they are not restored by vault recovery either
```

**Rollback:** N/A — recovery is itself the remediation. The critical operational risk is treating step 2 as "done" — a recovered vault with no role assignments looks fully healthy to an admin checking the portal but is completely inaccessible to every application that depended on it.

</details>

<details><summary>Playbook 4 — Remediate a fleet-wide certificate auto-rotation gap (CA credential expired)</summary>

```powershell
# 1. Identify every vault/certificate affected by an expired Issuer credential
$vaults = Get-AzKeyVault
$affected = foreach ($v in $vaults) {
    $issuers = Get-AzKeyVaultCertificateIssuer -VaultName $v.VaultName -ErrorAction SilentlyContinue
    foreach ($iss in $issuers) {
        [PSCustomObject]@{ Vault = $v.VaultName; Issuer = $iss.Name; Provider = $iss.IssuerProvider }
    }
}
$affected | Format-Table

# 2. Update the credential on each affected Issuer object
Set-AzKeyVaultCertificateIssuer -VaultName "<vaultName>" -Name "<issuerName>" `
    -IssuerProvider DigiCert -ApiKey "<newApiKey>"

# 3. Re-trigger renewal for any certificate that was stuck mid-failure
$policy = Get-AzKeyVaultCertificatePolicy -VaultName "<vaultName>" -Name "<certName>"
Add-AzKeyVaultCertificate -VaultName "<vaultName>" -Name "<certName>" -CertificatePolicy $policy

# 4. Confirm the operation completes cleanly this time
Get-AzKeyVaultCertificateOperation -VaultName "<vaultName>" -Name "<certName>"
```

**Rollback:** none needed — updating an Issuer credential and re-triggering renewal does not affect the currently-active certificate version until the new one is fully issued. Test the credential update against one non-production vault first if the CA account was shared broadly, since a typo'd API key produces the same "renewal failed" symptom as the original problem.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Azure Key Vault Evidence Collector — gathers diagnostic data for escalation
.NOTES     Run from an admin workstation with Az.KeyVault, Az.Resources modules.
#>

param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$VaultName
)

$report = [System.Collections.Generic.List[string]]::new()
$report.Add("=== Azure Key Vault Evidence Pack - $(Get-Date -Format 'yyyy-MM-dd HH:mm') ===`n")

try {
    $vault = Get-AzKeyVault -VaultName $VaultName -ResourceGroupName $ResourceGroupName
    $report.Add("Vault: $($vault.VaultName)")
    $report.Add("RBAC Authorization: $($vault.EnableRbacAuthorization)")
    $report.Add("Public Network Access: $($vault.PublicNetworkAccess)")
    $report.Add("Network Default Action: $($vault.NetworkAcls.DefaultAction) | Bypass: $($vault.NetworkAcls.Bypass)")
    $report.Add("Soft Delete: $($vault.EnableSoftDelete) | Retention Days: $($vault.SoftDeleteRetentionInDays)")
    $report.Add("Purge Protection: $($vault.EnablePurgeProtection)")
} catch { $report.Add("ERROR reading vault: $_") }

try {
    if ($vault.EnableRbacAuthorization) {
        $roles = Get-AzRoleAssignment -Scope $vault.ResourceId
        $report.Add("`nRBAC Role Assignments: $($roles.Count)")
        foreach ($r in $roles) { $report.Add("  $($r.DisplayName) | $($r.RoleDefinitionName) | Scope: $($r.Scope)") }
    } else {
        $report.Add("`nAccess Policies: $($vault.AccessPolicies.Count)")
        foreach ($p in $vault.AccessPolicies) { $report.Add("  $($p.DisplayName) | Secrets: $($p.PermissionsToSecrets -join ',')") }
    }
} catch { $report.Add("ERROR reading authorization grants: $_") }

try {
    $pe = Get-AzPrivateEndpointConnection -PrivateLinkResourceId $vault.ResourceId -ErrorAction SilentlyContinue
    $report.Add("`nPrivate Endpoint Connections: $($pe.Count)")
    foreach ($p in $pe) { $report.Add("  $($p.Name) | State: $($p.PrivateLinkServiceConnectionState.Status)") }
} catch { $report.Add("ERROR reading private endpoints: $_") }

try {
    $certs = Get-AzKeyVaultCertificate -VaultName $VaultName -ErrorAction SilentlyContinue
    $report.Add("`nCertificates: $($certs.Count)")
    foreach ($c in $certs) {
        $full = Get-AzKeyVaultCertificate -VaultName $VaultName -Name $c.Name
        $daysLeft = ($full.Expires - (Get-Date)).Days
        $report.Add("  $($c.Name) | Expires: $($full.Expires) ($daysLeft days) | Issuer: $($full.Policy.IssuerName)")
    }
} catch { $report.Add("ERROR reading certificates: $_") }

try {
    $diag = Get-AzDiagnosticSetting -ResourceId $vault.ResourceId -ErrorAction SilentlyContinue
    $report.Add("`nDiagnostic Settings Configured: $($diag.Count -gt 0)")
} catch { $report.Add("ERROR reading diagnostic settings: $_") }

try {
    $deletedObjs = @()
    $deletedObjs += Get-AzKeyVaultSecret -VaultName $VaultName -InRemovedState -ErrorAction SilentlyContinue
    $report.Add("`nSoft-deleted secrets pending: $($deletedObjs.Count)")
} catch { $report.Add("ERROR reading soft-deleted objects: $_") }

$outPath = "$env:TEMP\KeyVault-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
$report | Out-File $outPath -Encoding UTF8
Write-Host "Evidence saved to: $outPath" -ForegroundColor Green
$outPath
```

---
## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check authorization model | `(Get-AzKeyVault -VaultName <v> -ResourceGroupName <rg>).EnableRbacAuthorization` |
| List RBAC role assignments on a vault | `Get-AzRoleAssignment -Scope $vault.ResourceId` |
| Grant RBAC data-plane role | `New-AzRoleAssignment -ObjectId <id> -RoleDefinitionName "Key Vault Secrets User" -Scope $vault.ResourceId` |
| List/grant Access Policy (legacy) | `Set-AzKeyVaultAccessPolicy -VaultName <v> -ObjectId <id> -PermissionsToSecrets get,list` |
| Check network ACLs | `$vault.NetworkAcls` |
| Check private endpoint state | `Get-AzPrivateEndpointConnection -PrivateLinkResourceId $vault.ResourceId` |
| Enable trusted-services bypass | `Update-AzKeyVaultNetworkRuleSet -VaultName <v> -Bypass AzureServices` |
| List soft-deleted objects | `Get-AzKeyVaultSecret -VaultName <v> -InRemovedState` |
| Recover a deleted object | `Undo-AzKeyVaultSecretRemoval -VaultName <v> -Name <n>` |
| List/recover a deleted vault | `Get-AzKeyVault -InRemovedState` / `Undo-AzKeyVaultRemoval -VaultName <v> -ResourceGroupName <rg> -Location <region>` |
| Enable purge protection (irreversible) | `Update-AzKeyVault -VaultName <v> -ResourceGroupName <rg> -EnablePurgeProtection $true` |
| Get certificate renewal error | `Get-AzKeyVaultCertificateOperation -VaultName <v> -Name <cert>` |
| Update CA issuer credential | `Set-AzKeyVaultCertificateIssuer -VaultName <v> -Name <issuer> -IssuerProvider DigiCert -ApiKey <key>` |
| Trigger certificate renewal manually | `Add-AzKeyVaultCertificate -VaultName <v> -Name <cert> -CertificatePolicy $policy` |
| Check diagnostic logging config | `Get-AzDiagnosticSetting -ResourceId $vault.ResourceId` |

---
## 🎓 Learning Pointers

- **RBAC and Access Policy are exclusive systems on the same resource, not layers of the same system.** The `enableRbacAuthorization` boolean is a hard switch — understanding this one property resolves a large fraction of real-world Key Vault access tickets faster than any amount of role/policy troubleshooting on the wrong side of the switch. See [Azure RBAC vs. access policies](https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-access-policy).
- **The platform default changed under everyone's feet in 2026 — check IaC templates, don't assume.** New vaults default to RBAC as of API version `2026-02-01`, but existing Bicep/Terraform/ARM templates written earlier may still pin the old default explicitly. A "the vault just started behaving differently" report after a redeploy is worth checking against this change before assuming something else broke. See [Prepare for Key Vault API version 2026-02-01 and later](https://learn.microsoft.com/en-us/azure/key-vault/general/access-control-default).
- **DNS, not the firewall rule, is the actual root cause of most private-endpoint 403s.** Because the error message is identical whether the block is a genuine firewall denial or a DNS-resolution-to-public-IP mistake, always run `Resolve-DnsName` from the actual failing client before touching any network ACL. See [Troubleshoot 403 access denied through a private endpoint](https://learn.microsoft.com/en-us/troubleshoot/azure/private-link/troubleshoot-403-access-denied-private-endpoint).
- **Vault recovery restores data, not access.** Recovering a soft-deleted vault is only the first half of the job — RBAC role assignments and Event Grid subscriptions must be manually recreated afterward, or the recovery will look complete in the portal while every real integration remains broken. This mirrors the same "recovery doesn't restore surrounding config" pattern documented for Azure Backup vault immutability and DFS namespace recovery elsewhere in this repo.
- **Purge protection, once enabled, is permanent — treat it exactly like Purview retention-label regulatory records or Azure Backup immutability lock.** There is no administrative override, ever, for any principal. Get explicit client sign-off before enabling, and document that sign-off, since the eventual need to fully purge a specific secret (e.g. a leaked production credential requiring provable destruction) cannot be satisfied once this is on. See [Key Vault soft-delete overview](https://learn.microsoft.com/en-us/azure/key-vault/general/soft-delete-overview).
- **Auto-rotation is a CA-partnership feature, not a generic Key Vault capability.** Only certificates issued through DigiCert or GlobalSign integrations (or the Microsoft-managed `OneCertV2` issuers) actually auto-renew; self-signed and manually-imported certificates will sit there past expiry with no error and no renewal attempt unless a separate manual/automated process is built for them. See [Understanding autorotation in Azure Key Vault](https://learn.microsoft.com/en-us/azure/key-vault/general/autorotation) and [About Key Vault certificate renewal](https://learn.microsoft.com/en-us/azure/key-vault/certificates/overview-renew-certificate).
