#!/usr/bin/env bash
# Tests for bin/aidlc-kit milestone 1 (init/attach/status/detach).
# Dependency-free: bash, git, coreutils. Run: bash tests/core.sh
set -uo pipefail

# shellcheck source=helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

echo "version"
check "--version prints the version" bash -c "bash '$CLI' --version | grep -qE '^aidlc-kit [0-9]+\.[0-9]+\.[0-9]+$'"

echo "init"
new_sandbox
check_not "first init refuses without --yes when not on a terminal" kit init "$W" --docs-repo "$D"
check "dry run succeeds" kit init "$W" --docs-repo "$D" --dry-run
check "dry run changes nothing" test -f "$W/aidlc-docs/requirements.md" -a ! -L "$W/aidlc-docs" -a ! -e "$D/app"
check "init with --yes" kit init "$W" --docs-repo "$D" --yes
check "aidlc-docs is now a link" is_link "$W/aidlc-docs"
check "graphify-out is now a link" is_link "$W/graphify-out"
check "docs moved into the docs repo" test -f "$D/app/aidlc-docs/inception/plan.md"
check "contents visible through the link" grep -qx plan "$W/aidlc-docs/inception/plan.md"
check "graph.json present in the docs repo" test -f "$D/app/graph.json"
if [ "$FILE_LINKS" = 1 ]; then
  check "graph.json is a symlink" is_link "$W/graph.json"
else
  check "graph.json falls back to a copy (no file symlinks here)" test -f "$W/graph.json" -a ! -L "$W/graph.json"
fi
echo new > "$W/aidlc-docs/new.md"
check "a file written through the link lands in the docs repo" test -f "$D/app/aidlc-docs/new.md"
check "record written" grep -qx "path=aidlc-docs/|dir" "$D/app/.aidlc-kit/record"
check "record lists profiles" grep -qx "profile=graphify" "$D/app/.aidlc-kit/record"
check "machine state written in .git" grep -q "^docs_repo=" "$W/.git/aidlc-kit/state"
check "working .gitignore keeps user lines" grep -qx "node_modules/" "$W/.gitignore"
check "working .gitignore lists paths without trailing slash" grep -qx "/aidlc-docs" "$W/.gitignore"
check "working repo shows only .gitignore as changed" bash -c "[ \"\$(git -C '$W' status --porcelain)\" = ' M .gitignore' ]"
check "docs project .gitignore ignores backups" grep -qx "/.aidlc-kit/backup/" "$D/app/.gitignore"
check "rule details are left in the working repo" test -f "$W/.aidlc-rule-details/x.md" -a ! -L "$W/.aidlc-rule-details"
check "re-running init is a no-op that needs no confirmation" kit init "$W"
check "gitignore block not duplicated" bash -c "[ \$(grep -c 'aidlc-workspace-kit >>>' '$W/.gitignore') -eq 1 ]"
check "status is healthy" kit status "$W"

echo "status problems"
rm -f "$W/graphify-out" 2>/dev/null || rmdir "$W/graphify-out"
check_not "status fails when a link is missing" kit status "$W"
check "status names the missing path" bash -c "bash '$CLI' status '$W' 2>&1 | grep -q 'graphify-out/.*MISSING'"
check "attach repairs it" kit attach "$W"
check "link restored" is_link "$W/graphify-out"

new_sandbox
check "init with a forced profile" kit init "$W" --docs-repo "$D" --profile aidlc-v1 --yes
check "status reports unmanaged graphify output" bash -c "bash '$CLI' status '$W' 2>&1 | grep -q 'unmanaged: graphify-out/'"
check_not "status exits non-zero for unmanaged artifacts" kit status "$W"
check "adding the path later works" kit init "$W" --path graphify-out/ --yes
check "now managed" is_link "$W/graphify-out"

echo "conflicts"
new_sandbox
mkdir -p "$D/app/aidlc-docs"; echo "old docs" > "$D/app/aidlc-docs/requirements.md"
check_not "both sides have content -> refuses" kit init "$W" --docs-repo "$D" --profile aidlc-v1 --yes
check "nothing moved after the refusal" test -f "$W/aidlc-docs/requirements.md" -a ! -L "$W/aidlc-docs"
check "--prefer working" kit init "$W" --docs-repo "$D" --profile aidlc-v1 --prefer working --yes
check "working copy won" grep -qx req "$D/app/aidlc-docs/requirements.md"
check "docs copy backed up" bash -c "grep -rqx 'old docs' '$D/app/.aidlc-kit/backup/'"

