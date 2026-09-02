# Purview Network Data Security (GSA Content Policy DLP) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

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

**Scope check first:** this runbook covers **network data security** — Purview DLP inspecting traffic to *unmanaged* cloud/AI apps at the network layer via Microsoft Entra Global Secure Access (GSA) Internet Access content policies. It is a preview-status feature (as of this writing) distinct from the mature Exchange/SharePoint/OneDrive/Teams/Endpoint DLP workloads covered in `DLP-Policy-A/B.md`. If the ticket is about a Microsoft 365 app or an MDE-onboarded endpoint, use `DLP-Policy-B.md` instead.

```powershell
# 1. Is the tenant even licensed/configured for network data security?
#    (Portal-only check — no cmdlet reads GSA content policy state directly)
Write-Host "Confirm in Entra admin center: Global Secure Access > Secure > Content policies" -ForegroundColor Cyan
Write-Host "Confirm in Purview portal: pay-as-you-go billing configured (required even during preview)" -ForegroundColor Cyan

# 2. Is the GSA client actually routing traffic through Internet Access?
#    Run ON the affected device (Windows or macOS client with GSA installed)
# Global Secure Access client > Troubleshooting tab > Advanced Diagnostics > Run tool > Forwarding Profile tab
# Confirm "Internet Access" rules are present under Rules

# 3. What DLP policies exist that target Inline web traffic (the network scenario)?
Connect-IPPSSession -UserPrincipalName <adminUPN>
Get-DlpCompliancePolicy | Where-Object { $_.Workload -like "*CloudAppsInternal*" -or $_.Comment -like "*network*" } |
    Select-Object Name, Mode, Enabled, Workload | Format-Table -AutoSize

# 4. Recent network DLP activity (Activity Explorer is the primary tool — no bulk cmdlet equivalent for network events)
Write-Host "Purview portal > Data Classification > Activity explorer > filter Enforcement plane = Network" -ForegroundColor Cyan
```

**Interpretation:**

| Result | Likely cause | Go to |
|--------|-------------|-------|
| Upload/text send to sanctioned AI app (e.g. ChatGPT) is NOT blocked despite a policy existing | Content policy destination FQDNs don't match the app's real upload endpoint (apps use hidden API subdomains, not the visible URL) | Fix 1 |
| Text is not inspected/blocked, only files | Basic content policy in use — it never inspects text; text requires **Scan with Purview** | Fix 2 |
| **Scan with Purview** selected but nothing happens | No matching Purview DLP "Inline web traffic" policy exists, or it targets the wrong cloud apps | Fix 3 |
| Everything configured correctly but block/audit takes a while to appear | Preview-feature propagation: up to 24h for policy distribution + up to 30 min for first event in Activity Explorer | Fix 4 (expectation-setting, not a bug) |
| Content policy created but Global Secure Access traffic logs show nothing at all | Internet Access forwarding profile not enabled/assigned, or Conditional Access "Use GSA Security Profile" session control missing | Fix 5 |
| DLP working for one AI app but not a near-identical one (e.g. ChatGPT consumer vs. enterprise) | Multiple cloud-app catalog entries exist for the same brand — only some were added to the policy's Adaptive app scope | Fix 6 |
| Client asks "why can't I just block ChatGPT for everyone" — wrong tool being reached for | Blanket app blocking is a GSA **web content filtering** / basic content policy job, not a DLP job — DLP is for *conditional*, content-aware blocking | Scope & Assumptions note below |

---

## Dependency Cascade

<details><summary>What must be true for network data security to work</summary>

