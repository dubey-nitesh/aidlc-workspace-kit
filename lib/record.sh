# shellcheck shell=bash disable=SC2034,SC2153,SC2317
# (file-wide: globals and functions here are used by the files that source this one)

# Project record (in the docs repo, shared) and machine state (in the working
# repo's .git/, never committed). See docs/DESIGN.md §5.

RECORD_VERSION=1

# Managed paths for the current project, parallel arrays.
M_PATH=(); M_KIND=(); M_MODE=()
R_PROFILES=""; R_EXCLUDES=""

record_file() { echo "$1/$2/.aidlc-kit/record"; }    # docs project
state_file()  { echo "$1/aidlc-kit/state"; }          # git-dir

managed_index() { # path -> index
  local i
  for i in "${!M_PATH[@]}"; do
    [ "${M_PATH[$i]}" = "$1" ] && { echo "$i"; return 0; }
  done
  return 1
}

add_managed_path() { # path [mode]
  local p="$1"
  is_valid_managed_path "$p" || die "invalid path '$p' (must be relative, without '..' or wildcards)"
  managed_index "$p" >/dev/null && return 0
  local i="${#M_PATH[@]}"
  M_PATH[i]="$p"; M_KIND[i]="$(path_kind "$p")"; M_MODE[i]="${2:-}"
}

# read_record DOCS PROJECT -> fills M_PATH/M_KIND, R_PROFILES, R_EXCLUDES. 1 if absent.
read_record() {
  local file line rc version=""
  file="$(record_file "$1" "$2")"
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    rc=0; parse_kv_line "$line" || rc=$?
    [ "$rc" = 1 ] && continue
    [ "$rc" = 2 ] && die "$file: expected KEY=VALUE, got: $line"
    case "$KV_KEY" in
      version) version="$KV_VALUE" ;;
      project) ;;
      profile) R_PROFILES="$(append_line "$R_PROFILES" "$KV_VALUE")" ;;
      path) add_managed_path "${KV_VALUE%%|*}" ;;
      exclude)
        is_valid_managed_path "$KV_VALUE" glob || die "$file: invalid exclude '$KV_VALUE'"
        R_EXCLUDES="$(append_line "$R_EXCLUDES" "$KV_VALUE")" ;;
      *) warn "$file: ignoring unknown key '$KV_KEY'" ;;
    esac
  done < "$file"
  [ "$version" = "$RECORD_VERSION" ] || die "$file: record version '$version' is not supported by this kit (expects $RECORD_VERSION)"
  return 0
}

write_record() { # DOCS PROJECT
  local file p e
  file="$(record_file "$1" "$2")"
  mkdir -p "$(dirname "$file")"
  {
    echo "# Managed by aidlc-workspace-kit. Edit with 'aidlc-kit adopt' or by hand."
    echo "version=$RECORD_VERSION"
    echo "project=$2"
    while IFS= read -r p; do if [ -n "$p" ]; then echo "profile=$p"; fi; done <<< "$R_PROFILES"
    local i
    for i in "${!M_PATH[@]}"; do echo "path=${M_PATH[$i]}|${M_KIND[$i]}"; done
    while IFS= read -r e; do if [ -n "$e" ]; then echo "exclude=$e"; fi; done <<< "$R_EXCLUDES"
  } > "$file"
}

# read_state GITDIR -> sets S_DOCS, S_PROJECT, and M_MODE for paths already in
# M_PATH (call it again after read_record to pick up modes). 1 if absent.
read_state() {
  local file line rc p i
  file="$(state_file "$1")"
  [ -f "$file" ] || return 1
  S_DOCS=""; S_PROJECT=""
  while IFS= read -r line || [ -n "$line" ]; do
    rc=0; parse_kv_line "$line" || rc=$?
    [ "$rc" = 0 ] || continue
    case "$KV_KEY" in
      docs_repo) S_DOCS="$KV_VALUE" ;;
      project) S_PROJECT="$KV_VALUE" ;;
      mode)
        p="${KV_VALUE%%|*}"
        if i="$(managed_index "$p")"; then M_MODE[i]="${KV_VALUE#*|}"; fi
        ;;
    esac
  done < "$file"
  return 0
}

write_state() { # GITDIR DOCS PROJECT
  local file i
  file="$(state_file "$1")"
  mkdir -p "$(dirname "$file")"
  {
    echo "version=1"
    echo "docs_repo=$2"
    echo "project=$3"
    for i in "${!M_PATH[@]}"; do
      if [ -n "${M_MODE[$i]}" ]; then echo "mode=${M_PATH[$i]}|${M_MODE[$i]}"; fi
    done
  } > "$file"
}
