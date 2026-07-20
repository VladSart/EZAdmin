# Copilot Studio Security & Governance — Hotfix Runbook (Mode B: Ops)
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

Run these against the **Power Platform admin center** (`admin.powerplatform.microsoft.com`) and the `Microsoft.PowerApps.Administration.PowerShell` module (`Add-PowerAppsAccount` first) to place the ticket in under a minute.

```powershell
# 1. Is the agent published to a channel it shouldn't be able to reach?
Get-DlpPolicy | Select-Object DisplayName, EnvironmentType

# 2. Which data policies (DLP) apply to the environment the agent lives in?
Get-AdminDlpPolicy | Where-Object { $_.EnvironmentName -contains '<EnvironmentId>' -or $_.EnvironmentType -eq 'AllEnvironments' }

# 3. Is "Chat without Microsoft Entra ID authentication in Copilot Studio" blocked or allowed for this environment?
(Get-AdminDlpPolicy -PolicyName '<PolicyName>').ConnectorGroups |
    Where-Object { $_.Connectors.name -match 'shared_dlp_copilotstudio' -or $_.classification -in @('Business','NonBusiness','Blocked') }

# 4. Tenant-level: is generative-AI agent publishing turned off entirely for the tenant?
#    (Power Platform admin center → Settings → Product → Copilot Studio "Publish copilots with AI features")
#    No dedicated read cmdlet as of this writing — verify in the portal (see Diagnosis step 1).

# 5. Confirm the caller's admin role can even see/change the setting in question
Get-AdminPowerAppEnvironment -EnvironmentName '<EnvironmentId>' | Select-Object DisplayName, EnvironmentType, IsDefault
```

