**1. `wait_for_read` method calls in vlib/net**
- vlib/net/tcp.c.v:198 — `c.wait_for_read()`, TcpConn (inside `TcpConn.read_ptr`)
- vlib/net/tcp.c.v:224 — `c.wait_for_read()`, TcpConn (inside `TcpConn.read_ptr`)
- vlib/net/raw.c.v:126 — `c.wait_for_read()`, RawConn
- vlib/net/udp.c.v:125 — `c.wait_for_read()`, UdpConn
- vlib/net/udp.c.v:134 — `c.wait_for_read()`, UdpConn
- vlib/net/unix/stream.c.v:142 — `c.wait_for_read()`, unix.StreamConn
- vlib/net/openssl/ssl_connection.c.v:132 — `s.wait_for_read(...)`, openssl.SSLConn
- vlib/net/openssl/ssl_connection.c.v:374 — openssl.SSLConn
- vlib/net/openssl/ssl_connection.c.v:396 — openssl.SSLConn
- vlib/net/openssl/ssl_connection.c.v:468 — openssl.SSLConn
- vlib/net/openssl/ssl_connection.c.v:538 — openssl.SSLConn
- vlib/net/openssl/ssl_listener.c.v:216 — `conn.wait_for_read(timeout)`, openssl.SSLConn (in `accept_handshake`)
- vlib/net/mbedtls/ssl_connection.c.v:443 — `conn.wait_for_read(...)`, mbedtls.SSLConn (in `do_handshake_loop`)
- vlib/net/mbedtls/ssl_connection.c.v:916 — mbedtls.SSLConn
- vlib/net/mbedtls/ssl_connection.c.v:997 — mbedtls.SSLConn

Left out: vlib/net/mbedtls/ssl_connection.c.v:903 is commented out. The free-function calls are tcp.c.v:383, tcp.c.v:654, raw.c.v:191, udp.c.v:192, unix/stream.c.v:218 and unix/stream.c.v:346. The rest are in `_test.v` files.

**2. `os.open_append` and `fd` on Unix**
At this commit the premise doesn't hold: `open_append` does not return `fd == 0` on Unix.
- vlib/os/os.c.v:1246 — `mut file := File{}`. This temporary does have `fd` 0, the default for the `fd int` field (vlib/os/file.c.v:21).
- vlib/os/os.c.v:1255-1257 — on Unix only `cfile` is set, with `C.fopen(&char(cpath), c'ab')`.
- vlib/os/os.c.v:1259-1261 — it returns an error if `cfile` is nil.
- vlib/os/os.c.v:1262-1266 — it returns a new `File{ cfile: file.cfile, fd: fileno(file.cfile), is_opened: true }`. So `fd` is the real descriptor.
- vlib/os/os.c.v:371-378 — `fileno` calls `C.fileno(&C.FILE(cfile))` on Unix (line 377).

The returned `fd` would only be 0 if the stream really got descriptor 0, i.e. stdin had been closed. The zero `fd` exists only in the temporary built at line 1246, before the fix that fills `fd` from `fileno` at line 1264.

**3. Routes from `http.get` to `net.dial_tcp`**
Every route starts with the same prefix P:
`http.get` → vlib/net/http/http.v:71 `fetch` → vlib/net/http/http.v:251 `Request.do` → vlib/net/http/request.v:295 `method_and_url_to_response`

Two shorthands are used below:
- **[ssl-dial]**: `ssl.SSLConn.dial` resolves to `openssl.SSLConn.dial`, which calls `net.dial_tcp` at vlib/net/openssl/ssl_connection.c.v:336. This step only exists under `-d use_openssl` (vlib/net/ssl/ssl_d_use_openssl.v:5). The default mbedtls `SSLConn.dial` (vlib/net/mbedtls/ssl_connection.c.v:827) does not call `dial_tcp`.
- **TFRT**: `Transport.tls_fresh_round_trip`, used by routes 10–15. It goes either
  - (a) → transport.v:809 `tls_fresh_round_trip_ssl` → transport.v:822 [ssl-dial], or
  - (b) → transport.v:807 `vschannel_fresh_round_trip` → vlib/net/http/vschannel_pooled_transport_windows.c.v:270 `tls_fresh_round_trip_ssl` → transport.v:822 [ssl-dial].

