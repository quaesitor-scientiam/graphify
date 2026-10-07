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

## 6. Porting the extractor to V3 (done, October 2026)

Done on 7 October 2026: the extractor (`backend_v.v`) reads V3's flat AST,
graphify builds and tests with plain `v`, and the V 0.5.2 extractor and
`-old-compiler` are gone. CI tests on Linux, macOS and Windows and checks
that all three extract the same graph of one vlang commit
(`extract-on-every-os`, `same-graph`). The rest of this section is the
history: why the port was needed, the spike, and how V3's output was matched
to the old extractor's, including where it deliberately differs.

The extractor (`backend_v.v`, since split into
`backend_v_notd_graphify_v3.v` and `backend_common.v`) imports `v.ast`,
`v.parser`, `v.pref`, and `v.token` from V's V1 compiler frontend. Upstream V removed V1 and made V3 the default compiler
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
lost and no spurious one added. The remaining 561 sat in 45 files (320 in
`vlib/v/types/checker_ownership_d_ownership.v` alone).

**Per-declaration re-parse (October 2026).** The 320 were not outside a syntax
error, as first written here. That file shadows a local with a loop variable
(`name := ...`, then `for name, typ in m`), which V3 accepts and V 0.5.2
rejects. The parser returns from the middle of the `for` without closing its
scope, so every later method whose receiver is also `tc` fails as a
"redefinition of parameter" and its body is read as garbage at file scope;
only functions with other parameter names survived. Recovery cannot fix that
inside one parse, so a file whose parse reports an error is now parsed again
one top-level declaration at a time (`reparse_by_declaration` in
`backend_v.v`): each declaration behind the file's module and imports, padded
so line numbers stay the file's own, with boundaries taken from scanner tokens
in column 1 so code quoted in a string is never split on. Anything the
whole-file parse found that the per-declaration parses did not is kept too. On
vlang `1b4ecb9c05` this added 394 symbols (295 methods, 74 functions, the rest
types and fields), 298 of them in the ownership file, which now has all 501
of its functions; it lost none, and corrected the line numbers of the few
methods the broken parse had placed at the top of the file. A full extraction
still takes about 3.4 seconds.

Recovery has one side effect: in script-style files (top-level statements, no
`fn main`), skipping a statement can land the parser on an anonymous `fn`
inside a top-level call, which it records as a declaration with no name.
Extraction drops nameless function declarations; on vlang there were 338.

Nameless struct and `type` declarations are not dropped. Each is a real
declaration that V 0.5.2 could not parse and returned empty. On vlang `abcebfc16d` (graph of 7 October) there are 27 such symbols in
25 files, 21 structs and 6 `type` declarations, with an empty name, the id
`<module>.` and, since the parser gives them no position, mostly line 1. By
the first error `-check-syntax` reports for each file: 8 files declare a
single-letter capital name (`pub struct M`), which V 0.5.2 reserves for
generic parameters and which vlang's own tests use; the rest have newer syntax
inside the declaration, such as a generic type alias, sum types with named
variants, or `mut` or an embedded struct in a struct body. In
`vlib/v/tests/single_letter_result/single_letter_result.v` the graph has the
module and the two functions but neither struct `M` nor its field `x`, so the
`!M` and `?M` in the signatures stay unresolved. Within a module the nameless
ids collide and are separated as `<id>@<file>`. The effect is small (27 of
135,723 symbols; 8 of the files are test fixtures for single-letter names) and
is left as is, because the V3 port removes the class.

Two fixes were considered and not made. Dropping them like nameless functions
would remove the noise but gain nothing, since the declaration is already
lost. Reading the name and line from the declaration's first source line in
`reparse_by_declaration` (`pub struct M {`) would put the struct back and let
references to it resolve, but not its fields. Neither was checked for edges
that already point at the nameless ids. One nameless struct, in
`vlib/strconv/format_thousands.v`, was not traced to a declaration: that
file's syntax error is a generic constraint on a function, and the function
itself survives with its parameters and return type missing.

Files whose parse reported an error are listed in the manifest's new `partial`
list (245 on vlang), counted in `graphify extract`'s output, and classified by
`graphify diff` as parsed with syntax errors. They are served from the
current, recovered parse rather than from an older cached copy: an older
copy's line ranges would point `get_body` at the wrong code once anything in
the file moved. Compared with V 0.5.2's own `-check-syntax`, the list agrees
on 212 files; the 33 it lists that the check does not are script-style files,
whose top-level statements the check accepts as a standalone program but which
recover fully here (since parsed in script mode instead, and no longer listed); and the 37 the check flags that are not listed are type
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
compilers.

