**1. `wait_for_read` method calls in vlib/net** (15 calls)
- vlib/net/raw.c.v:126 — `c.wait_for_read()` on `RawConn`
- vlib/net/tcp.c.v:198 — `c.wait_for_read()` on `TcpConn`
- vlib/net/tcp.c.v:224 — `c.wait_for_read()` on `TcpConn`
- vlib/net/udp.c.v:125 — `c.wait_for_read()` on `UdpConn`
- vlib/net/udp.c.v:134 — `c.wait_for_read()` on `UdpConn`
- vlib/net/unix/stream.c.v:142 — `c.wait_for_read()` on `unix.StreamConn`
- vlib/net/openssl/ssl_connection.c.v:132 — `s.wait_for_read(...)` on `openssl.SSLConn`
- vlib/net/openssl/ssl_connection.c.v:374 — on `openssl.SSLConn`
- vlib/net/openssl/ssl_connection.c.v:396 — on `openssl.SSLConn`
- vlib/net/openssl/ssl_connection.c.v:468 — on `openssl.SSLConn`
- vlib/net/openssl/ssl_connection.c.v:538 — on `openssl.SSLConn`
- vlib/net/openssl/ssl_listener.c.v:216 — `conn.wait_for_read(timeout)` on `openssl.SSLConn`, in `accept_handshake`
- vlib/net/mbedtls/ssl_connection.c.v:445 — `conn.wait_for_read(...)` on `mbedtls.SSLConn`, in `do_handshake_loop`
- vlib/net/mbedtls/ssl_connection.c.v:902 — on `mbedtls.SSLConn`
- vlib/net/mbedtls/ssl_connection.c.v:983 — on `mbedtls.SSLConn`

Left out: vlib/net/mbedtls/ssl_connection.c.v:889 is commented out. The free-function calls at net/raw.c.v:191, tcp.c.v:383 and 654, udp.c.v:192, and unix/stream.c.v:218 and 346 don't count. Hits in `_test.v` files are excluded.

**2. `os.open_append` and `fd == 0`**
At this commit, the File that `open_append` returns does not have `fd` 0 on Unix:
- vlib/os/os.c.v:1255-1257 builds a temporary `File{ cfile: C.fopen(&char(cpath), c'ab') }`. That temporary has no `fd`, so its `fd` defaults to 0.
- vlib/os/os.c.v:1262-1266 does not return that temporary. It returns a new `File{ cfile: file.cfile, fd: fileno(file.cfile), is_opened: true }`.
- vlib/os/os.c.v:371-379 shows `fileno` calls `C.fileno(...)` on non-Windows (line 377), which gives the real descriptor.

The question describes the older code: there, `open_append` returned the struct literal with only `cfile` set, so `fd` kept the V zero default. The current code fixes that at line 1264. For comparison, `open_file` sets `fd` explicitly (vlib/os/file.c.v:109), as do `open` and `create` (file.c.v:139, 151).

**3. Routes from `http.get` to `net.dial_tcp`** (17 routes)
Every route starts with the same prefix, P:
`http.get` → `fetch` (vlib/net/http/http.v:71) → `Request.do` (http.v:251) → `Request.method_and_url_to_response` (vlib/net/http/request.v:307).

Six routes go through `ssl.SSLConn.dial`. This reaches `net.dial_tcp` only when `ssl.SSLConn` is `openssl.SSLConn` (`-d use_openssl`), at vlib/net/openssl/ssl_connection.c.v:336. The default mbedtls `SSLConn.dial` (vlib/net/mbedtls/ssl_connection.c.v:821) does not call `dial_tcp`.

Below, `W` means the Windows step `tls_fresh_round_trip` → `vschannel_fresh_round_trip` (transport.v:808) → `tls_fresh_round_trip_ssl` (vlib/net/http/vschannel_pooled_transport_windows.c.v:270). `W'` is the same chain but going directly to `tls_fresh_round_trip_ssl` (transport.v:810).

