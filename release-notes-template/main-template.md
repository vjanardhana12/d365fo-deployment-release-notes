# Release Notes – D365 Finance and Operations  

**Release information**: ⏳ _**Awaiting deployment**_

**Build information**: {{buildDetails.buildNumber}}

**Build date**: {{buildDetails.startTime}}  

**Repository**: {{buildDetails.repositoryName}}

**Prepared for**: _Your Project Name_

**Prepared by**: _Your Organization_

**Environments**:
<!-- ENV-PROGRESS-BLOCK -->


# User Stories

| **ID** |                 **Title**               |      **Area**     |     **Iteration**       |
|--------|-----------------------------------------|-------------------|-------------------------|
{{#forEach this.workItems}}
{{#if (eq (lookup this.fields 'System.WorkItemType') 'User Story')}}
| [{{this.id}}]({{replace this.url "_apis/wit/workItems" "_workitems/edit"}}) | {{lookup this.fields 'System.Title'}} | {{lookup this.fields 'System.AreaPath'}} | {{lookup this.fields 'System.IterationPath'}} |
{{/if}}
{{/forEach}}


# Tasks

| **ID** |                 **Title**               |      **Area**     |     **Iteration**       |
|--------|-----------------------------------------|-------------------|-------------------------|
{{#forEach this.workItems}}
{{#if (eq (lookup this.fields 'System.WorkItemType') 'Task')}}
| [{{this.id}}]({{replace this.url "_apis/wit/workItems" "_workitems/edit"}}) | {{lookup this.fields 'System.Title'}} | {{lookup this.fields 'System.AreaPath'}} | {{lookup this.fields 'System.IterationPath'}} |
{{/if}}
{{/forEach}}


# Bugs

| **ID** |                 **Title**               | **Severity** | **Priority** | **State** |
|--------|-----------------------------------------|--------------|--------------|-----------|
{{#forEach this.workItems}}
{{#if (eq (lookup this.fields 'System.WorkItemType') 'Bug')}}
| [{{this.id}}]({{replace this.url "_apis/wit/workItems" "_workitems/edit"}}) | {{lookup this.fields 'System.Title'}} | {{lookup this.fields 'Microsoft.VSTS.Common.Severity'}} | {{lookup this.fields 'Microsoft.VSTS.Common.Priority'}} | {{lookup this.fields 'System.State'}} |
{{/if}}
{{/forEach}}


# Pull Requests ({{pullRequests.length}})

| **ID** |       **Title**      |    **Raised by**    |    **Source**    |    **Target**    |        **Approved by**         |
|--------|----------------------|---------------------|------------------|------------------|--------------------------------|
{{#if pullRequests.length}}
{{#forEach pullRequests}}
| [!{{this.pullRequestId}}]({{replace (replace this.url "_apis/git/repositories" "_git") "pullRequests" "pullRequest"}}) | {{this.title}} | {{this.createdBy.displayName}} | {{replace this.sourceRefName "refs/heads/" ""}} | {{replace this.targetRefName "refs/heads/" ""}} | {{#if this.reviewers}}{{#forEach this.reviewers}}{{#if (eq this.vote 10)}}{{this.displayName}}{{/if}}{{/forEach}}{{else}}_pending_{{/if}} |
{{/forEach}}
{{else}}
_No associated pull requests_
{{/if}}
