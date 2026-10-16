# shellcheck shell=bash disable=SC2034,SC2153,SC2317
# (file-wide: globals and functions here are used by the files that source this one)
# AI-DLC rules: use what the user already has, never ship our own copy.
# See docs/DESIGN.md §10. Order:
#   1. the project already has AI-DLC rules      -> leave them alone
#   2. the upstream 2.x `aidlc` CLI is installed  -> `aidlc config --harness H`
#   3. AIDLC_RULES_DIR points at 1.x rules        -> copy them in the --target layout
#   4. none of these                             -> explain, carry on without rules

# 1.x layouts, from the upstream manual-setup instructions:
#   target -> entry file | rule-details dir | entry mode (plain, or cursor .mdc frontmatter)
rules_layout() {
  case "$1" in
    claude)  echo "CLAUDE.md|.aidlc-rule-details|plain" ;;
    agents)  echo "AGENTS.md|.aidlc-rule-details|plain" ;;
    cursor)  echo ".cursor/rules/ai-dlc-workflow.mdc|.aidlc-rule-details|cursor" ;;
    cline)   echo ".clinerules/core-workflow.md|.aidlc-rule-details|plain" ;;
    kiro)    echo ".kiro/steering/aws-aidlc-rules/core-workflow.md|.kiro/aws-aidlc-rule-details|plain" ;;
    amazonq) echo ".amazonq/rules/aws-aidlc-rules/core-workflow.md|.amazonq/aws-aidlc-rule-details|plain" ;;
    *) return 1 ;;
  esac
}

RULES_TARGETS="claude agents cursor cline kiro amazonq"

validate_target() {
  rules_layout "$1" >/dev/null || die "unknown target '$1' (expected one of: $RULES_TARGETS)"
}

# 2.x harness for a target (the CLI's own names). Empty: no 2.x equivalent.
harness_for() {
  case "$1" in
    claude) echo claude ;;
    cursor) echo cursor ;;
    kiro) echo kiro-ide ;;
    agents) echo codex ;;
    *) echo "" ;;
  esac
}

# rules_present -> 0 if the working repo already has AI-DLC rules: any 1.x
# rule-details folder, or a project a profile of an AI-DLC kind matches by
# its rules (detect= entries that aren't artifact paths).
rules_present() {
  local t layout details
  for t in $RULES_TARGETS; do
    layout="$(rules_layout "$t")"
    details="${layout#*|}"; details="${details%%|*}"
    if [ -d "$WORK/$details" ]; then return 0; fi
  done
  # upstream's "AI-assisted setup" layout, which the 1.x core workflow also reads
  if [ -d "$WORK/.aidlc/aidlc-rules/aws-aidlc-rule-details" ]; then return 0; fi
  # 2.x keeps its records under aidlc/spaces/
  if [ -d "$WORK/aidlc/spaces" ]; then return 0; fi
  return 1
}

# install_rules_from_dir DIR TARGET — copy 1.x rules (a release zip's
# aidlc-rules/ folder, or a clone's) into the working repo. Never overwrites
# an existing entry file; refreshes the rule-details folder.
install_rules_from_dir() {
  local dir="$1" target="$2" layout entry details mode core src_details
  core="$dir/aws-aidlc-rules/core-workflow.md"
  src_details="$dir/aws-aidlc-rule-details"
  # accept the repo root too (…/aidlc-workflows with aidlc-rules/ inside)
  if [ ! -f "$core" ] && [ -f "$dir/aidlc-rules/aws-aidlc-rules/core-workflow.md" ]; then
    install_rules_from_dir "$dir/aidlc-rules" "$target"
    return
  fi
  if [ ! -f "$core" ] || [ ! -d "$src_details" ]; then
    die "AIDLC_RULES_DIR=$dir doesn't look like AI-DLC 1.x rules (expected aws-aidlc-rules/core-workflow.md and aws-aidlc-rule-details/)"
  fi
  layout="$(rules_layout "$target")"
  entry="${layout%%|*}"; details="${layout#*|}"; mode="${details#*|}"; details="${details%%|*}"

  if [ -f "$WORK/$entry" ]; then
    # e.g. a CLAUDE.md the project already had for other reasons
    warn "$entry already exists, so it was left alone; append the AI-DLC workflow from $core to it yourself if it isn't there yet"
  else
    mkdir -p -- "$(dirname -- "$WORK/$entry")"
    if [ "$mode" = cursor ]; then
      {
        printf -- '---\ndescription: "AI-DLC (AI-Driven Development Life Cycle) adaptive workflow for software development"\nalwaysApply: true\n---\n\n'
        cat -- "$core"
      } > "$WORK/$entry"
    else
      cp -- "$core" "$WORK/$entry"
    fi
    info "  rules: wrote $entry"
  fi
  mkdir -p -- "$WORK/$details"
  cp -R -- "$src_details/." "$WORK/$details/"
  info "  rules: copied rule details to $details/ (from $dir)"
}

# run_aidlc_config HARNESS — in the working repo. Without a terminal (scripts,
# cloud setup) it gets no stdin, so a question from the CLI fails fast
# instead of waiting forever.
run_aidlc_config() {
  if [ -t 0 ]; then
    (cd "$WORK" && aidlc config --harness "$1")
  else
    (cd "$WORK" && aidlc config --harness "$1" < /dev/null)
  fi
}

# setup_rules — called by init (unless --no-rules) before it detects
# artifacts, so whatever the rules installer creates is managed in the same
# run. Only a bad AIDLC_RULES_DIR / target stops init: rules are optional.
setup_rules() {
  local target harness
  target="${OPT_TARGET:-$AIDLC_TARGET}"
  validate_target "$target"
  if rules_present; then
    info "  rules: AI-DLC rules already in the project, leaving them alone"
    return 0
  fi
  # an explicit setting wins over auto-detecting the CLI
  if [ -n "$AIDLC_RULES_DIR" ]; then
    if [ "$DRY_RUN" = 1 ]; then info "  rules: would copy 1.x rules from $AIDLC_RULES_DIR ($target layout)"; return 0; fi
    install_rules_from_dir "$AIDLC_RULES_DIR" "$target"
    return 0
  fi
  if command -v aidlc >/dev/null 2>&1; then
    harness="$(harness_for "$target")"
    if [ -z "$harness" ]; then
      warn "the aidlc 2.x CLI has no harness for target '$target'; set it up yourself (aidlc config --harness <name>)"
      return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
      info "  rules: would offer 'aidlc config --harness $harness'"
    elif [ "${ASSUME_YES:-0}" != 1 ] && [ ! -t 0 ]; then
      # optional step: never fail init over it
      info "  rules: none found; run 'aidlc config --harness $harness' in $WORK (or re-run init with --yes)"
    elif confirm "Run 'aidlc config --harness $harness' in $WORK to install the AI-DLC rules?"; then
      if run_aidlc_config "$harness"; then
        info "  rules: installed with 'aidlc config --harness $harness'"
      else
        warn "'aidlc config --harness $harness' failed; run it yourself in $WORK"
      fi
    else
      info "  rules: skipped (run 'aidlc config --harness $harness' yourself when ready)"
    fi
    return 0
  fi
  info "  rules: no AI-DLC rules found. Install them with the AI-DLC CLI"
  info "         (https://github.com/awslabs/aidlc-workflows), or point AIDLC_RULES_DIR at a"
  info "         downloaded 1.x aidlc-rules/ folder and re-run init. Artifact management works either way."
}
