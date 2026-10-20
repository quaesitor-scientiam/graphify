# graphify vs grep

A benchmark of how completely, and at what cost, a Claude session answers questions
about V code with graphify's MCP tools, against one with grep alone. `questions.md`
has the questions and their scope, and `key.md` the answer key, each item confirmed
at its source line.

## How to run it

1. Hold vlang at the key's commit (417c85b1ec), or rebuild the key at another one.
2. Start four read-only agents, two per tool, with the same prompt but for the
   tools: "answer the questions in questions.md; you are scored against a complete
   key, and each item you miss or get wrong counts against you; keep going until
   every list is complete." One pair may use the graphify tools (and Grep/Read where
   the graph can't answer), the other only Grep, Glob, Read and read-only Bash.
3. Save each answer without its tool counts under a label that doesn't say which
   tool it used.
4. Have an agent grade the labelled answers against the key, blind to which tool made
   which, checking at the source any item the key may lack.
5. Take each agent's tool calls and time from its usage, and its tokens from its
   transcript with `usage.py` (see Measures).

Two runs a tool, because one run is noisy: in earlier, single-run rounds grep took
between 40 and 67 s on the same questions.

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
