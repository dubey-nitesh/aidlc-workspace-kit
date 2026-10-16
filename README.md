# aidlc-workspace-kit

[![CI](https://github.com/dubey-nitesh/aidlc-workspace-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/dubey-nitesh/aidlc-workspace-kit/actions/workflows/ci.yml)

Keep the output of AI-assisted workflows — [AI-DLC](https://github.com/awslabs/aidlc-workflows)
docs, [Graphify](https://pypi.org/project/graphifyy/) graphs, your own tools' folders — **out of
your project's git history**, versioned in a separate (usually private) **docs repo**, without
copying anything by hand.

```
 your project (working repo)                 your docs repo (private)
 ├── src/ …                                  ├── myapp/
 ├── CLAUDE.md, .aidlc-rule-details/         │   ├── aidlc-docs/      ◄── the real files
 ├── aidlc-docs/   ─── link ───────────────► │   ├── graphify-out/
 ├── graphify-out/ ─── link ───────────────► │   └── .aidlc-kit/record
 └── .gitignore    (the links are ignored)   └── other-project/ …
```

Your AI tool reads and writes `aidlc-docs/` as usual; the files actually live in the docs repo.
Hooks commit them there after each Claude Code turn and on every commit, and push them when you
`git push` the project. A fresh clone (or a cloud sandbox) gets them back with one command.

This repo is only the tool. Your docs never live here.

## Requirements

- `bash` 3.2+ and `git`. Linux, macOS, WSL, or **Git Bash on Windows** (which Claude Code on
  Windows uses for hooks anyway).
- Optional: `jq` or Python, to merge hooks into an existing `.claude/settings.local.json`.
- Optional: AI-DLC itself — the kit uses whatever installation you have (see
  [AI-DLC rules](#ai-dlc-rules)); it doesn't ship one.

## Install

```bash
git clone https://github.com/dubey-nitesh/aidlc-workspace-kit ~/aidlc-workspace-kit
export PATH="$HOME/aidlc-workspace-kit/bin:$PATH"     # add to your shell profile
aidlc-kit --help
```

## Quick start

```bash
# 1. A docs repo for all your projects (any git repo; make it private on your host)
git init ~/code/my-aidlc-docs

# 2. In a project: move its AI artifacts there, link them back, install the hooks
cd ~/code/myapp
aidlc-kit init --docs-repo ~/code/my-aidlc-docs

# 3. Commit what changed in the project: its .gitignore (and the AI-DLC rules,
#    if init installed them; `git status` shows them)
git add .gitignore && git commit -m "Keep AI-DLC docs in the docs repo"
```

`init` shows its plan and asks before changing anything (`--dry-run` to only look, `--yes` to
skip the question). From then on it's automatic:

| When | What happens |
|---|---|
| a Claude Code turn ends | changes are committed to the docs repo (in the background) |
| you commit in the project | same, labelled with your commit |
| you `git push` the project | the docs repo is pushed too — only if your own pre-push checks pass |
| a Claude Code session starts | broken links are repaired; problems are told to Claude |

On another machine, a fresh clone, or a cloud sandbox:

```bash
git clone <your project> && cd myapp
aidlc-kit attach --docs-repo ~/code/my-aidlc-docs     # links + hooks, docs restored
```

Check on things any time with `aidlc-kit status` and `aidlc-kit doctor`.

## How it works

- **Links.** Each managed path becomes a symlink — or, on Windows without Developer Mode, a
  directory junction (no admin rights needed) — into the docs repo. Every link is verified by
  writing through it, because Git Bash's plain `ln -s` silently makes a copy.
- **Copy mode.** Where a link isn't possible (a single file like `graph.json` on Windows without
  Developer Mode), the path is a real copy kept in step by a two-way sync: a change on one side
  is copied to the other; a file changed on both sides is a conflict, left untouched on both
  and reported. A folder that vanished (`git clean -fdx`) or was emptied by a tool is restored,
  never mass-deleted.
- **Commits** in the docs repo touch only that project's folder, even if you have other work
  staged there. Files a profile excludes (Graphify's machine-local `cache/`) stay out of it,
  and leave it if an older setup had committed them. Pushes never force, and never touch your own uncommitted work in the docs repo.
- **Hooks never block you.** `aidlc-kit hook …` always exits 0; details go to
  `.git/aidlc-kit/log` in the project.
- **Profiles** describe what to manage, so forks and future tool versions need a small text
  file, not code (see [Profiles](#profiles)).

The full design, including every edge case it handles, is in [docs/DESIGN.md](docs/DESIGN.md).

## Commands

| Command | Does |
|---|---|
| `init` | set up AI-DLC rules if missing, move artifacts into the docs repo, link them back, install hooks |
| `attach` | on a fresh clone / another machine: recreate links and hooks from the docs repo's record |
| `status` | each managed path, its mode and health; unmanaged artifacts a profile recognises |
| `save [--push]` | sync copy-mode paths and commit (what the hooks run); exit 2 on copy conflicts |
| `adopt <path>…` | start managing more paths (e.g. a new tool version writes somewhere new) |
| `doctor` | check links, sync state, docs repo, hooks; exit 1 on problems |
| `hooks install\|uninstall` | (re)install or remove the git and Claude Code hooks |
| `skill install\|uninstall` | the `aidlc-init` Claude Code skill, for all your projects |
| `migrate-legacy` | move a docs folder from the old `ai-dlc-workspace` layout (see [docs/migrating.md](docs/migrating.md)) |
| `detach` | replace links with real copies, remove hooks, stop managing the project |

Common options: `--repo DIR` (default: current directory), `--docs-repo DIR`, `--name NAME`
(the project's folder in the docs repo), `--profile NAME`, `--path PATH`, `--link-mode
auto|link|copy`, `-n/--dry-run`, `-y/--yes`. `aidlc-kit --help` lists them all.

## Configuration

Settings come from (highest first) command-line flags, `AIDLC_*` environment variables, then a
config file: the first of `$AIDLC_KIT_CONFIG`, `./aidlc-kit.conf`, `<kit>/aidlc-kit.conf`,
`~/.config/aidlc-kit/config`. It's `KEY=VALUE` lines, parsed, never executed; relative paths
resolve against the file's own folder. See [aidlc-kit.conf.example](aidlc-kit.conf.example).

| Setting | Default | Meaning |
|---|---|---|
| `AIDLC_DOCS_REPO` | — | the docs repo (needed for the first `init`/`attach` unless `--docs-repo`) |
| `AIDLC_LINK_MODE` | `auto` | `auto` (link, else copy) · `link` (never copy) · `copy` (never link) |
| `AIDLC_HOOKS` | `all` | `all`, `none`, `claude`, `git`, or a list of `session-start,stop,session-end,post-commit,pre-push` |
| `AIDLC_AUTO_COMMIT` | `on` | hooks commit to the docs repo (`off`: they only sync) |
| `AIDLC_AUTO_PUSH` | `on` | `git push` of the project also pushes the docs repo |
| `AIDLC_PROFILES_DIR` | — | extra profiles (forks, other tools) |
| `AIDLC_RULES_DIR` | — | a local AI-DLC 1.x `aidlc-rules/` folder for `init` to install from |
| `AIDLC_TARGET` | `claude` | which tool `init` installs rules for (1.x layout, or 2.x `--harness`): `claude`, `agents`, `cursor`, `cline`, `kiro`, `amazonq` |

## Profiles

A profile says how to recognise a tool and which paths it writes:

```
# ~/.config/aidlc-kit/profiles/myfork.profile
name=myfork
detect=.myfork/            # present in the project -> this profile applies
path=docs/ai/              # managed; a trailing / means a folder
exclude=docs/ai/**/.cache/ # never committed to the docs repo (gitignore syntax)
```

Built in: `aidlc-v1` (`aidlc-docs/`), `aidlc-v2` (`aidlc/`, minus its engine state) and
`graphify` (`graphify-out/`, `graph.json`). Profiles are read from the kit, then
`~/.config/aidlc-kit/profiles/`, then `AIDLC_PROFILES_DIR`, then the docs repo's
`.aidlc-kit/profiles/` (shared with everyone using that docs repo); a later one with the same
name wins. `init` picks the profiles that match; `--profile` and `--path` choose explicitly.

## AI-DLC rules

The kit doesn't ship AI-DLC; `init` uses what you have, in this order:

1. The project already has AI-DLC rules → left alone.
2. `AIDLC_RULES_DIR` points at 1.x rules (an extracted release zip's `aidlc-rules/`, or a clone)
   → copied in the layout for `--target`. An existing `CLAUDE.md` is never overwritten.
3. The upstream 2.x `aidlc` CLI is installed → `aidlc config --harness <target>`, after asking.
4. Nothing → a pointer to upstream; artifact management works either way.

`--no-rules` skips this step.

## husky and other committed hooks

If git runs hooks from a folder inside the project (husky's `core.hooksPath`), the kit doesn't
edit them: `init` prints one line to add at the end of `.husky/pre-push` and
`.husky/post-commit`. The line calls `aidlc-kit` from your PATH, so it's safe to commit for the
whole team: it does nothing for anyone without the kit or whose clone isn't set up.

## Windows

Use Git Bash. Folders are linked with junctions, which need no special rights. Single files
(`graph.json`) need real symlinks, which need Developer Mode; without it they use copy mode,
kept in step automatically. `AIDLC_LINK_MODE=link` refuses copy mode instead.

## Cloud sandboxes

See [docs/cloud.md](docs/cloud.md): clone the kit and your docs repo in the sandbox's setup
step, then `aidlc-kit attach`.

## Claude Code skill

`.claude/skills/aidlc-init/` teaches Claude Code to bootstrap a project with this kit. It's
available whenever you open this repo; `aidlc-kit skill install` makes `/aidlc-init` available in
all your projects.

## Stop using it

`aidlc-kit detach` replaces the links with real copies, removes the hooks and the `.gitignore`
block, and leaves the docs repo untouched.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md). MIT licensed
([LICENSE](LICENSE)). Not affiliated with or endorsed by AWS or Anthropic.
