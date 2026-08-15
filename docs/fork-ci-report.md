# Fork CI/CD audit: `MMAgeek/t3code` (fork of `pingdotgg/t3code`)

Audit of all 13 workflows that shipped in `.github/workflows/`, covering what would have happened
now that Actions is enabled, what (if anything) could reach upstream infrastructure, and how to run
builds and CI entirely on GitHub-hosted runners in this repo.

**Status: applied.** Sections 1-2 are the audit record of the workflows as inherited. Section 3
records the changes made. The repo is a public fork used to build the desktop app and run it
locally; mobile is out of scope.

---

## 1. Headline answer

**Nothing in these workflows could run on Blacksmith's fleet or write to `pingdotgg/t3code`.**
Two mechanisms make that structurally true:

1. **Runner labels are scoped to the repo/org that registered them.** `runs-on: blacksmith-8vcpu-ubuntu-2404`
   resolves only against runners registered to _this_ repository or _this_ account. Blacksmith is a
   third-party managed-runner provider installed as a GitHub App on the upstream org. This fork has
   no such runners, so those jobs sit in **Queued** and are dropped after ~24 hours. That is a
   breakage problem, not a leakage problem - your jobs cannot land on their machines.
2. **Forks do not inherit secrets or repository variables.** Every `${{ secrets.* }}` and
   `${{ vars.* }}` reference in these workflows resolves to an empty string. Cloudflare, PlanetScale,
   Vercel, Expo, npm, Apple, Azure Trusted Signing, Discord and AUR credentials are all absent, so
   the deploy/publish jobs fail closed rather than deploying anywhere.

`GITHUB_TOKEN` is the exception - it is minted per-run and scoped to **your** repo, so every
label, comment, release and commit those workflows create would land in `MMAgeek/t3code`. That is
correct behaviour, but it means the release workflow would have happily cut releases and pushed
commits to your `main` if it had ever got past the runner problem.

### The three things that genuinely pointed at upstream-owned namespaces

These were the only paths touching anything outside this repo. All three failed for lack of
credentials, but all three have been removed rather than relied on:

| #   | Location                                        | What it targeted                                                                                                                                                            | State when found                                                           |
| --- | ----------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| 1   | `packaging/aur/scripts/release.sh:5`            | Hardcoded `repo='pingdotgg/t3code'`; reads their GitHub releases, then **pushes to `ssh://aur@aur.archlinux.org/t3code-bin.git`** - upstream's Arch User Repository package | Fails at push: no `AUR_SSH_PRIVATE_KEY`                                    |
| 2   | `release.yml` → `publish_cli`                   | Publishes the npm package literally named **`t3`** (`apps/server/package.json`) - upstream's package name                                                                   | Fails: no npm auth / OIDC trusted-publishing config                        |
| 3   | `apps/mobile/app.config.ts:369-372`, `eas.json` | `owner: "pingdotgg"`, Expo `projectId: d763fcb8-…`, updates URL `https://u.expo.dev/d763fcb8-…`, App Store Connect `ascAppId: 6787819824`                                   | Skipped cleanly: both EAS workflows gate on an `EXPO_TOKEN` presence check |

Item 3 was the one to watch. Both EAS workflows explicitly skipped when `EXPO_TOKEN` was unset - but
the moment you added _your own_ `EXPO_TOKEN`, `eas env:pull production` and `eas build` would have
resolved against **pingdotgg's Expo project**, not yours. The workflows are now gone; if you ever
reinstate mobile, change `owner`/`projectId` before setting that secret.

One thing that self-corrects: desktop auto-update. `scripts/build-desktop-artifact.ts:1908-1917`
falls back to `GITHUB_REPOSITORY` when `T3CODE_DESKTOP_UPDATE_REPOSITORY` is unset, so any installers
built here point their updater at `MMAgeek/t3code`. No change needed.

---

## 2. Workflow-by-workflow (as inherited)

