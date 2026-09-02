# Purview Network Data Security (GSA Content Policy DLP) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

This runbook covers **Microsoft Purview network data security** delivered through the **Microsoft Entra Global Secure Access (GSA) Internet Access** integration — extending Purview's classification and DLP enforcement to raw network traffic destined for *unmanaged* cloud apps and generative AI services (ChatGPT, Gemini, Claude, Dropbox, Gmail, Google Forms, social media, and 35,000+ other cataloged unmanaged apps). It does **not** cover:

- DLP for first-party Microsoft 365 workloads (Exchange/SharePoint/OneDrive/Teams) — see `DLP-Policy-A.md`.
- Endpoint DLP via Microsoft Defender for Endpoint (device-local file/clipboard/print enforcement) — also `DLP-Policy-A.md`.
- Non-Microsoft SASE/secure-browser integrations (via the Purview Security Store) — architecturally similar but a different licensing/configuration path, only summarized here.
- General GSA client deployment/health (service naming, Hyper-V switch boundaries, Windows Update auto-upgrade) — see `EntraID/Troubleshooting/GlobalSecureAccess-Windows-A.md` and `macOS/Troubleshooting/GlobalSecureAccess-macOS-A.md`.

**As of this writing, this entire feature area is preview-status** (`ms.date` 2026-06-30/2026-07-29 on the primary sources). GA timing, supported protocols, and specific limitations may change — re-verify against the live Learn pages before treating any constraint below as permanent.

---

## How It Works

<details><summary>Full architecture</summary>

Network data security is Microsoft's answer to a gap neither classic DLP nor classic CASB fully closed: **conditional, content-aware control over data leaving through unmanaged/unsanctioned destinations** — most urgently, shadow generative-AI usage, where an employee pastes source code or customer PII directly into a public chatbot with no file ever touching a monitored Microsoft 365 workload.

It combines two previously separate product surfaces into one enforcement pipeline:

```
┌─────────────────────────────────────────────────────────────────────┐
│  Managed endpoint (Windows or macOS) — GSA client installed          │
│  Browser / native app / add-in / API call                            │
└───────────────────────────────┬───────────────────────────────────────┘
                                  │  HTTP/HTTPS traffic (HTTP/1.1 only —
                                  │  no QUIC/UDP, no HTTP/3, in preview)
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Microsoft Entra Global Secure Access — Internet Access forwarding    │
│  profile (identity-centric network security policy enforcement)      │
│      └── Content policy evaluates the request:                       │
│            ├── Basic content policy → MIME-type Allow/Block only      │
│            │     (files only, never text; GA)                        │
│            └── Scan with Purview (preview) → forwards file/text       │
│                  content to Microsoft Purview for real-time            │
│                  classification + policy decision                     │
└───────────────────────────────┬───────────────────────────────────────┘
                                  │  real-time classification request
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Microsoft Purview — Inline web traffic DLP policy                   │
│      ├── Same Sensitive Information Type / sensitivity-label engine   │
│      │     used by every other Purview DLP workload                  │
│      ├── Evaluates against configured cloud apps / Adaptive app       │
│      │     scopes (backed by the Defender for Cloud Apps catalog,     │
│      │     35,000+ entries)                                           │
│      └── Returns Audit or Block decision per matched activity         │
└───────────────────────────────┬───────────────────────────────────────┘
                                  │  decision returned to GSA
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  GSA enforces the decision at the network edge                        │
│      ├── Block → connection/upload/text-send terminated               │
│      ├── Audit → allowed through, logged + alerted                    │
│      └── Event surfaces in:                                           │
│            ├── GSA Traffic logs (Entra admin center)                  │
│            └── Purview Activity Explorer (Enforcement plane: Network) │
│                  + DLP Alerts (if configured)                         │
└─────────────────────────────────────────────────────────────────────┘
```

