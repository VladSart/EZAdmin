# Teams Office 365 Connectors Retirement → Workflows Webhooks — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

**Scope:** Channel/chat notifications that used **Office 365 Connectors** in Microsoft Teams (Incoming Webhook, third-party connectors, RSS) and their replacement, **Workflows (Power Automate) webhooks**. Connectors were permanently disabled **18–22 May 2026** (Message Center **MC1181996**, Microsoft 365 Developer Blog update 14 Apr 2026). There is **no re-enable**. Anything still posting to a `*.webhook.office.com` URL today silently fails.
Related: Power Platform governance → `PowerAutomate/_AGENT.md`; Teams app availability → `UnifiedAppAgentManagement-B.md`.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [🎓 Learning Pointers](#-learning-pointers)

---
## Triage

Typical tickets: *"monitoring/CI/backup alerts stopped appearing in the channel back in May"* (often noticed months later), *"new webhook returns 202 but nothing posts"*, *"401 Unauthorized from the new URL"*, *"alerts stopped when Dave left"*, *"cards say '<name> used a Workflow template to send this card'"*.

```powershell
# 1. What URL is the sender actually calling? (ask for it, or grep the script/config — see Find-LegacyTeamsWebhookUrl.ps1)
$u = '<webhook-url-from-sender>'
switch -Regex ($u) {
  'webhook\.office\.com|outlook\.office(365)?\.com/webhook' { 'LEGACY Office 365 Connector URL - retired May 2026, will never work again' }
  'logic\.azure\.com'                                      { 'Workflows URL (Logic Apps-hosted, SAS sig in query)' }
  'environment\.api\.powerplatform\.com'                   { 'Workflows URL (Power Platform-hosted)' }
  default                                                  { 'Unknown - not a Teams webhook' }
}

# 2. Post a minimal test card to the NEW URL (this WILL post a message to the channel)
$body = @{
  type        = 'message'
  attachments = @(@{
    contentType = 'application/vnd.microsoft.card.adaptive'
    contentUrl  = $null
    content     = @{ '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'; type = 'AdaptiveCard'; version = '1.4'
                     body = @(@{ type = 'TextBlock'; text = "Webhook test $(Get-Date -Format s)"; wrap = $true }) }
  })
} | ConvertTo-Json -Depth 10
Invoke-WebRequest -Uri $u -Method Post -ContentType 'application/json' -Body $body -UseBasicParsing | Select-Object StatusCode
```

| Result | Meaning | Action |
|---|---|---|
| Step 1 = LEGACY URL | Connector retired; sender was never migrated | → Fix 1 (create Workflows webhook, swap URL) |
| `202 Accepted` but no message in channel | Flow **triggered** and then failed inside (payload shape, connection, channel access) | → Fix 2 (check run history) |
| `401 Unauthorized` | Trigger "Who can trigger the flow?" isn't **Anyone**, or URL is missing its `sig=` parameter (copied/truncated) | → Fix 3 |
| `404 Not Found` | Flow deleted, or URL regenerated (e.g. flow copied/"Save as") | Recreate/recopy URL → Fix 1 |
| `400/403` mentioning DLP / policy | Power Platform DLP blocks the Teams connector/trigger in that environment | → Fix 4 |
| Worked, then stopped when a person left | Flow's connection runs as the creator; their account disabled/unlicensed | → Fix 5 |
| Posts but shows Flow bot + "used a Workflow template" footer | By design for template flows; no custom bot name/icon for webhooks | → Fix 6 (cosmetic) |
| MessageCard with buttons renders without buttons | By design — MessageCard payloads render, **no** interactive actions | → Fix 2b (convert to Adaptive Card) |

---
## Dependency Cascade

<details><summary>What must be true for a Workflows webhook to land a card in Teams</summary>

```
[Sender] HTTPS POST to the Workflows trigger URL (NOT *.webhook.office.com)
  └─ [Trigger] "When a Teams webhook request is received"
       ├─ Who can trigger: Anyone (URL sig = the secret) | Any user in tenant / Specific users (caller must send Entra OAuth token)
       └─ Flow ON, not suspended; environment not blocked by DLP
            └─ [Payload] JSON the flow's actions expect
                 ├─ Template flow: { "type":"message", "attachments":[ { "contentType":"application/vnd.microsoft.card.adaptive", "content":{AdaptiveCard} } ] }
                 └─ MessageCard (@type MessageCard) accepted since 2026 — renders, no buttons
                      └─ [Action] "Post card in a chat or channel" via the Teams connection
                           ├─ Connection owner account enabled + licensed (Teams, Power Automate use rights)
                           ├─ Poster = Flow bot (or User) — must be able to post in the target channel
                           │    (shared channels supported; private channels via PA portal / Workflows app since Apr 2026)
                           └─ Workflows app not blocked for the owner in Teams app policies
```
</details>

---
## Diagnosis & Validation Flow

1. **Get the URL the sender uses** (script, app config, monitoring tool). Classify it with Triage step 1.
   Expected after migration: `logic.azure.com` or `environment.api.powerplatform.com`. Anything `webhook.office.com` = not migrated.

2. **Find the flow.** In Teams: channel **…** → **Workflows** → *Manage* (lists workflows on that channel). Or [make.powerautomate.com](https://make.powerautomate.com) → **My flows** (as the owner). Admins: see Fix 5 for tenant-wide lookup.
   Expected: flow **On**, recent runs listed.

3. **Send the test card** (Triage step 2) and open the flow's **28-day run history**.
   - No run appears → the request never reached the trigger (wrong URL, 401/404, DLP).
   - Run **Failed** → open the failed action: typical errors are `Property 'attachments' doesn't exist` / `The template language expression ... cannot be evaluated` (payload shape) or `Forbidden`/`Unauthorized` on *Post card* (connection/channel access).
   - Run **Succeeded** but nothing visible → wrong team/channel selected in the action, or posting as a user who isn't a channel member.

4. **Validate:** the test card appears in the channel within ~1 minute, and the real sender's next alert appears.

---
## Common Fix Paths

<details><summary>Fix 1 — Replace a retired connector URL with a Workflows webhook</summary>

1. In the target channel: **…** → **Workflows** → search **"Send webhook alerts to a channel"** (template may also appear as *"Post to a channel when a webhook request is received"*).
2. Name it meaningfully (e.g. `ALERT-Zabbix-to-NOC-channel`), confirm Team/Channel, **Add workflow**, copy the URL.
3. Replace the old URL in the sender. Keep the old payload first — Workflows accepts **Adaptive Card envelope** and **MessageCard** JSON.
4. Run Triage step 2, then trigger a real alert.
**Rollback:** none needed — the old URL is dead either way. Create the flow under a **service account** (Fix 5) rather than a person where possible.
</details>

<details><summary>Fix 2 — 202 Accepted but nothing posts (payload / action failure)</summary>

a) **Adaptive Card sent "bare"** (old incoming-webhook habit): the template flow loops over `attachments` and fails. Wrap it:
```json
{ "type": "message",
  "attachments": [ { "contentType": "application/vnd.microsoft.card.adaptive", "contentUrl": null,
                     "content": { "type": "AdaptiveCard", "version": "1.4", "body": [ { "type": "TextBlock", "text": "Hello" } ] } } ] }
```
b) **MessageCard with `potentialAction` buttons**: content renders, buttons don't — by design. For interactivity, convert to an Adaptive Card and extend the flow to handle the response.
c) **Plain text / Slack-style `{"text":"..."}`**: the template won't render it. Either change the sender to the envelope above, or edit the flow (PA portal) to build a card from `triggerBody()?['text']`.
d) Check `Post card` action → correct Team/Channel; poster = **Flow bot** for channels.
</details>

