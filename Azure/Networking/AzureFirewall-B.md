# Azure Firewall (Standard/Premium) — Hotfix Runbook (Mode B: Ops)
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

Run these first to locate the failure layer. This runbook covers the Firewall resource's **own rule/policy authoring** — if the ticket is "traffic isn't reaching the firewall at all" inside a Virtual WAN secured hub, start at `VirtualWAN-B.md` Triage instead and only come here once Routing Intent/Next Hop is confirmed correct.

```powershell
# 1. Confirm the Firewall resource and its SKU tier
Get-AzFirewall -ResourceGroupName '<rg>' -Name '<firewallName>' |
    Select-Object Name, Sku, ProvisioningState, ThreatIntelMode

# 2. Confirm the Firewall Policy attached and its SKU matches the Firewall SKU
Get-AzFirewallPolicy -ResourceGroupName '<rg>' -Name '<policyName>' |
    Select-Object Name, Sku, ThreatIntelMode, @{N='TLSInspection';E={$_.TransportSecurity -ne $null}}

# 3. Confirm rule collection groups and their priority order (lower number evaluates first)
Get-AzFirewallPolicyRuleCollectionGroup -ResourceGroupName '<rg>' -PolicyName '<policyName>' |
    Select-Object Name, Priority

# 4. If TLS inspection is expected to be active, confirm it's actually enabled on the policy
(Get-AzFirewallPolicy -ResourceGroupName '<rg>' -Name '<policyName>').TransportSecurity

# 5. If IDPS is expected to block/alert, confirm the policy-level mode
(Get-AzFirewallPolicy -ResourceGroupName '<rg>' -Name '<policyName>').IntrusionDetection.Mode
```

| Result | Action |
|--------|--------|
| Firewall SKU is `Basic`/`Standard` but client expects TLS inspection, IDPS, or URL filtering | → Fix 1: SKU doesn't support the feature — plan a Premium migration, not a config change |
| Firewall Policy SKU doesn't match Firewall SKU (e.g., Standard policy on a Premium firewall) | → Fix 2: Policy SKU ceiling silently caps available features |
| Traffic denied despite an allow rule present | → Fix 3: Priority/rule-type evaluation order — a higher-priority deny elsewhere wins |
| TLS inspection enabled but HTTPS sites fail to load / cert warnings | → Fix 4: Root CA not trusted on the client, or category exempt from termination |
| IDPS blocking legitimate traffic | → Fix 5: Override the specific signature ID, don't disable IDPS wholesale |
| DNAT rule doesn't route inbound traffic | → Fix 6: SNAT/DNAT rule collection priority or missing matching Network rule for return traffic |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Firewall SKU chosen (Basic / Standard / Premium)
    └── Firewall Policy SKU must be ≥ Firewall SKU
    │       (a Standard policy on a Premium firewall silently caps you to Standard features)
    └── Policy associated to the Firewall resource (directly, or via Firewall Manager /
    │   secured virtual hub — see VirtualWAN-A.md)
    └── Rule Collection Groups (containers, each with a Priority)
            └── Rule Collections within each group (also individually Prioritized)
                    └── Individual rules (NAT / Network / Application) evaluated in
                        Priority order, LOWEST number first, first match wins
                            └── (Premium only) TLS inspection must be Enabled on the policy
                            │   AND a trusted CA certificate configured in Key Vault
                            │   AND that Root/Intermediate CA trusted by the CLIENT OS
                            │       before URL filtering or HTTPS-aware web categories work
                            └── (Premium only) IDPS mode (Off / Alert / Deny) set at the
                                policy or rule-collection-group level — signature-level
                                overrides layer on top of this
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm SKU ceiling first.** `Get-AzFirewall` and `Get-AzFirewallPolicy` — a Standard SKU firewall or policy has no TLS inspection, no IDPS, and only FQDN-level (not full URL) web categories. No amount of policy configuration unlocks these on Standard/Basic.
   *Good:* Both Firewall and Policy report `Premium` when the client expects Premium-only features. *Bad:* Either reports `Standard`/`Basic`.

