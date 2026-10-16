# shellcheck shell=bash disable=SC2034,SC2153,SC2317
# (file-wide: globals and functions here are used by the files that source this one)

# init / attach / status / detach. See docs/DESIGN.md §3 and §7.

GITIGNORE_BEGIN="# >>> aidlc-workspace-kit >>> (managed block, do not edit)"
GITIGNORE_END="# <<< aidlc-workspace-kit <<<"
GITIGNORE_NAME_PREFIX="# docs-repo folder: "

# ---- option parsing shared by commands -------------------------------------

OPT_DOCS=""; OPT_NAME=""; OPT_PREFER=""; OPT_LINK_MODE=""; OPT_DIR=""
OPT_PUSH=0; OPT_MESSAGE=""; OPT_TRIGGER=""; OPT_NO_HOOKS=0; OPT_NO_RULES=0; OPT_TARGET=""
OPT_PATHS=(); OPT_PROFILES=()
DRY_RUN=0; ASSUME_YES=0; QUIET=0

parse_common_opts() { # "$@" -> sets OPT_* ; dies on unknown options
  while [ $# -gt 0 ]; do
    case "$1" in
      --docs-repo) need_value "$@"; OPT_DOCS="$2"; shift ;;
      --repo) need_value "$@"; OPT_DIR="$2"; shift ;;
      --no-hooks) OPT_NO_HOOKS=1 ;;
      --no-rules) OPT_NO_RULES=1 ;;
      -t|--target) need_value "$@"; OPT_TARGET="$2"; shift ;;
      --hook-format) need_value "$@"; shift ;;   # marker in installed hook commands
      --name) need_value "$@"; OPT_NAME="$2"; shift ;;
      --path) need_value "$@"; OPT_PATHS+=("$2"); shift ;;
      --profile) need_value "$@"; OPT_PROFILES+=("$2"); shift ;;
      --prefer) need_value "$@"; OPT_PREFER="$2"; shift ;;
      --link-mode) need_value "$@"; OPT_LINK_MODE="$2"; shift ;;
      --push) OPT_PUSH=1 ;;
      -m|--message) need_value "$@"; OPT_MESSAGE="$2"; shift ;;
      --trigger) need_value "$@"; OPT_TRIGGER="$2"; shift ;;
      -n|--dry-run) DRY_RUN=1 ;;
      -y|--yes) ASSUME_YES=1 ;;
      -q|--quiet) QUIET=1 ;;
      -h|--help) usage; exit 0 ;;
      -*) die "unknown option: $1 (see 'aidlc-kit --help')" ;;
      *) [ -z "$OPT_DIR" ] || die "unexpected argument: $1"; OPT_DIR="$1" ;;
    esac
    shift
  done
  case "$OPT_PREFER" in ''|working|docs) ;; *) die "--prefer must be 'working' or 'docs'" ;; esac
  [ -z "$OPT_LINK_MODE" ] || validate_link_mode "$OPT_LINK_MODE"
  return 0
}