Routes:
1. P → request.v:411 `Request.http_do` → request.v:531 `net.dial_tcp`
2. P → request.v:387 `Transport.round_trip` → transport.v:757 `dial_h1_tcp` → transport.v:791 `net.dial_tcp`
3. P → request.v:387 `round_trip` → transport.v:755 TFRT (a)
4. P → request.v:387 `round_trip` → transport.v:755 TFRT (b)
5. P → request.v:387 `round_trip` → transport.v:742 `h2_round_trip` → transport_h2.v:83/104 `h2_dial_and_do` → transport_h2.v:265 `h2_dial_probe` → transport_h2.v:156 `h2_dial_probe_ssl` → transport_h2.v:170 [ssl-dial]
6. Same as 5 up to `h2_dial_probe` → transport_h2.v:154 `h2_dial_probe_vschannel` → vschannel_pooled_transport_windows.c.v:226 `h2_dial_probe_ssl` → transport_h2.v:170 [ssl-dial]
7. P → `round_trip` → transport.v:742 `h2_round_trip` → transport_h2.v:83/104 `h2_dial_and_do` → transport_h2.v:253/314 `h2_fallback_h1` → transport_h2.v:198 `h2_use_h1_pool_or_dial` → transport_h2.v:484/495 TFRT (a)
8. Same as 7, ending in TFRT (b)
9. P → `round_trip` → `h2_round_trip` → `h2_dial_and_do` → transport_h2.v:220/259 `h2_await_dial` → transport_h2.v:469 `h2_fallback_h1` → transport_h2.v:198 `h2_use_h1_pool_or_dial` → transport_h2.v:484/495 TFRT (a)
10. Same as 9, ending in TFRT (b)
11. P → request.v:400 `Request.ssl_do` → backend.c.v:15 `net_ssl_do` → backend.c.v:39 [ssl-dial]
12. P → request.v:400 `ssl_do` → backend.c.v:12 `vschannel_retry_handshake` → vschannel_handshake.v:32 `net_ssl_do` → backend.c.v:39 [ssl-dial]
13. P → request.v:421 `HttpProxy.http_do` → http_proxy.v:173 `HttpProxy.dial` → http_proxy.v:204 `connect_tcp` → http_proxy.v:138 `net.dial_tcp`
14. P → request.v:421 `HttpProxy.http_do` → http_proxy.v:173 `dial` → http_proxy.v:204 `connect_tcp` → http_proxy.v:144 `socks.socks5_dial` → vlib/net/socks/socks5.v:20 `net.dial_tcp`
15. P → request.v:421 `HttpProxy.http_do` → http_proxy.v:160 `ssl_dial` → http_proxy.v:209 `connect_tcp` → http_proxy.v:138 `net.dial_tcp`
16. P → request.v:421 `HttpProxy.http_do` → http_proxy.v:160 `ssl_dial` → http_proxy.v:209 `connect_tcp` → http_proxy.v:144 `socks5_dial` → socks5.v:20 `net.dial_tcp`
17. P → request.v:421 `HttpProxy.http_do` → http_proxy.v:160 `ssl_dial` → http_proxy.v:224 `socks.socks5_ssl_dial` → socks5.v:35 `socks5_dial` → socks5.v:20 `net.dial_tcp`

All files above are in vlib/net/http unless another path is given. Routes 1, 2 and 13–17 reach `dial_tcp` in the default (mbedtls) build. Routes 3–12 need [ssl-dial], so only `-d use_openssl`. Routes with "(b)", route 6 and route 12 also need the Windows/vschannel code paths. The h3 path (transport.v:723) uses UDP and never reaches `dial_tcp`.

