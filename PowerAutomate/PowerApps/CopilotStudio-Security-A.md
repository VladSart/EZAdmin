# Copilot Studio Security & Governance — Reference Runbook (Mode A: Deep Dive)
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
| **Surface** | Microsoft Copilot Studio's own security and governance control surface: data (DLP) policies scoped to Copilot Studio connectors, per-agent authentication configuration, tenant/environment generative-AI publishing controls, customer-managed keys (CMK), sensitivity-label-aware knowledge grounding, and Purview/Sentinel audit logging of maker activity |
| **Scope** | Power Platform admin center's Copilot Studio-specific data policy connectors and classifications; agent-level Authentication settings (No authentication / Authenticate with Microsoft / Authenticate manually); tenant-level generative-AI publish/geo-data-movement toggles; CMK for Copilot Studio environment data at rest; knowledge-source governance (SharePoint/OneDrive, public websites, documents) including endpoint filtering; audit logging via Purview and Sentinel |
| **Out of scope (see cross-references)** | Copilot Studio's own bot-authoring, topics/dialog design, and connector-building mechanics — this file covers the governance/security control surface only, not agent development. Power Apps/Dataverse environment lifecycle (creation, licensing, provisioning) — see `PowerApps/Environment-Dataverse-A.md`/`-B.md`. Power Platform data (DLP) policies for **flows** (connector classification, throttling interactions) — see `PowerAutomate/Troubleshooting/DLP-Policies-A.md`/`-B.md` (this file only covers the Copilot Studio-specific connectors and use cases within the same DLP engine). Microsoft 365 Copilot base licensing/tenant enablement and the cross-platform Agent Registry/Agent 365 governance model spanning *all* agent-creation surfaces (Copilot Studio, Agent Builder, SharePoint agents, Microsoft Foundry, etc.) — see `M365/Copilot/Copilot-A.md`/`-B.md` and `M365/Copilot/AgentGovernance-A.md`/`-B.md`. Microsoft Purview Compliance Manager's broader assessment/scoring relationship to AI governance — see `Security/Purview/ComplianceManager-A.md`/`-B.md`. |
| **Assumed role** | L2/L3 engineer or MSP admin with Power Platform Administrator or Environment Admin role in the tenant; Microsoft.PowerApps.Administration.PowerShell module installed for any PowerShell-based evidence collection or remediation |

**Why this is a distinct topic from Agent Governance.** `M365/Copilot/AgentGovernance-A.md` deliberately treats Copilot Studio as one of several agent-creation platforms feeding into the Microsoft 365 Agent Registry — a cross-platform inventory/approval/ownership layer. It explicitly states "Copilot Studio's own bot-authoring... only the governance/admin-control surface is covered here, not agent development," and `PowerApps/Environment-Dataverse-A.md` explicitly lists "Copilot Studio-specific environment behavior" as out of scope. Neither file documents the actual mechanics of Copilot Studio's own DLP data policies, per-agent authentication model, or CMK — that surface is what this runbook covers. Put simply: Agent Registry governs *whether an agent is allowed to exist and who owns it*; this runbook governs *whether a specific Copilot Studio agent's own security configuration is sound*.

---

## How It Works

<details><summary>Full architecture</summary>

### Copilot Studio's security model is layered, not a single toggle

There is no single "Copilot Studio security" switch. Four largely independent control layers stack on top of each other, and a ticket that names only one of them is usually missing at least one other:

