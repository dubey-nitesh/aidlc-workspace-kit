# aidlc-workspace-kit — design (v2)

Status: **milestones 1–4 built** (core: config, profiles, record, link strategy,
`init`/`attach`/`status`/`detach`; then `save` with lock, commit, push and copy-mode sync; then hooks, `doctor`, `adopt`; then rules detection; see §16). Replaces the copy-based `sync.sh` + vendored-rules
design, which stays in the repo until milestone 4.

## 1. Problem and goal

AI-assisted workflows (AI-DLC, its forks and future versions, Graphify, …) write large, fast-
changing, often private artifacts into the **working repo** (e.g. `aidlc-docs/`,
`graphify-out/`). Committing them bloats the project's history; not committing them loses them.

**Goal:** keep those artifacts out of the working repo's history, versioned in a separate
**docs repo**, with no manual steps in daily use, on Windows, macOS, Linux and in cloud
sandboxes.

**Non-goals:** shipping or vendoring AI-DLC rules; understanding what's inside the artifacts;
running a background service.

## 2. Concepts

| Term | Meaning |
|---|---|
| **Kit** | This repo: scripts, profiles, the `aidlc-init` skill. Public. Holds no user docs. |
| **Working repo** | A project, e.g. `myapp`. |
| **Docs repo** | A separate (usually private) git repo holding artifacts for one or more projects, e.g. the user's `ai-dlc-workspace`. |
| **Profile** | A small data file describing one tool/version: how to detect it, which paths it writes. |
| **Managed path** | One path in the working repo kept in the docs repo (dir or file). |
| **Mode** | Per managed path: `symlink`, `junction` (Windows dirs) or `copy`. |
| **Project record** | Per-project file in the docs repo recording the managed paths, their modes, and settings. |

```
myapp/                               (working repo)      ai-dlc-workspace/           (docs repo)
├── aidlc-docs/  ── link ────────────────────────────►   ├── myapp/
├── graphify-out/ ── link ───────────────────────────►   │   ├── .aidlc-kit/record
├── graph.json   (copy mode: file links need admin on Win) │   ├── aidlc-docs/
└── .gitignore   (managed paths listed)                  │   ├── graphify-out/
                                                         │   └── graph.json
                                                         └── other-project/ …
```

Paths inside `<docs>/<project>/` mirror their path in the working repo exactly (no renaming), so
nested paths like `docs/ai/` work unchanged.

## 3. Commands

Single entry point `bin/aidlc-kit` (bash), subcommands in `lib/`:

| Command | Does |
|---|---|
| `aidlc-kit init [<project-dir>]` | Detect profiles, confirm paths, move existing artifacts into the docs repo, create links (or copies), update `.gitignore`, write the project record, install hooks, optionally set up AI-DLC rules. Idempotent. |
| `aidlc-kit attach [<project-dir>]` | On a fresh clone / another machine / cloud sandbox: read the project record from the docs repo and recreate links (or copy in), plus hooks. |
| `aidlc-kit save [--push]` | Copy out (copy-mode paths), commit changes in the docs repo; `--push` also pushes. What the hooks call. |
| `aidlc-kit status` | Per path: mode, link healthy?, uncommitted changes, ahead/behind remote. |
| `aidlc-kit doctor` | `status` + re-run detection: warn about new artifact paths not yet managed, broken links, links that silently became copies, missing hooks. |
| `aidlc-kit adopt <path>` | Start managing an extra path (e.g. after a tool upgrade changes its output folder). |
| `aidlc-kit detach [<project-dir>]` | Undo: replace links with real copies, remove hooks and the `.gitignore` block. Docs repo untouched. |

`init`/`attach` take `--docs-repo <dir>`; otherwise the configured default is used.

## 4. Profiles (future-proofing for forks and versions)

Profiles are data, not code. Adding a fork = adding a file; no script change.