new_sandbox
mkdir -p "$D/app/aidlc-docs"; echo "old docs" > "$D/app/aidlc-docs/requirements.md"
check "--prefer docs" kit init "$W" --docs-repo "$D" --profile aidlc-v1 --prefer docs --yes
check "docs copy won" grep -qx "old docs" "$W/aidlc-docs/requirements.md"
check "working copy backed up" bash -c "grep -rqx 'req' '$D/app/.aidlc-kit/backup/'"

echo "attach on a fresh clone"
new_sandbox
kit init "$W" --docs-repo "$D" --yes >/dev/null 2>&1
git -C "$W" add .gitignore && git -C "$W" commit -qm "ignore artifacts"
git clone -q "$W" "$SB/my work/clone"
C="$SB/my work/clone"
check_not "attach without a docs repo fails" kit attach "$C"
check "attach --docs-repo with --name" kit attach "$C" --docs-repo "$D" --name app
check "clone sees the docs" grep -qx req "$C/aidlc-docs/requirements.md"
check "clone has a link" is_link "$C/aidlc-docs"
check "clone working tree is clean" bash -c "[ -z \"\$(git -C '$C' status --porcelain)\" ]"
check_not "attach with an unknown name fails" kit attach "$C" --docs-repo "$D" --name nope
check_not "attach refuses --path" kit attach "$C" --path x/
git clone -q "$W" "$SB/laptop"
check "a clone in a differently named folder attaches without --name" kit attach "$SB/laptop" --docs-repo "$D"
check "...using the folder named in the committed .gitignore block" grep -qx req "$SB/laptop/aidlc-docs/requirements.md"
check "...and its working tree stays clean" bash -c "[ -z \"\$(git -C '$SB/laptop' status --porcelain)\" ]"
check "--name still wins over the .gitignore block" bash -c "bash '$CLI' attach '$SB/laptop' --docs-repo '$D' --name other < /dev/null 2>&1 | grep -q \"no record for 'other'\""
rm -f "$SB/laptop/.git/aidlc-kit/state"
check "...and says where the name came from" bash -c "bash '$CLI' attach '$SB/laptop' --docs-repo '$D' < /dev/null 2>&1 | grep -q \"Docs-repo folder: 'app', as named in\""
# a block written before the name line existed
sed -i.bak '/^# docs-repo folder: /d' "$W/.gitignore" && rm -f "$W/.gitignore.bak"
git -C "$W" commit -qam "older block"
git clone -q "$W" "$SB/old-clone"
kit attach "$SB/old-clone" --docs-repo "$D" --name app > "$SB/out" 2>&1
check "attach with an older block (and --name) adds the name line" grep -qx "# docs-repo folder: app" "$SB/old-clone/.gitignore"
check "...and says to commit it" grep -q "block was updated (it now names the docs-repo folder); commit it" "$SB/out"

echo "AIDLC_KIT_SIMULATE_NO_SYMLINKS (CI's stand-in for Windows without Developer Mode)"
new_sandbox
check "init" env AIDLC_KIT_SIMULATE_NO_SYMLINKS=1 bash "$CLI" init "$W" --docs-repo "$D" --yes
check "no path is a symlink" bash -c "! grep -q '|symlink$' '$W/.git/aidlc-kit/state'"
check "files use copy mode" grep -qx "mode=graph.json|copy" "$W/.git/aidlc-kit/state"
case "$(uname -s)" in   # as IS_WINDOWS in lib/common.sh
  MINGW*|MSYS*|CYGWIN*) check "folders use junctions" grep -qx "mode=aidlc-docs/|junction" "$W/.git/aidlc-kit/state" ;;
esac

