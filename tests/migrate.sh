#!/usr/bin/env bash
# Tests for migrate-legacy: the old ai-dlc-workspace layout (<project>/graphify/)
# becomes the kit's layout, and init links a project to it.
# Run: bash tests/migrate.sh
# shellcheck disable=SC2016  # $1, $2 in bash -c '...' belong to that inner shell
set -uo pipefail

# shellcheck source=helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# a docs folder as the old scripts/sync.sh left it
legacy_docs() { # name
  local p="$D/$1"
  mkdir -p "$p/aidlc-docs/inception" "$p/graphify/graphify-out"
  echo "legacy req" > "$p/aidlc-docs/requirements.md"
  echo "legacy plan" > "$p/aidlc-docs/inception/plan.md"
  echo '{"legacy":1}' > "$p/graphify/graph.json"
  echo "<html>legacy" > "$p/graphify/graphify-out/graph.html"
  mkdir -p "$p/graphify/graphify-out/cache/ast"   # the old scripts committed graphify's cache
  echo '{"C:/x/m.py":{"mtime_ns":1}}' > "$p/graphify/graphify-out/cache/stat-index.json"
  git -C "$D" add -A && git -C "$D" commit -qm "old layout"
}

# the project as a fresh clone: its artifacts only ever lived in the docs repo
clean_project() { rm -rf "$W/aidlc-docs" "$W/graphify-out" "$W/graph.json"; }

echo "dry run"
new_sandbox
legacy_docs old-name
check "dry run succeeds" kit migrate-legacy --docs-repo "$D" --name old-name --dry-run
check "...and moves nothing" test -f "$D/old-name/graphify/graph.json"
check "...nor creates the new paths" test ! -e "$D/old-name/graph.json"

echo "migrate"
check "migrate" kit migrate-legacy --docs-repo "$D" --name old-name --yes
check "graph.json moved up" grep -q legacy "$D/old-name/graph.json"
check "graphify-out/ moved up" grep -q legacy "$D/old-name/graphify-out/graph.html"
check "empty graphify/ removed" test ! -e "$D/old-name/graphify"
check "aidlc-docs/ untouched" grep -q "legacy req" "$D/old-name/aidlc-docs/requirements.md"
check "nothing committed" bash -c "[ \"\$(git -C '$D' log --oneline | wc -l)\" -eq 1 ]"
check "prints the next init command" bash -c "bash '$CLI' migrate-legacy --docs-repo '$D' --name old-name < /dev/null 2>&1 | grep -q 'init --docs-repo'"
check "a second run has nothing to do" bash -c "bash '$CLI' migrate-legacy --docs-repo '$D' --name old-name < /dev/null 2>&1 | grep -q 'Nothing to migrate'"

echo "init after migrating"
git -C "$D" add -A && git -C "$D" commit -qm "new layout"
clean_project
check "init --name with explicit profiles" kit init "$W" --docs-repo "$D" --name old-name --profile aidlc-v1 --profile graphify --yes
check "aidlc-docs/ readable in the project" grep -q "legacy req" "$W/aidlc-docs/requirements.md"
check "graphify-out/ readable in the project" grep -q legacy "$W/graphify-out/graph.html"
check "graph.json present in the project" grep -q legacy "$W/graph.json"
check "record written under the old name" test -f "$D/old-name/.aidlc-kit/record"
check "doctor is happy" kit doctor "$W"

echo "excluded files leave the docs repo's history"
echo theirs > "$D/unrelated.txt" && git -C "$D" add unrelated.txt
check "save" kit save "$W"
check "graphify's cache is no longer tracked" bash -c '[ -z "$(git -C "$1" ls-files -- old-name/graphify-out/cache)" ]' _ "$D"
check "...but stays on disk" test -f "$D/old-name/graphify-out/cache/stat-index.json"
check "...and is ignored from now on" git -C "$D" check-ignore -q old-name/graphify-out/cache/stat-index.json
check "the rest of graphify-out/ is still tracked" bash -c 'git -C "$1" ls-files -- old-name/graphify-out | grep -q graph.html' _ "$D"
check "the user's staged file is still staged" bash -c 'git -C "$1" diff --cached --name-only | grep -qx unrelated.txt' _ "$D"
check "...and wasn't committed" bash -c '! git -C "$1" log --name-only --format= | grep -q unrelated.txt' _ "$D"
check "the docs index matches the commit for the project" bash -c '[ -z "$(git -C "$1" status --porcelain -- old-name)" ]' _ "$D"
echo '{"C:/x/m.py":{"mtime_ns":2}}' > "$D/old-name/graphify-out/cache/stat-index.json"
check "a cache-only change: dry run says nothing to commit" bash -c 'bash "$1" save "$2" --dry-run < /dev/null 2>&1 | grep -q "nothing to commit"' _ "$CLI" "$W"
check "...and so does the real save" bash -c 'bash "$1" save "$2" < /dev/null 2>&1 | grep -q "nothing to commit"' _ "$CLI" "$W"

