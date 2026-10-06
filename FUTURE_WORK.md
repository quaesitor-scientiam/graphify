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

## 7. Publishing, degraded extractions, and manifest detail

A full three-way reconciliation between a common-base graph, another
branch's overlay, and the graph rebuilt from a merged commit is not needed.
Git already reconciles the *source*; the graph is derived only from current
source plus the extractor, so anything another branch contributed that
survived the merge is already reachable from current source, and anything
that did not survive is correctly excluded by the rule that the graph must
not retain symbols whose source is gone. The one real gap — a file that
fails to extract on the current commit — is already covered by the
incremental cache's own prior result for that file, not by another branch's
graph.

**Done (commit `22023d8`).** The three narrower gaps this section identified,
plus the audit command, are all implemented:

- **`graph.json` publishes atomically.** `save_graph` writes to a temp file
  and publishes it with `atomic_replace`. Windows needed real attention:
  `os.rename` FAILS outright there when the destination already exists
  (verified against the actual Windows C runtime), so Windows publishes via
  `MoveFileExW`/`MOVEFILE_REPLACE_EXISTING`, a genuine single-operation
  replace — `os.mv`'s fallback (copy then delete the source) would have
  reintroduced the exact torn-read window this exists to avoid.
- **A file that fails to parse now falls back to its last successful
  extraction, marked stale**, instead of silently vanishing from the graph.
  `CacheEntry` gained a `stale` flag; `stale_fallback_for`/`fresh_reuse_of`
  in `graphify.v` decide when to serve it and when to clear it (a hash match
  against current content directly reverifies the file, clearing `stale`
  even if it was previously carried forward). Both places in
  `build_graph_resilient` that used to drop a file's symbols outright — a
  crashed worker, and a listfile write failure — use this now.
- **`manifest.json` records `binary_hash`, a best-effort `source_commit`,
  and `failed`/`stale` file lists**, via a new `ExtractReport` threaded from
  `build_graph_resilient` through `write_bundle`.
- **`graphify diff <old.json> <new.json>`** lists symbols in `old` missing
  from `new`, grouped by file, classified from `new`'s manifest as
  parse-failed / stale / file-removed / symbol-specifically-missing — this
  is the audit trail, and it does cover losses beyond a merge, such as a
  walker or skip-list change.

Known gap left from this work: the stale-carry-forward *wiring* inside
`build_graph_resilient` has no test that triggers a real worker crash —
vlang's own permanently-unparseable files have never succeeded even once, so
there's nothing for them to fall back to, and constructing a reliable
artificial crash is fragile. The pure decision helpers are unit-tested
directly instead; the wiring is covered by review, the full test suite, and
a real full-corpus run, not a targeted crash-injection test.

## 8. Extraction depends on the build host's OS and architecture

The same vlang commit extracted on an arm64 Mac and an x86_64 Windows machine
gives different graphs: 108,812 versus 108,848 symbols, from the same 6,238
files. The whole difference sits in six files:

- five inline-assembly tests, `vlib/v/slow_tests/assembly/*.amd64.v` and
  `*.i386.v`, which yield 37 more symbols on the x86_64 host;
- `vlib/x/multiwindow/service_native_appkit_readback_metal_red_test.v`, whose
  code sits behind `$if darwin`, which yields 1 more symbol on the Mac.

`extract_v_file` parses with `pref.new_preferences()`, which defaults the
target OS and architecture to the host's. The V1 parser makes decisions
against those preferences at parse time: a top-level `$if` whose condition is
false for the target is skipped (`comptime_skip_curr_stmts` and
`skip_scope()` in V 0.5.2's `vlib/v/parser/if_match.v`), and a file named for
an architecture, such as `.amd64.v`, gets a per-file architecture mode
(`file_backend_mode` in `vlib/v/parser/parser.v`). The exact path by which the
assembly files lose symbols on a non-matching host has not been traced.

Consequences:

- graphs in a store shared between machines differ by platform, even after
  symbol ids were made independent of the working directory (`5170207`);
- `graphify diff` across two machines' graphs reports symbols as missing that
  are only another platform's code;
- the difference is small for vlang today, but grows with the amount of
  platform-specific code in a project.

Options:

- pin the target OS and architecture in the parser preferences, so every host
  extracts one canonical view. This is deterministic, but omits code that only
  exists for other platforms;
- extract every branch of each platform conditional, if the parser offers a
  mode for it. Whether V1's preferences support this has not been checked.

Because §6 replaces this frontend, treat host independence as a requirement
of the V3 port rather than patching the V1 path. If the shared store needs
identical graphs sooner, pinning OS and architecture is the cheap stopgap.

## 9. Building inside a git worktree compiles the main checkout

`cmd/cli`, `cmd/mcp`, and `cmd/hooks/graphify_hook.vsh` all `import graphify`,
and V resolves that import by directory name, walking up from the program
being built. Claude Code worktrees live at `.claude/worktrees/<name>/`, so from
a worktree the nearest directory named `graphify` is the main checkout. The
build succeeds, but every binary built in a worktree contains the main
checkout's code, not the worktree's.

Tests are not affected the same way: `graphify_test.v` is itself
`module graphify` in the repository root, so `v test` compiles the worktree's
sources directly. A change can therefore pass its tests in a worktree while
the binaries built there do not contain it. This happened while fixing the
symbol id scheme. `v -print-v-files cmd/cli` shows which sources a build will
use.

Workaround, from a worktree:

```
mkdir -p /tmp/gfshim && ln -s "$PWD" /tmp/gfshim/graphify
v -old-compiler -path "/tmp/gfshim|@vlib|@vmodules" -prod -gc none -o bin/graphify cmd/cli
```

Related: `v test .` from the main checkout also descends into
`.claude/worktrees/` and runs every worktree's copy of the tests, each against
whatever commit that worktree has checked out. Since `77742d7` and `e48a80c`
those copies no longer race on shared temp directories, but their results
describe stale code. Test the main checkout with an explicit path
(`v -old-compiler test graphify_test.v`) when that matters.

A durable fix could be a build script that detects a worktree and adds the
module path itself, or at least a README note in the build section.
