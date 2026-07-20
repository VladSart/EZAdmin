# Azure Firewall (Standard/Premium) — Reference Runbook (Mode A: Deep Dive)
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
- Azure Firewall's own rule/policy authoring: Firewall Policy architecture, rule collection groups/collections/rules, priority evaluation order
- SKU tiers (Basic / Standard / Premium) and the feature ceiling each imposes
- Premium-only capabilities: TLS inspection, IDPS, URL filtering, advanced web categories
- Firewall Manager as the central policy-management plane (base policy + child policy inheritance)
- DNAT/SNAT behavior, forced tunneling, multiple public IPs
- Certificate architecture for TLS inspection (Key Vault integration, CA requirements)

**Out of scope (see cross-references):**
- Azure Firewall as a Virtual WAN secured virtual hub's Routing Intent Next Hop resource, and the traffic-steering/route-table mechanics that get packets to the firewall in the first place — see `VirtualWAN-A.md` / `VirtualWAN-B.md`
- NSG as the separate subnet/NIC-level filtering layer — see `NSG-A.md` / `NSG-B.md`
- General site-to-site/ExpressRoute connectivity bringing traffic into Azure — see `HybridConnectivity-A.md` / `ExpressRoute-A.md`
- Inbound reverse-proxy protection (Web Application Firewall on Application Gateway) — referenced only as the supported pattern for **inbound** TLS inspection, since Azure Firewall itself only terminates outbound and East-West TLS

**Assumes:**
- Contributor or Network Contributor role on the target subscription/resource group for write operations; Reader for diagnostics
- `Az.Network` PowerShell module installed
- For TLS inspection troubleshooting: access to the organization's PKI/Key Vault admin, since the firewall itself only consumes a certificate it doesn't issue

---

## How It Works

<details><summary>Full architecture</summary>

### SKU tiers are an architectural ceiling, not a settings toggle

Azure Firewall ships in three SKUs, and the difference between them is not "more of the same feature" — Standard and Premium add entire capability categories that don't exist at all on the tier below:

| Capability | Basic | Standard | Premium |
|---|---|---|---|
| Stateful L3-L7 firewall, NAT | ✓ | ✓ | ✓ |
| Application FQDN filtering (SNI-based) | ✓ | ✓ | ✓ |
| Network-level FQDN filtering (any TCP/UDP protocol) | — | ✓ | ✓ |
| Threat intelligence | Alert only | Alert + Deny | Alert + Deny |
| DNS proxy / custom DNS | — | ✓ | ✓ |
| Web categories | — | FQDN-only | Full URL |
| TLS inspection | — | — | ✓ |
| IDPS | — | — | ✓ |
| URL filtering (full path) | — | — | ✓ |
| Throughput | 250 Mbps | 30 Gbps | 100 Gbps |

A client asking for "just enable IDPS" on a Standard firewall is asking for something that has no configuration path — it requires a SKU migration (effectively a new firewall deployment or a supported in-place SKU change via Firewall Manager), not a policy edit. Set this expectation early; it is the single most common source of scoped-wrong tickets for this topic.

### Firewall Policy: the separate, inheritable object that actually holds your rules

Since the introduction of Firewall Policy, rules do not live on the Firewall resource itself — they live in a **Firewall Policy** object, which the Firewall resource references. This separation is what enables Firewall Manager's central management story:

```
Firewall Manager (central policy management plane)
    └── Base Policy (parent) — org-wide baseline rules, e.g. deny-known-bad, allow-core-infra
            └── Child Policy A (inherits base) — client/region-specific rules layered on top
            └── Child Policy B (inherits base) — another client/region
                    └── Each child policy is what's actually associated to one or more
                        Firewall resources (a policy can be shared across multiple
                        firewalls, e.g. multiple regional hubs with common baseline rules)
```

**Critical gotcha:** a Firewall Policy has its own SKU tier (`Basic`/`Standard`/`Premium`), assigned at creation and **not changeable in place**. A Premium-SKU Firewall resource with a Standard-SKU policy attached will simply not expose TLS inspection or IDPS configuration — the portal doesn't show these blades, and there's no error, because from the policy object's perspective those features genuinely don't exist for it. This is the single most common "why can't I find the Premium settings" ticket.

### Rule evaluation order: two independent orderings that stack

