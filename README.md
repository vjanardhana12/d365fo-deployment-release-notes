# D365 F&O Deployment Release Notes

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**One-click deployment release notes for Dynamics 365 Finance & Operations** — published to your Azure DevOps project wiki on every build, then live-updated by each deployment stage. Zero manual effort, full traceability across DevTest → UAT → PROD.

---

## What gets published — per build

Every build creates one wiki page (`Build-<number>.md`) under `Deployment-release-notes/<branch>/` with:

### Metadata table (top of page)
| Cell | Content |
|---|---|
| **Release** | `⏳ Awaiting deployment` → flips to `[Release N](url) 🟢 Deployed` after each stage |
| **Build / Build date** | Build link + start time |
| **Branch / Repository** | Source ref + repo name |
| **Triggered by** | Person who triggered the build |
| **Commit** | 8-char SHA linked to the commit diff |
| **Schedule** | `Daily 00:15 CET` (auto-pulled from pipeline schedule trigger) |
| **Tag** | `uat-<build>` (release) / `v1.2.0` (prod, SemVer) auto-injected when tag is created |
| **Compare** | `<prevBuild> → <thisBuild>` link to ADO branch-compare across builds |

### Deployment status strip
Live, click-through strip of all release stages with traffic-light icons:
```
[DevTest](url) 🟢 → [UAT](url) 🟢 → [PROD](url) ⚪
Legend: 🟢 Deployed · 🟠 Partial · 🔴 Failed · ⚪ Pending
```
Each deployment stage re-runs the script and refreshes the strip with current REST status.

### Auto-injected sections
- **Priority Test Items** — 🚨 callout listing all S1/S2 bug fixes shipping in this build (so testers test those first)
- **Post-Deployment Actions** — manual steps the deployer must take, only when relevant:
  - 🔐 Security objects → verify role/duty assignments
  - 🗂 Data entities → refresh entity list in Data Management
  - 🔁 Workflows → activate/configure under module > Setup > Workflows
  - 🔢 Number sequences → run Generate wizard
  - 🏷 Financial dimensions → activate under GL > COA > Dimensions
  - ⚙ Configuration keys → review under Sys admin > Licensing
  - 📡 Business events → activate under Sys admin > Setup > Business events
  - ⏰ Batch jobs (detected via new `*Controller`/`*Batch` classes + new menu items)
  - Plus a *New objects introduced* counts summary
- **User Stories / Tasks / Bugs / Document Deliverables / Configuration Deliverables** — tables from ADO work items linked to the build
- **Bugs** — auto-sorted by Severity then Priority (S1 rows first)
- **Pull Requests** — who raised, source/target branch, who approved (🟢 / ✓); cherry-picked PRs are re-attributed to the original author
- **Data Entity Changes** — new/modified/deleted entities with field-level diff
- **Package Versions** — all NuGet packages (Platform / Foundation / ISV) from `packages.config`
- **Data Migration · Test Notes · Known Issues · Rollback Plan · Notes** — section-of-record placeholders (always rendered; show `_No xxx linked_` italic line when empty)

### Cosmetic post-processing
- Long 40-char commit SHAs in tables are shortened to 8 chars (URL kept full)
- `(EXT)` external-account suffixes are stripped from names
- Empty 3-row placeholder tables collapse to a single italic line
- Optional auto-tagging of the source commit per branch (release → `uat-<build>`, prod → SemVer `v1.2.0`)

---

## Prerequisites

