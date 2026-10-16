# shellcheck shell=bash disable=SC2034,SC2153,SC2317
# (file-wide: globals and functions here are used by the files that source this one)
# Link strategy (docs/DESIGN.md §6): native symlink -> Windows junction (dirs
# only) -> copy. Every link is verified before it is trusted, because Git
# Bash's plain `ln -s` silently makes a COPY instead of a link.

# is_link_to LINK TARGET -> 0 if LINK is a symlink/junction resolving to TARGET.
is_link_to() {
  local link="$1" target="$2"
  [ -L "$link" ] || return 1
  if [ -e "$target" ]; then
    [ "$link" -ef "$target" ]
  else
    # dangling link to a file that doesn't exist yet
    dangling_link_to "$link" "$target"
  fi
}

# dangling_link_to LINK TARGET -> 0 if LINK's stored destination is TARGET,
# even though TARGET doesn't exist. Compares the parent directories with -ef
# rather than the strings, because the same folder can be spelled /c/x,
# C:/x or /tmp/x on Windows.
dangling_link_to() {
  local dest
  dest="$(readlink -- "$1")" || return 1
  # a relative destination is relative to the link's own directory, not $PWD
  case "$dest" in
    /*|[A-Za-z]:[\\/]*) ;;
    *) dest="$(dirname -- "$1")/$dest" ;;
  esac
  [ "$(basename -- "$dest")" = "$(basename -- "$2")" ] || return 1
  [ "$dest" = "$2" ] && return 0
  [ -d "$(dirname -- "$dest")" ] && [ -d "$(dirname -- "$2")" ] && [ "$(dirname -- "$dest")" -ef "$(dirname -- "$2")" ]
}

# probe_dir LINK TARGET -> 0 if a file written through LINK appears in TARGET.
probe_dir() {
  local link="$1" target="$2" name
  name=".aidlc-kit-probe-$$-$RANDOM"
  ( : > "$link/$name" ) 2>/dev/null || return 1
  local ok=1
  if [ -f "$target/$name" ]; then ok=0; fi
  rm -f -- "$link/$name" "$target/$name"
  return "$ok"
}

# verify_link KIND LINK TARGET
verify_link() {
  is_link_to "$2" "$3" || return 1
  if [ "$1" = dir ]; then probe_dir "$2" "$3"; else return 0; fi
}

# remove_link LINK — removes only the link itself, never what it points to.
remove_link() {
  local link="$1"
  [ -L "$link" ] || die "refusing to remove '$link': not a link"
  rm -f -- "$link" 2>/dev/null || rmdir -- "$link" 2>/dev/null || die "could not remove link $link"
  [ ! -L "$link" ] || die "could not remove link $link"
}

# AIDLC_KIT_SIMULATE_NO_LINKS=1 makes every link attempt fail, to exercise the
# copy fallback and the --link-mode link preflight on any machine (tests,
# or checking what a teammate on a locked-down Windows box will get).
links_disabled() { [ "${AIDLC_KIT_SIMULATE_NO_LINKS:-0}" = 1 ]; }
# AIDLC_KIT_SIMULATE_NO_SYMLINKS=1 makes only symlinks fail, as on Windows
# without Developer Mode: folders get junctions, files copy mode. (CI's
# Windows runners can make symlinks, so this is how CI covers that case.)
symlinks_disabled() { links_disabled || [ "${AIDLC_KIT_SIMULATE_NO_SYMLINKS:-0}" = 1 ]; }

try_symlink() { # LINK TARGET
  if symlinks_disabled; then return 1; fi
  # nativestrict: fail instead of silently copying on Windows; ignored elsewhere.
  MSYS=winsymlinks:nativestrict CYGWIN=winsymlinks:nativestrict ln -s -- "$2" "$1" 2>/dev/null
}

try_junction() { # LINK TARGET (Windows only, directories only)
  if links_disabled; then return 1; fi
  [ "$IS_WINDOWS" = 1 ] || return 1
  command -v cygpath >/dev/null 2>&1 || return 1
  MSYS_NO_PATHCONV=1 cmd /c mklink /J "$(cygpath -w "$1")" "$(cygpath -w "$2")" >/dev/null 2>&1
}

# Cleanup after a failed attempt. LINK did not exist before the attempt (the
# caller guarantees it), so anything there now was created by us.
undo_attempt() {
  local link="$1"
  if [ -L "$link" ]; then
    remove_link "$link"
  elif [ -e "$link" ]; then
    rm -rf -- "$link"
  fi
}

# copy_in KIND LINK TARGET — make LINK a real copy of TARGET (copy mode).
copy_in() {
  local kind="$1" link="$2" target="$3"
  if [ "$kind" = dir ]; then
    mkdir -p -- "$link"
    if [ -d "$target" ]; then cp -Rp -- "$target/." "$link/"; fi
  else
    if [ -f "$target" ]; then
      mkdir -p -- "$(dirname "$link")"
      cp -p -- "$target" "$link"
    fi
  fi
  return 0
}

# make_link KIND LINK TARGET PREF -> echoes the mode used (symlink|junction|copy).
# PREF: auto (link, else copy) | link (symlink or junction, never copy) | copy. LINK must not exist. TARGET's parent must exist.
make_link() {
  local kind="$1" link="$2" target="$3" pref="$4"
  if [ -e "$link" ] || [ -L "$link" ]; then die "internal: $link already exists"; fi
  mkdir -p -- "$(dirname "$link")"

  if [ "$pref" != copy ]; then
    if try_symlink "$link" "$target" && verify_link "$kind" "$link" "$target"; then
      echo symlink; return 0
    fi
    undo_attempt "$link"

    if [ "$kind" = dir ] && try_junction "$link" "$target" && verify_link dir "$link" "$target"; then
      echo junction; return 0
    fi
    undo_attempt "$link"

    [ "$pref" = link ] && return 1
  fi

  copy_in "$kind" "$link" "$target"
  echo copy
}
