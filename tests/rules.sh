#!/usr/bin/env bash
# Tests for milestone 4: AI-DLC rules come from the user's own installation.
# Run: bash tests/rules.sh
set -uo pipefail

# shellcheck source=helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# a fake 1.x rules folder, shaped like upstream's aidlc-rules/
make_rules() { # dir
  mkdir -p "$1/aws-aidlc-rules" "$1/aws-aidlc-rule-details/common"
  echo "# AI-DLC core workflow (test copy)" > "$1/aws-aidlc-rules/core-workflow.md"
  echo "process overview" > "$1/aws-aidlc-rule-details/common/process-overview.md"
}

# a fake upstream `aidlc` CLI in $SB/bin that records how it was called
fake_aidlc() {
  mkdir -p "$SB/bin"
  # shellcheck disable=SC2016  # $PWD and $* belong to the fake script, not to us
  printf '#!/bin/sh\necho "$PWD|$*" >> "%s/aidlc-calls"\nmkdir -p aidlc/spaces/default\n' "$SB" > "$SB/bin/aidlc"
  chmod +x "$SB/bin/aidlc"
}

# a sandbox whose project has no rules yet (new_sandbox ships rule details)
no_rules_sandbox() {
  new_sandbox
  git -C "$W" rm -rq .aidlc-rule-details && git -C "$W" commit -qm "no rules"
  make_rules "$SB/rules"
}

echo "rules already present"
new_sandbox
make_rules "$SB/rules"
check "init with rules already in the project" env AIDLC_RULES_DIR="$SB/rules" bash "$CLI" init "$W" --docs-repo "$D" --yes
check "...leaves them alone (no CLAUDE.md written)" test ! -e "$W/CLAUDE.md"
check "...and says so" bash -c "AIDLC_RULES_DIR='$SB/rules' bash '$CLI' init '$W' --yes 2>&1 < /dev/null | grep -q 'already in the project'"

echo "copying 1.x rules from AIDLC_RULES_DIR"
no_rules_sandbox
check "claude target" env AIDLC_RULES_DIR="$SB/rules" bash "$CLI" init "$W" --docs-repo "$D" --yes
check "CLAUDE.md is the core workflow" grep -q "AI-DLC core workflow" "$W/CLAUDE.md"
check "rule details copied" test -f "$W/.aidlc-rule-details/common/process-overview.md"
check "artifacts still managed" is_link "$W/aidlc-docs"

no_rules_sandbox
check "cursor target (--target)" env AIDLC_RULES_DIR="$SB/rules" bash "$CLI" init "$W" --docs-repo "$D" --target cursor --yes
check "cursor .mdc has frontmatter + workflow" bash -c "head -1 '$W/.cursor/rules/ai-dlc-workflow.mdc' | grep -qx -- '---' && grep -q alwaysApply '$W/.cursor/rules/ai-dlc-workflow.mdc' && grep -q 'core workflow' '$W/.cursor/rules/ai-dlc-workflow.mdc'"

no_rules_sandbox
check "kiro target via AIDLC_TARGET" env AIDLC_RULES_DIR="$SB/rules" AIDLC_TARGET=kiro bash "$CLI" init "$W" --docs-repo "$D" --yes
check "kiro layout" bash -c "test -f '$W/.kiro/steering/aws-aidlc-rules/core-workflow.md' && test -d '$W/.kiro/aws-aidlc-rule-details/common'"

no_rules_sandbox
mkdir -p "$SB/clone/aidlc-rules"; make_rules "$SB/clone/aidlc-rules"
check "a clone's root (with aidlc-rules/ inside) is accepted" env AIDLC_RULES_DIR="$SB/clone" bash "$CLI" init "$W" --docs-repo "$D" --yes
check "...and used" test -f "$W/CLAUDE.md"

no_rules_sandbox
echo "# our own project notes" > "$W/CLAUDE.md"
AIDLC_RULES_DIR="$SB/rules" bash "$CLI" init "$W" --docs-repo "$D" --yes < /dev/null > "$SB/out" 2>&1
check "an existing CLAUDE.md is never overwritten" grep -qx "# our own project notes" "$W/CLAUDE.md"
check "...and the user is told to add the workflow" grep -q "append the AI-DLC workflow" "$SB/out"