| # | Requirement | Why |
|---|---|---|
| 1 | **Azure DevOps account** with a project | Where your code, builds, releases & wiki live |
| 2 | **Project wiki** (NOT a code-as-wiki) | Created via Project Settings → Wiki → Create project wiki |
| 3 | **Source code repo** in the same project (e.g. for D365 F&O X++ metadata) | Compare & Post-Deployment detection read this repo |
| 4 | **Classic Release pipeline** (Releases UI, NOT YAML multi-stage) | Required because `Update-WikiReleaseNotes.ps1` is a post-deployment task per stage and reads `$env:RELEASE_*` |
| 5 | **Build pipeline** that produces an artifact consumed by the release | Standard for D365 F&O |
| 6 | **Azure DevOps marketplace extensions** (free):<br>• [Generate Release Notes (Crossplatform)](https://marketplace.visualstudio.com/items?itemName=richardfennellBM.BM-VSTS-XplatGenerateReleaseNotes)<br>• [Wiki Updater Tasks](https://marketplace.visualstudio.com/items?itemName=richardfennellBM.BM-VSTS-WIKIUpdater-Tasks) | Generates the markdown + pushes it to the wiki |
| 7 | **Build agent with `git`** | Microsoft-hosted agents already have it |
| 8 | **PowerShell 5.1+ or PowerShell 7+** | Microsoft-hosted Windows agents have both |
| 9 | **`System.AccessToken` enabled on the agent job** | Needed for REST calls and wiki clone. Set on every job: `Allow scripts to access the OAuth token` |
| 10 | **Permission**: per-project Build service must have `Contribute` on the wiki git repo | One-time grant via `setup/Grant-BuildPermission.ps1` (handles the `TF401027` error automatically) |

> **Not D365-specific?** The script works for any ADO project. The Post-Deployment Actions detector is D365-aware (looks at `Ax*` folder names) but harmless on non-D365 repos — it just emits nothing.

---

## Step-by-step setup (one-time)

### Step 1 — Install the two marketplace extensions
Open both links in [Prerequisites #6](#prerequisites) and click **Get it free → Install** into your ADO organization. Requires org admin.

### Step 2 — Clone this repo and copy files into your repo
```powershell
git clone https://github.com/vjanardhana12/d365fo-deployment-release-notes.git
cd d365fo-deployment-release-notes
```
Copy three things into your own source repo:
```
release-notes-template/release-notes-template.md   →  release-notes-template/release-notes-template.md
pipelines/release-notes-stage.yaml                 →  pipelines/release-notes-stage.yaml
pipelines/scripts/Update-WikiReleaseNotes.ps1      →  pipelines/scripts/Update-WikiReleaseNotes.ps1
```

### Step 3 — Create the wiki folder structure
```powershell
.\setup\Setup-WikiStructure.ps1 `
    -Organization "https://dev.azure.com/yourorg" `
    -Project      "YourProject" `
    -WikiName     "YourProject.wiki"
```
Creates:
```
Deployment-release-notes/
├── Deployment-release-notes.md   (parent page)
├── .order
├── Main-branch.md
├── Prod-branch.md
├── Hotfix-branch.md
└── Release-branch.md
```

### Step 4 — Grant the Build service `Contribute` on the wiki repo
```powershell
.\setup\Grant-BuildPermission.ps1 `
    -Organization "https://dev.azure.com/yourorg" `
    -Project      "YourProject"
```
Without this you'll hit `TF401027: You need GenericContribute permission` on the very first wiki push. The script uses ADO Security REST API to grant the permission programmatically.

### Step 5 — Wire the build pipeline (publish the page on every build)
Add the stage template to the **build pipeline** (`azure-pipelines.yml`) that already builds your D365 F&O artifact:
```yaml
stages:
- stage: Build
  # ... your existing build ...

- template: pipelines/release-notes-stage.yaml
  parameters:
    wikiRepoUrl:        'https://yourorg@dev.azure.com/yourorg/YourProject/_git/YourProject.wiki'
    branchFolder:       'Main-branch'         # or 'Prod-branch' / 'Hotfix-branch' / 'Release-branch'
    packagesConfigPaths: |
      $(Build.SourcesDirectory)\src\xpp\xppBuild\AzureBuild\packages.config
    foundationPackagePattern: 'YourFoundationModuleNamePrefix'   # optional regex
```
See [examples/pipeline-snippet.yaml](examples/pipeline-snippet.yaml) for the full file.

> **Enable `System.AccessToken`** under the job → **Additional options** → ✅ Allow scripts to access the OAuth token.

### Step 6 — Wire the Classic Release pipeline (live-update the page on each stage)

On **every release stage** (DevTest, UAT, PROD, …) add a single PowerShell task **after** the deployment task:

| Field | Value |
|---|---|
| **Task** | PowerShell |
| **Type** | File Path |
| **Script Path** | `$(System.DefaultWorkingDirectory)/_<your-build-artifact>/drop/pipelines/scripts/Update-WikiReleaseNotes.ps1` |
| **Arguments** | (see below) |
| **Working Directory** | `$(System.DefaultWorkingDirectory)` |

Sample **Arguments** (one line, all on the PS task input):
```powershell
-Environment "$(Release.EnvironmentName)" -WikiRepoUrlBase "https://dev.azure.com/yourorg/YourProject/_git/YourProject.wiki" -RepoName "YourSourceRepo" -EnvUrlMapJson '{"DEV":"https://yourenv-dev.sandbox.operations.eu.dynamics.com/","UAT":"https://yourenv-uat.sandbox.operations.eu.dynamics.com/","PROD":"https://yourenv.operations.dynamics.com/"}' -CreateTag $true
```

> **Enable OAuth token** on the agent job (same as Step 5).
> Add the script as a **continueOnError** task so wiki failures never block deployment (the script itself is also trap-guarded).

### Step 7 — Run a build
1. Push a commit / queue a build.
2. The build publishes `Deployment-release-notes/<branch>/Build-<number>.md` to the wiki with the metadata table, deployment strip (⚪⚪⚪), and `⏳ Awaiting deployment`.
3. Kick off a release for that build. As each stage finishes, the wiki page is updated with the live status strip and `🟢 Deployed` link.

---

## Script parameter reference (`Update-WikiReleaseNotes.ps1`)

| Param | Default | Purpose |
|---|---|---|
| `-Environment` | _required_ | Fallback label for the current stage. Usually `$(Release.EnvironmentName)`. |
| `-WikiRepoUrlBase` | _required_ | Wiki git URL. e.g. `https://dev.azure.com/org/proj/_git/proj.wiki`. |
| `-RepoName` | `$env:BUILD_REPOSITORY_NAME` | Source-code repo (NOT wiki) — used to build Compare / commit / diff URLs. |
| `-BuildNumber` | `$env:BUILD_BUILDNUMBER` | Triggering build number. |
| `-SourceBranchName` | `$env:BUILD_SOURCEBRANCHNAME` | Triggering branch. |
| `-WikiBranch` | `wikiMaster` | Default wiki branch (don't change unless customized). |
| `-TargetDir` | `$(System.DefaultWorkingDirectory)\wiki` | Local clone directory. |
| `-Token` | `$env:SYSTEM_ACCESSTOKEN` | OAuth token. |
| `-EnvUrlMapJson` | `''` | JSON map of stage name → environment URL. Makes strip entries clickable. |
| `-CreateTag` | `$false` | Auto-tag the build commit when stage matches `TagTriggerJson`. |
| `-TagTriggerJson` | `'{"release":"UAT","prod":"PROD"}'` | Which branch/stage combos create tags. |
| `-GitUserEmail` | `ado-pipeline@noreply.local` | Email used for the tag commits. |
| `-GitUserName` | `Azure DevOps Pipeline` | Name used for the tag commits. |

### Tag format (when `-CreateTag $true`)
| Branch | Tag |
|---|---|
| `release` | `uat-<buildNumber>` |
| `prod` | `v<MAJOR>.<MINOR>.<PATCH>` — bump driven by release variable `RELEASETYPE`: `Sprint` (MINOR), `Hotfix` (PATCH), `Country` (MAJOR). Seeds `v1.0.0` if no prior tag. |
| _other_ | `build-<buildNumber>` |

---

## File layout

```
├── release-notes-template/
│   └── release-notes-template.md      # Handlebars template (single file, all branches)
├── pipelines/
│   ├── release-notes-stage.yaml       # Reusable YAML stage (build pipeline)
│   └── scripts/
│       └── Update-WikiReleaseNotes.ps1   # Post-deployment task script (release pipeline)
├── setup/
│   ├── Setup-WikiStructure.ps1        # One-time wiki folder creation
│   └── Grant-BuildPermission.ps1      # One-time wiki Contribute permission
└── examples/
    ├── pipeline-snippet.yaml          # Drop-in stage example
    └── custom-template-example.md     # Adding project-specific ADO fields
```

---

## Architecture

```
Build pipeline (per commit)                Classic Release (per stage, every env)
────────────────────────────               ─────────────────────────────────────
1. XplatGenerateReleaseNotes               5. Update-WikiReleaseNotes.ps1
   → releaseNotes.md (work items + PRs)      → Clone wiki repo
                                              → Query LIVE release stages via REST
2. Enrich (inline PS)                         → Refresh deployment-status strip
   → packages.config → Package table          → Inject Tag / Compare / Schedule cells
   → git diff → Data Entity Changes          → Inject Post-Deployment Actions
                                              → Inject Priority Test Items callout
3. Clean up (inline PS)                       → Sort Bugs by Severity / Priority
   → HTML decode + strip raw tags             → Collapse empty placeholder tables
   → Keep empty section placeholders          → Re-attribute cherry-picked PRs
                                              → Strip (EXT) suffixes
4. WikiUpdaterTask                            → Replace ⏳ Awaiting → 🟢 Deployed
   → Push Build-<n>.md to wiki                → (Optional) Push annotated tag
   → Sort .order
                                            6. WikiUpdaterTask → push updated page
```

---

## Customization

### Add project-specific ADO fields
Edit `release-notes-template/release-notes-template.md` and add Handlebars expressions, e.g.:
```handlebars
{{lookup this.fields 'Custom.RootCauseNotes'}}
```
Examples in [examples/custom-template-example.md](examples/custom-template-example.md).

### Change `Deployment-release-notes` folder name
Replace the string in three places: `release-notes-stage.yaml`, `Update-WikiReleaseNotes.ps1` (`$wikiPath` switch), and `Setup-WikiStructure.ps1`.

### Adjust Post-Deployment Actions categories
The arrays `$secTypes`, `$entityTypes`, `$wfTypes`, `$numSeqTypes`, `$dimTypes`, `$cfgTypes`, `$bizEvtTypes` near the Post-Deployment Actions block in `Update-WikiReleaseNotes.ps1` are easy to extend with extra `Ax*` folder names.

### Disable tagging
Leave `-CreateTag $false` (default). The Tag cell will simply stay `_Pending_`.

---

## Safety & robustness

- **Non-blocking**: every wiki step uses `continueOnError: true`. Wiki failures NEVER fail your build or deployment.
- **Trap guard**: `Update-WikiReleaseNotes.ps1` catches any unhandled exception, emits a pipeline warning, and exits 0 with a no-op placeholder.
- **Idempotent**: every section is re-applied via sentinels / "already-present" checks, so re-running a stage produces an identical page (no duplicates).
- **No secrets in code**: only `System.AccessToken` is used (auto-revoked after pipeline run).
- **Encoding-safe**: emojis emitted via `[char]::ConvertFromUtf32` so output is byte-stable across PS 5.1 (ANSI default) and PS 7 (UTF-8 default).

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `TF401027: You need GenericContribute permission` on first wiki push | Run `setup/Grant-BuildPermission.ps1` (Step 4). |
| `Wiki file not found: Build-<n>.md` in the release task | Build stage didn't publish — check the `WikiUpdaterTask` step output in the build, and confirm `branchFolder` matches the source branch. |
| Strip entries not clickable | `EnvUrlMapJson` keys are case-insensitive but must match the **stage name** in the release pipeline (e.g. `DEV`, not `DevTest`). |
| Compare cell stays `_Pending_` | First build on the branch — no prior build to compare to. Or `RepoName` not passed. |
| Tag cell stays `_Pending_` | `-CreateTag $true` not passed, or current stage doesn't match `TagTriggerJson`, or repository has no prior `v*.*.*` tag for SemVer bump (will seed `v1.0.0`). |
| Post-Deployment Actions section missing | First build (no prev SHA) or no relevant `Ax*` changes between the two SHAs. |

---

## License

MIT — see [LICENSE](LICENSE).

## Author

**Vinod Kumar K J** — [github.com/vjanardhana12](https://github.com/vjanardhana12)

Pull requests and feedback welcome.
# D365 F&O Deployment Release Notes

Automated deployment release notes for **Dynamics 365 Finance & Operations** — published to Azure DevOps project wiki on every build, with live environment progress tracking.

## What it does

On every CI build, a wiki page is created with:

- **Work items** — User Stories, Document Deliverables, Tasks, Bugs, Configuration Deliverables linked to the build (with clickable ADO links)
- **Pull Requests** — who raised, source/target branch, who approved (🟢 / ✓)
- **Data Entity Changes** — new/modified/deleted entities and extensions with field-level detail
- **Package Versions** — all NuGet packages (Platform, Foundation, ISV) with versions
- **Deployment status strip** — compact `[Env1](url) 🟢 → [Env2](url) ⚪ → [Env3](url) ⚪` strip showing live deployment status per environment, updated by the release pipeline
- **Release link** — once deployed, `⏳ Awaiting deployment` flips to `[Release N](url) 🟢 _Deployed_`
- **Section-of-record layout** — every page renders the full set of sections (User Stories, Tasks, Bugs, Config Deliverables, Data Migration, Test Notes, Known Issues, Rollback Plan, Notes, Pull Requests) so reviewers always know what to look for; empty sections render a single `_No xxx linked to this build._` placeholder row
- **Legend** — 🟢 Deployed · 🟠 Partial · 🔴 Failed · ⚪ Pending

## Prerequisites

| Requirement | Details |
|---|---|
| **Azure DevOps project wiki** | Must be a _project wiki_ (not a code wiki). Create one via Project Settings → Wiki → Create project wiki. |
| **XplatGenerateReleaseNotes** | Free marketplace extension: [Generate Release Notes](https://marketplace.visualstudio.com/items?itemName=richardfennellBM.BM-VSTS-XplatGenerateReleaseNotes) |
| **WikiUpdaterTask** | Free marketplace extension: [Wiki Updater](https://marketplace.visualstudio.com/items?itemName=richardfennellBM.BM-VSTS-WIKIUpdater-Tasks) |
| **Build agent** | Must have `git` available (standard on Microsoft-hosted agents) |

## Setup (one-time)

### Step 1: Install marketplace extensions

Install both extensions from the links above into your Azure DevOps organization.

### Step 2: Create wiki folder structure

```powershell
.\setup\Setup-WikiStructure.ps1 `
    -Organization "https://dev.azure.com/yourorg" `
    -Project "YourProject" `
    -WikiName "YourProject.wiki"
```

This creates:
```
Deployment-release-notes/
├── Deployment-release-notes.md    (parent page)
├── .order
├── Main-branch.md
├── Prod-branch.md
├── Hotfix-branch.md
└── Release-branch.md
```

### Step 3: Grant build service permission

```powershell
.\setup\Grant-BuildPermission.ps1 `
    -Organization "https://dev.azure.com/yourorg" `
    -Project "YourProject"
```

This fixes the `TF401027: You need GenericContribute permission` error by granting the per-project build service identity **Contribute** access on the wiki git repository.

**What it does (REST API details):**
- Security namespace: `2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87` (Git Repositories)
- Token: `repoV2/<projectId>/<wikiRepoId>`
- Identity: `Microsoft.TeamFoundation.ServiceIdentity;<instanceId>:Build:<projectId>`
- Permission: `GenericContribute` (bit 4) = Allow

### Step 4: Add to your pipeline

Copy the template files into your repo and add the stage to your pipeline:

```yaml
stages:
- stage: Build
  # ... your existing build ...

- template: pipelines/release-notes-stage.yaml
  parameters:
    wikiRepoUrl: 'https://yourorg@dev.azure.com/yourorg/YourProject/_git/YourProject.wiki'
    branchFolder: 'Main-branch'
    templateFile: 'release-notes-template/release-notes-template.md'
    packagesConfigPaths: |
      $(Build.SourcesDirectory)\path\to\packages.config
    foundationPackagePattern: ''  # regex for your foundation packages
```

See [examples/pipeline-snippet.yaml](examples/pipeline-snippet.yaml) for a complete example.

### Step 5 (optional): Environment URLs

To make the strip entries `[Env](url) 🟢` clickable, pass `EnvUrlMapJson` to `Update-WikiReleaseNotes.ps1` in your release pipeline:

```powershell
.\Update-WikiReleaseNotes.ps1 `
    -Environment "DEV" `
    -WikiRepoUrlBase "https://dev.azure.com/yourorg/YourProject/_git/YourProject.wiki" `
    -EnvUrlMapJson '{"DEV":"https://myenv-dev.sandbox.operations.eu.dynamics.com/","UAT":"https://myenv-uat.sandbox.operations.eu.dynamics.com/"}'
```

### Step 6 (optional): Release pipeline integration

Add the `Update-WikiReleaseNotes.ps1` script as a task in each release stage to:
- Refresh the deployment-status strip with live status from `RELEASE_RELEASEID`
- Replace `⏳ Awaiting deployment` with `[Release N](url) 🟢 _Deployed_`

## File structure

```
├── release-notes-template/
│   └── release-notes-template.md   # Single unified Handlebars template
│                                  # (Commit blockquote conditionally rendered
│                                  #  on release/prod/hotfix branches; omitted
│                                  #  on main via `{{#unless (eq ...) }}`)
├── pipelines/
│   ├── release-notes-stage.yaml   # Reusable YAML stage template
│   └── scripts/
│       └── Update-WikiReleaseNotes.ps1   # Release pipeline script
├── setup/
│   ├── Setup-WikiStructure.ps1    # One-time wiki folder creation
│   └── Grant-BuildPermission.ps1  # One-time permission fix
└── examples/
    ├── pipeline-snippet.yaml      # Copy-paste snippet
    └── custom-template-example.md # How to add custom fields
```

## Customization

### Adding custom ADO fields

The generic template uses only standard ADO fields. To add project-specific fields:

1. Copy `release-notes-template/release-notes-template.md`
2. Add Handlebars expressions for your custom fields (see [examples/custom-template-example.md](examples/custom-template-example.md))
3. Common custom fields to add:
   - `Custom.OriginatedFrom` (Bug origin)
   - `Custom.FoundInEnvironment` (where the bug was found)
   - `Custom.ReleaseNote` / `Custom.RootCauseNotes` (release notes text)
   - Custom work item types (Document Deliverable, Configuration Deliverable)

### Single template for all branches

The one template handles all four branches via a single Handlebars conditional:

```handlebars
{{#unless (eq (replace buildDetails.sourceBranch "refs/heads/" "") "main")}}
> **Commit** [`{{substring buildDetails.sourceVersion 0 8}}`]({{buildDetails.repository.url}}/commit/{{buildDetails.sourceVersion}})
{{/unless}}
```

- On `main` builds the Commit blockquote is omitted (commit isn't meaningful for daily CD).
- On `release` / `prod` / `hotfix` branches it renders as a callout above the metadata table.

### Package categories

The enrichment step categorizes packages as:
- **Platform** — matches `Microsoft.Dynamics.*`
- **Foundation** — matches the `foundationPackagePattern` parameter (e.g., `Smartcore`)
- **ISV** — everything else

### Changing the folder name

Replace `Deployment-release-notes` in:
- `release-notes-stage.yaml` (filename + .order script)
- `Update-WikiReleaseNotes.ps1` (switch block)
- `Setup-WikiStructure.ps1` (folder + page names)

## How it works

```
Build Pipeline                              Release Pipeline
─────────────                               ─────────────────
1. XplatGenerateReleaseNotes                5. Update-WikiReleaseNotes.ps1
   → releaseNotes.md (from ADO WIs)           → Clone wiki
                                               → Query live release stages via REST
2. Enrich (inline PS)                          → Build deployment-status strip:
   → Package versions from packages.config         [Env1](url) 🟢 → [Env2](url) ⚪
   → Entity changes from git diff              → Flip ⏳ Awaiting →
                                                   [Release N](url) 🟢 _Deployed_
3. Cleanup (inline PS)                         → Push updated page
   → HTML decode + strip raw tags
   → Keep empty section placeholders         6. (Each stage updates the same page
                                                  with fresh strip status)
4. WikiUpdaterTask
   → Push page to project wiki
   → Sort .order (newest first)
```

## Safety

- **Non-blocking**: The entire ReleaseNotes stage is independent from the Build stage. Build failures don't affect release notes; release note failures don't affect builds.
- **`continueOnError: true`** on every wiki-related task — if the wiki publish fails, the build/deployment continues.
- **No secrets**: Uses `System.AccessToken` (auto-revoked after pipeline run).

## License

MIT — see [LICENSE](LICENSE).

## Author

**Vinod Kumar K J** — [github.com/vjanardhana12](https://github.com/vjanardhana12)