<details><summary>Fix 3 — 401 Unauthorized</summary>

1. Open the flow in the PA portal → trigger **When a Teams webhook request is received** → **Who can trigger the flow?**
   - **Anyone**: URL must include its full query string (`...&sig=...`). Recopy the whole URL — ticketing tools and YAML often truncate at `&`.
   - **Any user in my tenant / Specific users**: the caller must present an Entra OAuth bearer token. Most monitoring tools can't — switch to **Anyone** and protect the URL (store as a secret; optional trigger-condition header check, see A runbook Playbook 3).
2. Community reports note that some environments issue `environment.api.powerplatform.com` URLs that return 401 without a token; if recopying with *Anyone* still fails, test from the PA portal and escalate with the evidence below (unverified against official docs as of Sept 2026).
**Rollback:** revert the trigger setting.
</details>

<details><summary>Fix 4 — Blocked by Power Platform DLP</summary>

The flow lives in the creator's (usually **Default**) environment. If a DLP policy puts the **Microsoft Teams** connector in *Blocked*, or splits Teams and another connector the flow uses across Business/Non-business groups, the flow is suspended.
- Power Platform admin center → **Security → Data and privacy → Data policy** → policies covering the environment. Identify the conflicting connector.
- Preferred fix: host alerting flows in a dedicated, governed environment whose policy allows Teams, owned by a service account (see `PowerAutomate/_AGENT.md`).
**Rollback:** revert the policy edit; changes affect every flow in scope — test in a non-default environment first.
</details>