echo "a setup from before the profile excluded graphify's cache"
new_sandbox
mkdir -p "$W/graphify-out/cache" && echo '{"m":1}' > "$W/graphify-out/cache/stat-index.json"
kit init "$W" --docs-repo "$D" --profile aidlc-v1 --profile graphify --yes >/dev/null 2>&1
# what an older kit wrote: no exclude in the record or the docs .gitignore
sed -i.bak '/^exclude=graphify-out\/cache\/$/d' "$D/app/.aidlc-kit/record" && rm -f "$D/app/.aidlc-kit/record.bak"
sed -i.bak '/graphify-out\/cache/d' "$D/app/.gitignore" && rm -f "$D/app/.gitignore.bak"
git -C "$D" add -A && git -C "$D" commit -qm "older setup" 2>/dev/null
check "(the cache starts out tracked)" bash -c '[ -n "$(git -C "$1" ls-files -- app/graphify-out/cache)" ]' _ "$D"
echo '{"m":2}' > "$W/graphify-out/cache/stat-index.json"
check "save" kit save "$W"
check "the docs .gitignore gains the profile's new exclude" grep -q '^/graphify-out/cache/$' "$D/app/.gitignore"
check "...and the cache leaves the index" bash -c '[ -z "$(git -C "$1" ls-files -- app/graphify-out/cache)" ]' _ "$D"

echo "never overwrites"
new_sandbox
legacy_docs p
echo '{"new":1}' > "$D/p/graph.json"
check_not "refuses when graph.json exists at both levels" kit migrate-legacy --docs-repo "$D" --name p --yes
check "...new one untouched" grep -q new "$D/p/graph.json"
check "...old one untouched" grep -q legacy "$D/p/graphify/graph.json"
check "...graphify-out/ not moved either" test -d "$D/p/graphify/graphify-out"

echo "partial and unexpected content"
new_sandbox
mkdir -p "$D/q/graphify/graphify-out" && echo x > "$D/q/graphify/graphify-out/a.html"
echo note > "$D/q/graphify/notes.txt"
check "only graphify-out/ (no graph.json yet)" kit migrate-legacy --docs-repo "$D" --name q --yes
check "...moved" test -f "$D/q/graphify-out/a.html"
check "graphify/ kept when it holds other files" test -f "$D/q/graphify/notes.txt"
check "...with a warning naming them" bash -c "mkdir -p '$D/q2/graphify' && echo n > '$D/q2/graphify/notes.txt' && bash '$CLI' migrate-legacy --docs-repo '$D' --name q2 < /dev/null 2>&1 | grep -q 'notes.txt'"

echo "dry run previews the graphify/ cleanup"
new_sandbox
legacy_docs r
echo note > "$D/r/graphify/notes.txt"
check "dry run names the files that keep graphify/" bash -c "bash '$CLI' migrate-legacy --docs-repo '$D' --name r --dry-run < /dev/null 2>&1 | grep -q 'kept: it also holds notes.txt'"
check "...and moves nothing" test -f "$D/r/graphify/graph.json"
mkdir -p "$D/e/graphify"
check "an empty graphify/: dry run says it would go" bash -c "bash '$CLI' migrate-legacy --docs-repo '$D' --name e --dry-run < /dev/null 2>&1 | grep -q 'remove the then-empty graphify/'"
check "...but keeps it" test -d "$D/e/graphify"
check "real run removes it" kit migrate-legacy --docs-repo "$D" --name e --yes
check "...gone" test ! -e "$D/e/graphify"

echo "asks first"
new_sandbox
legacy_docs s
check_not "no terminal and no --yes: refuses" kit migrate-legacy --docs-repo "$D" --name s
check "...nothing moved" test -f "$D/s/graphify/graph.json"

echo "printed commands are safe to paste"
new_sandbox
# no '"' (Windows forbids it) or '`' (Git Bash then stops converting the path for git)
DQ="$SB/odd \$HOME docs"
mkdir -p "$DQ" && git -C "$DQ" init -q -b main
git -C "$DQ" config user.email t@example.com; git -C "$DQ" config user.name t
mkdir -p "$DQ/p/graphify" && echo '{}' > "$DQ/p/graphify/graph.json"
kit migrate-legacy --docs-repo "$DQ" --name p --yes > "$SB/out" 2>&1
check "the printed git command runs as is" bash -c "grep '  git -C ' '$SB/out' | sed 's/^  //' | bash"
check "...and commits in that docs repo" bash -c "git -C \"\$1\" log --oneline | grep -q 'aidlc-kit layout'" _ "$DQ"

echo "the old layout's .gitkeep"
new_sandbox
mkdir -p "$D/k/graphify/graphify-out" && echo x > "$D/k/graphify/graphify-out/a.html" && : > "$D/k/graphify/.gitkeep"
check "migrate with a .gitkeep placeholder" kit migrate-legacy --docs-repo "$D" --name k --yes
check "...removes graphify/ with it" test ! -e "$D/k/graphify"
mkdir -p "$D/none"
check "nothing to migrate: no commit suggested" bash -c 'out="$(bash "$1" migrate-legacy --docs-repo "$2" --name none < /dev/null 2>&1)" && ! echo "$out" | grep -q "commit" && echo "$out" | grep -q "init --docs-repo"' _ "$CLI" "$D"

echo "bad input"
new_sandbox
check_not "needs --name" kit migrate-legacy --docs-repo "$D"
check_not "needs a docs repo" kit migrate-legacy --name x
check_not "unknown project folder" kit migrate-legacy --docs-repo "$D" --name nope
check_not "rejects an unsafe name" kit migrate-legacy --docs-repo "$D" --name ../x
check_not "takes no working repo" kit migrate-legacy "$W" --docs-repo "$D" --name x
check_not "rejects save-only options" kit migrate-legacy --docs-repo "$D" --name x --push

summary