```
[Content policy match & enforcement — GSA Content Policy]
    │
    ├── Microsoft Entra Internet Access traffic forwarding profile — Enabled + user assigned
    │     └── Global Secure Access client installed (Windows or macOS) and Entra-joined/Hybrid-joined
    │           └── Client routing verified via Advanced Diagnostics > Forwarding Profile tab
    │
    ├── Conditional Access policy — Target resources: "All internet resources with GSA"
    │     └── Session control: "Use Global Secure Access Security Profile" linked to the security profile
    │
    ├── Security profile — Content policy linked at correct Position/State
    │
    ├── Content policy rule — Action = "Scan with Purview" (for text; Basic policy = files only, MIME-type only)
    │     └── Matching conditions: Activities (Upload/Download) + Content types configured
    │     └── Destinations: exact upload-endpoint FQDNs/URLs (NOT just the app's visible domain)
    │
    └── Corresponding Microsoft Purview DLP policy — "Inline web traffic" location
          ├── Cloud apps / Adaptive app scopes configured (must match the content policy's intent)
          ├── "Network and non-Microsoft secure browsers" enforcement location enabled
          │     └── Requires Purview pay-as-you-go billing configured FIRST
          ├── Rule: Content contains (SIT/label) + Action: Restrict browser and network activities
          │     └── One or more of: Text sent/received, File uploaded/downloaded — set to Audit or Block
          └── Policy turned On (or in simulation first)
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm the GSA client is actually forwarding Internet Access traffic**
On the affected device: GSA client icon → **Troubleshooting** → **Advanced Diagnostics** → **Run tool** → **Forwarding Profile** tab.
Expected: **Internet Access** rules listed under **Rules**.
Bad: No Internet Access rules → the traffic never reaches GSA at all, so no content policy can act on it. Check profile enablement/assignment before touching DLP.

---

**Step 2 — Confirm the content policy action matches the scenario (file vs. text)**
Entra admin center → **Global Secure Access** → **Secure** → **Content policies** → open the policy → check each rule's **Action**.
Expected: **Scan with Purview** for any scenario involving text (prompts, form fields, message bodies).
Bad: **Allow/Block** (Basic content policy) selected for a text-inspection ask — Basic policy only ever inspects file MIME types, never text, regardless of how it's configured.

---

**Step 3 — Confirm a matching Purview DLP "Inline web traffic" policy exists and targets the right apps**
Purview portal → **Data loss prevention** → **Policies** → find the Inline web traffic policy.
Expected: **Cloud apps** step includes the destination app (or its full Adaptive app-scope category, e.g. "All unmanaged AI apps"). **Choose where to enforce** has **Network and non-Microsoft secure browsers** enabled.
Bad: Policy exists but was built for SharePoint/Exchange, not Inline web traffic — it will never evaluate GSA-forwarded network content.

---

**Step 4 — Confirm the rule's action list matches the content policy's rule intent**
Purview portal → open the DLP rule → **Actions** → **Restrict browser and network activities**.
Expected: the specific activity checked (Text sent to/shared with cloud or AI app, File uploaded, etc.) matches what the GSA content policy rule is trying to catch, and is set to **Block** (not just Audit) if enforcement — not just visibility — is the goal.
Bad: Action list only has **Audit** checked when the client expected a hard block — this is a config choice, not a fault; confirm intent with the client before "fixing."

---

**Step 5 — Check Activity Explorer / Global Secure Access traffic logs for evidence**
Purview portal → **Data Classification** → **Activity explorer** → filter **Enforcement plane = Network**.
Entra admin center → **Global Secure Access** → **Monitor** → **Traffic logs**.
Expected: matching events appear within ~30 minutes of a test action (once the policy itself has had up to 24h to propagate after creation/edit).
Bad: Nothing in either log after 24h+ → re-check Steps 1–4; also confirm pay-as-you-go billing is actually configured (network enforcement silently can't be selected without it, and an already-created policy can be left half-configured if billing was added afterward).

---

**Step 6 — Confirm destination FQDNs actually match real upload traffic (the #1 false-negative cause)**
Use browser dev tools / network trace on the actual upload action against the target app. Compare captured FQDNs/URLs against the content policy rule's **Destination** list.
Expected: exact match, including any dedicated upload subdomain (e.g. `*.oaiusercontent.com` for ChatGPT file uploads, not just `chatgpt.com`).
Bad: Only the marketing/landing domain is listed — traffic to the real upload API endpoint sails through unfiltered. Top-level and second-level wildcards are NOT supported, so each FQDN must be added explicitly.

---

## Common Fix Paths

<details>
<summary>Fix 1 — Sensitive content is uploaded/sent to an AI app without being blocked</summary>

**Symptoms:** Content policy and DLP policy both appear configured, but a documented test upload (e.g. a sample credit-card PDF) goes through to ChatGPT/Gemini/Claude unblocked.

**Step 1 — Re-derive the real upload endpoints, don't trust the marketing domain**
1. On a test device, open browser dev tools (Network tab).
2. Perform the exact upload/send action.
3. Note every distinct FQDN/URL involved — AI apps frequently use dedicated API/file subdomains separate from the main site.

**Step 2 — Rebuild the content policy destination list**
Entra admin center → **Global Secure Access** → **Secure** → **Content policies** → edit the rule → **+ Add destination**:
- Add each specific URL (not just FQDN) used for the upload/text-submission action.
- Add related FQDNs as explicit subdomains — top-level and second-level wildcards (`*`, `*.com`, `*contoso.com`) are not supported (e.g. use `*.oaiusercontent.com`, not a wildcard on the base domain).

**Step 3 — Confirm the DLP rule's cloud-app scope includes the same app**
Purview portal → DLP policy → **Cloud apps** step → verify the specific app (or its Adaptive app-scope category) is included, not just a generic "generative AI" label that may not resolve to every catalog entry for that vendor.

**Step 4 — Re-test and check both logs**
Re-run the test action → check **GSA Traffic logs** (confirms GSA saw and forwarded the request) AND **Purview Activity explorer** (confirms Purview classified and returned a decision). A miss in the first log points at content-policy/destination config; a miss in the second (with a hit in the first) points at the DLP rule/cloud-app scope.

**Rollback:** None needed — this is additive configuration. If overly broad destination matching starts blocking legitimate traffic, narrow the URL list rather than removing entries wholesale.

</details>

<details>
<summary>Fix 2 — Files are inspected but prompt/message text is not</summary>

**Symptoms:** PDF/document uploads are correctly blocked, but pasting the same sensitive data directly as text into a chat/form is not caught.

**Step 1 — Confirm the content policy action is Scan with Purview, not Basic**
Basic content policy (Allow/Block by MIME type) **never** inspects text under any configuration — this is a hard product limitation, not a misconfiguration.

**Step 2 — Add text content types to the content policy rule**
Edit the content policy rule → **Matching conditions** → **Text content types** → select the types to inspect. File content type selection is optional for text-only scenarios.

**Step 3 — Add matching text activities to the Purview DLP rule**
Purview DLP rule → **Actions** → **Restrict browser and network activities** → ensure **Text sent to or shared with cloud or AI app** (and **Text received**, if inbound inspection is also wanted) is checked and set to the desired action.

**Rollback:** N/A — additive configuration change.

</details>

<details>
<summary>Fix 3 — Content policy is set to Scan with Purview but nothing is ever inspected</summary>

**Symptoms:** GSA traffic logs show the policy matching and forwarding traffic to Purview, but Activity Explorer shows zero events and no block/audit ever occurs.

**Step 1 — Confirm a Purview DLP policy actually targets Inline web traffic**
Without a corresponding DLP policy scoped to **Inline web traffic**, Scan with Purview has nothing to evaluate against — the content policy alone cannot make audit/block decisions.
```
Purview portal > Data loss prevention > Policies > + Create policy > Inline web traffic
```

**Step 2 — Confirm pay-as-you-go billing is configured**
Network enforcement location cannot be enabled without Purview pay-as-you-go billing configured first (**Purview → Data loss prevention → Considerations for billing**). During public preview this doesn't incur charges, but the billing model must still be turned on.

**Step 3 — Confirm the rule condition and cloud-app scope are non-empty**
An Inline web traffic DLP policy with no sensitive-information-type condition, or with an empty cloud-app scope, will never fire.

**Rollback:** N/A.

</details>

<details>
<summary>Fix 4 — Configuration looks correct but nothing shows up yet</summary>

**Symptoms:** Everything in Fixes 1–3 checks out, but it's been less than a day since the policy was created or last edited.

**Step 1 — Wait for the documented propagation windows before troubleshooting further**
- Up to **24 hours** for policy distribution from Purview to the network security solution (GSA) after creation/edit.
- Up to **30 minutes** for the first classified event from a test action to appear in Activity Explorer, once the two services are fully communicating.

**Step 2 — Re-test after the window has elapsed**
If still nothing after 24h+, escalate through the earlier Diagnosis steps rather than assuming it's simply still propagating.

**Rollback:** N/A — this is an expectation-setting fix, not a configuration change.

</details>

<details>
<summary>Fix 5 — GSA traffic logs show nothing for the affected user/device at all</summary>

**Symptoms:** No content-policy hits, no misses, nothing — the traffic simply isn't visible to GSA.

**Step 1 — Confirm the Internet Access forwarding profile is enabled and assigned**
Entra admin center → **Global Secure Access** → **Connect** → **Traffic forwarding** → **Internet access profile** → confirm **Enabled** and that the affected user/group is assigned.

**Step 2 — Confirm the Conditional Access session control is linked**
Entra ID → **Protection** → **Conditional Access** → the policy targeting **All internet resources with Global Secure Access** → **Session** → **Use Global Secure Access Security Profile** must reference the security profile the content policy is linked to.

**Step 3 — Confirm the security profile actually has the content policy linked**
**Global Secure Access** → **Secure** → **Security profiles** → open the profile → **Link policies** view → confirm the content policy appears with the expected **Position** and **State**.

**Step 4 — Re-run client diagnostics (see Diagnosis Step 1)**

**Rollback:** N/A.

</details>

<details>
<summary>Fix 6 — DLP catches one variant of an app but not a near-identical one</summary>

**Symptoms:** ChatGPT enterprise traffic is blocked; ChatGPT consumer (or a similarly-branded alternate catalog entry, e.g. "QwenAI" vs. "Qwen Chat") is not, despite intending to cover "the same app."

**Step 1 — Check for multiple catalog entries for the same vendor**
Microsoft Defender for Cloud Apps catalog (35,000+ entries) sometimes lists consumer and enterprise instances of the same product, or near-duplicate names, as separate entries.

**Step 2 — Add every relevant entry to the cloud-app scope**
Purview DLP policy → **Cloud apps** step → search for all name variants and add each one individually rather than assuming one entry covers the brand.

**Rollback:** N/A — additive.

</details>

---

## Escalation Evidence

```
TICKET ESCALATION — Network Data Security (GSA Content Policy DLP) Issue
==========================================================================
Tenant:                    [tenant name / domain]
Content policy name:       [GSA content policy name]
Content policy rule action: [Allow/Block (Basic) / Scan with Purview]
Purview DLP policy name:   [Inline web traffic policy name]
Target app/destination:    [app name + exact FQDNs/URLs configured]
Issue type:                [Not blocking / Text not inspected / No logs at all / Wrong app variant]
User/device affected:      [UPN / device name]
GSA client version:        [from Advanced Diagnostics]
First observed:            [date/time]

