# Migrating from the old `ai-dlc-workspace` layout

Earlier setups kept AI-DLC docs in a sibling `ai-dlc-workspace` repo and copied them with
`scripts/sync.sh pull|push`. Its folders looked like this:

```
ai-dlc-workspace/
└── <project>/
    ├── aidlc-docs/
    └── graphify/
        ├── graph.json
        └── graphify-out/
```

The kit keeps every path exactly where it is in the project, so the graph files move up one
level. `migrate-legacy` does that, then you `init` the project as usual.

```bash
# 1. In the docs repo: move <project>/graphify/* up, then commit
aidlc-kit migrate-legacy --docs-repo ~/code/ai-dlc-workspace --name myapp-dev
git -C ~/code/ai-dlc-workspace add -A -- myapp-dev
git -C ~/code/ai-dlc-workspace commit -m "myapp-dev: aidlc-kit layout"

# 2. In the project: link the docs back (nothing is moved: they're already in the docs repo)
cd ~/code/myapp
aidlc-kit init --docs-repo ~/code/ai-dlc-workspace --name myapp-dev
git commit -m "Keep AI-DLC docs in the docs repo" -- .gitignore
```

- `--name` is the project's folder in the docs repo, when it differs from the project's own
  folder name (as with `myapp` / `myapp-dev` above). It's needed once: `init`
  records it in the project's `.gitignore` block, so later clones just run `attach`.
- What to manage is detected from the docs repo too: the project's `aidlc-docs/` and
  `graphify-out/` there are linked back even though the project itself has neither yet.
  (`--profile aidlc-v1 --profile graphify` says so explicitly.)
- An old folder's `graphify/.gitkeep` placeholder is removed with the then-empty `graphify/`.
- If the project still has a local `aidlc-docs/` (from a `push`) and it differs from the docs
  repo, `init` stops and asks you to choose with `--prefer working` or `--prefer docs`; the
  other side is backed up first.
- The old repo's own tool files (`scripts/`, `aidlc-rules/`, `.claude/skills/aidlc-init/`) are no
  longer used; delete them from it whenever you like.
- `migrate-legacy` never overwrites: if `<project>/graph.json` or `<project>/graphify-out/`
  already exists, it stops and tells you.
- The old scripts committed Graphify's `graphify-out/cache/` (machine-local paths and timestamps).
  The `graphify` profile excludes it, so the first `save` after `init` removes it from the docs
  repo's index; the files stay on disk, and `graphify update` keeps using them.
