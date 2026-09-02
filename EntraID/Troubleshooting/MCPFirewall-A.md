# Entra Global Secure Access — MCP Firewall (Preview) — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers the Microsoft Entra **Global Secure Access MCP firewall** — a Public Preview capability (entered preview August 2026) that extends the existing Internet Access Security Service Edge (SSE) layer to inspect and enforce policy on **Model Context Protocol (MCP)** traffic: the JSON-RPC 2.0-based wire protocol AI agents use to discover and invoke tools, resources, and prompt templates on remote MCP servers.

Covers: the MCP firewall's architecture and why it depends entirely on TLS inspection, the MCP policy/filtering-profile/Conditional-Access linking chain, the four supported enforcement scenarios (block-all, server allow/deny-list, primitive-level allow/deny, protocol/method/transport hygiene), Generative AI Insights as the discovery mechanism, and the documented Preview-era limitations.

**Assumes:**
- Microsoft Graph PowerShell SDK for read-only cross-checks: `Install-Module Microsoft.Graph.Beta -Scope CurrentUser`, `Connect-MgGraph -Scopes "NetworkAccess.Read.All"`
- Tenant licensed for Microsoft Entra Internet Access (standalone add-on or via Microsoft Entra Suite)
- The base Global Secure Access client/tunnel layer is already healthy (see `GlobalSecureAccess-A.md` — this topic assumes that layer, does not re-derive it)
- A user with the **Global Secure Access Administrator** role to configure MCP policies and security profiles, and a user with **Conditional Access Administrator** to enforce them
- Devices are Microsoft Entra joined or Microsoft Entra hybrid joined (a hard prerequisite for this specific feature, stricter than the "registered is the floor" rule that applies to base GSA)

**Not covered:** base Global Secure Access client deployment, traffic forwarding profile design outside what MCP depends on, and Private Access/connector architecture (see `GlobalSecureAccess-A.md`); TLS inspection policy design and certificate distribution mechanics beyond the "it must be on" dependency (see `how-to-transport-layer-security` reference); MCP protocol internals/client or server implementation (this is a network-policy-enforcement topic, not an MCP development topic); Microsoft 365 Copilot agent governance / Agent Registry (a completely different control plane for a different traffic class — see `M365/Copilot/AgentGovernance-A.md`); Entra Agent ID (identity for the agent itself, not network policy on its MCP traffic — see `Troubleshooting/AgentID-A.md`).

---
## How It Works

<details><summary>Full architecture</summary>

### Why this sits at the network layer, not the identity layer

Most of Entra's AI-agent governance surface area — Agent ID, the M365 Admin Agent Registry, Copilot Agent Governance — controls **what an agent is allowed to be** and **who can publish/approve it**. The MCP firewall is different: it controls **what an already-running agent is allowed to say over the wire** to a remote MCP server, regardless of the agent's identity, publisher, or governance status. This makes it a network-based, identity-*aware* (not identity-*driven*) control: it extends the same SSE model Internet Access already applies to general web traffic (identity-based access, Conditional Access, Continuous Access Evaluation) down to the MCP protocol layer specifically.

Practically, this means the MCP firewall does **not** require the agent or MCP client/host/server to be modified, MCP-aware of Entra, or running any special SDK — enforcement happens transparently in the traffic path, the same way Web Content Filtering blocks a URL category without the browser knowing anything changed.

### The hard dependency: TLS inspection

MCP traffic (JSON-RPC 2.0 over streamable HTTP, or Server-Sent Events) travels inside an ordinary HTTPS connection. Without TLS inspection enabled on the GSA Internet Access path, the payload is opaque to the network layer — GSA can see *that* a connection exists and to which host, but not the MCP-specific structure (method calls, tool names, resource URIs, prompt templates) needed to make a policy decision at that granularity. This is architecturally different from, say, Web Content Filtering's URL-category blocking, which only needs the SNI/hostname and works without decryption. The MCP firewall's entire value proposition — blocking one tool on an otherwise-trusted server, or auditing exactly which resources an agent touched — is impossible without decrypting and re-inspecting the payload. This is why TLS inspection isn't listed as "recommended" in Microsoft's documentation; it's a hard, load-bearing prerequisite.

