# shellcheck shell=bash disable=SC2034,SC2153,SC2317
# (file-wide: globals and functions here are used by the files that source this one)
# Hooks (docs/DESIGN.md §8): git post-commit / pre-push and Claude Code
# SessionStart / Stop / SessionEnd call `aidlc-kit hook <event>`, which never
# fails or blocks the user's action. Also: `hooks install|uninstall`, `doctor`.

HOOK_EVENTS_ALL="session-start stop session-end post-commit pre-push"

# enabled_events -> the events selected by AIDLC_HOOKS, space-separated.
# Accepts event names, the aliases `claude` and `git`, `all`, or `none`.
enabled_events() {
  local item out=""
  for item in ${AIDLC_HOOKS//,/ }; do
    case "$item" in
      all) out="$out $HOOK_EVENTS_ALL" ;;
      none) ;;
      claude) out="$out session-start stop session-end" ;;
      git) out="$out post-commit pre-push" ;;
      session-start|stop|session-end|post-commit|pre-push) out="$out $item" ;;
      *) die "AIDLC_HOOKS: unknown hook '$item' (use: $HOOK_EVENTS_ALL, claude, git, all, none)" ;;
    esac
  done
  local e uniq=""
  for e in $HOOK_EVENTS_ALL; do
    case " $out " in *" $e "*) uniq="$uniq $e" ;; esac
  done
  echo "${uniq# }"
}

event_enabled() { case " $(enabled_events) " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
claude_events_enabled() { event_enabled session-start || event_enabled stop || event_enabled session-end; }

# Bumped whenever what we install changes (commands, async/timeout options),
# so doctor can tell an up-to-date hook from one left by an older kit.
HOOK_FORMAT=2   # 2: pre-push runs the rest of the hook as a child, not via an EXIT trap

# The command every hook runs: absolute path to this kit, quoted for sh.
kit_cmd() { printf 'bash %s' "$(sh_dquote "$KIT_ROOT/bin/aidlc-kit")"; }

hook_cmd() { echo "$(kit_cmd) hook $1 --hook-format $HOOK_FORMAT"; }   # event

# git_path_abs NAME -> absolute `git rev-parse --git-path NAME` for the working
# repo (honours core.hooksPath for "hooks")
git_path_abs() {
  local d
  d="$(git -C "$WORK" rev-parse --git-path "$1")"
  case "$d" in /*|[A-Za-z]:[\\/]*) ;; *) d="$WORK/$d" ;; esac
  echo "$d"
}

# ---- git hooks -----------------------------------------------------------------

git_hooks_dir() { git_path_abs hooks; }

git_hook_block() { # event -> the managed block for that git hook
  echo "$GITIGNORE_BEGIN"
  case "$1" in
    post-commit)
      # background + all fds closed: the commit returns immediately
      echo "$(hook_cmd post-commit) --repo \"\$(pwd)\" </dev/null >/dev/null 2>&1 &" ;;
    pre-push)
      # Run the rest of this hook first, as a child process (the variable
      # stops the recursion), and push the docs repo only if it succeeded:
      # the user's own checks may still reject the push. Unlike an EXIT trap
      # this also holds when the hook `exec`s another program (pre-commit's
      # generated hooks do) or sets traps of its own. The child gets stdin
      # (the refs being pushed).
      echo "if [ -z \"\${AIDLC_KIT_PRE_PUSH_INNER:-}\" ]; then"
      echo "  AIDLC_KIT_PRE_PUSH_INNER=1 \"\$0\" \"\$@\"; aidlc_kit_rc=\$?"
      echo "  if [ \"\$aidlc_kit_rc\" -eq 0 ]; then $(hook_cmd pre-push) --repo \"\$(pwd)\" </dev/null || true; fi"
      echo "  exit \"\$aidlc_kit_rc\""
      echo "fi" ;;
  esac
  echo "$GITIGNORE_END"
}

# shell_hook FILE -> 0 if FILE is a shell script we can add lines to (or has
# no shebang at all, which git runs with sh). A Python/Node/... hook would be
# broken by shell lines.
shell_hook() {
  local first interp
  first="$(head -n 1 -- "$1")"
  case "$first" in '#!'*) ;; *) return 0 ;; esac
  # shellcheck disable=SC2086  # split "#!/usr/bin/env bash -e" into words
  set -- ${first#\#!}
  interp="${1##*/}"
  if [ "$interp" = env ]; then
    shift
    if [ "${1:-}" = -S ]; then shift; fi
    interp="${1##*/}"
  fi
  case "$interp" in sh|bash|dash|zsh|ksh|ash|mksh) return 0 ;; *) return 1 ;; esac
}

