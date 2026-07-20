# Sentinel Notebooks (Jupyter / MSTICPy) — Reference Runbook (Mode A: Deep Dive)
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
- [Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

This covers **Jupyter notebooks in Microsoft Sentinel**, powered by **MSTICPy** (Microsoft's cybersecurity Python toolkit) and executed on an **Azure Machine Learning (AML)** workspace. It is the fourth pillar of this repo's Sentinel analyst-workflow coverage, sitting alongside [[Security/Sentinel/DataConnectors-A]] (ingest), [[Security/Sentinel/AnalyticsRules-A]] (detect), [[Security/Sentinel/UEBA-A]] (behavioral baseline), and [[Security/Sentinel/Hunting-A]] (query/bookmark/Hunts-based hunting) — this topic is the fully-programmable, code-first extension of that same hunting surface, for analysis that KQL and the portal's built-in hunting tools can't express (custom ML, non-standard visualizations, external data joins).

**Explicitly out of scope here** (covered elsewhere or not yet built):
- KQL-based hunting queries, bookmarks, and the Hunts (Preview) feature — see `Hunting-A.md`/`Hunting-B.md`.
- The broader Microsoft Sentinel **data lake** architecture (federated tables, data lake onboarding, KQL jobs as a livestream replacement) — see `Hunting-A.md`'s KQL-jobs section; a standalone data-lake-architecture topic beyond KQL jobs remains a candidate for a future run, not yet independently verified as a distinct gap.
- Azure Machine Learning as a general ML platform outside the Sentinel-notebook use case (model training pipelines, MLOps, endpoints) — only the notebook-authoring surface Sentinel launches into is covered.
- MSTICPy usage entirely outside Sentinel/AML (e.g., a local Anaconda install pointed at other log sources) — mentioned only where it affects the `MSTICPYCONFIG` environment-variable behavior.

---
## How It Works

<details><summary>Full architecture</summary>

Microsoft Sentinel's core data store exposes a common query API used by the portal, KQL-based hunting, and — via the same API — external tools including Jupyter notebooks and raw Python. The **Kqlmagic** library is the glue: it lets a notebook cell run a KQL string directly against a Sentinel/Log Analytics workspace and get results back as a pandas DataFrame.

Sentinel does not host the Jupyter execution environment itself. Instead, "Notebooks" in the Sentinel/Defender portal is a **launch and management surface** for notebooks that actually run inside a separate **Azure Machine Learning workspace** — a distinct Azure resource with its own resource group, RBAC, storage account, Key Vault, Application Insights instance, and (optionally) container registry. This split is the architectural fact that drives almost every troubleshooting scenario in this topic:

```
┌─────────────────────────────────────────────────────────────┐
│  Microsoft Sentinel (Azure portal or Defender portal)        │
│  "Notebooks" blade — Templates tab, save/launch UI            │
│  Governed by: Sentinel Reader / Responder / Contributor RBAC  │
└───────────────────────────┬────────────────────────────────┘
                             │ launches into
                             ▼
┌─────────────────────────────────────────────────────────────┐
│  Azure Machine Learning workspace (separate Azure resource)   │
│  Governed by: AML workspace RBAC (Owner/Contributor/Reader)   │
│    ├─ Storage account (default datastore, notebook files)     │
│    │    └─ PublicNetworkAccess / private endpoint config      │
│    ├─ Key Vault (secrets)                                     │
│    ├─ Application Insights (monitoring)                       │
│    └─ Compute instance(s) — Azure VM(s), personal per user    │
│         └─ Jupyter kernel (Python 3.6 or 3.8)                 │
│              └─ MSTICPy + msticpyconfig.yaml                  │
└─────────────────────────────────────────────────────────────┘
```

**Why the split exists:** notebooks need general-purpose compute, package management, and persistent per-user storage — capabilities Sentinel's own SIEM data plane doesn't provide and was never designed to. Reusing Azure Machine Learning gives Sentinel notebook users a real, scalable Jupyter platform (with tiered compute for heavier ML workloads) rather than Microsoft having to build and maintain a bespoke one. The cost is that access to "Sentinel notebooks" is gated by **two independent RBAC systems**, not one — a pattern this repo has already documented in other guises (compare the `IsEnabled`/`IsSchedulingEnabled` split in `EntraID/Troubleshooting/LifecycleWorkflows-A.md`, and UEBA's three-independently-gated-capabilities model in `UEBA-A.md`). Here it's not a feature-flag split but a **resource-boundary** split, which makes it easy to miss: a user with full Sentinel Contributor rights can still be completely unable to run a notebook if nobody separately granted them Contributor on the AML workspace.

**Notebook contents.** Two cell types make up every notebook:
- **Markdown cells** — instructions, explanations, static images.
- **Code cells** — executable Python (or, for a handful of Microsoft-provided notebooks, PowerShell/C# via alternate kernels).

Several notebooks ship pre-packaged with Sentinel (via the **Templates** tab), authored by Microsoft security analysts. Some are ready-to-use for a specific scenario (e.g., **Credential Scan on Azure Log Analytics**, **Guided Investigation - Process Alerts**); others are illustrative samples meant to be copied and adapted. A much larger set — sample notebooks, how-to notebooks, and community contributions — lives in the [Azure-Sentinel-Notebooks GitHub repository](https://github.com/Azure/Azure-Sentinel-Notebooks/) and is not surfaced directly in the portal; it must be cloned in (see Remediation Playbook 2) or downloaded and uploaded manually.

**MSTICPy's role.** Not every Sentinel notebook depends on MSTICPy — Credential Scanner notebooks and some PowerShell/C# samples don't — but the majority of the analyst-facing hunting/investigation notebooks do. MSTICPy provides:
- Query providers (including the `AzureSentinelAPI`/`MSSentinel` provider used to run KQL against the workspace)
- Threat intelligence lookups (VirusTotal and others)
- GeoIP lookups (MaxMind GeoLite2, IPStack)
- Data visualization helpers (timelines, process trees) built on `pandas`, `matplotlib`, and `bokeh`
- **Pivot functions** — entity-centric shortcuts (e.g., calling a TI lookup directly off an IP entity object) that depend on other providers being loaded first
- **Notebooklets** (via the separate `msticnb` package) — pre-built, parameterized investigation workflows that wrap multiple MSTICPy calls into a single higher-level call

All of MSTICPy's provider/auth/enrichment configuration lives in a single `msticpyconfig.yaml` file. When notebooks run inside AML and this file sits in the user's AML home folder, MSTICPy's `init_notebook` function (run in the standard initialization cell) auto-discovers it — no environment variable needed. Outside that specific location (a different AML folder, a non-AML Jupyter environment, or a shared config reused across compute instances), the `MSTICPYCONFIG` environment variable must point at it explicitly, and the Jupyter server must be restarted for that variable to take effect.

**Component load order matters.** When `init_notebook` autoloads MSTICPy components, it does so in a fixed, documented order: TILookup → GeoIP → AzureData → AzureSentinelAPI → Notebooklets → Pivot. Pivot is loaded last because it attaches pivot functions to entities based on whichever query/data providers are already active — if a component is deliberately excluded from autoload (e.g., in a stripped-down `MpConfigEdit` profile), Pivot functions tied to that provider simply won't exist, which surfaces later as a confusing `AttributeError` on an entity object rather than a clear "provider not loaded" message at init time.

</details>

---
## Dependency Stack

```
Layer 0 — Identity
  Entra ID account with access to both the Sentinel workspace AND the AML workspace tenant

Layer 1 — Sentinel-side authorization
  Microsoft Sentinel Reader / Responder / Contributor role at the Log Analytics workspace scope
    (Contributor required to save a template and launch a notebook)

Layer 2 — AML-side authorization (INDEPENDENT of Layer 1)
  AML workspace RBAC role (Contributor to run notebooks)
  Resource-group-level Owner/Contributor (only needed to CREATE a new AML workspace)

Layer 3 — AML workspace resource + network
  Storage account (default datastore) — PublicNetworkAccess setting / private endpoints
    → if restricted: direct "Launch notebook" from Sentinel is blocked; manual copy/upload required
  Key Vault, Application Insights, (optional) Container Registry

Layer 4 — Compute
  Compute instance (Azure VM) — personal to its creator, must be running/started
  Kernel selection (Python 3.8 recommended, or 3.6)

Layer 5 — Notebook runtime
  Cell execution order (state — including auth tokens — is wiped on kernel restart)
  Package environment (pip vs. %pip vs. conda-activated terminal installs behave differently)

Layer 6 — MSTICPy
  msticpyconfig.yaml (auto-discovered in AML user folder, or via MSTICPYCONFIG env var elsewhere)
  Query provider auth (AzureCLI / AzureSentinelAPI — default interactive/device-code, or optional
    client ID/secret, "not recommended" per Microsoft's own guidance)
  External data providers (VirusTotal API key, MaxMind GeoLite2 license key) — gate enrichment only,
    NOT core KQL query execution
  Autoload component order (TILookup → GeoIP → AzureData → AzureSentinelAPI → Notebooklets → Pivot)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| "Notebooks" blade shows templates but Save/Launch is greyed out or errors | User has Sentinel Reader/Responder, not Contributor | `Get-AzRoleAssignment` at the Sentinel workspace scope |
| Notebook saves fine but "Launch notebook" fails or does nothing | No AML workspace RBAC grant for the user (independent of #1) | `Get-AzRoleAssignment` at the AML workspace scope |
| "Configure Azure Machine Learning" wizard fails at workspace creation | User lacks RG-level Owner/Contributor | Confirm the target resource group's role assignments |
| Launch never completes, no error shown, blank/spinning page | AML storage account has private endpoints or restricted public network access | `Get-AzStorageAccount` → `PublicNetworkAccess` / `NetworkRuleSet` |
| Notebook opens but no cells will run | No compute instance, or instance is stopped | Check compute instance state in AML Studio or via `Get-AzResource` |
| First code cell takes minutes with a spinner before "Ready" appears | Cold-start of the compute instance — expected, not a fault | Wait; subsequent sessions reuse the started instance |
| MSTICPy prints configuration warnings on first run | Expected — config not populated yet, not an error | Walk the Getting Started Guide's config cells, save settings |
| `NameError` on a variable defined in an earlier cell | Kernel was restarted or cells run out of order — in-memory state including auth was wiped | Re-run from the init/auth cells forward |
| KQL query in the notebook returns empty, but works in the Sentinel/Defender portal | Wrong workspace alias active, or query provider not actually authenticated | `msticpy.current_providers`; re-check Autoload QueryProvs tab |
| TI/GeoIP lookups return null/blank while core queries work | Missing VirusTotal or MaxMind GeoLite2 API key — a separate config from Sentinel query auth | `MpConfigEdit` → Data Providers tab |
| Package installs "work" then break after switching Python 3.6 ↔ 3.8 kernels | `!pip install` used instead of `%pip` or a conda-activated terminal install | Reinstall via `%pip install --upgrade <pkg>`, restart kernel |
| Entity-based pivot function (e.g. `ip_entity.TILookup()`) throws `AttributeError` | The underlying provider was excluded from MSTICPy autoload, so Pivot never attached that function | Check Autoload Components tab for the missing provider |
| Notebook uses `!git clone` to pull the full Sentinel notebook repo and times out | Compute instance has no outbound internet (VNet-restricted AML deployment) | Confirm AML workspace networking mode; may require manual upload instead |
| Colleague can't see "my" compute instance | Compute instances are personal to their creator by design, not a bug | Each user needs their own compute instance |
| Everything above checks out, but the specific notebook itself errors | The notebook doesn't use MSTICPy at all (e.g. Credential Scanner, PowerShell/C# samples) | Confirm notebook type before applying any MSTICPy-specific fix |

---
## Validation Steps

1. **Confirm Sentinel RBAC.**
   ```powershell
   Get-AzRoleAssignment -Scope $sentinelWs.ResourceId -SignInName <user@domain.com>
   ```
   Good: role name contains "Microsoft Sentinel Contributor" (or Reader/Responder if launch isn't required). Bad: no matching role — user cannot save/launch templates.

2. **Confirm AML workspace RBAC — independently of step 1.**
   ```powershell
   Get-AzRoleAssignment -Scope $amlWs.ResourceId -SignInName <user@domain.com>
   ```
   Good: Contributor or Owner present. Bad: empty — this is the #1 real-world "Sentinel says I have access but notebooks won't launch" root cause.

3. **Confirm AML workspace network posture.**
   ```powershell
   Get-AzStorageAccount -ResourceId $amlStorageId | Select-Object PublicNetworkAccess, NetworkRuleSet
   ```
   Good: `PublicNetworkAccess = Enabled` (or the org has a documented manual-upload workflow if restricted). Bad: `Disabled`/restrictive rules with no fallback process communicated to users.

4. **Confirm a compute instance exists and its state.**
   ```powershell
   Get-AzResource -ResourceType "Microsoft.MachineLearningServices/workspaces/computes" -ResourceGroupName <AMLResourceGroup>
   ```
   Good: at least one instance in a `Running` (or startable) state for the affected user. Bad: none exists, or the only instance belongs to a different user (compute instances aren't shared).

5. **Inside the notebook, confirm MSTICPy initialized cleanly.**
   ```python
   import msticpy
   from msticpy.init import nbinit
   nbinit.init_notebook(namespace=globals())
   ```
   Good: completes, with expected first-run config warnings if `msticpyconfig.yaml` isn't fully populated yet. Bad: a hard exception — check `MSTICPYCONFIG` path and file validity.

6. **Confirm the active query provider targets the correct workspace.**
   ```python
   import msticpy
   msticpy.current_providers
   ```
   Good: lists the expected `qry_<workspace-or-alias>` object in a connected state. Bad: wrong workspace, or provider missing entirely.

7. **Confirm external enrichment providers are configured, if the notebook uses them.**
   In `MpConfigEdit` → Data Providers tab, confirm VirusTotal and MaxMind GeoLite2 entries exist with non-empty keys.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Access.** Run Validation Steps 1–2. Fix any RBAC gap before touching anything else; nothing downstream can be diagnosed meaningfully while access is broken.

**Phase 2 — Network.** Run Validation Step 3. If the storage account is network-restricted, stop troubleshooting "Launch notebook" entirely and move the user to the manual copy/upload workflow (Remediation Playbook 1) — no portal-side fix exists for this by design.

**Phase 3 — Compute.** Run Validation Step 4. Ensure a running, user-owned compute instance exists. Cold starts are normal; a permanently `Stopped`/`Failed` instance is not.

**Phase 4 — Kernel/runtime.** Confirm the correct kernel is selected (3.8 recommended). If package installs behave inconsistently, check whether `!pip install` was used across a kernel switch (Symptom → Cause row above) — reinstall via `%pip` or a conda-activated terminal session instead.

**Phase 5 — MSTICPy initialization.** Run Validation Step 5. First-run config warnings are expected. A hard failure here almost always traces to a missing/misplaced `msticpyconfig.yaml` or an unset `MSTICPYCONFIG` environment variable outside the AML default location.

**Phase 6 — Query/enrichment behavior.** Run Validation Steps 6–7. Distinguish "core Sentinel query auth is broken" (Validation 6) from "enrichment provider keys are missing" (Validation 7) — these are separate MSTICPy config sections and separate root causes, even though both can look like "the notebook doesn't return useful data."

---
## Remediation Playbooks

<details><summary>Playbook 1 — Onboarding a new analyst to Sentinel notebooks (greenfield)</summary>

1. Grant **Microsoft Sentinel Contributor** at the workspace scope (or Reader/Responder if launch isn't needed for this role).
2. Confirm an AML workspace already exists for the tenant; if not, an admin with RG-level Owner/Contributor creates one via **Notebooks > Configure Azure Machine Learning > Create a new AML workspace**, choosing **Enable public access from all networks** unless the org has a documented private-endpoint standard.
3. Grant the new analyst **Contributor** on that AML workspace.
4. Have the analyst launch **A Getting Started Guide For Microsoft Sentinel ML Notebooks** from the Templates tab, create their own compute instance (General Purpose category is sufficient for most hunting notebooks), and walk the initialization → query-provider → external-data-provider configuration cells in order.
5. Confirm success: the analyst can run a sample query against live Sentinel data and see a populated DataFrame.

No rollback needed — this is purely additive access.

</details>

<details><summary>Playbook 2 — Pulling the full community notebook library into the workspace</summary>

From inside any working Sentinel notebook cell:

```python
!git clone https://github.com/Azure/Azure-Sentinel-Notebooks.git azure-sentinel-nb
```

To refresh later:

```python
!cd azure-sentinel-nb && git pull
```

Requires outbound internet access from the compute instance. If the AML workspace is deployed into a restricted VNet with no outbound access to GitHub, this will time out — the manual alternative is downloading the repo as a zip outside AML and uploading the specific notebooks needed through AML Studio's file upload.

</details>

<details><summary>Playbook 3 — Working around a network-restricted AML workspace (no direct launch)</summary>

For workspaces where the storage account has private endpoints or restricted public network access (Validation Step 3 fails):

1. In Sentinel, open the desired template under **Notebooks > Templates** and copy its full content, or download the equivalent `.ipynb` directly from the [Sentinel Notebooks GitHub repo](https://github.com/Azure/Azure-Sentinel-Notebooks/).
2. Navigate directly to the AML Studio for that workspace (`https://ml.azure.com`) — bypass the Sentinel "Launch notebook" button entirely.
3. Upload the notebook file into the analyst's user folder.
4. Attach/start a compute instance and run normally.

Document this as the standard operating procedure for that tenant rather than re-diagnosing it as a fault every time a new analyst hits it — it is expected, permanent behavior for as long as the network restriction remains in place, not a transient issue.

</details>

<details><summary>Playbook 4 — Recovering from a corrupted or misplaced msticpyconfig.yaml</summary>

1. Confirm the current file location: if it's not in the AML user folder root, MSTICPy needs the `MSTICPYCONFIG` environment variable set.
2. If corrupted, don't hand-edit YAML — re-run **A Getting Started Guide For Microsoft Sentinel ML Notebooks** notebook's configuration cells, which drive the `MpConfigEdit` UI tool and regenerate a valid file section-by-section (Data Providers, Autoload QueryProvs, Autoload Components).
3. If secrets (VirusTotal Enterprise keys, etc.) are involved, move them to Azure Key Vault references inside the config rather than storing them in plaintext, especially if the file lives in shared (non-compute-local) AML storage — compute-instance-local storage is accessible only to its creator, but the shared workspace storage is accessible to anyone with AML workspace access.
4. **Save File** in `MpConfigEdit`, then restart the kernel and re-run `init_notebook` to pick up the environment variable and new config cleanly.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects Sentinel Notebooks readiness evidence for escalation.
.NOTES     Read-only. Requires Az.Accounts, Az.OperationalInsights, Az.Storage, Az.Resources.
           Does not (and cannot, via PowerShell) inspect msticpyconfig.yaml, compute instance
           kernel state, or in-notebook MSTICPy provider status — capture those manually.
#>
param(
    [Parameter(Mandatory)][string]$SentinelResourceGroup,
    [Parameter(Mandatory)][string]$SentinelWorkspaceName,
    [Parameter(Mandatory)][string]$AMLResourceGroup,
    [string]$AMLWorkspaceName,
    [string]$UserPrincipalName
)

$sentinelWs = Get-AzOperationalInsightsWorkspace -ResourceGroupName $SentinelResourceGroup -Name $SentinelWorkspaceName
$evidence = [ordered]@{
    SentinelWorkspace        = $SentinelWorkspaceName
    SentinelRoleAssignments  = Get-AzRoleAssignment -Scope $sentinelWs.ResourceId | Where-Object { $_.RoleDefinitionName -like "*Sentinel*" }
}

if ($AMLWorkspaceName) {
    $amlWs = Get-AzResource -ResourceType "Microsoft.MachineLearningServices/workspaces" -Name $AMLWorkspaceName -ResourceGroupName $AMLResourceGroup
    $evidence["AMLWorkspaceRoleAssignments"] = Get-AzRoleAssignment -Scope $amlWs.ResourceId
    $storageId = $amlWs.Properties.storageAccount
    if ($storageId) {
        $evidence["AMLStorageNetworkPosture"] = Get-AzStorageAccount -ResourceId $storageId | Select-Object StorageAccountName, PublicNetworkAccess, NetworkRuleSet
    }
    $evidence["ComputeInstances"] = Get-AzResource -ResourceType "Microsoft.MachineLearningServices/workspaces/computes" -ResourceGroupName $AMLResourceGroup |
        Where-Object { $_.Name -like "$AMLWorkspaceName/*" }
}

$evidence | ConvertTo-Json -Depth 6 | Out-File "SentinelNotebookEvidence_$(Get-Date -Format yyyyMMdd_HHmm).json"
Write-Host "Evidence exported. Attach manually: msticpyconfig.yaml contents (redact secrets), notebook error screenshot, and 'msticpy.current_providers' output from the failing session." -ForegroundColor Yellow
```

---
## Command Cheat Sheet

| Purpose | Command |
|---|---|
| Sentinel role check | `Get-AzRoleAssignment -Scope $sentinelWs.ResourceId -SignInName <user>` |
| Grant Sentinel Contributor | `New-AzRoleAssignment -SignInName <user> -RoleDefinitionName "Microsoft Sentinel Contributor" -Scope $sentinelWs.ResourceId` |
| AML workspace role check | `Get-AzRoleAssignment -Scope $amlWs.ResourceId -SignInName <user>` |
| Grant AML Contributor | `New-AzRoleAssignment -SignInName <user> -RoleDefinitionName "Contributor" -Scope $amlWs.ResourceId` |
| Find AML workspace | `Get-AzResource -ResourceType "Microsoft.MachineLearningServices/workspaces"` |
| AML storage network posture | `Get-AzStorageAccount -ResourceId $storageId \| Select PublicNetworkAccess,NetworkRuleSet` |
| Find compute instances | `Get-AzResource -ResourceType "Microsoft.MachineLearningServices/workspaces/computes"` |
| Re-run MSTICPy init (in-notebook) | `nbinit.init_notebook(namespace=globals())` |
| Check active query providers (in-notebook) | `msticpy.current_providers` |
| Correct package upgrade (in-notebook) | `%pip install --upgrade msticpy` |
| Correct package upgrade (terminal) | `conda activate azureml_py38 && pip install --upgrade msticpy` |
| Clone full notebook library (in-notebook) | `!git clone https://github.com/Azure/Azure-Sentinel-Notebooks.git azure-sentinel-nb` |
| Open MSTICPy settings editor (in-notebook) | `mpedit.set_tab("Data Providers"); mpedit` |
| Set config path outside AML default location | Environment variable `MSTICPYCONFIG` → path, then restart Jupyter server |

---
## 🎓 Learning Pointers
- Treat "Sentinel Notebooks" mentally as two products glued together — a Sentinel-side launcher and an independent Azure Machine Learning environment — every time a colleague reports "I have access but it won't work," check both RBAC surfaces before assuming either is broken. This is the same shape of trap as `EntraID/Troubleshooting/LifecycleWorkflows-A.md`'s `IsEnabled`/`IsSchedulingEnabled` split and `UEBA-A.md`'s three-independently-gated-capabilities model — worth building a general instinct for "looks like one toggle, is actually several" across this whole knowledge base.
- MSTICPy's fixed component autoload order (TILookup → GeoIP → AzureData → AzureSentinelAPI → Notebooklets → Pivot) exists specifically because Pivot depends on the others — read [MSTICPy Pivot Functions](https://msticpy.readthedocs.io/en/latest/data_analysis/PivotFunctions.html) before assuming a missing pivot method is a bug rather than a missing autoload component.
- The private-endpoint/restricted-storage "Launch notebook" gap is a genuine, documented product limitation with no portal-side fix — see [Launch a notebook in your Azure Machine Learning workspace](https://learn.microsoft.com/en-us/azure/sentinel/notebooks-hunt#launch-a-notebook-in-your-azure-machine-learning-workspace). Worth flagging proactively to clients who plan to lock down AML workspace networking, before they discover it via a failed launch.
- `!pip install` vs. `%pip install` is a real, easy-to-miss Jupyter/conda footgun specific to Azure ML's kernel-switching behavior — see [Advanced configurations for Jupyter notebooks and MSTICPy](https://learn.microsoft.com/en-us/azure/sentinel/notebooks-msticpy-advanced#switch-between-python-36-and-38-kernels).
- For deeper investigation-notebook authoring beyond the Getting Started template, the `msticnb` (Notebooklets) package wraps common multi-step investigations into single calls — see the [MSTICNB documentation](https://msticnb.readthedocs.io/en/latest/) — a useful next step once an analyst is comfortable with raw MSTICPy query providers.
- Community background: [Create your first Microsoft Sentinel notebook](https://techcommunity.microsoft.com/t5/microsoft-sentinel-blog/creating-your-first-microsoft-sentinel-notebook/ba-p/2977745) (Microsoft's own blog series) and the [Azure-Sentinel-Notebooks GitHub wiki](https://github.com/Azure/Azure-Sentinel-Notebooks/wiki/) for FAQs and real sample notebooks beyond the handful shipped in the portal Templates tab.
