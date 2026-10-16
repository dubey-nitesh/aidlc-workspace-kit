# Contributing

Thanks for helping. This is a small bash toolkit; keeping it small and dependency-free is a goal.
How it works is written down in [docs/DESIGN.md](docs/DESIGN.md) — read the section for the part
you're changing first.

## Dev loop

```bash
bash tests/core.sh    # init / attach / status / detach, profiles, links
bash tests/save.sh    # save: lock, commit, push, copy-mode sync
bash tests/hooks.sh   # git + Claude Code hooks, doctor, adopt
bash tests/rules.sh   # AI-DLC rules detection, skill install
bash tests/migrate.sh # migrate-legacy
shellcheck bin/aidlc-kit lib/*.sh tests/*.sh   # CI runs it; `pip install shellcheck-py` gets you one
```

The tests need only bash, git and coreutils. They create throwaway repos (with spaces in their
paths) under your temp folder. `AIDLC_KIT_SIMULATE_NO_LINKS=1` makes every link attempt fail, so
the copy-mode code paths can be exercised on any machine.

## Guidelines

- Target bash 3.2+ (macOS default), GNU and BSD coreutils, and Git Bash on Windows. No `rsync`,
  no GNU-only flags. CI runs the suites on Linux, macOS and Windows.
- New settings go through `lib/common.sh` (`KNOWN_KEYS`, defaults, validation), are documented
  in `aidlc-kit.conf.example`, the README and docs/DESIGN.md, and have a test.
- Anything that deletes, moves or overwrites files needs a dry-run path, a refusal case and a
  test for both. Never record work (state, manifest) that didn't actually happen.
- Hooks must never fail or block the user's commit, push or Claude Code turn.
- New tools or forks are supported with a profile (`profiles/*.profile`), not with code.
- Don't commit private project docs; `aidlc-kit.conf` is gitignored on purpose.

Open an issue before large changes (new commands, new link strategies).