echo "profiles detected from the docs repo"
new_sandbox
rm -rf "$W/graphify-out" "$W/graph.json"
mkdir -p "$D/app/graphify-out" && echo "<html>old" > "$D/app/graphify-out/graph.html"
check "init without --profile" kit init "$W" --docs-repo "$D" --yes
check "graphify is managed: its output exists in the docs repo" grep -q old "$W/graphify-out/graph.html"
new_sandbox
rm -rf "$W/graphify-out" "$W/graph.json"
mkdir -p "$D/app/graphify-out" && echo "<html>old" > "$D/app/graphify-out/graph.html"
kit init "$W" --docs-repo "$D" --profile aidlc-v1 --yes >/dev/null 2>&1
check_not "set up with only aidlc-v1: doctor reports the docs repo's graphify-out/" kit doctor "$W"
check "...as unmanaged, with the adopt command" bash -c "bash '$CLI' status '$W' < /dev/null 2>&1 | grep -q 'unmanaged: graphify-out/ (profile graphify; in the docs repo, not linked here)'"
check "adopt links it" kit adopt graphify-out/ --repo "$W" --yes
check "...and it's there" grep -q old "$W/graphify-out/graph.html"

echo "the managed .gitignore block"
new_sandbox
kit init "$W" --docs-repo "$D" --yes >/dev/null 2>&1
git -C "$W" add .gitignore && git -C "$W" commit -qm ignore
echo "scratch/" >> "$W/.gitignore"   # the user's own, uncommitted edit
git clone -q "$W" "$SB/c2"
# in the file's own line endings, as an editor would (CRLF where git checks out CRLF)
eol='\n'; if [ -n "$(tr -cd '\r' < "$SB/c2/.gitignore" | head -c 1)" ]; then eol='\r\n'; fi
# shellcheck disable=SC2059  # eol is our own escape sequence
printf "scratch/$eol" >> "$SB/c2/.gitignore"
kit attach "$SB/c2" --docs-repo "$D" > "$SB/out" 2>&1
check "the user's own .gitignore edit isn't reported as a block update" bash -c "! grep -q 'block was updated' '$SB/out'"
# the name line twice (a bad merge): the first one counts
awk '{ print } /^# docs-repo folder: /{ print }' "$W/.gitignore" > "$SB/gi" && cp "$SB/gi" "$W/.gitignore"
git clone -q "$W" "$SB/c3"; cp "$SB/gi" "$SB/c3/.gitignore"
check "a doubled name line still names the folder" kit attach "$SB/c3" --docs-repo "$D"
grep -v '^# <<< aidlc-workspace-kit <<<' "$W/.gitignore" > "$SB/gi" && cp "$SB/gi" "$W/.gitignore"
check_not "a block without its end line: init stops" kit init "$W" --docs-repo "$D" --yes
check "...and leaves .gitignore as it was" cmp -s "$SB/gi" "$W/.gitignore"

echo "naming, custom paths, profiles"
new_sandbox
check "--name maps to another docs folder" kit init "$W" --docs-repo "$D" --name app-dev --yes
check "stored under the mapped name" test -f "$D/app-dev/aidlc-docs/requirements.md"

new_sandbox
mkdir -p "$W/docs/ai"; echo fork > "$W/docs/ai/notes.md"
check "--path for a nested custom dir" kit init "$W" --docs-repo "$D" --profile aidlc-v1 --path docs/ai/ --yes
check "nested dir linked" is_link "$W/docs/ai"
check "nested dir stored at the same relative path" test -f "$D/app/docs/ai/notes.md"
check "nested path ignored" grep -qx "/docs/ai" "$W/.gitignore"

new_sandbox
mkdir -p "$SB/profiles"
printf 'name=myfork\npath=fork-docs/\n' > "$SB/profiles/myfork.profile"
mkdir -p "$W/fork-docs"; echo f > "$W/fork-docs/a.md"
check "AIDLC_PROFILES_DIR adds a fork profile that is auto-detected" env AIDLC_PROFILES_DIR="$SB/profiles" bash "$CLI" init "$W" --docs-repo "$D" --yes
check "fork path managed" is_link "$W/fork-docs"
check "fork profile recorded" grep -qx "profile=myfork" "$D/app/.aidlc-kit/record"

new_sandbox
mkdir -p "$D/.aidlc-kit/profiles"
printf 'name=graphify\npath=graphify-out/\n' > "$D/.aidlc-kit/profiles/graphify.profile"
check "a docs-repo profile overrides a built-in one" kit init "$W" --docs-repo "$D" --profile graphify --yes
check "override applied (graph.json not managed)" bash -c "! grep -q 'path=graph.json' '$D/app/.aidlc-kit/record'"