### The three-object configuration chain

Configuring enforcement requires three distinct objects, each independently capable of silently neutering the other two if misconfigured:

1. **MCP policy** (`Global Secure Access > Secure > MCP policies (Preview)`) — the ruleset itself. Has a tenant-level **Default action** (Allow or Block) and an ordered list of **rules**, each scoped by some combination of: MCP server URL (exact/pattern match), primitive type and name (Tool/Resource/Prompt), MCP protocol version, MCP method, transport protocol, and protected-resource metadata. Graph exposes this as a `filteringPolicy`-family resource under `/beta/networkAccess/filteringPolicies` (the same base resource type used for URL filtering policies elsewhere in GSA — MCP policies are a variant of the same underlying filtering-policy model, not a wholly separate resource type).
2. **Filtering profile** ("Security profile" in the portal, `filteringProfile` in Graph) — the object that Conditional Access actually references. A policy that exists but is never *linked* to a profile has no effect on any traffic, no matter how correctly its rules are written — this is architecturally identical to the base-GSA "disabled forwarding profile" failure mode: perfectly good configuration sitting inert because the object one layer up was never wired in.
3. **Conditional Access policy** — the object that actually turns enforcement on for a scoped set of users/devices. Session control `Use Global Secure Access Security Profile` selects the filtering profile from step 2. Critically, CA policy `State` (`enabled` vs. `enabledForReportingButNotEnforced`) is the final on/off switch — a fully wired MCP policy → profile → CA chain in report-only mode logs violations but blocks nothing.

### Rule matching mechanics

Within a single MCP policy, rules are evaluated by **Priority** in order; the first matching rule's action wins. Four scoping strategies are supported for building a rule's match condition:
- **Discovered MCP servers** — pulled from Generative AI Insights telemetry ("View suggested MCP servers from recent activity"), the fastest and least error-prone path since it uses servers actually observed in traffic rather than hand-typed URLs.
- **Known MCP servers** — manually entered server URL(s), comma-separated for multiple.
- **Discovered tools** — add a server URL, trigger **Discover**, and the firewall queries the server's own MCP `tools/list`-equivalent capability to enumerate and auto-classify available tools/resources/prompts for granular selection.
- **Manual primitive entry** — for servers that require authentication or aren't reachable from the authoring context, tools/resources/prompts can be typed in by name/type/description without live discovery.

A rule can additionally constrain on **MCP protocol version** (block outdated/vulnerable versions), **MCP methods**, **transport protocol** (e.g., block unencrypted HTTP connection attempts), and **protected resource metadata**.

### The two canonical enforcement patterns

1. **Allow-list (default-deny)**: Default action = Block; explicit Allow rules for each approved server. New/unknown MCP servers are blocked by default the moment they're discovered — the safest posture for a first rollout, but requires active allow-list maintenance as legitimate new servers come online.
2. **Deny-list (default-allow)**: Default action = Allow; explicit Block rules for specific known-bad servers or specific risky tools on an otherwise-trusted server (e.g., block a destructive `delete_file` tool while allowing read-only tools on the same server). Lower operational overhead, but any MCP server not explicitly blocked is reachable — appropriate only where the organization has other compensating controls (e.g., app-level allow-listing at the agent host).

### Monitoring: Traffic logs vs. Generative AI Insights

Two distinct surfaces exist for observing MCP firewall activity, requiring different minimum RBAC:
- **Traffic logs** (`Monitor > Traffic logs`, minimum **Reports Reader**) — network-level allow/block decision records, useful for confirming a specific enforcement action fired.
- **Generative AI Insights** (`Monitor > Generative AI Insights`, minimum **Security Reader**) — MCP-protocol-aware session/tool-invocation/server-discovery view; filter by **Activity = MCP**. This is also the feed that powers the "suggested MCP servers from recent activity" authoring shortcut, so it has dual value as both an audit surface and a policy-authoring accelerant.

</details>

---
## Dependency Stack