| Workflow                          | Trigger                                          | Runner                                                  | Secrets needed                                                                  | Behaviour in the fork                                                                                                 |
| --------------------------------- | ------------------------------------------------ | ------------------------------------------------------- | ------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `ci.yml`                          | PR, push to `main`                               | blacksmith ubuntu ×3, blacksmith macOS ×1               | none                                                                            | **Queued forever.** The one worth keeping.                                                                            |
| `pr-size.yml`                     | `pull_request_target`                            | `ubuntu-24.04`                                          | none                                                                            | Worked as-is. Labels PR size.                                                                                         |
| `pr-vouch.yml`                    | `pull_request_target`, `issue_comment`, push     | `ubuntu-24.04`                                          | none                                                                            | Worked, but applies upstream's `.github/VOUCHED.td` trust list via `mitchellh/vouch`. Meaningless in a personal fork. |
| `issue-labels.yml`                | push to `main` (template paths), dispatch        | `ubuntu-24.04`                                          | none                                                                            | Worked. Creates 3 labels. Harmless.                                                                                   |
| `thread-transfer-report.yml`      | `workflow_run` on CI                             | `ubuntu-24.04`                                          | none                                                                            | Ran only after CI completed, so effectively dead.                                                                     |
| `mobile-fingerprint-check.yml`    | PR touching mobile paths                         | blacksmith ubuntu                                       | none                                                                            | Queued forever. Advisory only.                                                                                        |
| `mobile-eas-preview.yml`          | PR with a specific label                         | blacksmith ubuntu                                       | `EXPO_TOKEN`                                                                    | Queued; would skip on missing token.                                                                                  |
| `mobile-eas-production.yml`       | push to `main` (mobile paths), dispatch          | blacksmith ubuntu                                       | `EXPO_TOKEN`, `RELEASE_APP_*`                                                   | Queued; would skip. **Pointed at upstream's Expo project.**                                                           |
| `mobile-showcase-screenshots.yml` | `workflow_dispatch` only                         | blacksmith macOS 12vcpu, ubuntu 16vcpu                  | none                                                                            | Manual only. Expensive (macOS + Android emulator).                                                                    |
| `web-preview.yml`                 | PR labelled `preview:web`                        | blacksmith ubuntu                                       | `VERCEL_*`                                                                      | Queued; then hard-fails with an explicit "missing Vercel secrets" message.                                            |
| `deploy-relay.yml`                | **every push to `main`**                         | blacksmith ubuntu                                       | Cloudflare, PlanetScale, Axiom, Clerk, APNs                                     | Queued on every merge. Would deploy production Cloudflare infra if creds existed.                                     |
| `release.yml`                     | tags `v*.*.*`, **`cron: 0 */3 * * *`**, dispatch | blacksmith ×9 incl. 32vcpu Windows/Linux + 12vcpu macOS | ~20 secrets: npm, Apple, Azure signing, Vercel, Cloudflare, Discord, GitHub App | Queued. The 3-hourly nightly cron was the noisiest item.                                                              |
| `publish-aur.yml`                 | called by `release.yml`, dispatch                | blacksmith ubuntu                                       | `AUR_SSH_PRIVATE_KEY`                                                           | Would attempt to publish **upstream's AUR package**.                                                                  |

### Triggers worth knowing about

- **The 3-hourly cron.** `release.yml` carried `schedule: - cron: "0 */3 * * *"` for nightly releases.
  GitHub disables scheduled workflows in forks by default, but Actions has just been enabled here.
  Left alone this was 8 failed/queued runs per day, forever.
- **`deploy-relay.yml` ran on every push to `main`**, including every upstream sync pulled down.
  That is a red X on `main` after every merge.
- **`pull_request_target` in `pr-size.yml` and `pr-vouch.yml`** runs with a write-capable token against
  the base repo. Both were correctly written (they never execute PR code; `pr-size` fetches PR commits
  as passive git data only). Worth remembering if you ever reinstate them.
- **Fork PRs to upstream are unaffected.** If you open a PR to `pingdotgg/t3code`, _their_ workflow
  files run in _their_ context. Nothing in this fork's `.github/` influences their repo.

