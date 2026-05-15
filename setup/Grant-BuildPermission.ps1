<#
.SYNOPSIS
    Grants the build service identity Contribute permission on the project wiki repo.

.DESCRIPTION
    Fixes the TF401027 "needs GenericContribute permission" error that occurs when
    the WikiUpdaterTask tries to push to the project wiki from a pipeline.

    This script calls the Azure DevOps Security REST API to set an explicit Allow ACE
    on the Git Repositories namespace (2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87) for
    the per-project build service identity.

.PARAMETER Organization
    Azure DevOps organization URL (e.g., https://dev.azure.com/myorg)

.PARAMETER Project
    Azure DevOps project name

.PARAMETER PAT
    Personal Access Token with Security (Manage) + Identity (Read) permissions.

.EXAMPLE
    .\Grant-BuildPermission.ps1 -Organization "https://dev.azure.com/myorg" -Project "MyProject"

.NOTES
    Only needs to be run once per project. Safe to re-run.
#>
param(
    [Parameter(Mandatory)][string]$Organization,
    [Parameter(Mandatory)][string]$Project,
    [string]$PAT
)

$ErrorActionPreference = 'Stop'

if (-not $PAT) {
    $PAT = Read-Host -Prompt 'Enter PAT with Security Manage + Identity Read' -AsSecureString |
           ForEach-Object { [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($_)) }
}

$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$PAT"))
$headers = @{ Authorization = "Basic $base64Auth"; 'Content-Type' = 'application/json' }

$orgBase = $Organization.TrimEnd('/')

# --- Step 1: Get project ID ---
Write-Host "Getting project ID for '$Project'..." -ForegroundColor Cyan
$project_obj = Invoke-RestMethod -Uri "$orgBase/_apis/projects/$Project`?api-version=7.1" -Headers $headers
$projectId = $project_obj.id
Write-Host "  Project ID: $projectId"

# --- Step 2: Get organization ID (for the identity descriptor) ---
Write-Host "Getting organization identity..." -ForegroundColor Cyan
$orgId = ($orgBase -split '/')[-1]  # org name from URL
$connData = Invoke-RestMethod -Uri "$orgBase/_apis/connectiondata?api-version=7.1" -Headers $headers
$instanceId = $connData.instanceId
Write-Host "  Instance ID: $instanceId"

# --- Step 3: Find the build service identity ---
# The per-project build service identity has the pattern:
# Microsoft.TeamFoundation.ServiceIdentity;<instanceId>:Build:<projectId>
$buildDescriptor = "Microsoft.TeamFoundation.ServiceIdentity;${instanceId}:Build:${projectId}"
Write-Host "  Build service descriptor: $buildDescriptor"

# --- Step 4: Get the wiki repo ID ---
Write-Host "Getting wiki repo ID..." -ForegroundColor Cyan
$wikiRepoName = "$Project.wiki"
$repos = Invoke-RestMethod -Uri "$orgBase/$Project/_apis/git/repositories?api-version=7.1" -Headers $headers
$wikiRepo = $repos.value | Where-Object { $_.name -eq $wikiRepoName }
if (-not $wikiRepo) {
    Write-Warning "Wiki repo '$wikiRepoName' not found. Available repos:"
    $repos.value | ForEach-Object { Write-Host "  - $($_.name)" }
    throw "Wiki repo not found. Create a project wiki first."
}
$wikiRepoId = $wikiRepo.id
Write-Host "  Wiki repo ID: $wikiRepoId"

# --- Step 5: Grant Contribute permission ---
# Git Repositories security namespace: 2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87
# Contribute (GenericContribute) = bit 4
# Token format: repoV2/<projectId>/<repoId>
$secNamespace = '2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87'
$secToken = "repoV2/$projectId/$wikiRepoId"

Write-Host "Setting Contribute=Allow on wiki repo for build service..." -ForegroundColor Cyan
$body = @{
    token = $secToken
    merge = $true
    accessControlEntries = @(
        @{
            descriptor = $buildDescriptor
            allow = 4          # GenericContribute
            deny  = 0
            extendedInfo = @{}
        }
    )
} | ConvertTo-Json -Depth 5

$result = Invoke-RestMethod `
    -Uri "$orgBase/_apis/accesscontrolentries/$secNamespace`?api-version=7.1" `
    -Method Post -Headers $headers -Body $body

Write-Host "`nPermission granted successfully." -ForegroundColor Green
Write-Host @"

Summary:
  Project:    $Project ($projectId)
  Wiki repo:  $wikiRepoName ($wikiRepoId)
  Identity:   $buildDescriptor
  Permission: GenericContribute = Allow

The build pipeline can now push to the project wiki.
"@ -ForegroundColor Cyan
