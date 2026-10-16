#!/usr/bin/env bash
# Tests for milestone 3: git + Claude Code hooks, the hook runner, doctor, adopt.
# Run: bash tests/hooks.sh
set -uo pipefail

# shellcheck source=helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

commits() { git -C "$D" rev-list --count HEAD 2>/dev/null || echo 0; }
commits_above() { [ "$(commits)" -gt "$1" ]; }   # re-evaluated on every poll
hooks_dir() { echo "$W/.git/hooks"; }
settings() { echo "$W/.claude/settings.local.json"; }

# wait_until CMD... — poll up to ~15 s (background post-commit saves)
wait_until() {
  local n=0
  until "$@" >/dev/null 2>&1; do
    n=$((n + 1)); [ "$n" -ge 60 ] && return 1
    sleep 0.25
  done
}

# the exact command Claude Code would run for EVENT, taken from settings.local.json
claude_cmd() {
  grep -o "\"command\": \"bash [^\"]*\\\\\"[^\"]*\\\\\" hook $1 --hook-format [0-9]*\"" "$(settings)" | head -n 1 |
    sed -e 's/^"command": "//' -e 's/"$//' -e 's/\\"/"/g'
}

# a JSON tool that really works here (python3 may be a Windows Store stub)
JSON_TOOLS=""
for t in jq python3 python; do
  if command -v "$t" >/dev/null 2>&1; then
    if [ "$t" = jq ] || "$t" -c 'import json' >/dev/null 2>&1; then JSON_TOOLS="$JSON_TOOLS $t"; fi
  fi
done

setup_hooked() { # init with every hook installed
  new_sandbox
  rm -rf "$W/graphify-out" "$W/graph.json"   # only AI-DLC docs here: nothing unmanaged
  export AIDLC_HOOKS=all
  kit init "$W" --docs-repo "$D" --profile aidlc-v1 --yes >/dev/null 2>&1
}

echo "install"
setup_hooked
check "post-commit hook installed and executable" test -x "$(hooks_dir)/post-commit"
check "pre-push hook installed and executable" test -x "$(hooks_dir)/pre-push"
check "Claude settings written" test -f "$(settings)"
for e in SessionStart Stop SessionEnd; do
  check "settings has $e" grep -q "\"$e\"" "$(settings)"
done
check "Stop hook is async (never slows a turn)" grep -q '"async": true' "$(settings)"
check "SessionEnd gets more than the 1.5 s default" grep -q '"timeout": 30' "$(settings)"
check "settings.local.json is ignored by git in this clone" git -C "$W" check-ignore -q .claude/settings.local.json
check "working tree stays clean apart from .gitignore" bash -c "[ \"\$(git -C '$W' status --porcelain)\" = ' M .gitignore' ]"
kit hooks install "$W" >/dev/null 2>&1
check "re-install keeps one block per hook" bash -c "[ \$(grep -c 'aidlc-workspace-kit >>>' '$(hooks_dir)/post-commit') -eq 1 ]"
check "re-install keeps one Claude entry per event" bash -c "[ \$(grep -c 'hook stop' '$(settings)') -eq 1 ]"
check "doctor is happy" kit doctor "$W"

echo "git hooks run"
echo "change" >> "$W/aidlc-docs/requirements.md"
before="$(commits)"
git -C "$W" add .gitignore; git -C "$W" commit -qm "work"
check "post-commit triggers a docs commit (in the background)" wait_until commits_above "$before"
check "...in the docs repo, not the working repo (GIT_DIR not leaked)" bash -c "git -C '$D' log -1 --format=%s | grep -q '(post-commit)$' && ! git -C '$W' log -1 --format=%s | grep -q 'AI artifacts'"
check "...and it was logged" wait_until grep -q "post-commit exit=0" "$W/.git/aidlc-kit/log"

