# shellcheck shell=bash disable=SC2034,SC2153,SC2317
# (file-wide: globals and functions here are used by the files that source this one)

# Profiles: data files describing which paths a tool writes and how to detect
# it. See docs/DESIGN.md §4. Stored in parallel arrays (bash 3.2 has no
# associative arrays); list-valued fields are newline-separated.

P_NAME=(); P_DESC=(); P_DETECT=(); P_PATH=(); P_EXCLUDE=(); P_FILE=()

profile_index() { # name -> index on stdout, 1 if absent
  local i
  for i in "${!P_NAME[@]}"; do
    [ "${P_NAME[$i]}" = "$1" ] && { echo "$i"; return 0; }
  done
  return 1
}

append_line() { # "existing" "new" -> joined with newline
  if [ -z "$1" ]; then echo "$2"; else printf '%s\n%s\n' "$1" "$2"; fi
}

# load_profile_file FILE — later files override earlier ones with the same name.
load_profile_file() {
  local file="$1" line rc name="" desc="" detect="" paths="" excludes="" version=1
  while IFS= read -r line || [ -n "$line" ]; do
    rc=0; parse_kv_line "$line" || rc=$?
    [ "$rc" = 1 ] && continue
    [ "$rc" = 2 ] && die "$file: expected KEY=VALUE, got: $line"
    case "$KV_KEY" in
      version) version="$KV_VALUE" ;;
      name) name="$KV_VALUE" ;;
      description) desc="$KV_VALUE" ;;
      detect|path|exclude)
        local pmode=literal
        if [ "$KV_KEY" = exclude ]; then pmode=glob; fi
        is_valid_managed_path "$KV_VALUE" "$pmode" || die "$file: invalid $KV_KEY '$KV_VALUE' (must be a relative path without '..'; wildcards only in exclude=)"
        case "$KV_KEY" in
          detect) detect="$(append_line "$detect" "$KV_VALUE")" ;;
          path) paths="$(append_line "$paths" "$KV_VALUE")" ;;
          exclude) excludes="$(append_line "$excludes" "$KV_VALUE")" ;;
        esac
        ;;
      *) warn "$file: ignoring unknown key '$KV_KEY'" ;;
    esac
  done < "$file"

  [ "$version" = 1 ] || die "$file: profile format version $version is newer than this kit supports (1); update aidlc-workspace-kit"
  [ -n "$name" ] || die "$file: missing name="
  validate_name "profile name in $file:" "$name"
  [ -n "$paths" ] || die "$file: profile '$name' has no path= entries"
  [ -n "$detect" ] || detect="$paths"

  local i
  if i="$(profile_index "$name")"; then :; else i="${#P_NAME[@]}"; fi
  P_NAME[i]="$name"; P_DESC[i]="$desc"; P_DETECT[i]="$detect"
  P_PATH[i]="$paths"; P_EXCLUDE[i]="$excludes"; P_FILE[i]="$file"
}

# load_profiles [docs-repo] — built-ins, then user, then AIDLC_PROFILES_DIR,
# then the docs repo's shared profiles.
load_profiles() {
  local docs="${1:-}" dir f
  for dir in \
    "$KIT_ROOT/profiles" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/aidlc-kit/profiles" \
    "${AIDLC_PROFILES_DIR:-}" \
    "${docs:+$docs/.aidlc-kit/profiles}"; do
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then continue; fi
    for f in "$dir"/*.profile; do
      if [ -f "$f" ]; then load_profile_file "$f"; fi
    done
  done
  return 0
}

# profile_in_docs I DIR -> 0 if DIR (the project's folder in the docs repo)
# already holds one of the profile's paths: a fresh clone or a migrated
# project gets back everything it had, not only what the project itself shows.
profile_in_docs() {
  local i="$1" dir="$2" p
  [ -d "$dir" ] || return 1
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -e "$dir/$(strip_slash "$p")" ]; then return 0; fi
  done <<< "${P_PATH[$i]}"
  return 1
}

# profile_matches INDEX WORKDIR -> 0 if any detect path exists.
profile_matches() {
  local i="$1" work="$2" d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ -e "$work/$(strip_slash "$d")" ] || [ -L "$work/$(strip_slash "$d")" ]; then
      return 0
    fi
  done <<< "${P_DETECT[$i]}"
  return 1
}