2. **Confirm policy SKU matches firewall SKU.** A Premium Firewall with a Standard-SKU policy attached is a common half-finished-upgrade state — the firewall's compute is Premium but the policy object simply has no TLS inspection/IDPS blades available.
   ```powershell
   $fw = Get-AzFirewall -ResourceGroupName '<rg>' -Name '<firewallName>'
   $policy = Get-AzFirewallPolicy -ResourceGroupName '<rg>' -Name '<policyName>'
   "Firewall SKU: $($fw.Sku.Tier) | Policy SKU: $($policy.Sku)"
   ```
   *Good:* Both report the same tier. *Bad:* Mismatch — the policy needs re-creation at Premium (SKU tier cannot be changed on an existing policy).

3. **Walk rule collection group and rule collection priority in evaluation order.** Azure Firewall evaluates **all Rule Collection Groups by priority (lowest first)**, then within each group, all Rule Collections by their own priority, and within each collection, rules top to bottom. NAT rules are evaluated first overall (they can redirect traffic before Network/Application rules ever see it), then Network rules, then Application rules — and once any rule matches, evaluation stops.
   ```powershell
   Get-AzFirewallPolicyRuleCollectionGroup -ResourceGroupName '<rg>' -PolicyName '<policyName>' |
       Sort-Object Priority | Select-Object Name, Priority
   ```
   *Good:* The allow rule the client expects to match sits in a lower-priority-number group/collection than any conflicting deny. *Bad:* A broad deny in a lower-numbered (higher-priority) group shadows the intended allow.

4. **For TLS inspection issues, confirm the certificate chain independently of the rule logic.** TLS inspection failing looks identical to a blocked-by-policy symptom from the end user's perspective (connection refused / cert error) but has a completely different root cause.
   ```powershell
   (Get-AzFirewallPolicy -ResourceGroupName '<rg>' -Name '<policyName>').TransportSecurity.CertificateAuthority
   ```
   *Good:* A Key Vault secret ID is present and the certificate has not expired. *Bad:* Empty (TLS inspection not actually enabled despite portal toggle appearing on), or the Root CA was never pushed to client devices (Intune/GPO trusted-root deployment).

5. **For IDPS false positives, find the exact signature ID before touching the policy mode.** Never disable IDPS at the policy level to fix one false positive — it removes protection for all 67,000+ signatures.
   Query the Network Rules log in Log Analytics/Firewall Workbook for the blocked flow, note the `Signature ID`, then override just that signature's mode.

6. **For DNAT issues, confirm the matching implicit Network rule.** Azure Firewall DNAT rules require traffic to also be allowed by a Network rule for the *translated* destination — a DNAT rule alone does not implicitly allow the post-translation traffic unless `Network Rules FQDN filtering is applied to inbound traffic` implicit-allow behavior applies (varies by rule collection group Action).
   ```powershell
   Get-AzFirewallPolicyRuleCollectionGroup -ResourceGroupName '<rg>' -PolicyName '<policyName>' -Name '<groupName>' |
       Select-Object -ExpandProperty Properties |
       Select-Object -ExpandProperty RuleCollection |
       Where-Object { $_.RuleCollectionType -eq 'FirewallPolicyNatRuleCollection' }
   ```

---
## Common Fix Paths

<details><summary>Fix 1 — SKU doesn't support the requested feature (plan Premium migration)</summary>

Basic and Standard SKUs cannot be configured into supporting TLS inspection, IDPS, URL filtering, or full-URL web categories — these are architectural ceilings, not settings.

```powershell
# Confirm current SKU before promising a feature
Get-AzFirewall -ResourceGroupName '<rg>' -Name '<firewallName>' | Select-Object Name, Sku

# SKU change requires redeployment via Firewall Manager or Az.Network's change-SKU path —
# there is no in-place "upgrade" cmdlet for Basic/Standard -> Premium; plan a maintenance window.
```

Set client expectations: a SKU migration is a firewall redeployment, not a policy edit — budget downtime or a parallel-firewall cutover.

**Rollback:** N/A — this is a planning/expectations fix, not a live change.

</details>

---

<details><summary>Fix 2 — Firewall Policy SKU mismatch (policy needs Premium recreation)</summary>