1. **Tenant-level generative-AI controls** (Power Platform admin center → Settings → Product → Copilot Studio) — coarse on/off switches: whether agents using generative-AI features can be *published* at all in the tenant, and whether generative-AI data movement is allowed to leave the tenant's configured geography.
2. **Data (DLP) policies scoped to Copilot Studio connectors** — the primary, granular governance mechanism. These are the *same* Power Platform data policy engine used for flow/app connector governance, but Copilot Studio ships its own set of pseudo-connectors representing agent capabilities (authentication mode, knowledge-source types, channels, HTTP requests, skills, event triggers) rather than data-source connectors.
3. **Per-agent Authentication configuration** — set by the agent maker inside Copilot Studio itself (Settings → Security → Authentication), but *constrained* by whatever data policy from layer 2 applies to the agent's environment.
4. **Data-at-rest and audit controls** — customer-managed keys (CMK) for encryption, and Purview/Sentinel audit logging of maker actions — largely orthogonal to layers 1–3 and typically the last thing checked in a compliance-driven ticket.

### Data policies use Power Platform's DLP engine, but with Copilot Studio-specific "connectors"

Power Platform data policies classify every connector into one of three groups — **Business**, **Non-Business**, or **Blocked** — and connectors can only exchange data with other connectors in the *same* group within a policy. Copilot Studio surfaces its own capabilities as connectors inside this same engine so admins can apply the identical classify/block mechanism to agent behavior rather than only to data-source connections:

| Copilot Studio "connector" | Governs |
|---|---|
| `Chat without Microsoft Entra ID authentication in Copilot Studio` | Whether makers can publish an agent with **No authentication** |
| `Knowledge source with SharePoint and OneDrive in Copilot Studio` | Whether SharePoint/OneDrive can be used as a knowledge source (supports endpoint filtering) |
| `Knowledge source with public websites and data in Copilot Studio` | Whether public websites can be used as a knowledge source (supports endpoint filtering) |
| `Knowledge source with documents in Copilot Studio` | Whether uploaded documents can be used as a knowledge source |
| `HTTP` | Whether the HTTP Request authoring node can be published (supports endpoint filtering) |
| `Skills with Copilot Studio` | Whether skills can be added to an agent |
| `Microsoft Teams + Microsoft 365 Channel in Copilot Studio` | Whether the agent can publish to Teams + M365 |
| `Direct Line channels in Copilot Studio` | Whether the agent can publish to Demo website, custom websites, mobile app, or other Direct Line-based channels (allowed by default if unblocked) |
| `Facebook channel in Copilot Studio` / `Omnichannel in Copilot Studio` / `SharePoint channel in Copilot Studio` / `WhatsApp channel in Copilot Studio` | Channel-specific publish gates |
| `Application Insights in Copilot Studio` | Whether telemetry can be captured via App Insights |
| `Microsoft Copilot Studio` | Event triggers and automated evaluations using an authenticated account |

Connectors introduced after 2019 — which includes most Copilot Studio connectors — default into the **Non-Business** classification group unless explicitly reclassified by an admin. Many tenants configure their baseline data policy to auto-block Non-Business connectors, which is why a brand-new Copilot Studio capability (a newly shipped channel, a newly shipped knowledge-source type) frequently appears "broken" to a maker the moment Microsoft ships it — nothing regressed; the new connector simply inherited a blocking default classification.

### Data policy scope: tenant-wide, specific-environments, or exclude-list — and it is now mandatory

Since early 2025 (Microsoft message center **MC973179**), Copilot Studio data policy enforcement is mandatory for all tenants — the previous per-agent enforcement exemption mechanism no longer exists. Every agent, in every environment, is subject to whatever data policies scope to that environment. A policy's scope is one of:
- **All environments** — applies tenant-wide, and automatically covers any new environment created afterward.
- **Add multiple environments** — an explicit allow-list of environments the policy applies to.
- **Exclude certain environments** — applies everywhere except a named exclude-list.

### Authentication: three modes, with real behavioral differences, not cosmetic ones

