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

V only, by design: `backend_v.v` extracts symbols and edges via V's own
compiler frontend (`v.parser` + `v.ast`), which gives full fidelity with no
separate grammar to maintain and no gaps from a minimal binding. An earlier
draft sketched a second, tree-sitter-backed path for other languages
(`SourceFile.lang`, a language filter on `Options`, a `backend_ts.v` stub);
it was never implemented beyond that stub and has been removed rather than
kept as unused scaffolding for a project that doesn't exist yet — see
tree-sitter's own line in Status.

Pipeline: `walk files -> extract_v_file(file) -> []Symbol + []Edge -> Graph -> emit`.

### Model

- `Symbol{ id, name, kind, signature, file, line, end_line, is_pub, parent, doc }` — `end_line` is what lets `get_body` read one declaration instead of a whole file; `doc` is the `//` block directly above it
- `Edge{ from, to, kind, provenance }` — kinds: `defines`, `calls`, `imports`, `implements`, `embeds`, `references`; `provenance` (`extracted`/`inferred`) is set on resolved `calls`, `embeds`, and `references` edges — see the edge provenance item in Status
- **`implements` is a declared vocabulary slot, not a planned feature.** V's interfaces are satisfied structurally — there is no `impl X for Y` syntax to read off the AST, so detecting it means matching a candidate's resolved method/field set (including through embeds) against every visible interface's, which needs a whole-program, fully-resolved type table exactly like `v/ast/table.does_type_implement_interface` builds — the opposite of graphify's per-file, parallel-worker, cacheable extraction. Investigated concretely, not just deferred by assumption: real yield data across 3 real corpora (V's own compiler, this project, and a real `veb`-framework app) found the obvious pitch — a project's own type implementing a project's own interface — in **zero of 288 measured pairs**, including a corpus that declares 6 of its own interfaces specifically to test this. The one real signal (app code satisfying a *framework's* interface) scored 2 meaningful pairs in the one corpus built to have it; the other 286 pairs were stdlib-satisfying-stdlib facts (`io.ReaderWriter`, `IError`) — the same static fact in every V program, not project-specific insight. Building this would mean a standing compiler-patch dependency (forking or upstreaming a change to `v/ast/table.v`) for a feature that, on the best evidence gathered, finds a handful of edges per framework-consumer project and nothing in most others.

### Emitters

- `emit_skeleton()` — body-less code view (the token-saver)
- `emit_json()` — full graph for tooling

## Usage

Mirrors the Python [Graphify](https://medium.com/jin-system-architect/graphify-the-knowledge-graph-that-ends-your-codebases-token-tax-819b77f2ec58)
command surface: extract once, then traverse instead of re-reading files.

```
graphify extract  . --out /path/to/graph_data  # build graph -> a central dir
graphify overview                              # compact summary (counts + key symbols)
graphify query    "auth flow" --budget 2000    # token-bounded traversal
graphify path     build_graph emit_skeleton    # shortest path between symbols
graphify explain  build_graph                  # a symbol + its relationships
graphify body     build_graph                  # just that declaration's source
graphify skeleton .                            # body-less skeleton of a path
graphify merge-graphs a/graph.json b/graph.json --out merged.json   # combine two graphs
graphify communities --resolution 1.5          # split the graph into subsystems
graphify export graphml --out graph.graphml    # for Gephi, yEd, Cytoscape, NetworkX
graphify export cypher  --out graph.cypher     # for Neo4j: cypher-shell < graph.cypher
graphify export svg     --out graph.svg        # static, community-clustered node-link diagram
graphify export html    --out graph.html       # the same, interactive: hover/lock/trace/zoom, + to drill into large communities
```

**SVG/HTML.** Nodes are laid out by community (see Communities above), not by
a force-directed simulation: communities are arranged around an outer
circle, each community's own members around a smaller circle centered on
its spot. Deterministic trigonometry instead of an iterative physics
simulation that would need its own convergence/quality verification the way
communities.v's Louvain implementation did — genuine physical realism isn't
the goal, showing which symbols cluster into which subsystem (and roughly
how large each one is) is. Node size is degree, color is community, hovering
a node in the HTML version highlights it and its direct neighbors and shows
its name/kind/id — plain DOM/SVG event handling, no framework, no CDN
dependency, matching the rest of graphify's fully local design. Caps at 300
symbols (the highest-degree members of each community, kept proportional to
that community's own size so a few giant communities can't crowd out every
small one) since a large real codebase's full node count is too much to
usefully render or even open; a rendering that got capped says so in an
HTML comment / on-page caption rather than silently passing as complete.
No amount of client-side tuning changes that for a genuinely huge repo
(tens of thousands of symbols) — putting every node on one screen at once
stops being legible long before it stops being possible to draw. For that
scale, `export graphml`/`export cypher` are already uncapped and meant to
be opened in a tool actually built for graphs that size (Gephi, Neo4j
Bloom) rather than a hand-rolled SVG.

The HTML version also has scroll-to-zoom (centered on the cursor) and
drag-to-pan on the SVG viewBox, added after direct testing found the first
version impractical to actually use: a real WebDriver-synthesized mouse
move (not a JS-dispatched event — the browser preview tool available during
development renders local files as static snapshots with no JS execution
at all, so a synthetic `dispatchEvent` had been the only check, and it
passed without exercising the real problem) landed dead-center on a node
and measured its rendered size at ~4×4 CSS pixels — correct in principle,
unusable with an actual mouse. Fixed two ways, both verified the same
way afterward: each node's hover target (`.hit` in the SVG, invisible,
layered under the visible dot) is now sized independently of the dot's
degree-based visual size, roughly 3× larger; and the added zoom lets a
user close whatever gap remains. Confirmed with real synthesized
interactions, not just reading the JS: a pointer move to the enlarged
target still highlights correctly, a dispatched wheel event visibly
shrinks the viewBox width by the expected factor, and a real
mousedown-move-up drag shifts the viewBox origin.