new_sandbox
mkdir -p "$SB/profiles"
printf 'name=evil\npath=../outside/\n' > "$SB/profiles/evil.profile"
check_not "profile with '..' is rejected" env AIDLC_PROFILES_DIR="$SB/profiles" bash "$CLI" init "$W" --docs-repo "$D" --yes
printf 'version=2\nname=future\npath=x/\n' > "$SB/profiles/evil.profile"
check_not "newer profile format is rejected" env AIDLC_PROFILES_DIR="$SB/profiles" bash "$CLI" init "$W" --docs-repo "$D" --yes
check_not "unknown profile name is rejected" kit init "$W" --docs-repo "$D" --profile nope --yes
check_not "--path with .. is rejected" kit init "$W" --docs-repo "$D" --path ../x/ --yes
check_not "--path into .git is rejected" kit init "$W" --docs-repo "$D" --path .git/hooks/ --yes
check_not "bad --name is rejected" kit init "$W" --docs-repo "$D" --name "../x" --yes

new_sandbox
rm -rf "$W/aidlc-docs" "$W/graphify-out" "$W/graph.json" "$W/.aidlc-rule-details"
check_not "nothing detected -> clear error" kit init "$W" --docs-repo "$D" --yes
check "a fresh project can be initialised by profile" kit init "$W" --docs-repo "$D" --profile aidlc-v1 --yes
check "empty docs dir created and linked" bash -c "test -d '$D/app/aidlc-docs' && test -L '$W/aidlc-docs'"

echo "safety"
new_sandbox
check_not "docs repo inside the working repo is rejected" kit init "$W" --docs-repo "$W/sub" --yes
mkdir -p "$W/sub"
check_not "docs repo inside the working repo is rejected (existing dir)" kit init "$W" --docs-repo "$W/sub" --yes
check_not "working repo inside the docs repo is rejected" kit init "$W" --docs-repo "$SB" --yes
check_not "not a git repo is rejected" kit init "$SB" --docs-repo "$D" --yes

new_sandbox
git -C "$W" add -f aidlc-docs && git -C "$W" commit -qm "tracked docs"
check "tracked artifacts produce a warning with the fix" bash -c "bash '$CLI' init '$W' --docs-repo '$D' --profile aidlc-v1 --yes 2>&1 | grep -q 'git rm -r --cached -- aidlc-docs'"

echo "link modes"
new_sandbox
check "--link-mode copy" kit init "$W" --docs-repo "$D" --link-mode copy --yes
check "copy mode leaves a real directory" test -d "$W/aidlc-docs" -a ! -L "$W/aidlc-docs"
check "copy mode also stored the docs" test -f "$D/app/aidlc-docs/requirements.md"
check "status shows copy mode" bash -c "bash '$CLI' status '$W' | grep -q 'aidlc-docs/.*copy'"

new_sandbox
if [ "$FILE_LINKS" = 1 ]; then
  check "--link-mode link succeeds where file links work" kit init "$W" --docs-repo "$D" --link-mode link --yes
else
  check_not "--link-mode link fails for files where file links are unavailable" kit init "$W" --docs-repo "$D" --link-mode link --yes
fi

echo "detach"
new_sandbox
kit init "$W" --docs-repo "$D" --yes >/dev/null 2>&1
check "detach" kit detach "$W" --yes
check "link replaced with a real copy" test -d "$W/aidlc-docs" -a ! -L "$W/aidlc-docs"
check "copy has the content" grep -qx req "$W/aidlc-docs/requirements.md"
check "docs repo untouched" test -f "$D/app/aidlc-docs/requirements.md"
check "gitignore block removed, user lines kept" bash -c "! grep -q aidlc-workspace-kit '$W/.gitignore' && grep -qx node_modules/ '$W/.gitignore'"
check "machine state removed" test ! -e "$W/.git/aidlc-kit/state"
check_not "status after detach reports not set up" kit status "$W"

echo "line endings"
new_sandbox
printf 'node_modules/\r\n' > "$W/.gitignore"
kit init "$W" --docs-repo "$D" --yes >/dev/null 2>&1
check "CRLF .gitignore keeps CRLF on every line" bash -c "[ \$(grep -c '' '$W/.gitignore') -eq \$(tr -cd '\r' < '$W/.gitignore' | wc -c) ]"
cp "$W/.gitignore" "$SB/before"
kit init "$W" >/dev/null 2>&1
check "re-run leaves an unchanged .gitignore byte-identical" cmp -s "$SB/before" "$W/.gitignore"

