#!/usr/bin/env bash
# Tests for milestone 2: aidlc-kit save (commit, lock, push, copy-mode sync).
# Run: bash tests/save.sh
set -uo pipefail

# shellcheck source=helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

commits() { git -C "$D" rev-list --count HEAD 2>/dev/null || echo 0; }
last_msg() { git -C "$D" log -1 --format=%s; }
last_files() { git -C "$D" show --name-only --format= HEAD; }

# init + one save, docs repo has a commit
setup_saved() {
  new_sandbox
  kit init "$W" --docs-repo "$D" --yes >/dev/null 2>&1
  kit save "$W" >/dev/null 2>&1
}

# bare remote as the docs repo's upstream
add_remote() {
  git init -q --bare -b main "$SB/remote.git"
  git -C "$D" remote add origin "$SB/remote.git"
  git -C "$D" push -q -u origin main
}

echo "save: commit"
new_sandbox
kit init "$W" --docs-repo "$D" --yes >/dev/null 2>&1
check "save commits" kit save "$W"
check "message names project, branch and working-repo commit" bash -c "git -C '$D' log -1 --format=%s | grep -qx \"app: AI artifacts @ main \$(git -C '$W' rev-parse --short HEAD) (manual)\""
check "commit contains the project's artifacts" bash -c "git -C '$D' show --name-only --format= HEAD | grep -qx 'app/aidlc-docs/requirements.md'"
check "commit contains the record" bash -c "git -C '$D' show --name-only --format= HEAD | grep -qx 'app/.aidlc-kit/record'"
before="$(commits)"
check "save with no changes succeeds" kit save "$W"
check "...and makes no commit" test "$(commits)" = "$before"

echo "change" >> "$W/aidlc-docs/requirements.md"
mkdir -p "$D/other"; echo x > "$D/other/untracked.md"; echo y > "$D/other/staged.md"
git -C "$D" add other/staged.md
check "save with --trigger" kit save "$W" --trigger post-commit
check "trigger shown in the message" bash -c "git -C '$D' log -1 --format=%s | grep -q '(post-commit)$'"
check "other projects' files are not committed" bash -c "! git -C '$D' show --name-only --format= HEAD | grep -q '^other/'"
check "the user's staged file stays staged" bash -c "git -C '$D' diff --cached --name-only | grep -qx other/staged.md"
check "untracked files elsewhere stay untracked" bash -c "git -C '$D' status --porcelain -- other | grep -q '^?? other/untracked.md'"

echo "more" >> "$W/aidlc-docs/requirements.md"
check "custom --message" kit save "$W" -m "my message"
check "custom message used" test "$(last_msg)" = "my message"

echo "dry" >> "$W/aidlc-docs/requirements.md"
before="$(commits)"
check "dry run" kit save "$W" --dry-run
check "dry run makes no commit" test "$(commits)" = "$before"

check_not "--push is rejected outside save" kit status "$W" --push
check_not "save outside a set-up repo fails" bash "$CLI" save "$SB/home" < /dev/null

echo "save: special docs-repo states"
setup_saved
gd="$(git -C "$D" rev-parse --absolute-git-dir)"
git -C "$D" rev-parse HEAD > "$gd/MERGE_HEAD"
echo "x" >> "$W/aidlc-docs/requirements.md"
before="$(commits)"
check "save during a merge exits 0" kit save "$W"
check "...with a warning" bash -c "bash '$CLI' save '$W' 2>&1 | grep -q 'middle of a merge'"
check "...and no commit" test "$(commits)" = "$before"
rm -f "$gd/MERGE_HEAD"

new_sandbox
mkdir -p "$SB/plain docs"
kit init "$W" --docs-repo "$SB/plain docs" --yes >/dev/null 2>&1
check "save with a non-git docs repo exits 0" kit save "$W"
check "...and says why nothing was committed" bash -c "bash '$CLI' save '$W' 2>&1 | grep -q 'not a git repo'"