- **No authentication** — the agent is fully anonymous; anyone with the link can chat with it and it can only access public information/resources. Blocked entirely if a data policy requires the authentication connector.
- **Authenticate with Microsoft** — zero-config Entra ID auth, but restricted to the **Teams + Microsoft 365** channel (plus native/custom app channels). Users are never prompted separately in Teams because Teams itself already identifies them. Exposes `User.ID` and `User.DisplayName` as topic variables, but **not** `User.AccessToken` or `User.IsLoggedIn` — an agent maker who needs a token for downstream API calls must use manual authentication instead.
- **Authenticate manually** — supports Entra ID (classic), Entra ID V2 with client secret/certificate/federated credential, or any generic OAuth2-compliant identity provider. Exposes `User.Id`, `User.DisplayName`, `User.AccessToken`, and `User.IsLoggedIn`. This is the only mode compatible with non-Microsoft identity providers and the only mode that can be combined with **Require users to sign in** to gate the entire conversation (not just specific topics) behind auth, and to enable per-user sharing/access control outside of Teams.

Switching *from* Authenticate manually *to* Authenticate with Microsoft breaks any topic referencing `User.AccessToken`/`User.IsLoggedIn` — those become **Unknown** variables that must be fixed before republishing. Authentication changes never take effect until the agent is republished — a very common source of "I fixed it but it's still broken" tickets.

### Knowledge-source governance intersects with — but is distinct from — sensitivity labels

Blocking or endpoint-filtering the SharePoint knowledge-source connector controls *whether a site can be added as a source at all*. It does not replace sensitivity-label-based oversharing protection, which is a separate, always-on mechanism: Copilot Studio tailors generative responses to the querying user's own permissions and surfaces the highest sensitivity label present among the sources used in a response, plus per-reference labels. A knowledge source can be fully permitted by data policy and still correctly withhold content from a user who lacks access to the underlying SharePoint item.

### Customer-managed keys (CMK) and Customer Lockbox

CMK is configured per Power Platform environment (not uniquely to Copilot Studio — it is the same Power Platform CMK mechanism used for Dataverse) and, once enabled, encrypts all Copilot Studio data for that environment with a customer-owned Key Vault key rather than a Microsoft-managed key. Keys can be rotated or CMK disabled by the customer at any time. Customer Lockbox is also supported for accessing customer data, with one important carve-out: Lockbox does **not** cover data sent out from Copilot Studio as part of Agent 365 security audit logging — worth flagging explicitly to a compliance stakeholder who assumes Lockbox is a blanket guarantee.

### Tenant isolation does NOT apply to Copilot Studio the way it does to Power Platform connectors

Power Platform's tenant isolation feature (which restricts cross-tenant connector connections when turned on) explicitly does **not** govern Copilot Studio. This is a documented gap, not a misconfiguration — if a client asks "we have tenant isolation on, why can Copilot Studio still do X," the answer is architectural, not a settings fix. There is no equivalent Copilot Studio-specific tenant isolation control as of this writing; Microsoft's guidance is to use data policies for the specific behaviors you want to prevent instead.

### Agents cannot be centrally prevented from being created — only from being usable

There is no admin control to disable Copilot Studio agent *creation* org-wide. Microsoft's documented guidance is to govern usability via data policies (block the unauthenticated-chat connector, block all channel connectors, etc.) rather than expect a maker-creation kill switch. Setting client expectations here early avoids a ticket looping back as "but I asked you to stop people from making agents."

### App registrations, service principals, and federated identity

Every custom agent gets its own single-tenant Microsoft Entra ID app registration (agents created before this became default may still show multitenant registrations — not a security risk per Microsoft, just a historical artifact) plus an associated service principal using federated identity, created and managed by Copilot Studio to authenticate its own calls to Azure Bot Service. This app registration does not itself expose customer data — it exists purely for the Copilot Studio-to-Bot-Framework channel plumbing.

</details>

---

## Dependency Stack

