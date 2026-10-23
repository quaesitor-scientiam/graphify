All four runs are accurate: none gives a false item. Run 1 is complete (69/69), runs 2 and 4 each miss two items, and run 3 misses one item plus half of the Q3 extras. I graded at ffc38ada48 using Grep and Read on S:/repo/vlang, and created or edited no files.

| Run | Items found / total | Wrong | Q3 extra ([openssl]) found / total |
|---|---|---|---|
| run1 | **69 / 69** | 0 | 10 / 10 |
| run2 | 67 / 69 | 0 | 10 / 10 |
| run3 | 68 / 69 | 0 | 5 / 10 |
| run4 | 67 / 69 | 0 | 10 / 10 |

## Misses and wrong items per run

**run1:** no misses, nothing wrong.
- One naming slip in Q8: it calls `ftp.new_dtp` "`ftp.FTP.new_dtp`". It is a free function (ftp/ftp.v:190), not a method of `FTP`. The call site it gives, ftp.v:204, is right, so I counted it as found.
- Its Q6 list includes `s.on_running` (line 116), but it labels it as a function-typed field, not a method, so it isn't wrong.

**run2:** two misses, both in Q2.
- **Missed, Q2 point 1:** it never says `open_append` starts from `mut file := File{}` (os/os.c.v:1246).
- **Missed, Q2 point 3:** it cites the `C.fopen` lines (1255–1257) but never says that literal sets only `cfile`. I scored that as a miss, not a partial.
- Nothing wrong. The extra claims it makes are true at the source: the test at os/os_fd_test.v:102–111 with its comment at :110, and the `h3_round_trip` call at transport.v:723.

**run3:** one miss in Q2, and five Q3 extras left out.
- **Missed, Q2 point 1:** it doesn't mention the `File{}` start at os.c.v:1246.
- **Q3 extra:** it gives the five non-Windows [openssl] routes (key 8, 10, 12, 14, 16) and leaves out the five [windows] variants (9, 11, 13, 15, 17).
- Nothing wrong. Its `mbedtls_net_connect` line, mbedtls/ssl_connection.c.v:859, is correct.

**run4:** two misses, both in Q4.
- **Missed, Q4:** veb/veb_livereload.v:144 (`LivereloadHub.add`).
- **Missed, Q4:** veb/veb_livereload.v:166 (`LivereloadHub.send`).
- Nothing wrong. Its extra claims check out: `C.open` at file.c.v:98 and `fd: fd` at :109.

## Key drift at ffc38ada48

The key's own "Changes at ffc38ada48" section is correct; I confirmed every entry at the source:
- **Q2:** the premise is now false. `open_append` returns `File{ cfile: file.cfile, fd: fileno(file.cfile), is_opened: true }` at os.c.v:1262–1266, with `fd` at :1264. Points 1–3 hold at their old lines, point 4 is replaced by this, and point 6 (the descriptor is really stdin) no longer applies.
- **Q3:** the routes are the same, but these transport.v lines moved: 742, 755, 757, 791, 807, 809, 822. The transport_h2.v lines 469, 484 and 495 also moved.
- **Q8:** item 9 is now at transport.v:791.
- **Q1:** one not-item moved, to unix/stream.c.v:346.

One extra stale line the key doesn't list: the Q3 not-item `Transport.h3_round_trip` is now called at transport.v:723, not 636. It doesn't change any score.

No runs gave true items the key lacked, and the source has no new items:
- **Q1 and Q8:** I grepped all of vlib, leaving out test files, and found no new non-test call sites.
- **Q4:** I checked every non-builder `write_string` call I found in net/ and veb/; only the six key items have a `TcpConn` receiver.
- **Q3:** no new route from `http.get` reaches `net.dial_tcp`.
- **Q5, Q6, Q7:** they match the key at the same lines, including every Q6 declaration line.

## Updated per-question totals (ffc38ada48)

| Q | Items | run1 | run2 | run3 | run4 |
|---|---|---|---|---|---|
| Q1 | 15 | 15 | 15 | 15 | 15 |
| Q2 | 4 (points 1–3, plus revised point 4) | 4 | 2 | 3 | 4 |
| Q3 (default routes) | 7 | 7 | 7 | 7 | 7 |
| Q4 | 6 | 6 | 6 | 6 | 4 |
| Q5 | 12 | 12 | 12 | 12 | 12 |
| Q6 | 9 | 9 | 9 | 9 | 9 |
| Q7 | 3 | 3 | 3 | 3 | 3 |
| Q8 | 13 | 13 | 13 | 13 | 13 |
| **Total** | **69** | 69 | 67 | 68 | 67 |
| Q3 extra | 10 | 10 | 10 | 5 | 10 |

All four runs say Q2's premise no longer holds and back it with os.c.v:1264, as the revised point 4 requires.