git init -q --bare -b main "$SB/work-remote.git"; git -C "$W" remote add origin "$SB/work-remote.git"
git init -q --bare -b main "$SB/docs-remote.git"; git -C "$D" remote add origin "$SB/docs-remote.git"; git -C "$D" push -q -u origin main
echo "more" >> "$W/aidlc-docs/requirements.md"
wait_until test ! -e "$(git -C "$D" rev-parse --absolute-git-dir)/aidlc-kit.lock"
git -C "$W" push -q -u origin main 2> "$SB/push-err"
check "pre-push pushes the docs repo too" test "$(git -C "$SB/docs-remote.git" rev-parse main)" = "$(git -C "$D" rev-parse HEAD)"
check "...with the latest change" bash -c "git -C '$SB/docs-remote.git' show main:app/aidlc-docs/requirements.md | grep -qx more"
check "...and says so on the push output" grep -q "pushed the docs repo" "$SB/push-err"

git -C "$D" remote set-url origin "$SB/nowhere.git"
echo "again" >> "$W/aidlc-docs/requirements.md"
git -C "$W" commit -q --allow-empty -m "x"
wait_until test ! -e "$(git -C "$D" rev-parse --absolute-git-dir)/aidlc-kit.lock"
check "a failing docs push never blocks the working repo's push" git -C "$W" push -q origin main

echo "existing hooks are kept"
new_sandbox
printf '#!/bin/sh\necho user-hook-ran > "%s/user-hook"\nexit 0\n' "$SB" > "$W/.git/hooks/post-commit"; chmod +x "$W/.git/hooks/post-commit"
export AIDLC_HOOKS=git
kit init "$W" --docs-repo "$D" --profile aidlc-v1 --yes >/dev/null 2>&1
check "our block sits right after the shebang (before the user's exit 0)" bash -c "sed -n 2p '$W/.git/hooks/post-commit' | grep -q 'aidlc-workspace-kit >>>'"
before="$(commits)"
git -C "$W" commit -q --allow-empty -m "x"
check "user's hook still runs" wait_until test -f "$SB/user-hook"
check "our hook runs too" wait_until commits_above "$before"
check "no Claude settings when AIDLC_HOOKS=git" test ! -e "$(settings)"
kit hooks uninstall "$W" >/dev/null 2>&1
check "uninstall keeps the user's hook" grep -q "user-hook-ran" "$W/.git/hooks/post-commit"
check "...without our block" bash -c "! grep -q aidlc-workspace-kit '$W/.git/hooks/post-commit'"
check "a hook file we created is removed entirely" test ! -e "$W/.git/hooks/pre-push"

echo "core.hooksPath"
new_sandbox
export AIDLC_HOOKS=git
git -C "$W" config core.hooksPath "$SB/shared-hooks"
kit init "$W" --docs-repo "$D" --profile aidlc-v1 --yes >/dev/null 2>&1
check "hooks go to core.hooksPath" test -x "$SB/shared-hooks/post-commit"
new_sandbox
export AIDLC_HOOKS=git
mkdir -p "$W/.husky"; git -C "$W" config core.hooksPath .husky
kit init "$W" --docs-repo "$D" --profile aidlc-v1 --yes > "$SB/out" 2>&1
check "hooks inside the working tree (husky) are not edited" test ! -e "$W/.husky/post-commit"
check "...the lines to add are printed instead" grep -q "hook post-commit" "$SB/out"

echo "husky v9 (core.hooksPath .husky/_)"
new_sandbox
export AIDLC_HOOKS=git
mkdir -p "$W/.husky/_" "$SB/bin"
# husky's generated, gitignored runners: .husky/_/<hook> runs .husky/<hook> with sh -e
for h in pre-push post-commit; do
  # shellcheck disable=SC2016  # $0 / $@ belong to the generated hook
  printf '#!/bin/sh\nf="$(dirname "$0")/../%s"\n[ -f "$f" ] || exit 0\nexec sh -e "$f" "$@"\n' "$h" > "$W/.husky/_/$h"
  chmod +x "$W/.husky/_/$h"