# hook_file_editable FILE -> 1 if FILE lives in the working tree (husky,
# pre-commit-managed or committed hooks): editing it would change files the
# project tracks, so we print what to add instead.
hook_file_editable() {
  local dir dir_real
  dir="$(dirname -- "$1")"
  mkdir -p -- "$dir"
  dir_real="$(real_dir "$dir")/"
  # .git/hooks is physically inside the working tree but not part of it
  case "$dir_real" in "$(real_dir "$GITDIR")"/*) return 0 ;; esac
  case "$dir_real" in "$(real_dir "$WORK")"/*) return 1 ;; esac
  return 0
}

# hook_source_file EVENT -> the file people edit for this hook. Husky v9 points
# core.hooksPath at its generated, gitignored .husky/_/ and runs .husky/EVENT
# from there; otherwise it's the hook file itself.
hook_source_file() {
  local dir
  dir="$(git_hooks_dir)"; dir="${dir%/}"
  case "$dir" in
    */.husky/_) echo "${dir%/_}/$1" ;;
    *) echo "$dir/$1" ;;
  esac
}

# hook_snippet EVENT -> one line for a hook file the project tracks: no
# absolute path (everyone's kit lives elsewhere), and a no-op for teammates
# without aidlc-kit on PATH or whose clone isn't set up.
hook_snippet() {
  case "$1" in
    post-commit) echo "if command -v aidlc-kit >/dev/null 2>&1; then aidlc-kit hook post-commit --hook-format $HOOK_FORMAT </dev/null >/dev/null 2>&1 & fi" ;;
    pre-push) echo "if command -v aidlc-kit >/dev/null 2>&1; then aidlc-kit hook pre-push --hook-format $HOOK_FORMAT </dev/null || true; fi" ;;
  esac
}

# has_hook_snippet FILE EVENT -> 0 if a line that isn't commented out runs it
has_hook_snippet() { [ -f "$1" ] && grep -qE "^[^#]*aidlc-kit hook $2 " "$1"; }

install_git_hook() { # event
  local event="$1" file tmp src
  file="$(git_hooks_dir)/$event"
  if ! hook_file_editable "$file"; then
    src="$(hook_source_file "$event")"
    if has_hook_snippet "$src" "$event"; then info "  git $event hook: found in $src"; return 0; fi
    warn "git runs its $event hook from inside the working repo (husky / committed hooks), so it isn't edited. Add this line at the end of $src, after your own checks (it does nothing where aidlc-kit isn't on PATH):"
    echo "    $(hook_snippet "$event")" >&2
    return 0
  fi
  if [ -f "$file" ] && ! shell_hook "$file"; then
    warn "$file is not a shell script ($(head -n 1 -- "$file")); not editing it. Have it run this command (with </dev/null) on success:"
    echo "    $(hook_cmd "$event") --repo <this repo>" >&2
    return 0
  fi
  tmp="$file.aidlc-kit.tmp"
  if [ -f "$file" ]; then
    # drop an older copy of our block, then insert the new one right after the
    # shebang, so it runs even if the user's hook ends with `exit 0`
    if ! block_lines outside "$file" > "$tmp.body"; then
      rm -f -- "$tmp.body"
      warn "$file has an aidlc-workspace-kit block without its end line; not editing it (restore the '$GITIGNORE_END' line)"
      return 0
    fi
    {
      if head -n 1 "$tmp.body" | grep -q '^#!'; then
        head -n 1 "$tmp.body"; git_hook_block "$event"; tail -n +2 "$tmp.body"
      else
        echo '#!/bin/sh'; git_hook_block "$event"; cat "$tmp.body"
      fi
    } > "$tmp"
    rm -f -- "$tmp.body"
  else
    { echo '#!/bin/sh'; echo "# created by aidlc-workspace-kit"; git_hook_block "$event"; } > "$tmp"
  fi
  chmod +x "$tmp"
  mv -- "$tmp" "$file"
  info "  git $event hook installed"
}