```
Entra ID (Identity)
  └── Tenant licensed for Microsoft Entra Internet Access (Suite or standalone)
        └── Global Secure Access client — installed, running, signed in
              └── Device Entra joined or Entra hybrid joined (registered-only is NOT sufficient for this feature)
                    └── Internet Access traffic forwarding profile — state = enabled
                          └── TLS inspection — enabled + GSA root CA trusted on the device
                                (hard prerequisite — MCP payload is unparseable without this)
                                └── MCP policy (filteringPolicy, MCP variant)
                                      ├── Default action: Allow | Block
                                      └── Ordered rules (server URL / primitive / version / method / transport)
                                            └── Linked to a filtering profile (policyLink, priority-ordered)
                                                  └── Filtering profile referenced by a Conditional Access
                                                      Session control ("Use Global Secure Access Security Profile")
                                                        └── CA policy State = enabled (report-only = visibility only)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|--------------------|-------|
| MCP policy configured, zero effect on any traffic | Policy not linked to a filtering profile, or profile not referenced by any enforced CA policy | `filteringProfiles?$expand=policies` + CA policy `SessionControls` |
| MCP policy correctly built but "does nothing" tenant-wide | TLS inspection disabled | Portal: TLS inspection policy state |
| One tool on an otherwise-working server unexpectedly blocked | A higher-priority Block rule (server-wide or primitive-scoped) matches before the intended Allow rule | Rule priority order in the portal |
| Newly added tool on an already-allowed server is blocked | Primitive-level rules don't auto-cover tools added after rule creation — new tool falls to default action | Re-run **Discover** on the server, add the new tool explicitly |
| Local/stdio MCP server traffic completely invisible to logs | Out of scope by design — only remote servers over streamable HTTP/SSE are inspected | Confirm transport in use; not a misconfiguration |
| Rule shows correct primitives in the portal at creation, but detail looks wrong on later review | Documented UI limitation — tool/resource/prompt selections don't reliably re-render on retrieval | Query the rule via Graph (`filteringPolicies/{id}/policyRules`) as source of truth |
| CA policy references the right profile but users report zero enforcement | CA policy `State = enabledForReportingButNotEnforced` | `Get-MgIdentityConditionalAccessPolicy` → check `State` |
| MCP traffic visible in Traffic logs but not in Generative AI Insights | Traffic wasn't parsed as MCP (TLS inspection off, or non-JSON-RPC/non-HTTP-SSE transport) | Confirm TLS inspection + transport type |
| Batched JSON-RPC requests bypass an expected block | Documented limitation — JSON-RPC batches aren't inspected | Not currently addressable via policy; track for GA feature parity |
| Device reachable to the MCP server directly (off-network) but firewall shows nothing | Device not tunneling through GSA for that path — not an MCP-specific fault, base tunnel/forwarding-profile issue | `GlobalSecureAccess-B.md` triage |

---
## Validation Steps

**1. Confirm Graph connection and scopes**
```powershell
Connect-MgGraph -Scopes "NetworkAccess.Read.All"
Get-MgContext | Select-Object Scopes
```
Expected: `NetworkAccess.Read.All` present.

**2. Confirm the base Internet Access tunnel and forwarding profile**
```powershell
Get-Service "Global Secure Access Client" | Select-Object Name, Status
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/networkAccess/forwardingProfiles").value |
    Where-Object trafficForwardingType -eq "internet" | Select-Object name, state
```
Expected: Client `Running`; Internet Access profile `state = enabled`. MCP traffic cannot reach the firewall at all if this layer is broken.

**3. Confirm TLS inspection (portal — no stable dedicated read-only Graph endpoint confirmed for this preview yet)**
Navigate to **Global Secure Access > Secure > TLS inspection policy**. Expected: **State = Enabled**. Cross-check root CA trust on a representative device:
```powershell
Get-ChildItem Cert:\LocalMachine\Root | Where-Object Subject -like "*Global Secure Access*"
```

**4. Enumerate MCP filtering policies and their rules**
```powershell
$policies = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/networkAccess/filteringPolicies").value
$policies | Select-Object id, name, '@odata.type'

foreach ($p in $policies) {
    Write-Host "--- $($p.name) ---"
    Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/networkAccess/filteringPolicies/$($p.id)/policyRules"
}
```
Expected: The MCP-specific policy is present; its rules array reflects what the portal shows.

**5. Confirm filtering-profile linkage**
```powershell
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/networkAccess/filteringProfiles?`$expand=policies").value |
    Select-Object name, state, @{N='LinkedPolicyIds';E={$_.policies.id}}
```
Expected: The MCP policy's `id` appears inside at least one filtering profile's `policies`.

