# shellcheck shell=bash disable=SC2034,SC2153,SC2317
# (file-wide: globals and functions here are used by the files that source this one)
# save: copy-mode sync, commit to the docs repo, push. See docs/DESIGN.md §9.

# ---- temp dir + lock, released by cleanup() (trap set in bin/aidlc-kit) -----

KIT_TMP=""
LOCK_DIR=""

kit_tmp() { # -> path of a private temp dir (created once)
  if [ -z "$KIT_TMP" ]; then KIT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/aidlc-kit.XXXXXX")"; fi
  echo "$KIT_TMP"
}

cleanup() {
  release_lock
  if [ -n "$KIT_TMP" ]; then rm -rf -- "$KIT_TMP"; KIT_TMP=""; fi
}

docs_git_dir() { git -C "$DOCS" rev-parse --absolute-git-dir 2>/dev/null; }

# acquire_lock [TRIES] -> 0 when held, 1 when another aidlc-kit process holds
# it. mkdir is atomic everywhere (including Git Bash), so it is the lock. The
# holder's pid lets a later caller clear a lock left by a crashed process.
# Each try waits 0.25 s; default 20 tries (AIDLC_KIT_LOCK_TRIES overrides).
acquire_lock() {
  local base tries=0 max="${AIDLC_KIT_LOCK_TRIES:-${1:-20}}"
  base="$(docs_git_dir)" || base="$DOCS/.aidlc-kit"
  mkdir -p -- "$base"
  LOCK_DIR="$base/aidlc-kit.lock"
  while ! mkdir -- "$LOCK_DIR" 2>/dev/null; do
    if break_stale_lock; then continue; fi
    tries=$((tries + 1))
    if [ "$tries" -ge "$max" ]; then LOCK_DIR=""; return 1; fi
    sleep 0.25
  done
  echo "$$" > "$LOCK_DIR/pid"
}

# lock_is_stale -> 0 if the holder is gone (dead pid), or never wrote its pid
# and the lock is over a minute old.
lock_is_stale() {
  local pid
  pid="$(cat -- "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [ -n "$pid" ]; then
    ! pid_alive "$pid"
  else
    [ -d "$LOCK_DIR" ] && [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +1 2>/dev/null)" ]
  fi
}

# break_stale_lock -> 0 if a stale lock was removed. Two processes may judge
# the same lock stale at once; if both simply deleted it, the slower one
# could delete the lock the faster one had just re-taken. So breaking takes
# its own short mkdir mutex and re-checks staleness while holding it.
break_stale_lock() {
  lock_is_stale || return 1
  local breaker="$LOCK_DIR.break"
  if ! mkdir -- "$breaker" 2>/dev/null; then
    # someone else is breaking it; clear a breaker abandoned by a crash
    if [ -n "$(find "$breaker" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir -- "$breaker" 2>/dev/null || true; fi
    return 1
  fi
  local broke=1
  if lock_is_stale; then rm -rf -- "$LOCK_DIR"; broke=0; fi
  rmdir -- "$breaker" 2>/dev/null || true
  return "$broke"
}

# pid_alive PID — kill -0 fails both for a dead process and for a live one we
# may not signal (another user's); only the first means the lock is stale.
pid_alive() {
  local err
  err="$(kill -0 "$1" 2>&1)" && return 0
  case "$err" in *ermitted*|*EPERM*) return 0 ;; esac
  return 1
}

release_lock() {
  if [ -n "$LOCK_DIR" ]; then rm -rf -- "$LOCK_DIR"; LOCK_DIR=""; fi
}

# ---- two-way sync for copy-mode paths -----------------------------------------
# A manifest in the working repo's .git/ remembers each file's checksum at the
# last sync. A file changed on one side only is propagated; changed on both
# sides is a conflict and left alone on both sides (never silently
# overwritten). Deletions propagate the same way.

manifest_file() { echo "$GITDIR/aidlc-kit/manifest"; }

# list_sums BASE RELPATH -> "relpath<TAB>crc-size" for every file under BASE/RELPATH
list_sums() {
  local base="$1" rel="$2"
  if [ -d "$base/$rel" ]; then
    find "$base/$rel" -type f ! -name '.aidlc-kit-probe-*' -exec cksum {} +
  elif [ -f "$base/$rel" ]; then
    cksum "$base/$rel"
  fi | awk -v base="$base/" '
    match($0, /^[0-9]+ [0-9]+ /) {
      sum = $1 "-" $2; path = substr($0, RLENGTH + 1)
      if (index(path, base) == 1) path = substr(path, length(base) + 1)
      if (index(path, "\t") == 0) print path "\t" sum
    }'
}