echo "lock"
setup_saved
gd="$(git -C "$D" rev-parse --absolute-git-dir)"
check "no lock left behind after save" test ! -e "$gd/aidlc-kit.lock"
mkdir "$gd/aidlc-kit.lock"; echo $$ > "$gd/aidlc-kit.lock/pid"
echo "x" >> "$W/aidlc-docs/requirements.md"
before="$(commits)"
check "save skips while another live process holds the lock" bash -c "AIDLC_KIT_LOCK_TRIES=2 bash '$CLI' save '$W' < /dev/null | grep -q 'skipping'"
check "...without committing" test "$(commits)" = "$before"
check_not "init refuses while the lock is held" env AIDLC_KIT_LOCK_TRIES=2 bash "$CLI" init "$W" --yes
check "the other process's lock is untouched" test -f "$gd/aidlc-kit.lock/pid"
echo 999999 > "$gd/aidlc-kit.lock/pid"
check "a stale lock (dead pid) is cleared" kit save "$W"
check "...and the save went through" test "$(commits)" -gt "$before"
check "...and the lock is released" test ! -e "$gd/aidlc-kit.lock"

echo "push"
setup_saved
echo "x" >> "$W/aidlc-docs/requirements.md"
check_not "--push without an upstream fails" kit save "$W" --push
check "...and explains how to set one" bash -c "bash '$CLI' save '$W' --push 2>&1 | grep -q 'no upstream'"
check "...but the commit was still made" bash -c "git -C '$D' log -1 --format=%s | grep -q '^app: AI artifacts'"

add_remote
echo "y" >> "$W/aidlc-docs/requirements.md"
check "save --push with an upstream" kit save "$W" --push
check "remote has the commit" test "$(git -C "$SB/remote.git" rev-parse main)" = "$(git -C "$D" rev-parse HEAD)"

git clone -q "$SB/remote.git" "$SB/other-machine"
git -C "$SB/other-machine" config user.email o@example.com; git -C "$SB/other-machine" config user.name o
mkdir -p "$SB/other-machine/other"; echo o > "$SB/other-machine/other/o.md"
git -C "$SB/other-machine" add -A; git -C "$SB/other-machine" commit -qm "other project"; git -C "$SB/other-machine" push -q
echo "z" >> "$W/aidlc-docs/requirements.md"
check "save --push when the remote is ahead (rebases, then pushes)" kit save "$W" --push
check "remote has both commits" bash -c "git -C '$SB/remote.git' log --format=%s main | grep -q 'other project' && git -C '$SB/remote.git' log -1 --format=%s main | grep -q '^app: AI artifacts'"

git -C "$SB/other-machine" pull -q
echo "theirs" > "$SB/other-machine/app/aidlc-docs/requirements.md"
git -C "$SB/other-machine" commit -qam "conflicting edit"; git -C "$SB/other-machine" push -q
echo "mine" > "$W/aidlc-docs/requirements.md"
check_not "conflicting push fails" kit save "$W" --push
check "...without leaving the docs repo mid-rebase" bash -c "gd=\$(git -C '$D' rev-parse --absolute-git-dir); test ! -d \"\$gd/rebase-merge\" && test ! -d \"\$gd/rebase-apply\""
check "...keeping the local commit" bash -c "git -C '$D' show HEAD:app/aidlc-docs/requirements.md | grep -qx mine"

echo "copy-mode sync"
new_sandbox
export AIDLC_KIT_SIMULATE_NO_LINKS=1
kit init "$W" --docs-repo "$D" --yes >/dev/null 2>&1
check "copy mode in use" bash -c "test ! -L '$W/aidlc-docs' && grep -q 'mode=aidlc-docs/|copy' '$W/.git/aidlc-kit/state'"
check "manifest written at init" test -s "$W/.git/aidlc-kit/manifest"
kit save "$W" >/dev/null 2>&1
check "status is in sync" bash -c "bash '$CLI' status '$W' | grep -q 'aidlc-docs/.*in sync'"

echo "edited" > "$W/aidlc-docs/requirements.md"
echo "new" > "$W/aidlc-docs/new file.md"
rm "$W/aidlc-docs/inception/plan.md"
check "status shows pending changes" bash -c "bash '$CLI' status '$W' | grep -q 'aidlc-docs/.*3 change(s) to sync'"
check "dry-run save" kit save "$W" -n
check "dry run copied nothing" test ! -e "$D/app/aidlc-docs/new file.md"
check "save syncs working -> docs" kit save "$W"
check "edit reached the docs repo" grep -qx edited "$D/app/aidlc-docs/requirements.md"
check "new file (with a space) reached the docs repo" test -f "$D/app/aidlc-docs/new file.md"
check "deletion reached the docs repo" test ! -e "$D/app/aidlc-docs/inception/plan.md"
check "emptied folder tidied" test ! -d "$D/app/aidlc-docs/inception"
check "and was committed" bash -c "git -C '$D' show HEAD:'app/aidlc-docs/new file.md' | grep -qx new"