1. P → `Request.http_do` (request.v:426) → `net.dial_tcp` (request.v:546)
2. P → `Transport.round_trip` (request.v:402) → `Transport.dial_h1_tcp` (vlib/net/http/transport.v:757) → `net.dial_tcp` (transport.v:792)
3. P → `round_trip` (request.v:402) → `tls_fresh_round_trip` (transport.v:755) → `tls_fresh_round_trip_ssl` (transport.v:810) → `SSLConn.dial` (transport.v:823) → `net.dial_tcp` (vlib/net/openssl/ssl_connection.c.v:336)
4. P → `round_trip` (request.v:402) → `tls_fresh_round_trip` (transport.v:755) → `vschannel_fresh_round_trip` (transport.v:808) → `tls_fresh_round_trip_ssl` (vschannel_pooled_transport_windows.c.v:270) → `SSLConn.dial` (transport.v:823) → `net.dial_tcp` (openssl/ssl_connection.c.v:336)
5. P → `round_trip` (request.v:402) → `h2_round_trip` (transport.v:742) → `h2_dial_and_do` (vlib/net/http/transport_h2.v:83/104) → `h2_dial_probe` (transport_h2.v:265) → `h2_dial_probe_ssl` (transport_h2.v:156) → `SSLConn.dial` (transport_h2.v:170) → `net.dial_tcp` (openssl/ssl_connection.c.v:336)
6. Same as 5 up to `h2_dial_probe` (transport_h2.v:265) → `h2_dial_probe_vschannel` (transport_h2.v:154) → `h2_dial_probe_ssl` (vschannel_pooled_transport_windows.c.v:226) → `SSLConn.dial` (transport_h2.v:170) → `net.dial_tcp` (openssl/ssl_connection.c.v:336)
7. … `h2_dial_and_do` (transport_h2.v:83/104) → `h2_fallback_h1` (transport_h2.v:253/314) → `h2_use_h1_pool_or_dial` (transport_h2.v:198) → `tls_fresh_round_trip` (transport_h2.v:484/495) → W' → `SSLConn.dial` (transport.v:823) → `net.dial_tcp` (openssl/ssl_connection.c.v:336)
8. Same as 7, but `tls_fresh_round_trip` → W → `SSLConn.dial` (transport.v:823) → `net.dial_tcp` (openssl/ssl_connection.c.v:336)
9. … `h2_dial_and_do` → `h2_await_dial` (transport_h2.v:220/259) → `h2_fallback_h1` (transport_h2.v:469) → `h2_use_h1_pool_or_dial` (transport_h2.v:198) → `tls_fresh_round_trip` (transport_h2.v:484/495) → W' → `SSLConn.dial` (transport.v:823) → `net.dial_tcp` (openssl/ssl_connection.c.v:336)
10. Same as 9, but through W
11. P → `Request.ssl_do` (request.v:415) → `net_ssl_do` (vlib/net/http/backend.c.v:15) → `SSLConn.dial` (backend.c.v:39) → `net.dial_tcp` (openssl/ssl_connection.c.v:336)
12. P → `ssl_do` (request.v:415) → `vschannel_retry_handshake` (backend.c.v:12) → `net_ssl_do` (vlib/net/http/vschannel_handshake.v:32) → `SSLConn.dial` (backend.c.v:39) → `net.dial_tcp` (openssl/ssl_connection.c.v:336)
13. P → `HttpProxy.http_do` (request.v:436) → `HttpProxy.dial` (vlib/net/http/http_proxy.v:173) → `HttpProxy.connect_tcp` (http_proxy.v:204) → `net.dial_tcp` (http_proxy.v:138)
14. P → `HttpProxy.http_do` (request.v:436) → `dial` (http_proxy.v:173) → `connect_tcp` (http_proxy.v:204) → `socks.socks5_dial` (http_proxy.v:144) → `net.dial_tcp` (vlib/net/socks/socks5.v:20)
15. P → `HttpProxy.http_do` (request.v:436) → `HttpProxy.ssl_dial` (http_proxy.v:160) → `connect_tcp` (http_proxy.v:209) → `net.dial_tcp` (http_proxy.v:138)
16. P → `HttpProxy.http_do` (request.v:436) → `ssl_dial` (http_proxy.v:160) → `connect_tcp` (http_proxy.v:209) → `socks.socks5_dial` (http_proxy.v:144) → `net.dial_tcp` (socks5.v:20)
17. P → `HttpProxy.http_do` (request.v:436) → `ssl_dial` (http_proxy.v:160) → `socks.socks5_ssl_dial` (http_proxy.v:224) → `socks5_dial` (socks5.v:35) → `net.dial_tcp` (socks5.v:20)

