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
  vs skeleton, apples-to-apples) — 89–95% reduction. This is a theoretical
  maximum, not what a session gets.
- **Live end-to-end** (real `claude -p` A/B on a 2,885-file / 161-module
  corpus, both arms `--safe-mode` so neither inherits the user's graphify
  hooks):
  - **structural questions** ("where is X, what calls it, what's in this
    module"), n=3, opus: **~1.3× fewer unique-input tokens**.
  - **purpose/rationale questions** ("what is X for, why does it exist"),
    n=3, sonnet, warm-cache rounds: **~1.33× fewer unique-input tokens**,
    consistently — once `query` actually surfaces the doc it captures (see
    below), the model goes straight to one batched `explain` call per
    symbol instead of a full-body read.
  - **implementation walkthroughs** ("explain step by step what this
    function does internally"): **no gain** — these require reading the
    actual logic, and the graph is an extra hop before that read, not a
    substitute for it.

That's the honest headline — **~1.3× on structure, ~1.3× on rationale (once
wired correctly), ~1× on "explain this code".** Turn count and total tokens
looked better still but varied more run to run, so unique-input is the number
to quote.

Two findings are worth knowing before optimizing further:
- Call resolution went 53.7% → 82.9% and live savings did **not** move — for
  these tasks the bottleneck was never resolution accuracy.
- The rationale task initially **lost** (0.77× avg, 0.44×–1.06× round to
  round) despite being built to favor docs. Root cause: `query()`'s rendered
  output omitted the `doc` field entirely — only `explain` showed it — while
  the wired system prompt recommended `query` first. The model would query,
  get no doc text back, and fall back to reading a whole function body.
  Adding a one-line doc preview to `query()` and steering the prompt toward
  `explain` for named-symbol lookups turned that into the consistent ~1.33×
  win above. A benchmark claiming "docs help" is only as honest as the
  wiring that actually exercises the docs.

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

- `Symbol{ id, name, kind, signature, file, line, end_line, is_pub, parent, doc }` — `end_line` is what lets `get_body` read one declaration instead of a whole file; `doc` is the `//` block directly above it
- `Edge{ from, to, kind, provenance }` — kinds: `defines`, `calls`, `imports`, `implements`, `embeds`, `references`; `provenance` (`extracted`/`inferred`) is set on resolved `calls`, `embeds`, and `references` edges — see the edge provenance item in Status

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
- `.gf_cache.ndjson` — incremental cache: each file's content hash plus its
  extracted symbols/edges. A file whose hash matches the cache is reused
  as-is on the next `extract` instead of being reparsed — only new/changed
  files hit the parser. Safe to delete to force a full reparse.

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
- [x] **resilient extraction** — files parsed in worker-process batches across `nr_cpus()` concurrent workers, so a file that panics V's parser is skipped + reported, not fatal. Torture-tested on the full V compiler repo: 103,253 symbols in ~12s cold, 3 unparseable files isolated.
- [x] **extraction performance** — the full V compiler repo went 616s → ~12s, via two independent fixes. (1) `graphify.exe` is built `-gc none`: V's default Boehm GC costs roughly 590µs *per call* on the repeated small `strings.Builder` appends that writing `graph.json` is made of, which is not an allocation problem — isolated benchmarks showed the same loop run instantly with the writes stripped. Safe because the CLI is a one-shot process that exits; `graphify-mcp.exe` deliberately keeps the GC, being long-lived. (2) batch workers run concurrently rather than one at a time (32s → 12s), verified byte-identical against the sequential path.
- [x] Phase 2: MCP server (`query_graph`, `get_node`, `get_neighbors`, `shortest_path`) + `.mcp.json`
- [x] Phase 3: Claude Code wiring — `SKILL.md`, `/graphify`, `SessionStart` + `PreToolUse` hooks, git rebuild hook
- [x] **SHA256 incremental cache** (`.gf_cache.ndjson`) — a file whose content hash is unchanged since the last `extract` is reused as-is; only new/changed files are reparsed (~11s → ~4s on a full no-op re-run of the V compiler repo)
- [x] **call-edge disambiguation.** Call edges record the raw callee name and are matched to a declaration afterwards (`resolve_edges`). Ambiguity — not missing data — is the limit. Resolution narrows progressively, strongest signal first: globally unique name → method-vs-function (`x.foo()` can only be a method) → the caller's own file → its module → what the calling file can actually *see*, meaning its `import`s plus `builtin`, which V auto-imports. On the V compiler repo that takes **53.7% → 82.9%** of 167.6k call edges.
  Two ideas do most of the work. Candidates are compared by **id**, not by symbol count, so a function declared once per platform — `os.setenv` in both `environment.c.v` and `environment.js.v` — stops looking ambiguous: it is one function, and the shared id addresses it correctly. And an id is refused only when its declarations sit in separate **build units** that merely share a module name: every standalone `main` program, and every `_test.v` file, each of which V compiles as its own executable. Inside an ordinary module a repeat *cannot* be two different functions, because V would reject the redeclaration. Guessing there would point every consumer at whichever declaration was indexed first.
- [x] **doc/rationale capture** — the `//` block directly above a declaration becomes its `doc`, surfaced in full (capped at 8 lines) by `explain`/`get_node`, and as a one-line preview per result by `query`/`query_graph`. A blank line between comment and declaration means it is a header or a note about the code above, not documentation, so it is dropped. Read from source rather than the AST: in `.toplevel_comments` mode V reports only the *first* line of a contiguous block as a top-level node, and reading directly also keeps the parse in the cheaper `.skip_comments` mode. 15.8k declarations documented on the V compiler repo, 5.8k of them multi-line. The `query` preview was added after a live benchmark round showed it omitted `doc` entirely, which a suggested "`query` first" workflow turned into full-body reads instead of ever trying `explain` — see Measured savings.
- [x] **edge provenance** — every resolved `calls`, `embeds`, and `references` edge is tagged on `Edge.provenance`, persisted in `graph.json`: `extracted` when the name was globally unique (or, for `calls` only, the receiver's type came straight from the parser), `inferred` when narrowed among several real candidates by the referencing declaration's file/module/import-visibility locality — `resolve_type_ref` mirrors `resolve_callee` minus the calls-specific kind-match and self-receiver steps, since a type name has neither. `embeds`/`references` used to resolve *only* through the cruder, non-local, by-name-only check in `Index.resolve` at query time; giving them the same locality narrowing as calls is a real accuracy gain, not just a label — `references` resolution on the V compiler repo went 20.4% → 31.6% (4,065 → 6,298 of 19,931). Full breakdown in `GRAPH_REPORT.md`'s "Edges by provenance" section: calls 18,341 extracted / 1,287 inferred / 16,236 unresolved; references 4,065 / 2,233 / 13,633. Surfaced in `explain`'s `calls`/`called by`/`references`/`referenced by`/`embeds` lines as a per-entry `[inferred]` tag, with a one-line footnote the first time one appears.
- [ ] Phase 4 remaining: other languages via tree-sitter — needs its own project (see the Design note; the `tree_sitter` wrapper does not exist yet), so it stays parked.
- [ ] **remaining call-edge ambiguity.**
  Most of what is left needs the receiver's *inferred* type (`str` alone has 300 candidate declarations), and inference is a **checker** job: `CallExpr.left_type`/`receiver_type` are populated in `v/checker`, never in `v/parser`. Sharing one `ast.Table` across files — the obvious-looking fix — only improves `type_to_str` rendering in signatures; it does not infer receivers.
  But *inferred* is the operative word, and not every receiver needs inferring. The parser does hand us `CallExpr.left`, the receiver expression, and some shapes are typed syntactically: a method calling another method on its own receiver (`fn (t &Transformer) a() { t.b() }` — the type is written on the enclosing declaration), a literal receiver (`Foo{}.bar()`), or a local whose initializer names its type. graphify resolves the self-receiver case, worth ~4% of the remaining ambiguity. What genuinely requires the checker is a receiver that is a call's return value, a generic, an interface, an alias, or a chained expression. A real fix means running the checker over the whole project in a single process, which collides with worker-process crash isolation (V's parser *panics* on some files, uncatchably), with parallel batch dispatch, and with the per-file cache (a file's output would depend on global table state, so an unchanged hash could serve stale results). It would also restrict graphify to projects that typecheck, when navigating half-broken code is exactly when it is most useful. If wanted, this belongs behind an opt-in `--deep` mode, not in the default path.
  17.1% of call edges (28.7k) are still unattributed, but only 4,377 of those are genuinely unresolvable — calls into C, closures, and function variables, which nothing short of running the program could pin down. That puts the real ceiling at **97.4%**, with ~24.3k edges between here and there.
  Those remaining ones are at least not *silent*. `index()` drops any edge whose raw callee name matches several declarations, which makes a called function look uncalled; `explain` / `get_node` list them under `possibly called by`, with the declaration count that makes them uncertain.
  That is resolved at query time from the raw names already stored in the graph, *not* by emitting `AMBIGUOUS` edges to every candidate as originally sketched: measured on the V compiler repo, real fan-out adds 1.15M edges (4.2× the whole graph), and those guessed links would then leak into `shortest_path` and `query_graph` traversal. Keeping it query-side costs no graph growth and leaves traversal untouched.
- [ ] Phase 5: Leiden communities, `merge-graphs`, GraphML/Cypher/SVG, `graph.html`
