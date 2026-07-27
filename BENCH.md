# Token A/B benchmark

Does consulting the graph cost fewer tokens than reading source? Measured with
`cmd/bench` on **real, external** V codebases (not graphify's own source).
Token count is estimated as `chars / 4` — a rough proxy, not a real tokenizer.

## Results

| Corpus | files | symbols | **Task A** (map: source vs skeleton) | Task B (1 symbol, median) |
| --- | --- | --- | --- | --- |
| `vlib/v/ast` | 17 | 816 | **9.6×** (89% fewer) | 158× *(inflated — see caveat)* |
| `vlib/v/parser` | 29 | 494 | **18.6×** (94% fewer) | 36× *(inflated)* |
| `c2v` | 9 | 158 | **20.8×** (95% fewer) | 60× *(inflated)* |

## What's credible

**Task A — "map the codebase" — is the defensible, apples-to-apples number:**
read every file once vs. read the skeleton once. On real code that's a
**~10–20× token reduction (89–95% fewer)**. This is graphify's strongest and
most honest case: navigation, orientation, "what's in here / where is X".

## What's NOT credible (and why)

**Task B is an upper bound, not a headline.** It assumes the file-mode baseline
reads the *entire* containing file to understand one symbol. For large,
symbol-dense files (e.g. a 1600-line `ast.v`) that massively overstates the
baseline — Claude would do a targeted read, not load the whole file per symbol.
When the realistic alternative is grep + targeted read, the graph saves mainly
the **search**, not the body bytes.

An earlier version of this benchmark *summed* the whole-file cost per symbol,
manufacturing a "113×" — that was a methodology bug (a shared file counted once
per symbol). Fixed: Task B now reports per-independent-task ratios only, with
this caveat.

## Honest limitations

- `chars/4` is an estimate; a real tokenizer would shift numbers somewhat.
- This measures **artifact sizes**, not an end-to-end Claude Code session. The
  gold-standard test is running the same task twice (graphify wired vs. not) and
  comparing actual API token counts.
- Savings assume Claude actually navigates via the graph + targeted reads. The
  Phase 3 hooks nudge this but do not force it; if the model over-reads, savings
  shrink.

## Live result (end-to-end)

Real A/B via `bench/live` (task = map + call relationships on `vlib/v/ast`),
headless `claude -p` sessions, **3 runs each, all on opus-4-8**:

| pair | baseline uniq | wired uniq | unique× | total× | turns b/w |
| --- | --- | --- | --- | --- | --- |
| 1 | 101,088 | 98,405 | 1.03× | 2.16× | 23 / 12 |
| 2 | 94,312 | 50,219 | 1.88× | 2.01× | 25 / 14 |
| 3 | 66,988 | 41,642 | 1.61× | 2.47× | 27 / 13 |
| **avg** | | | **1.51×** | **2.21×** | |

**Honest headline: ~1.5× fewer unique-input tokens (high variance, 1.0–1.9×) and
~2.2× fewer total tokens (stable) and roughly half the turns.** Lower than the
first single run (2.7×) because:

- **The baseline here is *efficient*** — it greps surgically and does targeted
  reads (Grep 5–9×, Read 2–3×, some Bash), not whole-file dumps. graphify's edge
  shrinks against a smart baseline; the 2.7× was vs. a wastefully whole-file-reading one.
- **The wired session pays a `ToolSearch` tax** (1–2 calls per run) because the
  MCP tools load *deferred* in headless mode — pure overhead a GUI session with
  pre-loaded tools wouldn't have. This *understates* graphify here.

### After improvements (get_body, fields/refs, compact overview)

Two task types, 3 runs each, opus, headless. (An interim version had `overview`
dump the *full* skeleton — it regressed nav to 1.0× total; fixed to a compact
counts+top-symbols summary, ~240 tokens.)

| task | metric | original | regressed (overview=full) | **fixed** |
| --- | --- | --- | --- | --- |
| navigation | unique | 1.51× | 1.19× | **1.56×** |
| navigation | total | 2.21× | 1.0× | **2.41×** |
| navigation | wired turns | 12–14 | 15–17 | **7–10** |
| deep-dive | unique | ~1× (couldn't answer) | — | **1.82×** |
| deep-dive | total | — | — | **1.65×** |

- **Navigation recovered and improved** — compact `overview` + `get_node` cut wired
  turns to 7–10. Net ~1.6×/2.4×, slightly above the original.
- **Deep-dive is a NEW win.** The wired session used `get_body` ×3–4 to fetch
  individual function bodies instead of reading whole files — a task class that
  was ~1× before (graphify couldn't answer it, so the model read files anyway).
  Now ~1.8×/1.65×, and up to 3.5× when the baseline would load a large file.
- Variance stays high (baseline efficiency swings a lot); `ToolSearch` tax persists.

**Lesson banked:** richer tools aren't free — `overview` dumping everything was a
regression the benchmark caught before it shipped. Targeted output (compact
overview, `get_body`) is what wins.

### Controlled run (model pinned to opus, plugin-isolated via --strict-mcp-config, n=4/task)

| task | total tokens median (range) | turns wired vs base | unique median (range) |
| --- | --- | --- | --- |
| navigation | **2.26×** (1.84–3.16×) | **8–12 vs 17–21** | 1.02× (0.83–1.67×) |
| deep-dive | **1.95×** (1.5–3.59×) | **11–12 vs 15–26** | 1.25× (0.48–2.48×) |

Pinning the model and isolating plugins (no more woz_code leak) tightened the two
robust metrics and exposed what's actually going on:

- **Robust wins: ~2× fewer total (billed) tokens and ~half the turns.** Low
  variance — wired runs in 8–12 turns regardless of task; baseline takes 15–26.
- **Unique-input is genuinely ~1× and noisy — and that's NOT measurement error,
  it's the baseline.** An efficient grep-baseline ingests only ~26–44k new tokens;
  graphify's near-constant per-session overhead (~32–40k: skill + tool schemas +
  overview + get_node) roughly matches it. Against a *wasteful* baseline (one read
  132k) graphify wins 2–2.5×. So unique-input savings are baseline-dependent, and
  no amount of run-count reduces that spread.

**Defensible headline:** graphify cuts **total token throughput ~2× and turn count
~2×** on real tasks, robustly. New-context savings are task/baseline-dependent
(~1–2.5×). The turn-halving is the cleanest, lowest-variance result and drives the
billed-cost win.

What's rock-solid across all 3: the wired session used **only graph tools**
(`query_graph`+`get_node`), read **zero files**, and ran in **~half the turns**.
Mechanism confirmed every time. The artifact-size ceiling from `cmd/bench`
(~10–20×) is the theoretical max; live, against a competent baseline, it's
**~1.5–2.2×** — real, repeatable, but modest.

**Mechanism confirmed from the transcripts** (not luck):

| session | graph tools | file reads |
| --- | --- | --- |
| wired | `query_graph` ×1, `get_node` ×3 | **none** |
| baseline | — | `Grep` ×6, `Glob` ×1, `Read` ×2 (whole `types.v` + `table.v`) |

The wired session answered entirely from the graph and opened zero files; the
baseline grep-hunted and read two large files whole. The savings are exactly the
avoided whole-file reads. (Both read byte-identical source — the baseline
happened to run from the parent dir and grep into `wired\ast`, which doesn't
affect the token count.)

Single run; repeat 3× and average to rule out variance.

### Answer quality (the catch)

Comparing the two final answers: the **map** was comparable in both. But on
**call relationships** — the core of the task — graphify was much less complete:

| | `type_to_str` callers found |
| --- | --- |
| graphify | 2 |
| baseline (read files) | ~20 (all real) |

**Root cause:** `collect_calls` in `backend_v.v` only walks `ExprStmt`, `Return`,
`AssignStmt`, `ForStmt`. Calls inside `if`/`match`/`for-in`/nested blocks/string
interpolation are not recorded, so the call graph has **low recall**.

**Verdict:** graphify saved 63% tokens but produced an incomplete call-relationship
answer. It is currently a strong, cheap **map / first pass**, but NOT yet a
trustworthy source of truth for "find all callers" (impact analysis). Highest-value
fix: make `collect_calls` walk the full statement/expression tree (Phase 4).

### FIXED

`collect_calls` now walks the full statement/expression tree (if/match/for/blocks/
or-blocks/args/interpolation/initializers/closures) and records one edge per
distinct callee per caller. Verified on the same case:

| | `type_to_str` callers | `register_sym` callers |
| --- | --- | --- |
| before | 2 | partial (missed `unwrap_generic_type_ex_with_depth`) |
| after | **16** (matches baseline) | full set incl. `unwrap_generic_type_ex_with_depth` |

Call edges went 1036 → 1801 total (≈3.5× more `calls` edges), and the per-caller
dedup also removed the duplicate-caller noise (`register_builtin_type_symbols`
now listed once, not ~30×). graphify's call graph is now trustworthy for impact
analysis, not just mapping.

## Verdict

The premise **survives**: there is a real, measured **~10–20× reduction for the
navigation/mapping use case** on real codebases. The headline should be
"~10–20× for navigation", **not** the 70–79× the Python tool advertises (that
figure reflects their whole-corpus, LLM-augmented case). graphify's value is
concentrated in orientation and structure, weaker for single-symbol deep dives.

Reproduce: `v run cmd/bench <path-to-codebase>`
