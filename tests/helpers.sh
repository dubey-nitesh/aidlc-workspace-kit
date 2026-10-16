# shellcheck shell=bash disable=SC2034
# (file-wide: variables here are used by the test files that source this one)
# Shared helpers for tests/*.sh. Dependency-free: bash, git, coreutils.

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$KIT/bin/aidlc-kit"
PASS=0; FAIL=0

ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; if [ -n "${LAST_OUT:-}" ]; then tail -n 8 <<< "$LAST_OUT" | sed 's/^/       | /'; fi; }
check()     { local d="$1"; shift; if LAST_OUT="$("$@" 2>&1)"; then LAST_OUT=""; ok "$d"; else bad "$d"; fi; }
check_not() { local d="$1"; shift; if LAST_OUT="$("$@" 2>&1)"; then bad "$d"; else LAST_OUT=""; ok "$d"; fi; }
kit() { bash "$CLI" "$@" < /dev/null; }

# Can this machine make real file symlinks? (Windows needs Developer Mode.)
probe_symlinks() {
  local t; t="$(mktemp -d)"; echo x > "$t/f"
  if [ "${AIDLC_KIT_SIMULATE_NO_SYMLINKS:-0}" != 1 ] &&
     MSYS=winsymlinks:nativestrict ln -s "$t/f" "$t/l" 2>/dev/null && [ -L "$t/l" ]; then FILE_LINKS=1; else FILE_LINKS=0; fi
  rm -rf "$t"
}
probe_symlinks

is_link() { [ -L "$1" ]; }

# Sandbox with spaces in every path: <sb>/my work/app (git) and <sb>/my docs (git).
new_sandbox() {
  SB="$(mktemp -d)"
  export HOME="$SB/home" XDG_CONFIG_HOME="$SB/home/.config" AIDLC_KIT_CONFIG="$SB/none.conf"
  unset AIDLC_DOCS_REPO AIDLC_LINK_MODE AIDLC_PROFILES_DIR AIDLC_KIT_SIMULATE_NO_LINKS AIDLC_AUTO_COMMIT AIDLC_AUTO_PUSH
  export AIDLC_HOOKS=none   # hook tests turn them on explicitly
  mkdir -p "$HOME" "$SB/my work/app" "$SB/my docs"
  W="$SB/my work/app"; D="$SB/my docs"
  git -C "$W" init -q -b main
  git -C "$D" init -q -b main
  local r
  for r in "$W" "$D"; do git -C "$r" config user.email t@example.com; git -C "$r" config user.name t; done
  echo "print(1)" > "$W/app.py"
  printf 'node_modules/\n' > "$W/.gitignore"
  mkdir -p "$W/.aidlc-rule-details"; echo r > "$W/.aidlc-rule-details/x.md"
  git -C "$W" add -A && git -C "$W" commit -qm init
  mkdir -p "$W/aidlc-docs/inception"
  echo "req" > "$W/aidlc-docs/requirements.md"
  echo "plan" > "$W/aidlc-docs/inception/plan.md"
  mkdir -p "$W/graphify-out"; echo "<html>" > "$W/graphify-out/graph.html"
  echo '{}' > "$W/graph.json"
}

summary() {
  echo ""
  echo "passed: $PASS  failed: $FAIL  (platform: $(uname -s), file symlinks: $FILE_LINKS)"
  [ "$FAIL" -eq 0 ]
}
