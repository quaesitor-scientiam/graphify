---
name: graphify
description: Navigate or understand this codebase via the graphify code graph instead of grepping or reading whole files — find where things are defined, what calls/references/embeds what, how pieces connect, and fetch single declarations by name.
---

# graphify — query the graph, don't read files

For structural questions ("where is X", "what calls/references X", "how do A and
B connect", "what's in here"), use the graph instead of Grep/Glob/Read. Every
result carries `file:line`, so drill in with a targeted read — never load a whole
file to find one thing.

Tools (MCP `graphify`, or `S:\vProjects\graphify\bin\graphify.exe <cmd>` via Bash):

- `overview` / `skeleton <path>` — body-less map of the codebase
- `query_graph(text)` / `query` — token-bounded traversal from matching symbols
- `get_node(node)` / `explain` — a symbol + its relationships (defines, references, embeds, calls), each with `file:line`
- `get_body(node)` / `body` — the source of ONE declaration (instead of reading its file)
- `shortest_path(a, b)` / `path` — how two symbols connect

Workflow: map with `overview`/`query` → inspect with `get_node` → read only what
you need with `get_body`. Refresh after code changes: `graphify extract .` or
`/graphify`. Covers V (`.v`) files.