Evaluation order is frequently misunderstood as "just check the priority number." There are actually **two layers of ordering**, and the type-based one wins first:

1. **Rule type order (fixed, cannot be changed):** NAT rules evaluate first, then Network rules, then Application rules — for every packet, regardless of what priority number any specific rule collection group carries.
2. **Priority order within each type:** Rule Collection Groups are evaluated lowest-priority-number-first; within a group, Rule Collections are evaluated by their own priority; within a collection, rules are evaluated top to bottom. First match wins and evaluation stops for that packet.

This means a DNAT (NAT-type) rule in a Rule Collection Group with priority 500 will still be evaluated and can still act on a packet **before** an Application rule sitting in a Rule Collection Group with priority 100 ever gets a chance — because NAT-type rules as a category always go first. Engineers who only check "which group has the lower priority number" will misdiagnose this class of issue every time.

### TLS inspection: a real proxy, not a passthrough flag

TLS inspection is not Azure Firewall passively reading encrypted traffic — it is a genuine man-in-the-middle proxy architecture. The firewall terminates the client's TLS connection, inspects the plaintext, then originates a **second, separate** TLS connection to the real destination:

```
Client  <--TLS #1 (firewall's on-the-fly cert)-->  Azure Firewall Premium  <--TLS #2 (real cert)-->  Destination
```

The certificate the client sees is generated on-the-fly by the firewall, signed by a customer-provided **Intermediate CA certificate** stored in Key Vault. For this to work without constant browser warnings, every client device must already trust that Intermediate CA (or its Root CA) — meaning TLS inspection has a mandatory PKI/endpoint-management dependency (Intune trusted-root profile, GPO, or equivalent) that has nothing to do with the firewall policy itself. A correctly configured firewall policy with an unpushed Root CA produces the exact same symptom (cert warnings, connection failures) as a misconfigured one — this is why certificate trust must be validated independently of rule logic.

**TLS inspection scope, precisely:**
- **Outbound TLS Inspection** — internal Azure client → Internet (the common case)
- **East-West TLS Inspection** — Azure workload → Azure workload or on-premises, including hub-to-spoke traffic
- **Inbound TLS Inspection is NOT a Firewall capability at all** — Microsoft's supported pattern for inbound HTTPS inspection is Application Gateway with Web Application Firewall, a completely separate product

Four web categories never support TLS termination regardless of configuration, for privacy/compliance reasons baked into the product: **Education, Finance, Government, Health and medicine**. Traffic to sites in these categories passes through un-terminated. If a specific site within one of these categories genuinely needs inspecting, it must be added by exact FQDN to an application rule — the category-level exemption cannot be overridden wholesale.

### IDPS: signature-based, not behavior-based

Premium's IDPS is a signature-matching engine, not an anomaly-detection system — over 67,000 signatures across 50+ categories (malware C2, phishing, trojans, botnets, exploit kits, SCADA protocols), updated with 20-40+ new signatures daily. Each signature independently carries:
- A **Mode**: Disabled, Alert, or Alert and Deny (some signatures ship "Alert Only" by system default and can be overridden)
- A **Severity**: Low/Medium/High
- A **Direction**: Inbound / Outbound / Internal / Internal-Inbound / Internal-Outbound / Any — determined relative to the policy's configured Private IP ranges (default: RFC 1918 ranges)

Signature mode is resolved through a precedence chain: Policy Mode → Parent Policy Mode → user Override → System default. Up to 10,000 individual signature overrides are supported per policy — this is the intended, supported mechanism for tuning false positives. **Never** drop the policy-wide IDPS mode to fix one noisy signature; that removes protection from every other signature simultaneously.

For encrypted (HTTPS) traffic, IDPS depends on TLS inspection being enabled to see anything meaningful — without it, IDPS can only inspect the unencrypted TLS handshake metadata, not payload.

### URL filtering vs. web categories — related but distinct features

- **Web categories** (Standard: FQDN-only; Premium: full URL) classify destinations into buckets like Gambling, Social Media, News — administrators allow/deny by category.
- **URL filtering** (Premium only) extends the FQDN-matching application rules themselves to match on full path, e.g. `www.contoso.com/finance/reports` vs. just `www.contoso.com`.

Both require TLS inspection to be enabled at the **application rule level** (not just the policy level) to work on HTTPS traffic — the policy-level toggle alone is necessary but not sufficient.

