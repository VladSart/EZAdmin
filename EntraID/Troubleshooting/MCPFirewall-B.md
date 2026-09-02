# Entra Global Secure Access — MCP Firewall (Preview) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## ⚠ A note on tooling before you start

The MCP firewall is a **Preview** capability (as of September 2026) and Microsoft's own configuration guide is entirely **portal-driven** — there is no documented typed Graph PowerShell cmdlet set for creating or editing MCP policies yet. Don't guess at `Get-MgBeta*` cmdlet names for this specific feature; they may not exist in the module you have installed. Use `Invoke-MgGraphRequest` against the confirmed beta REST endpoints below for read-only checks, and use the **Microsoft Entra admin center** (`Global Secure Access > Secure > MCP policies (Preview)`) for all configuration changes. Microsoft's own docs confirm the Graph API is the fallback specifically for reading tool/resource/prompt-level rule detail that doesn't reliably re-render in the portal UI — not a general automation surface yet.

---
## Triage

Run these first. Interpret results to choose a fix path.

```powershell
# 1. Confirm GSA client is tunneling Internet Access traffic on the affected device (MCP firewall rides this profile)
Get-Service "Global Secure Access Client" | Select-Object Name, Status, StartType

# 2. Confirm Graph connectivity and required scopes
Connect-MgGraph -Scopes "NetworkAccess.Read.All"
Get-MgContext | Select-Object Scopes

# 3. Confirm the Internet Access forwarding profile is enabled tenant-wide
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/networkAccess/forwardingProfiles").value |
    Where-Object trafficForwardingType -eq "internet" | Select-Object name, state

# 4. List filtering policies and find the MCP one (no dedicated "policyType eq mcp" filter is
#    documented yet — list all and inspect @odata.type / name to find it)
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/networkAccess/filteringPolicies").value |
    Select-Object id, name, '@odata.type'

# 5. List filtering profiles ("Security profiles" in the portal) and their linked policies
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/networkAccess/filteringProfiles?`$expand=policies").value |
    Select-Object id, name, state, policies
```

| Result | Action |
|--------|--------|
| GSA client service `Stopped`/missing | → [Fix 1 — Restore Base GSA Client/Tunnel](#fix-1--restore-base-gsa-clienttunnel) (MCP firewall inherits the base GSA fault domain — see `GlobalSecureAccess-B.md`) |
| Internet Access forwarding profile disabled | → [Fix 2 — Enable Internet Access Profile](#fix-2--enable-internet-access-profile) |
| TLS inspection not confirmed enabled (see Step 2 of Diagnosis Flow) | → [Fix 3 — Enable TLS Inspection](#fix-3--enable-tls-inspection) |
| MCP policy exists but not linked to any filtering profile | → [Fix 4 — Link MCP Policy to a Filtering Profile](#fix-4--link-mcp-policy-to-a-filtering-profile) |
| Filtering profile linked but no Conditional Access policy enforces it | → [Fix 5 — Enforce via Conditional Access](#fix-5--enforce-via-conditional-access) |
| Approved MCP server/tool still being blocked | → [Fix 6 — Correct a Server/Tool Rule](#fix-6--correct-a-servertool-rule) |
| All checks pass, traffic still not enforced as expected | → Escalate — capture **Global Secure Access > Monitor > Traffic logs** + **Generative AI Insights** MCP activity export and open a support case |

---
## Dependency Cascade

<details><summary>What must be true for the MCP firewall to inspect and enforce on MCP traffic</summary>

```
Entra ID (Identity)
  └── Tenant licensed for Microsoft Entra Internet Access
        └── Global Secure Access client installed, running, signed in (Entra joined/hybrid joined device)
              └── Internet Access traffic forwarding profile — state = enabled
                    └── TLS inspection enabled on the traffic path  ⚠ HARD PREREQUISITE
                          (MCP is JSON-RPC 2.0 over HTTPS — without decryption, the
                           firewall cannot parse MCP messages at all; every other
                           layer below can be perfect and still enforce nothing)
                          └── MCP policy (Global Secure Access > Secure > MCP policies (Preview))
                                ├── Default action: Allow or Block
                                ├── Rule(s): server URL / primitive (Tool, Resource, Prompt) /
                                │            protocol version / method / transport conditions
                                └── Linked to a filtering profile ("Security profile" in portal)
                                      └── Filtering profile linked to a Conditional Access policy
                                            ├── Target resources = "All internet resources with GSA"
                                            └── Session control = "Use Global Secure Access Security Profile"
                                                  └── Policy State = On (report-only does not enforce)
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the base GSA tunnel is healthy**
```powershell
Get-Service "Global Secure Access Client" | Select-Object Name, Status
dsregcmd /status | Select-String "AzureAdPrt"
```
Expected: `Status = Running`, `AzureAdPrt : YES`. The MCP firewall is a policy layer on top of Internet Access — if the base tunnel is broken, troubleshoot `GlobalSecureAccess-B.md` first; nothing MCP-specific will work until this layer is healthy.