uninstall_git_hook() { # event
  local event="$1" file tmp
  file="$(git_hooks_dir)/$event"
  # nothing of ours anywhere: done (and no hooks folder gets created by asking)
  if [ ! -f "$file" ] && ! has_hook_snippet "$(hook_source_file "$event")" "$event"; then return 0; fi
  if ! hook_file_editable "$file"; then
    if has_hook_snippet "$(hook_source_file "$event")" "$event"; then
      warn "$(hook_source_file "$event") runs aidlc-kit; remove that line yourself (it's part of the project)"
    elif [ -f "$file" ] && grep -qF "$GITIGNORE_BEGIN" "$file"; then
      warn "$file is inside the working repo; remove the aidlc-workspace-kit block yourself"
    fi
    return 0
  fi
  if [ ! -f "$file" ] || ! grep -qF "$GITIGNORE_BEGIN" "$file"; then return 0; fi
  tmp="$file.aidlc-kit.tmp"
  if ! block_lines outside "$file" > "$tmp"; then
    rm -f -- "$tmp"
    warn "$file has an aidlc-workspace-kit block without its end line; remove the block yourself"
    return 0
  fi
  # a hook we created and that now holds nothing else is removed entirely
  if ! grep -qv -e '^#!' -e '^# created by aidlc-workspace-kit$' -e '^[[:space:]]*$' "$tmp"; then
    rm -f -- "$tmp" "$file"
  else
    chmod +x "$tmp"; mv -- "$tmp" "$file"
  fi
  info "  git $event hook removed"
}

git_hook_installed() { # event -> 0 if our current block (or, in a hook the project tracks, the snippet) is there
  local file
  file="$(git_hooks_dir)/$1"
  if [ -f "$file" ] && grep -qF "$(hook_cmd "$1")" "$file"; then return 0; fi
  has_hook_snippet "$(hook_source_file "$1")" "$1" && ! hook_file_editable "$file"
}

# ---- Claude Code hooks (.claude/settings.local.json) -----------------------------

claude_settings() { echo "$WORK/.claude/settings.local.json"; }

json_str() { # string -> JSON string literal
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# Our hook entries as a JSON object {Event: [group], ...} for enabled events.
claude_hooks_json() {
  local first=1 e name handler
  printf '{'
  for e in session-start stop session-end; do
    event_enabled "$e" || continue
    case "$e" in
      session-start) name=SessionStart; handler="\"timeout\": 60" ;;
      stop)          name=Stop;         handler="\"async\": true" ;;  # never slows a turn down
      session-end)   name=SessionEnd;   handler="\"timeout\": 30" ;;  # default budget is 1.5 s
    esac
    if [ "$first" = 0 ]; then printf ','; fi
    first=0
    printf '%s: [{"hooks": [{"type": "command", "command": %s, %s}]}]' \
      "$(json_str "$name")" "$(json_str "$(hook_cmd "$e")")" "$handler"
  done
  printf '}'
}

# json_tool -> jq | python command | none. AIDLC_KIT_JSON_TOOL forces one
# (tests). A `python3` that is the Windows Store stub doesn't count.
json_tool() {
  if [ -n "${AIDLC_KIT_JSON_TOOL:-}" ]; then echo "$AIDLC_KIT_JSON_TOOL"; return; fi
  if command -v jq >/dev/null 2>&1; then echo jq; return; fi
  local py
  for py in python3 python; do
    if command -v "$py" >/dev/null 2>&1 && "$py" -c 'import json' >/dev/null 2>&1; then echo "$py"; return; fi
  done
  echo none
}