done
echo '*' > "$W/.husky/_/.gitignore"
git -C "$W" config core.hooksPath .husky/_
# aidlc-kit on PATH, as the README's install step sets it up
printf '#!/bin/sh\nexec bash "%s" "$@"\n' "$CLI" > "$SB/bin/aidlc-kit"; chmod +x "$SB/bin/aidlc-kit"
kit init "$W" --docs-repo "$D" --profile aidlc-v1 --profile graphify --yes > "$SB/out" 2>&1
check "the line is suggested for husky's own .husky/pre-push" grep -q "end of .*/app/\.husky/pre-push," "$SB/out"
# shellcheck disable=SC2016  # $1, $2 belong to the inner shell
check "...and has no absolute kit path in it" bash -c '! grep -A1 "end of " "$1" | grep -qF "$2"' _ "$SB/out" "$KIT"
check "husky's generated files are untouched" bash -c "! grep -q aidlc '$W/.husky/_/pre-push' '$W/.husky/_/post-commit'"
check_not "doctor: hooks missing until the lines are added" kit doctor "$W"
for h in pre-push post-commit; do
  { echo 'echo "own checks" >&2'; grep -A1 "end of .*/app/\.husky/$h," "$SB/out" | tail -n 1 | sed 's/^ *//'; } > "$W/.husky/$h"
done
check "doctor accepts the added lines" kit doctor "$W"
check "hooks install finds them" bash -c "bash '$CLI' hooks install --repo '$W' < /dev/null 2>&1 | grep -q 'pre-push hook: found in'"
git init -q --bare -b main "$SB/work-remote.git"; git -C "$W" remote add origin "$SB/work-remote.git"
kit save "$W" >/dev/null 2>&1
git init -q --bare -b main "$SB/docs-remote.git"; git -C "$D" remote add origin "$SB/docs-remote.git"; git -C "$D" push -q -u origin main
before="$(commits)"
echo "husky" > "$W/aidlc-docs/requirements.md"
PATH="$SB/bin:$PATH" git -C "$W" commit -q --allow-empty -m "husky commit" 2>/dev/null
check "post-commit via husky commits the docs" wait_until commits_above "$before"
wait_until test ! -e "$(git -C "$D" rev-parse --absolute-git-dir)/aidlc-kit.lock"
PATH="$SB/bin:$PATH" git -C "$W" push -q origin main 2>/dev/null
check "pre-push via husky pushes the docs repo" test "$(git -C "$SB/docs-remote.git" rev-parse main)" = "$(git -C "$D" rev-parse HEAD)"
before="$(git -C "$SB/docs-remote.git" rev-parse main)"
{ echo 'false'; cat "$W/.husky/pre-push"; } > "$SB/pp" && mv "$SB/pp" "$W/.husky/pre-push"
echo "husky fail" > "$W/aidlc-docs/requirements.md"; kit save "$W" >/dev/null 2>&1
git -C "$W" commit -q --allow-empty -m "second" 2>/dev/null
PATH="$SB/bin:$PATH" git -C "$W" push -q origin main 2>/dev/null
check "a failing husky check: docs not pushed" test "$(git -C "$SB/docs-remote.git" rev-parse main)" = "$before"
# shellcheck disable=SC2016  # $1 belongs to the inner shell
check "without aidlc-kit on PATH the line does nothing (and doesn't fail the hook)" \
  bash -c 'cd "$1" && PATH=/usr/bin:/bin sh -e .husky/post-commit 2>/dev/null' _ "$W"