echo "config file"
new_sandbox
printf 'AIDLC_DOCS_REPO=%s\nAIDLC_LINK_MODE=copy\n' "$D" > "$SB/kit.conf"
check "settings from the config file" env AIDLC_KIT_CONFIG="$SB/kit.conf" bash "$CLI" init "$W" --yes
check "config link mode honoured" test ! -L "$W/aidlc-docs"
printf 'AIDLC_NOPE=1\n' > "$SB/bad.conf"
check_not "unknown config key rejected" env AIDLC_KIT_CONFIG="$SB/bad.conf" bash "$CLI" status "$W"

echo "review regressions"
# R1: many tracked files must not SIGPIPE-abort init under pipefail
new_sandbox
mkdir -p "$W/aidlc-docs/many"
i=0; while [ $i -lt 1500 ]; do : > "$W/aidlc-docs/many/a-fairly-long-generated-file-name-for-listing-$i.md"; i=$((i + 1)); done
git -C "$W" add -f aidlc-docs >/dev/null 2>&1 && git -C "$W" commit -qm "many tracked docs"
check "init survives a large tracked listing (pipefail)" kit init "$W" --docs-repo "$D" --profile aidlc-v1 --yes
check "and moved everything" test -f "$D/app/aidlc-docs/many/a-fairly-long-generated-file-name-for-listing-1499.md"

# R2: --link-mode link must fail BEFORE moving anything when links can't be made
# (AIDLC_KIT_SIMULATE_NO_LINKS makes this run on every platform)
new_sandbox
check_not "--link-mode link refuses up front" env AIDLC_KIT_SIMULATE_NO_LINKS=1 bash "$CLI" init "$W" --docs-repo "$D" --link-mode link --yes
check "nothing was moved" test -d "$W/aidlc-docs" -a ! -L "$W/aidlc-docs" -a ! -e "$D/app/aidlc-docs"
check "no record written" test ! -e "$D/app/.aidlc-kit/record"
check "no preflight leftovers in the docs repo" bash -c "! ls -A '$D' | grep -q preflight"
check "no preflight leftovers in .git" bash -c "! ls -A '$W/.git/aidlc-kit' 2>/dev/null | grep -q preflight"
check "auto mode falls back to copies when links are unavailable" env AIDLC_KIT_SIMULATE_NO_LINKS=1 bash "$CLI" init "$W" --docs-repo "$D" --yes
check "every path is a copy" bash -c "test ! -L '$W/aidlc-docs' && test ! -L '$W/graphify-out' && bash '$CLI' status '$W' | grep -c ' copy ' | grep -qx 3"
new_sandbox
kit init "$W" --docs-repo "$D" --profile aidlc-v1 --yes >/dev/null 2>&1
check "preflight is skipped when nothing needs linking" env AIDLC_KIT_SIMULATE_NO_LINKS=1 bash "$CLI" attach "$W" --link-mode link
# R2b: record and state exist even if apply is interrupted -> re-run resumes
new_sandbox
kit init "$W" --docs-repo "$D" --profile aidlc-v1 --yes >/dev/null 2>&1
mkdir -p "$W/graphify-out"; echo g > "$W/graphify-out/g.html"
check "re-running init adds and applies new paths (resume path)" kit init "$W" --path graphify-out/ --yes
check "resumed path linked" is_link "$W/graphify-out"

# R3: folder names with spaces/odd characters get a safe default name
new_sandbox
mkdir -p "$SB/my work/My App (old)"; git -C "$SB/my work/My App (old)" init -q -b main
mkdir -p "$SB/my work/My App (old)/aidlc-docs"; echo x > "$SB/my work/My App (old)/aidlc-docs/a.md"
check "init in 'My App (old)' without --name" kit init "$SB/my work/My App (old)" --docs-repo "$D" --yes
check "default name sanitised to My-App-old" test -f "$D/My-App-old/aidlc-docs/a.md"
check "bad --name error mentions --name" bash -c "bash '$CLI' init '$W' --docs-repo '$D' --name 'a b' --yes 2>&1 | grep -q -- '--name'"

