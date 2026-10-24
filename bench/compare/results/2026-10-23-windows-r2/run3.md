**1. Calls of a `wait_for_read` method in vlib/net**
- vlib/net/unix/stream.c.v:142 — `c.wait_for_read()!` (unix.StreamConn)
- vlib/net/udp.c.v:125 — `c.wait_for_read()!` (UdpConn)
- vlib/net/udp.c.v:134 — `c.wait_for_read()!` (UdpConn)
- vlib/net/tcp.c.v:198 — `c.wait_for_read()!` (TcpConn)
- vlib/net/tcp.c.v:224 — `c.wait_for_read()!` (TcpConn)
- vlib/net/raw.c.v:126 — `c.wait_for_read()!` (RawConn)
- vlib/net/openssl/ssl_listener.c.v:216 — `conn.wait_for_read(timeout)!` (openssl.SSLConn)
- vlib/net/openssl/ssl_connection.c.v:132 — `s.wait_for_read(...)` (openssl.SSLConn)
- vlib/net/openssl/ssl_connection.c.v:374 — `s.wait_for_read(...)` (openssl.SSLConn)
- vlib/net/openssl/ssl_connection.c.v:396 — `s.wait_for_read(...)` (openssl.SSLConn)
- vlib/net/openssl/ssl_connection.c.v:468 — `s.wait_for_read(...)` (openssl.SSLConn)
- vlib/net/openssl/ssl_connection.c.v:538 — `s.wait_for_read(...)` (openssl.SSLConn)
- vlib/net/mbedtls/ssl_connection.c.v:445 — `conn.wait_for_read(...)` (mbedtls.SSLConn)
- vlib/net/mbedtls/ssl_connection.c.v:902 — `s.wait_for_read(...)` (mbedtls.SSLConn)
- vlib/net/mbedtls/ssl_connection.c.v:983 — `s.wait_for_read(...)` (mbedtls.SSLConn)

Left out: the free-function calls (unix/stream.c.v:218, 346; udp.c.v:192; tcp.c.v:383, 654; raw.c.v:191), the commented-out call at mbedtls/ssl_connection.c.v:889, and the test files.

**2. `os.open_append` and `fd`**
At this commit the premise doesn't hold: the File that `open_append` returns does not have `fd == 0` on Unix.
- vlib/os/os.c.v:1246 — `mut file := File{}` makes a temporary File whose `fd` is 0 (the default).
- vlib/os/os.c.v:1255-1257 — on Unix, the temporary is rebuilt with only `cfile: C.fopen(&char(cpath), c'ab')`, so its `fd` is still 0.
- vlib/os/os.c.v:1262-1266 — but the function returns a new `File{ cfile: file.cfile, fd: fileno(file.cfile), is_opened: true }`.
- vlib/os/os.c.v:371-378 — `fileno` calls `C.fileno(...)` on non-Windows (line 377), which gives the real descriptor.

The only File with `fd` 0 is the temporary at 1246/1255, and it is never returned. A 0 could only show up if `fileno` itself returned 0, meaning the descriptor really is 0.

**3. Routes from `http.get` to `net.dial_tcp`**
Every route starts with this prefix, P:
`http.get` → `fetch` (vlib/net/http/http.v:71) → `Request.do` (vlib/net/http/http.v:251) → `Request.method_and_url_to_response` (vlib/net/http/request.v:307)

Routes that hold in every build:
1. P → `Request.http_do` (vlib/net/http/request.v:426) → `net.dial_tcp` (vlib/net/http/request.v:546)
2. P → `Transport.round_trip` (vlib/net/http/request.v:402) → `Transport.dial_h1_tcp` (vlib/net/http/transport.v:757) → `net.dial_tcp` (vlib/net/http/transport.v:792)
3. P → `HttpProxy.http_do` (vlib/net/http/request.v:436) → `HttpProxy.dial` (vlib/net/http/http_proxy.v:173) → `HttpProxy.connect_tcp` (vlib/net/http/http_proxy.v:204) → `net.dial_tcp` (vlib/net/http/http_proxy.v:138)
4. P → `HttpProxy.http_do` (request.v:436) → `HttpProxy.dial` (http_proxy.v:173) → `HttpProxy.connect_tcp` (http_proxy.v:204) → `socks.socks5_dial` (vlib/net/http/http_proxy.v:144) → `net.dial_tcp` (vlib/net/socks/socks5.v:20)
5. P → `HttpProxy.http_do` (request.v:436) → `HttpProxy.ssl_dial` (vlib/net/http/http_proxy.v:160) → `HttpProxy.connect_tcp` (vlib/net/http/http_proxy.v:209) → `net.dial_tcp` (http_proxy.v:138)
6. P → `HttpProxy.http_do` (request.v:436) → `HttpProxy.ssl_dial` (http_proxy.v:160) → `HttpProxy.connect_tcp` (http_proxy.v:209) → `socks.socks5_dial` (http_proxy.v:144) → `net.dial_tcp` (socks5.v:20)
7. P → `HttpProxy.http_do` (request.v:436) → `HttpProxy.ssl_dial` (http_proxy.v:160) → `socks.socks5_ssl_dial` (vlib/net/http/http_proxy.v:224) → `socks.socks5_dial` (vlib/net/socks/socks5.v:35) → `net.dial_tcp` (socks5.v:20)

