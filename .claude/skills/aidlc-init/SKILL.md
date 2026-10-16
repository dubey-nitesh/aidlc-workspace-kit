---
name: aidlc-init
description: "Use when the user wants a project's AI-DLC docs, Graphify output or similar AI-generated artifacts kept out of the project's git history in a separate docs repo with aidlc-workspace-kit (`aidlc-kit`) — setting it up in a new or existing project, attaching a fresh clone or cloud sandbox, migrating from the old ai-dlc-workspace/sync.sh layout, or fixing it when `aidlc-kit doctor` reports problems. Triggers: 'set up AI-DLC docs repo here', 'keep aidlc-docs out of git', 'bootstrap this repo like the other projects', 'aidlc-kit init/attach', '/aidlc-init'. Not for routine AI-DLC phase work (Requirements Analysis, Construction, ...) in an already set-up repo — that follows the repo's own AI-DLC rules."
---

# /aidlc-init

Sets a project up with **aidlc-workspace-kit**: AI-generated artifacts (AI-DLC `aidlc-docs/` or
`aidlc/`, Graphify `graphify-out/` and `graph.json`, or paths a custom profile names) move into a
separate docs repo and are linked back; hooks commit and push them automatically.

## 1. Find the tool and the docs repo

- `aidlc-kit` on PATH, or `<kit>/bin/aidlc-kit` in a clone of aidlc-workspace-kit. If neither
  exists, ask the user where the kit is or whether to clone it — never guess a URL.
- The docs repo: `AIDLC_DOCS_REPO` (env or config file), or ask. It must be a directory outside
  the project; a git repo is strongly recommended (`git init` it if the user agrees).
- Find out where the project stands first:
  - `aidlc-kit status` works → this clone is set up; use `doctor` for problems, or `attach`
    for missing links.
  - `status` says "not set up" but `.gitignore` has the `# >>> aidlc-workspace-kit >>>`
    block → the project was set up elsewhere and this is a fresh clone or another machine:
    use `attach` (see "Other situations"), not `init`.
  - Neither → a new setup: `init`, below.

## 2. Ask only what you can't infer

- **Docs repo location** (above).
- **Name** in the docs repo (`--name`) only if the project folder name differs from the
  existing folder in the docs repo (e.g. a renamed repo).
- **AI-DLC rules**: if the project has none, `init` uses `AIDLC_RULES_DIR` (a 1.x rules folder)
  or offers the upstream 2.x `aidlc config` when that CLI is installed. `--target` picks the
  tool layout (claude, agents, cursor, cline, kiro, amazonq). `--no-rules` skips it.
- **Hooks**: all by default (`AIDLC_HOOKS`); mention that `git push` will also push the docs
  repo (`AIDLC_AUTO_PUSH=off` to disable).

## 3. Preview, then run

```bash
aidlc-kit init --docs-repo <docs repo> --dry-run      # show the plan; changes nothing
aidlc-kit init --docs-repo <docs repo>                # asks before changing anything
```

Show the user the plan. If `init` reports a conflict (the same path has content in both
repos), ask which side to keep and re-run with `--prefer working` or `--prefer docs` (the other
side is backed up). Use `--yes` only after the user has approved the plan.

## 4. Commit

- In the project: `.gitignore` gained the managed block (it may be a new file), plus the AI-DLC
  rules if `init` installed them. Show `git status` and the diff; let the user commit them
  (`git add` the new files: `commit -a` misses them).
- In the docs repo: `aidlc-kit save` commits the project's folder; `save --push` also pushes.
  Don't push either repo without the user's go-ahead.

## 5. Check

`aidlc-kit doctor` should end with "All good." A WARN about a missing upstream means `git push`
won't push the docs repo until the user runs `git -C <docs repo> push -u origin HEAD`.

## Other situations

- **Fresh clone, other machine:** `aidlc-kit attach --docs-repo <docs repo>` (the folder name
  comes from the project's `.gitignore` block; `--name <folder>` only for older setups).
- **Cloud sandbox:** see the kit's `docs/cloud.md` (setup script: clone kit + docs repo,
  `attach --yes`).
- **Old ai-dlc-workspace layout:** `aidlc-kit migrate-legacy --docs-repo <old repo> --name <folder>`,
  then `init --name <folder>` in the project (see `docs/migrating.md`).
- **A tool now writes somewhere new:** `aidlc-kit status` lists it as unmanaged;
  `aidlc-kit adopt <path>`.
- **A fork or another tool:** add a profile (`name=`, `detect=`, `path=`, `exclude=`) in
  `~/.config/aidlc-kit/profiles/` or the docs repo's `.aidlc-kit/profiles/`.
- **Stop using it:** `aidlc-kit detach` (links become real copies; docs repo untouched).
