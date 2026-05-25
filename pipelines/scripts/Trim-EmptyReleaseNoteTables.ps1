# Trim-EmptyReleaseNoteTables.ps1
# -----------------------------------------------------------------------------
# Apply two idempotent markdown transforms to a rendered release-notes page:
#
#   1. Collapse empty-state tables to a single italic line.
#        | **Header** | ... |
#        |---|---|---|
#        | - | _No X linked to this build._ | - | ... |
#      becomes:
#        _No X linked to this build._
#
#   2. Strip the trailing placeholder row from tables that DO have real data.
#      The Handlebars template always emits a `| - | _No X..._ | - |` trailing
#      row regardless of whether real rows matched the upstream filter.
#      Heuristic: a placeholder row is removed when another data row (one
#      starting with `| [` -- i.e. a markdown link cell) exists earlier in the
#      same table block (delimited by `## ` headings).
#
# Both transforms run safely on any page: they no-op if patterns don't match.
# This script is invoked from two places:
#   - The CI build task, right after the release-notes Handlebars render, so
#     the wiki page is clean even before any stage has deployed.
#   - The release-definition post-deploy task (Update-WikiReleaseNotes.ps1),
#     so pages that pre-date this script's introduction also get trimmed.
# Running it twice on the same page is a no-op (idempotent).
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Path
)

if (-not (Test-Path $Path)) {
    Write-Warning "Trim-EmptyReleaseNoteTables: file not found: $Path"
    return
}

$utf8 = [System.Text.UTF8Encoding]::new($false)
$content = [System.IO.File]::ReadAllText($Path, $utf8)
$original = $content

# --- 1. Collapse empty-state tables --------------------------------------
# Matches header + separator + a placeholder row with N leading "-" cells
# before the italic placeholder cell, and any number of trailing cells.
$emptyRx = [regex]'(?ms)^\|\s\*\*[^\r\n]+\|\s*\r?\n\|[-\s|]+\|\s*\r?\n\|(?:\s-\s\|)+\s_([^_]+)_\s\|(?:[^\r\n|]*\|)*\s*\r?\n'
$collapsed = $emptyRx.Replace($content, { param($m) "_" + $m.Groups[1].Value + "_`r`n" })
$collapseCount = 0
if ($collapsed -ne $content) {
    $collapseCount = ($content -split "`n").Count - ($collapsed -split "`n").Count
    $content = $collapsed
}

# --- 2. Strip trailing placeholder row from non-empty tables -------------
$placeholderRx = [regex]'(?m)^\|(?:\s-\s\|)+\s_[^_]+_\s\|[^\r\n]*\r?\n'
$blocks = [regex]::Split($content, '(?m)(?=^## )')
$stripCount = 0
for ($i = 0; $i -lt $blocks.Count; $i++) {
    $b = $blocks[$i]
    if ($b -match '(?m)^\|\s*\[' -and $b -match $placeholderRx) {
        $blocks[$i] = $placeholderRx.Replace($b, '', 1)
        $stripCount++
    }
}
if ($stripCount -gt 0) {
    $content = $blocks -join ''
}

if ($content -ne $original) {
    [System.IO.File]::WriteAllText($Path, $content, $utf8)
    Write-Host "Trim-EmptyReleaseNoteTables: collapsed $collapseCount empty-table line(s); stripped $stripCount trailing placeholder row(s) in $Path"
} else {
    Write-Host "Trim-EmptyReleaseNoteTables: no changes needed in $Path"
}