**Semantic zoom and cluster context.** The default view shows only one bold
label per community — its name, member count, and *where in the source tree
it actually lives* (e.g. `main (22) — cmd/cli +2 more dirs`) — with
individual symbol labels hidden, so the first thing you see is a high-level
map, not a wall of overlapping per-symbol text. Zooming in past a threshold
fades the per-symbol labels in; the cluster label stays anchored throughout
for context. The directory info exists because a community's own label
(its most internally-connected member's name — see `label_community`)
doesn't say what part of the codebase it corresponds to, and graphify
doesn't otherwise show repo directory structure anywhere; `community_location`
reports the single directory most members share when there's a strict
majority, or a plain count of distinct directories when there isn't one —
guessing a "best" directory for a genuinely scattered community would
misrepresent it, not describe it. Verified live in a real browser: the
default view shows communities with node labels at `opacity:0`; scrolling in
on a specific cluster flips `svg.zoomed-in` and reveals that cluster's full
member names while the rest of the graph stays uncluttered off to the side.

**Click to zoom, lock, and trace.** Clicking a legend entry, or a cluster's
own label on the canvas, zooms the viewBox to fit that community — no need
to scroll-zoom by hand to find where a cluster from the legend actually
sits in the layout. Clicking a node locks its hover highlight so it
survives the mouse moving away: pan or scroll around a node's neighbors at
leisure, or click one of those now-visible neighbors to re-lock onto it and
trace a path across communities one click at a time (click the same node
again, or empty canvas, to drop the lock). The locked node, its neighbors,
and the edges connecting them get a distinct stroke — black for the node
itself, orange for its neighbors and the edges reaching them — instead of
relying on everything else merely getting dimmer to imply connectivity,
which was easy to lose against a cluster's own now-dimmed edges.

Verified with real WebDriver clicks, not `dispatchEvent`, which caught two
real bugs neither a code read nor a synthetic check would have surfaced.
`classList.toggle(cls, x)` treats an explicit `undefined` `x` as "no force
argument given" — falling back to flip-on-current-presence — rather than
"force false"; since `keep[nid] && nid !== id` evaluates to `undefined`
(not `false`) whenever `keep[nid]` itself is unset, this silently marked
nearly every node in the graph as a "neighbor" on top of correctly being
"dim." And the pan-starter's `mousedown` handler was calling `unlock()` on
*every* mousedown, including a plain click with no drag, nulling out the
lock before the click handler's own "am I re-clicking my own lock?" check
could ever see it — breaking click-the-same-node-to-unlock outright. Both
fixed (a `!!` coercion before the affected `toggle()` calls; deferring the
pan-triggered unlock until real pointer movement is detected) and
re-confirmed the same way: real clicks on legend entries and cluster labels
shrinking the viewBox to the expected community, a locked node's
neighbor/dim counts summing exactly to the total node count, re-clicking a
locked node cleanly dropping every highlight, and clicking through to a
neighbor correctly demoting the previous selection while promoting the new
one.

That "defer unlock until real pointer movement" fix later turned out to
overcorrect: it dropped a lock on *any* drag, including one starting from
a locked node — which defeats the reason locking exists, panning or
scroll-zooming out to see where a highlighted edge actually leads. Fixed
to only clear a transient, never-locked hover highlight on pan; a
deliberate lock now survives it. That exposed a second issue directly
underneath: a real synthesized ~90px drag still made the browser fire a
trailing `click` event at mouseup, which was immediately re-triggering
unlock right back through the *other* click handler the moment the pan
fix stopped dropping it directly — invisible without tracing the actual
mousedown/mousemove/mouseup/click sequence a real drag produces, not just
reading the code. Fixed by having the node and background click handlers
ignore a click that's the tail end of a just-finished drag. Confirmed with
a real WebDriver-synthesized drag (not a single click): a locked node's
highlight classes and dim count come out byte-identical before and after
panning, while the viewBox itself genuinely moved.

**Drill down into large communities.** A large, internally-lumpy community
gets a small "+" badge next to its legend entry and in-canvas label —
computed by `communities_within`, a scoped re-run of the same Louvain
optimization on just that community's own members and edges, gated on it
actually finding a real split (`>= 2` sub-communities), not just on size
alone. Clicking the badge reveals a precomputed nested sub-layout, using
the same deterministic ring layout and node/edge/label rendering as the
top level, complete with its own directory-location context per
sub-cluster; an explicit "back to overview" button (not a re-click toggle
or an implicit zoom-out threshold — this project already learned that
lesson once, see above) reverses it. Capped at the 10 largest qualifying
candidates, bounding both the extra clustering cost (each scoped run has
its own restart loop) and the payload growth, with the truncation
disclosed on-page ("N of M large communities include a detail view") the
same way the 300-node cap already is — never silent.

The size threshold (30 members) is empirically grounded, not a guess:
tuned against the classic Fortunato–Barthelemy "ring of cliques"
resolution-limit case, the textbook example of a community that plain
modularity optimization provably cannot resolve further at the top level
yet still contains real, recoverable sub-structure once analyzed in
isolation — a plain clique-of-cliques (few cliques, one clean bridge)
turned out to *always* get cleanly separated by `communities()` at the
top level too, confirmed directly after several other hand-built test
graphs kept failing this exact way, which would leave nothing for
drill-down to ever find.

Two real bugs surfaced only by testing against an actual ~47k-symbol
codebase, not the smaller synthetic test graphs the feature was built
against: the drill badge's fixed small offset from the cluster label
placed it *inside* a large community's own member ring (whose radius
grows with `sqrt(member count)`), so a real click landed on a member node
instead — fixed by measuring each community's actual rendered spread and
placing the badge outside it. And a drill-view's hidden `.dot` circles
stayed independently clickable even at `opacity: 0`, since only the
larger `.hit`/`.cluster-hit` targets had an explicit `pointer-events: none`
override — `opacity` never implies `pointer-events: none` on its own —
fixed by covering `.dot` too, in both the hidden-drill-view and
hidden-flat-content directions.