Routes that end in `ssl.SSLConn.dial`:
These reach `net.dial_tcp` only when `ssl.SSLConn` is `openssl.SSLConn`, which needs `-d use_openssl` (vlib/net/ssl/ssl_d_use_openssl.v:5). In that case `openssl.SSLConn.dial` calls `net.dial_tcp` at vlib/net/openssl/ssl_connection.c.v:336. In the default build `ssl.SSLConn` is `mbedtls.SSLConn` (vlib/net/ssl/ssl_notd_use_openssl.v:5), and its `dial` (vlib/net/mbedtls/ssl_connection.c.v:821) calls `C.mbedtls_net_connect` at line 845 instead. The last step of each route below is `openssl.SSLConn.dial` → `net.dial_tcp` (vlib/net/openssl/ssl_connection.c.v:336).

8. P → `Request.ssl_do` (vlib/net/http/request.v:415) → `net_ssl_do` (vlib/net/http/backend.c.v:15) → `SSLConn.dial` (vlib/net/http/backend.c.v:39) → `net.dial_tcp`
9. P → `Request.ssl_do` (request.v:415) → `vschannel_retry_handshake` (vlib/net/http/backend.c.v:12, Windows) → `net_ssl_do` (vlib/net/http/vschannel_handshake.v:32) → `SSLConn.dial` (backend.c.v:39) → `net.dial_tcp`
10. P → `Transport.round_trip` (request.v:402) → `tls_fresh_round_trip` (vlib/net/http/transport.v:755) → `tls_fresh_round_trip_ssl` (vlib/net/http/transport.v:810) → `SSLConn.dial` (vlib/net/http/transport.v:823) → `net.dial_tcp`
11. P → `Transport.round_trip` (request.v:402) → `tls_fresh_round_trip` (transport.v:755) → `vschannel_fresh_round_trip` (vlib/net/http/transport.v:808, Windows) → `tls_fresh_round_trip_ssl` (vlib/net/http/vschannel_pooled_transport_windows.c.v:270) → `SSLConn.dial` (transport.v:823) → `net.dial_tcp`
12. P → `round_trip` → `h2_round_trip` (vlib/net/http/transport.v:742) → `h2_dial_and_do` (vlib/net/http/transport_h2.v:83 / 104) → `h2_dial_probe` (vlib/net/http/transport_h2.v:265) → `h2_dial_probe_ssl` (vlib/net/http/transport_h2.v:156) → `SSLConn.dial` (vlib/net/http/transport_h2.v:170) → `net.dial_tcp`
13. Same as 12, but `h2_dial_probe` → `h2_dial_probe_vschannel` (vlib/net/http/transport_h2.v:154) → `h2_dial_probe_ssl` (vlib/net/http/vschannel_pooled_transport_windows.c.v:226) → `SSLConn.dial` (transport_h2.v:170) → `net.dial_tcp`
14. P → `round_trip` → `h2_round_trip` (transport.v:742) → `h2_dial_and_do` (transport_h2.v:83 / 104) → `h2_fallback_h1` (vlib/net/http/transport_h2.v:253 / 314) → `h2_use_h1_pool_or_dial` (vlib/net/http/transport_h2.v:198) → `tls_fresh_round_trip` (vlib/net/http/transport_h2.v:484 / 495) → `tls_fresh_round_trip_ssl` (transport.v:810) → `SSLConn.dial` (transport.v:823) → `net.dial_tcp`
15. Same as 14, but `tls_fresh_round_trip` → `vschannel_fresh_round_trip` (transport.v:808) → `tls_fresh_round_trip_ssl` (vschannel_pooled_transport_windows.c.v:270) → `SSLConn.dial` (transport.v:823) → `net.dial_tcp`
16. P → `round_trip` → `h2_round_trip` (transport.v:742) → `h2_dial_and_do` (transport_h2.v:83 / 104) → `h2_await_dial` (vlib/net/http/transport_h2.v:220 / 259) → `h2_fallback_h1` (vlib/net/http/transport_h2.v:469) → `h2_use_h1_pool_or_dial` (transport_h2.v:198) → `tls_fresh_round_trip` (transport_h2.v:484 / 495) → `tls_fresh_round_trip_ssl` (transport.v:810) → `SSLConn.dial` (transport.v:823) → `net.dial_tcp`
17. Same as 16, but through `vschannel_fresh_round_trip` (transport.v:808) → `tls_fresh_round_trip_ssl` (vschannel_pooled_transport_windows.c.v:270) → `SSLConn.dial` (transport.v:823) → `net.dial_tcp`