| Symptom in the ticket | Likely cause | Do this |
|---|---|---|
| "Publish" button greyed out / blocked with an error banner | A data (DLP) policy is blocking a connector the agent uses | [Fix 1](#fix-1) — identify the blocking connector from the error details file |
| Agent works with no login prompt at all, and it shouldn't | Agent authentication is set to **No authentication**, or the tenant has no auth-enforcing data policy | [Fix 2](#fix-2) |
| Client wants a specific channel (WhatsApp, Facebook, Direct Line/custom website) turned off org-wide | No data policy currently blocks that channel's connector | [Fix 3](#fix-3) |
| "Our agent maker can see a knowledge source we didn't approve" (public website, arbitrary SharePoint site) | No data policy restricting knowledge-source connectors, or no endpoint filtering configured | [Fix 4](#fix-4) |
| Compliance asks "can we encrypt Copilot Studio conversation data with our own key?" | Customer-managed key (CMK) not yet enabled for the environment | [Fix 5](#fix-5) |
| "Who published/changed this agent?" audit request | Purview audit log not yet checked, or caller lacks Compliance/Audit reader role | [Fix 6](#fix-6) |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Power Platform tenant
  └── Tenant-level Copilot Studio settings (Power Platform admin center → Settings → Product)
        ├── "Publish copilots with AI features" — must be ON for any generative-AI agent to publish at all
        └── "Allow data movement across geographic locations" — governs cross-geo grounding
  └── Environment (Dataverse-backed or not)
        └── Data (DLP) policy scope — Tenant-wide OR specific-environments OR exclude-environments
              └── Connector classification per data policy: Business / Non-Business / Blocked
                    ├── "Chat without Microsoft Entra ID authentication in Copilot Studio" connector
                    │     → if Blocked: agent maker CANNOT publish with "No authentication"
                    ├── Knowledge-source connectors (SharePoint/OneDrive, public websites, documents)
                    │     → if Blocked: agent maker cannot add that knowledge-source type
                    │     → optionally narrowed further by endpoint filtering (allow/deny specific URLs)
                    ├── Channel connectors (Teams+M365, Direct Line, Facebook, Omnichannel,
                    │     SharePoint channel, WhatsApp)
                    │     → if Blocked: agent maker cannot publish to that channel
                    ├── HTTP connector → if Blocked: HTTP Request node cannot be published
                    │     (or narrowed via endpoint filtering instead of a full block)
                    ├── Skills with Copilot Studio connector → if Blocked: skills cannot be added
                    └── Microsoft Copilot Studio connector → if Blocked: event triggers/automated
                          evaluations using an authenticated account are blocked
        └── Agent-level Authentication setting (Settings → Security → Authentication)
              ├── No authentication — only if no data policy requires auth
              ├── Authenticate with Microsoft — Teams + M365 channel only, always requires sign-in
              └── Authenticate manually — Entra ID / Entra ID v2 (cert/secret/federated) / Generic OAuth2
        └── Customer-managed key (CMK) — optional, encrypts Copilot Studio data at rest with a
              customer Key Vault key; configured per environment via Power Platform admin center
        └── Purview audit logging — captures maker actions (create/edit/publish/co-owner changes);
              requires the caller to have a Purview role (Audit Reader/Compliance Administrator etc.)
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm whether the block is tenant-level or a specific data policy.**
   In the Power Platform admin center, go to **Settings → Product → Copilot Studio**. Confirm "Publish copilots with AI features" is on. Then go to **Security → Data and privacy → Data policy** and check which policies scope to the agent's environment.
   Good: exactly the policies you expect apply, with the classifications you expect. Bad: an unexpected tenant-wide policy is silently blocking a connector nobody remembers creating a rule for.

2. **Reproduce the block and pull the error details file.**
   In Copilot Studio, open the agent, attempt **Publish**. If a data policy blocks something, an error banner with a **Details** button appears. On the **Channels** page, expand the error link and select **Download** — the CSV lists one row per violation (which connector, which policy).
   Good: the CSV names the exact connector and policy. Bad: no error appears but publish still silently fails — check the environment's own maker permissions instead (this is not a data-policy issue).

3. **Cross-check the connector's classification group.**
   `Get-AdminDlpPolicy -PolicyName '<PolicyName>' | Select-Object -ExpandProperty ConnectorGroups`
   Good: the connector sits in the classification group (Business/Non-Business/Blocked) the admin intended. Bad: the connector landed in the default group (commonly **Non-Business**, which many tenants auto-block) because nobody explicitly classified a newer Copilot Studio connector after it shipped — this is the single most common cause of "this used to work" tickets after a Microsoft feature update introduces a new connector.

4. **Confirm data groups match across the policy.**
   Connectors in a single data policy must share a data group to interact — if the knowledge-source connector and the HTTP connector are in different groups, the agent can't pass data between them even without an explicit block. Check both connectors' groups side by side before concluding "block" is the root cause.

---
## Common Fix Paths

<details><summary>Fix 1 — Publish blocked by a data policy: find and adjust the blocking connector</summary>

1. Download the violation details CSV from the Copilot Studio error banner (Diagnosis step 2).
2. In the Power Platform admin center, open the named data policy → **Edit Policy** → **Assign connectors**.
3. Search for the flagged connector, select the three dots (⋮), and either:
   - **Reclassify** it into the same data group as the agent's other in-use connectors, or
   - **Configure connector → Connector endpoints** to allow the specific SharePoint/public-website/HTTP endpoint instead of a full block (available for SharePoint/OneDrive knowledge source, public-website knowledge source, and HTTP connectors only).
4. Save, then go back to Copilot Studio and re-attempt **Publish**.

**Rollback:** Revert the connector's classification/endpoint list to its prior value in the same policy edit screen — no data is altered, this is a policy-metadata change only.

</details>

<details><summary>Fix 2 — Agent has no authentication and shouldn't</summary>

1. Confirm this is actually unwanted — some agents (public FAQ bots) are legitimately unauthenticated by design; check the ticket intent first.
2. If authentication should be required tenant-wide or environment-wide going forward: create/edit a data policy and **Block** the connector **"Chat without Microsoft Entra ID authentication in Copilot Studio"**. This prevents *new* publishes without auth — existing published agents are not retroactively unpublished, so also open the specific agent.
3. For the specific agent: **Settings → Security → Authentication** → choose **Authenticate with Microsoft** (Teams + M365 only, zero-config) or **Authenticate manually** (any other channel, requires an app registration/OAuth2 provider).
4. Turn on **Require users to sign in** if the agent should gate every topic behind auth rather than only auth-tagged topics.
5. Publish. Note: authentication changes only take effect after publish — don't consider the fix applied until the agent has been republished.

**Rollback:** Switching back to **No authentication** is available unless a data policy now blocks it (which is the point of step 2).

</details>

<details><summary>Fix 3 — Block or allow a specific publishing channel org-wide</summary>

1. Edit the relevant data policy → **Assign connectors**.
2. Block the channel-specific connector: `Microsoft Teams + M365 Channel in Copilot Studio`, `Direct Line channels in Copilot Studio` (covers Demo website, custom websites, mobile app), `Facebook channel in Copilot Studio`, `Omnichannel in Copilot Studio` (Dynamics 365 Customer Service), `SharePoint channel in Copilot Studio`, or `WhatsApp channel in Copilot Studio`.
3. Save and confirm scope (tenant-wide vs. specific environments) matches intent.

**Note:** if an admin blocks *every* channel connector, agents in that environment simply cannot be published anywhere — this is sometimes used deliberately as a "development only, no publish" environment control.

**Rollback:** Remove the block from the connector in the same policy.

</details>

<details><summary>Fix 4 — Restrict or scope knowledge sources</summary>

1. To fully block a knowledge-source type: block one or more of `Knowledge source with SharePoint and OneDrive in Copilot Studio`, `Knowledge source with public websites and data in Copilot Studio`, `Knowledge source with documents in Copilot Studio` in the data policy.
2. To allow the type but restrict *which* sites/URLs: instead of blocking, select **Configure connector → Connector endpoints** on the SharePoint or public-website connector and add explicit allow/deny endpoint patterns.
3. Remember sensitivity labels on SharePoint sources still apply independently — Copilot Studio surfaces the highest sensitivity label present in a generative answer and tailors responses to the querying user's own permissions, so a blocked/unblocked knowledge source is a separate control from label-based oversharing protection.

**Rollback:** Remove the connector block or clear the endpoint list.

</details>

<details><summary>Fix 5 — Enable customer-managed key (CMK) for conversation data at rest</summary>

1. Confirm a Key Vault with an appropriate key already exists and Power Platform's service principal has been granted access (this is a Power Platform-wide CMK mechanism, not Copilot Studio-specific setup).
2. Power Platform admin center → select the environment → **Customer-managed key** → follow the enable workflow, pointing at the Key Vault key.
3. Once turned on, all Copilot Studio data for that environment is encrypted with the customer key. Key rotation and key revocation are handled the same way as any other Power Platform CMK-protected data.

**Rollback:** CMK can be turned off per environment, reverting to Microsoft-managed encryption — this is a metadata change on the encryption wrapper, not a re-encryption of existing data in place, so validate current Microsoft guidance before promising an instant rollback to a client under audit pressure.

</details>

<details><summary>Fix 6 — Pull the audit trail for "who published/changed this agent"</summary>

1. Sign in to the **Microsoft Purview portal** (`purview.microsoft.com`) with an account holding Audit Reader/Compliance Administrator (or equivalent).
2. Use **Audit** search, filter by workload/activity related to Copilot Studio (agent create, edit, publish, co-owner change).
3. If the tenant also forwards to **Microsoft Sentinel**, the same events are queryable there for alerting/correlation — confirm the connector/data connector for Copilot Studio activity is actually enabled before assuming an absence of events means nothing happened.
4. If required audit fields/events aren't present, this is a known product-idea gap — escalate via the Copilot Studio feature-request channel rather than treating it as a misconfiguration on the tenant side.

</details>

---
## Escalation Evidence

```
Ticket: <ticket number>
Tenant: <tenant name / GUID>
Environment: <environment display name / GUID>
Agent name: <agent display name>
Reported symptom: <what the client/user reported>

Data policy(ies) in scope: <policy name(s)>
Data policy scope: <tenant-wide / specific environments / exclude list>
Blocking connector (from violation CSV, if applicable): <connector name>
Connector's current classification: <Business / Non-Business / Blocked>
Agent authentication setting: <No authentication / Authenticate with Microsoft / Authenticate manually — provider>
"Require users to sign in": <On / Off>
Tenant-level "Publish copilots with AI features": <On / Off>
CMK status for environment: <On / Off / N/A>
Screenshot of publish error banner + downloaded violation CSV attached: <Y/N>
Caller's admin role: <Power Platform Administrator / Environment Admin / other>
Actions already attempted: <list>
```

---
## 🎓 Learning Pointers

- Data policy enforcement for Copilot Studio agents became mandatory tenant-wide in early 2025 (message center **MC973179**) — the old "exempt this agent from data policy" escape hatch no longer exists, so a ticket that says "this always worked before" is almost always a newly-created or newly-reclassified connector landing in a blocking group, not a regression in Copilot Studio itself. See [Configure data policies for agents](https://learn.microsoft.com/en-us/microsoft-copilot-studio/admin-data-loss-prevention).
- New Copilot Studio connectors default into the **Non-Business** classification group unless an admin explicitly reclassifies them — this is the root cause behind the majority of "a feature just stopped working after a Microsoft update" tickets. Check [default data group for new connectors](https://learn.microsoft.com/en-us/power-platform/admin/dlp-connector-classification#default-data-group-for-new-connectors) whenever a previously-working agent suddenly can't publish.
- Endpoint filtering (allow/deny specific SharePoint sites, public websites, or HTTP endpoints) is a *narrower* alternative to a full connector block — use it when the client wants "some sites but not others," not a blanket policy edit. See [connector endpoint filtering](https://learn.microsoft.com/en-us/power-platform/admin/connector-endpoint-filtering).
- Authentication changes in Copilot Studio only take effect after the agent is republished — a common "I fixed it but it's still broken" ticket is simply a missing publish step.
- You cannot disable Copilot Studio agent *creation* org-wide — Microsoft's documented guidance is to govern via data policies (blocking chat/publish), not to expect a maker-creation kill switch. See [Security FAQs](https://learn.microsoft.com/en-us/microsoft-copilot-studio/security-faq).
- This is distinct from `M365/Copilot/AgentGovernance-B.md` — that runbook covers the cross-platform Microsoft 365 **Agent Registry/Agent 365** lifecycle (approve/reject/publish/ownership across *all* agent-creation platforms). This runbook covers Copilot Studio's *own* security surface (DLP data policies, per-agent authentication, CMK, audit). A Copilot Studio agent can be fully compliant here and still be pending review in the Agent Registry, or vice versa — check both when a governance ticket spans "is this agent allowed to exist" vs. "is this agent's own security configuration correct."
