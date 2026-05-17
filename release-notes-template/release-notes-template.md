## Build {{buildDetails.buildNumber}} - D365 Finance and Operations

{{#unless (eq (replace buildDetails.sourceBranch "refs/heads/" "") "main")}}
> **Commit** [`{{substring buildDetails.sourceVersion 0 8}}`]({{buildDetails.repository.url}}/commit/{{buildDetails.sourceVersion}})
{{/unless}}

| | | | |
|---|---|---|---|
| **Release**        | ⏳ _**Awaiting deployment**_                                  | **Build**         | [{{buildDetails.buildNumber}}]({{buildDetails.url}}) |
| **Prepared for**   | _Your Project Name_                                           | **Prepared by**   | _Your Organization_ |
| **Branch**         | `{{replace buildDetails.sourceBranch "refs/heads/" ""}}`      | **Repository**    | `{{buildDetails.repository.name}}` |
| **Build date**     | {{buildDetails.startTime}}                                    | **Triggered by**  | {{buildDetails.requestedFor.displayName}} |

## Deployment status

<!-- ENV-PROGRESS-BLOCK -->


## User Stories

| **ID** | **Title** | **Area** | **Iteration** |
|--------|-----------|----------|---------------|
{{#forEach this.relatedWorkItems}}
{{#if (eq (lookup this.fields 'System.WorkItemType') 'User Story')}}
| [{{this.id}}]({{replace this.url "_apis/wit/workItems" "_workitems/edit"}}) | {{lookup this.fields 'System.Title'}} | {{lookup this.fields 'System.AreaPath'}} | {{lookup this.fields 'System.IterationPath'}} |
{{/if}}
{{/forEach}}
| - | _No user stories linked to this build._ | - | - |

## Document Deliverables

| **ID** | **Title** | **Area** | **Iteration** | **Tags** |
|--------|-----------|----------|---------------|----------|
{{#forEach this.relatedWorkItems}}
{{#if (eq (lookup this.fields 'System.WorkItemType') 'Document Deliverable')}}
| [{{this.id}}]({{replace this.url "_apis/wit/workItems" "_workitems/edit"}}) | {{lookup this.fields 'System.Title'}} | {{lookup this.fields 'System.AreaPath'}} | {{lookup this.fields 'System.IterationPath'}} | {{lookup this.fields 'System.Tags'}} |
{{/if}}
{{/forEach}}
| - | _No document deliverables linked to this build._ | - | - | - |

## Tasks

| **ID** | **Title** | **Area** | **Iteration** |
|--------|-----------|----------|---------------|
{{#forEach this.workItems}}
{{#if (eq (lookup this.fields 'System.WorkItemType') 'Task')}}
| [{{this.id}}]({{replace this.url "_apis/wit/workItems" "_workitems/edit"}}) | {{lookup this.fields 'System.Title'}} | {{lookup this.fields 'System.AreaPath'}} | {{lookup this.fields 'System.IterationPath'}} |
{{/if}}
{{/forEach}}
| - | _No tasks linked to this build._ | - | - |

## Bugs

| **ID** | **Title** | **Severity** | **Priority** | **State** |
|--------|-----------|--------------|--------------|-----------|
{{#forEach this.workItems}}
{{#if (eq (lookup this.fields 'System.WorkItemType') 'Bug')}}
| [{{this.id}}]({{replace this.url "_apis/wit/workItems" "_workitems/edit"}}) | {{lookup this.fields 'System.Title'}} | {{lookup this.fields 'Microsoft.VSTS.Common.Severity'}} | {{lookup this.fields 'Microsoft.VSTS.Common.Priority'}} | {{lookup this.fields 'System.State'}} |
{{/if}}
{{/forEach}}
| - | _No bugs linked to this build._ | - | - | - |

## Configuration Deliverables

| **ID** | **Title** | **Area** | **Iteration** |
|--------|-----------|----------|---------------|
{{#forEach this.relatedWorkItems}}
{{#if (eq (lookup this.fields 'System.WorkItemType') 'Configuration Deliverable')}}
| [{{this.id}}]({{replace this.url "_apis/wit/workItems" "_workitems/edit"}}) | {{lookup this.fields 'System.Title'}} | {{lookup this.fields 'System.AreaPath'}} | {{lookup this.fields 'System.IterationPath'}} |
{{/if}}
{{/forEach}}
| - | _No configuration deliverables linked to this build._ | - | - |

## Data Migration / Cutover Notes

| **Step** | **Description** | **Owner** | **Environment** | **Status** |
|----------|-----------------|-----------|-----------------|------------|
| - | _Not applicable for this build._ | - | - | - |

## Test Notes

| **Area** | **Test type** | **Owner** | **Result** | **Comments** |
|----------|---------------|-----------|------------|--------------|
| - | _Smoke tests pending sign-off._ | - | - | - |

## Known Issues / Caveats

| **ID** | **Description** | **Workaround** | **Impacted environments** |
|--------|-----------------|----------------|---------------------------|
| - | _None reported._ | - | - |

## Rollback Plan

_Standard rollback: redeploy the previous build artifact for affected environment(s)._

## Notes

| **ID** | **Work Item Type** | **Title** | **Release notes** | **Root cause notes** |
|--------|--------------------|-----------|-------------------|----------------------|
{{#forEach this.workItems}}
{{#if (or (lookup this.fields 'Custom.ReleaseNote') (lookup this.fields 'Custom.RootCauseNotes'))}}
| [{{this.id}}]({{replace this.url "_apis/wit/workItems" "_workitems/edit"}}) | {{lookup this.fields 'System.WorkItemType'}} | {{lookup this.fields 'System.Title'}} | {{lookup this.fields 'Custom.ReleaseNote'}} | {{lookup this.fields 'Custom.RootCauseNotes'}} |
{{/if}}
{{/forEach}}
| - | - | _No release notes or root cause notes captured for this build._ | - | - |

## Pull Requests - **{{pullRequests.length}} merged**

| **ID** | **Title** | **Raised by** | **Source** | **Target** | **Merged on** | **Approved by** |
|--------|-----------|---------------|------------|------------|---------------|-----------------|
{{#if pullRequests.length}}
{{#forEach pullRequests}}
| [!{{this.pullRequestId}}]({{replace (replace this.url "_apis/git/repositories" "_git") "pullRequests" "pullRequest"}}) | {{this.title}} | {{this.createdBy.displayName}} | `{{replace this.sourceRefName "refs/heads/" ""}}` | `{{replace this.targetRefName "refs/heads/" ""}}` | {{this.closedDate}} | {{#if this.reviewers}}{{#forEach this.reviewers}}{{#if (eq this.vote 10)}}{{this.displayName}} 🟢 {{/if}}{{#if (eq this.vote 5)}}{{this.displayName}} ✓ {{/if}}{{/forEach}}{{else}}_No approvers_{{/if}} |
{{/forEach}}
{{else}}
| - | _No pull requests associated with this build._ | - | - | - | - | - |
{{/if}}

**Reviewer legend**: 🟢 Approved · ✓ Approved with suggestions