**4. Calls of `net.TcpConn.write_string`** (6 calls)
- vlib/net/http/http_proxy.v:176 — `client.write_string(s)!`, in `HttpProxy.http_do`
- vlib/net/pop/pop.v:138 — `c.conn.write_string(wire)`, in `pop.Client.send_cmd`
- vlib/veb/veb.v:1103 — `conn.write_string(s)!`, in `veb.send_string`
- vlib/veb/veb_livereload.v:144 — `c.write_string(head)`, in `LivereloadHub.add`
- vlib/veb/veb_livereload.v:166 — `c.write_string(payload)`, in `LivereloadHub.send`
- vlib/veb/veb_livereload.v:289 — `conn.write_string(...)`, in `Context.handle_veb_livereload_events`

**5. Functions `os.cp_all` calls directly** (vlib/os/os.v)
- `real_path` — 72, 73
- `exists` — 74, 85, 95, 106
- `error` — 75, 89, 99
- `is_dir` — 78, 80, 98, 105
- `file_name` — 79
- `join_path_single` — 81, 103, 104
- `rm` — 87
- `cp` — 92
- `mkdir` — 96, 107
- `ls` — 101
- `cp_all` (recursive) — 110
- `rmdir` — 111

**6. Method calls in `http.Server.listen_and_serve`** (vlib/net/http/server.v)
- 79 `s.listen_and_serve_tls()` — receiver `http.Server`; declared at vlib/net/http/server_tls_notd_use_openssl.v:46 (default build) or vlib/net/http/server_tls_d_use_openssl.v:11 (`-d use_openssl`)
- 92 `s.listener.addr()` — receiver `net.TcpListener`; declared at vlib/net/tcp.c.v:661
- 96 `l.str()` — receiver `net.Addr`; declared at vlib/net/address.c.v:305
- 98 `s.listener.set_accept_timeout(...)` — receiver `net.TcpListener`; declared at vlib/net/tcp.c.v:649
- 119 `s.listener.accept_only()` — receiver `net.TcpListener`; declared at vlib/net/tcp.c.v:593
- 120 `err.code()` — receiver `IError`; declared at vlib/builtin/chan_option_result.v:38 (interface method)
- 128 `conn.set_read_timeout(...)` — receiver `net.TcpConn`; declared at vlib/net/tcp.c.v:348
- 129 `conn.set_write_timeout(...)` — receiver `net.TcpConn`; declared at vlib/net/tcp.c.v:377
- 133 `s.close()` — receiver `http.Server`; declared at vlib/net/http/server.v:149

Line 116 `s.on_running(mut s)` calls a function-pointer field, not a method.

**7. Errors in vlib/net/http that mention a redirect**
- vlib/net/http/request.v:305 — `error('http.request.do: maximum number of redirects reached (${max_redirects})')`
- vlib/net/http/request.v:329 — `error('http.request.do: invalid URL in redirect "${redirect_url}"')`
- vlib/net/http/request.v:334 — `error('http.request.do: invalid URL in redirect "${redirect_url}"')`

**8. Functions that call `net.dial_tcp` directly** (13 calls in 12 functions)
- `net.TCPDialer.dial` — vlib/net/tcp.c.v:17
- `redis.dial_connection` — vlib/db/redis/dial.c.v:8
- `ftp.FTP.connect` — vlib/net/ftp/ftp.v:113
- `ftp.new_dtp` — vlib/net/ftp/ftp.v:204
- `socks.socks5_dial` — vlib/net/socks/socks5.v:20
- `pop.dial` — vlib/net/pop/pop.v:54
- `openssl.SSLConn.dial` — vlib/net/openssl/ssl_connection.c.v:336
- `smtp.Client.reconnect` — vlib/net/smtp/smtp.v:127
- `websocket.Client.dial_socket` — vlib/net/websocket/io.v:77
- `imap.Client.connect` — vlib/net/imap/imap.v:161
- `http.Request.http_do` — vlib/net/http/request.v:546
- `http.Transport.dial_h1_tcp` — vlib/net/http/transport.v:792
- `http.HttpProxy.connect_tcp` — vlib/net/http/http_proxy.v:138