### Third-party action supply chain

`expo/expo-github-action/continuous-deploy-fingerprint@main` (`mobile-eas-preview.yml:85`) was pinned to a
**moving branch**, not a tag or SHA - pin to a SHA if mobile is ever reinstated. Also present:
`voidzero-dev/setup-vp@v1` (essential - the Vite+ toolchain the whole repo builds on),
`dtolnay/rust-toolchain@stable`, `softprops/action-gh-release@v3`, `mitchellh/vouch`,
`reactivecircus/android-emulator-runner@v2`, `gradle/actions/setup-gradle@v5`.

---

## 3. Changes applied

### Deleted (12 workflows)

`release.yml`, `publish-aur.yml`, `deploy-relay.yml`, `web-preview.yml`, `mobile-eas-preview.yml`,
`mobile-eas-production.yml`, `mobile-showcase-screenshots.yml`, `mobile-fingerprint-check.yml`,
`pr-vouch.yml`, `pr-size.yml`, `issue-labels.yml`, `thread-transfer-report.yml`.

Rationale by group:

- **Outward-pointing** (`release`, `publish-aur`, `deploy-relay`, `web-preview`): every one targets a
  third-party account - AUR, npm, Cloudflare, Vercel - and several target upstream's namespace
  specifically. None can work here and none should.
- **Mobile** (four workflows): out of scope, and two of them resolve against upstream's Expo project.
- **PR hygiene** (`pr-vouch`, `pr-size`, `issue-labels`, `thread-transfer-report`): these worked and
  cost nothing, but they are collaboration tooling for a busy upstream repo. On a solo fork they are
  noise. `pr-vouch` in particular enforces upstream's contributor trust list.

Non-workflow files left in place deliberately: `.github/scripts/thread-transfer-report.cjs` (and its
test), `.github/VOUCHED.td`, and `packaging/aur/`. They trigger nothing on their own, and leaving them
reduces merge-conflict surface when syncing from upstream.

### Kept and rewritten: `ci.yml`

Two jobs, both on `ubuntu-24.04`, no secrets, no external services:

- **Check** - `vp check`, `vpr typecheck`, `cargo fmt --check`, `vp run build:desktop`, and the
  preload-bundle verification. This is the job that proves the desktop app actually builds.
- **Test** - `vp run test`, the transfer-budget step summary, and `cargo test` for the Rust
  resource monitor.

Specific edits:

| Change                                                      | Why                                                                                                                                                                            |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `blacksmith-8vcpu-ubuntu-2404` → `ubuntu-24.04` (both jobs) | The only change CI actually needed - it uses no secrets                                                                                                                        |
| `timeout-minutes: 10` → `20`                                | GitHub's standard runner is 4 vCPU / 16 GB against Blacksmith's 8 vCPU; the original 10-minute budget was tuned for the faster machine and would have caused spurious timeouts |
| Dropped the `mobile_native_static_analysis` job             | macOS-only, mobile-only (`brew bundle` + `vp run lint:mobile`)                                                                                                                 |
| Dropped the `release_smoke` job                             | Exercises release-only script paths; `release.yml` is gone                                                                                                                     |
| Dropped the `Upload thread transfer result` step            | Its only consumer was `thread-transfer-report.yml`                                                                                                                             |

The transfer-budget **step summary** is retained - it still renders in the run output, it just no
longer uploads an artifact nobody reads.

### Not done

Nothing was committed or pushed. Review with `git diff` / `git status` and commit when you are happy.

---

## 4. End state

One workflow, `ci.yml`, running two `ubuntu-24.04` jobs on every PR and every push to `main`.

- **Cost: zero.** Standard GitHub-hosted runners are free and uncapped on public repositories.
- **Secrets required: none.** There is nothing to configure in repo settings.
- **Reach: none.** No path to Cloudflare, Vercel, Expo, npm, AUR, Discord or App Store Connect.

### Building and running locally

CI now mirrors what you would run yourself, so a green run means a working local build:

```bash
pnpm dev
```

Other relevant scripts from the root `package.json`: `pnpm dev:desktop` (Electron app only),
`pnpm build:desktop`, `pnpm typecheck`, `pnpm test`, and `pnpm dist:desktop:win` if you ever want a
packaged installer locally rather than in CI.

### Keeping it this way across upstream syncs

Pulling from upstream will keep reintroducing Blacksmith labels and the deleted files. Resolve
`.github/` conflicts by taking your side:

```bash
git checkout --ours .github/workflows && git add .github/workflows
```

If you would rather keep upstream's files but make them inert, the alternative is a repository guard
on each job you do not want firing:

```yaml
if: github.repository == 'pingdotgg/t3code'
```

That makes the job a no-op in every fork, including this one, without deleting anything.

---

## 5. Daily upstream sync + carrying PR 4546

### The model

The fork is maintained as a **rebased stack**: `main` is `upstream/main` plus a short, ordered set of
local commits.

```
upstream/main ──┬── chore(ci): trim workflows for fork
                └── fix: discover project-level Claude skills  (PR 4546, rebased)
```

Syncing is therefore one operation - `git rebase upstream/main` - which replays the stack onto the
new upstream tip. This is better than re-cherry-picking the raw upstream PR each day, because you
resolve its conflicts **once** and carry the resolved version forward.

`git rerere` is enabled (`rerere.enabled`, `rerere.autoupdate`), so a conflict resolved once is
replayed automatically on subsequent rebases. That matters a lot here - see the drift warning below.

### Daily command

```bash
pwsh -File scripts/sync-fork.ps1 -Push
```

`scripts/sync-fork.ps1` does the following, refusing to continue at the first sign of trouble:

1. Aborts unless the working tree is clean.
2. Ensures the `upstream` remote exists and **disables its push URL** (`DISABLED_no_push_to_upstream`),
   so pushing to pingdotgg is impossible even by accident.
3. Sets `core.longpaths`, `rerere.enabled`, `rerere.autoupdate`.
4. Fetches `upstream/main` and reports how many commits arrived.
5. Lists the local commits about to be replayed, then rebases.
6. On conflict: stops, lists the conflicted files, prints the resolve/continue/abort commands, exits 1.
7. Checks via `gh` whether PR 4546 has merged upstream, and says so if the local copy is now redundant.
8. With `-Push`, force-pushes to origin using `--force-with-lease`.

Rebasing rewrites history, so pushing to your fork requires a force push. `--force-with-lease` is used
rather than `--force` so a push is rejected if origin has commits you have not seen.

Run without `-Push` first if you want to inspect the result before it leaves the machine.

### Warning: PR 4546 is stale and does not apply cleanly

Verified against today's `upstream/main` with an in-memory three-way merge:

- The PR branches off `5719e8ac`. Upstream/main is now **415 commits ahead** of that point.
- It is **open, not merged** (`Rido:fix/project-skills-picker-discovery`, single commit `ce84ea7f`,
  11 files, +280/-28). Now applied locally as a rebased 12-file commit - see below.
- Applying it onto current `upstream/main` produces **5 conflict hunks across 3 files**:

  | File                                            | Hunks |
  | ----------------------------------------------- | ----- |
  | `apps/server/src/ws.ts`                         | 1     |
  | `apps/web/src/components/chat/ChatComposer.tsx` | 2     |
  | `apps/web/src/state/queries.ts`                 | 2     |

  The other 8 files in the PR auto-merge cleanly.

The conflicts come from heavy upstream churn in the composer and query layers - `cad2c936`,
`b28f9bf0`, `d7abd7f3` and others all rewrote those files after the PR was opened.

**Good news:** the PR touches only `apps/server`, `apps/web`, `packages/client-runtime` and
`packages/contracts`. There is **no overlap with `.github/workflows/`**, so it will never conflict
with the CI trim commit.

### How the conflicts were resolved

Four of the five hunks were additive - two features landing in the same region, where the resolution
is simply "keep both sides":