**Export.** Both formats emit one node per unique symbol id via `Index.by_id`
rather than one per raw `Symbol`, and only resolved edges (`Index.edges`) —
the same reasoning as `query`/`explain`: an id like `main` (every standalone
V program's entry module) or `graphify` (this project's own module, declared
identically in every one of its own files) is shared by several distinct
real declarations, and an unresolved edge has no real node to point at. This
isn't just consistency for its own sake — the Cypher export declares a
uniqueness constraint on `id` for fast edge lookups, and a naive
one-node-per-raw-symbol version was confirmed to violate that constraint
against this project's own export (its own files collide on `graphify`),
failing outright rather than degrading gracefully. GraphML escapes
`&<>"'`; Cypher property strings escape `\` and `'` only — `<`, `>`, `&`,
`"` don't need it inside a single-quoted Cypher string, and escaping them
anyway would corrupt the data (this was cross-checked directly: a signature
containing all of `<>&"` round-trips unescaped in the Cypher output, escaped
in the GraphML one).

**Communities.** Splits the graph into densely-interconnected subsystems by
modularity optimization — the same idea Python Graphify ships as "Communities:
the graph split into subsystems (Leiden), with LLM-free labels." What this
implements, precisely, since "Leiden" names a specific algorithm and it's
worth being exact about the difference: Louvain-style local-moving +
multi-level aggregation (the same core as the original Louvain algorithm),
followed by a connectivity-guaranteeing pass that splits any resulting
community whose induced subgraph turns out disconnected into its connected
components. That delivers the same practically-important guarantee the
Leiden paper's randomized refinement phase exists to prove — every returned
community is one connected piece — via a much simpler, much easier-to-verify
mechanism (connected-components is a solved primitive; a randomized
multi-way refinement merge is not something to hand-roll and trust without a
reference implementation to check against).