need_value() { if [ $# -lt 2 ] || [ -z "$2" ]; then die "$1 needs a value"; fi; }

reject_opts_for() { # command — save-only options make no sense elsewhere
  if [ "$1" != save ] && { [ "$OPT_PUSH" = 1 ] || [ -n "$OPT_MESSAGE" ] || [ -n "$OPT_TRIGGER" ]; }; then
    die "--push, --message and --trigger only apply to 'save'"
  fi
}

# ---- context ---------------------------------------------------------------

# resolve_work [dir] -> WORK (repo top level), GITDIR
resolve_work() {
  local dir="${1:-.}"
  [ -d "$dir" ] || die "not a directory: $dir"
  WORK="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || die "$dir is not inside a git working tree"
  GITDIR="$(git -C "$WORK" rev-parse --absolute-git-dir)"
}

# resolve_docs <from-state> -> DOCS (absolute, real). Precedence: flag, state, config.
resolve_docs() {
  local candidate="${OPT_DOCS:-${1:-$AIDLC_DOCS_REPO}}"
  [ -n "$candidate" ] || die "no docs repo given: pass --docs-repo <dir> or set AIDLC_DOCS_REPO"
  candidate="$(expand_path "$candidate")"
  [ -d "$candidate" ] || die "docs repo not found: $candidate (clone or create it first)"
  DOCS="$(real_dir "$candidate")"
  local work_real
  work_real="$(real_dir "$WORK")"
  case "$DOCS/" in "$work_real"/*) die "the docs repo must not be inside the working repo" ;; esac
  case "$work_real/" in "$DOCS"/*) die "the working repo must not be inside the docs repo" ;; esac
  docs_is_git || \
    warn "$DOCS is not a git repo yet; artifacts will be stored there but not versioned (run 'git init' in it)"
}

docs_is_git() { git -C "$DOCS" rev-parse --is-inside-work-tree >/dev/null 2>&1; }

# block_lines inside|outside|outside-marked FILE -> the lines inside (or
# outside) the managed block, CRs stripped; outside-marked also prints
# BLOCK_MARK where the block was. Exit 3 if a begin marker has no end marker:
# what follows it can't be told apart from the user's own lines.
BLOCK_MARK="@@aidlc-workspace-kit block position@@"
block_lines() {
  awk -v want="$1" -v b="$GITIGNORE_BEGIN" -v e="$GITIGNORE_END" -v m="$BLOCK_MARK" '
    { sub(/\r$/, "") }
    $0 == b { inb = 1; if (want == "outside-marked") print m; next }
    $0 == e { inb = 0; next }
    (want == "inside") == (inb == 1) { print }
    END { if (inb) exit 3 }' "$2"
}

# name_from_gitignore -> the docs-repo folder named in the working repo's
# managed .gitignore block (empty if none)
name_from_gitignore() {
  local lines line
  [ -f "$WORK/.gitignore" ] || return 0
  lines="$(block_lines inside "$WORK/.gitignore")" || return 0
  while IFS= read -r line; do
    case "$line" in "$GITIGNORE_NAME_PREFIX"?*) echo "${line#"$GITIGNORE_NAME_PREFIX"}"; return 0 ;; esac
  done <<< "$lines"
}

resolve_name() { # <from-state>
  local hint
  if [ -n "$OPT_NAME" ]; then
    NAME="$OPT_NAME"
  elif [ -n "${1:-}" ]; then
    NAME="$1"
  elif hint="$(name_from_gitignore)" && [ -n "$hint" ]; then
    NAME="$hint"
    # a .gitignore copied from another project would name that project's folder
    info "Docs-repo folder: '$NAME', as named in $WORK/.gitignore (pass --name to use another)"
  else
    NAME="$(default_name "$(basename "$WORK")")"
    [ -n "$NAME" ] || die "can't derive a project name from '$(basename "$WORK")'; pass --name <name>"
  fi
  validate_name "project name" "$NAME" "pass a valid one with --name"
}

# Folder name -> safe project name: "My App (old)" -> "My-App-old".
default_name() {
  local n
  n="$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-' | tr -s '-')"
  while :; do case "$n" in [-.]*) n="${n#?}" ;; *) break ;; esac; done
  while :; do case "$n" in *-) n="${n%-}" ;; *) break ;; esac; done
  echo "$n"
}

link_pref() { echo "${OPT_LINK_MODE:-$AIDLC_LINK_MODE}"; }

has_content() { # PATH KIND -> 0 if it holds anything
  if [ "$2" = dir ]; then
    [ -d "$1" ] && [ -n "$(ls -A -- "$1" 2>/dev/null)" ]
  else
    [ -f "$1" ]
  fi
}

# ---- plan + apply (shared by init and attach) -------------------------------

# For each managed path, decide an action:
#   ok        already linked to the docs repo (or a copy-mode copy)
#   relink    link points at the right place but the docs folder is gone
#   move      working repo has content, docs repo empty -> move it over, link
#   link      nothing to move -> link (restores context if docs repo has content)
#   keep-working / keep-docs   both have content, resolved by --prefer
#   conflict  both have content, no --prefer
PLAN=()

make_plan() {
  local i p kind w d
  PLAN=()
  for i in "${!M_PATH[@]}"; do
    p="$(strip_slash "${M_PATH[$i]}")"; kind="${M_KIND[$i]}"
    w="$WORK/$p"; d="$DOCS/$NAME/$p"
    if [ -L "$w" ] && [ ! -e "$w" ] && dangling_link_to "$w" "$d"; then
      # right destination, but it doesn't exist: a missing docs folder must be
      # recreated; a file that hasn't been generated yet is normal
      if [ "$kind" = dir ]; then PLAN[i]=relink; else PLAN[i]=ok; fi
    elif is_link_to "$w" "$d"; then
      PLAN[i]=ok
    elif [ -L "$w" ]; then
      die "$w is a link to somewhere else ($(readlink -- "$w")); remove it or pick another --name"
    fi
    if [ -e "$w" ] && [ "$kind" = dir ] && [ ! -d "$w" ]; then die "$w should be a directory but is a file"; fi
    if [ -e "$w" ] && [ "$kind" = file ] && [ ! -f "$w" ]; then die "$w should be a file but is a directory"; fi
    if [ -e "$d" ] && [ "$kind" = dir ] && [ ! -d "$d" ]; then die "$d should be a directory but is a file"; fi
    if [ -e "$d" ] && [ "$kind" = file ] && [ ! -f "$d" ]; then die "$d should be a file but is a directory"; fi

    if [ -n "${PLAN[$i]:-}" ]; then
      :   # ok / relink, decided above
    elif [ "${M_MODE[$i]:-}" = copy ] && [ -e "$w" ]; then
      PLAN[i]=ok
    elif has_content "$w" "$kind"; then
      if has_content "$d" "$kind"; then
        case "$OPT_PREFER" in
          working) PLAN[i]=keep-working ;;
          docs) PLAN[i]=keep-docs ;;
          *) PLAN[i]=conflict ;;
        esac
      else
        PLAN[i]=move
      fi
    else
      PLAN[i]="link"
    fi
  done
}

describe_plan() {
  local i p conflicts=0 changes=0
  info "Working repo: $WORK"
  info "Docs repo:    $DOCS/$NAME"
  for i in "${!M_PATH[@]}"; do
    p="${M_PATH[$i]}"
    case "${PLAN[$i]}" in
      ok)           info "  $p — already set up" ;;
      relink)       info "  $p — docs folder missing: recreate it and re-link"; changes=1 ;;
      move)         info "  $p — move into docs repo, then link"; changes=1 ;;
      link)         if has_content "$DOCS/$NAME/$(strip_slash "$p")" "${M_KIND[$i]}"; then
                      info "  $p — link (restores existing docs)"
                    else
                      info "  $p — link (nothing there yet)"
                    fi; changes=1 ;;
      keep-working) info "  $p — both sides have content: keep WORKING copy, back up the docs copy"; changes=1 ;;
      keep-docs)    info "  $p — both sides have content: keep DOCS copy, back up the working copy"; changes=1 ;;
      conflict)     info "  $p — CONFLICT: both the working repo and the docs repo have content"; conflicts=1 ;;
    esac
    # --error-unmatch instead of `ls-files | head`: under pipefail, a long
    # listing would SIGPIPE git and abort the whole command.
    if [ "${PLAN[$i]}" != ok ] && git -C "$WORK" ls-files --error-unmatch -- "$(strip_slash "$p")" >/dev/null 2>&1; then
      warn "$p is tracked by git in the working repo. After this, git will show it as deleted; to stop tracking it run:  git rm -r --cached -- $(strip_slash "$p")"
    fi
  done
  if [ "$conflicts" = 1 ]; then
    die "resolve the conflicts with --prefer working (keep the working repo's files) or --prefer docs (keep the docs repo's files); the other side is backed up under $NAME/.aidlc-kit/backup/ in the docs repo"
  fi
  PLAN_CHANGES="$changes"
}

backup_dir() {
  [ -n "${BACKUP_DIR:-}" ] || BACKUP_DIR="$DOCS/$NAME/.aidlc-kit/backup/$(date +%Y%m%d-%H%M%S)"
  echo "$BACKUP_DIR"
}

move_to_backup() { # SRC SIDE RELPATH
  local dst
  dst="$(backup_dir)/$2/$3"
  mkdir -p -- "$(dirname "$dst")"
  mv -- "$1" "$dst"
  info "    backed up $1 -> $dst"
}

apply_plan() {
  local i p kind w d mode pref
  pref="$(link_pref)"
  for i in "${!M_PATH[@]}"; do
    p="$(strip_slash "${M_PATH[$i]}")"; kind="${M_KIND[$i]}"
    w="$WORK/$p"; d="$DOCS/$NAME/$p"
    case "${PLAN[$i]}" in
      ok)
        if [ -z "${M_MODE[$i]:-}" ]; then M_MODE[i]="$(detect_mode "$w")"; fi
        continue ;;
      relink)       remove_link "$w" ;;
      keep-working) move_to_backup "$d" docs "$p" ;;
      keep-docs)    move_to_backup "$w" working "$p" ;;
    esac

    mkdir -p -- "$(dirname "$d")"
    if [ -e "$w" ] && has_content "$w" "$kind"; then
      # move (or keep-working): docs side is empty or was just backed up
      if [ "$kind" = dir ] && [ -d "$d" ]; then rmdir -- "$d"; fi
      mv -- "$w" "$d"
      info "    moved $p into the docs repo"
    elif [ -d "$w" ]; then
      rmdir -- "$w"      # empty dir in the working repo
    fi
    link_path "$i" "$pref" || die "could not create a link for $p (link mode '$pref'); on Windows enable Developer Mode for file links, or use --link-mode auto to fall back to copying"
  done
}

# link_path INDEX PREF -> create the working-repo link (or copy) for one
# managed path whose working side is absent, record its mode in the machine
# state, report it. 1 if PREF can't be satisfied. Shared by init/attach and
# by save's repair of links removed from the working repo.
link_path() {
  local i="$1" pref="$2" p w d mode
  p="$(strip_slash "${M_PATH[$i]}")"; w="$WORK/$p"; d="$DOCS/$NAME/$p"
  if [ "${M_KIND[$i]}" = dir ]; then mkdir -p -- "$d"; fi
  mode="$(make_link "${M_KIND[$i]}" "$w" "$d" "$pref")" || return 1
  M_MODE[i]="$mode"
  # record progress per path, so a later failure leaves a resumable state
  write_state "$GITDIR" "$DOCS" "$NAME"
  case "$mode" in
    copy) info "    $p: copy mode (links unavailable here); changes are synced by 'aidlc-kit save'" ;;
    *)    info "    $p: $mode -> $d" ;;
  esac
}

# With --link-mode link, prove the needed link types work here before moving
# anything, so a failure can't leave artifacts half-moved.
preflight_links() {
  [ "$(link_pref)" = link ] || return 0
  local i l t need_dir=0 need_file=0 ok=1
  for i in "${!M_PATH[@]}"; do
    if [ "${PLAN[$i]}" = ok ]; then continue; fi
    if [ "${M_KIND[$i]}" = dir ]; then need_dir=1; else need_file=1; fi
  done
  if [ "$need_dir" = 0 ] && [ "$need_file" = 0 ]; then return 0; fi
  # Links live in the working repo and point into the docs repo, and link
  # support depends on the filesystem holding the LINK. So: targets in the
  # docs repo, test links next to the working repo (its .git dir, which stays
  # out of `git status` if we're interrupted).
  t="$DOCS/.aidlc-kit-preflight-$$"
  l="$GITDIR/aidlc-kit/preflight-$$"
  mkdir -p -- "$t/target-dir" "$l"
  : > "$t/target-file"
  if [ "$need_dir" = 1 ] && ! make_link dir "$l/dir-link" "$t/target-dir" link >/dev/null; then ok=0; fi
  if [ "$need_file" = 1 ] && ! make_link file "$l/file-link" "$t/target-file" link >/dev/null; then ok=0; fi
  for i in "$l/dir-link" "$l/file-link"; do
    if [ -L "$i" ]; then remove_link "$i"; fi
  done
  rm -rf -- "$t" "$l"
  [ "$ok" = 1 ] || die "--link-mode link: this machine can't create the links needed (file links on Windows need Developer Mode); nothing was changed. Use --link-mode auto to fall back to copying."
}

# Write everything that describes the setup BEFORE moving files, so an
# interrupted apply can be finished by re-running init/attach.
apply_with_record() { # 1 = also write the record (init), 0 = keep it (attach)
  # same lock as `save`, so a hook-triggered commit never sees a half-moved tree
  acquire_lock || die "another aidlc-kit process is working on this docs repo; try again in a moment"
  preflight_links
  if [ "$1" = 1 ]; then write_record "$DOCS" "$NAME"; fi
  write_state "$GITDIR" "$DOCS" "$NAME"
  update_ignores
  apply_plan
  write_state "$GITDIR" "$DOCS" "$NAME"
  # copy-mode paths: bring both sides in step and record the sync baseline
  sync_copy_paths
  if [ "$SYNC_CONFLICTS" -gt 0 ]; then
    warn "$SYNC_CONFLICTS copy-mode file(s) differ on both sides; see the warnings above"
  fi
  release_lock
}

detect_mode() { # existing working path -> symlink|junction|copy
  if [ -L "$1" ]; then
    if [ "$IS_WINDOWS" = 1 ] && [ -d "$1" ] && cmd_is_junction "$1"; then echo junction; else echo symlink; fi
  else
    echo copy
  fi
}

cmd_is_junction() {
  command -v cygpath >/dev/null 2>&1 || return 1
  MSYS_NO_PATHCONV=1 cmd /c dir /AL "$(cygpath -w "$(dirname "$1")")" 2>/dev/null | grep -q "<JUNCTION>.*[[:space:]]$(basename "$1") \["
}

# ---- ignore files ----------------------------------------------------------

# write_block FILE LINES... — replace (or append) the managed block.
write_block() {
  # Keeps the file's line endings (CRLF checkouts on Windows) and leaves it
  # untouched when nothing would change, so a fresh clone stays clean.
  local file="$1"; shift
  local tmp="$file.aidlc-kit.tmp" crlf=0
  # byte-level check: Git Bash's grep hides CRs in text files
  if [ -f "$file" ] && [ -n "$(tr -cd '\r' < "$file" | head -c 1)" ]; then crlf=1; fi
  if [ -f "$file" ]; then
    if ! block_lines outside-marked "$file" > "$tmp"; then
      rm -f -- "$tmp"
      die "$file has an aidlc-workspace-kit block without its end line ('$GITIGNORE_END'); restore it, then re-run"
    fi
  else
    : > "$tmp"
  fi
  if [ $# -gt 0 ]; then
    { echo "$GITIGNORE_BEGIN"; printf '%s\n' "$@"; echo "$GITIGNORE_END"; } > "$tmp.block"
  else
    : > "$tmp.block"
  fi
  if grep -qF "$BLOCK_MARK" "$tmp"; then
    # where the block already is (lines the user added after it stay after it)
    awk -v m="$BLOCK_MARK" -v bf="$tmp.block" '
      $0 == m { while ((getline l < bf) > 0) print l; close(bf); next } { print }' "$tmp" > "$tmp.new"
    mv -- "$tmp.new" "$tmp"
  elif [ -s "$tmp.block" ]; then
    # at the end, after exactly one blank line
    if [ -s "$tmp" ] && [ -n "$(tail -n 1 "$tmp")" ]; then echo "" >> "$tmp"; fi
    cat "$tmp.block" >> "$tmp"
  fi
  rm -f -- "$tmp.block"
  if [ "$crlf" = 1 ]; then
    sed 's/$/\r/' "$tmp" > "$tmp.crlf" && mv -- "$tmp.crlf" "$tmp"
  fi
  if [ -f "$file" ] && cmp -s "$tmp" "$file"; then
    rm -f -- "$tmp"
  else
    mv -- "$tmp" "$file"
  fi
}

update_ignores() {
  # the first line names the project's folder in the docs repo: the block is
  # committed, so a fresh clone (another machine, a cloud sandbox) finds it
  # without --name even when the folder names differ
  local lines=("$GITIGNORE_NAME_PREFIX$NAME") i e
  for i in "${!M_PATH[@]}"; do
    # no trailing slash: a symlink to a directory is not a directory to git
    lines+=("/$(strip_slash "${M_PATH[$i]}")")
  done
  write_block "$WORK/.gitignore" "${lines[@]}"
  update_docs_ignore
}

# update_docs_ignore -> the managed block in <docs>/<project>/.gitignore: our
# backups, the record's excludes, and the excludes the record's profiles have
# now, so a kit upgrade that adds one (graphify's cache/) reaches older setups.
update_docs_ignore() {
  local lines=("/.aidlc-kit/backup/") all="$R_EXCLUDES" name i e
  load_profiles "$DOCS"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    i="$(profile_index "$name")" || continue   # a profile since removed: the record still has its excludes
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      case $'\n'"$all"$'\n' in *$'\n'"$e"$'\n'*) ;; *) all="$(append_line "$all" "$e")" ;; esac
    done <<< "${P_EXCLUDE[$i]}"
  done <<< "$R_PROFILES"
  while IFS= read -r e; do if [ -n "$e" ]; then lines+=("/$e"); fi; done <<< "$all"
  mkdir -p -- "$DOCS/$NAME"
  write_block "$DOCS/$NAME/.gitignore" "${lines[@]}"
}

# ---- init ------------------------------------------------------------------

select_profiles() { # fills M_PATH, R_PROFILES, R_EXCLUDES from profiles/flags
  local name i p e
  load_profiles "$DOCS"
  if [ "${#OPT_PROFILES[@]}" -gt 0 ]; then
    for name in "${OPT_PROFILES[@]}"; do
      i="$(profile_index "$name")" || die "unknown profile '$name' (available: ${P_NAME[*]:-none})"
      use_profile "$i"
    done
  else
    for i in "${!P_NAME[@]}"; do
      if profile_matches "$i" "$WORK" || profile_in_docs "$i" "$DOCS/$NAME"; then use_profile "$i"; fi
    done
  fi
  for p in ${OPT_PATHS[@]+"${OPT_PATHS[@]}"}; do add_managed_path "$p"; done
  return 0
}

use_profile() {
  local i="$1" p e
  case $'\n'"$R_PROFILES"$'\n' in *$'\n'"${P_NAME[$i]}"$'\n'*) ;; *) R_PROFILES="$(append_line "$R_PROFILES" "${P_NAME[$i]}")" ;; esac
  while IFS= read -r p; do if [ -n "$p" ]; then add_managed_path "$p"; fi; done <<< "${P_PATH[$i]}"
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    case $'\n'"$R_EXCLUDES"$'\n' in *$'\n'"$e"$'\n'*) ;; *) R_EXCLUDES="$(append_line "$R_EXCLUDES" "$e")" ;; esac
  done <<< "${P_EXCLUDE[$i]}"
}

cmd_init() {
  parse_common_opts "$@"
  reject_opts_for "${FUNCNAME[0]#cmd_}"
  load_config
  resolve_work "$OPT_DIR"
  local s_docs="" s_project=""
  if read_state "$GITDIR"; then s_docs="$S_DOCS"; s_project="$S_PROJECT"; fi
  resolve_docs "$s_docs"
  resolve_name "$s_project"

  local existing=0
  if read_record "$DOCS" "$NAME"; then
    existing=1
    info "Found an existing record for '$NAME' in the docs repo; reusing it."
  fi
  read_state "$GITDIR" || true
  # rules first: a bad AIDLC_RULES_DIR or --target stops init before anything
  # moves, and whatever the rules installer creates (2.x's aidlc/) is detected
  # and managed by this same run
  if [ "$OPT_NO_RULES" != 1 ]; then setup_rules; fi
  select_profiles

  if [ "${#M_PATH[@]}" -eq 0 ]; then
    load_profiles "$DOCS"
    die "no AI artifacts detected in $WORK. Use --profile <name> (available: ${P_NAME[*]:-none}) or --path <relative/path/> to choose what to manage"
  fi

  if [ -n "$R_PROFILES" ]; then info "Profiles: $(echo "$R_PROFILES" | paste -sd ',' - | sed 's/,/, /g')"; fi
  make_plan
  describe_plan
  if [ "$DRY_RUN" = 1 ]; then info "(dry run — nothing changed)"; return 0; fi
  if [ "$existing" = 0 ] || [ "$PLAN_CHANGES" = 1 ]; then
    confirm "Proceed?" || die "aborted"
  fi

  apply_with_record 1
  if [ "$OPT_NO_HOOKS" != 1 ]; then install_hooks; fi
  info ""
  info "Done. '$NAME' artifacts now live in $DOCS/$NAME."
  info "Commit the working repo's .gitignore, and the docs repo's $NAME/ folder."
}

# ---- attach ----------------------------------------------------------------

cmd_attach() {
  parse_common_opts "$@"
  reject_opts_for "${FUNCNAME[0]#cmd_}"
  if [ "${#OPT_PATHS[@]}" -gt 0 ] || [ "${#OPT_PROFILES[@]}" -gt 0 ]; then
    die "attach uses the paths recorded in the docs repo; use 'init' to change them"
  fi
  load_config
  resolve_work "$OPT_DIR"
  local s_docs="" s_project=""
  if read_state "$GITDIR"; then s_docs="$S_DOCS"; s_project="$S_PROJECT"; fi
  resolve_docs "$s_docs"
  resolve_name "$s_project"
  read_record "$DOCS" "$NAME" || die "no record for '$NAME' in $DOCS (expected $(record_file "$DOCS" "$NAME")); use 'init' for a new project, or --name if the folder is named differently"
  read_state "$GITDIR" || true

  make_plan
  describe_plan
  if [ "$DRY_RUN" = 1 ]; then info "(dry run — nothing changed)"; return 0; fi
  local i needs_confirm=0
  for i in "${!PLAN[@]}"; do
    # relink only replaces a link and recreates an empty folder: no prompt, so
    # scripts, hooks and cloud setup can repair without --yes
    case "${PLAN[$i]}" in move|keep-working|keep-docs) needs_confirm=1 ;; esac
  done
  [ "$needs_confirm" = 0 ] || confirm "Proceed?" || die "aborted"

  local ignore_before
  ignore_before="$(cksum < "$WORK/.gitignore" 2>/dev/null || true)"
  apply_with_record 0
  if [ "$OPT_NO_HOOKS" != 1 ]; then install_hooks; fi
  info "Attached '$NAME'."
  # a block written by an older kit gains the docs-repo folder line
  if [ "$(cksum < "$WORK/.gitignore" 2>/dev/null || true)" != "$ignore_before" ]; then
    info "Its .gitignore block was updated (it now names the docs-repo folder); commit it: git add .gitignore && git commit -m \"aidlc-kit: update .gitignore block\""
  fi
}

# ---- status ----------------------------------------------------------------

load_existing_setup() { # -> WORK GITDIR DOCS NAME, record + modes; dies if not set up
  resolve_work "$OPT_DIR"
  read_state "$GITDIR" || die "$WORK is not set up; run 'aidlc-kit init' (or 'attach')"
  DOCS="$S_DOCS"; NAME="$S_PROJECT"
  [ -d "$DOCS" ] || die "docs repo $DOCS (from $(state_file "$GITDIR")) not found; run 'aidlc-kit attach --docs-repo <dir>'"
  read_record "$DOCS" "$NAME" || die "no record for '$NAME' in $DOCS"
  read_state "$GITDIR"   # again, now that the paths are known: picks up modes
}

cmd_status() {
  parse_common_opts "$@"
  reject_opts_for "${FUNCNAME[0]#cmd_}"
  load_config
  load_existing_setup
  echo "Project:      $NAME"
  echo "Working repo: $WORK"
  echo "Docs repo:    $DOCS/$NAME"
  local rc=0
  status_lines || rc=1
  if docs_is_git; then
    echo "Docs repo changes not committed: $(git -C "$DOCS" status --porcelain -- "$NAME" 2>/dev/null | wc -l | tr -d ' ')"
  fi
  return "$rc"
}

# status_lines -> one line per managed path (mode + health), then any
# artifacts a profile recognises that aren't managed. 1 if anything is wrong.
# Shared by `status` and `doctor`.
status_lines() {
  local i p w d mode health problems=0
  for i in "${!M_PATH[@]}"; do
    p="$(strip_slash "${M_PATH[$i]}")"; w="$WORK/$p"; d="$DOCS/$NAME/$p"
    mode="${M_MODE[$i]:-unknown}"
    case "$mode" in
      symlink|junction)
        if verify_link "${M_KIND[$i]}" "$w" "$d"; then health=ok
        elif [ -L "$w" ]; then health="BROKEN (link does not reach the docs repo)"; problems=1
        elif [ -e "$w" ]; then health="NOT A LINK (replaced by a real file/folder?)"; problems=1
        else health="MISSING (run 'aidlc-kit attach')"; problems=1; fi ;;
      copy)
        # dry-run the two-way sync to report what `save` would do — unless a
        # real sync just ran (SessionStart), whose results are reused
        SYNC_COPIED=0; SYNC_DELETED=0; SYNC_CONFLICTS=0
        if [ "${STATUS_USE_LAST_SYNC:-0}" = 1 ] && [ -n "${SYNC_LAST_CONFLICTS[$i]:-}" ]; then
          SYNC_CONFLICTS="${SYNC_LAST_CONFLICTS[$i]}"
        else
          DRY_RUN=1 QUIET=1 SYNC_SILENT=1 sync_copy_path "$i"
        fi
        if [ "$SYNC_CONFLICTS" -gt 0 ]; then
          health="$SYNC_CONFLICTS CONFLICT(S): changed on both sides since the last sync"; problems=1
        elif [ $((SYNC_COPIED + SYNC_DELETED)) -gt 0 ]; then
          health="ok (copy) — $((SYNC_COPIED + SYNC_DELETED)) change(s) to sync with 'aidlc-kit save'"
        elif [ -e "$w" ]; then
          health="ok (copy, in sync)"
        else
          health="ok (copy; nothing generated yet)"
        fi ;;
      *) health="not set up (run 'aidlc-kit attach')"; problems=1 ;;
    esac
    printf '  %-28s %-9s %s\n' "${M_PATH[$i]}" "$mode" "$health"
  done

  # artifacts a known profile would manage but this project doesn't (yet)
  load_profiles "$DOCS"
  local j q
  for j in "${!P_NAME[@]}"; do
    profile_matches "$j" "$WORK" || profile_in_docs "$j" "$DOCS/$NAME" || continue
    while IFS= read -r q; do
      [ -n "$q" ] || continue
      if managed_index "$q" >/dev/null; then continue; fi
      if [ -e "$WORK/$(strip_slash "$q")" ] || [ -L "$WORK/$(strip_slash "$q")" ]; then
        echo "  unmanaged: $q (profile ${P_NAME[$j]}) — add it with: aidlc-kit adopt $q"
        problems=1
      elif [ -e "$DOCS/$NAME/$(strip_slash "$q")" ]; then
        # e.g. set up with only --profile aidlc-v1 while the docs repo has graphify-out/
        echo "  unmanaged: $q (profile ${P_NAME[$j]}; in the docs repo, not linked here) — add it with: aidlc-kit adopt $q"
        problems=1
      fi
    done <<< "${P_PATH[$j]}"
  done
  [ "$problems" = 0 ]
}

# ---- detach ----------------------------------------------------------------

cmd_detach() {
  parse_common_opts "$@"
  reject_opts_for "${FUNCNAME[0]#cmd_}"
  load_config
  load_existing_setup
  info "Detaching '$NAME': links in $WORK are replaced by real copies; the docs repo is not changed."
  if [ "$DRY_RUN" = 1 ]; then info "(dry run — nothing changed)"; return 0; fi
  confirm "Proceed?" || die "aborted"
  local i p w d
  for i in "${!M_PATH[@]}"; do
    p="$(strip_slash "${M_PATH[$i]}")"; w="$WORK/$p"; d="$DOCS/$NAME/$p"
    if is_link_to "$w" "$d"; then   # also true for a dangling link to $d
      remove_link "$w"
      copy_in "${M_KIND[$i]}" "$w" "$d"
      info "  $p: link replaced with a copy"
    elif [ -L "$w" ]; then
      warn "$p links to $(readlink -- "$w"), not to the docs repo; left alone"
    else
      info "  $p: left as is"
    fi
  done
  uninstall_hooks
  write_block "$WORK/.gitignore"
  rm -f -- "$(state_file "$GITDIR")"
  info "Done. Those paths are now ordinary untracked files in the working repo."
}

# ---- adopt -------------------------------------------------------------------

# adopt PATH... — start managing more paths in an already set-up repo (e.g. a
# new tool version writes somewhere new). Paths are positional; the working
# repo is the current directory or --repo DIR.
cmd_adopt() {
  local args=() a
  while [ $# -gt 0 ]; do
    case "$1" in
      --docs-repo|--name|--path|--profile|--prefer|--link-mode|-m|--message|--trigger|--repo)
        args+=("$1" "${2:-}"); shift; [ $# -gt 0 ] && shift ;;
      -*) args+=("$1"); shift ;;
      *) OPT_PATHS+=("$1"); shift ;;
    esac
  done
  parse_common_opts ${args[@]+"${args[@]}"}
  reject_opts_for adopt
  [ "${#OPT_PATHS[@]}" -gt 0 ] || die "usage: aidlc-kit adopt <path>... (dirs end with '/'; see 'aidlc-kit status' for suggestions)"
  load_config
  load_existing_setup
  for a in "${OPT_PATHS[@]}"; do add_managed_path "$a"; done
  make_plan
  describe_plan
  if [ "$DRY_RUN" = 1 ]; then info "(dry run — nothing changed)"; return 0; fi
  if [ "$PLAN_CHANGES" = 1 ]; then confirm "Proceed?" || die "aborted"; fi
  apply_with_record 1
  info "Now managing: ${OPT_PATHS[*]}"
}

# ---- migrate-legacy ------------------------------------------------------------

# migrate-legacy --docs-repo D --name P — the old ai-dlc-workspace repo kept
# Graphify output under <P>/graphify/; the kit keeps every path where it is in
# the project, so graph.json and graphify-out/ move up one level. Works on the
# docs repo only; never overwrites, never commits.
LEGACY_GRAPHIFY_ITEMS=(graph.json graphify-out)

cmd_migrate_legacy() {
  parse_common_opts "$@"
  reject_opts_for migrate-legacy
  [ -z "$OPT_DIR" ] || die "migrate-legacy works on the docs repo only (--docs-repo, --name); it takes no working repo"
  load_config
  local docs="${OPT_DOCS:-$AIDLC_DOCS_REPO}" proj old item moves=() rest=""
  [ -n "$docs" ] || die "usage: aidlc-kit migrate-legacy --docs-repo <old ai-dlc-workspace repo> --name <project folder>"
  [ -n "$OPT_NAME" ] || die "pass --name <the project's folder in the docs repo>"
  validate_name "project name" "$OPT_NAME" "pass a valid one with --name"
  docs="$(expand_path "$docs")"
  [ -d "$docs" ] || die "docs repo not found: $docs"
  docs="$(real_dir "$docs")"
  proj="$docs/$OPT_NAME"; old="$proj/graphify"
  [ -d "$proj" ] || die "no folder '$OPT_NAME' in $docs"

  for item in "${LEGACY_GRAPHIFY_ITEMS[@]}"; do
    if [ -e "$old/$item" ] || [ -L "$old/$item" ]; then
      if [ -e "$proj/$item" ] || [ -L "$proj/$item" ]; then
        die "$proj/$item already exists; not overwriting it (keep one of the two, then re-run)"
      fi
      moves+=("$item")
    fi
  done

  # whatever else is in graphify/ stays, and so does graphify/ itself (a
  # .gitkeep, which kept the empty folder in git, doesn't count)
  if [ -d "$old" ]; then
    while IFS= read -r item; do
      case " ${moves[*]-} .gitkeep " in *" $item "*) ;; *) rest="${rest:+$rest, }$item" ;; esac
    done < <(ls -A -- "$old")
  fi

  local planned=1
  if [ "${#moves[@]}" -eq 0 ] && { [ ! -d "$old" ] || [ -n "$rest" ]; }; then
    planned=0
    info "Nothing to migrate: no graph.json or graphify-out/ under $old."
  else
    info "In $proj:"
    for item in ${moves[@]+"${moves[@]}"}; do info "  move graphify/$item  ->  $item"; done
    if [ -z "$rest" ]; then info "  remove the then-empty graphify/"; fi
    if [ "$DRY_RUN" = 1 ]; then
      info "(dry run — nothing changed)"
    else
      confirm "Proceed?" || die "aborted"
      for item in ${moves[@]+"${moves[@]}"}; do
        mv -- "$old/$item" "$proj/$item" || die "couldn't move $old/$item (is a file open?)"
      done
      if [ -z "$rest" ]; then rm -f -- "$old/.gitkeep"; rmdir -- "$old"; fi
    fi
  fi
  if [ -n "$rest" ]; then warn "graphify/ is kept: it also holds $rest"; fi

  info ""
  if [ "$planned" = 1 ]; then
    info "Next: commit the docs repo, then link the project to it:"
    info "  git -C $(sh_dquote "$docs") add -A -- $(sh_dquote "$OPT_NAME") && git -C $(sh_dquote "$docs") commit -m $(sh_dquote "$OPT_NAME: aidlc-kit layout")"
  else
    info "Next: link the project to it:"
  fi
  info "  cd <the project> && aidlc-kit init --docs-repo $(sh_dquote "$docs") --name $(sh_dquote "$OPT_NAME")"
}

# ---- skill -------------------------------------------------------------------

# skill install|uninstall — copy the aidlc-init Claude Code skill to your user
# skills folder, so /aidlc-init works in every project (inside this kit's own
# repo Claude Code finds it without installing).
cmd_skill() {
  local action="${1:-}" src dst
  [ $# -gt 0 ] && shift
  parse_common_opts "$@"
  reject_opts_for skill
  src="$KIT_ROOT/.claude/skills/aidlc-init"
  dst="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/aidlc-init"
  case "$action" in
    install)
      [ -f "$src/SKILL.md" ] || die "skill source missing: $src"
      if [ -e "$dst" ] && ! grep -q '^name: aidlc-init$' "$dst/SKILL.md" 2>/dev/null; then
        die "$dst exists and isn't the aidlc-init skill; not overwriting it"
      fi
      mkdir -p -- "$dst"
      cp -R -- "$src/." "$dst/"
      info "Installed the aidlc-init skill to $dst (use /aidlc-init in Claude Code)." ;;
    uninstall)
      if [ ! -e "$dst" ]; then info "The aidlc-init skill isn't installed in $dst."; return 0; fi
      grep -q '^name: aidlc-init$' "$dst/SKILL.md" 2>/dev/null || die "$dst isn't the aidlc-init skill; not removing it"
      rm -rf -- "$dst"
      info "Removed the aidlc-init skill from $dst." ;;
    *) die "usage: aidlc-kit skill install|uninstall" ;;
  esac
}