# sync_copy_path INDEX -> runs the merge for one managed path, updates the
# manifest; adds to SYNC_COPIED / SYNC_DELETED / SYNC_CONFLICTS.
sync_copy_path() {
  local i="$1" p t w_list d_list b_list actions newman act rel sum src dst victim
  local conflicts_before="$SYNC_CONFLICTS"
  p="$(strip_slash "${M_PATH[$i]}")"
  t="$(kit_tmp)"
  w_list="$t/w"; d_list="$t/d"; b_list="$t/b"; actions="$t/actions"; newman="$t/manifest"
  list_sums "$WORK" "$p" > "$w_list"
  list_sums "$DOCS/$NAME" "$p" > "$d_list"
  : > "$b_list"
  if [ -f "$(manifest_file)" ]; then cp -- "$(manifest_file)" "$b_list"; fi

  # A managed path that is missing entirely on one side (`git clean -fdx`
  # removes ignored files), or a managed folder that is suddenly empty there
  # while the last sync had files (a tool clearing its output before
  # regenerating it), means "no information there", not "everything was
  # deleted": restore that side from the other instead of propagating a mass
  # deletion. Individual files deleted inside a non-empty folder still sync.
  local wroot=1 droot=1
  if [ ! -e "$WORK/$p" ]; then wroot=0; fi
  if [ ! -e "$DOCS/$NAME/$p" ]; then droot=0; fi

  # 3-way decision per file (w = working, d = docs, b = last sync)
  awk -F '\t' -v OFS='\t' -v pre="$p" -v wroot="$wroot" -v droot="$droot" '
    function inscope(k) { return k == pre || index(k, pre "/") == 1 }
    FILENAME == ARGV[1] { w[$1] = $2; all[$1] = 1; nw++; next }
    FILENAME == ARGV[2] { d[$1] = $2; all[$1] = 1; nd++; next }
    inscope($1)         { b[$1] = $2; all[$1] = 1; nb++ }
    END {
      if (nb > 0 && nw == 0) wroot = 0
      if (nb > 0 && nd == 0) droot = 0
      for (k in all) {
        wv = (k in w) ? w[k] : "-"; dv = (k in d) ? d[k] : "-"; bv = (k in b) ? b[k] : "-"
        if (!wroot)        { if (dv != "-") print "to-work", k, dv, bv; continue }
        if (!droot)        { if (wv != "-") print "to-docs", k, wv, bv; continue }
        if (wv == dv)      { if (wv != "-") print "same", k, wv }
        else if (dv == bv) { if (wv == "-") print "del-docs", k, "-"; else print "to-docs", k, wv, bv }
        else if (wv == bv) { if (dv == "-") print "del-work", k, "-"; else print "to-work", k, dv, bv }
        else               { print "conflict", k, bv }
      }
    }' "$w_list" "$d_list" "$b_list" | LC_ALL=C sort -t "$(printf '\t')" -k2 > "$actions"

  # new manifest: other paths' entries unchanged, this path's from the actions
  awk -F '\t' -v pre="$p" 'index($1, pre "/") != 1 && $1 != pre' "$b_list" > "$newman"

  while IFS="$(printf '\t')" read -r act rel sum base; do
    case "$act" in
      same) printf '%s\t%s\n' "$rel" "$sum" >> "$newman" ;;
      to-docs|to-work)
        if [ "$act" = to-docs ]; then src="$WORK/$rel"; dst="$DOCS/$NAME/$rel"; else src="$DOCS/$NAME/$rel"; dst="$WORK/$rel"; fi
        if [ ! -f "$src" ]; then
          # unusual names (e.g. a newline) can't round-trip through the listing
          warn "skipping '$rel': can't read it back (unusual characters in the name?)"
          continue
        fi
        if [ "$DRY_RUN" = 1 ]; then
          info "    would copy $rel ${act#to-} side"
        else
          if ! { mkdir -p -- "$(dirname -- "$dst")" && cp -p -- "$src" "$dst"; }; then
            # never record a copy that didn't happen: keep the previous
            # baseline, so the next sync still sees "changed on this side
            # only" and retries the copy — never an overwrite of the newer side
            warn "couldn't copy '$rel' (locked or no permission?); it will be retried"
            if [ -n "$base" ] && [ "$base" != "-" ]; then printf '%s\t%s\n' "$rel" "$base" >> "$newman"; fi
            continue
          fi
          info "    $rel -> ${act#to-}"
        fi
        printf '%s\t%s\n' "$rel" "$sum" >> "$newman"
        SYNC_COPIED=$((SYNC_COPIED + 1)) ;;
      del-docs|del-work)
        victim="$WORK/$rel"
        if [ "$act" = del-docs ]; then victim="$DOCS/$NAME/$rel"; fi
        if [ "$DRY_RUN" = 1 ]; then
          info "    would delete $rel (${act#del-} side)"
        else
          rm -f -- "$victim"
          remove_emptied_parents "$victim" "$rel" "$p"
          info "    $rel deleted (${act#del-} side)"
        fi
        SYNC_DELETED=$((SYNC_DELETED + 1)) ;;
      conflict)
        [ "${SYNC_SILENT:-0}" = 1 ] || warn "$rel changed in both the working repo and the docs repo since the last sync; left both untouched — keep one version (copy it over the other), then run 'aidlc-kit save' again"
        if [ "$sum" != "-" ]; then printf '%s\t%s\n' "$rel" "$sum" >> "$newman"; fi
        SYNC_CONFLICTS=$((SYNC_CONFLICTS + 1)) ;;
    esac
  done < "$actions"

  if [ "$DRY_RUN" != 1 ]; then
    mkdir -p -- "$(dirname -- "$(manifest_file)")"
    cp -- "$newman" "$(manifest_file)"
    # what's left after a real sync: only conflicts (for status/doctor reuse)
    SYNC_LAST_CONFLICTS[i]=$((SYNC_CONFLICTS - conflicts_before))
  fi
}
SYNC_LAST_CONFLICTS=()