**6. Confirm Conditional Access enforcement**
```powershell
Get-MgIdentityConditionalAccessPolicy |
    Where-Object { $_.SessionControls.GlobalSecureAccessFilteringProfile.Enabled -eq $true } |
    Select-Object DisplayName, State
```
Expected: `State = enabled` for policies intended to actively enforce (not merely report).

---
## Troubleshooting Steps (by phase)

### Phase 1 — Base Layer (client, tunnel, forwarding profile)
1. Confirm GSA client service running and PRT valid (`dsregcmd /status`)
2. Confirm Internet Access forwarding profile is enabled
3. If either is broken, resolve via `GlobalSecureAccess-B.md`/`-A.md` before proceeding — nothing MCP-specific can be diagnosed on top of a broken base tunnel

### Phase 2 — Inspection Layer (TLS inspection)
1. Confirm TLS inspection policy state in the portal
2. Confirm the GSA root CA is present and trusted on affected devices (Intune-deployed trusted root cert profile)
3. If TLS inspection was recently enabled, allow for client policy propagation delay before assuming a persistent fault

### Phase 3 — MCP Policy Configuration
1. Confirm the MCP policy's default action matches the intended enforcement posture (allow-list vs. deny-list)
2. Review rule priority order for shadowing — a broader higher-priority rule masking a narrower lower-priority one is the most common single-tool-blocked ticket
3. For primitive-level rules, re-run **Discover** against the target server to confirm the tool/resource/prompt catalog hasn't changed since rule authoring

### Phase 4 — Linking Chain (profile + Conditional Access)
1. Confirm the MCP policy is linked to a filtering profile (`filteringProfiles?$expand=policies`)
2. Confirm that filtering profile is the one referenced by the relevant Conditional Access policy's session control
3. Confirm the CA policy `State = enabled`, not report-only, if active enforcement (not just log visibility) is expected

### Phase 5 — Verification via Monitoring
1. Reproduce the reported traffic pattern from a managed test device
2. Check **Traffic logs** for the specific allow/block decision
3. Cross-reference **Generative AI Insights** (Activity = MCP) for the full session/tool-invocation detail
4. If the decision doesn't match policy intent, re-walk Phases 2–4 in order rather than immediately assuming a product bug — the vast majority of "policy isn't working" reports trace to a missing link in the profile/CA chain

---
## Remediation Playbooks

<details><summary>Playbook 1 — Roll out MCP firewall from zero (default-deny allow-list pattern)</summary>

Use when: standing up MCP governance for the first time, want the safest posture (block unknown servers by default).

```
Step 1: Confirm prerequisites — Internet Access licensed, GSA client deployed to
        target devices (Entra joined/hybrid joined), TLS inspection enabled and
        root CA trusted (Intune cert profile pushed and confirmed installed).

Step 2: Run with TLS inspection + Generative AI Insights for a discovery window
        (a few days) BEFORE writing any MCP policy — populate the "suggested MCP
        servers from recent activity" list with real traffic instead of guessing.

Step 3: Create the MCP policy — Default action = Block.
        Add Allow rules for each server surfaced in Generative AI Insights that's
        confirmed legitimate (finance/eng-approved AI tooling, internal MCP servers).

Step 4: Link the policy to a filtering profile scoped to a PILOT group first —
        do not link to a tenant-wide profile on day one.

Step 5: Create/scope a Conditional Access policy in
        enabledForReportingButNotEnforced against the pilot group + the linked
        profile. Observe Traffic logs for 3-5 business days for false-positive
        blocks against the pilot group's legitimate workflows.

Step 6: Flip the pilot CA policy to State = enabled once false-positive rate is
        acceptable. Expand scope in waves, repeating steps 5-6 for each wave.
```

**Rollback:** At any stage, setting the CA policy to `enabledForReportingButNotEnforced` stops active blocking immediately without losing the policy/profile/rule configuration.

</details>

<details><summary>Playbook 2 — Block a single risky tool without blocking the whole MCP server</summary>

Use when: a server hosts both safe (read-only) and risky (destructive/write) tools, and only the risky ones should be blocked.