<details><summary>Fix 5 — Alerts stopped because the flow owner left</summary>

```powershell
# Admin (Power Platform admin): Microsoft.PowerApps.Administration.PowerShell
Add-PowerAppsAccount
Get-AdminPowerAppEnvironment | Select-Object EnvironmentName, DisplayName, IsDefault
Get-AdminFlow -EnvironmentName <EnvironmentName> |
  Where-Object DisplayName -match '<part-of-flow-name>' |
  Select-Object DisplayName, FlowName, Enabled, CreatedBy, LastModifiedTime
# Add a service account as co-owner, then have it re-create the connection
Set-AdminFlowOwnerRole -EnvironmentName <EnvironmentName> -FlowName <FlowName> -PrincipalType User -PrincipalObjectId <ServiceAccountObjectId> -RoleName CanEdit
```
Then, as the service account, open the flow → fix the Teams connection → turn **On**. If the flow was deleted with the user, recreate it (Fix 1) — the URL **will change**; update the sender.
**Rollback:** `Remove-AdminFlowOwnerRole -EnvironmentName <env> -FlowName <flow> -RoleId <roleId>`.
</details>

<details><summary>Fix 6 — Footer "<name> used a Workflow template to send this card" / bot identity</summary>

Open the flow in the PA portal → **Save as** a copy (custom flow, no footer) → use the **new** URL in the sender → delete the original. Custom bot names/icons are **not** supported for webhook posts (MC1181996 known limitation).
</details>

---
## Escalation Evidence

```
Ticket: Teams channel notifications missing — Connectors retirement / Workflows webhook
Sender (tool/script, host):          <name> on <host>
URL type (legacy / logic.azure.com / powerplatform.com): <type>   (DO NOT paste the full URL — it is a secret)
Target team / channel (type std/shared/private): <team> / <channel> / <type>
Flow name / owner / environment:     <flow> / <UPN> / <env>
Trigger "Who can trigger":           <Anyone | tenant | specific>
Test POST status code:               <202/401/404/...> at <UTC time>
Run history result + failing action + error text: <...>
DLP policy covering environment:     <policy name / none>
Payload format (Adaptive envelope / MessageCard / other): <...>
Changes made + rollback status:      <...>
```

---
## 🎓 Learning Pointers

- **Connectors are gone for good (18–22 May 2026) — there's no switch to look for.** The full timeline and known limitations (no bot icon/name, no MessageCard buttons) are in the [Microsoft 365 Developer Blog retirement post](https://devblogs.microsoft.com/microsoft365dev/retirement-of-office-365-connectors-within-microsoft-teams/) and [MC1181996](https://mc.merill.net/message/MC1181996).
- **202 ≠ delivered.** A Workflows webhook acknowledges the *trigger*; delivery happens in later flow actions. Always read run history — that's where the real error is.
- **The URL is the credential** when the trigger is set to *Anyone*. Treat it like a password — Tony Redmond's retirement write-up started with a repo scanner flagging an embedded webhook: [Office365ITPros — Replacing Retired Office 365 Connectors with Teams Workflows](https://office365itpros.com/2026/09/18/teams-workflows-updates/).
- **Payload shape trips most migrations** — the template expects the `type: message` + `attachments[]` envelope. Martin Heusser's walkthrough covers both that and a custom "bare card" flow: [Migrate Teams Incoming Webhooks to Workflows](https://heusser.pro/p/migrate-teams-office-365-connectors-to-workflows-8p40yq7jfebm/).
- **Workflows = Power Automate**, so owner lifecycle, DLP and environments now matter for something that used to be a static URL. Design for a service-account owner from day one.
- Deep dive and scanner: `ConnectorsToWorkflows-A.md`, `Scripts/Find-LegacyTeamsWebhookUrl.ps1`.