**The core builds under V3 (checked October 2026).** With `backend_v.v`
replaced by a stub that keeps its public functions (`extract_v_file`,
`extract_v_text` and their `_result` forms, plus the frontend-free helpers
`module_id`, `import_id`, `strip_generic_args`, `is_generic_param`) and
returns no symbols, every other file compiles under plain V3 (vlang
`abcebfc16d`) without a change: `cmd/cli`, `cmd/mcp` and the hook script all
build. Of the 104 tests, the 61 that do not extract source pass; the other 43
fail only because the stub extracts nothing. On the real vlang graph, the
V3-built CLI gives byte-identical output to the V1-built one for `overview`,
`explain`, `query`, `path` and `diff`, and with `-prod` loads and summarizes
the graph in 0.47 s against 0.38 s. So the port is confined to the
extractor: a V3 `backend_v.v` behind the same functions, with the rest of
graphify unchanged. Only `backend_v.v` imports V's frontend (`v.ast`,
`v.parser`, `v.pref`, `v.token`, `v.scanner`).

On macOS 27, build V with `-cc cc` for this: a V compiler linked by the
bundled TCC can start with garbage in its zero-initialized globals and panic
or hang on any program (vlang/v#29744; TCC's Mach-O writer).

### The V3 extractor (October 2026)

Until the switch, the V3 extractor lived in `backend_v3_d_graphify_v3.v`,
built in place of the V 0.5.2 one with plain V and `-d graphify_v3`, while
the default build still used `-old-compiler`.
The test suite passes against both, with the tests of V 0.5.2's own syntax
errors and pseudo-imports returning early under `-d graphify_v3` and the
tests of a file-level `$if` expecting every branch there.

It parses with `preserve_comptime_conditionals`, so every branch of a `$if`
is kept, at file scope and in function bodies: the host dependence of §8 goes
away, and a call inside `$if debug {}` is still a call. On vlang `abcebfc16d`,
against the V 0.5.2 extractor on the same tree:

| | V 0.5.2 | V3 |
|---|---|---|
| symbols | 135,746 | 136,165 |
| calls resolved / total | 209,831 / 243,794 | 214,703 / 248,638 |
| type references resolved / total | 80,442 / 117,066 | 82,273 / 120,023 |
| embeds resolved / total | 668 / 678 | 668 / 678 |
| files flagged with syntax errors | 220 (+3 unparseable) | 5 |
| full extraction | 2.90 s | 2.14 s |

The symbols only V 0.5.2 has are its pseudo-imports (`builtin.closure`,
2,042), nameless declarations from its parse failures, and generic receivers
it spelled `Arc<T>` where every other id uses `Arc[T]`. The ones only V3 has
are other platforms' declarations, the three files V 0.5.2 could not parse,
and declarations V 0.5.2 lost to syntax it did not know. The 5 flagged
files are in `x/multiwindow` (methods defined in more than one `$if` branch,
which keeping every branch makes duplicates) and two test fixtures. Inline
assembly for another architecture parses fine but is reported as unsupported
by the backend unless `prefs.supports_inline_asm` is set, which the extractor
does, so the flagged list doesn't depend on the host.

Under V3, `import graphify` in `cmd/` in a worktree under `.claude/worktrees/`
resolved to the main checkout's files, not the worktree's (seen with `-v`;
the lookup rule wasn't traced): build the V3 binaries from the main checkout, or
a worktree's changes are silently left out.

Imports are resolved (`resolve_import` in backend_common.v, October 2026): V3
records the path as written, so `import helper` in `vlib/v/tests/x` was just
`helper`, ambiguous among the many test modules of that name. The lookup
follows V3's order (the nearest v.mod's root, the importing file's
directory, `vlib`, then ancestors) but only inside the extracted tree, so it
stays host-independent, and names the module below `vlib` (`v.tests.helper`,
`os`) or below the tree's root (`cmd.tools.vpm.test_utils`). It corrects
V 0.5.2's nearest-first walk, which took `import rand` in `vlib/crypto/...`
for `crypto.rand` and `import json2` for `x.json2`. On vlang: 23 fewer
unresolved calls and 7 fewer unresolved type references; extraction 0.4 s
slower (2.8 s). The Mac and Windows graphs were still identical after it.

Signatures are written as V 0.5.2 wrote them (October 2026): each module
qualifier in a type, wherever it sits, becomes the module's resolved path
(`[]flat.NodeId` -> `[]v.flat.NodeId`), a type from a selective import is
qualified the same way, and a function type is `fn (...)`. On vlang the
signatures that differ fell from 10,312 to 1,036, and those are almost all
V 0.5.2's errors, which V3 doesn't copy: 362 function-type aliases it wrote
as `type X = X`, 225 variadics without their `...`, 41 generics in the old
`<T>` spelling, signatures missing their return type or parameters, `mut x
&T` written as `&&T`, and module qualifiers it left as written (`color.RGBA64`
for `image.color.RGBA64`) or named by its own import resolution. Fixed-array
sizes differ in 27, because each parser substitutes some constants
(`[node_payload_max_chunks]` is `[4096]` in V3) and neither matches the
source exactly; and 7 module symbols show the declared module name where
V 0.5.2 showed the directory's.

Line numbers follow V 0.5.2's (October 2026): a function's `end_line` is the
last line of its header, the line of the `{` that opens its body, and a
script's `main` spans its first statement to the end of its last (V 0.5.2
said line 1 to line 1). Of 479 symbols whose lines still differ on vlang,
the rest are V 0.5.2's errors or deliberate: its end lines run past a
generic header, a `&[]T` return type or a body-less declaration into the
next one; a module's line is the `module` keyword's where V 0.5.2 gave the
attribute above it (159 files start with an attribute); a declaration
repeated in several `$if` branches is listed at the first, since V3 keeps
them all; and a struct field's end line covers a default value spanning
several lines.

