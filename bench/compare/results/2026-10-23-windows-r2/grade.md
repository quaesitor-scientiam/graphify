I re-keyed at c4e254fab1 and found no drift beyond what the key already records. Runs 1 and 4 get every item, run 3 misses one Q2 point and run 2 misses two. No run gives a wrong item.

| Run | Items found / total | Wrong | Q3 extra ([openssl]) found / total |
|---|---|---|---|
| run1 | 69 / 69 | 0 | 10 / 10 |
| run2 | 67 / 69 | 0 | 10 / 10 |
| run3 | 68 / 69 | 0 | 10 / 10 |
| run4 | 69 / 69 | 0 | 10 / 10 |

The 69 items are Q1 15, Q2 4 (the four required points), Q3 7 (default-build routes), Q4 6, Q5 12, Q6 9, Q7 3 and Q8 13.

## Misses and wrong items per run

**run1:** no misses and no wrong items. All 17 Q3 routes are given, in a different order from the key.

**run2:** two misses, no wrong items.
- **Q2 point 1 missed:** it never cites `mut file := File{}` at os/os.c.v:1246.
- **Q2 point 2 missed:** it says the temporary's `fd` "defaults to 0" but doesn't point to the field `fd int` at os/file.c.v:21. This is a strict call; it states the fact without the line. If the fact alone counts, run2 scores 68/69.
- **Not scored:**
  - Its Q3 text says "Six routes go through `ssl.SSLConn.dial`", but it lists all 10 such routes, and all 17 routes are correct.
  - Its Q8 heading says "13 calls in 12 functions", but it lists 13 functions, which is correct.

**run3:** one miss, no wrong items.
- **Q2 point 2 missed:** it says the `fd` is "0 (the default)" without citing os/file.c.v:21. This is the same strict call; leniently, run3 scores 69/69.

**run4:** no misses and no wrong items.
- **Not scored:** its Q8 heading says "14 calls in 13 functions", but the list has 13 calls, which is correct.

## The key's drift at c4e254fab1

None beyond the key's own "Changes at c4e254fab1" section. HEAD of S:/repo/vlang is c4e254fab12e. Each item, at the lines after both change sections are applied, checks out at the source:
- **Q1:** all 15 calls. mbedtls calls are at :445, :902 and :983; the commented-out call is at :889 and the declaration at :1107. The free-function calls are at tcp.c.v:383 and :654, udp.c.v:192, raw.c.v:191, and unix/stream.c.v:218 and :346.
- **Q2:** the premise is still false. `open_append` returns `File{ cfile, fd: fileno(file.cfile), is_opened: true }` at os/os.c.v:1262-1266, with `fd` at :1264.
  - Points 1-3 hold at 1246, file.c.v:21 and 1253-1257.
  - `fileno` is at os.c.v:371, with the `C.fileno` call at :377.
  - The test is os_fd_test.v:102, with the assertion at :110-112.
- **Q3:** every step holds.
  - In request.v: 307, 402, 415, 426, 436 and 546.
  - In transport.v: 742, 755, 757, 792, 808, 810 and 823.
  - In transport_h2.v: 83/104, 154, 156, 170, 198, 220/259, 253/314, 265, 469 and 484/495.
  - In http_proxy.v: 138, 144, 160, 173, 204, 209 and 224.
  - Also socks5.v:20 and :35, backend.c.v:12, :15 and :39, vschannel_handshake.v:32, vschannel_pooled_transport_windows.c.v:226 and :270, and openssl/ssl_connection.c.v:336.
  - mbedtls `dial` is at :821 and calls `C.mbedtls_net_connect` at :845, not `net.dial_tcp`.
- **Q4:** all 6 hold (http_proxy.v:176, pop.v:138, veb.v:1103, veb_livereload.v:144, :166 and :289). Every other non-test `write_string` in the files that use `TcpConn` is a `strings.Builder`.
- **Q5:** all 12 functions hold at os/os.v:72-111.
- **Q6:** all 9 calls hold at server.v:79-133, and the declarations they call are at the lines in the key.
- **Q7:** request.v:305, :329 and :334. No other error message in net/http mentions a redirect.
- **Q8:** the 13 non-test callers. Every other `dial_tcp` hit is in a test file.

No run gave an item that is true at the source but missing from the key, so nothing was added.

## Updated per-question totals (at c4e254fab1)

| Q | Items | run1 | run2 | run3 | run4 |
|---|---|---|---|---|---|
| 1 | 15 | 15 | 15 | 15 | 15 |
| 2 | 4 (required points; the premise is false at this commit) | 4 | 2 | 3 | 4 |
| 3 | 7 default + 10 extra [openssl] | 7 + 10 | 7 + 10 | 7 + 10 | 7 + 10 |
| 4 | 6 | 6 | 6 | 6 | 6 |
| 5 | 12 | 12 | 12 | 12 | 12 |
| 6 | 9 | 9 | 9 | 9 | 9 |
| 7 | 3 | 3 | 3 | 3 | 3 |
| 8 | 13 | 13 | 13 | 13 | 13 |
| **Total** | **69 (+10 extra)** | **69** | **67** | **68** | **69** |

All four runs say Q2's premise doesn't hold at this commit and cite the `fd: fileno(...)` return at os.c.v:1262-1266, which is the replaced point 4.