Forwarding profile enabled:        [Yes/No]
CA session control linked:         [Yes/No]
Security profile has policy linked: [Yes/No]
Purview pay-as-you-go configured:  [Yes/No]

GSA Traffic logs show a hit:       [Yes/No]
Purview Activity Explorer shows a hit: [Yes/No]

Actions taken so far:
  □ Verified client forwarding via Advanced Diagnostics
  □ Confirmed Scan with Purview (not Basic) for text scenarios
  □ Verified destination FQDNs against actual captured upload traffic
  □ Confirmed matching Inline web traffic DLP policy + cloud-app scope
  □ Waited out the 24h policy-propagation / 30min event-latency window
  □ [Other]

Next recommended action: [your assessment]
```

---

## 🎓 Learning Pointers

- **This is a preview feature layered on top of two already-mature products, not a new product.** Network data security is the DLP *classification engine* (same SITs, same Purview policy authoring) extended to a new *enforcement plane* (network traffic via GSA), not a replacement for Exchange/SharePoint/OneDrive/Teams/Endpoint DLP. Keep `DLP-Policy-A/B.md` as the reference for those workloads. MS Docs: [Learn about Microsoft Purview Network Data Security](https://learn.microsoft.com/en-us/purview/dlp-network-data-security-learn)

- **Basic content policy and Scan with Purview are fundamentally different capabilities, not tiers of the same feature.** Basic policy inspects file MIME types only — it can never see text, no matter how it's configured. Any client request to block sensitive *text* going to an AI app requires Scan with Purview plus a matching Inline web traffic DLP policy. MS Docs: [Create content policies for network content filtering](https://learn.microsoft.com/en-us/entra/global-secure-access/how-to-network-content-filtering)

- **Destination FQDN precision is the single most common cause of a "policy exists but doesn't work" ticket.** Modern web apps route uploads and API calls through dedicated subdomains that differ from the visible marketing domain, and top/second-level wildcards aren't supported. Always capture real traffic with browser dev tools before finalizing a destination list — don't guess from the app's homepage URL.

- **Two independent logs, two independent failure points.** GSA Traffic logs prove the client forwarded the traffic and the content policy matched it; Purview Activity Explorer proves Purview classified it and returned a decision. A gap in one but not the other narrows the fault to a specific half of the pipeline — check both before escalating.

- **Licensing has two valid paths, and network data security specifically is the pricier of the two.** Network data security with Entra GSA requires either Microsoft 365 E7 per-seat, or Purview E5 (or equivalent) *plus* Entra Internet Access licensing *plus* Purview pay-as-you-go billing configured — non-Microsoft SASE/secure-browser integrations only need Purview E5 + pay-as-you-go, without the GSA-specific add-on. Confirm which integration path a client is actually licensed for before troubleshooting configuration. MS Docs: [Learn about Microsoft Purview billing models](https://learn.microsoft.com/en-us/purview/purview-billing-models)

- **Everything here is explicitly preview-status as of this writing.** Set client expectations accordingly — behavior, supported protocols (HTTP/1.1 and HTTP/HTTPS only; no QUIC/UDP, no HTTP/3), and the feature list itself may change before GA. Re-verify current scope against the live Learn pages before treating any specific limitation as permanent.