Verified against Zachary's Karate Club, the standard 34-node benchmark for
this exact algorithm: correctly separates the graph's two well-documented
rival factions every run, and (since local-moving is randomized and any
single run can settle into a meaningfully weaker local optimum purely by
chance) `communities()` retries `--restarts` times and keeps the
highest-modularity result — more restarts is slower but more reliable; the
default balances the two. `defines`/`imports`/`implements` edges don't count
toward community weight, only `calls`/`references`/`embeds` — containment
("this module defines this function") isn't "these two things interact",
and including it pulled unrelated members of the same module toward each
other instead of toward whatever they actually collaborate with.

**Fixed: `Index.by_id` no longer collapses distinct declarations that share
an id.** It used to — the same case `resolve_edges`' `unaddressable` check
already named for call resolution (every standalone `main` program's entry
point is `main.main`; every `_test.v` file's helpers can collide the same
way) silently dropped whichever declaration wasn't indexed last, everywhere
`Index.by_id` is used: `query`/`explain`/`get_node`, `communities`,
GraphML/Cypher export. Measured on the V compiler repo before the fix:
21.03% of all 107,134 symbols were silently discarded this way, 17.11%
of them genuinely distinct declarations, not harmless duplicates. `extract`
now runs `disambiguate_ids` before edge resolution: a declaration whose id
collides across separate *build units* (every standalone `main` program, or
an id repeated across ≥2 distinct `_test.v` files — same classification
`unaddressable` already used, just applied earlier) is renamed to
`id@file`, file-qualified and so unique for any two declarations V itself
would accept as distinct; a same-declaration repeat inside one ordinary
module (a per-platform variant like `os.setenv` in both environment.c.v and
environment.js.v) is untouched, since V would reject a genuine
redeclaration there. Post-fix on the same repo: 13.54% of symbols still
collapse, entirely the `mod_`/`import_`/`constant`/`field` kinds this pass
deliberately doesn't touch (matching `resolve_edges`' own scope) plus
legitimate platform variants — of the 7,646 rows that were genuine
cross-build-unit collisions, 7,638 (99.9%) are fixed; the 8 remaining are a
separate, root-caused, out-of-scope bug (a `fn C.foo`/`fn JS.foo` extern
declaration colliding with a same-named V wrapper in the *same* file, where
a file-qualified suffix can't help). Before excluding containment edges,
the old collapse also produced an artificial "main" supermassive community
spanning every unrelated standalone program in a large corpus; excluding
`defines` edges from community weight remains independently correct
(containment isn't interaction) even now that the underlying collision
itself is fixed.

**Merging graphs.** Every id is namespaced by its source graph's label (its
root directory name by default, or `--labels a,b,...`), unconditionally and
regardless of merge order, because two unrelated projects sharing a module
name is the common case, not an edge case — `main` is the implicit module of
*every* standalone V program, so any two merged programs collide on
`main.main` unless kept apart. `query`/`explain`/`path`/`shortest_path`/
`overview` work normally against the merged result, and so does `get_body`:
the merged graph carries a `roots` map from each source's label chain (the
same `label::` prefix its symbol ids carry) back to that source's own
original root, so `get_body` picks the right root per symbol instead of
needing one root for the whole graph. `--source-dir` still overrides the
single `root` field when set, which only matters for a non-merged graph or
for forcing every symbol through one relocated checkout. Content that's
genuinely duplicated across inputs (the same file extracted into two of
them) is not deduplicated — it appears twice, once per label.

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

Build and register (project-scoped via `.mcp.json`, already in this repo).
`cmd/cli` and `cmd/hooks` both build `-gc none`: both are one-shot, short-lived
processes — `graphify extract`'s own README section above already explains why
(Boehm GC's per-call overhead caused a ~500x slowdown on the graph.json write
path, 616s -> 32s on the full vlang repo). Do NOT add `-gc none` to
`graphify-mcp` below — it's a long-lived server process and needs bounded
memory. The binary name gets an `.exe` suffix on Windows only; the rest of
this doc omits it:

```
v -prod -gc none -o bin/graphify         cmd/cli     # extract, query, etc.
v -prod -gc none -o bin/graphify-hook    cmd/hooks/graphify_hook.vsh   # Claude Code hook, see below
v -prod            -o bin/graphify-mcp   cmd/mcp
bin/graphify extract .                 # produce graphify-out/graph.json first
```

`.mcp.json` (already in this repo, gitignored — copy `.mcp.json.example` if
you don't have one) uses Claude Code's `${CLAUDE_PROJECT_DIR}` path expansion,
so it works unedited on any machine; the one thing to check per OS is the
`.exe` suffix on `command`:

```json
{
  "mcpServers": {
    "graphify": {
      "command": "${CLAUDE_PROJECT_DIR}/bin/graphify-mcp.exe",
      "args": ["${CLAUDE_PROJECT_DIR}/graphify-out/graph.json"]
    }
  }
}
```

Or register globally: `claude mcp add graphify -- /path/to/bin/graphify-mcp <path-to-graph.json>`.
Smoke-test the protocol without Claude: `cat cmd/mcp/test_session.jsonl | bin/graphify-mcp graphify-out/graph.json`.

## Operational scripts

Beyond the `graphify` CLI itself, `bin/` and `bench/` hold V shell scripts
(`.vsh`, run via `v run` — no separate scripting language or interpreter to
install, since every machine running this already has V) for running this
against a large external repo (vlang) day to day. The one exception is the
Claude Code hook (below), which is prebuilt for latency reasons rather than
run via `v run`.

**One-time setup:** copy `graphify.config.json.example` to
`graphify.config.json` (repo root) and edit the two paths for your machine:

```json
{ "vlang_repo": "/path/to/repo/vlang", "store": "/path/to/graph_data" }
```

`graphify.config.json` is gitignored — each machine keeps its own copy, and
`update-vlang-graph.vsh`, `switch-vlang-graph.vsh`, and `extract_bench.vsh`
(its default `-Source`) all read from it. If the file is missing, each script
errors with a pointer back to the `.example` template instead of silently
using the wrong paths.

### `bin/update-vlang-graph.vsh` — daily graph refresh

Pulls the target repo and re-extracts only if there were new commits. Wired
into a daily scheduler — Windows Task Scheduler, macOS `launchd`, or Linux
`cron`, see **Scheduling** below; can also be run by hand.

```
v run bin/update-vlang-graph.vsh              # git pull, extract only if new commits
v run bin/update-vlang-graph.vsh -NoPull      # skip the pull, always re-extract
```

Logs to `<store>/update.log`.

### `bin/switch-vlang-graph.vsh` — branch-aware graph switching

Extracts (or reuses) a graph for a specific branch and repoints the MCP
server's `~/.claude.json` config at it. `master`/`main` keep the graph at
`<store>/vlang`; other branches get their own `<store>/vlang-<branch>`. The
`~/.claude.json` edit is a targeted text splice of just that one field, not a
full rewrite — see the comment on `patch_mcp_args` in the script for why (a
full parse+re-encode round-trip was tried first and found to silently corrupt
unrelated floating-point fields elsewhere in the file).

```
v run bin/switch-vlang-graph.vsh                             # graph for the current branch
v run bin/switch-vlang-graph.vsh feature-x                   # graph for a specific branch
v run bin/switch-vlang-graph.vsh feature-x -Checkout          # also `git checkout` that branch first
v run bin/switch-vlang-graph.vsh -Force                      # re-extract even if a graph already exists
```

Restart Claude Code after switching so the MCP server picks up the new graph.

### `bench/session_stats.vsh` — token-free MCP usage stats

Scans Claude Code's session transcripts and reports graphify tool-call counts
per session (main-agent vs. subagent split), at zero token/API cost.

```
v run bench/session_stats.vsh                  # last 14 days
v run bench/session_stats.vsh -Days 30         # look back further
v run bench/session_stats.vsh -IncludeBench    # include graphify's own bench sessions
```

### `bench/extract_bench.vsh` — repeatable extraction benchmark

Times `graphify extract` end-to-end against a target repo, clearing the
output directory first so every run starts cold.

```
v run bench/extract_bench.vsh                          # defaults: configured repo, temp out dir
v run bench/extract_bench.vsh -Runs 3                  # average over 3 runs
v run bench/extract_bench.vsh -Source /path/to/myproject -Out /tmp/gf-bench-myproject
```

### Scheduling — Windows / macOS / Linux

- **Windows**: register `update-vlang-graph.vsh` in Task Scheduler (`v run
  <path>` as the action), daily. No script for this in-repo — it's a couple
  of clicks in the Task Scheduler GUI, or `schtasks /create`.
- **macOS**: copy `bin/com.graphify.vlang-update.plist.example` to
  `~/Library/LaunchAgents/com.graphify.vlang-update.plist`, edit the
  `/path/to/...` placeholders, then `launchctl bootstrap gui/$(id -u)
  ~/Library/LaunchAgents/com.graphify.vlang-update.plist`. Chosen over cron:
  modern macOS restricts cron from accessing files outside a few whitelisted
  locations without manually granting it Full Disk Access, so a stock cron
  job for this fails silently; launchd needs no such grant.
- **Linux**: a plain crontab line is enough for one daily command —
  `crontab -e` and add
  `0 3 * * * v run /path/to/graphify/bin/update-vlang-graph.vsh >> /path/to/graph_data/cron.log 2>&1`.

## Claude Code wiring

`.claude/` makes Claude Code reach for the graph automatically (this repo
dogfoods it on itself):

- **`.claude/skills/graphify/SKILL.md`** — tells Claude to query the graph (MCP
  tools or CLI) for structural questions and drill into bodies by `file:line`.
- **`.claude/commands/graphify.md`** — `/graphify [path]` rebuilds the graph and
  summarizes `GRAPH_REPORT.md`.
- **`.claude/settings.json`** (gitignored — copy `.claude/settings.json.example`,
  same per-machine pattern as `graphify.config.json`/`.mcp.json`) — a
  `SessionStart` hook injects standing guidance, and a `PreToolUse` hook on
  `Grep|Glob` reminds Claude to consult the graph before scanning files. Both
  call `bin/graphify-hook(.exe)` — the compiled `cmd/hooks/graphify_hook.vsh`
  above — directly. It's prebuilt rather than run via `v run` because this
  hook fires on every Grep/Glob/SessionStart, and `v run` recompiling from
  source each time costs several seconds per call — the prebuilt binary
  responds in well under 100ms. Settings.json is per-machine (not
  `${CLAUDE_PROJECT_DIR}`-templated like `.mcp.json`) specifically so the one
  `.exe` suffix difference can just be hardcoded directly, with no dispatcher
  layer and no non-V dependency: an earlier version of this used a tiny pwsh
  script to pick the binary name per OS (since a static JSON command can't
  branch, and V always appends `.exe` on Windows regardless of the `-o` name
  given, confirmed empirically — there's no way to build one binary name that
  works unedited on all three platforms), but that made pwsh a real
  dependency for macOS/Linux just to dispatch a 3-line decision. One
  per-machine edit (matching the two config files you already edit) removes
  that dependency entirely.
- **`.githooks/post-commit`** — rebuilds the graph after each commit. Enable with
  `git config core.hooksPath .githooks`.

To wire a *different* project, copy `.claude/` (including
`settings.json.example` → `settings.json`, editing the `.exe` suffix for your
OS) and `.mcp.json.example` (as `.mcp.json`, no edits needed) into it.

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
- [x] **tree-sitter removed.** The multi-language scaffolding (`backend_ts.v`'s stub, `SourceFile.lang`, `Options.languages`, `lang_by_ext`) never did real work — see the Design note — and existed only for a second backend that was never built. Removed rather than left as dead abstraction for a hypothetical future project; other languages would need their own tool, not a mode of this one.
- [ ] **remaining call-edge ambiguity.**
  Most of what is left needs the receiver's *inferred* type (`str` alone has 300 candidate declarations), and inference is a **checker** job: `CallExpr.left_type`/`receiver_type` are populated in `v/checker`, never in `v/parser`. Sharing one `ast.Table` across files — the obvious-looking fix — only improves `type_to_str` rendering in signatures; it does not infer receivers.
  But *inferred* is the operative word, and not every receiver needs inferring. The parser does hand us `CallExpr.left`, the receiver expression, and some shapes are typed syntactically: a method calling another method on its own receiver (`fn (t &Transformer) a() { t.b() }` — the type is written on the enclosing declaration), a literal receiver (`Foo{}.bar()`), or a local whose initializer names its type. graphify resolves all three now — self-receiver (~4% of the remaining ambiguity), literal receiver (small: +5 calls resolved on this project's own `vlib/v` benchmark corpus (2,885 files) — a different, smaller corpus than the full-repo figures elsewhere in this note, since most methods chain off a named variable, not a fresh literal), and local receiver (`x := Foo{}` then `x.bar()`; bigger, as expected since this is the common idiom: +42 net calls resolved on the same corpus, some of them upgrading from `inferred` straight to `extracted`). The literal-receiver fix caught a real trap worth recording: `ast.StructInit.typ_str` is *not* trustworthy for this — despite its `// 'Foo'` doc comment, the parser always prefixes it with whichever module is currently being parsed, not the module actually written, so `other.Bar{}` referenced from inside `demo` silently reports itself as `demo.Bar` (confirmed by direct probing of `v.parser`, not by trusting the comment). Resolving through `.typ` via the table, the same route `clean_type` already uses elsewhere, does not have that bug. The local-receiver tracking is deliberately conservative about what it tracks: only a `:=` (not a plain `=`) with exactly one name on the left and a directly-typed literal on the right, and a nested block's local never leaks to a sibling branch or to code after the block — ordinary lexical scoping, which V's insistence on an explicit `.clone()` for any map copy gives for free once each block's tracked-locals are threaded by value rather than mutated in place. A later plain reassignment (`x = something_uncertain()`) is deliberately *not* treated as invalidating the tracked type, because V is statically typed: a `:=`-declared local's type cannot change for the rest of its scope no matter what a later right side looks like, so there is nothing to invalidate. What genuinely requires the checker is a receiver that is a call's return value, a generic, an interface, an alias, or a chained expression. A real fix means running the checker over the whole project in a single process, which collides with worker-process crash isolation (V's parser *panics* on some files, uncatchably), with parallel batch dispatch, and with the per-file cache (a file's output would depend on global table state, so an unchanged hash could serve stale results). It would also restrict graphify to projects that typecheck, when navigating half-broken code is exactly when it is most useful. If wanted, this belongs behind an opt-in `--deep` mode, not in the default path.
  17.1% of call edges (28.7k) are still unattributed, but only 4,377 of those are genuinely unresolvable — calls into C, closures, and function variables, which nothing short of running the program could pin down. That puts the real ceiling at **97.4%**, with ~24.3k edges between here and there.
  Those remaining ones are at least not *silent*. `index()` drops any edge whose raw callee name matches several declarations, which makes a called function look uncalled; `explain` / `get_node` list them under `possibly called by`, with the declaration count that makes them uncertain.
  That is resolved at query time from the raw names already stored in the graph, *not* by emitting `AMBIGUOUS` edges to every candidate as originally sketched: measured on the V compiler repo, real fan-out adds 1.15M edges (4.2× the whole graph), and those guessed links would then leak into `shortest_path` and `query_graph` traversal. Keeping it query-side costs no graph growth and leaves traversal untouched.
- [x] Phase 5, **`merge-graphs`** — combines any number of previously-extracted graphs into one, with every id namespaced by its source's label (default: root directory name, deduplicated with `-2`/`-3`/... on repeat) so a shared module name like `main` — the implicit module of every standalone V program — can never collide across inputs. `get_body` works against the merged result too: a `roots` map from each source's label chain to its own original root lets it pick the right root per symbol; a graph.json from before this map existed simply decodes with `roots` empty and falls back to the single `root` field, unchanged. See Usage.
- [x] Phase 5, **`communities`** — Louvain-style modularity optimization (local-moving + multi-level aggregation) plus a connectivity-guaranteeing split pass, standing in for the Leiden paper's randomized refinement phase; see Usage for exactly what that trades away. Verified against Zachary's Karate Club (correctly separates its two documented rival factions every run; modularity reliably well above a random/degenerate partition across dozens of test runs) and against real V codebases, where the resulting communities are recognizable subsystems — `Checker`, `Builder`, `Parser`, `Fmt`, `JsGen`, `Table`, `Scope` on the V compiler repo, not noise. Surfaced a real, pre-existing limitation rather than papering over it: `Index.by_id` collapsed distinct declarations that share an id across build units (every standalone `main` program above all) into one node, which without `defines`-edge exclusion produced an artificial supermassive "main" community. Excluding containment edges (`defines`/`imports`/`implements`) from community weight remains independently well-motivated (containment isn't interaction) even now that the id-collision itself is fixed below — it also matters for the legitimate platform-variant ids that are still intentionally left collapsed.
- [x] **`Index.by_id` id-collision fixed (2026-08-16).** `disambiguate_ids` (graphify.v) runs before edge resolution and gives colliding declarations their own distinct node identity — see the Usage section's Index.by_id note for the full mechanism and real before/after numbers (21.03% of all symbols silently discarded → 13.54%, with the fixable portion — genuine cross-build-unit collisions — going from 7,646 rows to 8). The 8 that remain are a distinct, root-caused, out-of-scope bug: a `fn C.foo`/`fn JS.foo` extern declaration colliding with a same-named V wrapper *in the same file*, which a file-qualified suffix can't separate.
- [x] Phase 5, **GraphML/Cypher export** — both formats emit one node per unique id (via `Index.by_id`, not the raw `Symbol` list) and only resolved edges, for the reasons the Usage section explains. A real bug was caught in the process, not just anticipated: a naive one-node-per-raw-`Symbol` version violated the Cypher export's own uniqueness constraint against this project's own files (they all declare `module graphify`), confirmed by actually running the export, not by inspection.
- [x] Phase 5, **SVG export and `graph.html`** — both share one layout: communities (see above) arranged around an outer circle, each community's own members around a smaller circle centered on its spot, sized by degree and colored by community. Deterministic trigonometry, not a force-directed simulation — see Usage for why. `graph.html` adds a legend, hover-to-highlight-neighbors, and scroll-to-zoom/drag-to-pan — plain DOM/SVG, no framework. Capped at 300 symbols (proportional per-community, highest-degree first) with the cap always disclosed, never silent.
  Shipped once already believing it was verified, then genuinely wasn't: the first pass checked hover by dispatching a synthetic `mouseenter` in JS, which passed because it targets the element directly — it can't catch "the real click target is too small to hit," which is exactly what user feedback then reported. Re-verified with a real WebDriver session (`vebidor`, driving actual Edge) instead: a synthesized *pointer move*, not a dispatched event, landed dead-center on a node and measured its rendered size at ~4×4 CSS pixels. Fixed by decoupling the hover hit-target from the node's degree-sized visible dot (now independently sized, ~3× larger) and adding real zoom/pan, then re-confirmed the same honest way — synthesized pointer move on the new target, a dispatched wheel event, and a real drag — plus visual screenshots at each step.
  Followed by a second round of user feedback shaping this feature further: a high-level view first, with detail revealed while exploring, and per-cluster context since graphify shows no repo directory structure anywhere else. Added semantic zoom — the default view shows one bold label per community (name, count, and `community_location`'s summary of where in the source tree it actually lives) with individual symbol labels hidden until zoomed in past a threshold. Verified the same way as everything else in this feature: real WebDriver zoom on an actual cluster, screenshotted, confirming the map is legible by default and a specific cluster's full member names appear on zooming into it.
  A third round added click-to-zoom (a legend entry or an in-canvas cluster label zooms the viewBox to fit that community, computed from the rendered nodes' own bounding boxes) and click-to-lock (a node's highlight persists past `mouseleave`, so clicking through its now-visible neighbors traces a path across clusters one click at a time; connecting edges get a distinct accent color instead of merely staying undimmed). Real-browser verification again earned its keep, catching two genuine bugs invisible to a synthetic dispatch or a code read: a `classList.toggle(cls, undefined)` force-argument gotcha that silently inflated the neighbor set to nearly the whole graph, and a `mousedown`-before-`click` ordering bug that broke unlocking a node by clicking it again. Both fixed and reconfirmed the same way — see Usage for the full story.
  A fourth round added hierarchical drill-down: a large, internally-lumpy community gets a "+" badge that reveals its own precomputed nested sub-layout (via `communities_within`, a scoped Louvain re-run gated on actually finding real sub-structure, not just size), capped at 10 with the truncation disclosed. The size threshold was tuned empirically against the classic Fortunato–Barthelemy ring-of-cliques resolution-limit case after plain clique-of-cliques test graphs kept getting cleanly separated by `communities()` at the top level too, leaving nothing to drill into — see Usage for why that shape doesn't work. Testing against a real ~47k-symbol codebase (not just the synthetic test graphs) caught two more real bugs: a badge positioned inside a large community's own member ring instead of outside it, and hidden drill-view `.dot` circles that stayed clickable at `opacity: 0` since only their larger `.hit`/`.cluster-hit` siblings had an explicit `pointer-events: none`. Both fixed and reconfirmed on the real codebase. A related regression also surfaced and was fixed in the same round: panning was unconditionally dropping a locked highlight, defeating the reason locking exists (surviving exploration); fixing that then exposed a trailing-click-after-a-real-drag issue underneath, only found by tracing the actual mousedown/mousemove/mouseup/click sequence a real drag produces — see Usage for the full story. This is the closing item of Phase 5.