</details>

---

## Dependency Stack

```
Subscription / Resource Group
    └── Virtual Network with a dedicated AzureFirewallSubnet (min /26)
            └── Firewall resource deployed (Basic / Standard / Premium SKU — fixed at creation)
                    └── Public IP(s) associated (required for SNAT/DNAT and outbound-only scenarios
                    │   alike, except Forced Tunnel deployments without a public IP)
                    └── Firewall Policy associated (own SKU tier — must be ≥ Firewall SKU,
                        cannot be changed in place once created)
                            └── (Optional) Parent/Base Policy inheritance via Firewall Manager
                            └── Rule Collection Groups (each with a Priority)
                                    └── Rule Collections (NAT / Network / Application types;
                                    │   NAT always evaluates before Network, before Application,
                                    │   regardless of group/collection priority number)
                                            └── Individual rules, evaluated top-to-bottom,
                                                first match wins
                            └── (Premium only) TLS Inspection settings
                                    └── Key Vault holding the Intermediate CA cert (PFX,
                                    │   RSA ≥4096-bit, KeyUsage=KeyCertSign, valid ≥1yr)
                                    └── User-assigned Managed Identity with Key Vault
                                    │   Secret Get/List access policy (RBAC not supported here)
                                    └── Client OS/browser trust of that Root/Intermediate CA
                                        (Intune/GPO trusted-root deployment — external to Firewall)
                            └── (Premium only) IDPS mode + Private IP ranges + signature overrides
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| "Premium" blades (TLS inspection, IDPS) missing from the portal despite a Premium firewall | Firewall Policy is Standard/Basic SKU, not matching the Firewall's SKU | Compare `Get-AzFirewall` SKU vs. `Get-AzFirewallPolicy` SKU |
| Allow rule present but traffic still denied | A NAT-type rule elsewhere is matching first, or a higher-priority-numbered group's deny is being hit before rule-type ordering is accounted for | Walk both orderings: rule type first, then Rule Collection Group/Collection priority |
| HTTPS site fails to load / browser cert warning under TLS inspection | Root CA not trusted on the client device, or cert expired in Key Vault | Confirm `TransportSecurity.CertificateAuthority` and client trusted-root deployment status |
| TLS inspection enabled at policy but a specific rule's HTTPS traffic isn't being inspected | TLS inspection toggle is policy-level only — must also be enabled per Application Rule | Check the individual rule's TLS inspection setting, not just the policy default |
| One named site in Education/Finance/Government/Health category won't inspect | By-design category exemption — these four categories never support TLS termination | Add the specific FQDN as its own application rule if inspection is genuinely required |
| Legitimate traffic blocked with an IDPS-related deny in logs | A signature is a false positive for this environment | Find the Signature ID in Network Rules logs, apply a per-signature override — don't change policy-wide mode |
| DNAT rule configured but inbound connection still fails | Missing matching Network rule allowing the translated destination, or DNAT bound to the wrong Public IP configuration | Cross-check `IpConfigurations` and confirm a Network rule permits the post-translation flow |
| Web category filtering behaves differently than expected for the "same" site | Standard SKU categorizes by FQDN only; Premium by full URL — a URL with multiple path-based categories can be treated differently per SKU | Confirm SKU tier and test with `Web Category Check` (Premium) |
| Firewall deployed but a client asks "why can't we just get ExpressRoute/IDPS/TLS through the portal" | SKU or Virtual WAN type (Basic) ceiling — not a firewall configuration gap at all | Confirm both Firewall SKU and, if in a vWAN hub, the vWAN type per `VirtualWAN-A.md` |
| Rule change made but old behavior persists briefly | Firewall Policy changes propagate asynchronously to the underlying instances; a large policy can take several minutes | Re-check after 5-10 minutes before assuming the change failed |

---

## Validation Steps

**Step 1 — Confirm the Firewall and Policy SKU tiers match**
```powershell
$fw = Get-AzFirewall -ResourceGroupName '<rg>' -Name '<firewallName>'
$policy = Get-AzFirewallPolicy -ResourceGroupName '<rg>' -Name '<policyName>'
[PSCustomObject]@{ FirewallSku = $fw.Sku.Tier; PolicySku = $policy.Sku; ProvisioningState = $fw.ProvisioningState }
```
*Good:* `FirewallSku` and `PolicySku` are identical, `ProvisioningState: Succeeded`.
*Bad:* Mismatch — Premium features will be unavailable regardless of firewall compute tier.

---

**Step 2 — Enumerate rule collection groups in true evaluation order**
```powershell
Get-AzFirewallPolicyRuleCollectionGroup -ResourceGroupName '<rg>' -PolicyName '<policyName>' |
    Sort-Object Priority |
    Select-Object Name, Priority
