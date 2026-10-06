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
- V 0.5.2 cannot parse syntax V3 has added, and the vlang tree already uses
  it. Extraction recovers past such errors and lists the affected files in the
  manifest's `partial` list (see "Silent truncation" below), but whatever the
  parser cannot read around an error is still lost, and new V3-only constructs
  keep adding to it;
- when upstream drops the fallback, graphify stops building on every
  platform. In September 2026 the V maintainer said the fallback will stay
  available for one year, so the port needs to land by about September 2027.

The eventual fix is porting the extractor to V3's frontend. V3's parser
produces a flat arena AST (`vlib/v/flat`: `NodeId` indices into a node array,
a single `NodeKind` enum, and node payloads held in a process-global table).
That is an internal compiler representation, not a stable API. Before any port,
establish the following (the feasibility spike below answers all three):

- whether the V3 parser can parse a single file in isolation, as the
  per-file workers, crash isolation, and incremental cache require;
- how declarations, line ranges, and call edges map onto the flat AST, and
  whether existing symbol ids can be preserved or must change under an
  explicit schema version;
- how graphify will track V3's frontend as it changes.

The incremental cache is already keyed on the extractor binary's hash, so a
ported extractor will not reuse cache entries produced by the V1-based one.

### Feasibility spike (October 2026)

Run against vlang `612eda2c73` (7,467 `.v` files), with a fresh V1 extraction
of the same commit as the baseline. Conclusion: a V3 port is feasible, and it
is needed sooner than the fallback deadline, because the V1 extractor is
already losing code.

**Silent truncation in the V1 extractor (since fixed, see below).** When V
0.5.2's parser met syntax it did not know, it stopped and returned what it had
read so far. graphify's parse worker discarded stderr and stored that partial
result, so the file was not counted as unparseable. Compared with V3, 190
files lost functions: about 3,500 of roughly 70,000 (5%), while the update log
reported 3 unparseable files.

- 153 files stop partway; every function V3 finds after that point is missing
  (2,957);
- 26 files yield no functions at all (232);
- 11 files differ in the middle (311).

177 of the 190 fail V 0.5.2's `-check-syntax`. Grouped by the commit that last
touched the failing line: 75 files (1,988 functions) come from vlang
`70ee511b35`, which migrated `os` command strings to argument arrays using the
array spread `[..., ...(expr), ...]`; 102 files (1,431 functions) use V3-only
features with no V1 form (raw and Intel inline-asm blocks, sum types with
named variants, newer generics rules); 13 files (81 functions) have no V1
syntax error and differ for other reasons. The spread has appeared in later
vlang commits too, so the loss grows regardless of the port.

**Fixed (October 2026).** The stopping was graphify's configuration, not a
limit of the parser: in its default `.stdout` output mode V 0.5.2's parser
aborts at the first syntax error, while in `.silent` mode it records the
error, skips the bad token and keeps going, as `v -check-syntax` does.
Extraction now parses in `.silent` mode. On vlang `414f15fb7b` that brought
the functions missing relative to V3 from 3,548 down to 561, with no function
lost and no spurious one added. The remaining 561 sit in 45 files, most of
them outside any syntax error (320 in
`vlib/v/types/checker_ownership_d_ownership.v` alone).

Recovery has one side effect: in script-style files (top-level statements, no
`fn main`), skipping a statement can land the parser on an anonymous `fn`
inside a top-level call, which it records as a declaration with no name.
Extraction drops nameless function declarations; on vlang there were 338.

Files whose parse reported an error are listed in the manifest's new `partial`
list (245 on vlang), counted in `graphify extract`'s output, and classified by
`graphify diff` as parsed with syntax errors. They are served from the
current, recovered parse rather than from an older cached copy: an older
copy's line ranges would point `get_body` at the wrong code once anything in
the file moved. Compared with V 0.5.2's own `-check-syntax`, the list agrees
on 212 files; the 33 it lists that the check does not are script-style files,
whose top-level statements the check accepts as a standalone program but which
recover fully here; and the 37 the check flags that are not listed are type
conflicts from `-check-syntax` registering vlib/builtin types twice (33), the
3 files that crash the parser (listed under `failed`), and one call to a
function named `byte` that only parses without the built-in type table.

