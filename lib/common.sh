# shellcheck shell=bash disable=SC2034,SC2153,SC2317
# (file-wide: globals and functions here are used by the files that source this one)

# Shared helpers: output, platform detection, configuration, validation.

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die()  { echo "aidlc-kit: error: $*" >&2; exit 1; }
warn() { echo "aidlc-kit: warning: $*" >&2; }
info() { [ "${QUIET:-0}" = 1 ] || echo "$*"; }

case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;;
  *) IS_WINDOWS=0 ;;
esac

# ---- prompts ---------------------------------------------------------------

# confirm "question" -> 0 if yes. Honors ASSUME_YES; refuses without a terminal.
confirm() {
  [ "${ASSUME_YES:-0}" = 1 ] && return 0
  [ -t 0 ] || die "$1 — re-run with --yes to confirm non-interactively"
  local answer
  printf '%s [y/N] ' "$1"
  read -r answer
  case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---- configuration ---------------------------------------------------------
# Precedence: CLI flag > environment > config file > default. The config file
# is KEY=VALUE lines, PARSED (never sourced), so it cannot execute code.

KNOWN_KEYS="AIDLC_DOCS_REPO AIDLC_LINK_MODE AIDLC_AUTO_COMMIT AIDLC_AUTO_PUSH AIDLC_HOOKS AIDLC_PROFILES_DIR AIDLC_TARGET AIDLC_RULES_DIR"
# Settings of the removed sync.sh / init-project.sh scripts: rejected with a
# pointer to what replaced them.
LEGACY_KEYS="AIDLC_PROJECTS_ROOT AIDLC_DATA_DIR AIDLC_DOCS_NAME AIDLC_GRAPHIFY AIDLC_GRAPH_FILE AIDLC_GRAPH_OUT AIDLC_GITIGNORE AIDLC_PROJECT_MAP"

# legacy_key_hint KEY -> what replaced a setting of the removed sync.sh /
# init-project.sh scripts
legacy_key_hint() {
  case "$1" in
    AIDLC_DATA_DIR) echo "use AIDLC_DOCS_REPO (the docs repo)" ;;
    AIDLC_PROJECT_MAP) echo "use --name on init/attach (it is remembered per clone)" ;;
    AIDLC_PROJECTS_ROOT) echo "no longer needed: run aidlc-kit inside the project, or pass --repo" ;;
    AIDLC_DOCS_NAME|AIDLC_GRAPH_FILE|AIDLC_GRAPH_OUT|AIDLC_GRAPHIFY) echo "managed paths now come from profiles (--profile, --path, AIDLC_PROFILES_DIR)" ;;
    AIDLC_GITIGNORE) echo "no longer configurable: the managed .gitignore block is required" ;;
  esac
}
# Path settings: relative values in a config file resolve against that file's
# directory (not the current directory, which differs for hooks).
PATH_KEYS="AIDLC_DOCS_REPO AIDLC_PROFILES_DIR AIDLC_RULES_DIR"

