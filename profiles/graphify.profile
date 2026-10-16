# Graphify knowledge-graph output. Its cache/ (AST cache, absolute local paths
# and mtimes in stat-index.json) is rebuilt by `graphify update` without an
# LLM, differs per machine and changes on every run: kept out of the docs repo.
version=1
name=graphify
description=Graphify (graph.json + graphify-out/)
detect=graphify-out/
detect=graph.json
path=graphify-out/
path=graph.json
exclude=graphify-out/cache/
