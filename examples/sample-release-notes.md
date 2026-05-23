# Sample Release Notes (rendered output)

This is exactly what a `Build-<n>.md` page looks like on the wiki **after** the build pipeline + one release stage have run. Every section in this sample is auto-generated — nothing in here is hand-typed.

Tip: open this file as raw markdown to see the source, or open it in a wiki/markdown previewer to see it rendered.

---

## Build 2026.05.23.1 - D365 Finance and Operations

| | | | |
|---|---|---|---|
| **Release**        | [Release-187](https://dev.azure.com/contoso/MyProject/_releaseProgress?releaseId=187) 🟢 _Deployed_ | **Build**         | [2026.05.23.1](https://dev.azure.com/contoso/MyProject/_build/results?buildId=4421) |
| **Prepared for**   | Contoso Retail D365 F&O                                       | **Prepared by**   | Contoso Engineering |
| **Branch**         | `main`                                                        | **Repository**    | `MyApp` |
| **Build date**     | 2026-05-23T00:15:42Z                                          | **Triggered by**  | Jane Doe |
| **Commit**         | [`d3208bdb`](https://dev.azure.com/contoso/MyProject/_git/MyApp/commit/d3208bdb8fddd86e8a6d51e2e4daf4a205ae2c3a) | **Schedule** | Daily 00:15 CEST |
| **Tag**            | [`uat-2026.05.23.1`](https://dev.azure.com/contoso/MyProject/_git/MyApp?version=GTuat-2026.05.23.1) | **Compare**       | [`2026.05.22.1` -> `2026.05.23.1`](https://dev.azure.com/contoso/MyProject/_git/MyApp/branchCompare?baseVersion=GC3844d040&targetVersion=GCd3208bdb&_a=files) |

## Deployment status

<!-- ENV-PROGRESS-START -->
[DevTest](https://contoso-devtest.sandbox.operations.eu.dynamics.com/) 🟢 → [UAT](https://contoso-uat.sandbox.operations.eu.dynamics.com/) 🟢 → [PreProd](https://contoso-preprod.sandbox.operations.eu.dynamics.com/) ⚪ → [PROD](https://contoso.operations.dynamics.com/) ⚪

<sub>**Legend**: 🟢 Deployed · 🟠 Partial · 🔴 Failed · ⚪ Pending</sub>
<!-- ENV-PROGRESS-END -->

## Priority Test Items

> [!WARNING]
> 🚨 **2 high-severity bug fix(es) (S1/S2) in this build** - please test on priority. Full details in the [Bugs](#bugs) table below.
>
> - 🔥 [82148](https://dev.azure.com/contoso/MyProject/_workitems/edit/82148) **Sales order confirmation fails for project-funded orders** _(Sev: 1 - Critical, Pri: 1)_
> - 🚨 [82369](https://dev.azure.com/contoso/MyProject/_workitems/edit/82369) **Vendor invoice posting rounding error on multi-currency** _(Sev: 2 - High, Pri: 2)_

## Post-Deployment Actions

- 🔐 **Security objects changed** — verify role/duty assignments in target environment.
- 🔢 **Number sequences changed** — run the Generate wizard under Organization administration > Number sequences.

**New objects introduced in this build:**

- 🔐 Security: 2 roles, 4 duties, 15 privileges, 7 policies
- 🔢 Number sequences: 1 new reference/scope/group
- ⏰ Batch jobs: 1 new batch job (schedule under System administration > Inquiries > Batch jobs)

## User Stories

| **ID** | **Title** | **Area** | **Iteration** |
|--------|-----------|----------|---------------|
| [81523](https://dev.azure.com/contoso/MyProject/_workitems/edit/81523) | Add new approval workflow for purchase requisitions over 50k | MyProject\Procurement | Sprint 24 |
| [81730](https://dev.azure.com/contoso/MyProject/_workitems/edit/81730) | Custom number sequence for inter-company sales orders | MyProject\Sales | Sprint 24 |
| [81950](https://dev.azure.com/contoso/MyProject/_workitems/edit/81950) | Project funding source allocation enhancement | MyProject\Projects | Sprint 24 |

## Document Deliverables

_No document deliverables linked to this build._

## Tasks

| **ID** | **Title** | **Area** | **Iteration** |
|--------|-----------|----------|---------------|
| [81524](https://dev.azure.com/contoso/MyProject/_workitems/edit/81524) | Design - PurchReqWorkflow approval matrix | MyProject\Procurement | Sprint 24 |
| [81525](https://dev.azure.com/contoso/MyProject/_workitems/edit/81525) | Implement PurchReqWorkflow X++ classes | MyProject\Procurement | Sprint 24 |
| [81731](https://dev.azure.com/contoso/MyProject/_workitems/edit/81731) | Create SalesIntercoNumSeq scope + reference | MyProject\Sales | Sprint 24 |
| [81951](https://dev.azure.com/contoso/MyProject/_workitems/edit/81951) | Refactor ProjFundingAllocator class for performance | MyProject\Projects | Sprint 24 |

## Bugs

| **ID** | **Title** | **Severity** | **Priority** | **State** |
|--------|-----------|--------------|--------------|-----------|
| [82148](https://dev.azure.com/contoso/MyProject/_workitems/edit/82148) | Sales order confirmation fails for project-funded orders | 1 - Critical | 1 | Resolved |
| [82369](https://dev.azure.com/contoso/MyProject/_workitems/edit/82369) | Vendor invoice posting rounding error on multi-currency | 2 - High | 2 | Resolved |
| [81855](https://dev.azure.com/contoso/MyProject/_workitems/edit/81855) | Inventory adjustment report shows duplicate lines | 3 - Medium | 3 | Resolved |

## Configuration Deliverables

| **ID** | **Title** | **Area** | **Iteration** |
|--------|-----------|----------|---------------|
| [81739](https://dev.azure.com/contoso/MyProject/_workitems/edit/81739) | New ledger account 470100 for digital subscription revenue | MyProject\Finance | Sprint 24 |

## Data Migration / Cutover Notes

_Not applicable for this build._

## Test Notes

_Smoke tests pending sign-off._

## Known Issues / Caveats

| **ID** | **Description** | **Workaround** | **Impacted environments** |
|--------|-----------------|----------------|---------------------------|
| KI-014 | Worker self-service portal slow on Edge < 110 | Use Chrome or upgrade Edge | All sandboxes |

## Rollback Plan

_Standard rollback: redeploy the previous build artifact for affected environment(s)._

## Notes

| **ID** | **Work Item Type** | **Title** | **Release notes** | **Root cause notes** |
|--------|--------------------|-----------|-------------------|----------------------|
| [82148](https://dev.azure.com/contoso/MyProject/_workitems/edit/82148) | Bug | Sales order confirmation fails for project-funded orders | Project-funded sales orders can now be confirmed without manual unposting. | Race condition in `SalesFormLetter.run()` when project funding source was attached after order creation. |
| [82369](https://dev.azure.com/contoso/MyProject/_workitems/edit/82369) | Bug | Vendor invoice posting rounding error on multi-currency | Multi-currency invoices now post with correct rounding to 2dp. | `Currency::amountCur2MST` was using bank rate instead of accounting rate. |

## Pull Requests - **5 merged**

| **ID** | **Title** | **Raised by** | **Source** | **Target** | **Merged on** | **Approved by** |
|--------|-----------|---------------|------------|------------|---------------|-----------------|
| [!21847](https://dev.azure.com/contoso/MyProject/_git/MyApp/pullRequest/21847) | Add Number Sequences detection to Post-Deployment Actions | Jane Doe | `feature/numseq-detection` | `main` | 2026-05-23T08:14:00Z | John Smith 🟢 |
| [!21845](https://dev.azure.com/contoso/MyProject/_git/MyApp/pullRequest/21845) | Fix sales order confirmation for project-funded orders | Aaron Lee _(cherry-picked by Jane Doe)_ | `bugfix/82148` | `main` | 2026-05-23T07:42:00Z | John Smith 🟢 Maria Garcia ✓ |
| [!21843](https://dev.azure.com/contoso/MyProject/_git/MyApp/pullRequest/21843) | Add PurchReqWorkflow with approval matrix | Aaron Lee | `feature/purchreq-workflow` | `main` | 2026-05-23T05:11:00Z | Maria Garcia 🟢 |
| [!21841](https://dev.azure.com/contoso/MyProject/_git/MyApp/pullRequest/21841) | Create SalesIntercoNumSeq scope + reference | Priya Nair | `feature/interco-numseq` | `main` | 2026-05-22T18:22:00Z | John Smith 🟢 |
| [!21839](https://dev.azure.com/contoso/MyProject/_git/MyApp/pullRequest/21839) | Fix multi-currency rounding in `Currency::amountCur2MST` | Priya Nair | `bugfix/82369` | `main` | 2026-05-22T15:05:00Z | Aaron Lee 🟢 Maria Garcia ✓ |

**Reviewer legend**: 🟢 Approved · ✓ Approved with suggestions

# Data Entity Changes

> Entities changed in this build: **2** added, **1** modified.
> Use the **Compare** link in the metadata table for the full file-level diff.

# Package Versions

| **Package** | **Version** | **Category** |
|---|---|---|
| Microsoft.Dynamics.AX.Platform.CompilerPackage | 7.0.7521.39 | Platform |
| Microsoft.Dynamics.AX.Application.DevALM.BuildXpp | 10.0.2014.31 | Platform |
| MyCompany.Foundation.Core | 1.18.0 | Foundation |
| MyCompany.Foundation.Workflow | 1.18.0 | Foundation |
| Acme.RetailExtensions | 4.2.1 | ISV |
| Acme.AnalyticsConnector | 2.9.0 | ISV |

---

## What you're looking at

| Section | Source | Notes |
|---|---|---|
| Metadata table | Build env vars + script REST calls | `Tag`, `Compare`, `Schedule` cells filled live by `Update-WikiReleaseNotes.ps1` |
| Deployment status strip | Release REST API | Refreshed by every stage; click links open D365 environments |
| Priority Test Items | Parsed from Bugs table | Auto-callout for S1/S2 bug fixes |
| Post-Deployment Actions | git diff between this build's SHA and previous successful build SHA on the same branch | Counts derived from `Ax*` folder paths; Compare link has the full detail |
| User Stories / Tasks / Bugs / etc. | ADO work items linked to the build | Bugs auto-sorted by Severity then Priority |
| Pull Requests | ADO PR REST | Cherry-picked PRs re-attributed to original author; `(EXT)` suffix stripped |
| Data Entity Changes | `git diff HEAD~1 --name-status` on entity folders | Counts only — Compare link has the file-level diff |
| Package Versions | `packages.config` (XML parse) | Categorized via `foundationPackagePattern` regex |