echo "from another machine" > "$D/app/aidlc-docs/requirements.md"
rm "$D/app/aidlc-docs/new file.md"
check "save syncs docs -> working" kit save "$W"
check "docs edit reached the working repo" grep -qx "from another machine" "$W/aidlc-docs/requirements.md"
check "docs deletion reached the working repo" test ! -e "$W/aidlc-docs/new file.md"

echo "work side" > "$W/aidlc-docs/requirements.md"
echo "docs side" > "$D/app/aidlc-docs/requirements.md"
LAST_OUT=""
bash "$CLI" save "$W" < /dev/null > "$SB/out" 2>&1; rc=$?
check "conflict: save exits 2" test "$rc" = 2
check "conflict: explained" grep -q "changed in both" "$SB/out"
check "conflict: working copy untouched" grep -qx "work side" "$W/aidlc-docs/requirements.md"
check "conflict: docs copy untouched" grep -qx "docs side" "$D/app/aidlc-docs/requirements.md"
check_not "conflict: status fails" kit status "$W"
check "conflict: status names it" bash -c "bash '$CLI' status '$W' | grep -q 'CONFLICT'"
cp "$W/aidlc-docs/requirements.md" "$D/app/aidlc-docs/requirements.md"
check "resolved conflict: save succeeds" kit save "$W"
check "resolved conflict: status clean" kit status "$W"

echo "copy mode on a fresh clone"
git -C "$W" add .gitignore && git -C "$W" commit -qm "ignore artifacts"
git clone -q "$W" "$SB/my work/clone"
C="$SB/my work/clone"
check "attach in copy mode" kit attach "$C" --docs-repo "$D" --name app
check "clone received the docs" grep -qx "work side" "$C/aidlc-docs/requirements.md"
echo "from clone" > "$C/aidlc-docs/clone.md"
check "save from the clone" kit save "$C"
check "clone's file reached the docs repo" test -f "$D/app/aidlc-docs/clone.md"
check "first working copy picks it up on its next save" bash -c "bash '$CLI' save '$W' < /dev/null >/dev/null 2>&1; test -f '$W/aidlc-docs/clone.md'"

echo "copy mode: a missing folder is restored, never mass-deleted"
new_sandbox
export AIDLC_KIT_SIMULATE_NO_LINKS=1
kit init "$W" --docs-repo "$D" --yes >/dev/null 2>&1
kit save "$W" >/dev/null 2>&1
git -C "$W" add .gitignore && git -C "$W" commit -qm "ignore artifacts"
git -C "$W" clean -fdxq      # removes the ignored copies, as people do
check "git clean removed the working copy" test ! -e "$W/aidlc-docs"
before="$(commits)"
check "save after git clean" kit save "$W"
check "docs repo still has everything" test -f "$D/app/aidlc-docs/inception/plan.md"
check "nothing was committed as deleted" test "$(commits)" = "$before"
check "working copy restored from the docs repo" grep -qx plan "$W/aidlc-docs/inception/plan.md"
check "a single managed file (graph.json) is restored too" test -f "$W/graph.json" -a -f "$D/app/graph.json"
echo k > "$W/aidlc-docs/keep.md"; mkdir -p "$W/aidlc-docs/placeholder"
kit save "$W" >/dev/null 2>&1
rm "$W/aidlc-docs/requirements.md" "$W/aidlc-docs/inception/plan.md"
check "deleting files inside a non-empty folder still syncs" bash -c "bash '$CLI' save '$W' < /dev/null >/dev/null 2>&1; test ! -e '$D/app/aidlc-docs/requirements.md' && test ! -e '$D/app/aidlc-docs/inception/plan.md'"
check "the folder emptied by that deletion is removed" test ! -e "$D/app/aidlc-docs/inception"
check "a placeholder folder the tool created is kept" test -d "$W/aidlc-docs/placeholder"
rm -f "$W/aidlc-docs/"*.md
before="$(commits)"
check "save after a tool emptied the folder" kit save "$W"
check "emptied folder: docs repo keeps its files" test -f "$D/app/aidlc-docs/keep.md"
check "emptied folder: working side restored" test -f "$W/aidlc-docs/keep.md"
check "emptied folder: nothing committed" test "$(commits)" = "$before"
unset AIDLC_KIT_SIMULATE_NO_LINKS

