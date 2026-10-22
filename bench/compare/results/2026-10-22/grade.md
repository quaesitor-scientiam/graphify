# Grade, 2026-10-22

Graded blind by an agent that saw only run1.md to run4.md, `questions.md` and `key.md`.
It checked every item with grep and reading at vlang ffc38ada48, and used no graphify
tools. 69 items; the Q3 [openssl] routes are counted apart as extra.

| Run | Items found | Wrong | Q3 extra |
| --- | --- | --- | --- |
| run1 | 69/69 | 0 | 10/10, 4 with the wrong file for one step |
| run2 | 69/69 | 0 | 10/10 (5 listed in full, 5 given as VSChannel substitutions) |
| run3 | 68/69 | 0 | 0/10 |
| run4 | 69/69 | 0 | 10/10, 4 with the wrong file for one step |

## Per run

**run1.** No misses, no wrong items.
- Q3 extra: routes 11, 13, 16 and 17 put the calls of `tls_fresh_round_trip_ssl`
  (:270) and `h2_dial_probe_ssl` (:226) in `backend_vschannel_d_cross.v`. That file
  is a 13-line `-d cross` stub. The calls are at those lines of
  `vschannel_pooled_transport_windows.c.v`. (graphify showed the stub's copy of the
  calling functions; fixed in #118.)
- Not counted against it: Q6 lists line 116 `s.on_running(mut s)`, correctly as a
  call of a function-typed field (server.v:64), not a method.

**run2.** No misses, no wrong items.
- Q3 extra: [openssl] routes 8, 10, 12, 14 and 16 are listed in full.
- Routes 9, 11, 13, 15 and 17 are given as three VSChannel substitutions, with the
  right files and lines, and each route is unambiguous. Credited; under a strict
  "every route listed" rule it would be 5/10.

**run3.** One miss, no wrong items.
- Missed Q3 route 7: `HttpProxy.ssl_dial` (http_proxy.v:160) →
  `socks.socks5_ssl_dial` (http_proxy.v:224) → `socks.socks5_dial` (socks5.v:35) →
  `net.dial_tcp` (socks5.v:20). It says "all six routes".
- Q3 extra 0/10: it names only the three `ssl_conn.dial` call sites of OpenSSL, with
  partial chains.

**run4.** No misses, no wrong items.
- Q3 extra: the same wrong file as run1 in routes 11, 13, 16 and 17.
- Minor, not counted: Q8 calls `ftp.FTP.new_dtp` a method; it is the free function
  `new_dtp` (ftp/ftp.v:190). The call site, ftp.v:204, is right.

No answer gave a true item missing from the key, so the key gained nothing from the
answers. Its changes at ffc38ada48 are under "Changes at ffc38ada48" in `key.md`.