```powershell
# Confirm the mismatch
$fw = Get-AzFirewall -ResourceGroupName '<rg>' -Name '<firewallName>'
$policy = Get-AzFirewallPolicy -ResourceGroupName '<rg>' -Name '<policyName>'
"Firewall: $($fw.Sku.Tier) | Policy: $($policy.Sku)"

# Policy SKU cannot be changed in place — create a new Premium policy, migrate rule
# collection groups, then re-associate to the firewall
$newPolicy = New-AzFirewallPolicy -ResourceGroupName '<rg>' -Name '<policyName>-premium' `
    -Location '<region>' -SkuTier Premium

# Re-point the firewall at the new policy
$fw.FirewallPolicy = $newPolicy.Id
Set-AzFirewall -AzureFirewall $fw
```

**Rollback:** Re-point `FirewallPolicy` back to the original policy ID; the old policy object is not deleted by this process.

</details>

---

<details><summary>Fix 3 — Priority/evaluation-order conflict shadowing an allow rule</summary>

```powershell
# List every rule collection group in priority order to find what evaluates before the
# intended allow rule's group
Get-AzFirewallPolicyRuleCollectionGroup -ResourceGroupName '<rg>' -PolicyName '<policyName>' |
    Sort-Object Priority | Select-Object Name, Priority

# Once the conflicting (usually broader deny) collection group is identified, either:
#  (a) move the allow rule to a lower-numbered (higher-priority) group, or
#  (b) narrow the conflicting deny's scope so it no longer shadows the allow
```

Remember NAT rules are evaluated before Network rules, which are evaluated before Application rules, **regardless of the rule collection group's own priority number** — a DNAT rule can redirect traffic before an Application rule ever gets a chance to see it.

**Rollback:** Restore original priority values / rule scope from the policy's version history in the portal, or from a pre-change export.

</details>

---

<details><summary>Fix 4 — TLS inspection certificate/trust issue</summary>

```powershell
# Confirm TLS inspection is genuinely enabled and pointed at a valid, non-expired cert
(Get-AzFirewallPolicy -ResourceGroupName '<rg>' -Name '<policyName>').TransportSecurity

# Common root causes, in order of frequency:
#  1. Root/Intermediate CA never deployed to client devices (push via Intune trusted
#     root profile or GPO — see Intune/Troubleshooting/ or Group Policy equivalent)
#  2. Certificate in Key Vault expired (must be valid one year forward at time of import)
#  3. TLS inspection not enabled at the APPLICATION RULE level even though enabled at
#     the policy level — it must be turned on for the specific rule, not just the policy
#  4. Destination falls in a category that does NOT support TLS termination by design:
#     Education, Finance, Government, Health and medicine — these pass through
#     un-terminated regardless of policy settings; add specific FQDNs to an application
#     rule if a named site in one of these categories genuinely needs inspecting
```

**Rollback:** Disable TLS inspection at the policy level (`TransportSecurity = $null`) as an emergency bypass if certificate issues are blocking business-critical traffic — this drops HTTPS visibility/URL-filtering fidelity back to FQDN-only until resolved.

</details>

---

<details><summary>Fix 5 — IDPS false positive (signature-level override, not policy-wide disable)</summary>

```powershell
# Find the exact Signature ID from the Network Rules log (Firewall Workbook or Log
# Analytics query) for the blocked flow, then override just that signature

$policy = Get-AzFirewallPolicy -ResourceGroupName '<rg>' -Name '<policyName>'

# Add a signature override (mode: Alert, Deny, or Off for that specific signature only)
Update-AzFirewallPolicyIntrusionDetection -InputObject $policy `
    -SignatureId '<signatureId>' -Mode Alert

Set-AzFirewallPolicy -InputObject $policy
```

Up to 10,000 individual signature overrides are supported per policy — this is the intended tool for false-positive tuning. Never drop the policy-wide IDPS mode from `Deny` to `Alert` or `Off` to fix one noisy signature.

**Rollback:** Remove the specific signature override to restore default (usually `Alert`) behavior for that signature.

</details>

---

<details><summary>Fix 6 — DNAT rule not routing inbound traffic</summary>

