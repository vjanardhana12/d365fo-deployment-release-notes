# Example: Custom template with project-specific ADO fields.
#
# This extends the generic template with:
#   - Custom bug fields (OriginatedFrom, FoundInEnvironment)
#   - Custom work item types (Document Deliverable, Configuration Deliverable)
#   - Custom notes fields (ReleaseNote, RootCauseNotes)
#
# Copy release-notes-template/release-notes-template.md and add your custom sections.
# Below shows the diff — what to ADD to the generic template.

# ── Bugs section: replace the generic Bugs table with this ────────────────────

# Bugs

| **ID** | **Title** | **Severity** | **Priority** | **Originated From** | **Found in environment** |
|--------|-----------|--------------|--------------|---------------------|--------------------------|
{{#forEach this.workItems}}
{{#if (eq (lookup this.fields 'System.WorkItemType') 'Bug')}}
| [{{this.id}}]({{replace this.url "_apis/wit/workItems" "_workitems/edit"}}) | {{lookup this.fields 'System.Title'}} | {{lookup this.fields 'Microsoft.VSTS.Common.Severity'}} | {{lookup this.fields 'Microsoft.VSTS.Common.Priority'}} | {{lookup this.fields 'Custom.OriginatedFrom'}} | {{lookup this.fields 'Custom.FoundInEnvironment_MicrosoftServices'}} |
{{/if}}
{{/forEach}}


# ── Add after Bugs: Configuration Deliverables ────────────────────────────────

# Associated Configuration Deliverables

| **ID** | **Title** | **Area** | **Iteration** |
|--------|-----------|----------|---------------|
{{#forEach this.relatedWorkItems}}
{{#if (eq (lookup this.fields 'System.WorkItemType') 'Configuration Deliverable')}}
| [{{this.id}}]({{replace this.url "_apis/wit/workItems" "_workitems/edit"}}) | {{lookup this.fields 'System.Title'}} | {{lookup this.fields 'System.AreaPath'}} | {{lookup this.fields 'System.IterationPath'}} |
{{/if}}
{{/forEach}}


# ── Add after Config Deliverables: Notes with custom fields ───────────────────

# Notes

| **ID** | **Work Item Type** | **Title** | **Release notes** | **Root cause notes** |
|--------|--------------------|-----------|-------------------|----------------------|
{{#forEach this.workItems}}
{{#if (or (lookup this.fields 'Custom.ReleaseNote') (lookup this.fields 'Custom.RootCauseNotes'))}}
| [{{this.id}}]({{replace this.url "_apis/wit/workItems" "_workitems/edit"}}) | {{lookup this.fields 'System.WorkItemType'}} | {{lookup this.fields 'System.Title'}} | {{lookup this.fields 'Custom.ReleaseNote'}} | {{lookup this.fields 'Custom.RootCauseNotes'}} |
{{/if}}
{{/forEach}}


# ── Add after Bugs: Document Deliverables ─────────────────────────────────────

# Document Deliverables

| **ID** | **Title** | **Area** | **Iteration** | **Tags** |
|--------|-----------|----------|---------------|----------|
{{#forEach this.relatedWorkItems}}
{{#if (eq (lookup this.fields 'System.WorkItemType') 'Document Deliverable')}}
| [{{this.id}}]({{replace this.url "_apis/wit/workItems" "_workitems/edit"}}) | {{lookup this.fields 'System.Title'}} | {{lookup this.fields 'System.AreaPath'}} | {{lookup this.fields 'System.IterationPath'}} | {{lookup this.fields 'System.Tags'}} |
{{/if}}
{{/forEach}}