**Step 2 — Confirm TLS inspection is enabled on the path**
TLS inspection has no single dedicated read-only Graph endpoint confirmed stable in this repo yet — verify directly in the portal (**Global Secure Access > Secure > TLS inspection policy**) that **State = Enabled**, and cross-check the client's root-certificate trust:
```powershell
# On the device — confirm the GSA TLS inspection root certificate is trusted
Get-ChildItem Cert:\LocalMachine\Root | Where-Object Subject -like "*Global Secure Access*"
```
Expected: TLS inspection shows Enabled in the portal, and the device trusts the GSA root CA. This is the single most common "MCP policy exists but does nothing" root cause — TLS inspection is not optional for MCP visibility because MCP traffic is inside HTTPS.

**Step 3 — Confirm the MCP policy's default action and rule set (portal)**
Browse to **Global Secure Access > Secure > MCP policies (Preview)**, open the policy, and confirm:
- **Default action** matches intent (Allow-by-default with explicit Block rules, or Block-by-default with explicit Allow rules)
- Rule **Priority** order — rules are evaluated in order, and a higher-priority rule can silently shadow a lower-priority one for the same server/tool
- Each rule's **Status** is enabled, not just present

```powershell
# Read-only cross-check via Graph — confirm the policy object and its rule count exist
$mcp = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/networkAccess/filteringPolicies").value |
    Where-Object name -like "*MCP*"
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/networkAccess/filteringPolicies/$($mcp.id)/policyRules"
```

**Step 4 — Confirm the policy is actually linked to a filtering profile**
```powershell
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/networkAccess/filteringProfiles?`$expand=policies").value |
    Select-Object name, state, @{N='LinkedPolicyIds';E={$_.policies.id}}
```
Expected: The filtering profile assigned to the relevant Conditional Access policy shows the MCP policy's `id` inside `policies`. A perfectly configured MCP policy that is never linked to a profile enforces on zero traffic — this is a distinct and common gap from the policy itself being misconfigured.

**Step 5 — Confirm Conditional Access is enforcing that filtering profile**
```powershell
Get-MgIdentityConditionalAccessPolicy |
    Where-Object { $_.SessionControls.GlobalSecureAccessFilteringProfile.Enabled -eq $true } |
    Select-Object DisplayName, State
```
Expected: A policy in `State = enabledForReportingButNotEnforced` will show violations in logs but never actually block anything — confirm `State = enabled` if the expectation is active enforcement, not just visibility.

---
## Common Fix Paths

<details><summary>Fix 1 — Restore Base GSA Client/Tunnel</summary>

**When:** GSA client isn't running or isn't tunneling Internet Access traffic at all — MCP firewall has zero visibility without the base tunnel.

```powershell
Restart-Service "Global Secure Access Client" -Force
```

Full base-layer diagnosis (client service, forwarding profiles, PRT, connectors) is out of scope here — hand off to `GlobalSecureAccess-B.md` Fix 1/2, which owns this fault domain.

**Rollback:** Non-destructive; client re-establishes tunnel on next sign-in.

</details>

<details><summary>Fix 2 — Enable Internet Access Profile</summary>

**When:** The Internet Access traffic forwarding profile is disabled, so no internet-bound traffic (including MCP) is tunneled through GSA at all.

```powershell
$profile = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/networkAccess/forwardingProfiles").value |
    Where-Object trafficForwardingType -eq "internet"

