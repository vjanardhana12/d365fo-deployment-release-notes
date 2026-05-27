## Build {{buildDetails.buildNumber}} - D365 Finance and Operations

| | | | |
|---|---|---|---|
| **Build**          | [{{buildDetails.buildNumber}}](https://dev.azure.com/carlsberggroup/1760-SmartCore-HUB/_build/results?buildId={{buildDetails.id}}&view=results) | **Build date**        | {{buildDetails.startTime}} |
| **Prepared for**   | Carlsberg Hub Implementation | **Prepared by**       | Microsoft Services |
| **Branch**         | `{{replace buildDetails.sourceBranch "refs/heads/" ""}}` | **Repository** | `{{buildDetails.repository.name}}` |
| **Triggered by**   | {{buildDetails.requestedFor.displayName}} | **Commit** | [`{{buildDetails.sourceVersion}}`](https://dev.azure.com/carlsberggroup/1760-SmartCore-HUB/_git/1760-Smartcore-HUB/commit/{{buildDetails.sourceVersion}}) |
{{#if (eq (replace buildDetails.sourceBranch "refs/heads/" "") "main")}}
|                    |           | **Compare** | _Pending_ |
{{else}}
| **Tag**            | _Pending_ | **Compare** | _Pending_ |
{{/if}}

## Deployment status

⏳ _**Awaiting deployment**_

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

| **ID** | **Title** | **Severity** | **Priority** | **Originated From** | **Found in environment** | **How Found** | **Root Cause** |
|--------|-----------|--------------|--------------|---------------------|--------------------------|---------------|----------------|
{{#forEach this.workItems}}
{{#if (eq (lookup this.fields 'System.WorkItemType') 'Bug')}}
| [{{this.id}}]({{replace this.url "_apis/wit/workItems" "_workitems/edit"}}) | {{lookup this.fields 'System.Title'}} | {{lookup this.fields 'Microsoft.VSTS.Common.Severity'}} | {{lookup this.fields 'Microsoft.VSTS.Common.Priority'}} | {{lookup this.fields 'Custom.OriginatedFrom'}} | {{lookup this.fields 'Custom.FoundInEnvironment_MicrosoftServices'}} | {{lookup this.fields 'Custom.HowFoundCategory_MicrosoftServices'}} | {{lookup this.fields 'Custom.RootCauseNotes'}} |
{{/if}}
{{/forEach}}
| - | _No bugs linked to this build._ | - | - | - | - | - | - |

## Configuration Deliverables

| **ID** | **Title** | **Area** | **Iteration** |
|--------|-----------|----------|---------------|
{{#forEach this.relatedWorkItems}}
{{#if (eq (lookup this.fields 'System.WorkItemType') 'Configuration Deliverable')}}
| [{{this.id}}]({{replace this.url "_apis/wit/workItems" "_workitems/edit"}}) | {{lookup this.fields 'System.Title'}} | {{lookup this.fields 'System.AreaPath'}} | {{lookup this.fields 'System.IterationPath'}} |
{{/if}}
{{/forEach}}
| - | _No configuration deliverables linked to this build._ | - | - |

## Notes

| **ID** | **Work Item Type** | **Title** | **Release notes** | **Root cause notes** |
|--------|--------------------|-----------|-------------------|----------------------|
{{#forEach this.workItems}}
{{#if (or (lookup this.fields 'Custom.ReleaseNote') (lookup this.fields 'Custom.RootCauseNotes'))}}
| [{{this.id}}]({{replace this.url "_apis/wit/workItems" "_workitems/edit"}}) | {{lookup this.fields 'System.WorkItemType'}} | {{lookup this.fields 'System.Title'}} | {{lookup this.fields 'Custom.ReleaseNote'}} | {{lookup this.fields 'Custom.RootCauseNotes'}} |
{{/if}}
{{/forEach}}
{{#forEach this.relatedWorkItems}}
{{#if (and (eq (lookup this.fields 'System.WorkItemType') 'Document Deliverable') (or (lookup this.fields 'Custom.ReleaseNote') (lookup this.fields 'Custom.RootCauseNotes')))}}
| [{{this.id}}]({{replace this.url "_apis/wit/workItems" "_workitems/edit"}}) | {{lookup this.fields 'System.WorkItemType'}} | {{lookup this.fields 'System.Title'}} | {{lookup this.fields 'Custom.ReleaseNote'}} | {{lookup this.fields 'Custom.RootCauseNotes'}} |
{{/if}}
{{/forEach}}
| - | - | _No release notes or root cause notes captured for this build._ | - | - |

## Pull Requests _(MS internal)_ - **{{pullRequests.length}} merged**

_Source/Target branches omitted: source user-branches are deleted on merge; target is always this build's branch._

| **ID** | **Title** | **Raised by** | **Merged on** | **Approved by** |
|--------|-----------|---------------|---------------|-----------------|
{{#if pullRequests.length}}
{{#forEach pullRequests}}
| [!{{this.pullRequestId}}]({{replace (replace this.url "_apis/git/repositories" "_git") "pullRequests" "pullRequest"}}) | {{this.title}} | {{this.createdBy.displayName}} | {{this.closedDate}} | {{#if this.reviewers}}{{#forEach this.reviewers}}{{#if this.isContainer}}{{#if this.votedFor}}{{#forEach this.votedFor}}{{#if (eq this.vote 10)}}{{this.displayName}} 🟢 {{/if}}{{#if (eq this.vote 5)}}{{this.displayName}} ✓ {{/if}}{{/forEach}}{{/if}}{{else}}{{#if (eq this.vote 10)}}{{this.displayName}} 🟢 {{/if}}{{#if (eq this.vote 5)}}{{this.displayName}} ✓ {{/if}}{{/if}}{{/forEach}}{{else}}_No approvers_{{/if}} |
{{/forEach}}
{{else}}
| - | _No pull requests associated with this build._ | - | - | - |
{{/if}}

**Reviewer legend**: 🟢 Approved · ✓ Approved with suggestions
