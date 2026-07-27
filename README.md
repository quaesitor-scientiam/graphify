# graphify

Builds a compact **symbol graph** of a codebase — declarations plus the
relationships between them — so an AI tool can understand a project's structure
at a fraction of the tokens of the raw source.

## Why

Feeding whole files to an AI is expensive. A `skeleton` view keeps the module
layout, imports, and every declaration's *signature* while dropping function
bodies — the part that dominates token count but rarely matters for navigation.

```
// demo.v
module demo
  import os
struct User
const max_users
pub fn (u User) greeting() string { ... }
fn greet(name string) string { ... }
fn main() { ... }
```

## Measured savings

Benchmarked on real external V codebases (`vlib/v/ast`, `vlib/v/parser`, `c2v`)
with [`cmd/bench`](cmd/bench/main.v) — see [BENCH.md](BENCH.md):

- **Artifact ceiling: ~10–20× fewer tokens** for navigation/mapping (full source
  vs skeleton, apples-to-apples) — 89–95% reduction.
- **Live end-to-end** (real `claude -p` A/B, 3 runs, opus): **~1.5× fewer
  unique-input and ~2.2× fewer total tokens**, in ~half the turns, vs. an
  *efficient* grep-based baseline. The ceiling is theoretical max; this is what
  actually lands against a competent baseline.

That's the honest headline — **a real but modest ~1.5–2.2× live, not 70×.**
Single-symbol deep dives save less; the figure depends on whether the model
would otherwise have loaded a whole file. graphify's value is concentrated in
"where is X / what connects to it / what's in here", not in reading bodies.

For the gold-standard test — real Claude Code sessions, same task wired vs. not,
comparing actual API tokens — see [bench/live/PROTOCOL.md](bench/live/PROTOCOL.md)
and `bench/live/count_tokens.ps1`.

## Design

Two backends behind one graph model:

| Backend          | Files       | Source                                   |
| ---------------- | ----------- | ---------------------------------------- |
| **V native**     | `.v`        | `v.parser` + `v.ast` (full fidelity)     |
| **tree-sitter**  | other langs | the `tree_sitter` wrapper (per-language) |

Using V's own compiler frontend for V avoids the toy `vgrammer` grammar and the
gaps in the minimal C binding. Tree-sitter covers everything else.

Pipeline: `walk files -> backend.extract(file) -> []Symbol + []Edge -> Graph -> emit`.

### Model

- `Symbol{ id, name, kind, signature, file, line, is_pub, parent }`
- `Edge{ from, to, kind }` — kinds: `defines`, `calls`, `imports`, `implements`, `embeds`, `references`

### Emitters

- `emit_skeleton()` — body-less code view (the token-saver)
- `emit_json()` — full graph for tooling

## Usage