find_config_file() {
  local candidate
  for candidate in \
    "${AIDLC_KIT_CONFIG:-}" \
    "$PWD/aidlc-kit.conf" \
    "$KIT_ROOT/aidlc-kit.conf" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/aidlc-kit/config"; do
    if [ -n "$candidate" ] && [ -f "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# parse_kv_line "line" -> sets KV_KEY / KV_VALUE; returns 1 for blank/comment.
parse_kv_line() {
  local line="${1%$'\r'}"
  line="${line#"${line%%[![:space:]]*}"}"
  case "$line" in ''|'#'*) return 1 ;; esac
  case "$line" in *=*) ;; *) return 2 ;; esac
  KV_KEY="${line%%=*}"
  KV_KEY="${KV_KEY//[[:space:]]/}"
  KV_VALUE="${line#*=}"
  KV_VALUE="${KV_VALUE#"${KV_VALUE%%[![:space:]]*}"}"
  KV_VALUE="${KV_VALUE%"${KV_VALUE##*[![:space:]]}"}"
  case "$KV_VALUE" in
    \"*\") KV_VALUE="${KV_VALUE#\"}"; KV_VALUE="${KV_VALUE%\"}" ;;
    \'*\') KV_VALUE="${KV_VALUE#\'}"; KV_VALUE="${KV_VALUE%\'}" ;;
  esac
  return 0
}

load_config() {
  CONFIG_FILE=""
  if CONFIG_FILE="$(find_config_file)"; then
    local line rc config_dir
    config_dir="$(real_dir "$(dirname "$CONFIG_FILE")")"
    while IFS= read -r line || [ -n "$line" ]; do
      rc=0; parse_kv_line "$line" || rc=$?
      [ "$rc" = 1 ] && continue
      [ "$rc" = 2 ] && die "$CONFIG_FILE: expected KEY=VALUE, got: $line"
      case " $KNOWN_KEYS " in
        *" $KV_KEY "*) ;;
        *)
          case " $LEGACY_KEYS " in
            *" $KV_KEY "*) die "$CONFIG_FILE: '$KV_KEY' was a setting of the old sync.sh scripts; $(legacy_key_hint "$KV_KEY")" ;;
          esac
          die "$CONFIG_FILE: unknown setting '$KV_KEY' (known: $KNOWN_KEYS)" ;;
      esac
      case " $PATH_KEYS " in
        *" $KV_KEY "*)
          case "$KV_VALUE" in
            ''|\~|\~/*|/*|[A-Za-z]:[\\/]*) ;;
            *) KV_VALUE="$config_dir/$KV_VALUE" ;;
          esac ;;
      esac
      # environment wins over the file
      if [ -z "${!KV_KEY+x}" ]; then
        printf -v "$KV_KEY" '%s' "$KV_VALUE"
      fi
    done < "$CONFIG_FILE"
  fi

  : "${AIDLC_DOCS_REPO:=}"
  : "${AIDLC_LINK_MODE:=auto}"
  : "${AIDLC_AUTO_COMMIT:=on}"
  : "${AIDLC_AUTO_PUSH:=on}"
  : "${AIDLC_HOOKS:=all}"
  : "${AIDLC_PROFILES_DIR:=}"
  : "${AIDLC_TARGET:=claude}"
  : "${AIDLC_RULES_DIR:=}"

  validate_link_mode "$AIDLC_LINK_MODE"
  # check AIDLC_HOOKS now, not after init has already moved files (the hooks
  # need it on every command; the rules target is checked by init only)
  if declare -F enabled_events >/dev/null; then enabled_events >/dev/null; fi
  validate_switch AIDLC_AUTO_COMMIT "$AIDLC_AUTO_COMMIT"
  validate_switch AIDLC_AUTO_PUSH "$AIDLC_AUTO_PUSH"
  if [ -n "$AIDLC_DOCS_REPO" ]; then AIDLC_DOCS_REPO="$(expand_path "$AIDLC_DOCS_REPO")"; fi
  if [ -n "$AIDLC_PROFILES_DIR" ]; then AIDLC_PROFILES_DIR="$(expand_path "$AIDLC_PROFILES_DIR")"; fi
  if [ -n "$AIDLC_RULES_DIR" ]; then AIDLC_RULES_DIR="$(expand_path "$AIDLC_RULES_DIR")"; fi
  return 0
}

# ---- paths and validation --------------------------------------------------

# Expand a leading ~; resolve relative paths against $PWD (env vars and CLI
# flags; config-file values were already anchored to the file); return absolute.
expand_path() {
  local p="$1"
  case "$p" in
    \~) p="$HOME" ;;
    \~/*) p="$HOME/${p#\~/}" ;;
  esac
  case "$p" in
    /*|[A-Za-z]:[\\/]*) ;;
    *) p="$PWD/$p" ;;
  esac
  echo "$p"
}

# Absolute, symlink-free path of an existing directory.
real_dir() { (cd -P -- "$1" 2>/dev/null && pwd); }

validate_link_mode() {
  case "$1" in auto|link|copy) ;; *) die "link mode must be auto, link or copy (got '$1')" ;; esac
}

validate_switch() {
  case "$2" in on|off) ;; *) die "$1 must be 'on' or 'off' (got '$2')" ;; esac
}

# A single safe name (project names, profile names). Optional 3rd arg: hint.
validate_name() {
  local label="$1" value="$2" hint="${3:+; $3}"
  case "$value" in
    ''|.|..|-*|*[!A-Za-z0-9._-]*) die "$label '$value' must be letters, digits, '.', '_' or '-' (not starting with '-')$hint" ;;
  esac
}

# A managed path: relative, no traversal, no empty segments, not .git.
# Trailing '/' marks a directory. Glob characters are rejected unless the 2nd
# arg is "glob" (exclude= patterns): a literal path= becomes a .gitignore
# line, where '*' etc. would silently ignore more than intended. Returns 0/1
# instead of dying so callers can report where the bad value came from.
is_valid_managed_path() {
  local p="$1" mode="${2:-literal}"
  case "$p" in
    ''|/*|*\\*|[A-Za-z]:*|*'|'*) return 1 ;;
  esac
  if [ "$mode" != glob ]; then
    case "$p" in *'*'*|*'?'*|*'['*|*']'*|*'!'*) return 1 ;; esac
  fi
  case "/${p%/}/" in
    */../*|*/./*|*//*|/.git/*|*/.git/*) return 1 ;;
  esac
  case "$p" in *[[:cntrl:]]*) return 1 ;; esac
  return 0
}

# sh_dquote STRING -> "STRING", safe to paste into sh (\ " $ ` escaped)
sh_dquote() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//\$/\\\$}"; s="${s//\`/\\\`}"
  printf '"%s"' "$s"
}

path_kind() { case "$1" in */) echo dir ;; *) echo file ;; esac; }
strip_slash() { echo "${1%/}"; }