echo "link mode: save recreates links removed by git clean"
new_sandbox
kit init "$W" --docs-repo "$D" --profile aidlc-v1 --yes >/dev/null 2>&1
kit save "$W" >/dev/null 2>&1
git -C "$W" add .gitignore && git -C "$W" commit -qm "ignore artifacts"
git -C "$W" clean -fdxq
check "git clean removed the link only" bash -c "test ! -e '$W/aidlc-docs' && test -f '$D/app/aidlc-docs/requirements.md'"
before="$(commits)"
check "save after git clean (link mode)" kit save "$W"
check "link recreated" bash -c "test -L '$W/aidlc-docs' && grep -qx req '$W/aidlc-docs/requirements.md'"
check "no commit" test "$(commits)" = "$before"
# the recreated link's type is written back to the machine state
real_mode="$(grep '^mode=aidlc-docs/|' "$W/.git/aidlc-kit/state")"
other="junction"; [ "$real_mode" = "mode=aidlc-docs/|junction" ] && other="symlink"
sed -i.bak "s/^mode=aidlc-docs\/|.*/mode=aidlc-docs\/|$other/" "$W/.git/aidlc-kit/state" && rm -f "$W/.git/aidlc-kit/state.bak"
git -C "$W" clean -fdxq
kit save "$W" >/dev/null 2>&1
check "repaired link's mode recorded in the state" bash -c "! grep -qx 'mode=aidlc-docs/|$other' '$W/.git/aidlc-kit/state' && grep -q '^mode=aidlc-docs/|' '$W/.git/aidlc-kit/state'"

echo "lock: stale-lock breaking"
setup_saved
gd="$(git -C "$D" rev-parse --absolute-git-dir)"
mkdir "$gd/aidlc-kit.lock"; echo 999999 > "$gd/aidlc-kit.lock/pid"
mkdir "$gd/aidlc-kit.lock.break"
echo "x" >> "$W/aidlc-docs/requirements.md"
check_not "a fresh breaker means someone else is breaking the lock: wait" env AIDLC_KIT_LOCK_TRIES=2 bash "$CLI" save "$W" --push
touch -t 202001010000 "$gd/aidlc-kit.lock.break"
before="$(commits)"
check "an abandoned breaker is cleared and the stale lock broken" kit save "$W"
check "...and the save went through" test "$(commits)" -gt "$before"
check "...no breaker left" test ! -e "$gd/aidlc-kit.lock.break"

echo "push: busy lock, user's rebase, ssh prompts"
setup_saved
add_remote
gd="$(git -C "$D" rev-parse --absolute-git-dir)"
mkdir "$gd/aidlc-kit.lock"; echo $$ > "$gd/aidlc-kit.lock/pid"
echo "x" >> "$W/aidlc-docs/requirements.md"
bash -c "AIDLC_KIT_LOCK_TRIES=2 bash '$CLI' save '$W' --push" < /dev/null > "$SB/out" 2>&1; rc=$?
check "save --push with a busy lock fails instead of silently skipping" test "$rc" = 1
check "...and says it was not pushed" grep -q "NOT saved or pushed" "$SB/out"
rm -rf "$gd/aidlc-kit.lock"
kit save "$W" --push >/dev/null 2>&1

echo n1 > "$D/n1.md"; git -C "$D" add n1.md; git -C "$D" commit -qm n1
echo n2 > "$D/n2.md"; git -C "$D" add n2.md; git -C "$D" commit -qm n2
GIT_SEQUENCE_EDITOR="sed -i.bak '1s/^pick/edit/'" git -C "$D" rebase -i -q HEAD~1 >/dev/null 2>&1
check "the user is mid-rebase (setup)" test -d "$gd/rebase-merge"
echo "y" >> "$W/aidlc-docs/requirements.md"
check_not "save --push during the user's rebase does not push" kit save "$W" --push
check "...and the user's rebase is still in progress" test -d "$gd/rebase-merge"
git -C "$D" rebase --abort
# `git am` stopped part-way keeps HEAD on the branch with a clean tree, so it
# gets past the upstream and dirty checks: only the busy guard protects it
mkdir -p "$gd/rebase-apply"; echo 1 > "$gd/rebase-apply/next"; echo 1 > "$gd/rebase-apply/last"; : > "$gd/rebase-apply/applying"
check_not "save --push while the user's 'git am' is in progress does not push" kit save "$W" --push
check "...and leaves their am/rebase state alone" test -f "$gd/rebase-apply/applying"
rm -rf "$gd/rebase-apply"