**The critical architectural distinction: two policy objects, two portals, one pipeline.** The **content policy** (Entra admin center, GSA-side) decides *what traffic gets forwarded to Purview and what basic action applies*. The **DLP policy** (Purview portal, Inline web traffic location) decides *what Purview does with the content it receives*. Neither one alone is sufficient for text/file inspection — Scan with Purview without a matching Inline web traffic DLP policy forwards traffic that is never actually evaluated against any rule.

**Four supported network activities**, applicable independently in either direction:
- Text sent to or shared with cloud or AI app
- Text received from cloud or AI app
- File uploaded to or shared with cloud or AI app
- File downloaded from cloud or AI app

**Billing model is unusual for a DLP feature: it's request-based, not per-seat.** Network data security uses Purview pay-as-you-go billing, metered per network *request* (each outbound call from device/browser to a destination; responses aren't separately counted). Pay-as-you-go must be configured before any network data security policy — including collection-only, non-enforcing policies — can be created, though GSA-integration usage specifically doesn't incur charges during the public preview window.

**Two collection mechanisms exist, serving different purposes.** A **collection policy** (visibility-only, asynchronous) feeds Activity Explorer and DSPM for AI's activity events without blocking anything — useful for a pre-rollout baseline of what's actually leaving the organization before writing an enforcement policy. A **DLP policy** (real-time, when protections are configured) is what actually blocks/audits. Microsoft Purview DSPM for AI also ships a **one-click default policy** ("DSPM for AI - Detect sensitive info shared with AI via network") built on the collection-policy mechanism, giving a fast starting baseline without hand-authoring conditions.

</details>

---

## Dependency Stack