check "hooks uninstall says to remove the line" bash -c "bash '$CLI' hooks uninstall --repo '$W' < /dev/null 2>&1 | grep -q 'remove that line yourself'"
sed -i.bak 's/^if command -v aidlc-kit/# if command -v aidlc-kit/' "$W/.husky/pre-push" && rm -f "$W/.husky/pre-push.bak"
check_not "a commented-out line doesn't count as installed" kit doctor "$W"
new_sandbox
export AIDLC_HOOKS=git
git -C "$W" config core.hooksPath .husky/_
kit init "$W" --docs-repo "$D" --profile aidlc-v1 --profile graphify --no-hooks --yes >/dev/null 2>&1
kit doctor "$W" >/dev/null 2>&1
kit detach "$W" --yes >/dev/null 2>&1
check "doctor and detach don't create a missing in-tree hooks folder" test ! -e "$W/.husky"

echo "Claude Code settings merge"
for tool in $JSON_TOOLS; do
  new_sandbox
  export AIDLC_HOOKS=claude AIDLC_KIT_JSON_TOOL="$tool"
  mkdir -p "$W/.claude"
  cat > "$(settings)" <<'JSON'
{
  "permissions": { "allow": ["Bash(npm test)"] },
  "hooks": {
    "Stop": [ { "hooks": [ { "type": "command", "command": "echo mine" } ] } ],
    "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "echo pre" } ] } ]
  }
}
JSON
  kit init "$W" --docs-repo "$D" --profile aidlc-v1 --yes >/dev/null 2>&1
  check "[$tool] our hooks added" grep -q "hook session-start" "$(settings)"
  check "[$tool] user's permissions kept" grep -q 'Bash(npm test)' "$(settings)"
  check "[$tool] user's own Stop hook kept" grep -q 'echo mine' "$(settings)"
  check "[$tool] user's PreToolUse hook kept" grep -q 'echo pre' "$(settings)"
  kit hooks install "$W" >/dev/null 2>&1
  check "[$tool] re-install doesn't duplicate" bash -c "[ \$(grep -c 'hook stop' '$(settings)') -eq 1 ]"
  kit hooks uninstall "$W" >/dev/null 2>&1
  check "[$tool] uninstall removes only ours" bash -c "! grep -q 'aidlc-kit' '$(settings)' && grep -q 'echo mine' '$(settings)' && grep -q 'Bash(npm test)' '$(settings)'"
  unset AIDLC_KIT_JSON_TOOL
done
[ -n "$JSON_TOOLS" ] || ok "settings merge (skipped: no jq/python here)"
new_sandbox
export AIDLC_HOOKS=claude AIDLC_KIT_JSON_TOOL=none
mkdir -p "$W/.claude"; echo '{"permissions": {}}' > "$(settings)"
kit init "$W" --docs-repo "$D" --profile aidlc-v1 --yes > "$SB/out" 2>&1
check "no JSON tool: existing settings left untouched" bash -c "[ \"\$(cat '$(settings)')\" = '{\"permissions\": {}}' ]"
check "...and the snippet to add is printed" grep -q '"SessionStart"' "$SB/out"
unset AIDLC_KIT_JSON_TOOL

echo "Claude Code hooks run"
setup_hooked
echo "from claude" >> "$W/aidlc-docs/requirements.md"
cmd="$(claude_cmd stop)"
check "Stop command can be read from settings" test -n "$cmd"
before="$(commits)"
check "Stop hook exits 0" bash -c "cd '$SB' && CLAUDE_PROJECT_DIR='$W' $cmd < /dev/null"
check "...and committed the change" test "$(commits)" -gt "$before"
check "...labelled with the trigger" bash -c "git -C '$D' log -1 --format=%s | grep -q '(stop)$'"
rm -f "$W/aidlc-docs" 2>/dev/null || rmdir "$W/aidlc-docs"
out="$(cd "$SB" && CLAUDE_PROJECT_DIR="$W" bash -c "$(claude_cmd session-start)" < /dev/null)"
check "SessionStart repairs a missing link" is_link "$W/aidlc-docs"
check "SessionStart prints nothing when all is well (it becomes Claude's context)" test -z "$out"
git -C "$W" config core.hooksPath "$SB/nowhere-hooks"     # make the git hooks 'missing'
out="$(cd "$SB" && CLAUDE_PROJECT_DIR="$W" bash -c "$(claude_cmd session-start)" < /dev/null)"
check "SessionStart reports problems to Claude, one line each" bash -c "printf '%s\n' \"$out\" | grep -q '^aidlc-kit: git post-commit hook not installed'"
git -C "$W" config --unset core.hooksPath
check "SessionEnd hook exits 0" bash -c "cd '$SB' && CLAUDE_PROJECT_DIR='$W' $(claude_cmd session-end) < /dev/null"