```
*Good:* The group containing the expected-to-match rule sits at a lower priority number than any conflicting rule of the **same type**.
*Bad:* Remember to separately check rule TYPE order (NAT → Network → Application) — a lower-priority-numbered Application rule group does not override a higher-priority-numbered NAT rule group.

---

**Step 3 — Confirm TLS inspection configuration end to end**
```powershell
$policy = Get-AzFirewallPolicy -ResourceGroupName '<rg>' -Name '<policyName>'
$policy.TransportSecurity
```
*Good:* `CertificateAuthority` points to a Key Vault secret; certificate not expired; the specific application rule in question also has TLS inspection enabled (not just the policy default).
*Bad:* `TransportSecurity` is `$null` (not enabled at all), or populated but the client device has never received the Root CA via Intune/GPO.

---

**Step 4 — Confirm IDPS mode and check for signature-level overrides**
```powershell
$policy.IntrusionDetection.Mode
$policy.IntrusionDetection.Configuration.SignatureOverrides |
    Select-Object Id, Mode
```
*Good:* Mode matches intended posture (`Alert` or `Deny`); any overrides present are deliberate, documented tuning.
*Bad:* Mode is `Off` when the client believes IDPS is active, or an override silently disabled a signature nobody remembers disabling.

---

**Step 5 — Confirm DNAT rule and its Network-rule counterpart together**
```powershell
$group = Get-AzFirewallPolicyRuleCollectionGroup -ResourceGroupName '<rg>' -PolicyName '<policyName>' -Name '<groupName>'
$group.Properties.RuleCollection | Where-Object RuleCollectionType -eq 'FirewallPolicyNatRuleCollection'
$group.Properties.RuleCollection | Where-Object RuleCollectionType -eq 'FirewallPolicyFilterRuleCollection'
```
*Good:* A DNAT rule's translated destination/port is also permitted by a Network rule (or the collection group's implicit posture allows it).
*Bad:* DNAT rule exists in isolation with no corresponding allow for the post-translation flow.

---

**Step 6 — Confirm Public IP / IpConfiguration binding for DNAT**
```powershell
(Get-AzFirewall -ResourceGroupName '<rg>' -Name '<firewallName>').IpConfigurations |
    Select-Object Name, PublicIpAddress