```
Layer 6 — Audit & Compliance visibility
              (Microsoft Purview audit log search; optional Microsoft Sentinel
               forwarding for alerting/correlation on maker activity)
                                    ▲
Layer 5 — Data-at-rest protection
              (Customer-managed keys per environment; Customer Lockbox — EXCLUDES
               Agent 365 audit-log data export)
                                    ▲
Layer 4 — Agent-level Authentication configuration
              (No authentication / Authenticate with Microsoft / Authenticate manually
               — constrained by whichever data policy from Layer 3 applies)
                                    ▲
Layer 3 — Data (DLP) policies scoped to Copilot Studio connectors
              (mandatory enforcement since MC973179, early 2025; Business /
               Non-Business / Blocked classification per connector, per policy,
               per environment scope; optional endpoint filtering for SharePoint/
               public-website/HTTP connectors)
                                    ▲
Layer 2 — Tenant-level generative-AI controls
              ("Publish copilots with AI features" tenant toggle;
               cross-geo data movement toggle)
                                    ▲
Layer 1 — Power Platform environment
              (the environment an agent lives in; NOT covered here — see
               PowerApps/Environment-Dataverse-A.md for environment lifecycle)
```

Read top-down for "what stopped this from working" (highest layer first — audit gaps rarely block a publish, environment problems always do). Read bottom-up for "what do I need to configure before this agent is compliant."

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Publish blocked with an error banner, "Details" link present | A data policy blocks a connector the agent uses | Download the violation CSV from the Channels page error link; cross-reference `Get-AdminDlpPolicy` |
| A specific Copilot Studio feature "just stopped working" after a Microsoft update | New connector shipped into the default Non-Business classification, now blocked by an existing baseline policy | `Get-AdminDlpPolicy` → inspect `ConnectorGroups` for the new connector's classification |
| Agent works without any sign-in prompt, unexpectedly | Authentication set to No authentication, and no data policy currently requires auth | Agent Settings → Security → Authentication; check for a policy blocking the unauthenticated-chat connector |
| Agent authenticates fine in Teams but users can't sign in on the custom website/Direct Line channel | Authentication mode is **Authenticate with Microsoft**, which only supports Teams + M365 | Switch to **Authenticate manually** for non-Teams channels |
| Topic variables show as "Unknown" after an auth change | Switched from Authenticate manually to Authenticate with Microsoft while `User.AccessToken`/`User.IsLoggedIn` were still referenced | Topics page → fix flagged topics before republishing |
| Client asks why tenant isolation didn't stop a Copilot Studio cross-tenant behavior | Tenant isolation does not govern Copilot Studio by design | Confirm via data policy instead — no isolation-control gap to "fix" |
| Compliance wants proof of who published/edited an agent | Audit not yet checked, or caller lacks a Purview role | Purview portal → Audit search, filtered to Copilot Studio activity |
| Client wants conversation data encrypted with their own key | CMK not yet enabled for the environment | Power Platform admin center → environment → Customer-managed key |
| Agent surfaces content from a SharePoint site the user shouldn't see | NOT a data-policy issue — check sensitivity labels and the source item's actual permissions first | Confirm label/permission state on the SharePoint item, independent of DLP connector classification |

---

## Validation Steps

1. **Confirm the tenant-level generative-AI publish gate is on.**
   Power Platform admin center → **Settings → Product → Copilot Studio** → "Publish copilots with AI features."
   Good: enabled (or intentionally disabled with client sign-off). Bad: disabled without anyone realizing — every generative-AI agent in the tenant will fail to publish regardless of any other correct configuration.

2. **Enumerate active data policies and their scope.**
   ```powershell
   Get-AdminDlpPolicy | Select-Object DisplayName, CreatedTime, EnvironmentType
   ```
   Good: a manageable, documented set of policies with clear scope. Bad: overlapping tenant-wide and environment-specific policies with conflicting classifications for the same connector — Copilot Studio doesn't merge conflicting classifications gracefully; the most restrictive applicable classification wins in practice, so audit for contradictions before troubleshooting a specific block.