```
Step 1: In the MCP policy, add a rule scoped to the specific server URL.

Step 2: Under MCP server primitives, select "Match on discovered tools" (or
        "Match on known MCP servers" -> Discover if not yet indexed).

Step 3: Select ONLY the specific tool(s) to block (e.g. a destructive
        delete/write tool) — leave other tools on the same server unselected.

Step 4: Set Action = Block on this rule. Set its Priority HIGHER (evaluated
        before) any broader Allow rule that would otherwise match the same
        server, since first-match-wins means a broad Allow rule ahead of this
        one in priority order would shadow it entirely.

Step 5: Validate: invoke the blocked tool from a test agent/device on the
        pilot profile — confirm it's blocked while other tools on the same
        server continue to succeed. Cross-check via Traffic logs +
        Generative AI Insights.
```

**Rollback:** Remove or disable the specific block rule — this does not affect any other rule in the policy.

</details>

<details><summary>Playbook 3 — Diagnose "policy exists, nothing is enforced"</summary>

Use when: an MCP policy is fully authored (correct rules, correct priorities) but has zero observable effect on real traffic.

```
Step 1: Confirm linkage — query filteringProfiles?$expand=policies and confirm
        the MCP policy's id appears under some profile's "policies" collection.
        If absent: this IS the root cause. Link it (portal: Security profiles ->
        Link policies -> + Link a policy -> Existing MCP policy).

Step 2: If linked, confirm which Conditional Access policy references that
        specific filtering profile in its Session controls
        (GlobalSecureAccessFilteringProfile). If no CA policy references it,
        the profile is configured but never invoked for any user/session.

Step 3: If a CA policy references it, confirm State = enabled (not report-only)
        AND confirm the CA policy's user/group scope actually includes the
        affected user — a correctly built chain that's scoped to the wrong
        group looks identical to "nothing is enforced" from the reporter's seat.

Step 4: If all of the above check out, confirm TLS inspection is genuinely
        enabled (not just configured) and that the affected device's GSA
        client has picked up the current policy set (client polls
        periodically — allow one polling interval, or restart the client
        service to force a refresh).
```

**Rollback:** N/A — diagnostic playbook only.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Global Secure Access MCP firewall diagnostic evidence for escalation
.NOTES     Requires Microsoft.Graph.Beta module and NetworkAccess.Read.All scope.
           Uses Invoke-MgGraphRequest against beta endpoints — typed cmdlet coverage
           for this Preview feature is not yet confirmed stable.
#>

$outputPath = "C:\MCPFirewall_Diagnostics_$(Get-Date -Format 'yyyyMMdd_HHmm')"
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

# Base tunnel / forwarding profile state
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/networkAccess/forwardingProfiles").value |
    Select-Object name, trafficForwardingType, state |
    Export-Csv "$outputPath\forwarding_profiles.csv" -NoTypeInformation

# All filtering policies (includes MCP policy/policies)
$policies = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/networkAccess/filteringPolicies").value
$policies | Select-Object id, name, '@odata.type' | Export-Csv "$outputPath\filtering_policies.csv" -NoTypeInformation

# Rules per policy
foreach ($p in $policies) {
    $rules = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/networkAccess/filteringPolicies/$($p.id)/policyRules"
    $rules.value | Select-Object *, @{N='PolicyName';E={$p.name}} |
        Export-Csv "$outputPath\policy_rules_$($p.id).csv" -NoTypeInformation
}

# Filtering profiles and their linked policies
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/networkAccess/filteringProfiles?`$expand=policies").value |
    Select-Object name, state, @{N='LinkedPolicyIds';E={($_.policies.id) -join ';'}} |
    Export-Csv "$outputPath\filtering_profiles.csv" -NoTypeInformation

# Conditional Access policies referencing a GSA filtering profile
Get-MgIdentityConditionalAccessPolicy |
    Where-Object { $_.SessionControls.GlobalSecureAccessFilteringProfile } |
    Select-Object DisplayName, State |
    Export-Csv "$outputPath\ca_policies.csv" -NoTypeInformation

Write-Host "Evidence collected to: $outputPath" -ForegroundColor Green
Compress-Archive -Path "$outputPath\*" -DestinationPath "$outputPath.zip" -Force
Write-Host "Archive: $outputPath.zip" -ForegroundColor Cyan
Write-Host "NOTE: TLS inspection state and Generative AI Insights MCP activity must be captured manually from the portal — no confirmed stable Graph read endpoint for either at time of writing." -ForegroundColor Yellow
```

