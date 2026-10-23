# graphify vs grep

A benchmark of how completely, and at what cost, a Claude session answers questions
about V code with graphify's MCP tools, against one with grep alone. `questions.md`
has the questions and their scope, and `key.md` the answer key, each item confirmed
at its source line.

## How to run it

`headless/run.sh` (macOS, Linux) or `headless/run.ps1` (Windows) runs a whole round
as separate `claude -p` sessions, so every machine runs the same test:

```bash
bench/compare/headless/run.sh /tmp/vbench-$(date +%F)
```

- It runs four sessions at once, two per tool, with the same prompt but for the
  tools (`headless/prompt-*.md`):
  - **graphify:** the graphify MCP server and the user's setup, as a normal session has.
  - **baseline:** no MCP server (`--strict-mcp-config` with none) and none of the
    user's settings (`--setting-sources project,local`), so no graphify hook or
    `~/.claude/CLAUDE.md` reaches it. It checks each run's own start record, and
    fails if a baseline run saw an MCP server.
- Every run may use Grep, Glob, Read and read-only shell commands; a graphify run may
  also use the graphify tools.
- Then it has a blind grader grade the four answers. The grader is a baseline-style
  session that sees only the labels run1 to run4 (`headless/prompt-grade.md`).
- Settings default to `graphify.config.json` (`vlang_repo`, `store`): `VLANG`,
  `GRAPHIFY_MCP`, `GRAPH`, `PROJECTS` and `MODEL` override them.
- The output directory's path must not contain "graphify", since the runs see it.
- The CLI must be logged in (`claude auth login`).

It writes each run's transcript (`.jsonl`) and answer (`.md`), `mapping.txt` (runs
1 and 4 are graphify), `runs.txt` (turns, time, cost, tool calls, MCP servers seen),
`usage.txt` (`usage.py`) and `grade.md`. A run's answer is the reply in which its agent
first stopped (`answer.py`), its answer to the prompt. When a hook or a classifier
answers that stop with more input, the agent replies again, and the transcript's own
result holds only its last reply; those later replies stay in the transcript and aren't
graded. `python3 answer_test.py` checks this. Copy the answers and those files into
`results/<date>/` to keep a round.

The key is keyed at vlang 417c85b1ec, with its changes at later commits at its end.
At another commit, the grader re-keys at the source and reports any drift.

Rounds before 2026-10-22 ran as subagents of one session: four read-only agents with
the same prompt, graded by a fifth. A grep agent there still had the graphify tools
loaded, the user's CLAUDE.md telling it to use them, and a hook suggesting graphify on
each search. That made its baseline not quite one. Two runs a tool, because one run is
noisy: in earlier, single-run rounds grep took between 40 and 67 s on the same
questions.

## Measures

- **Items found / wrong**: against `key.md`, by the blind grader.
- **Tool calls**: the tools an agent called. Several can go in one turn.
- **Turns**: the API responses in the run, each one the whole conversation sent to
  the model again. Cost follows these, not tool calls: a grep agent's broad `rg` is
  one call and usually a turn of its own, while a graphify agent often sends several
  `get_node` calls in one turn.
- **Final context**: the tokens in the conversation when the agent stopped. The
  prompt, each tool result and each reply count once. It shows how much the agent
  took in, not what the run cost. It is what an agent's usage reports as its tokens.
- **Cache reads, over all turns**: the input read from the prompt cache, summed over
  every turn. This is the bulk of what a run reads, and it grows with the turns.
- **Weighted input**: cache writes x 1.25 + cache reads x 0.1 + uncached input x 1,
  the input's cost in plain input tokens at the usual relative prices. This is the
  cost to compare.

`usage.py` reads them from the agents' transcripts. Output tokens are left out: the
transcripts record only a few hundred per run, too few to be the real count, and
they are small next to the input either way.

## Results

### 2026-10-22, headless, on Windows, graphify at 612193e, vlang at ffc38ada48