**4. Calls of `net.TcpConn.write_string`** (declared at vlib/net/tcp.c.v:322)
- vlib/net/http/http_proxy.v:176 — in `HttpProxy.http_do`
- vlib/net/pop/pop.v:138 — in `pop.Client.send_cmd`
- vlib/veb/veb.v:1103 — in `veb.send_string`
- vlib/veb/veb_livereload.v:144 — in `LivereloadHub.add`
- vlib/veb/veb_livereload.v:166 — in `LivereloadHub.send`
- vlib/veb/veb_livereload.v:289 — in `Context.handle_veb_livereload_events`

**5. Functions `os.cp_all` calls directly** (vlib/os/os.v:71)
- `real_path` — vlib/os/os.v:72, 73
- `exists` — vlib/os/os.v:74, 85, 95, 106
- `error` — vlib/os/os.v:75, 89, 99
- `is_dir` — vlib/os/os.v:78, 80, 98, 105
- `file_name` — vlib/os/os.v:79
- `join_path_single` — vlib/os/os.v:81, 103, 104
- `rm` — vlib/os/os.v:87
- `cp` — vlib/os/os.v:92
- `mkdir` — vlib/os/os.v:96, 107
- `ls` — vlib/os/os.v:101
- `cp_all` (recursive) — vlib/os/os.v:110
- `rmdir` — vlib/os/os.v:111

**6. Method calls in `http.Server.listen_and_serve`** (vlib/net/http/server.v:73)
- line 79: `s.listen_and_serve_tls()` — receiver `http.Server` — vlib/net/http/server_tls_notd_use_openssl.v:46 (default build) / vlib/net/http/server_tls_d_use_openssl.v:11 (`-d use_openssl`)
- line 92: `s.listener.addr()` — `net.TcpListener` — vlib/net/tcp.c.v:661
- line 96: `l.str()` — `net.Addr` — vlib/net/address.c.v:305
- line 98: `s.listener.set_accept_timeout(...)` — `net.TcpListener` — vlib/net/tcp.c.v:649
- line 119: `s.listener.accept_only()` — `net.TcpListener` — vlib/net/tcp.c.v:593
- line 120: `err.code()` — `IError` — vlib/builtin/chan_option_result.v:38 (interface method; `Error.code` is at line 67)
- line 128: `conn.set_read_timeout(...)` — `&net.TcpConn` — vlib/net/tcp.c.v:348
- line 129: `conn.set_write_timeout(...)` — `&net.TcpConn` — vlib/net/tcp.c.v:377
- line 133: `s.close()` — `http.Server` — vlib/net/http/server.v:149

Not methods: line 116 `s.on_running(mut s)` calls a function stored in a field. `net.listen_tcp` (87), `new_handler_worker` (105), `eprintln`, `println`, `flush_stdout` and `time.sleep` are free functions.

**7. Errors in vlib/net/http whose message mentions a redirect**
- vlib/net/http/request.v:305 — `error('http.request.do: maximum number of redirects reached (${max_redirects})')`
- vlib/net/http/request.v:329 — `error('http.request.do: invalid URL in redirect "${redirect_url}"')`
- vlib/net/http/request.v:334 — `error('http.request.do: invalid URL in redirect "${redirect_url}"')`

**8. Functions in vlib that call `net.dial_tcp` directly**
- `net.TCPDialer.dial` — vlib/net/tcp.c.v:17
- `http.Request.http_do` — vlib/net/http/request.v:546
- `http.Transport.dial_h1_tcp` — vlib/net/http/transport.v:792
- `http.HttpProxy.connect_tcp` — vlib/net/http/http_proxy.v:138
- `socks.socks5_dial` — vlib/net/socks/socks5.v:20
- `smtp.Client.reconnect` — vlib/net/smtp/smtp.v:127
- `imap.Client.connect` — vlib/net/imap/imap.v:161
- `pop.dial` — vlib/net/pop/pop.v:54
- `ftp.FTP.connect` — vlib/net/ftp/ftp.v:113
- `ftp.new_dtp` — vlib/net/ftp/ftp.v:204
- `websocket.Client.dial_socket` — vlib/net/websocket/io.v:77
- `openssl.SSLConn.dial` — vlib/net/openssl/ssl_connection.c.v:336
- `redis.dial_connection` — vlib/db/redis/dial.c.v:8