Invoke-MgGraphRequest -Method PATCH `
    -Uri "https://graph.microsoft.com/beta/networkAccess/forwardingProfiles/$($profile.id)" `
    -Body (@{ state = "enabled" } | ConvertTo-Json)
```

**Rollback:** Setting `state = "disabled"` reverts to direct (untunneled, unfiltered) routing for all internet traffic — no persistent client-side state to clean up.

</details>

<details><summary>Fix 3 — Enable TLS Inspection</summary>

**When:** TLS inspection is not enabled — the MCP firewall cannot parse any MCP traffic without it.

Enable in the portal: **Global Secure Access > Secure > TLS inspection policy > Enable**.

Before enabling in production, confirm the Global Secure Access root certificate has already been distributed to and trusted by target devices (Intune-deployed trusted root certificate profile) — enabling TLS inspection without client-side trust causes certificate warnings/connection failures across **all** inspected traffic, not just MCP. Verify trust on a test device first:
```powershell
Get-ChildItem Cert:\LocalMachine\Root | Where-Object Subject -like "*Global Secure Access*"
```

**Rollback:** Disabling TLS inspection immediately stops decryption/inspection tenant-wide (not MCP-specific — this affects Web Content Filtering too if it depends on the same TLS inspection policy).

</details>

<details><summary>Fix 4 — Link MCP Policy to a Filtering Profile</summary>

**When:** An MCP policy exists and looks correctly configured but has no effect — it was never attached to a filtering profile ("Security profile" in the portal).

In the Microsoft Entra admin center:
1. **Global Secure Access** > **Secure** > **Security profiles**
2. Select the profile assigned to the affected users (or create/select the one referenced by your Conditional Access policy)
3. **Link policies** tab > **+ Link a policy** > **Existing MCP policy**
4. Select the MCP policy, keep default **Position**/**State**, select **Add**

**Rollback:** Unlink the policy from the profile — the underlying MCP policy definition is untouched and can be relinked later.

</details>

<details><summary>Fix 5 — Enforce via Conditional Access</summary>

**When:** The filtering profile is correctly linked but no Conditional Access policy is actually applying it, or the CA policy is in report-only.

```powershell
$ca = Get-MgIdentityConditionalAccessPolicy | Where-Object DisplayName -like "*GSA*MCP*"
Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $ca.Id -BodyParameter @{
    state = "enabled"
}
```

If no such CA policy exists yet, it must be created in the portal: **Identity > Protection > Conditional Access > + Create new policy**, target resources = **All internet resources with Global Secure Access**, Session > **Use Global Secure Access Security Profile** > select the profile from Fix 4.

**Rollback:** Set `state = "enabledForReportingButNotEnforced"` to stop active blocking immediately while keeping visibility in logs.

</details>

<details><summary>Fix 6 — Correct a Server/Tool Rule</summary>

**When:** A specific MCP server or tool that should be allowed is being blocked (or vice versa).

Review rule order and conditions in the portal (**MCP policies (Preview) > [policy] > rules**). Common causes, in order of frequency:

1. **Priority ordering** — a higher-priority Block rule matches the same server/tool before the intended Allow rule is reached. Reorder or narrow the Block rule's scope.
2. **Default action mismatch** — if **Default action = Block** and no explicit Allow rule matches the server URL exactly (including path/subdomain), everything falls through to the block. Server URL matching in this feature is exact/pattern-based, not fuzzy.
3. **Tool/resource/prompt-level scoping** — a rule scoped to the server URL but with specific primitives selected only allows/blocks those named primitives; a new tool added to the server after the rule was created is **not** automatically covered and falls through to the policy default action.

```powershell
# Read-only cross-check: confirm the rule set Graph returns matches what the portal shows
$mcp = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/networkAccess/filteringPolicies").value |
    Where-Object name -like "*MCP*"
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/networkAccess/filteringPolicies/$($mcp.id)/policyRules"
```
Per Microsoft's documented limitation, specific tool/resource/prompt selections inside a rule don't reliably re-render in the portal UI on later retrieval — treat this Graph output as source of truth when auditing what a rule actually matches, not the UI.

**Rollback:** Revert to the previous rule priority/action captured before editing — always export the rule table (via the Graph read-only query above) before modifying.

</details>

---
## Escalation Evidence

Copy this template, fill in all fields, attach to ticket before escalating to Microsoft Support.

```
=== GSA MCP FIREWALL ESCALATION EVIDENCE PACK ===
Date/Time (UTC): _______________
Reported by: _______________
Tenant ID: _______________
Affected user(s)/device(s): _______________
MCP server URL involved: _______________
Tool/Resource/Prompt name (if primitive-level issue): _______________

