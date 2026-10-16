# Cloud sandboxes (Claude Code on the web and similar)

A sandbox clones only your project. Its `aidlc-docs/` (or other managed paths) are gitignored, so
the sandbox starts without them — and without the kit, your docs repo, or the hooks. Add this to
the sandbox's **setup script**:

```bash
set -e
KIT="$HOME/aidlc-workspace-kit"
DOCS="$HOME/my-aidlc-docs"
DOCS_URL="https://github.com/you/my-aidlc-docs"

# Each step skips work already done, so the script can run again. A clone goes to a
# temporary folder first: an interrupted one leaves nothing a later run would mistake
# for a finished checkout.
clone_once() { # clone_once <dir> <git clone args...>
  dir="$1"; shift
  [ -d "$dir" ] && return 0
  rm -rf "$dir.part"
  git "$@" "$dir.part" && mv "$dir.part" "$dir"
}

# 1. The kit (public)
clone_once "$KIT" clone --depth 1 https://github.com/dubey-nitesh/aidlc-workspace-kit

# 2. Your docs repo (private). The token comes from a secret environment variable
#    (here DOCS_REPO_TOKEN), read by a credential helper at run time: it is never written
#    into a clone URL, .git/config or the logs, and only the docs repo uses it (the
#    project's own remote keeps the sandbox's credentials).
HELPER='!f() { echo username=x-access-token; echo "password=$DOCS_REPO_TOKEN"; }; f'
clone_once "$DOCS" -c credential.helper= -c "credential.helper=$HELPER" clone "$DOCS_URL"
git -C "$DOCS" config --replace-all credential.helper ''    # ignore other helpers here...
git -C "$DOCS" config --add credential.helper "$HELPER"     # ...and use this one
git -C "$DOCS" config user.name  "Cloud session"
git -C "$DOCS" config user.email "cloud@example.com"

# 3. Link the docs back into the project and install the hooks
"$KIT/bin/aidlc-kit" attach --docs-repo "$DOCS" --yes
```

Run it from the project's directory (or add `--repo <project dir>`). The project's folder in the
docs repo is read from the project's committed `.gitignore` block; a project set up with an older
kit may need `--name <folder>` once.

What you get:

- the project's docs, exactly as last pushed to the docs repo;
- the Claude Code hooks, so each turn's changes are committed to the docs repo inside the
  sandbox;
- the git `pre-push` hook, so pushing the project's branch also pushes the docs repo (when the
  token can push).

Notes:

- The token needs read access to the docs repo, and write access if the sandbox should push.
- If the sandbox's network policy blocks GitHub, none of this works; check its allow-list.
- Without the setup step, a cloud session can still do Construction work on top of an
  already-approved design; it just doesn't see or record the AI-DLC docs.
- Not yet verified end to end in a live Claude Code cloud session — please report what you find.