The Opus round on Windows, with `headless/run.ps1`. graphify at 612193e has the same
code as 1672ca7 (#118): #119 changed only the benchmark. Files in
`results/2026-10-22-windows/`. The baseline runs saw no MCP server and no graphify tool.

| Run | Items found | Wrong | Q3 extra | Tool calls | Turns | Time | Cost |
| --- | --- | --- | --- | --- | --- | --- | --- |
| graphify 1 | 69/69 | 0 | 10/10 | 45 | 48 | 226 s | $2.13 |
| graphify 4 | 67/69 | 0 | 10/10 | 41 | 43 | 166 s | $1.91 |
| baseline 2 | 67/69 | 0 | 10/10 | 78 | 79 | 333 s | $2.75 |
| baseline 3 | 68/69 | 0 | 5/10 | 52 | 53 | 226 s | $2.19 |
| **graphify, mean** | **68** | 0 | 10 | **43** | **45.5** | **196 s** | **$2.02** |
| **baseline, mean** | **67.5** | 0 | 7.5 | **65** | **66** | **280 s** | **$2.47** |

| Run | Final context | Cache writes | Cache reads, all turns | Weighted input |
| --- | --- | --- | --- | --- |
| graphify 1 | 140k | 140k | 3.35M | 510k |
| graphify 4 | 125k | 125k | 2.90M | 446k |
| baseline 2 | 163k | 134k | 5.55M | 723k |
| baseline 3 | 153k | 124k | 4.14M | 569k |
| **graphify, mean** | **133k** | 133k | **3.12M** | **478k** |
| **baseline, mean** | **158k** | 129k | **4.85M** | **646k** |

What it says:

- Completeness is level: 68 and 67.5 of 69, no wrong items. graphify 4 missed two Q4
  calls (veb/veb_livereload.v:144 and :166). Baseline 2 missed Q2's points 1 and 3, and
  baseline 3 missed point 1. Of the Q3 extras, baseline 3 left out the five [windows]
  [openssl] routes.
- graphify finished 30% sooner (196 s against 280 s), with 34% fewer tool calls, and cost
  18% less ($2.02 against $2.47; weighted input 26% less).
- Both sides cost more than in the `run.sh` round below, at the same commits: the
  baseline $2.47 against $2.03, graphify $2.02 against $1.45. This round doesn't show why.
- The graphify answers had to be recovered for grading. A graphify run has the user's
  setup, and here that includes a global Stop hook that asks for a closing review. In both
  graphify runs the agent added that review in a message after its answer, and the
  harness then kept only the last message, so the first grade saw only the reviews and
  scored them 3 and 2 of 69. `run1.md` and `run4.md` here are the answers taken from the
  transcripts (line 201 of run1's, line 186 of run4's; as in the other rounds, the
  transcripts aren't kept here), and `grade.md` is a second grade of all four by a fresh
  grader with the same prompt. In run 1 the agent also repeated its answer, and a safety
  classifier cut that repeat off.
- The hook's extra turns are in graphify's turns and cost.

### 2026-10-22, headless, graphify at 1672ca7 (#118), vlang at ffc38ada48

The Opus round again, with `headless/run.sh` as committed, after #118. Files in
`results/2026-10-22-r3/`. The baseline runs saw no MCP server and no graphify tool.

| Run | Items found | Wrong | Q3 extra | Tool calls | Turns | Time | Cost |
| --- | --- | --- | --- | --- | --- | --- | --- |
| graphify 1 | 69/69 | 0 | 10/10 | 49 | 50 | 156 s | $1.52 |
| graphify 4 | 68/69 | 0 | 10/10 | 33 | 34 | 158 s | $1.38 |
| baseline 2 | 69/69 | 0 | 10/10 | 50 | 51 | 251 s | $2.14 |
| baseline 3 | 69/69 | 0 | 10/10 | 58 | 59 | 230 s | $1.91 |
| **graphify, mean** | **68.5** | 0 | 10 | **41** | **42** | **157 s** | **$1.45** |
| **baseline, mean** | **69** | 0 | 10 | **54** | **55** | **241 s** | **$2.03** |

| Run | Final context | Cache writes | Cache reads, all turns | Weighted input |
| --- | --- | --- | --- | --- |
| graphify 1 | 116k | 91k | 2.42M | 356k |
| graphify 4 | 110k | 85k | 2.21M | 327k |
| baseline 2 | 151k | 126k | 3.71M | 528k |
| baseline 3 | 128k | 102k | 3.30M | 458k |
| **graphify, mean** | **113k** | 88k | **2.32M** | **342k** |
| **baseline, mean** | **140k** | 114k | **3.50M** | **493k** |

What it says:

- #118 holds. Neither graphify run named `backend_vschannel_d_cross.v`. The four
  VSChannel steps now cite `vschannel_pooled_transport_windows.c.v:270` and `:226`.
- Completeness is level: 68.5 and 69 of 69, no wrong items, every run with all ten
  [openssl] routes. graphify 4's miss is a strict one: Q2's point 1, `File{}` at
  os/os.c.v:1246, described but not cited.
- graphify finished 35% sooner (157 s against 241 s) and cost 29% less ($1.45 against
  $2.03; weighted input 31% less).
- The baseline did better on Q3 than in the first round: all ten [openssl] routes
  twice, against 10 and 0. One round of two runs a side is noisy, so compare rounds
  by their means, and over several rounds.

### 2026-10-22, headless, graphify at 95db630, vlang at ffc38ada48

69 items, re-keyed at ffc38ada48 (see `key.md`). The Q3 [openssl] routes are counted
apart as extra. Files in `results/2026-10-22/`. The baseline runs saw no MCP server and
no graphify tool; their start records show none.

| Run | Items found | Wrong | Q3 extra | Tool calls | Turns | Time | Cost |
| --- | --- | --- | --- | --- | --- | --- | --- |
| graphify 1 | 69/69 | 0 | 10/10 | 39 | 40 | 138 s | $1.33 |
| graphify 4 | 69/69 | 0 | 10/10 | 35 | 36 | 168 s | $1.34 |
| baseline 2 | 69/69 | 0 | 10/10 | 62 | 63 | 198 s | $2.17 |
| baseline 3 | 68/69 | 0 | 0/10 | 46 | 47 | 199 s | $1.76 |
| **graphify, mean** | **69** | 0 | 10 | **37** | **38** | **153 s** | **$1.34** |
| **baseline, mean** | **68.5** | 0 | 5 | **54** | **55** | **199 s** | **$1.97** |

| Run | Final context | Cache writes | Cache reads, all turns | Weighted input |
| --- | --- | --- | --- | --- |
| graphify 1 | 112k | 87k | 1.94M | 303k |
| graphify 4 | 107k | 82k | 2.10M | 312k |
| baseline 2 | 152k | 126k | 3.56M | 514k |
| baseline 3 | 123k | 98k | 3.09M | 432k |
| **graphify, mean** | **110k** | 85k | **2.02M** | **308k** |
| **baseline, mean** | **138k** | 112k | **3.33M** | **473k** |

(Turns in the first table are the session's own count; `usage.py` counts the API
responses by id: 25, 27, 38 and 39.)

What it says:

- Both are about as complete: 69 and 68.5 of 69, with no wrong items. The miss was
  baseline 3's: Q3's route through `socks5_ssl_dial`.
- graphify finished 23% sooner (153 s against 199 s), with 31% fewer tool calls, and
  cost 32% less ($1.34 against $1.97; weighted input 35% less, 308k against 473k).
- The routes only other builds have are now graphify's to find. Both graphify runs
  found all ten [openssl] routes, through the build conditions on declarations and
  calls (#103, #108, #109, #113). The baseline runs found 10 and 0. On 2026-10-20 both
  graphify runs found 3.
- Both graphify runs gave four of those routes a wrong file for one step. They put
  two calls in `backend_vschannel_d_cross.v`, a 13-line `-d cross` stub, instead of
  `vschannel_pooled_transport_windows.c.v`. `shortest_path` had shown the stub's copy
  of a function both files declare. Fixed in #118, as the next round shows.
- All four noticed that Q2's premise no longer holds at this commit (vlang/v#30945).
- Against 2026-10-20 the gap is wider: 23% against 20% in time and 35% against 13% in
  weighted input. Part of that may be the clean baseline and the headless harness, rather
  than graphify itself.

### 2026-10-22, headless, Haiku 5.5, same commits

The same round with `MODEL=claude-haiku-5-5`, run as the end-to-end test of
`headless/run.sh`, graded by Haiku too. Files in `results/2026-10-22-haiku/`.

| Run | Items found | Wrong | Q3 extra | Tool calls | Time | Cost | Weighted input |
| --- | --- | --- | --- | --- | --- | --- | --- |
| graphify 1 | 68/69 | 0 | 10/10 | 63 | 252 s | $0.36 | 499k |
| graphify 4 | 66/69 | 0 | 10/10 | 51 | 209 s | $0.25 | 365k |
| baseline 2 | 61/69 | 0 | 3/10 | 49 | 192 s | $0.34 | 474k |
| baseline 3 | 65/69 | 2 | 5/10 | 80 | 295 s | $0.51 | 816k |
| **graphify, mean** | **67** | 0 | 10 | **57** | **231 s** | **$0.31** | **432k** |
| **baseline, mean** | **63** | 1 | 4 | **64.5** | **244 s** | **$0.43** | **645k** |

- With the smaller model, the completeness gap opens:
  - graphify found 67 of 69 on average, against 63 for the baseline.
  - The baseline gave 2 wrong items, graphify none.
  - graphify found all ten [openssl] routes both times, against 3 and 5.
- The baseline's misses were in Q3 (4 of 7 default routes, both runs) and Q4 (2 of 6
  in one run). Those are the questions the graph is built for: routes, and callers of
  a method whose name many types share.
- Time and cost are closer than with Opus: 5% faster and 28% cheaper on average.
  Haiku's grader is less thorough than Opus's, so read its counts as rougher.

### 2026-10-20, graphify at 3dd6f94 (#99), vlang at 417c85b1ec

69 items. The Q3 [openssl] routes 8-17 are counted apart as extra.

| Run | Items found | Wrong | Q3 extra | Tool calls | Turns | Time |
| --- | --- | --- | --- | --- | --- | --- |
| graphify A | 69/69 | 0 | 3/10 | 46 | 31 | 222 s |
| graphify B | 66/69 | 0 | 3/10 | 49 | 30 | 233 s |
| grep A | 68/69 | 0 | 3/10 | 38 | 37 | 275 s |
| grep B | 69/69 | 0 | 10/10 | 34 | 34 | 290 s |
| **graphify, mean** | **67.5** | 0 | 3 | **47.5** | **30.5** | **228 s** |
| **grep, mean** | **68.5** | 0 | 6.5 | **36** | **35.5** | **283 s** |

| Run | Final context | Cache writes | Cache reads, all turns | Weighted input |
| --- | --- | --- | --- | --- |
| graphify A | 98k | 98k | 2.21M | 343k |
| graphify B | 113k | 113k | 2.38M | 379k |
| grep A | 109k | 109k | 2.90M | 427k |
| grep B | 111k | 111k | 2.63M | 402k |
| **graphify, mean** | **106k** | 106k | **2.29M** | **361k** |
| **grep, mean** | **110k** | 110k | **2.77M** | **414k** |

What the misses were:

- graphify B missed two of the 15 `wait_for_read` calls (openssl/ssl_connection.c.v:468
  and :538). The graph has both: `get_node openssl.SSLConn.wait_for_read` lists them.
  The agent dropped them.
- graphify B and grep A each left out that `open_append` starts from a zero `File{}`
  (os.c.v:1246), one of Q2's four required points.
- Only grep B listed every [openssl] route of Q3. The graph resolves `ssl.SSLConn`
  to the default build's `mbedtls.SSLConn`, whose `dial` doesn't call `net.dial_tcp`,
  so `shortest_path` can't show a route that only an OpenSSL build has.

What it says:

- Told to be complete, both tools are about as complete: 67.5 and 68.5 of 69, with no
  wrong items. The misses were the agents', not the tools'.
- graphify finished about 55 s (20%) sooner and cost about 13% less (weighted input
  361k against 414k), reading 17% fewer tokens from the cache over the run. Its final
  context was about the same (106k against 110k).
- It made more tool calls (47.5 against 36) in fewer turns (30.5 against 35.5): it
  sent several small `get_node` lookups at once, where a grep agent spends a turn on
  each broad `rg`. Counted in tool calls, graphify looks the dearer; counted in what
  the model read, it is the cheaper.
- The graph knows one build. A question whose answer depends on a `-d` flag or the
  OS needs grep, or a graph extracted for that build.
- `shortest_path` stops at 5 routes, and Q3 has 7 in the default build. Both graphify
  agents went past it with `get_node` to find the other two (through
  `socks5_ssl_dial`, and `HttpProxy.dial` on to SOCKS5). A session that took its 5 as
  the answer would have missed them.

Found while keying: `get_node TcpConn.write_string` gives its signature as
`fn (c &TcpConn) write_string`, but the source has `(mut c TcpConn)`.