```
*Good:* The Public IP the client is sending inbound traffic to matches an `IpConfiguration` actually present on the firewall.
*Bad:* Traffic arriving at a Public IP not associated with any `IpConfiguration` — silently dropped, no log entry to explain why.

---

**Step 7 — Confirm deployment model before assuming standalone-hub behavior**
```powershell
(Get-AzFirewall -ResourceGroupName '<rg>' -Name '<firewallName>').HubIPAddresses
```
*Good:* `$null`/absent for a standalone hub-VNet deployment; populated for a Virtual WAN secured-hub deployment (managed via Firewall Manager, associated through Routing Intent — see `VirtualWAN-A.md`).
*Bad:* Assuming standalone-hub troubleshooting steps apply to a vWAN-hosted firewall, or vice versa — the routing layer above the firewall is architecturally different between the two models.

---

## Troubleshooting Steps (by phase)

### Phase 1: Feature Appears Unavailable
1. Run Step 1 — confirm Firewall and Policy SKU tiers match and are at the tier the feature requires
2. If mismatched, this is a policy recreation (Fix 2), not a settings change
3. If both SKUs are correct and the feature is still missing, confirm `ProvisioningState: Succeeded` — a stuck deployment can mask feature availability

### Phase 2: Traffic Allowed/Denied Unexpectedly
1. Run Step 2 — enumerate by BOTH orderings: rule type (NAT/Network/Application, fixed) and priority number within type
2. Identify the actual first-match rule for the specific 5-tuple in question
3. Confirm whether the match is in the expected rule collection, or an earlier-evaluated one the client forgot about
4. Adjust priority or rule scope only after the true first-match rule is confirmed — don't guess

### Phase 3: TLS Inspection / Certificate Issues
1. Run Step 3 — separate "is TLS inspection configured" from "is the client trusting the cert"
2. If policy-level config is correct but client-side trust is the gap, this becomes an endpoint-management ticket (Intune/GPO trusted-root deployment), not a firewall ticket
3. Check the four TLS-termination-exempt categories before assuming a bug for Education/Finance/Government/Health sites
4. Confirm TLS inspection is enabled at the specific application rule, not just the policy default

### Phase 4: IDPS False Positives or Missed Detections
1. Run Step 4 — confirm policy mode and existing overrides first
2. Pull the exact Signature ID from Network Rules logs / Firewall Workbook for the flow in question
3. Apply a signature-level override — never adjust the policy-wide mode for a single false positive
4. For missed detections, confirm the traffic was even eligible for inspection (HTTPS traffic requires TLS inspection to be active for IDPS to see payload)

### Phase 5: NAT/DNAT Issues
1. Run Step 5 and Step 6 together — DNAT is a two-part configuration (the NAT rule itself, plus IP binding and often a companion Network rule)
2. Confirm the client is sending traffic to the exact Public IP bound to an `IpConfiguration` on the firewall
3. Trace via Network Rules logs — a silently-dropped DNAT due to IP mismatch produces no denial log entry to explain itself, which is itself a diagnostic signal

---

## Remediation Playbooks

<details><summary>Playbook 1 — Greenfield: stand up a new Firewall Policy hierarchy via Firewall Manager</summary>

Use when onboarding a new client/region that should inherit organization-wide baseline rules.

1. Create (or identify the existing) Base Policy in Firewall Manager containing org-wide rules (threat-intel posture, deny-known-bad, allow-core-infra).
2. Create a Child Policy for the new client/region, setting `BasePolicy` to the parent's resource ID.
3. Add client/region-specific Rule Collection Groups to the child policy — these layer additively on top of the base, they don't replace it.
4. Deploy the Firewall resource (choosing SKU up front — Premium if TLS inspection/IDPS/URL filtering are contracted requirements; this cannot be upgraded in place later without a policy recreation).
5. Associate the child policy to the firewall.
6. If Premium: complete the Key Vault + Managed Identity + CA certificate chain (see `premium-certificates` reference) **and** confirm the client's endpoint-management team has a plan to push the Root CA — this is frequently the longest-lead-time step, coordinate it early.

</details>

---

<details><summary>Playbook 2 — Retrofit: add TLS inspection to an existing Premium firewall with FQDN-only rules today</summary>

Use when a client already has a working Premium firewall on FQDN/application filtering and wants to add TLS inspection and IDPS without disrupting existing traffic.

1. Confirm current policy SKU is genuinely Premium (Step 1) — if not, this is Playbook 3 first.
2. Provision or confirm an Intermediate CA certificate meeting all requirements (PFX, RSA ≥4096, `KeyCertSign`, `BasicConstraints:CA=TRUE`, `PathLength≥1`, valid ≥1 year), stored as a Key Vault **Secret** (not just a Certificate object — the firewall reads via the Secrets interface regardless of import method).
3. Create or reuse a user-assigned Managed Identity; grant it Key Vault **Get/List** under Secret Permissions (Access Policy model — Azure RBAC is not supported for this integration).
4. Enable TLS inspection at the policy level, selecting the Key Vault certificate and Managed Identity.
5. Enable TLS inspection on a small, low-risk pilot set of Application rules first — not the entire rule base at once.
6. Coordinate Root CA distribution to client devices via Intune/GPO **before** wide rollout; a firewall correctly configured for TLS inspection with an untrusted client Root CA breaks HTTPS for every user hitting an inspected rule.
7. Expand TLS inspection to additional rules incrementally, monitoring for cert-trust support tickets after each wave.
8. Enable IDPS in `Alert`-only mode initially; review the Network Rules log for a baseline period before moving to `Alert and Deny` to avoid an immediate flood of unreviewed blocks.

</details>

---

<details><summary>Playbook 3 — SKU migration: Standard to Premium</summary>

Use when a client contractually requires TLS inspection, IDPS, or full-URL filtering and is currently on Standard.

1. Confirm via `Get-AzFirewall`/`Get-AzFirewallPolicy` that both the firewall and policy are genuinely Standard (not just appearing so due to an unrelated portal issue).
2. There is no supported in-place SKU upgrade cmdlet for the Firewall Policy object — plan to create a new Premium-SKU policy and migrate Rule Collection Groups into it (export existing groups first for reference/rollback).
3. For the Firewall resource itself, follow Microsoft's documented SKU change process via Firewall Manager (may involve redeployment depending on current version) — budget a maintenance window; this is not a zero-downtime settings change.
4. Once on Premium compute + Premium policy, proceed with Playbook 2 to layer on TLS inspection/IDPS.

**Rollback:** Retain the original Standard policy object (don't delete it) until the Premium migration is validated in production — re-pointing the firewall's `FirewallPolicy` property back is the fastest rollback path if issues surface.

</details>

---

<details><summary>Playbook 4 — Fleet-wide policy hygiene audit across clients</summary>

Use during a periodic MSP health-check pass across multiple client firewalls.

1. Run `Scripts/Get-AzureFirewallPolicyAudit.ps1` across all subscriptions to surface SKU mismatches, priority-ordering red flags, TLS inspection/cert expiry issues, and IDPS posture in one pass.
2. Cross-reference any Premium firewalls with Standard-tier policies (the most common silent-gap finding) and schedule policy recreation.
3. Flag any TLS inspection certificates approaching their 1-year validity ceiling for proactive renewal before they lapse and break HTTPS tenant-wide.
4. Document findings per client in the Evidence Pack format below for the account record.

</details>

---

## Evidence Pack

```powershell
<#
  Azure Firewall Evidence Collector
  Run before escalating to Microsoft Support or a client stakeholder.