# remove_emptied_parents FILE REL ROOT — after deleting FILE (REL inside the
# project, under managed path ROOT), remove the folders that deletion left
# empty, walking up but never past ROOT. Folders that were empty on their own
# (a tool's placeholder) are left alone.
remove_emptied_parents() {
  local dir="${1%/*}" rel="${2%/*}"
  while [ "$rel" != "$2" ] && [ "$rel" != "$3" ] && [ -n "$rel" ]; do
    rmdir -- "$dir" 2>/dev/null || break
    dir="${dir%/*}"
    case "$rel" in */*) rel="${rel%/*}" ;; *) break ;; esac
  done
  return 0
}

# repair_missing_links -> recreate link-mode links that vanished from the
# working repo (e.g. `git clean -fdx` removes ignored links). Only a link is
# created; no content moves, so this is safe to do on every save.
repair_missing_links() {
  local i p w d
  for i in "${!M_PATH[@]}"; do
    case "${M_MODE[$i]:-}" in symlink|junction) ;; *) continue ;; esac
    p="$(strip_slash "${M_PATH[$i]}")"; w="$WORK/$p"; d="$DOCS/$NAME/$p"
    if [ -e "$w" ] || [ -L "$w" ] || [ ! -e "$d" ]; then continue; fi
    if [ "$DRY_RUN" = 1 ]; then info "    would recreate the link for $p"; continue; fi
    link_path "$i" link || warn "the link for $p is missing and couldn't be recreated; run 'aidlc-kit attach'"
  done
}

# sync_copy_paths -> sync every copy-mode path. Sets SYNC_* counters.
sync_copy_paths() {
  local i
  SYNC_COPIED=0; SYNC_DELETED=0; SYNC_CONFLICTS=0
  for i in "${!M_PATH[@]}"; do
    if [ "${M_MODE[$i]:-}" = copy ]; then sync_copy_path "$i"; fi
  done
}

# ---- commit + push ------------------------------------------------------------

# repo_busy GITDIR -> 0 if that repo is mid-merge/rebase/cherry-pick/am
repo_busy() {
  [ -d "$1/rebase-merge" ] || [ -d "$1/rebase-apply" ] || [ -f "$1/MERGE_HEAD" ] || [ -f "$1/CHERRY_PICK_HEAD" ]
}

docs_repo_busy() {
  local gd
  gd="$(docs_git_dir)" || return 1
  repo_busy "$gd"
}

commit_message() {
  if [ -n "$OPT_MESSAGE" ]; then echo "$OPT_MESSAGE"; return 0; fi
  local branch sha
  branch="$(git -C "$WORK" symbolic-ref --short -q HEAD 2>/dev/null || echo detached)"
  sha="$(git -C "$WORK" rev-parse -q --verify --short HEAD 2>/dev/null || echo no-commits)"
  echo "$NAME: AI artifacts @ $branch $sha (${OPT_TRIGGER:-manual})"
}

# commit_docs -> 0 committed or nothing to do, 1 commit failed
commit_docs() {
  if ! docs_is_git; then
    warn "$DOCS is not a git repo; artifacts are stored but not committed (run 'git init' there)"
    return 0
  fi
  if docs_repo_busy; then
    warn "the docs repo is in the middle of a merge/rebase; not committing (finish it, then run 'aidlc-kit save')"
    return 0
  fi
  # the docs-side ignore block, with what the record's profiles exclude now
  # (a kit upgrade can add an exclude= to a profile used by an older setup)
  if [ "$DRY_RUN" != 1 ]; then update_docs_ignore; fi

  # Commit through a private index holding HEAD + this project's folder, so
  # the user's own staged work elsewhere in the docs repo stays out of the
  # commit (and staged), and files tracked from before an exclude= covered
  # them (a migrated repo's graphify cache) can leave the history:
  # `commit -- <path>` would re-add those from the disk.
  local idx real msg excluded
  real="$(git -C "$DOCS" rev-parse --git-path index)"
  case "$real" in /*|[A-Za-z]:*) ;; *) real="$DOCS/$real" ;; esac
  idx="$real.aidlc-kit"
  # a save killed mid-commit (an async hook when Claude Code exits) can leave
  # these behind; the kit lock we hold means nothing else is using them
  rm -f -- "$idx" "$idx.lock"
  if git -C "$DOCS" rev-parse -q --verify HEAD >/dev/null; then
    # one-tree `read-tree -m` over a copy of the real index: HEAD's entries,
    # with git's stat cache kept for unchanged files and no scan of the work tree
    if [ -f "$real" ]; then cp -- "$real" "$idx"; fi
    if ! GIT_INDEX_FILE="$idx" git -C "$DOCS" read-tree -m HEAD >/dev/null 2>&1; then
      rm -f -- "$idx"
      GIT_INDEX_FILE="$idx" git -C "$DOCS" read-tree HEAD
    fi
  fi
  GIT_INDEX_FILE="$idx" git -C "$DOCS" -c core.safecrlf=false add -A -- "$NAME"
  # tracked files the project's .gitignore files now exclude leave the index
  # (only those: not the user's global or info/exclude patterns)
  excluded="$(kit_tmp)/excluded"
  GIT_INDEX_FILE="$idx" git -C "$DOCS" ls-files -z -c -i --exclude-per-directory=.gitignore -- "$NAME" > "$excluded"
  if [ -s "$excluded" ]; then
    GIT_INDEX_FILE="$idx" xargs -0 git -C "$DOCS" rm -q --cached -- < "$excluded"
  fi
  if GIT_INDEX_FILE="$idx" git -C "$DOCS" diff --cached --quiet; then
    rm -f -- "$idx"
    info "  nothing to commit"
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    rm -f -- "$idx"
    info "  would commit changes in $NAME/"
    return 0
  fi
  msg="$(commit_message)"
  if ! GIT_INDEX_FILE="$idx" git -C "$DOCS" commit -q -m "$msg"; then
    rm -f -- "$idx"
    warn "commit in $DOCS failed (is git user.name/user.email set there? a hook rejecting it?)"
    return 1
  fi
  rm -f -- "$idx"
  # the real index: this folder now matches the new commit (other paths keep
  # whatever the user staged)
  git -C "$DOCS" reset -q HEAD -- "$NAME" >/dev/null 2>&1 || \
    warn "couldn't refresh the docs repo's index for $NAME/; 'git -C \"$DOCS\" reset -- $NAME' fixes how 'git status' shows it"
  info "  committed: $msg"
}

# push_docs -> 0 pushed, 1 not pushed (reason printed). Never forces.
push_docs() {
  docs_is_git || return 0
  if [ "$DRY_RUN" = 1 ]; then info "  would pull --rebase and push the docs repo"; return 0; fi
  # The user's own merge/rebase in progress must never be touched — in
  # particular never `rebase --abort`ed below.
  if docs_repo_busy; then
    warn "the docs repo is in the middle of a merge/rebase; not pushing (finish it, then run 'aidlc-kit save --push')"
    return 1
  fi
  if ! git -C "$DOCS" rev-parse -q --verify '@{upstream}' >/dev/null 2>&1; then
    warn "the docs repo's branch has no upstream; set it once with: git -C \"$DOCS\" push -u origin HEAD"
    return 1
  fi
  # The user's own uncommitted work elsewhere in the docs repo is theirs:
  # rebasing would need --autostash, which loses what they had staged. Leave it
  # alone and say so rather than touch it.
  if [ -n "$(git -C "$DOCS" status --porcelain --untracked-files=no)" ]; then
    warn "the docs repo has uncommitted changes outside $NAME/; not pushing (commit or stash them, then run 'aidlc-kit save --push')"
    return 1
  fi
  local err
  if ! err="$(net_git pull -q --rebase 2>&1)"; then
    # the repo wasn't busy before (checked above), so any rebase now is ours
    if docs_repo_busy; then git -C "$DOCS" rebase --abort >/dev/null 2>&1 || true; fi
    warn "couldn't update the docs repo from its upstream; your commit is kept locally. Resolve with: git -C \"$DOCS\" pull --rebase"
    warn "git said: $(first_line "$err")"
    return 1
  fi
  if ! err="$(net_git push -q 2>&1)"; then
    warn "push of the docs repo failed; your commit is kept locally"
    warn "git said: $(first_line "$err")"
    return 1
  fi
  info "  pushed the docs repo"
}

# net_git ARGS... — git in the docs repo for network operations, which must
# never wait for input (they run from hooks): no credential prompts, and ssh
# in BatchMode so a key passphrase or unknown host key fails instead of
# hanging. Honors core.sshCommand; leaves GIT_SSH (e.g. plink) alone.
net_git() {
  if [ -n "${GIT_SSH:-}" ] && [ -z "${GIT_SSH_COMMAND:-}" ]; then
    GIT_TERMINAL_PROMPT=0 git -C "$DOCS" "$@"
    return
  fi
  local ssh_cmd
  ssh_cmd="${GIT_SSH_COMMAND:-$(git -C "$DOCS" config --get core.sshCommand 2>/dev/null || echo ssh)}"
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$ssh_cmd -o BatchMode=yes" git -C "$DOCS" "$@"
}

first_line() { printf '%s\n' "$1" | sed -n '/[^[:space:]]/{p;q;}'; }

# ---- save ---------------------------------------------------------------------

# Exit codes: 0 ok, 1 commit/push failed, 2 copy-mode conflicts (everything
# else was still synced and committed). A busy lock is not an error: the next
# event catches up.
cmd_save() {
  parse_common_opts "$@"
  reject_opts_for save
  load_config
  load_existing_setup
  save_flow
}

# save_flow -> the save itself, for an already-loaded setup (also used by the
# hooks). SAVE_NO_COMMIT=1 (AIDLC_AUTO_COMMIT=off in hooks) only syncs.
save_flow() {
  # A plain save may skip when busy (the next one catches up); a push must not
  # be silently dropped, since nothing retries it: wait longer, then fail.
  if [ "$OPT_PUSH" = 1 ]; then
    if ! acquire_lock 120; then
      warn "another aidlc-kit process kept the docs repo busy for 30 s; '$NAME' was NOT saved or pushed — run 'aidlc-kit save --push' again"
      return 1
    fi
  elif ! acquire_lock; then
    info "Another aidlc-kit process is saving '$NAME'; skipping (the next save catches up)."
    return 0
  fi
  info "Saving '$NAME'..."
  if [ "$DRY_RUN" = 1 ]; then info "  (dry run — nothing will change)"; fi

  repair_missing_links
  sync_copy_paths
  if [ $((SYNC_COPIED + SYNC_DELETED)) -gt 0 ]; then
    info "  copy-mode sync: $SYNC_COPIED copied, $SYNC_DELETED deleted"
  fi

  local rc=0
  if [ "${SAVE_NO_COMMIT:-0}" = 1 ]; then
    info "  not committing (AIDLC_AUTO_COMMIT=off)"
  else
    commit_docs || rc=1
    if [ "$OPT_PUSH" = 1 ]; then push_docs || rc=1; fi
  fi
  release_lock

  if [ "$SYNC_CONFLICTS" -gt 0 ] && [ "$rc" = 0 ]; then rc=2; fi
  return "$rc"
}