# merge_claude_settings FILE OURS_JSON -> rewrite FILE: our previous entries
# removed (any handler whose command runs `aidlc-kit ... hook`), OURS added,
# everything else kept. Returns 1 if no JSON tool is available.
merge_claude_settings() {
  local file="$1" ours="$2" tool out ours_file
  tool="$(json_tool)"
  out="$file.aidlc-kit.tmp"
  # passed as files, not arguments: MSYS rewrites path-like arguments to
  # native Windows programs, which could mangle the JSON
  ours_file="$(kit_tmp)/hooks.json"
  printf '%s\n' "$ours" > "$ours_file"
  case "$tool" in
    jq)
      MSYS_NO_PATHCONV=1 jq --slurpfile ours "$(native_path "$ours_file")" '
        def mine: (.command // "" | tostring) | (contains("aidlc-kit") and contains(" hook "));
        .hooks = ((.hooks // {})
          | with_entries(.value |= (map(.hooks |= map(select(mine | not))) | map(select((.hooks // []) | length > 0))))
          | with_entries(select(.value | length > 0)))
        | reduce ($ours[0] | to_entries[]) as $e (.; .hooks[$e.key] = ((.hooks[$e.key] // []) + $e.value))
        | if (.hooks | length) == 0 then del(.hooks) else . end' "$(native_path "$file")" > "$out" ;;
    none) return 1 ;;
    *)
      MSYS_NO_PATHCONV=1 "$tool" - "$(native_path "$file")" "$(native_path "$ours_file")" "$(native_path "$out")" <<'PY'
import json, sys
path, ours_path, out_path = sys.argv[1:4]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
with open(ours_path, encoding="utf-8") as f:
    ours = json.load(f)
def mine(h):
    c = str(h.get("command", ""))
    return "aidlc-kit" in c and " hook " in c
hooks = {}
for event, groups in (data.get("hooks") or {}).items():
    kept = []
    for g in groups:
        g = dict(g)
        g["hooks"] = [h for h in g.get("hooks", []) if not mine(h)]
        if g["hooks"]:
            kept.append(g)
    if kept:
        hooks[event] = kept
for event, groups in ours.items():
    hooks.setdefault(event, []).extend(groups)
if hooks:
    data["hooks"] = hooks
else:
    data.pop("hooks", None)
with open(out_path, "w", encoding="utf-8", newline="\n") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
      ;;
  esac || { rm -f -- "$out"; die "couldn't update $file (is it valid JSON?)"; }
  mv -- "$out" "$file"
}

# settings.local.json is meant to be per machine; if a project commits it
# anyway, our absolute kit path must not end up in everyone's copy.
claude_settings_tracked() {
  git -C "$WORK" ls-files --error-unmatch -- .claude/settings.local.json >/dev/null 2>&1
}

install_claude_hooks() {
  local file ours
  file="$(claude_settings)"
  ours="$(claude_hooks_json)"
  if claude_settings_tracked; then
    warn "$file is tracked by git in this project; not editing it (it would commit this machine's paths). Add to its \"hooks\" on your machine only, or untrack it:"
    printf '%s\n' "$ours" | sed 's/^/    /' >&2
    return 0
  fi
  mkdir -p -- "$(dirname -- "$file")"
  ensure_locally_ignored ".claude/settings.local.json"
  if [ ! -f "$file" ]; then
    printf '{\n  "hooks": %s\n}\n' "$ours" > "$file"
  elif ! merge_claude_settings "$file" "$ours"; then
    warn "no JSON tool (jq or python) found to edit $file; add this to its \"hooks\" yourself:"
    printf '%s\n' "$ours" | sed 's/^/    /' >&2
    return 0
  fi
  info "  Claude Code hooks installed ($(enabled_events | tr ' ' '\n' | grep -E '^(session-start|stop|session-end)$' | paste -sd ',' -))"
}

uninstall_claude_hooks() {
  local file
  file="$(claude_settings)"
  if [ ! -f "$file" ] || ! grep -q 'aidlc-kit' "$file"; then return 0; fi
  if claude_settings_tracked; then
    warn "$file is tracked by git; remove the aidlc-kit hook entries from it yourself"
    return 0
  fi
  if ! merge_claude_settings "$file" '{}'; then
    warn "no JSON tool (jq or python) found; remove the aidlc-kit entries from $file yourself"
    return 0
  fi
  info "  Claude Code hooks removed"
}

claude_hook_installed() { # event -> 0 if settings.local.json runs our current command for it
  local file
  file="$(claude_settings)"
  [ -f "$file" ] && grep -qF "$(json_str "$(hook_cmd "$1")")" "$file"
}

# native_path PATH -> a path native Windows tools (python.exe, jq.exe) can open.
native_path() {
  if [ "$IS_WINDOWS" = 1 ] && command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else echo "$1"; fi
}

# Keep a per-machine file out of `git status` without touching the project's
# .gitignore: .git/info/exclude is local to this clone.
ensure_locally_ignored() {
  git -C "$WORK" check-ignore -q -- "$1" 2>/dev/null && return 0
  local exclude
  exclude="$(git_path_abs info/exclude)"
  mkdir -p -- "$(dirname -- "$exclude")"
  printf '/%s\n' "$1" >> "$exclude"
}

# ---- install / uninstall ---------------------------------------------------------

install_hooks() {
  local e
  for e in $HOOK_EVENTS_ALL; do
    case "$e" in
      post-commit|pre-push)
        if event_enabled "$e"; then install_git_hook "$e"; else uninstall_git_hook "$e"; fi ;;
    esac
  done
  if claude_events_enabled; then
    install_claude_hooks
  else
    uninstall_claude_hooks
  fi
}

uninstall_hooks() {
  uninstall_git_hook post-commit
  uninstall_git_hook pre-push
  uninstall_claude_hooks
}

cmd_hooks() { # hooks install|uninstall [dir] [opts]
  local action="${1:-}"
  [ $# -gt 0 ] && shift
  parse_common_opts "$@"
  reject_opts_for hooks
  load_config
  load_existing_setup
  case "$action" in
    install) info "Installing hooks for '$NAME' ($(enabled_events)):"; install_hooks ;;
    uninstall) info "Removing hooks for '$NAME':"; uninstall_hooks ;;
    *) die "usage: aidlc-kit hooks install|uninstall [<working-repo-dir>]" ;;
  esac
}

# ---- the hook runner ---------------------------------------------------------------

hook_log() { echo "$GITDIR/aidlc-kit/log"; }

# cmd_hook EVENT [opts] — what every installed hook runs. Always exits 0: a
# problem here must never block a commit, a push, or a Claude Code turn. The
# details go to .git/aidlc-kit/log; for session-start, problems are printed
# to stdout, which Claude Code adds to the session's context.
cmd_hook() {
  local event="${1:-}" rc log out
  [ $# -gt 0 ] && shift
  case " $HOOK_EVENTS_ALL " in *" $event "*) ;; *) echo "aidlc-kit: unknown hook event '$event'" >&2; return 0 ;; esac
  # Git exports GIT_DIR, GIT_INDEX_FILE, ... to hooks; left set, they would
  # make `git -C <docs repo>` operate on the working repo instead.
  # shellcheck disable=SC2046
  unset $(git rev-parse --local-env-vars 2>/dev/null) 2>/dev/null || true
  parse_common_opts "$@"
  OPT_DIR="${OPT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
  out="$(kit_tmp)/hook-out"
  # The work runs in a subshell so no failure can escape. It must NOT be part
  # of an `||`/`&&`/`if` (that would switch `set -e` off for everything inside
  # it and let failed copies or commits carry on), hence set +e around it.
  # fd 3 = what session-start wants Claude to see.
  set +e
  ( hook_dispatch "$event" ) 3>&1 > "$out" 2>&1
  rc=$?
  set -e
  if GITDIR="$(git -C "$OPT_DIR" rev-parse --absolute-git-dir 2>/dev/null)"; then
    log="$(hook_log)"
    if [ -d "$(dirname -- "$log")" ]; then
      { printf '%s %s exit=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$event" "$rc"; sed 's/^/  /' "$out"; } >> "$log"
      # keep the log small
      if [ "$(wc -l < "$log")" -gt 2000 ]; then tail -n 1000 "$log" > "$log.tmp" && mv -- "$log.tmp" "$log"; fi
    fi
  fi
  if [ "$event" = pre-push ]; then grep -E '^(  pushed|aidlc-kit: )' "$out" >&2 || true; fi
  return 0
}

hook_dispatch() { # event (options already parsed by cmd_hook)
  local event="$1"
  # runs in a subshell, which doesn't inherit the EXIT trap: release the lock here
  trap release_lock EXIT
  QUIET=0; ASSUME_YES=1
  load_config
  resolve_work "$OPT_DIR"
  read_state "$GITDIR" || return 0          # not set up here: nothing to do
  event_enabled "$event" || return 0
  load_existing_setup
  case "$event" in
    session-start)
      if acquire_lock; then
        repair_missing_links
        sync_copy_paths
        release_lock
        STATUS_USE_LAST_SYNC=1               # doctor reuses this sync's results
      else
        echo "another aidlc-kit process holds the lock; link repair and sync skipped this time"
      fi
      doctor_report quiet >&3 || true ;;
    post-commit)
      # every commit replayed by a rebase/cherry-pick/am fires post-commit:
      # skip those, the next ordinary commit or turn catches up
      if repo_busy "$GITDIR"; then echo "skipped: rebase/cherry-pick/am in progress"; return 0; fi
      OPT_TRIGGER="$event"
      if [ "$AIDLC_AUTO_COMMIT" = off ]; then SAVE_NO_COMMIT=1; fi
      save_flow ;;
    stop|session-end)
      OPT_TRIGGER="$event"
      if [ "$AIDLC_AUTO_COMMIT" = off ]; then SAVE_NO_COMMIT=1; fi
      save_flow ;;
    pre-push)
      OPT_TRIGGER="$event"
      if [ "$AIDLC_AUTO_COMMIT" = off ]; then SAVE_NO_COMMIT=1; fi
      if [ "$AIDLC_AUTO_PUSH" = on ] && [ "${SAVE_NO_COMMIT:-0}" != 1 ]; then OPT_PUSH=1; fi
      save_flow ;;
  esac
}