```
# profiles/aidlc-v1.profile
name=aidlc-v1
description=AWS AI-DLC 1.x (rules in CLAUDE.md / .aidlc-rule-details)
detect=.aidlc-rule-details/
detect=aidlc-docs/aidlc-state.md
path=aidlc-docs/

# profiles/aidlc-v2.profile
name=aidlc-v2
description=AWS AI-DLC 2.x (aidlc CLI)
detect=aidlc/spaces/
path=aidlc/
exclude=aidlc/**/.aidlc-engine/

# profiles/graphify.profile
name=graphify
detect=graphify-out/
detect=graph.json
path=graphify-out/
path=graph.json
```

- Format: `KEY=VALUE`, repeatable keys, `#` comments, parsed never sourced. `version=1` implied;
  a future format bump is explicit.
- Lookup order (later overrides same `name`): `<kit>/profiles/` → `~/.config/aidlc-kit/profiles/`
  → `<docs-repo>/.aidlc-kit/profiles/` (shareable with a team via the docs repo).
- `detect=` is any existing path (file or dir). A profile matches if any `detect` exists.
- `detect=`, `path=` and `exclude=` are all relative to the working repo root (a trailing `/`
  marks a directory; `exclude=` may use gitignore globs). Excludes are written into
  `<docs>/<project>/.gitignore` so transient state is committed nowhere.
- `init` shows matches and asks to confirm; `--path <p>` adds paths no profile knows;
  `--profile <name>` forces one.

## 5. Project record

`<docs-repo>/<project>/.aidlc-kit/record` — travels with the docs, so `attach` reproduces the
setup anywhere; the working repo gets nothing but its `.gitignore` block.

```
version=1
project=myapp
profile=aidlc-v1
profile=graphify
path=aidlc-docs/|dir
path=graphify-out/|dir
path=graph.json|file
```

Mode is **not** stored: it's a property of the machine (a Windows laptop may need `junction`
while CI on Linux uses `symlink`), decided at `init`/`attach` time and cached in the working
repo's `.git/aidlc-kit/state` (never committed).

## 6. Link strategy (verified on Windows 10, Git Bash, Developer Mode off)

Per managed path, first that works:

| | Directory | File |
|---|---|---|
| 1 | native symlink (`ln -s`, with `MSYS=winsymlinks:nativestrict` on Windows) | same |
| 2 | Windows only: junction — `MSYS_NO_PATHCONV=1 cmd /c mklink /J <link> <target>` with `cygpath -w` paths | — (junctions are dir-only) |
| 3 | copy mode | copy mode |

Findings that drive this:
- Plain `ln -s` in Git Bash **silently makes a copy**. Never call it without `nativestrict`.
- `nativestrict` fails without Developer Mode / admin → fall through.
- Junctions need no admin; `[ -L ]` is true for them; writes go through; git ignores them when
  gitignored; `rm` removes only the link.
- After creating any link, **verify** by writing a probe file through it and checking it appears
  in the docs repo (then delete it). A link that fails the probe is removed and the next option
  is tried. `doctor` re-runs the probe.

Paths with spaces are supported throughout (tested case: `Project Principal`).

Gitignore entries are written **without** a trailing slash (`/aidlc-docs`, not `/aidlc-docs/`):
to git, a symlink to a directory is not a directory, so a trailing-slash pattern would not
ignore it. The managed block is rewritten only when its content changes, and keeps the file's
line endings, so a CRLF checkout on Windows stays clean.

## 7. Moving existing content at `init`

| Working repo has | Docs repo has | Action |
|---|---|---|
| content | nothing | move into docs repo, then link |
| nothing | content | link (restores context) |
| content | content | stop; show a short diff summary; require `--prefer working` or `--prefer docs` (the other side is backed up to `.aidlc-kit/backup/<timestamp>/` in the docs repo, gitignored) |

Content is never deleted without a backup.

Order of operations, so an interrupted run can always be finished by re-running `init` or
`attach`: plan and conflict check → (with `--link-mode link`) a preflight proving the needed
link types work here → write the record, state and ignore blocks → move/link path by path,
updating the machine state after each one. A working-repo link whose docs folder has gone
missing is recreated (`relink`) rather than reported as foreign.

