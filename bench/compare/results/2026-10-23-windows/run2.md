**1. Calls of a `wait_for_read` method in vlib/net**
- vlib/net/unix/stream.c.v:142 (`StreamConn`)
- vlib/net/udp.c.v:125 (`UdpConn`)
- vlib/net/udp.c.v:134 (`UdpConn`)
- vlib/net/tcp.c.v:198 (`TcpConn`)
- vlib/net/tcp.c.v:224 (`TcpConn`)
- vlib/net/raw.c.v:126 (`RawConn`)
- vlib/net/openssl/ssl_listener.c.v:216 (openssl `SSLConn`)
- vlib/net/openssl/ssl_connection.c.v:132, 374, 396, 468, 538 (openssl `SSLConn`)
- vlib/net/mbedtls/ssl_connection.c.v:445, 902, 983 (mbedtls `SSLConn`)

Left out: the commented-out call at vlib/net/mbedtls/ssl_connection.c.v:889, the free-function calls (stream.c.v:218, 346; udp.c.v:192; tcp.c.v:383, 654; raw.c.v:191), and the test files.

**2. `os.open_append` and `fd`**
The premise is false: in this tree the `fd` field is not left at 0. `open_append` (vlib/os/os.c.v:1245) opens the file with `C.fopen(&char(cpath), c'ab')` on Unix (vlib/os/os.c.v:1254-1257). It then returns a new `File` with `fd: fileno(file.cfile)` (vlib/os/os.c.v:1262-1266, the `fd` line is 1264). `os.fileno` calls `C.fileno(unsafe { &C.FILE(cfile) })` on Unix (vlib/os/os.c.v:371-379, the call is at 377). The field is declared as `fd int` (vlib/os/file.c.v:21).

The only `File` that has `fd` at its default 0 is the temporary one at vlib/os/os.c.v:1246 and 1255-1257, which sets only `cfile`. That value is never returned. The returned `fd` is 0 only if `fileno` really returns descriptor 0, which happens when stdin was closed and `fopen` reused descriptor 0.

**3. Routes from `http.get` to `net.dial_tcp`**
Every route starts with this common prefix:
- `http.get` → `fetch` (vlib/net/http/http.v:71)
- `fetch` → `Request.do` (vlib/net/http/http.v:251)
- `Request.do` → `Request.method_and_url_to_response` (vlib/net/http/request.v:307)

Below, M stands for `method_and_url_to_response`.

Plain TCP:
- R1: M → `Request.http_do` (request.v:426) → `net.dial_tcp` (request.v:546)
- R2: M → `Transport.round_trip` (request.v:402) → `Transport.dial_h1_tcp` (transport.v:757) → `net.dial_tcp` (transport.v:792)

Through a proxy:
- R3: M → `HttpProxy.http_do` (request.v:436) → `HttpProxy.dial` (http_proxy.v:173) → `HttpProxy.connect_tcp` (http_proxy.v:204) → `net.dial_tcp` (http_proxy.v:138)
- R4: same as R3 until `connect_tcp`, then → `socks.socks5_dial` (http_proxy.v:144) → `net.dial_tcp` (vlib/net/socks/socks5.v:20)
- R5: M → `HttpProxy.http_do` (request.v:436) → `HttpProxy.ssl_dial` (http_proxy.v:160) → `connect_tcp` (http_proxy.v:209) → `net.dial_tcp` (http_proxy.v:138)
- R6: same as R5 until `connect_tcp`, then → `socks5_dial` (http_proxy.v:144) → `net.dial_tcp` (socks5.v:20)
- R7: `HttpProxy.ssl_dial` (http_proxy.v:160) → `socks.socks5_ssl_dial` (http_proxy.v:224) → `socks5_dial` (socks5.v:35) → `net.dial_tcp` (socks5.v:20)

Through TLS (`ssl.SSLConn.dial`): these routes reach TCP only with the OpenSSL backend (`-d use_openssl`). There `ssl.SSLConn` is `openssl.SSLConn` (vlib/net/ssl/ssl_d_use_openssl.v:5), and `openssl.SSLConn.dial` calls `net.dial_tcp` at vlib/net/openssl/ssl_connection.c.v:336. The default mbedtls `dial` uses `C.mbedtls_net_connect` instead (vlib/net/mbedtls/ssl_connection.c.v:845). Each route below ends with `SSLConn.dial` → `net.dial_tcp` (ssl_connection.c.v:336).
- R8: M → `Request.ssl_do` (request.v:415) → `net_ssl_do` (backend.c.v:15) → `SSLConn.dial` (backend.c.v:39)
- R9: M → `ssl_do` (request.v:415) → `vschannel_retry_handshake` (backend.c.v:12) → `net_ssl_do` (vschannel_handshake.v:32) → `SSLConn.dial` (backend.c.v:39)
- R10: M → `round_trip` (402) → `tls_fresh_round_trip` (transport.v:755) → `tls_fresh_round_trip_ssl` (transport.v:810) → `SSLConn.dial` (transport.v:823)
- R11: M → `round_trip` → `tls_fresh_round_trip` (755) → `vschannel_fresh_round_trip` (transport.v:808) → `tls_fresh_round_trip_ssl` (vschannel_pooled_transport_windows.c.v:270) → `SSLConn.dial` (823)
- R12: M → `round_trip` → `h2_round_trip` (transport.v:742) → `h2_dial_and_do` (transport_h2.v:83 or 104) → `h2_dial_probe` (transport_h2.v:265) → `h2_dial_probe_ssl` (transport_h2.v:156) → `SSLConn.dial` (transport_h2.v:170)
- R13: same as R12 until `h2_dial_probe`, then → `h2_dial_probe_vschannel` (transport_h2.v:154) → `h2_dial_probe_ssl` (vschannel_pooled_transport_windows.c.v:226) → `SSLConn.dial` (170)
- R14: … `h2_dial_and_do` → `h2_fallback_h1` (transport_h2.v:253 or 314) → `h2_use_h1_pool_or_dial` (transport_h2.v:198) → `tls_fresh_round_trip` (transport_h2.v:484 or 495) → `tls_fresh_round_trip_ssl` (transport.v:810) → `SSLConn.dial` (823)
- R15: as R14, but `tls_fresh_round_trip` → `vschannel_fresh_round_trip` (transport.v:808) → `tls_fresh_round_trip_ssl` (vschannel_pooled_transport_windows.c.v:270) → `SSLConn.dial` (823)
- R16: … `h2_dial_and_do` → `h2_await_dial` (transport_h2.v:220 or 259) → `h2_fallback_h1` (transport_h2.v:469) → `h2_use_h1_pool_or_dial` (198) → `tls_fresh_round_trip` (484 or 495) → `tls_fresh_round_trip_ssl` (transport.v:810) → `SSLConn.dial` (823)
- R17: as R16, but through `vschannel_fresh_round_trip` (transport.v:808) → `tls_fresh_round_trip_ssl` (vschannel_pooled_transport_windows.c.v:270) → `SSLConn.dial` (823)

