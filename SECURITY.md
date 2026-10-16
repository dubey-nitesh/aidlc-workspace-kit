# Security policy

`aidlc-kit` is a local bash tool that moves, links and copies files between a project and a docs
repo you configure, and installs git and Claude Code hooks. The areas that matter most:

- path handling (`lib/common.sh`, `lib/commands.sh`, `lib/save.sh`): it must never read, write or
  delete outside the managed paths of the project and its folder in the docs repo;
- config, profile and record parsing (`lib/common.sh`, `lib/profiles.sh`, `lib/record.sh`): these
  files are parsed as `KEY=VALUE`, never sourced or executed;
- the hooks (`lib/hooks.sh`): what they run, and that they never push anything but the docs repo.

Please report vulnerabilities privately through GitHub's **"Report a vulnerability"** button
under the repo's Security tab rather than a public issue. Expect an initial reply within a week.