The project name (its folder in the docs repo) is, in order: `--name`; the one this clone's
state recorded; the one in the working repo's committed `.gitignore` block (`# docs-repo
folder: NAME`, written by `init`), so a fresh clone in a differently named folder or a cloud
sandbox needs no `--name`; else the working repo's folder name made safe (`My App (old)` →
`My-App-old`).

Profiles are auto-detected from the working repo (`detect=`) and from the project's folder in
the docs repo: a profile whose `path=` already exists there applies, so a fresh clone or a
migrated project gets back everything it had.

## 8. Events and hooks

Built in milestone 3 (`lib/hooks.sh`). Every hook runs `bash "<kit>/bin/aidlc-kit" hook <event>`.

| Event | Mechanism | Action |
|---|---|---|
| Claude Code turn ends | `Stop` hook, `"async": true` (never slows a turn) | `save` (no-op if nothing changed) |
| Claude Code session ends | `SessionEnd` hook, `"timeout": 30` (default budget is 1.5 s) | `save` |
| Claude Code session starts | `SessionStart` hook, `"timeout": 60` | recreate missing links, two-way copy-mode sync, then print only problems — Claude Code adds `SessionStart` stdout to the session's context |
| Commit in working repo | git `post-commit`, in the background | `save` — message references the working-repo commit |
| Push of working repo | git `pre-push`, in the foreground | `save --push` (just `save` with `AIDLC_AUTO_PUSH=off`) |
| Manual | `aidlc-kit save [--push]` | — |

`AIDLC_HOOKS` picks the events (`all` by default; also `claude`, `git`, `none`, or a list
like `stop,pre-push`). `AIDLC_AUTO_COMMIT=off` makes the hooks only sync, never commit.

No timer: the Stop hook already fires after every turn during active work and is a no-op
otherwise. A scheduler (cron / Task Scheduler) can be added later if needed.

Rules for hooks:
- **Never block or fail the user's action.** `aidlc-kit hook` always exits 0; details go to
  `.git/aidlc-kit/log` (trimmed to the last ~1000 lines). On `pre-push` the "pushed the docs
  repo" line and any warning are shown on the push output.
- **Git's hook environment is cleared first** (`git rev-parse --local-env-vars`): git exports
  `GIT_DIR` etc. to hooks, which would otherwise make `git -C <docs repo>` act on the working
  repo.
- `settings.local.json` (per machine; added to `.git/info/exclude` if not already ignored):
  created if absent; if present, merged with `jq` or Python (a `python3` that is only the
  Windows Store stub doesn't count), keeping every other setting and hook; otherwise the snippet
  is printed and the file left untouched. Our entries are recognised by their command
  (`aidlc-kit … hook …`), so re-installing replaces them and uninstalling removes only them.
- Git hooks: our marked block is inserted right after the shebang, never replacing the file;
  `core.hooksPath` is honoured. `pre-push` first runs the rest of the hook as a child process
  and pushes the docs repo only if it succeeded (this holds after an explicit `exit 0`, an
  `exec`, or the hook's own traps; earlier versions used an `EXIT` trap, which an `exec`
  bypasses). Not edited, with what to add printed instead: hooks that aren't shell scripts
  (Python, Node, …), and hook folders inside the working tree (husky, committed hooks). For the
  latter it's one line using `aidlc-kit` from PATH (no absolute path; a no-op for teammates
  without the kit or whose clone isn't set up), suggested for the file people edit — husky v9's
  `.husky/<hook>`, not its generated `.husky/_/` — at its end, after the project's own checks;
  `doctor` recognises the line.
  `detach`/`hooks uninstall` remove only the block, and delete a hook file we created that
  holds nothing else. `post-commit` does nothing while the working repo is replaying commits
  (rebase, cherry-pick, am).
- Installed commands carry `--hook-format N`; `doctor` reports hooks from an older kit version
  as outdated, and `hooks install` refreshes them.
- A tracked `.claude/settings.local.json` is never edited (it would commit this machine's paths);
  the snippet is printed instead.
- The hook runner keeps `set -e` in force (it runs its work in a subshell outside any `||`), and
  a copy-mode copy that fails keeps the previous baseline, so it is retried and never recorded
  as done.
- Concurrency: the docs-repo lock (§9).

`doctor` checks the managed paths (links, copy-mode conflicts, unmanaged artifacts), the docs
repo (git, identity, upstream when pushes are on), each enabled hook (installed and pointing at
this kit), and stale locks; it exits 1 on problems. `adopt <path>...` starts managing more
paths in a set-up repo; `status` suggests it for artifacts a profile recognises.

## 9. Commit, push, and copy-mode drift

Built in milestone 2 as `aidlc-kit save [--push] [-m MSG] [--trigger NAME] [-n]` (`lib/save.sh`):

- **Lock:** `mkdir` of `<docs .git>/aidlc-kit.lock` holding the owner's pid, shared by `save`,
  `init` and `attach` (one docs repo = one lock, so projects sharing a docs repo serialize).
  A busy lock makes `save` skip with exit 0 (the next event catches up) — except `save --push`,
  which waits up to 30 s and then fails (exit 1), since nothing would retry the push — and
  makes `init`/`attach` stop. A lock whose pid is dead — or that has no pid after a minute — is
  stale; it is broken under a second short `mkdir` mutex that re-checks staleness, so two
  processes breaking the same stale lock can't both end up holding it.
- **Commit:** through a private index (`<docs git dir>/index.aidlc-kit`: a copy of the real one
  with HEAD read in by a one-tree `read-tree -m`, which keeps git's stat cache without scanning
  the work tree; then `add -A -- <project>`), so only that folder is committed, the user's own
  staged work elsewhere stays staged, and tracked files that the project's `.gitignore` files
  now exclude leave the index (`commit -- <path>` would re-add them from disk; the user's
  global or `info/exclude` patterns don't count). Afterwards the real index is reset for
  `<project>/` only. Before committing, the docs-side `.gitignore` block is rewritten with the
  record's excludes plus those its profiles have now, so a profile's new `exclude=` (a kit
  upgrade) reaches projects set up earlier. Message:
  `<project>: AI artifacts @ <work-branch> <short-sha> (<trigger>)` or `-m`. Uses the docs
  repo's own git identity. Skipped (with a warning, exit 0) when the docs repo is not a git
  repo or is mid-merge/rebase.
- **Push** (`--push`): refuses if the docs repo is mid-merge/rebase/am or has other uncommitted
  tracked changes (rebasing would need `--autostash`, which loses the user's staging);
  otherwise `pull --rebase`, then `push` to the upstream. Never forces. On failure: abort only
  the rebase this command started, keep the local commit, warn with git's own message. Network
  git runs never wait for input: `GIT_TERMINAL_PROMPT=0` and ssh in `BatchMode`
  (`core.sshCommand` is kept; a `GIT_SSH` program such as plink is left alone).
- **Exit codes:** 0 ok · 1 commit or push failed · 2 copy-mode conflicts (everything else was
  still synced and committed).
- **Link repair:** links that vanished from the working repo (`git clean -fdx` deletes ignored
  links, never their targets) are recreated on the next `save`.
- **Copy mode — two-way sync:** a last-sync manifest (`cksum` per file) in
  `.git/aidlc-kit/manifest`. A file changed on one side only is copied to the other; deleted on
  one side only is deleted on the other; changed on both sides is a conflict, left untouched on
  both sides, reported by `save` (exit 2) and `status`. A managed path that is missing
  *entirely* on one side — or a managed folder that is suddenly empty there while the last sync
  had files (a tool clearing its output before regenerating) — is restored from the other side
  instead of being treated as deleted, so `git clean -fdx` or a regeneration can never turn
  into a mass deletion in the docs repo. Deleting a whole managed folder on purpose is done in
  the docs repo (or with `detach`). After a deletion, only the folders it emptied are removed;
  empty placeholder folders a tool created are left alone. `init`/`attach` run the
  same sync, so a fresh clone gets the docs and the baseline in one step.
- Settings: `AIDLC_AUTO_COMMIT=on|off`, `AIDLC_AUTO_PUSH=on|off` (default on/on) are for the
  hooks (milestone 3); an explicit `save` always commits.
- Testing aid: `AIDLC_KIT_SIMULATE_NO_LINKS=1` makes every link attempt fail, so copy mode and
  the `--link-mode link` preflight can be exercised on any machine.

## 10. AI-DLC rules: use the existing installation

Built in milestone 4 (`lib/rules.sh`). No vendored rules. `init` (unless `--no-rules`), before
it moves anything, so a bad `AIDLC_RULES_DIR` or `--target` stops it early:
1. Rules already in the project (a 1.x rule-details folder in any layout, or 2.x's
   `aidlc/spaces/`) → leave them alone.
2. The upstream 2.x `aidlc` CLI is on PATH → run `aidlc config --harness <h>` in the project,
   after confirmation (`--yes`; skipped with a message when there's no terminal, since rules
   are optional). Harness from `--target`: claude → claude, cursor → cursor, kiro → kiro-ide,
   agents → codex; cline/amazonq have no 2.x harness → a message, nothing run.
3. `AIDLC_RULES_DIR` points at 1.x rules (a release zip's `aidlc-rules/` folder, or a clone of
   the repo) → copy them in the layout for `--target` (claude, agents, cursor, cline, kiro,
   amazonq). An existing entry file (e.g. a project's own `CLAUDE.md`) is never overwritten;
   the user is told to append the workflow.
4. Nothing found → print where rules come from; artifact management works either way.

The old `scripts/sync.sh` / `init-project.sh` and the vendored `aidlc-rules/` are removed; their
settings in a config file fail with a pointer to the replacement (`AIDLC_DATA_DIR` →
`AIDLC_DOCS_REPO`, …).

## 11. Configuration

Precedence: CLI flag > env var > config file > default. Config file lookup and parsing as today
(`KEY=VALUE`, parsed, unknown keys rejected).

| Setting | Default | Meaning |
|---|---|---|
| `AIDLC_DOCS_REPO` | (required on first `init`) | Docs repo directory |
| `AIDLC_LINK_MODE` | `auto` | `auto` (link, else copy; §6) / `link` (symlink or junction, never copy) / `copy` |
| `AIDLC_AUTO_COMMIT` | `on` | Hooks commit to the docs repo |
| `AIDLC_AUTO_PUSH` | `on` | Working-repo push also pushes the docs repo |
| `AIDLC_HOOKS` | `all` | Hooks to install: `all`, `none`, `claude`, `git`, or events (`session-start,stop,session-end,post-commit,pre-push`) |
| `AIDLC_PROFILES_DIR` | — | Extra profile directory |
| `AIDLC_TARGET` | `claude` | Rule layout when installing 1.x rules |
| `AIDLC_RULES_DIR` | — | Local 1.x rules folder (§10) |

## 12. Cloud sandboxes

Sandbox setup script, documented in [cloud.md](cloud.md) (a copy-paste snippet rather than a
script, since it has to run before the kit exists in the sandbox):
1. Clone the kit and the docs repo. Credentials come from an env var / credential helper —
   never embedded in a clone URL or logged.
2. `aidlc-kit attach <project>` → links + hooks (settings.local.json isn't in the clone, so
   `attach` recreates it).
3. Pushing the working branch triggers `pre-push` → docs pushed too.

## 13. Testing and CI

- Plain-bash test suites (no dependencies): `tests/core.sh`, `save.sh`, `hooks.sh`, `rules.sh`, `migrate.sh`,
  sharing `tests/helpers.sh`.
- CI matrix: ubuntu, macos (bash 3.2 + BSD tools), **windows (Git Bash)** — the Windows job
  covers the silent-copy trap, junction fallback, file-path copy mode, and paths with spaces.
- shellcheck on all scripts.

## 14. Migration (for existing users of the old workspace layout)

The old layout stored Graphify output under `<project>/graphify/`. A one-time
`aidlc-kit migrate-legacy --docs-repo <old repo> --name <folder>` moves `graphify/graph.json` →
`graph.json` and `graphify/graphify-out/` → `graphify-out/` (refusing to overwrite anything), and
prints the `init` command to run next; `init` then writes the record and links the paths. It
doesn't commit: the user reviews and commits the move. Renamed projects (`myapp` ↔
`myapp-dev`) are handled by `--name`. Walkthrough: [migrating.md](migrating.md).

## 15. To verify during the build

- ✅ Claude Code hooks, in a live session (`claude -p`, Windows/Git Bash): SessionStart, Stop
  and SessionEnd all run from `settings.local.json` and commit to the docs repo. In a one-shot
  `-p` run the async Stop hook can be cut off when the process exits; SessionEnd (synchronous)
  saves anyway. The kit's own leftovers from a save killed mid-commit (its lock, its private
  index) don't block the next save; a lock git itself left (`index.lock`, a ref's `.lock`) does,
  and every save fails (git's message is in `.git/aidlc-kit/log`) until it is removed.
- ✅ Graphify 0.9 (`graphify update`, also `--force`) writes through a linked `graphify-out/`
  (a junction on Windows) and keeps the link. It now writes `graph.json` inside `graphify-out/`;
  the profile still manages a top-level `graph.json` for older versions. Its `cache/` holds
  absolute local paths and mtimes, changes every run and is rebuilt without an LLM, so the
  profile excludes it.
- ✅ `core.hooksPath` inside the working tree, husky v9 layout (`.husky/_/` running
  `.husky/<hook>` with `sh -e`): the suggested line commits on `post-commit`, pushes on
  `pre-push`, and doesn't push when an earlier check fails (`tests/hooks.sh`).
- ✅ AI-DLC 2.x, from upstream's source (awslabs/aidlc-workflows `harness/*/dot-gitignore`,
  docs/guide/14): the `aidlc-v2` profile now excludes every machine-local entry upstream
  ignores (`aidlc/.aidlc-*` incl. the per-clone `.aidlc-clone-id`, `active-space`,
  `active-intent`, `active-memory/`, `.aidlc-engine/`, `runtime-graph.json`, …); tested.
  Note: upstream commits `aidlc/` (its rules live in `aidlc/spaces/*/memory/`) and its doctor
  warns about a `.gitignore` rule hiding those records; the kit's `/aidlc` line is that rule,
  by design.
- ✅ pre-commit (4.x hook template, verbatim): its hooks `exec pre-commit`, which an `EXIT`
  trap can't survive, so `pre-push` now runs the rest of the hook as a child and pushes the
  docs repo only if it succeeded (hook format 2). `pre-commit install` rewrites its hook files
  and drops our block; `doctor` then reports it and `aidlc-kit hooks install` restores it.
- ✅ Cloud setup snippet, rehearsed locally twice in a fake home (credential helper checked
  with `git credential fill`); an interrupted clone no longer leaves a half-made folder.
  Not yet run in a real Claude Code cloud session.

## 16. Build order

1. ✅ Core: config, profiles, record, link strategy + probe, `init`/`attach`/`status`/`detach`
   (`bin/aidlc-kit`, `lib/`, `profiles/`, `tests/core.sh`).
2. ✅ `save` with lock, commit, push; copy-mode two-way sync (`lib/save.sh`, `tests/save.sh`).
3. ✅ Hooks (git, Claude Code) + `doctor`/`adopt` (`lib/hooks.sh`, `tests/hooks.sh`).
4. ✅ Rules detection (§10); vendored `aidlc-rules/` and the legacy scripts removed (`lib/rules.sh`, `tests/rules.sh`).
5. ✅ Skill rewrite, README, cloud docs, `migrate-legacy` (`docs/cloud.md`, `docs/migrating.md`, `tests/migrate.sh`).
6. Windows CI; then migrate the author's own projects as the first real-world test.