# R4: settings of the removed sync.sh scripts get a pointer to their replacement
new_sandbox
printf 'AIDLC_DATA_DIR=%s\n' "$SB/legacy-data" > "$SB/old.conf"
check_not "an old sync.sh setting is rejected" env AIDLC_KIT_CONFIG="$SB/old.conf" bash "$CLI" init "$W" --docs-repo "$D" --yes
check "...with what replaced it" bash -c "AIDLC_KIT_CONFIG='$SB/old.conf' bash '$CLI' init '$W' --docs-repo '$D' --yes 2>&1 | grep -q 'use AIDLC_DOCS_REPO'"
check "...before anything moved" test -d "$W/aidlc-docs" -a ! -L "$W/aidlc-docs"

# R5: relative paths in a config file resolve against the file's directory
new_sandbox
mkdir -p "$SB/cfg"
printf 'AIDLC_DOCS_REPO=../my docs\n' > "$SB/cfg/kit.conf"
check "relative config path works from another cwd" bash -c "cd '$SB/my work' && AIDLC_KIT_CONFIG='$SB/cfg/kit.conf' bash '$CLI' init app --yes"
check "resolved next to the config file" test -f "$D/app/aidlc-docs/requirements.md"

# R6: attach repairs a link whose docs folder was deleted
new_sandbox
kit init "$W" --docs-repo "$D" --yes >/dev/null 2>&1
rm -rf "$D/app/graphify-out"
check "attach repairs a dangling link without --yes (non-interactive)" kit attach "$W"
check "docs folder recreated and link healthy" kit status "$W"

# R6b: a relative dangling link is resolved against the link's own directory
if [ "$FILE_LINKS" = 1 ]; then
  new_sandbox
  mkdir -p "$SB/a" "$SB/b" "$SB/elsewhere"
  # nativestrict, as the kit does: Git Bash's plain `ln -s` makes no real symlink
  MSYS=winsymlinks:nativestrict ln -s "../b/target" "$SB/a/link"
  check "relative dangling link matches its real destination from any cwd" bash -c "cd '$SB/elsewhere' && . '$KIT/lib/common.sh' && . '$KIT/lib/link.sh' && dangling_link_to '$SB/a/link' '$SB/b/target'"
  check_not "and does not match a different destination" bash -c "cd '$SB/elsewhere' && . '$KIT/lib/common.sh' && . '$KIT/lib/link.sh' && dangling_link_to '$SB/a/link' '$SB/elsewhere/target'"
else
  ok "relative dangling links (skipped: needs real symlinks; covered on Linux/macOS CI)"
fi

# R7: detach leaves links that point somewhere else alone
new_sandbox
kit init "$W" --docs-repo "$D" --profile aidlc-v1 --yes >/dev/null 2>&1
mkdir -p "$SB/elsewhere"; echo other > "$SB/elsewhere/o.md"
rm -f "$W/aidlc-docs" 2>/dev/null || rmdir "$W/aidlc-docs"
if ! MSYS=winsymlinks:nativestrict ln -s "$SB/elsewhere" "$W/aidlc-docs" 2>/dev/null; then
  MSYS_NO_PATHCONV=1 cmd /c mklink /J "$(cygpath -w "$W/aidlc-docs")" "$(cygpath -w "$SB/elsewhere")" >/dev/null 2>&1
fi
check "detach with a foreign link succeeds" kit detach "$W" --yes
check "foreign link left in place" bash -c "test -L '$W/aidlc-docs' && test -f '$W/aidlc-docs/o.md'"
check "foreign target untouched" test -f "$SB/elsewhere/o.md"

# R8: wildcards are rejected in path=/--path but allowed in exclude=
new_sandbox
check_not "--path with '*' rejected" kit init "$W" --docs-repo "$D" --path "docs/*/" --yes
mkdir -p "$SB/profiles"; printf 'name=globby\npath=docs*/\n' > "$SB/profiles/g.profile"
check_not "profile path= with '*' rejected" env AIDLC_PROFILES_DIR="$SB/profiles" bash "$CLI" init "$W" --docs-repo "$D" --yes
mkdir -p "$W/aidlc/spaces/default"; echo s > "$W/aidlc/spaces/default/state.md"
check "exclude= globs accepted (aidlc-v2)" kit init "$W" --docs-repo "$D" --profile aidlc-v2 --yes
check "exclude written to the docs .gitignore" grep -qxF "/aidlc/spaces/*/intents/**/.aidlc-engine/" "$D/app/.gitignore"

summary