Mirrors the Python [Graphify](https://medium.com/jin-system-architect/graphify-the-knowledge-graph-that-ends-your-codebases-token-tax-819b77f2ec58)
command surface: extract once, then traverse instead of re-reading files.

```
graphify extract  . --out S:\graph_data        # build graph -> a central dir
graphify overview                              # compact summary (counts + key symbols)
graphify query    "auth flow" --budget 2000    # token-bounded traversal
graphify path     build_graph emit_skeleton    # shortest path between symbols
graphify explain  build_graph                  # a symbol + its relationships
graphify body     build_graph                  # just that declaration's source
graphify skeleton .                            # body-less skeleton of a path
```

Queries read `./graphify-out/graph.json` by default. Override with `--graph <file>`.

**Central store (recommended for multiple projects).** Set `GRAPHIFY_STORE` once;
then `extract` auto-files each project under `<store>/<project-name>/`, and queries
resolve the graph for whatever project directory you're in — no path juggling:

```
$env:GRAPHIFY_STORE = 'S:\graph_data'
cd my-project ; graphify extract .      # -> S:\graph_data\my-project\graph.json
graphify overview                        # resolves S:\graph_data\my-project\graph.json
```

Resolution order: `--graph` > `GRAPHIFY_GRAPH` > `GRAPHIFY_STORE`/<cwd-name> > `./graphify-out`.

`extract` writes a Graphify-style bundle to `graphify-out/`:

- `graph.json` — persistent, queryable graph (read by query/path/explain)
- `GRAPH_REPORT.md` — counts, most-connected symbols, suggested queries
- `manifest.json` — metadata + counts

Library:

```v
import graphify

g := graphify.build_graph(graphify.Options{ root: 'path/to/project' })
graphify.write_bundle(g, 'graphify-out')!
println(g.query('auth flow', 2000, false))
```

## MCP server (for Claude Code)

`cmd/mcp` is a JSON-RPC-over-stdio MCP server that loads a persisted
`graph.json` once and exposes graph traversal as tools, so the model queries
the graph instead of reading source files:

| Tool | Purpose |
| --- | --- |
| `overview` | body-less skeleton map of the whole codebase |
| `query_graph(text, budget?, dfs?)` | token-bounded traversal from matching symbols |
| `get_node(node)` | a symbol + its relationships (defines, references, embeds, calls), each with file:line |
| `get_body(node)` | the source of ONE declaration by name (instead of reading its file) |
| `get_neighbors(node)` | names of all directly linked symbols |
| `shortest_path(a, b)` | relationship path between two symbols |

Build and register (project-scoped via `.mcp.json`, already in this repo):

```
v -prod -gc none -o bin/graphify.exe cmd/cli   # -gc none: extract is one-shot and short-lived;
                                                # Boehm GC caused a ~500x slowdown on the graph.json
                                                # write path (616s -> 32s on the full vlang repo).
                                                # Do NOT add -gc none to graphify-mcp below — it's a
                                                # long-lived server process and needs bounded memory.
v -prod -o bin/graphify-mcp.exe cmd/mcp
bin\graphify.exe extract .                 # produce graphify-out/graph.json first
```

```json
{
  "mcpServers": {
    "graphify": {
      "command": "S:\\vProjects\\graphify\\bin\\graphify-mcp.exe",
      "args": ["S:\\vProjects\\graphify\\graphify-out\\graph.json"]
    }
  }
}
```

Or register globally: `claude mcp add graphify -- S:\vProjects\graphify\bin\graphify-mcp.exe <path-to-graph.json>`.
Smoke-test the protocol without Claude: `Get-Content cmd/mcp/test_session.jsonl | bin\graphify-mcp.exe graphify-out/graph.json`.

## Operational scripts

Beyond the `graphify` CLI itself, `bin/` and `bench/` hold PowerShell helpers
built for running this against a large external repo (vlang) day to day.

**One-time setup:** copy `graphify.config.ps1.example` to `graphify.config.ps1`
(repo root) and edit the two paths for your machine:

```
$GraphifyVlangRepo = 'S:\repo\vlang'   # the external repo these scripts track
$GraphifyStore     = 'S:\graph_data'   # central store for extracted graphs
```

`graphify.config.ps1` is gitignored — each machine keeps its own copy, and
`update-vlang-graph.ps1`, `switch-vlang-graph.ps1`, and `extract_bench.ps1`
(its default `-Source`) all read from it. If the file is missing, each script
errors with a pointer back to the `.example` template instead of silently
using the wrong paths.

### `bin/update-vlang-graph.ps1` — daily graph refresh

Pulls the target repo and re-extracts only if there were new commits. Wired
into Windows Task Scheduler for a nightly run; can also be run by hand.

```
bin\update-vlang-graph.ps1              # git pull, extract only if new commits
bin\update-vlang-graph.ps1 -NoPull      # skip the pull, always re-extract
```

Logs to `S:\graph_data\update.log`.

### `bin/switch-vlang-graph.ps1` — branch-aware graph switching

Extracts (or reuses) a graph for a specific branch and repoints the MCP
server's `~/.claude.json` config at it. `master`/`main` keep the graph at
`<store>\vlang`; other branches get their own `<store>\vlang-<branch>`.

```
bin\switch-vlang-graph.ps1                             # graph for the current branch
bin\switch-vlang-graph.ps1 -Branch feature-x           # graph for a specific branch
bin\switch-vlang-graph.ps1 -Branch feature-x -Checkout # also `git checkout` that branch first
bin\switch-vlang-graph.ps1 -Force                      # re-extract even if a graph already exists
```

Restart Claude Code after switching so the MCP server picks up the new graph.

### `bench/session_stats.ps1` — token-free MCP usage stats

Scans Claude Code's session transcripts and reports graphify tool-call counts
per session (main-agent vs. subagent split), at zero token/API cost.

```
bench\session_stats.ps1                  # last 14 days
bench\session_stats.ps1 -Days 30         # look back further
bench\session_stats.ps1 -IncludeBench    # include graphify's own bench sessions
```

### `bench/extract_bench.ps1` — repeatable extraction benchmark

Times `graphify extract` end-to-end against a target repo, clearing the
output directory first so every run starts cold.

```
bench\extract_bench.ps1                          # defaults: vlang repo, temp out dir
bench\extract_bench.ps1 -Runs 3                  # average over 3 runs
bench\extract_bench.ps1 -Source S:\myproject -Out S:\temp\gf-bench-myproject
```

## Claude Code wiring

`.claude/` makes Claude Code reach for the graph automatically (this repo
dogfoods it on itself):

- **`.claude/skills/graphify/SKILL.md`** — tells Claude to query the graph (MCP
  tools or CLI) for structural questions and drill into bodies by `file:line`.
- **`.claude/commands/graphify.md`** — `/graphify [path]` rebuilds the graph and
  summarizes `GRAPH_REPORT.md`.
- **`.claude/settings.json`** — a `SessionStart` hook injects standing guidance,
  and a `PreToolUse` hook on `Grep|Glob` reminds Claude to consult the graph
  before scanning files. Both call `.claude/hooks/graphify_hook.ps1`
  (pwsh, non-blocking, emits `hookSpecificOutput.additionalContext`).
- **`.githooks/post-commit`** — rebuilds the graph after each commit. Enable with
  `git config core.hooksPath .githooks`.

To wire a *different* project, copy `.claude/` (and `.mcp.json`) into it and
update the absolute paths to point at this repo's `bin/`.

## Sharing a graph across machines / OSes

`graph.json` stores paths with forward slashes, so a graph extracted on one OS
resolves on another (Windows / WSL-Linux / macOS). All structural queries
(`query_graph`, `get_node`, `shortest_path`, `overview`, `skeleton`) need *only*
the graph file — no source. `get_body` reads the actual source, so on a different
machine point it at the local checkout:

```
graphify body <symbol> --graph shared\graph.json --source-dir /path/to/local/checkout
```

For the MCP server, pass the local source root as a 2nd arg (or set
`GRAPHIFY_SOURCE_DIR`):

```json
{ "mcpServers": { "graphify": {
  "command": "…/graphify-mcp", "args": ["…/graph.json", "/path/to/local/checkout"] } } }
```

## Status

Phase 1 (engine) — done; V only.

- [x] V backend: module, imports, structs, enums, interfaces, consts, fns/methods, body-less signatures, call edges
- [x] `graphify-out/` bundle: `graph.json`, `GRAPH_REPORT.md`, `manifest.json`
- [x] `extract` / `query` (BFS/DFS + token budget) / `path` / `explain` / `body` / `skeleton`
- [x] **resilient extraction** — files parsed in worker-process batches, so a file that panics V's parser is skipped + reported, not fatal. Torture-tested on the full V compiler repo: 5593 files → 89,368 symbols in ~111s, 3 unparseable files isolated.
- [x] Phase 2: MCP server (`query_graph`, `get_node`, `get_neighbors`, `shortest_path`) + `.mcp.json`
- [x] Phase 3: Claude Code wiring — `SKILL.md`, `/graphify`, `SessionStart` + `PreToolUse` hooks, git rebuild hook
- [ ] Phase 4: doc/rationale capture, edge provenance (`EXTRACTED`/`INFERRED`), SHA256 incremental cache, other languages via tree-sitter
- [ ] share one `ast.Table` across files for accurate cross-file call resolution
- [ ] Phase 5: Leiden communities, `merge-graphs`, GraphML/Cypher/SVG, `graph.html`