---
## Command Cheat Sheet

```powershell
# Connect with the read scope needed for every check below
Connect-MgGraph -Scopes "NetworkAccess.Read.All"

# Internet Access forwarding profile state
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/networkAccess/forwardingProfiles").value |
    Where-Object trafficForwardingType -eq "internet" | Select name,state

# List all filtering policies (MCP policy is a variant of this resource)
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/networkAccess/filteringPolicies").value |
    Select id,name,'@odata.type'

# List rules for a specific policy
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/networkAccess/filteringPolicies/<policy-id>/policyRules"

# List filtering profiles and their linked policies
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/networkAccess/filteringProfiles?`$expand=policies").value |
    Select name,state,policies

# Enable the Internet Access forwarding profile
Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/beta/networkAccess/forwardingProfiles/<id>" -Body (@{state="enabled"}|ConvertTo-Json)

# Conditional Access policies referencing a GSA filtering profile session control
Get-MgIdentityConditionalAccessPolicy | Where-Object { $_.SessionControls.GlobalSecureAccessFilteringProfile.Enabled -eq $true } | Select DisplayName,State

# On-device: GSA client service state
Get-Service "Global Secure Access Client" | Select Name,Status,StartType

# On-device: confirm GSA TLS inspection root CA is trusted
Get-ChildItem Cert:\LocalMachine\Root | Where-Object Subject -like "*Global Secure Access*"

# On-device: identity/PRT (shared GSA dependency)
dsregcmd /status | Select-String "AzureAdPrt|AzureAdJoined"
```

---
## 🎓 Learning Pointers

- **This is a network-layer control on top of, not a replacement for, agent-identity governance**: Entra Agent ID governs what an agent *is*; Agent Registry/Copilot Agent Governance govern what an agent is *allowed to be published as*; the MCP firewall governs what an already-running agent's *traffic* is allowed to do over the wire. A tenant can have excellent agent-identity governance and zero MCP traffic control, or vice versa — they are complementary, not overlapping, controls. Reference: [Configure Global Secure Access MCP firewall](https://learn.microsoft.com/en-us/entra/global-secure-access/how-to-configure-mcp-firewall)
- **TLS inspection is the one dependency that makes or breaks this entire feature**: because MCP is JSON-RPC over HTTPS, there is no degraded/partial mode — either TLS inspection is on and MCP policy enforcement is fully possible, or it's off and MCP policy enforcement is completely impossible, with no error surfaced anywhere except "traffic isn't showing up in Generative AI Insights." Reference: [TLS inspection](https://learn.microsoft.com/en-us/entra/global-secure-access/how-to-transport-layer-security)
- **Preview tooling maturity lags the portal**: as of this writing, Microsoft's own configuration guide for this feature is 100% portal-driven with no PowerShell/Graph write examples at all — only a documented Graph *read* fallback for rule-primitive detail that doesn't reliably re-render in the UI. Don't build change-management automation around assumed cmdlet names for a Preview feature; validate against the live beta schema first.
- **Rule priority is first-match-wins, same mental model as Conditional Access and NSGs**: engineers who default to "more specific rule should win regardless of order" will misdiagnose shadowed rules as product bugs — always check priority order before assuming the policy engine is broken.
- **Batched JSON-RPC and local/stdio MCP servers are explicit, permanent-for-now scope exclusions, not bugs to report**: set expectations with stakeholders up front that this firewall covers *remote* MCP servers over HTTP/SSE only — a security review that assumes 100% MCP traffic coverage tenant-wide will be wrong. Reference: [Known limitations](https://learn.microsoft.com/en-us/entra/global-secure-access/how-to-configure-mcp-firewall#known-limitations)
- **Discover before you author**: Generative AI Insights isn't just an audit log here — it's the recommended starting point for building an accurate server/tool allow-list, since it reflects what's actually being called rather than what admins assume is being called.