```
[Microsoft Entra tenant]
    │
    ├── Licensing — ONE of:
    │     ├── Microsoft 365 E7 per-seat, OR
    │     └── Purview E5 (or equivalent) + Entra Internet Access (or equivalent), per-seat
    │           └── Purview pay-as-you-go billing configured (mandatory prerequisite,
    │                 even though GSA-path usage is free during preview)
    │
    ├── Global Secure Access Administrator role — configures content policies/profiles
    ├── Conditional Access Administrator role — configures the enforcing CA policy
    │
    ├── [Internet Access traffic forwarding profile] — Enabled + user/group assigned
    │     └── [GSA client] — Windows or macOS, Entra-joined or Hybrid-joined device
    │           └── [TLS inspection policy] configured (prerequisite for content policies)
    │
    ├── [Content policy] (Entra admin center)
    │     └── Rule: Action = Scan with Purview (preview) — required for TEXT inspection;
    │           Basic Allow/Block only ever inspects file MIME type
    │           └── Matching conditions: Activities + Content types (file and/or text)
    │           └── Destinations: exact URLs/FQDNs (no top/second-level wildcards) +
    │                 optional web-category destinations (needs a separate web content
    │                 filtering policy)
    │
    ├── [Security profile] — content policy linked at a Position/State
    │
    ├── [Conditional Access policy] — Target resources: All internet resources with GSA
    │     └── Session: Use Global Secure Access Security Profile → linked to the profile above
    │
    └── [Microsoft Purview — Inline web traffic DLP policy]
          ├── Cloud apps / Adaptive app scopes (Defender for Cloud Apps catalog-backed)
          ├── Enforcement location: Network and non-Microsoft secure browsers (ENABLED)
          ├── Rule: Content contains (SIT/sensitivity label) condition
          └── Rule: Restrict browser and network activities action
                └── Per-activity Audit/Block: text sent/received, file uploaded/downloaded
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Nothing in GSA Traffic logs at all for the user/device | Internet Access forwarding profile not enabled/assigned, or CA session control not linked | GSA client Advanced Diagnostics; CA policy session settings |
| GSA logs show a hit, Purview Activity Explorer shows nothing | Content policy uses Basic Allow/Block (never reaches Purview), or no matching Inline web traffic DLP policy exists | Content policy rule Action; Purview DLP policy list |
| Text goes through unblocked, files are correctly blocked | Basic content policy in effect, or DLP rule missing the text activity actions | Content policy Action = Scan with Purview; DLP rule Actions list |
| One AI app blocked, a near-identical one isn't | Multiple Defender for Cloud Apps catalog entries for the same vendor, only some added to scope | Cloud apps step in the DLP policy |
| Config looks complete, zero events after a few minutes | Normal preview propagation latency (up to 24h policy distribution, up to 30 min first-event) | Time elapsed since policy create/edit |
| Upload silently succeeds despite a destination entry for the app's main domain | Real upload traffic goes through a dedicated API/file subdomain not covered by the entry; wildcards unsupported at top/second level | Browser dev tools trace of the actual upload request |
| B2B guest user's traffic isn't governed by the policy at all | Documented limitation — Purview network data security policies don't apply to B2B guest users | Confirm affected identity type |
| Policy can't select Network as an enforcement location | Purview pay-as-you-go billing not yet configured | Purview billing settings |
| Compressed file (ZIP) content not fully inspected | Compressed content is detected by ZIP format only — contents are not decompressed for inspection | Confirm file type/nesting |

---

## Validation Steps

1. **Client forwarding.** GSA client → Troubleshooting → Advanced Diagnostics → Forwarding Profile tab. Good: Internet Access rules present. Bad: absent — nothing downstream can work.
2. **Content policy action.** Entra admin center → content policy rule → Action. Good: Scan with Purview for any text scenario. Bad: Basic Allow/Block used where text inspection was actually requested.
3. **Security profile linkage.** Security profiles → target profile → Link policies view. Good: content policy listed with expected Position/State. Bad: policy created but never linked to a profile actually in use.
4. **CA session control.** Conditional Access policy → Session → Use Global Secure Access Security Profile. Good: references the correct profile. Bad: missing entirely, or references a different/unused profile.
5. **Purview DLP policy scope.** Purview portal → DLP policy → Location = Inline web traffic; Cloud apps step. Good: target app/category present, Network enforcement location enabled. Bad: policy exists for a different location, or app scope too narrow.
6. **End-to-end test.** Perform a documented test action (e.g. sample sensitive PDF upload to a test AI app) from a validated device. Good: event appears in both GSA Traffic logs and Purview Activity Explorer within the expected windows. Bad: appears in one but not the other — isolates the fault to a specific half of the pipeline.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Client/network layer.** Confirm the GSA client is installed, the device is Entra-joined/Hybrid-joined, TLS inspection is configured, and the Internet Access profile is both enabled and assigned to the user. Nothing else in this stack matters until traffic is actually reaching GSA.

**Phase 2 — Policy linkage layer.** Confirm content policy → security profile → CA policy session control forms an unbroken chain. A content policy that exists but isn't linked to an in-use security profile is inert.

**Phase 3 — Content-matching layer.** Confirm the content policy's Action, Activities, Content types, and — critically — exact Destination URLs/FQDNs are correct. This is where most false negatives originate: apps route uploads through non-obvious subdomains, and wildcarding isn't supported at the top/second level.

**Phase 4 — Purview evaluation layer.** Confirm an Inline web traffic DLP policy exists, targets the same app/category, has Network enforcement enabled (requires pay-as-you-go billing), and its rule's condition + action list matches intent (Audit vs. Block, which specific activities).

**Phase 5 — Evidence/propagation layer.** Before concluding something is broken, confirm sufficient time has elapsed (up to 24h policy distribution, up to 30 min event latency) and check both GSA Traffic logs and Purview Activity Explorer independently to localize the gap.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Stand up network data security for a new pilot (visibility-first rollout)</summary>

1. Confirm licensing path (M365 E7, or Purview E5 + Entra Internet Access) and configure Purview pay-as-you-go billing.
2. Enable and assign the Internet Access traffic forwarding profile to a small pilot group; deploy the GSA client; verify client forwarding via Advanced Diagnostics.
3. Start with a **collection policy** (not DLP) targeting "All unmanaged AI apps" to establish a visibility baseline in Activity Explorer with zero enforcement risk — or apply DSPM for AI's one-click default policy for a fast start.
4. Review 3-5 days of collected data with the client. Identify genuinely risky patterns (which apps, which SIT types, which users).
5. Convert findings into a scoped Inline web traffic DLP policy in **Audit** mode first, paired with a content policy set to Scan with Purview for the same destinations.
6. Move to **Block** only after the client has reviewed audit-mode findings and signed off on the enforcement scope.

</details>

<details><summary>Playbook 2 — Block a specific high-risk destination (e.g. a named "shadow AI" tool flagged by the client)</summary>

1. Identify the tool's real upload/text-submission endpoints via browser dev tools trace — never rely on the marketing domain alone.
2. Content policy: add a new rule, Action = Scan with Purview, Content types = file and/or text as needed, Destinations = every captured FQDN/URL.
3. Purview DLP: add/extend an Inline web traffic policy's Cloud apps scope to include the specific catalog entry (check for near-duplicate entries for the same vendor).
4. Set the rule action to Audit initially; validate against a controlled test upload; promote to Block once confirmed.
5. Document the destination list in the escalation/change record — these lists silently go stale as vendors change infrastructure, and should be periodically re-validated.

</details>

<details><summary>Playbook 3 — Investigate a suspected false negative reported by the client</summary>

1. Reproduce with a controlled, clearly-labeled test payload (never real customer data) from a known-good pilot device.
2. Check GSA Traffic logs first — did GSA even see and forward the request?
3. If yes, check Purview Activity Explorer — did Purview receive and classify it?
4. If GSA saw it but Purview didn't: check content policy Action (Basic vs. Scan with Purview) and whether a matching DLP policy/location exists.
5. If Purview saw it but returned no match: check the DLP rule's SIT/label condition — the test payload may not actually trigger the configured condition at its confidence/count threshold (see `DLP-Policy-A.md` for SIT tuning, which applies identically here).
6. If neither log shows anything: return to Phase 1 (client/network layer) — this is very rarely a Purview-side issue when both logs are silent.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Purview + Entra ID prerequisite/configuration evidence for network data
    security (GSA content policy DLP integration) escalations.
.DESCRIPTION
    No dedicated cmdlet surface exists for GSA content policies or their traffic logs —
    those are portal-only (Entra admin center). This evidence pack collects everything
    that IS cmdlet-reachable: Purview DLP policies scoped to Inline web traffic, tenant
    licensing signals, and a reminder checklist of the portal-only items an engineer must
    screenshot/export manually before escalating.
.NOTES
    Run with Security & Compliance PowerShell (Connect-IPPSSession) + Microsoft Graph
    (Connect-MgGraph) sessions established first.
#>
Connect-IPPSSession -UserPrincipalName <adminUPN>
Connect-MgGraph -Scopes "Organization.Read.All" -NoWelcome

Write-Host "=== Purview DLP policies (all — filter manually for Inline web traffic location) ===" -ForegroundColor Cyan
Get-DlpCompliancePolicy | Select-Object Name, Mode, Enabled, Workload, Comment | Format-Table -AutoSize

Write-Host "=== Tenant SKUs (confirm E7 / Purview E5 + Internet Access licensing path) ===" -ForegroundColor Cyan
Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits, @{N='Enabled';E={($_.PrepaidUnits).Enabled}} |
    Where-Object { $_.SkuPartNumber -match "PURVIEW|E7|E5|INTERNET_ACCESS|GLOBAL_SECURE" } | Format-Table -AutoSize

Write-Host "`n=== PORTAL-ONLY EVIDENCE — collect manually before escalating ===" -ForegroundColor Yellow
Write-Host "  [ ] Entra admin center > Global Secure Access > Secure > Content policies (screenshot rule config)"
Write-Host "  [ ] Entra admin center > Global Secure Access > Secure > Security profiles (confirm policy linkage)"
Write-Host "  [ ] Entra admin center > Global Secure Access > Monitor > Traffic logs (export/screenshot the relevant window)"
Write-Host "  [ ] Entra ID > Conditional Access > affected policy > Session tab (confirm GSA Security Profile link)"
Write-Host "  [ ] Purview portal > Data Classification > Activity explorer, filter Enforcement plane = Network"
Write-Host "  [ ] Purview portal > Settings > pay-as-you-go billing status"
Write-Host "  [ ] GSA client (device) > Troubleshooting > Advanced Diagnostics > Forwarding Profile tab"
```

**What it cannot do:** read GSA content policy definitions, security profile linkage, CA session-control configuration, or GSA/Purview traffic logs — none of these have a supported cmdlet/Graph read surface as of this writing; all require the portal checklist above.

---

## Command Cheat Sheet

| Purpose | Command |
|---------|---------|
| Connect to compliance PowerShell | `Connect-IPPSSession -UserPrincipalName <adminUPN>` |
| List DLP policies (filter for Inline web traffic manually) | `Get-DlpCompliancePolicy \| Select Name,Mode,Enabled,Workload` |
| List rules in a policy | `Get-DlpComplianceRule -Policy "<PolicyName>"` |
| Check tenant SKUs for licensing path | `Get-MgSubscribedSku` |
| GSA client diagnostics | Client icon → Troubleshooting → Advanced Diagnostics → Forwarding Profile tab (portal/client-only) |
| Content policies | Entra admin center → Global Secure Access → Secure → Content policies (portal-only) |
| Security profiles | Entra admin center → Global Secure Access → Secure → Security profiles (portal-only) |
| GSA traffic logs | Entra admin center → Global Secure Access → Monitor → Traffic logs (portal-only) |
| Purview network DLP evidence | Purview portal → Data Classification → Activity explorer, Enforcement plane = Network |
| Purview billing status | Purview portal → Settings → pay-as-you-go |

---

## 🎓 Learning Pointers

- **Network data security is a new enforcement plane on top of the existing Purview classification engine, not a new classification system.** The SITs, sensitivity labels, and confidence-tuning knobs from `DLP-Policy-A.md` all apply unchanged here — the only thing that's new is *where* the content is captured (network traffic via GSA) rather than *how* it's evaluated. MS Docs: [Learn about Microsoft Purview Network Data Security](https://learn.microsoft.com/en-us/purview/dlp-network-data-security-learn)

- **Two portals, two policy objects, and both are required — this is the single biggest source of "half-configured" tickets.** The GSA-side content policy and the Purview-side Inline web traffic DLP policy must both exist and be correctly scoped; each is inert without the other for text/file inspection beyond basic MIME-type blocking. MS Docs: [Create content policies for network content filtering](https://learn.microsoft.com/en-us/entra/global-secure-access/how-to-network-content-filtering)

- **Collection policies exist as a deliberately lower-risk on-ramp.** Before writing an enforcing DLP policy, a collection policy (or DSPM for AI's one-click default) gives visibility-only data into Activity Explorer with zero blocking risk — use this to build the actual scope of a client's shadow-AI exposure before deciding what to block.

- **The billing model (per-request, pay-as-you-go) is a genuine prerequisite gate, not just a cost consideration.** A tenant without pay-as-you-go configured literally cannot select Network as a DLP enforcement location — this is one of the first things to check when a policy "can't be created" rather than "isn't working."

- **Preview status is a real, not cosmetic, caveat.** No UDP/QUIC/HTTP-3 support, no B2B guest coverage, no wildcard destination matching at the top/second level, and ZIP-only compressed-content detection are all current, documented limitations — set client expectations explicitly rather than assuming feature parity with mature DLP workloads. Re-check the live Learn source before any client-facing commitment, since this is exactly the kind of scope that changes at GA.