echo "hook runner never fails"
setup_hooked
mv "$D" "$SB/moved-docs"
check "hook exits 0 even when the docs repo is gone" kit hook stop --repo "$W"
check "...and logs why" grep -q "not found" "$W/.git/aidlc-kit/log"
mv "$SB/moved-docs" "$D"
check "hook in a repo that isn't set up: silent exit 0" bash -c "[ -z \"\$(bash '$CLI' hook stop --repo '$SB/home' 2>&1 < /dev/null)\" ]"
check "unknown event: exit 0" kit hook bogus --repo "$W"
AIDLC_HOOKS=git kit hook stop --repo "$W" >/dev/null 2>&1
check "a disabled event does nothing" bash -c "tail -n 3 '$W/.git/aidlc-kit/log' | grep -q 'stop exit=0'"

echo "AIDLC_AUTO_COMMIT / AIDLC_AUTO_PUSH"
setup_hooked
export AIDLC_KIT_SIMULATE_NO_LINKS=1
new_sandbox; export AIDLC_HOOKS=all AIDLC_KIT_SIMULATE_NO_LINKS=1
kit init "$W" --docs-repo "$D" --profile aidlc-v1 --yes >/dev/null 2>&1
kit save "$W" >/dev/null 2>&1
echo "copy edit" > "$W/aidlc-docs/requirements.md"
before="$(commits)"
AIDLC_AUTO_COMMIT=off kit hook stop --repo "$W"
check "AUTO_COMMIT=off still syncs copy-mode files" grep -qx "copy edit" "$D/app/aidlc-docs/requirements.md"
check "...but doesn't commit" test "$(commits)" = "$before"
unset AIDLC_KIT_SIMULATE_NO_LINKS
git init -q --bare -b main "$SB/docs-remote.git"; git -C "$D" remote add origin "$SB/docs-remote.git"; git -C "$D" push -q -u origin main
echo "push me" > "$W/aidlc-docs/requirements.md"
AIDLC_AUTO_PUSH=off kit hook pre-push --repo "$W"
check "AUTO_PUSH=off: pre-push commits" bash -c "git -C '$D' log -1 --format=%s | grep -q '(pre-push)$'"
check "...but doesn't push" test "$(git -C "$SB/docs-remote.git" rev-parse main)" != "$(git -C "$D" rev-parse HEAD)"

echo "doctor"
setup_hooked
rm -f "$(hooks_dir)/pre-push"
check_not "doctor fails when a hook is missing" kit doctor "$W"
check "...and says how to fix it" bash -c "bash '$CLI' doctor '$W' | grep -q 'pre-push hook not installed.*hooks install'"
kit hooks install "$W" >/dev/null 2>&1
check "hooks install fixes it" kit doctor "$W"
check "doctor warns about a docs repo without upstream" bash -c "bash '$CLI' doctor '$W' | grep -q 'WARN.*no upstream'"
git -C "$D" config --unset user.email
check_not "doctor fails without a docs-repo identity (hook commits would fail)" kit doctor "$W"