# ---- doctor ------------------------------------------------------------------------

# doctor_report [quiet] -> prints findings; returns 1 if any problem.
# quiet: problems only, one line each, prefixed "aidlc-kit:" (for SessionStart).
doctor_report() {
  local mode="${1:-}" problems=0 line e
  say_ok()      { [ "$mode" = quiet ] || echo "  ok    $*"; }
  say_warn()    { [ "$mode" = quiet ] || echo "  WARN  $*"; }
  say_problem() { if [ "$mode" = quiet ]; then echo "aidlc-kit: $*"; else echo "  FAIL  $*"; fi; problems=1; }

  # managed paths, copy-mode sync state, unmanaged artifacts
  while IFS= read -r line; do
    case "$line" in
      *"BROKEN"*|*"NOT A LINK"*|*"MISSING"*|*"CONFLICT"*|*"not set up"*|*"unmanaged:"*)
        say_problem "${line#"${line%%[![:space:]]*}"}" ;;
    esac
  done < <(status_lines)
  [ "$problems" = 1 ] || say_ok "managed paths healthy"

  if docs_is_git; then
    if [ -z "$(git -C "$DOCS" config user.email 2>/dev/null)" ]; then
      say_problem "the docs repo has no git user.email; commits from hooks will fail (git -C \"$DOCS\" config user.email you@example.com)"
    else
      say_ok "docs repo is a git repo with an identity"
    fi
    if event_enabled pre-push && [ "$AIDLC_AUTO_PUSH" = on ]; then
      if git -C "$DOCS" rev-parse -q --verify '@{upstream}' >/dev/null 2>&1; then
        say_ok "docs repo has an upstream (pushed on 'git push')"
      else
        say_warn "docs repo has no upstream, so 'git push' won't push it (git -C \"$DOCS\" push -u origin HEAD)"
      fi
    fi
  else
    say_warn "the docs repo is not a git repo: artifacts are kept but not versioned"
  fi

  for e in $(enabled_events); do
    case "$e" in
      post-commit|pre-push) if git_hook_installed "$e"; then say_ok "git $e hook"; else say_problem "git $e hook not installed or outdated (aidlc-kit hooks install)"; fi ;;
      *) if claude_hook_installed "$e"; then say_ok "Claude Code $e hook"; else say_problem "Claude Code $e hook not installed or outdated (aidlc-kit hooks install)"; fi ;;
    esac
  done

  local base
  base="$(docs_git_dir)" || base="$DOCS/.aidlc-kit"
  LOCK_DIR="$base/aidlc-kit.lock"
  if [ -d "$LOCK_DIR" ] && lock_is_stale; then say_warn "a stale lock from a crashed run is present; the next save clears it"; fi
  LOCK_DIR=""

  return "$problems"
}

cmd_doctor() {
  parse_common_opts "$@"
  reject_opts_for doctor
  load_config
  load_existing_setup
  echo "aidlc-kit doctor — '$NAME' ($WORK -> $DOCS/$NAME)"
  if doctor_report; then echo "All good."; else echo "Problems found (see FAIL lines)."; return 1; fi
}