**4. Calls of `net.TcpConn.write_string`**
- vlib/net/http/http_proxy.v:176 — `client.write_string(s)`, in `HttpProxy.http_do`
- vlib/net/pop/pop.v:138 — `c.conn.write_string(wire)`, in `pop.Client.send_cmd`
- vlib/veb/veb.v:1103 — `conn.write_string(s)`, in `veb.send_string`
- vlib/veb/veb_livereload.v:144 — `c.write_string(head)`, in `LivereloadHub.add`
- vlib/veb/veb_livereload.v:166 — `c.write_string(payload)`, in `LivereloadHub.send`
- vlib/veb/veb_livereload.v:289 — `conn.write_string(...)`, in `veb.Context.handle_veb_livereload_events`

**5. Direct calls in `os.cp_all` (vlib/os/os.v:71-115)**
- `real_path` — os.v:72, 73
- `exists` — os.v:74, 85, 95, 106
- `error` (builtin) — os.v:75, 89, 99
- `is_dir` — os.v:78, 80, 98, 105
- `file_name` — os.v:79
- `join_path_single` — os.v:81, 103, 104
- `rm` — os.v:87
- `cp` — os.v:92
- `mkdir` — os.v:96, 107
- `ls` — os.v:101
- `cp_all` (recursive) — os.v:110
- `rmdir` — os.v:111

**6. Method calls in `http.Server.listen_and_serve` (vlib/net/http/server.v:73)**
- server.v:79 — `s.listen_and_serve_tls()`, receiver `http.Server`. Declared at vlib/net/http/server_tls_notd_use_openssl.v:46 (default build) and vlib/net/http/server_tls_d_use_openssl.v:11 (`-d use_openssl`).
- server.v:92 — `s.listener.addr()`, receiver `net.TcpListener`, declared at vlib/net/tcp.c.v:661
- server.v:96 — `l.str()`, receiver `net.Addr`, declared at vlib/net/address.c.v:305
- server.v:98 — `s.listener.set_accept_timeout(...)`, receiver `net.TcpListener`, declared at vlib/net/tcp.c.v:649
- server.v:119 — `s.listener.accept_only()`, receiver `net.TcpListener`, declared at vlib/net/tcp.c.v:593
- server.v:120 — `err.code()`, receiver `IError`, declared at vlib/builtin/chan_option_result.v:38 (in the interface at line 36)
- server.v:128 — `conn.set_read_timeout(...)`, receiver `&net.TcpConn`, declared at vlib/net/tcp.c.v:348
- server.v:129 — `conn.set_write_timeout(...)`, receiver `&net.TcpConn`, declared at vlib/net/tcp.c.v:377
- server.v:133 — `s.close()`, receiver `http.Server`, declared at vlib/net/http/server.v:149

`s.on_running(mut s)` at server.v:116 calls a function-typed field, not a method. Plain function calls (`net.listen_tcp`, `new_handler_worker`, `time.sleep`, `eprintln`, `println`, `flush_stdout`) are not listed.

**7. Errors in vlib/net/http that mention a redirect**
- vlib/net/http/request.v:293 — `error('http.request.do: maximum number of redirects reached (${max_redirects})')`
- vlib/net/http/request.v:314 — `error('http.request.do: invalid URL in redirect "${redirect_url}"')`
- vlib/net/http/request.v:319 — `error('http.request.do: invalid URL in redirect "${redirect_url}"')`

**8. Functions that call `net.dial_tcp` directly**
- vlib/net/tcp.c.v:17 — `net.TCPDialer.dial`
- vlib/net/http/request.v:531 — `http.Request.http_do`
- vlib/net/http/transport.v:791 — `http.Transport.dial_h1_tcp`
- vlib/net/http/http_proxy.v:138 — `http.HttpProxy.connect_tcp`
- vlib/net/openssl/ssl_connection.c.v:336 — `openssl.SSLConn.dial`
- vlib/net/socks/socks5.v:20 — `socks.socks5_dial`
- vlib/net/smtp/smtp.v:127 — `smtp.Client.reconnect`
- vlib/net/imap/imap.v:161 — `imap.Client.connect`
- vlib/net/pop/pop.v:54 — `pop.dial`
- vlib/net/ftp/ftp.v:113 — `ftp.FTP.connect`
- vlib/net/ftp/ftp.v:204 — `ftp.new_dtp`
- vlib/net/websocket/io.v:77 — `websocket.Client.dial_socket`
- vlib/db/redis/dial.c.v:8 — `redis.dial_connection`