3. **Inspect a specific policy's connector classifications.**
   ```powershell
   (Get-AdminDlpPolicy -PolicyName '<PolicyName>').ConnectorGroups |
       Select-Object classification -ExpandProperty Connectors
   ```
   Good: Copilot Studio connectors are explicitly classified per admin intent. Bad: a Copilot Studio connector is absent from every explicit group — it has silently inherited the default (commonly Non-Business, commonly auto-blocked).

4. **Confirm agent-level authentication matches policy intent.**
   In Copilot Studio: agent → **Settings → Security → Authentication**.
   Good: matches what the data policy allows/requires. Bad: **Authenticate manually** is greyed out/locked — this happens when an admin control in Power Platform has pinned "Authenticate manually" as always-on, which is itself a valid governance state, not a bug.

5. **Confirm CMK status if compliance requires customer-owned encryption.**
   Power Platform admin center → environment → **Customer-managed key**.
   Good: status matches the compliance requirement (On with the correct Key Vault key, or explicitly Off with sign-off). Bad: assumed-on but never actually configured — a common audit-finding gap.

6. **Pull recent Purview audit activity for the agent/environment in question.**
   `purview.microsoft.com` → Audit → filter by Copilot Studio-related activities (create, edit, publish, co-owner change) within the relevant date range.
   Good: a complete activity trail matching what the ticket describes. Bad: gaps — confirm the caller's Purview role first (Audit Reader/Compliance Administrator) before concluding logging itself is broken; a permissions gap on the *reader* side is far more common than a genuine logging gap.

---

## Troubleshooting Steps (by phase)

### Phase 1: Publish/Feature Blocked
Confirm tenant-level toggle (Validation 1) → confirm applicable data policies and scope (Validation 2) → download the violation CSV from the in-product error banner and match it to a specific connector/policy (Validation 3).

### Phase 2: Authentication Behaving Unexpectedly
Confirm current agent authentication mode and whether a data policy constrains the available options (Validation 4) → confirm the agent has actually been republished since the last authentication change → if switching modes, check the Topics page for variables now flagged Unknown.

### Phase 3: Knowledge-Source / Data-Exfiltration Concerns
Confirm which knowledge-source connectors are blocked vs. endpoint-filtered vs. fully open → separately confirm sensitivity-label behavior on the underlying SharePoint content, since this is enforced independently of DLP connector state → don't conflate "site is an approved knowledge source" with "user can see everything in it."

### Phase 4: Compliance / Encryption / Audit Requests
Confirm CMK state (Validation 5) → confirm Customer Lockbox scope understanding (excludes Agent 365 audit export data — set this expectation explicitly with compliance stakeholders) → pull Purview audit trail (Validation 6) → if Sentinel forwarding is expected, confirm the relevant data connector is actually enabled rather than assuming silence means "no activity."

### Phase 5: "This Used to Work" After a Microsoft Feature Update
Assume a newly shipped Copilot Studio connector landed in the default Non-Business classification and is now caught by an existing baseline "block Non-Business" policy before investigating anything else — this is overwhelmingly the most common root cause for this specific symptom pattern.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Baseline governance rollout for a new Copilot Studio deployment</summary>

Use when a client is adopting Copilot Studio and has no existing data policy coverage for it.

1. Confirm the tenant-level "Publish copilots with AI features" toggle matches the rollout plan (on for a phased rollout, off if piloting in one environment only with the toggle scoped appropriately).
2. Create a dedicated data policy scoped to the target environment(s) (not tenant-wide, for a controlled pilot).
3. Block `Chat without Microsoft Entra ID authentication in Copilot Studio` to force every published agent to require authentication from day one — retrofitting this after agents are already live in production is a much harder conversation.
4. Explicitly classify the knowledge-source connectors (SharePoint/OneDrive, public websites, documents) rather than leaving them on the default — decide Business/Non-Business/Blocked deliberately, and add endpoint filtering for public websites if any are permitted at all.
5. Explicitly classify channel connectors to match the intended publish surface (e.g., allow Teams + M365 only for an internal pilot; block Direct Line/public-facing channels until the pilot graduates).
6. Document the policy's scope and classifications in the client's runbook/knowledge base — this is the artifact that prevents "we don't know why this connector is blocked" six months later.