When a step has more than one call site (for example 83 or 104), each call site makes a separate route.

**4. Calls of `net.TcpConn.write_string`**
- vlib/veb/veb_livereload.v:144, in `LivereloadHub.add`
- vlib/veb/veb_livereload.v:166, in `LivereloadHub.send`
- vlib/veb/veb_livereload.v:289, in `Context.handle_veb_livereload_events` (`ctx.conn` is `&net.TcpConn`, vlib/veb/context.v:86)
- vlib/veb/veb.v:1103, in `send_string`
- vlib/net/http/http_proxy.v:176, in `HttpProxy.http_do`
- vlib/net/pop/pop.v:138, in `Client.send_cmd` (`conn &net.TcpConn`, pop.v:22)

**5. Direct calls in `os.cp_all` (vlib/os/os.v:71)**
- `real_path`: 72, 73
- `exists`: 74, 85, 95, 106
- `error`: 75, 89, 99
- `is_dir`: 78, 80, 98, 105
- `file_name`: 79
- `join_path_single`: 81, 103, 104
- `rm`: 87
- `cp`: 92
- `mkdir`: 96, 107
- `ls`: 101
- `cp_all` (recursive): 110
- `rmdir`: 111

**6. Method calls in `http.Server.listen_and_serve` (vlib/net/http/server.v:73)**
- 79: `s.listen_and_serve_tls()`, receiver `http.Server`. Declared at vlib/net/http/server_tls_notd_use_openssl.v:46 (default build) and vlib/net/http/server_tls_d_use_openssl.v:11 (`-d use_openssl`).
- 92: `s.listener.addr()`, receiver `net.TcpListener`, declared at vlib/net/tcp.c.v:661
- 96: `l.str()`, receiver `net.Addr`, declared at vlib/net/address.c.v:305
- 98: `s.listener.set_accept_timeout(...)`, receiver `net.TcpListener`, declared at vlib/net/tcp.c.v:649
- 119: `s.listener.accept_only()`, receiver `net.TcpListener`, declared at vlib/net/tcp.c.v:593
- 120: `err.code()`, receiver `IError`, declared at vlib/builtin/chan_option_result.v:38 (the interface method)
- 128: `conn.set_read_timeout(...)`, receiver `&net.TcpConn`, declared at vlib/net/tcp.c.v:348
- 129: `conn.set_write_timeout(...)`, receiver `&net.TcpConn`, declared at vlib/net/tcp.c.v:377
- 133: `s.close()`, receiver `http.Server`, declared at vlib/net/http/server.v:149

Line 116, `s.on_running(mut s)`, calls a function-pointer field (declared at server.v:64), not a method. Line 87 (`net.listen_tcp`) and line 105 (`new_handler_worker`) are free-function calls.

**7. Redirect-related errors in vlib/net/http**
- vlib/net/http/request.v:305: `error('http.request.do: maximum number of redirects reached (${max_redirects})')`
- vlib/net/http/request.v:329: `error('http.request.do: invalid URL in redirect "${redirect_url}"')`
- vlib/net/http/request.v:334: `error('http.request.do: invalid URL in redirect "${redirect_url}"')`

**8. Functions that call `net.dial_tcp` directly**
- `net.TCPDialer.dial`: vlib/net/tcp.c.v:17
- `redis.dial_connection`: vlib/db/redis/dial.c.v:8
- `websocket.Client.dial_socket`: vlib/net/websocket/io.v:77
- `socks.socks5_dial`: vlib/net/socks/socks5.v:20
- `smtp.Client.reconnect`: vlib/net/smtp/smtp.v:127
- `pop.dial`: vlib/net/pop/pop.v:54
- `openssl.SSLConn.dial`: vlib/net/openssl/ssl_connection.c.v:336
- `imap.Client.connect`: vlib/net/imap/imap.v:161
- `http.Transport.dial_h1_tcp`: vlib/net/http/transport.v:792
- `http.Request.http_do`: vlib/net/http/request.v:546
- `http.HttpProxy.connect_tcp`: vlib/net/http/http_proxy.v:138
- `ftp.FTP.connect`: vlib/net/ftp/ftp.v:113
- `ftp.new_dtp`: vlib/net/ftp/ftp.v:204