echo "adopt"
setup_hooked
mkdir -p "$W/graphify-out"; echo g > "$W/graphify-out/g.html"
check "status suggests adopt for an unmanaged artifact" bash -c "bash '$CLI' status '$W' | grep -q 'aidlc-kit adopt graphify-out/'"
check "adopt (from inside the repo)" bash -c "cd '$W' && bash '$CLI' adopt graphify-out/ --yes < /dev/null"
check "adopted path is linked" is_link "$W/graphify-out"
check "...stored in the docs repo" test -f "$D/app/graphify-out/g.html"
check "...and recorded" grep -qx "path=graphify-out/|dir" "$D/app/.aidlc-kit/record"
check "adopt with --repo from elsewhere" bash -c "mkdir -p '$W/notes' && echo n > '$W/notes/n.md' && cd '$SB' && bash '$CLI' adopt notes/ --repo '$W' --yes < /dev/null && test -L '$W/notes'"
check_not "adopt without paths fails" kit adopt --repo "$W"
check_not "adopt in a repo that isn't set up fails" bash -c "cd '$SB/home' && bash '$CLI' adopt x/ --yes < /dev/null"

echo "review regressions"
# a copy that fails is never recorded, so it can't later overwrite the user's edit
new_sandbox
export AIDLC_HOOKS=claude AIDLC_KIT_SIMULATE_NO_LINKS=1
rm -rf "$W/graphify-out" "$W/graph.json"
kit init "$W" --docs-repo "$D" --yes >/dev/null 2>&1
kit save "$W" >/dev/null 2>&1
chmod a-w "$D/app/aidlc-docs/requirements.md"
if ! (echo probe >> "$D/app/aidlc-docs/requirements.md") 2>/dev/null; then
  echo "my edit" > "$W/aidlc-docs/requirements.md"
  kit hook stop --repo "$W"
  check "failed copy: the user's edit is intact" grep -qx "my edit" "$W/aidlc-docs/requirements.md"
  check "failed copy: logged as a retry, not a success" grep -q "couldn't copy 'aidlc-docs/requirements.md'" "$W/.git/aidlc-kit/log"
  chmod u+w "$D/app/aidlc-docs/requirements.md"
  bash "$CLI" save "$W" < /dev/null >/dev/null 2>&1
  check "next save copies the edit instead of overwriting it" grep -qx "my edit" "$D/app/aidlc-docs/requirements.md"
  check "...and the user's file is still their edit" grep -qx "my edit" "$W/aidlc-docs/requirements.md"
else
  chmod u+w "$D/app/aidlc-docs/requirements.md"
  ok "failed-copy test (skipped: read-only files are writable here, e.g. running as root)"
fi
unset AIDLC_KIT_SIMULATE_NO_LINKS

# non-shell hooks are never edited
new_sandbox
export AIDLC_HOOKS=git
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n' > "$W/.git/hooks/pre-push"; chmod +x "$W/.git/hooks/pre-push"
cp "$W/.git/hooks/pre-push" "$SB/pre-push.orig"
kit init "$W" --docs-repo "$D" --profile aidlc-v1 --yes > "$SB/out" 2>&1
check "a Python pre-push hook is left byte-identical" cmp -s "$SB/pre-push.orig" "$W/.git/hooks/pre-push"
check "...and the command to call is printed" grep -q "not a shell script" "$SB/out"
check "a missing post-commit hook is still created" test -x "$W/.git/hooks/post-commit"
printf '#!/usr/bin/env bash -e\necho hi\n' > "$W/.git/hooks/pre-push"
kit hooks install "$W" >/dev/null 2>&1
check "an 'env bash -e' hook counts as shell and is edited" grep -q "aidlc-workspace-kit >>>" "$W/.git/hooks/pre-push"

# a tracked settings.local.json is never edited
new_sandbox
export AIDLC_HOOKS=claude
mkdir -p "$W/.claude"; echo '{"permissions": {}}' > "$(settings)"
git -C "$W" add -f .claude/settings.local.json && git -C "$W" commit -qm "team settings"
kit init "$W" --docs-repo "$D" --profile aidlc-v1 --yes > "$SB/out" 2>&1
check "tracked settings.local.json is untouched" bash -c "[ -z \"\$(git -C '$W' status --porcelain -- .claude)\" ]"
check "...and the snippet is printed instead" grep -q "tracked by git" "$SB/out"