**Rollback:** Data policies can be deleted or their scope reduced at any time without affecting already-created agent content; only future publish attempts are affected.

</details>

<details><summary>Playbook 2 — Retrofitting authentication enforcement onto an existing, already-live Copilot Studio deployment</summary>

Use when agents are already published without a consistent authentication requirement and the client now wants to enforce it.

1. Inventory currently published agents and their authentication mode — no single admin cmdlet enumerates this directly; use the Copilot Studio maker portal per environment, or the CoE Starter Kit's Power BI dashboard if deployed, to build the inventory.
2. For each agent that needs to move off **No authentication**: switch to **Authenticate with Microsoft** (if Teams-only is acceptable) or **Authenticate manually** (if other channels are in play), fix any Topics flagged with newly-Unknown variables, and republish.
3. Only *after* every in-scope agent has been individually remediated, apply the tenant/environment-scoped data policy blocking the unauthenticated-chat connector — applying the policy first will surface as a hard publish-block on every agent still mid-remediation, which is disruptive if makers aren't expecting it.
4. Communicate the cutover date to agent makers in advance; a maker who tries to republish an unremediated agent after the policy is live will hit an unexplained block without this context.

**Rollback:** Removing the policy block restores the ability to publish with No authentication; it does not retroactively re-enable No authentication on agents already switched to a different mode (that is a maker-side change, not a policy-side one).

</details>

<details><summary>Playbook 3 — Enabling CMK for a compliance-driven environment</summary>

1. Confirm (or provision) a Key Vault and key meeting the client's compliance requirement, and grant the Power Platform CMK service principal the necessary Key Vault access per current Microsoft guidance — verify the exact permission set against the live Power Platform CMK documentation before executing, since Key Vault access-model requirements are the most likely detail to have shifted since any cached guidance.
2. In the Power Platform admin center, select the target environment → **Customer-managed key** → follow the enable workflow, selecting the Key Vault key.
3. Confirm status reflects "enabled" and validate with the client's compliance owner that this satisfies their specific requirement (some frameworks require key rotation cadence evidence, which is a client-side Key Vault policy, not a Copilot Studio setting).
4. Document the Key Vault/key identity used, since key rotation and potential future key-revocation procedures depend on this being findable later without re-deriving it from scratch.

**Rollback:** CMK can be turned off per environment, reverting to Microsoft-managed encryption. Confirm with the client whether "off" needs to be accompanied by evidence of prior encrypted-data handling for their audit trail — that's a client compliance-process question, not a technical one.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Copilot Studio-relevant data policy and environment governance evidence for escalation.
.DESCRIPTION
    Read-only. Requires Microsoft.PowerApps.Administration.PowerShell, connected via
    Add-PowerAppsAccount as a Power Platform Administrator or Environment Admin.
#>
$OutputPath = "$env:TEMP\CopilotStudioSecurityEvidence_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

$policies = Get-AdminDlpPolicy
$rows = foreach ($policy in $policies) {
    $full = Get-AdminDlpPolicy -PolicyName $policy.PolicyName
    foreach ($group in $full.ConnectorGroups) {
        foreach ($connector in $group.Connectors) {
            if ($connector.name -match 'copilotstudio|shared_dlp|CopilotStudio') {
                [pscustomobject]@{
                    PolicyName          = $policy.DisplayName
                    PolicyScope         = $policy.EnvironmentType
                    ConnectorName       = $connector.name
                    ConnectorFriendly   = $connector.id
                    Classification      = $group.classification
                }
            }
        }
    }
}

