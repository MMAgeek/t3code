#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Sync this fork with pingdotgg/t3code and replay local commits on top.

.DESCRIPTION
    Fork model: main = upstream/main + a short stack of local commits.

        upstream/main ──┬── chore(ci): trim workflows for fork
                        └── fix: discover project-level Claude skills (PR 4546)

    Syncing is a rebase, so the local stack is replayed onto the new upstream
    tip every day. git rerere is enabled, so a conflict resolved once is
    replayed automatically on later syncs.

    Nothing here can write to upstream: the upstream remote's push URL is
    disabled, and the only push target is origin (your fork).

.PARAMETER Push
    Force-push the rebased main to origin. Rebasing rewrites history, so a
    plain push will be rejected; this uses --force-with-lease.

.PARAMETER NoFetchPatchState
    Skip the GitHub API check for whether PR 4546 has merged upstream.
    Use when offline or when gh is not authenticated.

.EXAMPLE
    pwsh -File scripts/sync-fork.ps1
    pwsh -File scripts/sync-fork.ps1 -Push
#>
[CmdletBinding()]
param(
    [switch]$Push,
    [switch]$NoFetchPatchState
)

$ErrorActionPreference = 'Stop'

$UpstreamUrl = 'https://github.com/pingdotgg/t3code.git'
$UpstreamBranch = 'main'
$PatchPr = 4546

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "    $Message" -ForegroundColor Yellow }
function Write-Err { param([string]$Message) Write-Host "    $Message" -ForegroundColor Red }

# Run from the repo root regardless of where the script was invoked.
$repoRoot = (git rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0) { throw 'Not inside a git repository.' }
Set-Location $repoRoot

# --- Guard: clean working tree -------------------------------------------
Write-Step 'Checking working tree'
$dirty = git status --porcelain
if ($dirty) {
    Write-Err 'Working tree is not clean. Commit or stash first:'
    $dirty -split "`n" | Select-Object -First 15 | ForEach-Object { Write-Host "      $_" }
    throw 'Aborting: refusing to rebase over uncommitted changes.'
}
$branch = git rev-parse --abbrev-ref HEAD
if ($branch -ne 'main') {
    Write-Warn "On branch '$branch', not 'main'. Rebasing '$branch' onto upstream/$UpstreamBranch."
}
Write-Ok "Clean, on '$branch'."

# --- Ensure remotes and safety settings ----------------------------------
Write-Step 'Checking remotes'
$remotes = git remote
if ($remotes -notcontains 'upstream') {
    git remote add upstream $UpstreamUrl
    Write-Ok "Added upstream -> $UpstreamUrl"
}
# Belt and braces: make it impossible to push to upstream by accident.
git remote set-url --push upstream 'DISABLED_no_push_to_upstream'
git config core.longpaths true      # .repos/ contains paths over the Win32 limit
git config rerere.enabled true      # remember conflict resolutions between syncs
git config rerere.autoupdate true
Write-Ok 'upstream is fetch-only; longpaths and rerere enabled.'

# --- Fetch ----------------------------------------------------------------
Write-Step "Fetching upstream/$UpstreamBranch"
$before = git rev-parse HEAD
$oldUpstream = git rev-parse "upstream/$UpstreamBranch" 2>$null
git fetch upstream $UpstreamBranch --prune
if ($LASTEXITCODE -ne 0) { throw 'Fetch from upstream failed.' }
$newUpstream = git rev-parse "upstream/$UpstreamBranch"

if ($oldUpstream -eq $newUpstream) {
    Write-Ok 'Upstream unchanged since last sync.'
} else {
    $incoming = git rev-list --count "$oldUpstream..$newUpstream" 2>$null
    Write-Ok "$incoming new upstream commit(s)."
}

# --- Show the local stack about to be replayed ---------------------------
Write-Step 'Local commits to replay'
$localCommits = @(git log --oneline "$newUpstream..HEAD" 2>$null)
if ($localCommits.Count -eq 0) {
    Write-Ok 'None - this fork has no local commits.'
} else {
    $localCommits | ForEach-Object { Write-Host "      $_" }
}

# --- Rebase ---------------------------------------------------------------
Write-Step "Rebasing onto upstream/$UpstreamBranch"
git rebase "upstream/$UpstreamBranch"
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Err 'Rebase stopped on a conflict.'
    $conflicts = git diff --name-only --diff-filter=U
    if ($conflicts) {
        Write-Host '    Conflicted files:' -ForegroundColor Red
        $conflicts -split "`n" | ForEach-Object { Write-Host "      $_" }
    }
    Write-Host ''
    Write-Host '    Resolve, then:' -ForegroundColor Yellow
    Write-Host '      git add <files>'
    Write-Host '      git rebase --continue'
    Write-Host '      pwsh -File scripts/sync-fork.ps1 -Push'
    Write-Host ''
    Write-Host '    Or abandon this sync:' -ForegroundColor Yellow
    Write-Host '      git rebase --abort'
    Write-Host ''
    Write-Host '    rerere is on, so this resolution is recorded and replayed next time.' -ForegroundColor DarkGray
    exit 1
}
Write-Ok 'Rebase clean.'

# --- Did upstream absorb the patch? --------------------------------------
if (-not $NoFetchPatchState) {
    Write-Step "Checking whether PR $PatchPr has merged upstream"
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) {
        Write-Warn 'gh CLI not found; skipping. Re-run with -NoFetchPatchState to silence.'
    } else {
        $state = gh pr view $PatchPr --repo pingdotgg/t3code --json state,mergedAt 2>$null | ConvertFrom-Json
        if ($null -eq $state) {
            Write-Warn 'Could not read PR state (not authenticated?). Skipping.'
        } elseif ($state.state -eq 'MERGED') {
            Write-Warn "PR $PatchPr has MERGED upstream. Your local copy of it is now redundant."
            Write-Warn 'git rebase usually drops it automatically once the patch IDs match.'
            Write-Warn 'If it survived, remove it with: git rebase -i upstream/main  (drop that commit)'
        } elseif ($state.state -eq 'CLOSED') {
            Write-Warn "PR $PatchPr was CLOSED without merging. Decide whether to keep carrying it."
        } else {
            Write-Ok "PR $PatchPr still open; local copy still needed."
        }
    }
}

# --- Push -----------------------------------------------------------------
if ($Push) {
    Write-Step 'Pushing to origin (force-with-lease)'
    git push --force-with-lease origin HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Push failed. Someone else may have pushed to origin; re-run without -Push and inspect.' }
    Write-Ok 'Pushed.'
} else {
    Write-Warn 'Not pushed. Re-run with -Push, or: git push --force-with-lease origin main'
}

# --- Summary --------------------------------------------------------------
$after = git rev-parse HEAD
Write-Host ''
Write-Step 'Summary'
if ($before -eq $after) {
    Write-Ok 'Nothing changed.'
} else {
    Write-Ok "HEAD $($before.Substring(0,8)) -> $($after.Substring(0,8))"
    Write-Host ''
    Write-Host '    Rebuild before running:' -ForegroundColor DarkGray
    Write-Host '      pnpm install'
    Write-Host '      pnpm build:desktop'
}