# pre-push: docs are pushed only if the user's own pre-push checks pass
for verdict in fail pass; do
  new_sandbox
  export AIDLC_HOOKS=git
  if [ "$verdict" = fail ]; then rc=1; else rc=0; fi
  printf '#!/bin/sh\necho checks >&2\nexit %s\necho unreachable\n' "$rc" > "$W/.git/hooks/pre-push"; chmod +x "$W/.git/hooks/pre-push"
  kit init "$W" --docs-repo "$D" --profile aidlc-v1 --yes >/dev/null 2>&1
  kit save "$W" >/dev/null 2>&1
  git init -q --bare -b main "$SB/work-remote.git"; git -C "$W" remote add origin "$SB/work-remote.git"
  git init -q --bare -b main "$SB/docs-remote.git"; git -C "$D" remote add origin "$SB/docs-remote.git"; git -C "$D" push -q -u origin main
  echo "$verdict" >> "$W/aidlc-docs/requirements.md"
  git -C "$W" push -q -u origin main >/dev/null 2>&1
  if [ "$verdict" = fail ]; then
    check "user's pre-push check fails -> docs not pushed" bash -c "! git -C '$SB/docs-remote.git' show main:app/aidlc-docs/requirements.md | grep -qx fail"
  else
    check "user's pre-push hook ends with exit 0 -> docs still pushed" bash -c "git -C '$SB/docs-remote.git' show main:app/aidlc-docs/requirements.md | grep -qx pass"
  fi
done

# pre-commit's generated hook (pre-commit 4.x hook-tmpl, verbatim) ends in
# `exec pre-commit ...`: an EXIT trap would never run after that
for verdict in fail pass; do
  new_sandbox
  export AIDLC_HOOKS=git
  if [ "$verdict" = fail ]; then rc=1; else rc=0; fi
  mkdir -p "$SB/bin"
  # a stand-in pre-commit: records the refs git sends on stdin, passes or fails
  printf '#!/bin/sh\ncat > "%s/refs-seen"\nexit %s\n' "$SB" "$rc" > "$SB/bin/pre-commit"; chmod +x "$SB/bin/pre-commit"
  # shellcheck disable=SC2016  # the template's own $vars
  printf '%s\n' '#!/usr/bin/env bash' '# File generated by pre-commit: https://pre-commit.com' \
    '# ID: 138fd403232d2ddd5efb44317e38bf03' '' '# start templated' "INSTALL_PYTHON=''" \
    'ARGS=(hook-impl --config=.pre-commit-config.yaml --hook-type=pre-push)' '# end templated' '' \
    'HERE="$(cd "$(dirname "$0")" && pwd)"' 'ARGS+=(--hook-dir "$HERE" -- "$@")' '' \
    'if [ -x "$INSTALL_PYTHON" ]; then' '    exec "$INSTALL_PYTHON" -mpre_commit "${ARGS[@]}"' \
    'elif command -v pre-commit > /dev/null; then' '    exec pre-commit "${ARGS[@]}"' 'else' \
    "    echo '\`pre-commit\` not found.  Did you forget to activate your virtualenv?' 1>&2" \
    '    exit 1' 'fi' > "$W/.git/hooks/pre-push"
  chmod +x "$W/.git/hooks/pre-push"
  kit init "$W" --docs-repo "$D" --profile aidlc-v1 --yes >/dev/null 2>&1
  kit save "$W" >/dev/null 2>&1
  git init -q --bare -b main "$SB/work-remote.git"; git -C "$W" remote add origin "$SB/work-remote.git"
  git init -q --bare -b main "$SB/docs-remote.git"; git -C "$D" remote add origin "$SB/docs-remote.git"; git -C "$D" push -q -u origin main
  echo "$verdict" >> "$W/aidlc-docs/requirements.md"
  PATH="$SB/bin:$PATH" git -C "$W" push -q -u origin main >/dev/null 2>&1
  if [ "$verdict" = fail ]; then
    check "pre-commit-managed pre-push fails -> docs not pushed" bash -c "! git -C '$SB/docs-remote.git' show main:app/aidlc-docs/requirements.md | grep -qx fail"
  else
    check "pre-commit-managed pre-push passes -> docs pushed (despite its exec)" bash -c "git -C '$SB/docs-remote.git' show main:app/aidlc-docs/requirements.md | grep -qx pass"
    check "...and pre-commit still got the refs on stdin" grep -q "refs/heads/main" "$SB/refs-seen"
  fi