no_rules_sandbox
mkdir -p "$SB/not-rules"
check_not "a folder that isn't AI-DLC rules is rejected" env AIDLC_RULES_DIR="$SB/not-rules" bash "$CLI" init "$W" --docs-repo "$D" --yes
check "...before anything moved" test -d "$W/aidlc-docs" -a ! -L "$W/aidlc-docs"
check_not "an unknown target is rejected" env AIDLC_RULES_DIR="$SB/rules" bash "$CLI" init "$W" --docs-repo "$D" --target emacs --yes
check "...before anything moved" test -d "$W/aidlc-docs" -a ! -L "$W/aidlc-docs"

echo "upstream 2.x CLI"
no_rules_sandbox; fake_aidlc
check "init with the aidlc CLI on PATH" env PATH="$SB/bin:$PATH" bash "$CLI" init "$W" --docs-repo "$D" --yes
check "runs 'aidlc config --harness claude' in the project" grep -q "app|config --harness claude$" "$SB/aidlc-calls"
check "AIDLC_RULES_DIR is not needed" test ! -e "$W/CLAUDE.md"

no_rules_sandbox; fake_aidlc
check "kiro maps to the kiro-ide harness" env PATH="$SB/bin:$PATH" bash "$CLI" init "$W" --docs-repo "$D" --target kiro --yes
check "...called with kiro-ide" grep -q "config --harness kiro-ide" "$SB/aidlc-calls"

no_rules_sandbox; fake_aidlc
PATH="$SB/bin:$PATH" bash "$CLI" init "$W" --docs-repo "$D" --target cline --yes < /dev/null > "$SB/out" 2>&1
check "a target with no 2.x harness doesn't run the CLI" test ! -e "$SB/aidlc-calls"
check "...and says so" grep -q "no harness for target 'cline'" "$SB/out"

no_rules_sandbox; fake_aidlc
kit init "$W" --docs-repo "$D" --yes >/dev/null 2>&1    # set up first, non-interactively
PATH="$SB/bin:$PATH" bash "$CLI" init "$W" < /dev/null > "$SB/out" 2>&1; rc=$?
check "no terminal and no --yes: the optional rules step is skipped, init still succeeds" test "$rc" = 0
check "...without running the CLI" test ! -e "$SB/aidlc-calls"

echo "review regressions"
no_rules_sandbox; fake_aidlc
check "an explicit AIDLC_RULES_DIR wins over an installed aidlc CLI" env PATH="$SB/bin:$PATH" AIDLC_RULES_DIR="$SB/rules" bash "$CLI" init "$W" --docs-repo "$D" --yes
check "...the 1.x rules were copied" test -f "$W/CLAUDE.md"
check "...and the CLI was not run" test ! -e "$SB/aidlc-calls"

no_rules_sandbox; fake_aidlc
check "init with the CLI creating aidlc/ (2.x)" env PATH="$SB/bin:$PATH" bash "$CLI" init "$W" --docs-repo "$D" --yes
check "what the rules installer created is managed in the same run" is_link "$W/aidlc"
check "...recorded with the aidlc-v2 profile" grep -qx "profile=aidlc-v2" "$D/app/.aidlc-kit/record"

no_rules_sandbox
mkdir -p "$W/.aidlc/aidlc-rules/aws-aidlc-rule-details/common"
check "the .aidlc/aidlc-rules layout counts as rules present" env AIDLC_RULES_DIR="$SB/rules" bash "$CLI" init "$W" --docs-repo "$D" --yes
check "...no second copy installed" bash -c "test ! -e '$W/CLAUDE.md' && test ! -e '$W/.aidlc-rule-details'"

