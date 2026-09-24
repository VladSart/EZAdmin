# Teams Office 365 Connectors Retirement → Workflows Webhooks — Reference Runbook (Mode A: Deep Dive)
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

- **In scope:** the replacement of Office 365 Connectors in Teams (Incoming Webhook, third-party connectors such as Azure DevOps/Jira/Zabbix/etc., RSS) with **Workflows** — Power Automate flows created from Teams or the Power Automate portal, primarily using the **When a Teams webhook request is received** trigger and the **Post card in a chat or channel** action.
- **Status (Sept 2026):** retirement is **complete**. Final rollout 18–22 May 2026 (MC1181996 v3, 15 Apr 2026; Microsoft 365 Developer Blog update 14 Apr 2026). The MC post expired 29 Jun 2026. Tickets now are about (a) integrations nobody migrated, discovered late, and (b) operating Workflows webhooks.
- **Out of scope:** Outlook actionable messages / Office 365 Connectors for **Outlook** groups (different surface); Teams bots built on Azure Bot Service; Graph `chatMessage` posting (see Playbook 4 for why it's rarely a like-for-like replacement).
- **Sourcing:** Microsoft (MC1181996 via mc.merill.net archive; Developer Blog post with all updates 2024–2026). Operational details (payload envelope, trigger auth options, header trigger-condition pattern, no-premium-licence note) from Martin Heusser (MVP) and Tony Redmond (Office365ITPros, 18 Sep 2026). The `environment.api.powerplatform.com` 401 behaviour comes from a Power Platform Community thread and is **not** confirmed by Microsoft docs — flagged where used.

---
## How It Works

<details><summary>Full architecture</summary>

### Before vs after

```
BEFORE (retired)                                  AFTER (Workflows)
────────────────                                  ─────────────────
Sender ──POST──► https://<t>.webhook.office.com   Sender ──POST──► Workflows trigger URL
                 /webhookb2/<ids>                                 (logic.azure.com  or  environment.api.powerplatform.com)
                    │                                                │ "When a Teams webhook request is received"
                    ▼                                                ▼
          Office 365 Connectors service              Power Automate flow (in an ENVIRONMENT, owned by a USER)
          (static, ownerless, per-channel)             │ actions: For each attachment → Post card in chat/channel
                    │                                  │ runs under the owner's Teams CONNECTION
                    ▼                                  ▼
          Channel post (custom name/icon)          Channel post as Flow bot (or user); no custom name/icon
```

The key architectural shift: a connector webhook was a **stateless endpoint owned by the channel**. A Workflows webhook is a **flow** — an object in a Power Platform environment, owned by a person/service account, executed with that owner's connection, governed by DLP, subject to licensing/run limits, with its own run history. Every failure mode that exists for Power Automate now exists for "a Teams notification".

### Timeline (why tenants were caught out)

| Date | Event |
|---|---|
| 3 Jul 2024 | Retirement announced (MC808160); original dates Aug/Oct 2024 |
| 23 Jul 2024 | Extended through Dec 2025 |
| Oct 2024 – Jan 2025 | Existing connector URLs had to be regenerated to a new URL structure (by 31 Jan 2025) |
| 28 Oct 2025 | Extended to 31 Mar 2026; MessageCard + shared/private channel parity promised |
| 5 Feb 2026 | MessageCard payloads supported in Workflows; Flow bot can post to shared channels; extended to 30 Apr 2026 |
| 14–15 Apr 2026 | Final dates: rollout **18–22 May 2026**; private channels supported via PA portal, Workflows-app selection by 20 Apr 2026 |
| 22 May 2026 | Connectors stop functioning |

Five extensions trained people to ignore the notice; the final one stuck. Integrations that "sat untouched for years" simply stopped — often noticed months later.

### Trigger URL formats

| Host | Notes |
|---|---|
| `prod-NN.<region>.logic.azure.com/workflows/<id>/triggers/manual/paths/invoke?api-version=...&sp=...&sv=...&sig=...` | SAS-signed. With *Anyone*, the `sig` value is the only secret. |
| `<env>.environment.api.powerplatform.com/powerautomate/automations/direct/workflows/<id>/triggers/manual/paths/invoke?api-version=1&...` | Newer Power Platform-hosted format. Community reports say some such URLs return 401 without an OAuth token; Microsoft hasn't documented what decides the format (unverified). |

### Trigger authentication ("Who can trigger the flow?")

- **Anyone** — default for flows created from the Teams Workflows app. No auth header; possession of the URL = permission.
- **Any user in my tenant** / **Specific users in my tenant** — caller must present an Entra token. Good for internal callers that can do OAuth; most monitoring appliances can't.

### Payload handling

- Template flows expect the Bot Framework-style envelope: `type: "message"`, `attachments[]` each with `contentType: application/vnd.microsoft.card.adaptive` and `content: {AdaptiveCard}`. They loop over attachments, so one request can post multiple cards.
- **MessageCard** (`@type: MessageCard`) payloads are accepted (Feb 2026) and render — but `potentialAction`/HttpPost buttons are not rendered.
- A bare Adaptive Card or `{ "text": "..." }` will fail in a template flow; either wrap it or build a custom flow (Compose `triggerBody()` → Post card).

### Licensing

The Teams webhook trigger is a **standard** (non-premium) trigger, unlike the generic *When an HTTP request is received* trigger — so M365-included Power Automate use rights normally suffice (Heusser). Run/request limits still apply to the owner's licence.

</details>

---
## Dependency Stack

```
Layer 7  Card visible in the channel/chat
Layer 6  Post card action: Teams connection (owner account enabled + licensed), poster (Flow bot / User) has access to the channel
           └─ Channel type: standard ✓, shared ✓ (Feb 2026), private ✓ (PA portal; Workflows app from Apr 2026)
Layer 5  Flow logic: payload shape matches actions (envelope vs MessageCard vs bare)
Layer 4  Flow state: On; not suspended by DLP; environment exists; not deleted with its owner
Layer 3  Trigger auth: Anyone (sig in URL) | tenant/specific users (OAuth bearer)
Layer 2  Sender reaches the trigger host over HTTPS (proxy/firewall allows *.logic.azure.com / *.powerplatform.com)
Layer 1  Sender uses the NEW URL (legacy *.webhook.office.com = dead since 22 May 2026)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Alerts silently stopped around 18–22 May 2026 | Unmigrated connector | URL contains `webhook.office.com` |
| Sender logs 202, no card | Flow run failed after trigger | Run history → failing action |
| Run fails at *Apply to each* / "attachments" | Bare card / text payload into template flow | Wrap in envelope or custom flow |
| 401 | Trigger not *Anyone*, or URL truncated (missing `sig`) | Trigger setting; full URL length |
| 404 | Flow deleted or URL regenerated (copy/Save as/recreate) | Flow exists? current URL? |
| Flow suspended / "DLP policy violation" | Data policy blocks Teams connector or mixes groups | PPAC data policies for env |
| Stopped when an employee left | Owner's connection invalid (account disabled/licence removed) | `Get-AdminFlow` owner; connection status |
| Private channel not selectable | Workflows-app rollout / use PA portal | Build in PA portal |
| Buttons missing | MessageCard actions unsupported | Convert to Adaptive Card |
| Footer "X used a Workflow template…" | Template-created flow | Save as custom copy |
| Sender behind proxy fails TLS/407 | Egress to new hosts not allowed | Proxy allow-list `*.logic.azure.com`, `*.powerplatform.com` |

---
## Validation Steps

1. **No legacy URLs remain in senders**
   ```powershell
   .\Find-LegacyTeamsWebhookUrl.ps1 -Path '<\\fileserver\scripts>','<C:\ProgramData\VendorTool>'
   ```
   Good: zero `Legacy` findings. Bad: any `Legacy` row → migrate that sender.

2. **Webhook accepts a post**
   ```powershell
   .\Find-LegacyTeamsWebhookUrl.ps1 -TestWebhookUrl '<workflows-url>'
   ```
   Good: `StatusCode 202` **and** card visible. Bad: 401/404, or 202 with no card (→ run history).

3. **Flow ownership is resilient**
   ```powershell
   Get-AdminFlow -EnvironmentName <env> | Where-Object DisplayName -match '<name>' | ForEach-Object {
     Get-AdminFlowOwnerRole -EnvironmentName $_.EnvironmentName -FlowName $_.FlowName }
   ```
   Good: a service account (or ≥2 owners). Bad: single human owner.

4. **DLP compatible**: environment's data policy has Microsoft Teams (and any other connectors used) in the same group, not *Blocked*.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Is it migrated?** Classify the URL. Legacy = stop troubleshooting, migrate (Playbook 1).

**Phase 2 — Does the request land?** POST the test card. No run in history → network/auth/URL (401/404/proxy). Check with `Invoke-WebRequest -Verbose` from the sender host, not your PC — egress proxies commonly allow `webhook.office.com` but not the new hosts.

**Phase 3 — Does the flow succeed?** Run history (28 days). Map the failing action: trigger/Parse (payload) → Apply to each (envelope) → Post card (connection/channel/DLP).

**Phase 4 — Is it durable?** Owner, environment, DLP, and URL secrecy. Most "it broke again" tickets are ownership/DLP.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Bulk migration of stragglers</summary>

1. **Discover senders**: you can no longer enumerate connectors in Teams (the service is gone). Instead:
   - Scan script shares, CI variables, monitoring configs with `Find-LegacyTeamsWebhookUrl.ps1`.
   - Ask channel owners which channels *used to* receive alerts (look for the last connector post in May 2026 — Microsoft appended a URL-migration warning to connector posts before retirement).
2. For each sender: create a flow from **Send webhook alerts to a channel** (Teams) — ideally from a **service account**, in a governed environment.
3. Swap URL in sender; keep existing MessageCard payloads if they have no buttons.
4. Validate (Validation 2) and record flow name ↔ sender ↔ channel in your CMDB.
**Rollback:** n/a (legacy is gone). Keep the old config commented for reference.
</details>

<details><summary>Playbook 2 — Service-account-owned alerting flows (recommended pattern)</summary>

- Licensed service account (Teams + Power Automate use rights), excluded from interactive-sign-in-only CA policies as appropriate, MFA/CA per your non-human identity standard.
- Dedicated Power Platform environment (e.g. `Ops-Notifications`) with a DLP policy allowing Microsoft Teams.
- Service account is a member of the target teams; flows post as **Flow bot**.
- Add a second admin owner via `Set-AdminFlowOwnerRole`.
- One flow per sender *or* one shared flow with routing (Playbook 3).
**Rollback:** leave original user-owned flow in place (disabled) until the new URL is proven.
</details>

<details><summary>Playbook 3 — Harden an "Anyone" trigger (shared secret + routing)</summary>

Community pattern (Heusser): in the trigger **Settings → Trigger conditions**:
```
@equals(triggerOutputs()?['headers']?['X-Alert-Secret'], '<long-random-secret>')
```
Sender adds the header:
```powershell
Invoke-RestMethod -Uri '<workflows-url>' -Method Post -ContentType 'application/json' `
  -Headers @{ 'X-Alert-Secret' = '<long-random-secret>' } -Body $body
```
Requests without the header don't start a run at all (no noise in history). Optionally route by a `X-Channel` header with a **Switch** to several *Post card* actions — one URL, many channels.
Store the URL + secret in a vault (Key Vault / CI secret), never in scripts in repos.
**Rollback:** remove the trigger condition.
</details>

<details><summary>Playbook 4 — When Workflows is the wrong tool</summary>

- **Microsoft Graph `POST /teams/{id}/channels/{id}/messages`** requires **delegated** `ChannelMessage.Send`; application permissions only cover migration import scenarios — so unattended daemons generally can't use Graph to post as themselves. Workflows (or a bot) remains the practical path.
- **Channel email address** (channel **…** → Get email address): fine for low-volume, plain notifications from systems that can only send mail; no cards.
- **Bot (Azure Bot Service / Teams SDK)**: custom name/icon, proactive messages, interactivity — for product teams, not typical MSP alerting.
</details>

---
## Evidence Pack

```powershell
# Run from the SENDER host. Does not print the full URL (treat as secret).
param([Parameter(Mandatory)][string]$Url)
$out = Join-Path $PWD ("TeamsWebhook-Evidence-{0}.txt" -f (Get-Date -Format yyyyMMdd-HHmm))
$uri = [Uri]$Url
$masked = '{0}://{1}{2}?<query redacted, length {3}>' -f $uri.Scheme, $uri.Host, $uri.AbsolutePath, $uri.Query.Length
& {
  "Timestamp (UTC): $((Get-Date).ToUniversalTime().ToString('s'))"
  "Host: $env:COMPUTERNAME"
  "URL: $masked"
  "Has sig param: $($uri.Query -match '(^|[?&])sig=')"
  "--- TCP 443 ---"; Test-NetConnection $uri.Host -Port 443 | Select-Object ComputerName,RemoteAddress,TcpTestSucceeded | Out-String
  "--- Proxy ---"; netsh winhttp show proxy
  "--- Test POST ---"
  $body = '{"type":"message","attachments":[{"contentType":"application/vnd.microsoft.card.adaptive","contentUrl":null,"content":{"type":"AdaptiveCard","version":"1.4","body":[{"type":"TextBlock","text":"Evidence-pack test","wrap":true}]}}]}'
  try { $r = Invoke-WebRequest -Uri $Url -Method Post -ContentType 'application/json' -Body $body -UseBasicParsing; "Status: $($r.StatusCode)" }
  catch { "Error: $($_.Exception.Message)" }
} *>&1 | Out-File $out -Encoding utf8
"Evidence written to $out - add flow run-history screenshot + owner/env/DLP details"
```

---
## Command Cheat Sheet

| Purpose | Command |
|---|---|
| Scan files for legacy/new webhook URLs | `.\Find-LegacyTeamsWebhookUrl.ps1 -Path <dir>` |
| Test-post a card (posts a real message) | `.\Find-LegacyTeamsWebhookUrl.ps1 -TestWebhookUrl <url>` |
| Connect PA admin | `Add-PowerAppsAccount` |
| List environments | `Get-AdminPowerAppEnvironment` |
| Find a flow | `Get-AdminFlow -EnvironmentName <env> \| ? DisplayName -match '<x>'` |
| Flow owners | `Get-AdminFlowOwnerRole -EnvironmentName <env> -FlowName <flow>` |
| Add co-owner | `Set-AdminFlowOwnerRole -EnvironmentName <env> -FlowName <flow> -PrincipalType User -PrincipalObjectId <id> -RoleName CanEdit` |
| Disable / enable a flow | `Disable-AdminFlow` / `Enable-AdminFlow -EnvironmentName <env> -FlowName <flow>` |
| DLP policies | `Get-DlpPolicy` (Microsoft.PowerApps.Administration.PowerShell) |
| Reachability from sender | `Test-NetConnection <trigger-host> -Port 443` |
| Proxy used by services | `netsh winhttp show proxy` |

---
## 🎓 Learning Pointers

- **Read the full update chain once** — five extensions, the URL-regeneration step, then MessageCard/shared/private-channel parity: [Retirement of Office 365 connectors within Microsoft Teams](https://devblogs.microsoft.com/microsoft365dev/retirement-of-office-365-connectors-within-microsoft-teams/); final dates and limitations in [MC1181996](https://mc.merill.net/message/MC1181996).
- **A notification is now an application.** Owner lifecycle, environments and DLP apply — align with your Power Platform governance (`PowerAutomate/_AGENT.md`) instead of treating webhooks as config strings.
- **Understand the envelope.** Why a bare card fails and how to build a custom flow that accepts one: [Martin Heusser — Migrate Teams Incoming Webhooks to Workflows](https://heusser.pro/p/migrate-teams-office-365-connectors-to-workflows-8p40yq7jfebm/).
- **Old code rots quietly.** The retirement surfaced via a secret-scanner hit on an embedded webhook in a public script: [Office365ITPros, 18 Sep 2026](https://office365itpros.com/2026/09/18/teams-workflows-updates/). Add webhook URL patterns to your repo secret scanning.
- **Trigger auth options** (Anyone vs tenant users) and the trigger reference: [Microsoft Teams connector reference](https://learn.microsoft.com/en-us/connectors/teams/).
