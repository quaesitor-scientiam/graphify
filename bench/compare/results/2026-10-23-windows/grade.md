I graded all four runs at c4e254fab1. Runs 1, 2 and 4 found every item; run 3 missed two Q2 points. The key's items all still exist, but many of their lines have moved, and the current source has no items the key lacks.

## Scores (graded against the updated key, 69 items)

| Run | Items found / total | Wrong | Q3 extra ([openssl]) found / total |
|---|---|---|---|
| run1 | 69 / 69 | 1 | 10 / 10 |
| run2 | 69 / 69 | 0 | 10 / 10 |
| run3 | 67 / 69 | 0 | 10 / 10 |
| run4 | 69 / 69 | 1 | 10 / 10 |

Q2 is scored on its 4 required points, as the key's count of 69 does. Q3 is scored on the 7 default-build routes.

## Misses and wrong items, per run

**run1**
- Misses: none.
- Wrong: Q6 lists `s.on_running(mut s)` (server.v:116) as a method call with receiver `http.Server`. It calls a function-typed field, which the key does not count as a method call. Run1 says so itself and lists it anyway, so this is a judgment call; counted as wrong.

**run2**
- Misses: none.
- Wrong: none.

**run3**
- Misses, Q2 point 1: it never cites `mut file := File{}` at os/os.c.v:1246.
- Misses, Q2 point 2: it says the int default is 0 but never cites the `fd int` field (os/file.c.v:21) or says it has no default.
- I credited point 3 on the lines 1255-1257 alone; it doesn't say that literal sets only `cfile`.
- Wrong: none.
- Note: the Q1 heading says "16 calls" but the list has the correct 15.

**run4**
- Misses: none.
- Wrong: Q6 lists `s.on_running(mut s)` (server.v:116) as a method call, the same as run1, counted the same way.
- Notes:
  - The Q1 heading says "18 calls" but the list has the correct 15.
  - Q8 calls `ftp.v:204` "`FTP.new_dtp`", but `new_dtp` is a free function (ftp.v:190). The line is right, so I counted it as found with a mislabel.

## Drift in the key at c4e254fab1 (on top of its "Changes at ffc38ada48" section)

No items were removed and none were added. The only drift is moved lines:

- **Q1:**
  - Items 7, 8 and 9 (mbedtls/ssl_connection.c.v) moved: 443 → 445, 916 → 902, 997 → 983. They are in the same functions (`do_handshake_loop`, `socket_read_into_ptr`, `write_ptr`).
  - Not-items: the commented-out call moved 903 → 889, and the mbedtls declaration moved 1121 → 1107.
- **Q2:** the same as at ffc38ada48. The premise is still false: os.c.v:1262-1266 returns the File with `fd: fileno(file.cfile)` at :1264, and points 1-3 hold at the same lines.
- **Q3:**
  - request.v moved:
    - `method_and_url_to_response` call 295 → 307
    - `round_trip` 387 → 402
    - `ssl_do` 400 → 415
    - `Request.http_do` 411 → 426
    - `HttpProxy.http_do` 421 → 436
    - `net.dial_tcp` 531 → 546
  - transport.v, compared with the ffc38 lines, moved:
    - `net.dial_tcp` 791 → 792
    - `vschannel_fresh_round_trip` 807 → 808
    - `tls_fresh_round_trip_ssl` 809 → 810
    - `ssl_conn.dial` 822 → 823
  - transport.v lines 742, 755 and 757 have not moved.
  - Every other route line is unchanged: http.v, transport_h2.v at the ffc38 lines, http_proxy.v, socks5.v, backend.c.v, vschannel files, openssl:336.
  - Not-items moved: `on_redirect` is now at request.v:338, `mbedtls.SSLConn.dial` at :821, and the `h3_round_trip` call is at transport.v:723.
- **Q4:** unchanged.
- **Q5:** unchanged.
- **Q6:** unchanged.
- **Q7:** request.v 293 → 305, 314 → 329, 319 → 334. No new redirect errors in net/http.
- **Q8:** the same 13 functions. `Request.http_do` moved to request.v:546 and `Transport.dial_h1_tcp` to transport.v:792. There are no new callers outside tests.

## Updated per-question totals

| Q | Items |
|---|---|
| Q1 | 15 |
| Q2 | 4 required points (plus 2 supporting) |
| Q3 | 7 default-build routes (plus 10 [openssl] extra) |
| Q4 | 6 |
| Q5 | 12 |
| Q6 | 9 |
| Q7 | 3 |
| Q8 | 13 |
| **Total** | **69** (plus 10 extra) |

No file was edited or created.