Imports V's parser implies (October 2026) are recorded by both extractors as
import symbols signed `import m (implied)`: `builtin.closure` for an
anonymous function, `sync.threads` for `spawn` or a `thread` type, `sync` for
channels, `<-`, `shared`, `lock` and `select`, `math` for `**`, and the
`embed_file` and `debug` preludes. V 0.5.2's come from its parser's
`auto_imports`; V3's from the same syntax in the flat AST
(`extract_implied_imports`). On vlang V3 finds 1,235 to V 0.5.2's 1,829: it
doesn't count an `it` expression such as `a.map(it * 2)` as a closure (602),
which compiles inline, nor a variable named `shared` (5), and it adds 13 in
code V 0.5.2 didn't see. The resolver ignores implied imports for
visibility, since a file can't name anything through one; counting them had
left 160 calls such as `ch.close()` unresolved in V 0.5.2's graph.

Mapping notes, for whoever moves this forward: methods are `fn_decl`s whose
value is `Recv.name` with the receiver as the first `param`; a static method
is `T@static@f` (graphify's `T__static__f`); a body-less V declaration in a
`.c.v` file is a `c_fn_decl` like `fn C.puts`, with the `C.` dropped, so only
the source line tells them apart; an embedded struct is a `field_decl` named
by its type as written; V3 records no visibility, so `pub` is read from the
source line and a field's from the nearest access label; an error diagnostic
has an empty severity.

It became the default on 7 October 2026, once its tests passed on all three
OSes in CI and the remaining differences from the V 0.5.2 extractor were
either fixed or recorded above as that extractor's errors.

Mac and Windows graphs of vlang `abcebfc16d` were compared in October 2026:
same 136,165 symbols, 3 edges apart. Each difference depended on the host and
is fixed for both extractors where it applied: directories are walked in
sorted order (the first of two same-id declarations wins, and `os.ls` order
differs between APFS and NTFS: 1,734 symbols took another file's line or
signature), the graph is assembled in file order whatever the cache held,
V3's anonymous struct names (which embed the absolute path) become
`_VAnonStructN`, inline assembly for another architecture isn't flagged, and
`@[if cond]` guards are blanked before V3 parses, since it drops a guarded
body when the condition is false on the host (79 calls on vlang). The rerun
then matched in every edge and all but one symbol: a `const` inside a
file-scope `$match @OS`, which V3 resolves for the host even with every `$if`
kept. The extractor now writes `$match @X` as `$match mut @X`, which makes
the parser build the `$if` chain and keep every branch (3 consts on vlang).
V 0.5.2's extractor records nothing declared inside a file-scope `$match`.

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

Resolved in October 2026 by the V3 extractor, which keeps every branch of a
platform conditional (see the end of this section); CI checks it. What
follows describes the V 0.5.2 extractor, since removed.

The same vlang commit can extract to different graphs on different hosts.
Compared on vlang `1b4ecb9c05` (October 2026), an arm64 Mac against an x86_64
Windows machine, after symbol ids were made independent of the working
directory (`5170207`) and extraction began recovering past syntax errors
(`b2f253b`): of 132,735 symbols found on both, none differ in id. What remains
is 3 import symbols and 11 call edges, all inside `$if darwin` or
`$if windows` blocks, plus one file, `vlib/net/http/util.v`, that only the Mac
reports as having a syntax error, in its Windows-only branch.

An earlier comparison (vlang `d2a18d9`, September 2026: 108,812 versus 108,848
symbols) attributed most of its gap, 37 more symbols on x86_64 in five
inline-assembly tests (`vlib/v/slow_tests/assembly/*.amd64.v` and `*.i386.v`),
to the CPU architecture. That was mistaken. V 0.5.2 cannot parse those tests'
asm syntax on either host, and before `b2f253b` each host's parser stopped at
its first error, at different points. With recovery both hosts read all 16
such files in full and extract the same symbols from them. The architecture
played no part beyond where the parser happened to stop.

Host dependence now comes only from platform conditionals. Extraction parses
with preferences from `pref.new_preferences()` (`extract_prefs` in
`backend_v.v`), which default the target OS and architecture to the host's,
and the V1 parser evaluates conditionals against them at parse time: a
top-level `$if` whose condition is false for the target is skipped
(`comptime_skip_curr_stmts` and `skip_scope()` in V 0.5.2's
`vlib/v/parser/if_match.v`). That holds for architecture conditions such as
`$if amd64` as well as for OS conditions.

Graphify's own extractor used not to descend into top-level `$if` blocks, so
a declaration inside one was missing on every host, not only on the platforms
where the condition is false. (Imports were unaffected: the parser collects
those itself.) Fixed in October 2026: `top_level_decls` in `backend_v.v`
flattens the branch the parser kept into the file's top-level statements. On
vlang `414f15fb7b` that added 180 symbols in 25 files (functions, methods,
constants, structs, enums and fields; an earlier count of 16 covered functions
only) and lost none. One id changed form: three test files each declare `ret`
inside a top-level `$if`, so it is now split per file by the usual collision
disambiguation. The fix makes the platform difference below somewhat larger,
since declarations in a taken branch now appear on the hosts that take it
instead of on none.

Consequences:

- graphs in a store shared between machines differ by platform, even after
  symbol ids were made independent of the working directory (`5170207`);
- `graphify diff` across two machines' graphs reports symbols as missing that
  are only another platform's code;
- the difference is small for vlang today (3 symbols and 11 edges between the
  Mac and Windows), but grows with the amount of platform-specific code in a
  project.

Options:

- pin the target OS and architecture in the parser preferences, so every host
  extracts one canonical view. This would be deterministic but omit code that
  only exists for other platforms, and it is not known to work in V1 (see
  below);
- extract every branch of each platform conditional. V3 supports this
  (`preserve_comptime_conditionals`, measured below). V1 does not: see the
  experiment below.

**V1 has no usable keep-all-branches mode (checked October 2026, vlang
`414f15fb7b`).** V 0.5.2's parser skips false top-level `$if` branches unless
`is_fmt` (set for `vfmt`) or `output_cross_c` (`-os cross`) is set, so both
were tried as extraction preferences, against V3 as ground truth: V3 in
preserve mode finds 2,254 symbols that its default mode does not, the code
other platforms see, and today's graph has none of them. Formatter mode
captured 48 of the 2,254, lost 62 real symbols (44 of them functions) and
added 22 that V3 does not find; cross mode captured the same 48, lost 101
(mostly struct fields) and added 8. Both only pick up some platform-gated
imports, and both change parsing elsewhere.

Overriding the target OS in V1's preferences also does not behave like a
different host. In a fixture with `$if windows { import winonly }` and
`$if macos { import maconly }`, the Mac with the target OS set to `windows`
still resolved to `maconly`, and combined with formatter mode it lost
`winonly` again. This was observed, not root-caused. It means cross-host
behavior can only be verified on a real second host, and that pinning the
preferences would need such a check before being relied on.

Host independence therefore belongs to the V3 port (§6) rather than to the V1
path.

**The V3 extractor is host-independent (verified October 2026, vlang
`abcebfc16d`).** Built with `-d graphify_v3` and extracted on the arm64 Mac
and the x86_64 Windows machine, the two graphs have the same 136,168 symbols
and 498,034 edges, field for field, and the same 5 flagged files; only
`root`, the binary hash and the timestamp differ. Getting there took the
fixes listed in §6: every `$if` and `$match` branch kept, `@[if]` guards
blanked, inline assembly for another architecture not flagged, anonymous
struct names without the path, and files walked and assembled in sorted
order. The last also applies to the V1 extractor, whose graphs still differ
by platform conditionals as described above.

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
v -path "/tmp/gfshim|@vlib|@vmodules" -prod -gc none -o bin/graphify cmd/cli
```

Related: `v test .` from the main checkout also descends into
`.claude/worktrees/` and runs every worktree's copy of the tests, each against
whatever commit that worktree has checked out. Since `77742d7` and `e48a80c`
those copies no longer race on shared temp directories, but their results
describe stale code; the main checkout's own result is the line for
`graphify_test.v` at the root. (With V 0.5.2, `v test graphify_test.v`
tested just that file; V3 compiles a file given that way on its own, without
the rest of the module, so it fails.)

A durable fix could be a build script that detects a worktree and adds the
module path itself, or at least a README note in the build section.