SYMPTOM:
[ ] Approved server/tool being blocked unexpectedly
[ ] Server/tool that should be blocked is getting through
[ ] MCP policy has no visible effect at all
[ ] No MCP traffic appearing in Generative AI Insights
[ ] Other: _______________

TRIAGE RESULTS:
GSA Client Service Status: _______________
TLS Inspection State (portal): _______________
Internet Access Forwarding Profile State: _______________
MCP Policy Name / Default Action: _______________
Filtering Profile Link Confirmed (Y/N): _______________
Conditional Access Policy State (enabled / report-only): _______________

ACTIONS TAKEN:
_______________

CORRELATION ID: _______________
CLIENT VERSION: _______________
```

---
## 🎓 Learning Pointers

- **MCP firewall is Preview — treat the tooling as immature, not the concept**: This is explicitly a prerelease capability per Microsoft's own preview terms; configuration is portal-first with no documented typed Graph PowerShell cmdlet set yet. Validate any automation against `Invoke-MgGraphRequest` and the raw beta REST schema, not assumed `Get-MgBeta*` wrapper names, before relying on it in production change control. Reference: [Configure Global Secure Access MCP firewall](https://learn.microsoft.com/en-us/entra/global-secure-access/how-to-configure-mcp-firewall)
- **TLS inspection is the hidden hard gate, not an optional hardening step**: Unlike most GSA features, the MCP firewall is structurally incapable of functioning without TLS inspection, because MCP rides inside encrypted HTTPS payloads — this is the single highest-yield first check when an MCP policy "does nothing." Reference: [Transport Layer Security inspection](https://learn.microsoft.com/en-us/entra/global-secure-access/how-to-transport-layer-security)
- **A configured MCP policy that isn't linked to a filtering profile enforces on nothing**: This mirrors the same "profile as master switch" pattern seen with GSA forwarding profiles — always confirm the link (`filteringProfiles?$expand=policies`), not just the policy's own rule table, before assuming a misconfiguration inside the policy itself.
- **Only remote MCP servers over streamable HTTP/SSE are inspected**: Local (stdio) MCP servers running on the device are invisible to Global Secure Access by design — a "why isn't this local MCP server being controlled" ticket is not a misconfiguration, it's a documented scope boundary. Reference: [Known limitations](https://learn.microsoft.com/en-us/entra/global-secure-access/how-to-configure-mcp-firewall#known-limitations)
- **Use Generative AI Insights to discover before you author rules**: Rather than guessing at server URLs, review **Global Secure Access > Monitor > Generative AI Insights** first — discovered servers/tools from real traffic can be added directly into a rule via "View suggested MCP servers from recent activity," which is both faster and less error-prone than hand-typing URLs. Reference: [View MCP traffic logs](https://learn.microsoft.com/en-us/entra/global-secure-access/how-to-view-model-context-protocol-logging)
- **This sits directly on top of the existing GSA topic**: cross-reference `GlobalSecureAccess-B.md`/`-A.md` for the base client/connector/profile layer this feature depends on entirely — do not duplicate base-tunnel triage here.