| Hunk                              | Resolution                                                                                                       |
| --------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `queries.ts` imports              | Merged both import lists (`ProjectContentMatch`/`ProjectEntryKind` + `ProviderInstanceId`/`ServerProviderSkill`) |
| `queries.ts` body                 | Kept upstream's `useProjectContentSearch` and appended the PR's `useWorkspaceProviderSkills`                     |
| `ChatComposer.tsx` top-level      | Kept upstream's `ComposerCommandMenuPosition` type and the PR's `EMPTY_PROVIDER_SKILLS` const                    |
| `ChatComposer.tsx` `useMemo` deps | Merged both dependency lists (kept `planModeUiEnabled`, added `workspaceProviderSkills`)                         |

**The `ws.ts` hunk was not a merge - it was a port.** The PR adds one entry to a
`RPC_REQUIRED_SCOPE` map in `ws.ts`, but upstream **deleted that map** in `a04c09a1`
("Use HttpApi for Environment APIs & standardize authn/authz"). Scope declarations now live in
`apps/server/src/auth/RpcAuthorization.ts` as `RPC_REQUIRED_SCOPES`, an object literal, consumed via
`requiredScopeForRpcMethod`.

Taking either side of that conflict would have been wrong. Resolution:

1. Kept upstream's side of the `ws.ts` hunk verbatim (the `THREAD_RESUME_MAX_GAP` constant), dropping
   the PR's obsolete map wholesale.
2. Added the entry to its new home instead:

   ```ts
   [WS_METHODS.serverDiscoverProviderSkills]: AuthOrchestrationReadScope,
   ```

This is not optional. `RPC_REQUIRED_SCOPES` ends with
`satisfies Readonly<Record<WsRpcMethod, AuthEnvironmentScope>>`, so every method in `WsRpcGroup` must
have a scope or the build fails - which is exactly how the port was confirmed correct. The local
commit therefore touches **12 files**, one more than the upstream PR.

The PR's other `ws.ts` changes (the `ProviderInstanceRegistry` import, the registry binding, and the
`serverDiscoverProviderSkills` handler) auto-merged and were verified present afterwards.

### Verification

| Gate                                                | Result                                         |
| --------------------------------------------------- | ---------------------------------------------- |
| `pnpm typecheck`                                    | **exit 0, 0 errors** across all 15 projects    |
| `npx vp check` (lint + format)                      | **exit 0**, 0 errors (9 pre-existing warnings) |
| `RpcAuthorization.test.ts` + `ClaudeSkills.test.ts` | **12 passed**                                  |
| `pnpm test` (full suite)                            | 342 passed, **5 failed**                       |

The 5 failures are in `packages/shared/src/logging.test.ts` (1) and
`packages/shared/src/relayClient.test.ts` (4) - files neither the PR nor the CI commit touches. They
were confirmed pre-existing by checking out clean `upstream/main` and running the same two files
there: **identical 5 failures**. They look like Windows-specific path/executable-resolution
assumptions and are unrelated to this work. Linux CI may well be green.

Because rerere recorded the resolution, later rebases that hit the same conflict replay it
automatically rather than asking again.

To refresh the patch if its author pushes an update:

```bash
git fetch upstream 'refs/pull/4546/head:refs/fork-patches/pr-4546' --force
```

Then drop your old copy of the commit (`git rebase -i upstream/main`) and cherry-pick the new ref.

### When the PR merges upstream

`git rebase` compares patch IDs and usually drops a local commit once an equivalent lands upstream,
so the stack self-cleans. The sync script also queries the PR state and warns you explicitly. If your
resolved version diverged enough that git cannot match it, remove it manually with
`git rebase -i upstream/main` and drop the commit.

### Why not automate this in Actions

A scheduled workflow could do the sync, but it would have to force-push `main`, and you would then
need `git reset --hard origin/main` locally anyway before building. Since you build and run locally,
doing the sync locally is simpler, gives you the result immediately in your working tree, and keeps
conflict resolution interactive - which, given the drift on PR 4546, is where the real work is.
