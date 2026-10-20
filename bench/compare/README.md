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
5. Take the tool calls, time and tokens from each agent's usage.

Two runs a tool, because one run is noisy: in earlier, single-run rounds grep took
between 40 and 67 s on the same questions.

## Results

### 2026-10-20, graphify at 3dd6f94 (#99), vlang at 417c85b1ec

69 items. The Q3 [openssl] routes 8-17 are counted apart as extra.

| Run | Items found | Wrong | Q3 extra | Tool calls | Time | Tokens |
| --- | --- | --- | --- | --- | --- | --- |
| graphify A | 69/69 | 0 | 3/10 | 46 | 222 s | 102k |
| graphify B | 66/69 | 0 | 3/10 | 49 | 233 s | 117k |
| grep A | 68/69 | 0 | 3/10 | 38 | 275 s | 113k |
| grep B | 69/69 | 0 | 10/10 | 34 | 290 s | 116k |
| **graphify, mean** | **67.5** | 0 | 3 | **47.5** | **228 s** | **110k** |
| **grep, mean** | **68.5** | 0 | 6.5 | **36** | **283 s** | **115k** |

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
- graphify finished about 55 s (20%) sooner and used about as many tokens, but made
  more tool calls (47.5 against 36), many of them small `get_node` lookups where a
  grep agent runs one broad `rg` and reads the result.
- The graph knows one build. A question whose answer depends on a `-d` flag or the
  OS needs grep, or a graph extracted for that build.
- `shortest_path` stops at 5 routes, and Q3 has 7 in the default build. Both graphify
  agents went past it with `get_node` to find the other two (through
  `socks5_ssl_dial`, and `HttpProxy.dial` on to SOCKS5). A session that took its 5 as
  the answer would have missed them.

Found while keying: `get_node TcpConn.write_string` gives its signature as
`fn (c &TcpConn) write_string`, but the source has `(mut c TcpConn)`.