```powershell
# Confirm the DNAT rule collection AND that a corresponding Network rule allows the
# translated destination/port — DNAT alone does not guarantee the post-translation hop
Get-AzFirewallPolicyRuleCollectionGroup -ResourceGroupName '<rg>' -PolicyName '<policyName>' |
    Select-Object -ExpandProperty Properties |
    Select-Object -ExpandProperty RuleCollection |
    Format-Table RuleCollectionType, Name, Priority -AutoSize

# Also confirm the firewall has a Public IP configured on the correct IpConfiguration —
# DNAT rules are bound to a specific public IP, not "the firewall" generically
Get-AzFirewall -ResourceGroupName '<rg>' -Name '<firewallName>' |
    Select-Object -ExpandProperty IpConfigurations
```

**Rollback:** N/A — diagnostic/read path; fixes are additive rule changes.

</details>

---
## Escalation Evidence

```
=== AZURE FIREWALL ESCALATION TEMPLATE ===
Firewall name / RG / Subscription: ___________
Firewall SKU (Basic/Standard/Premium): ___________
Firewall Policy name / SKU: ___________
Deployment model (standalone hub VNet / Virtual WAN secured hub): ___________
Symptom (deny expected to allow / allow expected to deny / TLS/cert error / IDPS false positive / DNAT not routing): ___________
Rule Collection Group + Collection + rule name believed responsible: ___________
Priority values of the group/collection in question: ___________
TLS inspection enabled at policy level? At rule level?: ___________
IDPS mode (Off/Alert/Deny) and Signature ID if applicable: ___________
Output of Get-AzFirewallPolicyRuleCollectionGroup (attach): ___________
Firewall Workbook / Network Rules log excerpt for the specific flow (attach): ___________
Client-impact window (start time / ongoing?): ___________
```

---
## 🎓 Learning Pointers

- **A Firewall Policy has its own SKU tier, independent of the Firewall resource's SKU, and it cannot be upgraded in place.** A Premium firewall with a Standard-tier policy silently loses access to TLS inspection and IDPS in the portal with no obvious error — always check both SKUs when a "Premium feature" appears to be missing. [MS Docs: Azure Firewall features by SKU](https://learn.microsoft.com/en-us/azure/firewall/features-by-sku)

- **Rule type has its own evaluation order that overrides rule collection group priority.** NAT rules are always evaluated before Network rules, which are always evaluated before Application rules — a DNAT rule can redirect a packet before any Application rule in a lower-priority-numbered group ever sees it. Don't debug "my Application rule isn't matching" without first ruling out an earlier-evaluated NAT or Network rule. [MS Docs: Azure Firewall rule processing logic](https://learn.microsoft.com/en-us/azure/firewall/rule-processing)

- **TLS inspection failures and policy-block failures look identical to the end user** (connection refused, certificate warning, page won't load) but have completely different root causes and fixes — always separate "is TLS inspection even configured correctly" from "is a rule blocking this" before troubleshooting further. [MS Docs: Azure Firewall Premium certificates](https://learn.microsoft.com/en-us/azure/firewall/premium-certificates)

- **Four web categories never support TLS termination by design, regardless of policy configuration: Education, Finance, Government, and Health and medicine.** If a client reports inspection isn't happening for a specific site in one of these categories, that's expected behavior, not a bug — add the specific FQDN to an application rule if that individual site genuinely needs inspecting. [MS Docs: Azure Firewall Premium features](https://learn.microsoft.com/en-us/azure/firewall/premium-features)

- **IDPS false positives should always be fixed with a per-signature override, never a policy-wide mode downgrade.** Up to 10,000 individual signature overrides are supported — disabling IDPS wholesale to silence one noisy rule removes protection from all 67,000+ signatures across every threat category. [MS Docs: Azure Firewall Premium IDPS](https://learn.microsoft.com/en-us/azure/firewall/premium-features#idps)

- **This runbook is deliberately scoped to Firewall's own rule/policy authoring.** If the ticket is actually "traffic isn't reaching the firewall in our Virtual WAN hub," that's a Routing Intent/Next-Hop problem — start at `VirtualWAN-B.md` instead and only return here once the traffic is confirmed to be arriving at the firewall.