#>
$rg = Read-Host "Resource Group"
$fwName = Read-Host "Firewall Name"
$outPath = "$env:TEMP\AzureFirewall-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
$sb = [System.Text.StringBuilder]::new()

$fw = Get-AzFirewall -ResourceGroupName $rg -Name $fwName
$policyId = $fw.FirewallPolicy.Id
$policy = if ($policyId) { Get-AzResource -ResourceId $policyId | ForEach-Object { Get-AzFirewallPolicy -ResourceGroupName $_.ResourceGroupName -Name $_.Name } } else { $null }

$null = $sb.AppendLine("=== AZURE FIREWALL EVIDENCE PACK ===")
$null = $sb.AppendLine("Firewall: $fwName | RG: $rg")
$null = $sb.AppendLine("Collected: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("--- Firewall ---")
$null = $sb.AppendLine("SKU: $($fw.Sku.Tier) | ProvisioningState: $($fw.ProvisioningState) | ThreatIntelMode: $($fw.ThreatIntelMode)")
$null = $sb.AppendLine("HubIPAddresses (populated = Virtual WAN secured hub): $($fw.HubIPAddresses -ne $null)")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("--- Policy ---")
if ($policy) {
    $null = $sb.AppendLine("Name: $($policy.Name) | SKU: $($policy.Sku)")
    $null = $sb.AppendLine("TLS Inspection Configured: $($policy.TransportSecurity -ne $null)")
    $null = $sb.AppendLine("IDPS Mode: $($policy.IntrusionDetection.Mode)")
} else {
    $null = $sb.AppendLine("No policy resolved — check FirewallPolicy association.")
}
$null = $sb.AppendLine("")
$null = $sb.AppendLine("--- Rule Collection Groups (priority order) ---")
Get-AzFirewallPolicyRuleCollectionGroup -ResourceGroupName $rg -PolicyName $policy.Name -ErrorAction SilentlyContinue |
    Sort-Object Priority | ForEach-Object {
        $null = $sb.AppendLine("  [$($_.Priority)] $($_.Name)")
    }

$sb.ToString() | Out-File $outPath -Encoding UTF8
Write-Host "Evidence written to: $outPath" -ForegroundColor Green
notepad $outPath
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Get firewall SKU/state | `Get-AzFirewall -ResourceGroupName <rg> -Name <fw>` |
| Get policy SKU/TLS/IDPS config | `Get-AzFirewallPolicy -ResourceGroupName <rg> -Name <policy>` |
| List rule collection groups by priority | `Get-AzFirewallPolicyRuleCollectionGroup -ResourceGroupName <rg> -PolicyName <policy> \| Sort-Object Priority` |
| Get one rule collection group's full rule content | `Get-AzFirewallPolicyRuleCollectionGroup -ResourceGroupName <rg> -PolicyName <policy> -Name <group>` |
| Check TLS inspection cert/identity config | `(Get-AzFirewallPolicy -ResourceGroupName <rg> -Name <policy>).TransportSecurity` |
| Check IDPS mode | `(Get-AzFirewallPolicy -ResourceGroupName <rg> -Name <policy>).IntrusionDetection.Mode` |
| List IDPS signature overrides | `(Get-AzFirewallPolicy -ResourceGroupName <rg> -Name <policy>).IntrusionDetection.Configuration.SignatureOverrides` |
| Add an IDPS signature override | `Update-AzFirewallPolicyIntrusionDetection -InputObject <policy> -SignatureId <id> -Mode Alert` |
| List firewall IP configurations (for DNAT binding) | `(Get-AzFirewall -ResourceGroupName <rg> -Name <fw>).IpConfigurations` |
| Create a new Premium policy | `New-AzFirewallPolicy -ResourceGroupName <rg> -Name <name> -Location <region> -SkuTier Premium` |
| Re-point firewall to a different policy | `$fw.FirewallPolicy = $newPolicy.Id; Set-AzFirewall -AzureFirewall $fw` |
| Check if firewall is Virtual WAN secured-hub-hosted | `(Get-AzFirewall -ResourceGroupName <rg> -Name <fw>).HubIPAddresses` |
| Fleet-wide policy hygiene audit | `Scripts/Get-AzureFirewallPolicyAudit.ps1` |

---

## 🎓 Learning Pointers

- **A Firewall Policy's SKU tier is fixed at creation and cannot be upgraded in place — and it is a separate ceiling from the Firewall resource's own SKU.** A Premium firewall with a Standard-tier policy is a common half-finished-migration state that produces no error, just quietly missing feature blades. Always check both when a Premium feature "isn't there." [MS Docs: Azure Firewall features by SKU](https://learn.microsoft.com/en-us/azure/firewall/features-by-sku)

- **Rule-type evaluation order (NAT → Network → Application) is fixed and independent of Rule Collection Group priority numbers.** Engineers who only sort by priority number will misdiagnose why a DNAT rule "jumped the queue" ahead of an Application rule in a numerically higher-priority group — it isn't a bug, it's how the engine is designed to evaluate. [MS Docs: Azure Firewall rule processing logic](https://learn.microsoft.com/en-us/azure/firewall/rule-processing)

- **TLS inspection is a genuine two-hop proxy, not a passive flag — and its biggest real-world failure mode lives entirely outside the firewall's own configuration**, in whether client devices trust the Root/Intermediate CA. Budget the Intune/GPO trusted-root rollout as its own workstream, not an afterthought, when planning a TLS inspection deployment. [MS Docs: Azure Firewall Premium certificates](https://learn.microsoft.com/en-us/azure/firewall/premium-certificates)

- **Four web categories (Education, Finance, Government, Health and medicine) never support TLS termination, by design, for privacy/compliance reasons — this cannot be overridden at the category level.** A specific FQDN within one of these categories can still be individually added to an application rule if inspection of that one site is genuinely required. [MS Docs: Azure Firewall Premium features — Web categories](https://learn.microsoft.com/en-us/azure/firewall/premium-features#web-categories)

- **IDPS false positives are meant to be tuned per-signature (up to 10,000 overrides per policy), never by dropping the policy-wide mode.** A policy-wide downgrade from `Deny` to `Alert` to silence one noisy signature removes enforcement from all 67,000+ signatures simultaneously — treat this the same as you would treat disabling an entire antivirus product to fix one false positive. [MS Docs: Azure Firewall Premium IDPS](https://learn.microsoft.com/en-us/azure/firewall/premium-features#idps)

- **This runbook deliberately stops at the firewall's own rule/policy authoring.** The question of how traffic actually reaches the firewall — Routing Intent, Next Hop, secured virtual hub association — is a distinct architectural layer covered in `VirtualWAN-A.md`/`VirtualWAN-B.md`; don't debug rule logic on a firewall that traffic never reached in the first place.
