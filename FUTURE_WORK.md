# Future work and known gaps

This file records the concrete limitations identified in the current Graphify
design. It is intentionally scoped to gaps that affect graph accuracy,
portability, or day-to-day use; completed features and exploratory ideas stay
in `README.md`.

## 1. Remaining call-edge ambiguity

The extractor uses V's parser and a per-file AST table. It resolves calls by
callee name, method/function shape, file/module locality, and import
visibility, but it does not run V's whole-program checker. Calls whose
receiver type comes from a function result, interface, generic, alias,
function variable, closure, or chained expression can remain unattributed.

The raw edge is retained and `explain` reports ambiguous callers rather than
inventing links. A future opt-in deep mode could run the checker over a whole
project, but it would need to address these constraints first:

- checker state would make extraction results depend on the whole project;
- per-file cache entries could become stale when another file changes;
- parser worker crash isolation and parallel extraction would no longer be
  independent per file;
- partially broken projects must remain navigable, even when they do not
  typecheck.

Any implementation should preserve unresolved edges, provenance, incremental
cache correctness, and the current performance path. It should be benchmarked
against the parser-only mode rather than silently replacing it.

## 2. Structural `implements` edges

V interfaces are satisfied structurally and have no explicit `impl` declaration
for the parser to extract. Detecting these edges requires matching resolved
methods and fields, including embeds, against visible interfaces with a
whole-program type table.

Graphify currently does not emit `implements` edges. This should remain an
evidence-gated feature: measurements recorded in `README.md` found almost no
project-specific interface relationships across the tested corpora. If the
feature is revisited, first establish a corpus where the additional edges
materially improve navigation, then decide whether an opt-in checker-backed
mode justifies its cost and compiler dependency.

## 3. Language scope remains V-only

The live backend is deliberately V-specific and uses V's own compiler
frontend. The earlier tree-sitter scaffolding was removed because it did not
provide a working second backend.

Supporting another language would require a real backend, language-specific
symbol identity and resolution rules, tests, cache behavior, and an explicit
CLI/MCP contract. Do not reintroduce placeholder language switches without an
implemented backend behind them.

## 4. Graph freshness and source availability

Structural queries work from `graph.json`, but the graph must be refreshed
after source changes. `get_body` additionally needs access to the source
checkout because it reads the captured line range from disk.

Potential improvements include a lightweight freshness check or file watcher,
clearer stale-graph diagnostics, and a more explicit source-root health check
for shared graphs. Any automatic refresh should preserve the existing
incremental cache and should not make ordinary read-only queries unexpectedly
expensive.

## 5. Large-graph visualization limits

SVG and HTML exports intentionally cap the rendered view at 300 symbols so
the result remains legible. GraphML and Cypher are the uncapped outputs for
large repositories.

Future visualization work could add user-selected filters, community-focused
exports, or a generated index for navigating very large graphs. It should not
silently render a partial graph: truncation must remain visible to the user.

## 6. The extractor depends on V's removed V1 frontend

`backend_v.v` imports `v.ast`, `v.parser`, `v.pref`, and `v.token` from V's
V1 compiler frontend. Upstream V removed V1 and made V3 the default compiler
(vlang commit `2a7447b5e5`, #28556): `vlib/v/ast` no longer exists, and
`v.parser`, `v.pref`, and `v.token` are now V3 modules with different APIs.

Graphify still builds only through a pinned V 0.5.2 compatibility compiler,
and only when that compiler is requested explicitly with `-old-compiler`
(for example `v -old-compiler -prod -gc none -o bin/graphify cmd/cli`, and
`v -old-compiler test .`). Since vlang #28772 the driver retries only C
compilation errors with V 0.5.2; a V error such as the missing `v.ast` module
is final, so a plain `v` build fails. To locate the compatibility compiler
(`ensure_v1_fallback` in `cmd/v/v.v`), the driver looks for `v1_fallback` in
the V source tree, then for a per-user cached copy, and otherwise runs
`make v1` to download and SHA256-verify the V 0.5.2 release, or build it from
source. This has
consequences:

- graphify builds only on machines where that fallback is installed or can be
  installed automatically;
- on Windows, the `v1` recipe is POSIX shell, and GNU make for Windows runs
  recipes through `cmd.exe` when no `sh.exe` is on `PATH`, which fails with
  "The system cannot find the path specified". Having `make` on `PATH` is not
  sufficient; make also needs a POSIX `sh`, such as Git for Windows'
  `usr\bin`;
- V 0.5.2 parses the current vlang tree today, but new V3-era syntax will
  eventually appear. The first visible sign is a growing list of files
  skipped as unparseable in the update log;
- when upstream drops the fallback, graphify stops building on every
  platform. In September 2026 the V maintainer said the fallback will stay
  available for one year, so the port needs to land by about September 2027.

The eventual fix is porting the extractor to V3's frontend. V3's parser
produces a flat arena AST (`vlib/v/flat`: `NodeId` indices into a node array,
a single `NodeKind` enum, and node payloads held in a process-global table).
That is an internal compiler representation, not a stable API. Before any port,
establish:

- whether the V3 parser can parse a single file in isolation, as the
  per-file workers, crash isolation, and incremental cache require;
- how declarations, line ranges, and call edges map onto the flat AST, and
  whether existing symbol ids can be preserved or must change under an
  explicit schema version;
- how graphify will track V3's frontend as it changes.

The incremental cache is already keyed on the extractor binary's hash, so a
ported extractor will not reuse cache entries produced by the V1-based one.