$rows | Export-Csv -Path $OutputPath -NoTypeInformation
Write-Host "Evidence written to $OutputPath" -ForegroundColor Green
Write-Host "Attach to ticket along with: Copilot Studio publish-error violation CSV (from the in-product error banner), and a Purview audit search export scoped to the affected agent/environment." -ForegroundColor Cyan
```

---

## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Add-PowerAppsAccount` | Authenticate the admin PowerShell session |
| `Get-AdminDlpPolicy` | List all data policies in the tenant with scope |
| `Get-AdminDlpPolicy -PolicyName '<name>'` | Full detail of one policy, including `ConnectorGroups` |
| `Get-DlpPolicy` | Retrieve policy objects for the signed-in admin's accessible scope |
| `New-DlpPolicy` | Create a new data policy (supports `-DefaultConnectorClassification`) |
| `Set-DlpPolicy` | Update policy metadata (e.g., display name) |
| `Set-PowerAppDlpPolicyConnectorConfigurations` | Update per-connector configuration (e.g., endpoint filtering) within a policy |
| `Set-PowerAppDlpErrorSettings` / `New-PowerAppDlpErrorSettings` | Configure the admin contact email / "Learn more" link shown in data-policy violation error messages tenant-wide |
| `Get-AdminPowerAppEnvironment` | Confirm environment identity/type before scoping a policy or CMK change |
| Portal: Power Platform admin center → **Settings → Product → Copilot Studio** | Tenant-level generative-AI publish toggle, cross-geo data movement toggle |
| Portal: Power Platform admin center → **Security → Data and privacy → Data policy** | Create/edit data policies |
| Portal: environment → **Customer-managed key** | Enable/disable/rotate CMK |
| Portal: Copilot Studio agent → **Settings → Security → Authentication** | Per-agent authentication mode |
| Portal: `purview.microsoft.com` → **Audit** | Maker activity audit trail |

---

## 🎓 Learning Pointers

- Data policy enforcement for Copilot Studio became mandatory tenant-wide in early 2025 (message center **MC973179**) — there is no longer a per-agent enforcement exemption, which changes how you should read any client documentation written before that date. See [Configure data policies for agents](https://learn.microsoft.com/en-us/microsoft-copilot-studio/admin-data-loss-prevention).
- The full security-and-governance control inventory (agent runtime protection status, maker security warnings, environment routing, maker welcome messages) is broader than DLP + authentication alone — worth a full read before a client's first Copilot Studio security review. See [Security and governance - Microsoft Copilot Studio](https://learn.microsoft.com/en-us/microsoft-copilot-studio/security-and-governance).
- Authentication mode selection has real functional consequences beyond "is it secured" — Authenticate with Microsoft trades broader channel support for zero-config simplicity, and only manual authentication exposes an access token for downstream API calls. See [Configure user authentication in Copilot Studio](https://learn.microsoft.com/en-us/microsoft-copilot-studio/configuration-end-user-authentication).
- Tenant isolation, a control many admins assume is universal across Power Platform, explicitly does not extend to Copilot Studio — a documented product boundary worth surfacing proactively to security-conscious clients rather than waiting for them to discover it. See [Security FAQs - Microsoft Copilot Studio](https://learn.microsoft.com/en-us/microsoft-copilot-studio/security-faq).
- The Center of Excellence (CoE) Starter Kit's Power BI dashboard is the most practical way to inventory Copilot Studio agents and their governance-relevant attributes at scale — no single admin cmdlet substitutes for it today. See [Power BI dashboard for the CoE Starter Kit](https://learn.microsoft.com/en-us/power-platform/guidance/coe/power-bi).
- Cross-reference `M365/Copilot/AgentGovernance-A.md` for the layer *above* this one — the Microsoft 365 Agent Registry/Agent 365 lifecycle governance that spans Copilot Studio and every other agent-creation platform. This runbook is the security configuration of one agent; that one is the inventory/approval/ownership control plane across all of them.