**Single-file isolation (first question): yes.** `parser.Parser.new(prefs)`
and `parse_file(path)` return a `flat.FlatAst` for one file, from a program
built with plain V (no `-old-compiler`). All 7,467 files parse in one process
in 1.85 s with no crashes. A per-file hash over every node's kind, value,
type, position and child count is identical whether the file is parsed in a
shared process or in its own, for every file but one:
`vlib/v/tests/comptime/comptime_at_test.v`, whose `@BUILD_DATE`, `@BUILD_TIME`
and `@BUILD_TIMESTAMP` are filled from the clock at parse time, so it differs
between isolated runs as well. Batching files per worker process, as today, is
therefore safe. Speed is not an argument either way: V1's full extraction of
the same tree takes 2.4 s with parallel workers.

**Declarations, ranges, calls and ids (second question): yes, with known
work.**

- Every kind graphify extracts has a V3 node kind (`module_decl`,
  `import_decl`, `fn_decl`, `struct_decl`/`field_decl`, `enum_decl`,
  `interface_decl`, `type_decl`, `const_field`, `global_decl`). Extern `fn
  C.foo()` is a separate `c_fn_decl`, so it no longer needs special handling.
- `fn_decl.value` is receiver-qualified for methods (`Point.dist`) and `typ`
  holds the return type. A call's callee is its first child: an `ident`, or a
  `selector` whose own child is the receiver or module. That is the same
  information the V1 extractor records.
- Struct line ranges are correct. `fn_decl` has no end offset (`pos.end` is 0)
  and `enum_decl` spans only its name, so end lines must be derived, for
  example from the last descendant and the closing brace. `get_body` depends
  on this.
- `import_decl.value` is the module path as written and `typ` the alias. V1
  recorded the resolved path (`import json2` became `x.json2`), so matching it
  needs module resolution in graphify (196 imports differ).
- Of 125,665 symbols found by both at the same file and line, 97.8% get
  identical ids from a naive mapping (`<module_id>.<value>`). Nearly all of
  the rest follow three rules: strip the `C.`/`JS.` prefix V3 keeps on C and
  JS declarations (2,236), map V3's static-method form `T@static@f` to V1's
  `T__static__f` (297), and strip V's `@` escape on keyword names (`@type`). A
  few remaining differences are V1 bugs, such as `shared St.g`, where V1 kept
  the receiver modifier in the id.
- On one side only: V1's 1,741 extra imports are compiler-injected pseudo-
  imports (`builtin.closure`, `sync.threads`) placed where a closure or
  `spawn` occurs, not real imports. V3 additionally yields type aliases
  (1,976) and globals (256), kinds the V1 extractor never emitted.

**Tracking V3's frontend (third question).** Depend on the narrowest surface:
`Parser.new`, `parse_file`, the parser's `diagnostics`, and each node's
`kind`, `value`, `typ`, children and byte offsets, computing line numbers from
the source rather than through `token.File`. Pin the vlang commit graphify
builds against, and keep the spike's comparison (V3-derived ids against a V1
extraction of the same commit, grouped by cause) as a check when moving that
pin, for as long as V1 still builds.

**Errors.** V3 also stops at a syntax error, but it records the error in the
parser's `diagnostics` with line and column, so a ported extractor can mark
the file degraded instead of hiding it.

**Running both.** A V1 and a V3 backend cannot share one binary: they need
different compilers, and both define `v.parser`. They can coexist as two
worker binaries behind the existing `_parse-batch` protocol, which would allow
V1 as a per-file fallback and as a cross-check during the transition. That
requires the core module to build without either frontend, under both
compilers, which has not been checked.

The spike's probe programs were not kept; the method above is enough to repeat
it.

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

**V3 resolves this (October 2026 spike, §6).** V3's parser has a
`preserve_comptime_conditionals` preference. With it set, every platform
branch is kept, inside `comptime_if` nodes that carry the condition text
(`windows`, `macos`), so a ported extractor can be host-independent and could
record which platform a declaration belongs to. Without it, V3 evaluates
conditionals against the host, as V1 does.

The effect is larger than the Mac/Windows comparison suggests. On the Mac,
V3's default mode hides 892 functions, 205 structs, 863 fields and 19,030
calls in vlang compared with preserve mode, mostly Linux-only code (X11,
Wayland, `sapp_wayland_linux.v`). Today's V1 graph matches V3's default mode
on those files. Linux-only code is therefore missing from graphs built on both
the Mac and Windows, and can never show up in a comparison between the two.
Preserve mode parsed all 7,467 files without crashing, and no file had fewer
functions than in default mode.

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