check "a bad AIDLC_TARGET doesn't break status" env AIDLC_TARGET=cluade bash "$CLI" status "$W"
check "...or save" env AIDLC_TARGET=cluade bash "$CLI" save "$W"
check "...or a hook" bash -c "AIDLC_TARGET=cluade bash '$CLI' hook stop --repo '$W' < /dev/null; ! tail -n 5 '$W/.git/aidlc-kit/log' 2>/dev/null | grep -q 'unknown target'"

no_rules_sandbox
check "dry run with AIDLC_RULES_DIR writes no rules" env AIDLC_RULES_DIR="$SB/rules" bash "$CLI" init "$W" --docs-repo "$D" --dry-run
check "...nothing written" test ! -e "$W/CLAUDE.md"

echo "skill install"
new_sandbox
check "skill install" kit skill install
check "...copied to ~/.claude/skills" grep -q "^name: aidlc-init$" "$HOME/.claude/skills/aidlc-init/SKILL.md"
check "re-install is fine" kit skill install
check "CLAUDE_CONFIG_DIR is honoured" env CLAUDE_CONFIG_DIR="$SB/cfgdir" bash "$CLI" skill install
check "...installed there" test -f "$SB/cfgdir/skills/aidlc-init/SKILL.md"
check "skill uninstall" kit skill uninstall
check "...removed" test ! -e "$HOME/.claude/skills/aidlc-init"
mkdir -p "$HOME/.claude/skills/aidlc-init"; echo "name: something-else" > "$HOME/.claude/skills/aidlc-init/SKILL.md"
check_not "a different skill with that name is never overwritten" kit skill install
check_not "...or removed" kit skill uninstall

echo "no rules anywhere"
no_rules_sandbox
check "init without any rules source still manages artifacts" kit init "$W" --docs-repo "$D" --yes
check "...and explains where rules come from" bash -c "bash '$CLI' init '$W' --yes < /dev/null 2>&1 | grep -q 'no AI-DLC rules found'"
no_rules_sandbox
check "--no-rules skips the rules step" env AIDLC_RULES_DIR="$SB/rules" bash "$CLI" init "$W" --docs-repo "$D" --no-rules --yes
check "...nothing written" test ! -e "$W/CLAUDE.md"

echo "AI-DLC 2.x: machine-local files stay out of the docs repo"
new_sandbox
rm -rf "$W/aidlc-docs" "$W/graphify-out" "$W/graph.json"
A="$W/aidlc"; I="$A/spaces/default/intents/i1"
mkdir -p "$A/spaces/default/memory" "$I/audit" "$I/.aidlc-engine/sensors" "$A/.aidlc-sessions" "$A/active-memory" "$A/diagnostics"
echo rules > "$A/spaces/default/memory/project.md"            # committed upstream
echo state > "$I/aidlc-state.md"; echo shard > "$I/audit/host-clone.md"
echo '{}' > "$A/spaces/default/intents/intents.json"
echo local > "$A/.aidlc-clone-id"; echo default > "$A/active-space"  # machine-local upstream
echo i1 > "$A/spaces/default/intents/active-intent"
echo x > "$I/.aidlc-engine/plan.json"; echo x > "$I/runtime-graph.json"
echo x > "$A/.aidlc-sessions/s"; echo x > "$A/active-memory/project.md"; echo x > "$A/diagnostics/d"
kit init "$W" --docs-repo "$D" --no-rules --yes >/dev/null 2>&1
check "aidlc-v2 detected and saved" kit save "$W"
tracked="$(git -C "$D" ls-files -- app/aidlc)"
for f in spaces/default/memory/project.md spaces/default/intents/i1/aidlc-state.md spaces/default/intents/i1/audit/host-clone.md spaces/default/intents/intents.json; do
  check "committed: $f" grep -qx "app/aidlc/$f" <<< "$tracked"
done
for f in .aidlc-clone-id active-space spaces/default/intents/active-intent spaces/default/intents/i1/.aidlc-engine/plan.json spaces/default/intents/i1/runtime-graph.json .aidlc-sessions/s active-memory/project.md diagnostics/d; do
  check_not "machine-local, not committed: $f" grep -qx "app/aidlc/$f" <<< "$tracked"
done

summary