done

# post-commit is skipped while the working repo replays commits
setup_hooked
mkdir -p "$W/.git/rebase-merge"
echo "during rebase" >> "$W/aidlc-docs/requirements.md"
before="$(commits)"
kit hook post-commit --repo "$W"
check "post-commit during a rebase does nothing" test "$(commits)" = "$before"
check "...and says why in the log" grep -q "skipped: rebase" "$W/.git/aidlc-kit/log"
rmdir "$W/.git/rebase-merge"

# SessionStart still reports problems when the lock is busy
setup_hooked
gd="$(git -C "$D" rev-parse --absolute-git-dir)"
mkdir "$gd/aidlc-kit.lock"; echo $$ > "$gd/aidlc-kit.lock/pid"
rm -f "$(hooks_dir)/pre-push"
out="$(cd "$SB" && AIDLC_KIT_LOCK_TRIES=1 CLAUDE_PROJECT_DIR="$W" bash -c "$(claude_cmd session-start)" < /dev/null)"
check "SessionStart with a busy lock still reports problems" bash -c "printf '%s\n' \"$out\" | grep -q 'pre-push hook not installed'"
rm -rf "$gd/aidlc-kit.lock"

# SessionStart reports copy-mode conflicts (reusing its own sync's results)
new_sandbox
export AIDLC_HOOKS=all AIDLC_KIT_SIMULATE_NO_LINKS=1
rm -rf "$W/graphify-out" "$W/graph.json"
kit init "$W" --docs-repo "$D" --yes >/dev/null 2>&1
echo "work" > "$W/aidlc-docs/requirements.md"; echo "docs" > "$D/app/aidlc-docs/requirements.md"
out="$(cd "$SB" && CLAUDE_PROJECT_DIR="$W" bash -c "$(claude_cmd session-start)" < /dev/null)"
check "SessionStart reports a copy-mode conflict" bash -c "printf '%s\n' \"$out\" | grep -q 'CONFLICT'"
unset AIDLC_KIT_SIMULATE_NO_LINKS

# hooks left by an older kit version are reported as outdated
setup_hooked
sed -i.bak 's/ --hook-format [0-9]*//' "$(settings)" && rm -f "$(settings).bak"
check_not "doctor flags an outdated Claude hook" kit doctor "$W"
kit hooks install "$W" >/dev/null 2>&1
check "hooks install refreshes it" kit doctor "$W"

echo "settings validation"
new_sandbox
check_not "a bad AIDLC_HOOKS value is rejected" env AIDLC_HOOKS=stop,bogus bash "$CLI" init "$W" --docs-repo "$D" --yes
check "...before anything was moved" test -d "$W/aidlc-docs" -a ! -L "$W/aidlc-docs"

echo "detach removes hooks"
setup_hooked
kit detach "$W" --yes >/dev/null 2>&1
check "git hooks removed" bash -c "test ! -e '$(hooks_dir)/post-commit' && test ! -e '$(hooks_dir)/pre-push'"
check "Claude hooks removed" bash -c "test ! -e '$(settings)' || ! grep -q aidlc-kit '$(settings)'"

summary
