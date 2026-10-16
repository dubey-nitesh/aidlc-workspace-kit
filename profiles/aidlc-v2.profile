# AWS AI-DLC 2.x (the `aidlc` CLI): records under aidlc/spaces/<space>/...
# The excludes mirror the machine-local entries of the .gitignore block AI-DLC
# ships (harness/*/dot-gitignore upstream): per-user cursors, this clone's id
# and sessions, engine state. They must never reach the docs repo, where a
# shared .aidlc-clone-id would make two machines write the same audit shard.
version=1
name=aidlc-v2
description=AWS AI-DLC 2.x (output in aidlc/)
detect=aidlc/spaces/
path=aidlc/
exclude=aidlc/active-space
exclude=aidlc/spaces/*/intents/active-intent
exclude=aidlc/.aidlc-*
exclude=aidlc/active-memory/
exclude=aidlc/diagnostics/
exclude=aidlc/spaces/*/intents/.aidlc-*
exclude=aidlc/spaces/*/intents/*/.aidlc-*
exclude=aidlc/spaces/*/intents/*/runtime-graph.json
exclude=aidlc/spaces/*/intents/**/.aidlc-engine/
exclude=aidlc/spaces/*/intents/**/.aidlc-sensors/
exclude=aidlc/spaces/*/knowledge/documentkb/.journal/
exclude=aidlc/spaces/*/knowledge/.sources.local.json
