# Windows 365 for Agents — Hotfix Runbook (Mode B: Ops)
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

**Read this first:** Windows 365 for Agents is a **pool-based**, not device-based, Cloud PC model built for AI agent workloads (Copilot Studio computer use, Project Opal, Researcher, and Agent 365 agents) rather than a named human user. A "Cloud PC for Agents" is checked out of a shared pool by an agent when it needs one and returned when the task finishes — there is no persistent 1:1 user assignment, and the VM resets after each use. Tickets about these devices almost always resolve to one of three places: the **pool** (status/capacity), the **provisioning policy (agents)** (config drift, since edits don't auto-reprovision), or **Intune device visibility** (the legacy device view hides them by default). Identify which bucket the symptom belongs to before troubleshooting further.

Run these first, in this order:

```powershell
Connect-MgGraph -Scopes "CloudPC.Read.All","DeviceManagementManagedDevices.Read.All","DeviceManagementConfiguration.Read.All"

# 1 — Find the Cloud PC agent pool and its current status (pool-level, not per-VM).
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -All |
    Where-Object { $_.CloudPcNamingTemplate -like 'CPCA-*' -or $_.ProvisioningType -eq 'agents' } |
    Select-Object DisplayName, Id, ProvisioningType

# 2 — Confirm the device actually shows up (legacy device view hides Cloud PCs for Agents details).
Get-MgDeviceManagementManagedDevice -Filter "startswith(deviceName,'CPCA-')" |
    Select-Object DeviceName, Model, EnrolledDateTime, LastSyncDateTime, ManagementAgent

# 3 — Check session usage against the policy's Always Available Cloud PCs count.
#     (Active sessions + Available sessions = Always available Cloud PCs count — no dedicated
#     single Graph property for this pairing as of this writing; cross-reference the
#     admin center's Provisioning policies (Agents) session view against the CloudPc count below.)
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -Filter "provisioningPolicyId eq '<PolicyId>'" |
    Select-Object DisplayName, Status, ProvisioningPolicyId
```

| Symptom | Likely cause | Go to |
|---------|-------------|-------|
| Pool status shows **Failed** — no available devices, none can provision | Underlying provisioning failure (image, licensing, network) at the pool level — same failure classes as Enterprise Cloud PC provisioning, but evaluated for the whole pool | Fix 1 |
| Pool status shows **Available with warning** | Some reprovisions/updates failed but the pool still has usable devices | Fix 2 |
| Agent request fails to check out a Cloud PC ("no capacity") | Active + Available sessions already equal Always Available Cloud PCs count — pool is saturated | Fix 3 |
| Edited provisioning policy (agents), but existing Cloud PCs behave unchanged | Windows 365 does **not** auto-reprovision on policy edit for most properties — a manual reprovision (or waiting for natural pool churn) is required | Fix 4 |
| Devices under **Devices > All devices** show blank/missing detail for `CPCA-*` entries | Known issue: the **default (legacy) device view** doesn't render detail for Cloud PCs for Agents | Fix 5 |
| Admin tries to edit a Copilot Studio computer use / Project Opal / Researcher provisioning policy inside Intune | Those partners' policies are created and owned in their own portals and appear **read-only** in Intune — Intune is view-only for this class | Fix 6 |
| Apps/policies not applying to Cloud PCs for Agents | Assignment targets a static/user-based group; these are pool-provisioned, non-persistent VMs — must target by device-name-prefix filter, device model, or enrollment profile instead | Fix 7 |
| Human wants interactive access to a Cloud PC for Agents like an Enterprise Cloud PC | Not the intended access model — Cloud PCs for Agents are reached via Computer-Get/Computer-Do APIs (agentic) or a chat UX (human), not the Windows App/RDP client used for Enterprise Cloud PCs | Fix 8 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Provisioning policy (agents) created (Intune admin center or Cloud PC Graph APIs)
    │
    ├── Billing plan + Region + Cloud PC count + Image (all required at pool creation)
    │
    └── Computer-Create subsystem provisions the pool
            └── Same underlying provisioning pipeline as Windows 365 Enterprise
                (Hosted-On-Behalf-Of / HOBO architecture — Microsoft-managed subscription)
                    ├── Microsoft Entra enrollment (mandatory, same as Enterprise)
                    └── Microsoft Intune enrollment (mandatory, same as Enterprise)
                            └── Device appears as "CPCA-*" / model "Cloud PC for Agents"
                                    │
                                    └── Cloud PC agent pool reaches status: Available
                                            │
                                            ├── Computer-Get: agent calls MCP server to
                                            │   check out a Cloud PC (Active sessions++)
                                            │       └── Computer-Do: MCP action API (click/
                                            │           type/navigate/run) relayed to the
                                            │           on-box CUA client on the checked-out VM
                                            │
                                            └── Computer-See & Computer-Take-Control: human
                                                interactive chat UX via IC3 media (separate
                                                access path, not required for agentic use)
```

**Key fact:** status is evaluated **at the pool level, not per-VM** — an individual failed Cloud PC inside an otherwise-healthy pool does not surface as a device-level ticket the way an Enterprise Cloud PC failure would; it shows up as "Available with warning" at the policy/pool level instead. Also key: for third-party agent solutions (Copilot Studio, Project Opal, Researcher), the provisioning policy itself lives in that partner's portal — Intune only mirrors a read-only view, so "policy won't save" tickets for those are never an Intune-side problem.

</details>

---
## Diagnosis & Validation Flow

1. **Classify the ticket first**: is this about the *pool* (capacity/status), the *policy* (configuration, ownership), or *device visibility* (Intune UI)? Each has a different fix path below.

2. **Check pool status** (Devices > Provision Cloud PCs > Provisioning policies (Agents) > select policy, or via Graph):
   - `Creating` / `Updating` — transient, wait.
   - `Available` — healthy; if a symptom persists here, it's a session-capacity or policy-assignment issue, not a pool-health issue.
   - `Available with warning` — some devices failed to update/reprovision but the pool is still usable — go to Fix 2.
   - `Failed` — no available devices at all — go to Fix 1.

3. **For "can't get a Cloud PC" reports**, check session math: **Active sessions + Available sessions = Always available Cloud PCs count**. If Active already equals the total, the pool is genuinely saturated — this is a capacity/sizing conversation, not a bug.

4. **For "my policy edit didn't take effect" reports**, confirm whether the changed property is one that requires manual reprovision — Windows 365 does not reprovision automatically on every provisioning policy (agents) edit. Compare against the property list in "Edit a provisioning policy (agents)" before assuming a platform bug.

5. **For "device missing details" reports**, confirm **Preview new device view** is turned on for the admin viewing the device — this is a known, documented gap in the legacy/default device view specifically for `CPCA-*` devices, not a sync or enrollment failure.

6. **For third-party agent solution policies (Copilot Studio computer use, Project Opal, Researcher)**, confirm the admin is looking in the right portal — Intune's **Devices > Provision Cloud PCs > Provisioning policies** view for these is read-only by design; all edits happen in the partner's own portal (Copilot Studio, etc.).

---
## Common Fix Paths

<details><summary>Fix 1 — Pool status: Failed</summary>

1. This mirrors Enterprise Cloud PC provisioning failure triage — check the same root causes at pool scope: source image availability/corruption, licensing/billing plan validity for the pool's assigned SKU, and network capacity in the selected region.
2. Because status is pool-level, a `Failed` pool means **zero** devices are available — this is a full-outage-for-this-workload situation for whichever agent(s) depend on it; treat with matching urgency.
3. There is no supported "retry" action distinct from correcting the underlying cause and allowing the pool to reprovision — fix the root cause (image/licensing/region capacity) first.

</details>

<details><summary>Fix 2 — Pool status: Available with warning</summary>

1. Some Cloud PCs in the pool failed an update/reprovision cycle, but others remain usable — this is a degraded, not down, state.
2. Check the count of available devices against expected pool size; if materially under-provisioned, escalate as a capacity risk even though agents can still check out a Cloud PC today.
3. Root-cause the specific failed devices the same way as Fix 1 (image/licensing/network) rather than assuming the warning will self-clear.

</details>

<details><summary>Fix 3 — No capacity to check out a Cloud PC</summary>

1. Confirm via the provisioning policy's session view (Active vs. Available sessions) that the pool is genuinely at its **Always available Cloud PCs count** ceiling — this is billing/consumption-based, so raising the count is a deliberate cost decision, not a free fix.
2. If usage is bursty, this is a sizing conversation with whoever owns the agent workload's budget — Windows 365 for Agents does not auto-scale a pool's ceiling on its own.
3. Confirm the requesting agent/orchestrator is actually checking sessions back in when done — a workload that never calls check-in will exhaust the pool even with adequate sizing.

</details>

<details><summary>Fix 4 — Provisioning policy (agents) edited, no visible change</summary>

1. Identify which property was changed and cross-reference it against "Edit a provisioning policy (agents)" to confirm whether it's one of the properties requiring reprovision.
2. If it is, trigger a manual reprovision (or wait for natural pool churn/reset-after-use cycling) — Windows 365 does not do this automatically.
3. Set the expectation up front with whoever owns the workload: config changes to a live agent pool are not instant the way they might assume from other cloud consoles.

</details>

<details><summary>Fix 5 — CPCA-* devices show blank/missing detail</summary>

1. Turn on **Preview new device view** for the affected admin — this is a documented, known gap in the legacy view specifically for Cloud PCs for Agents, not a data or sync problem.
2. Confirm the device does appear correctly (name, model "Cloud PC for Agents", enrollment profile matching the policy name) once the new view is enabled before escalating further.

</details>

<details><summary>Fix 6 — Can't edit a third-party agent solution's provisioning policy in Intune</summary>

1. This is by design — for Copilot Studio computer use, Project Opal, and Researcher, the provisioning policy is owned and edited in that partner's own portal; Intune's copy under Provisioning policies is **read-only**.
2. Redirect the requester to the relevant partner portal (e.g., Copilot Studio's "Use a Cloud PC pool for computer use runs" settings) rather than continuing to search for an edit control in Intune.

</details>

<details><summary>Fix 7 — App/policy assignment not reaching Cloud PCs for Agents</summary>

1. These devices are pool-provisioned and non-persistent (reset after each checked-in session) with no primary human user — a user-based or standard static-device-group assignment will not reliably target them.
2. Re-scope the assignment using the `CPCA-` device name prefix, the **Cloud PC for Agents** device model, or the enrollment profile name (which matches the provisioning policy name) via a dynamic device group or an assignment filter.
3. Optionally, link a Microsoft Entra group or an Intune Autopilot device preparation profile directly at pool-creation time (Cloud PC agent pool device grouping and preparation) rather than retrofitting group membership after the fact.

</details>

<details><summary>Fix 8 — Expecting interactive human access like an Enterprise Cloud PC</summary>

1. Set expectations: Cloud PCs for Agents are reached through the **Computer-Get** (check-out/check-in) and **Computer-Do** (action) APIs for agentic orchestration, or a **chat UX** for human interactive sessions via Computer-See & Computer-Take-Control — not the Windows App, web client, or RDP path used for Enterprise/Business Cloud PCs.
2. If the actual requirement is a persistent, user-assigned Cloud PC with standard client access, the correct product is Windows 365 Enterprise/Business/Flex (see `Windows365-A.md`/`Flex-A.md`), not Windows 365 for Agents.

</details>

---
## Escalation Evidence

```
WINDOWS 365 FOR AGENTS — ESCALATION TEMPLATE
============================================
Tenant:                          <tenant name/ID>
Provisioning policy (agents) name: <name>
Consuming agent solution:        <Agent 365 / Copilot Studio computer use / Project Opal /
                                   Researcher / other>
Pool status:                     <Creating / Available / Updating / Available with warning /
                                   Failed / Deleting>
Always available Cloud PCs count: <value>
Active sessions / Available sessions: <value> / <value>
Affected device name(s):         <CPCA-... prefix if known>
Preview new device view enabled: <Y/N — required to see CPCA-* device detail>
Region / billing plan / image:   <values>
Recent policy edits (if any):    <property changed, date, reprovisioned Y/N>
```

---
## 🎓 Learning Pointers

- **This is a pool, not a device, management model.** Status, capacity, and most troubleshooting live at the provisioning-policy(agents)/pool level, not the individual Cloud PC — a mental model carried over from Enterprise Cloud PC troubleshooting will misdirect the first 10 minutes of triage. See [What is Windows 365 for Agents?](https://learn.microsoft.com/en-us/windows-365/agents/introduction-windows-365-for-agents) and [Cloud PC agent pools](https://learn.microsoft.com/en-us/windows-365/agents/cloud-pc-agent-pools).
- **Provisioning policy edits are not automatically applied to running Cloud PCs.** Always check whether a change requires manual reprovision before assuming a platform bug — see [Edit a provisioning policy (agents)](https://learn.microsoft.com/en-us/windows-365/agents/edit-provisioning-policy-agents).
- **The legacy device view has a known, documented gap** for `CPCA-*` devices — turn on Preview new device view before spending time on what looks like a missing-inventory-data ticket.
- **Third-party agent solution policies are read-only in Intune by design** — Copilot Studio, Project Opal, and Researcher own their own provisioning policy inside their own portals; don't chase a missing "Edit" button in Intune for these.
- **Consumption-based billing means capacity is a cost decision, not a platform limit to escalate against Microsoft.** A saturated pool is resolved by resizing the Always Available Cloud PCs count (spend) or by the workload checking sessions back in more promptly (efficiency) — not by an Intune support ticket.
- See `Agents-A.md` for the full four-subsystem architecture (Computer-Create/Get/Do/See) if the ticket requires explaining *why* the check-out model behaves this way, not just how to fix it.