mkdir -p "$SB/bin"
printf '#!/bin/sh\necho "$@" >> "%s/ssh-args"\nexit 1\n' "$SB" > "$SB/bin/ssh"; chmod +x "$SB/bin/ssh"
git -C "$D" remote set-url origin "ssh://git@example.invalid/docs.git"
echo "z" >> "$W/aidlc-docs/requirements.md"
PATH="$SB/bin:$PATH" bash "$CLI" save "$W" --push < /dev/null >/dev/null 2>&1
check "ssh runs in BatchMode (never prompts)" grep -q "BatchMode=yes" "$SB/ssh-args"
git -C "$D" config core.sshCommand "ssh -o MyOption=kept"
rm -f "$SB/ssh-args"; echo "z2" >> "$W/aidlc-docs/requirements.md"
PATH="$SB/bin:$PATH" bash "$CLI" save "$W" --push < /dev/null >/dev/null 2>&1
check "core.sshCommand is honoured alongside BatchMode" bash -c "grep -q 'MyOption=kept' '$SB/ssh-args' && grep -q 'BatchMode=yes' '$SB/ssh-args'"

echo "push leaves the user's own docs-repo work alone"
setup_saved
add_remote
mkdir -p "$D/notes"; echo n > "$D/notes/n.md"; git -C "$D" add notes/n.md; git -C "$D" commit -qm notes
echo "edited by me" > "$D/notes/n.md"; git -C "$D" add notes/n.md
echo "x" >> "$W/aidlc-docs/requirements.md"
check_not "save --push refuses with other uncommitted changes" kit save "$W" --push
check "...says why" bash -c "bash '$CLI' save '$W' --push 2>&1 | grep -q 'uncommitted changes outside app/'"
check "...the user's change is still staged" bash -c "git -C '$D' diff --cached --name-only | grep -qx notes/n.md"
check "...and its content untouched" grep -qx "edited by me" "$D/notes/n.md"
check "...our commit was still made locally" bash -c "git -C '$D' log -1 --format=%s | grep -q '^app: AI artifacts'"
git -C "$D" commit -qm "my notes"
git -C "$D" remote set-url origin "$SB/nowhere.git"
check "a failing push reports git's own message" bash -c "bash '$CLI' save '$W' --push 2>&1 | grep -q 'git said:'"

echo "the user's own ignore patterns don't untrack anything"
new_sandbox
echo "first" > "$W/aidlc-docs/run.log"
kit init "$W" --docs-repo "$D" --profile aidlc-v1 --yes >/dev/null 2>&1
kit save "$W" >/dev/null 2>&1
echo '*.log' > "$HOME/global-ignore"; git config --global core.excludesFile "$HOME/global-ignore"
echo "*.log" >> "$(git -C "$D" rev-parse --absolute-git-dir)/info/exclude"
echo "second" > "$W/aidlc-docs/run.log"
check "save" kit save "$W"
check "a file matching a global / info/exclude pattern stays tracked and committed"   bash -c "git -C '$D' show HEAD:app/aidlc-docs/run.log | grep -qx second"

echo "leftovers of a save killed mid-commit"
new_sandbox
kit init "$W" --docs-repo "$D" --profile aidlc-v1 --yes >/dev/null 2>&1
kit save "$W" >/dev/null 2>&1
ix="$(git -C "$D" rev-parse --absolute-git-dir)/index.aidlc-kit"
echo junk > "$ix"; echo junk > "$ix.lock"
echo "after a kill" > "$W/aidlc-docs/requirements.md"
check "a stale private index and its lock don't block the next save" kit save "$W"
check "...which commits" bash -c "git -C '$D' show HEAD:app/aidlc-docs/requirements.md | grep -qx 'after a kill'"
check "...and cleans them up" bash -c "[ ! -e '$ix' ] && [ ! -e '$ix.lock' ]"

summary
