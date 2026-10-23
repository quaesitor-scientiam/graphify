I've answered all eight questions from the source, with no test files counted.

- **Q2:** the premise doesn't hold at this commit. `open_append` sets `fd` from `fileno`, and a vlib test checks for exactly that.
- **Q3:** 11 of the 17 routes go through `SSLConn.dial`. They reach `net.dial_tcp` only when V is built with `-d use_openssl`. The default mbedtls backend connects by another path (details in Q3).

**1. Calls of a `wait_for_read` method in vlib/net**
- net/unix/stream.c.v:142 — `c.wait_for_read()!` (unix `StreamConn`)
- net/udp.c.v:125 — `c.wait_for_read()!` (`UdpConn`)
- net/udp.c.v:134 — `c.wait_for_read()!` (`UdpConn`)
- net/tcp.c.v:198 — `c.wait_for_read()!` (`TcpConn`)
- net/tcp.c.v:224 — `c.wait_for_read()!` (`TcpConn`)
- net/raw.c.v:126 — `c.wait_for_read()!` (`RawConn`)
- net/openssl/ssl_listener.c.v:216 — `conn.wait_for_read(timeout)!` (openssl `SSLConn`)
- net/openssl/ssl_connection.c.v:132 — `s.wait_for_read(...)` (openssl `SSLConn`)
- net/openssl/ssl_connection.c.v:374 — `s.wait_for_read(...)` (openssl `SSLConn`)
- net/openssl/ssl_connection.c.v:396 — `s.wait_for_read(...)` (openssl `SSLConn`)
- net/openssl/ssl_connection.c.v:468 — `s.wait_for_read(...)` (openssl `SSLConn`)
- net/openssl/ssl_connection.c.v:538 — `s.wait_for_read(...)` (openssl `SSLConn`)
- net/mbedtls/ssl_connection.c.v:443 — `conn.wait_for_read(...)` (mbedtls `SSLConn`, in `do_handshake_loop`)
- net/mbedtls/ssl_connection.c.v:916 — `s.wait_for_read(...)` (mbedtls `SSLConn`, in `socket_read_into_ptr`)
- net/mbedtls/ssl_connection.c.v:997 — `s.wait_for_read(...)` (mbedtls `SSLConn`, in `write_ptr`)

Left out:
- net/mbedtls/ssl_connection.c.v:903 is commented out.
- These are calls of the free function, not the method: net/unix/stream.c.v:218 and :346, net/udp.c.v:192, net/tcp.c.v:383 and :654, net/raw.c.v:191.

**2. `os.open_append` and `fd` on Unix**
At this commit it doesn't return `fd == 0`; the premise is out of date.
- vlib/os/os.c.v:1245 defines `open_append`. On Unix it opens the file with `C.fopen(path, 'ab')` at os.c.v:1255-1257.
- The File it returns sets `fd: fileno(file.cfile)` at os.c.v:1262-1266, line 1264 being the `fd` line.
- On Unix `fileno` is `C.fileno(&C.FILE(cfile))` (os.c.v:371-379, line 377), which gives the real descriptor.
- `fd` would only be 0 if the struct literal left it out. `File.fd` is a plain `int` with no default (os/file.c.v:17-24, line 21), so it would then be zero.
- That was the old bug. The regression test vlib/os/os_fd_test.v:102-111 (comment at line 110: "os.open_append must carry the descriptor, not the zero default") checks that it's fixed.
- For comparison, `open_file` sets `fd: fd` (file.c.v:107-111), and `open`/`create` use `fileno` (file.c.v:136, 148).

**3. Routes from `http.get` to `net.dial_tcp`**
All routes start with the same prefix, P:
`http.get` → `fetch` (net/http/http.v:71) → `Request.do` (http.v:251) → `Request.method_and_url_to_response` (net/http/request.v:295)

`SSLConn.dial` below is `net.openssl.SSLConn.dial` (net/openssl/ssl_connection.c.v:329). `net.ssl.SSLConn` is that type only with `-d use_openssl` (net/ssl/ssl_d_use_openssl.v:5). The default mbedtls `SSLConn.dial` (net/mbedtls/ssl_connection.c.v:827) uses `mbedtls_net_connect` and never calls `dial_tcp`. The vschannel steps exist only on Windows.

1. P → `Request.http_do` (request.v:411) → `net.dial_tcp` (request.v:531)
2. P → `Transport.round_trip` (request.v:387) → `Transport.dial_h1_tcp` (net/http/transport.v:757) → `net.dial_tcp` (transport.v:791)
3. P → `round_trip` (request.v:387) → `tls_fresh_round_trip` (transport.v:755) → `tls_fresh_round_trip_ssl` (transport.v:809) → `SSLConn.dial` (transport.v:822) → `net.dial_tcp` (openssl/ssl_connection.c.v:336)
4. P → `round_trip` → `tls_fresh_round_trip` (transport.v:755) → `vschannel_fresh_round_trip` (transport.v:807) → `tls_fresh_round_trip_ssl` (net/http/vschannel_pooled_transport_windows.c.v:270) → `SSLConn.dial` (transport.v:822) → `net.dial_tcp` (ssl_connection.c.v:336)
5. P → `round_trip` → `h2_round_trip` (transport.v:742) → `h2_dial_and_do` (net/http/transport_h2.v:83 / :104) → `h2_dial_probe` (transport_h2.v:265) → `h2_dial_probe_ssl` (transport_h2.v:156) → `SSLConn.dial` (transport_h2.v:170) → `net.dial_tcp` (ssl_connection.c.v:336)
6. P → `round_trip` → `h2_round_trip` (742) → `h2_dial_and_do` (83/104) → `h2_dial_probe` (265) → `h2_dial_probe_vschannel` (transport_h2.v:154) → `h2_dial_probe_ssl` (vschannel_pooled_transport_windows.c.v:226) → `SSLConn.dial` (transport_h2.v:170) → `net.dial_tcp` (336)
7. P → `round_trip` → `h2_round_trip` (742) → `h2_dial_and_do` (83/104) → `h2_fallback_h1` (transport_h2.v:253 / :314) → `h2_use_h1_pool_or_dial` (transport_h2.v:198) → `tls_fresh_round_trip` (transport_h2.v:484 / :495) → `tls_fresh_round_trip_ssl` (transport.v:809) → `SSLConn.dial` (transport.v:822) → `net.dial_tcp` (336)
8. Same as route 7 up to `tls_fresh_round_trip` (484/495), then → `vschannel_fresh_round_trip` (transport.v:807) → `tls_fresh_round_trip_ssl` (vschannel_pooled_transport_windows.c.v:270) → `SSLConn.dial` (transport.v:822) → `net.dial_tcp` (336)
9. P → `round_trip` → `h2_round_trip` (742) → `h2_dial_and_do` (83/104) → `h2_await_dial` (transport_h2.v:220 / :259) → `h2_fallback_h1` (transport_h2.v:469) → `h2_use_h1_pool_or_dial` (198) → `tls_fresh_round_trip` (484/495) → `tls_fresh_round_trip_ssl` (transport.v:809) → `SSLConn.dial` (transport.v:822) → `net.dial_tcp` (336)
10. Same as route 9 up to `tls_fresh_round_trip` (484/495), then → `vschannel_fresh_round_trip` (transport.v:807) → `tls_fresh_round_trip_ssl` (vschannel_pooled_transport_windows.c.v:270) → `SSLConn.dial` (822) → `net.dial_tcp` (336)
11. P → `Request.ssl_do` (request.v:400) → `net_ssl_do` (net/http/backend.c.v:15) → `SSLConn.dial` (backend.c.v:39) → `net.dial_tcp` (336)
12. P → `ssl_do` (request.v:400) → `vschannel_retry_handshake` (backend.c.v:12) → `net_ssl_do` (net/http/vschannel_handshake.v:32) → `SSLConn.dial` (backend.c.v:39) → `net.dial_tcp` (336)
13. P → `HttpProxy.http_do` (request.v:421) → `HttpProxy.dial` (net/http/http_proxy.v:173) → `HttpProxy.connect_tcp` (http_proxy.v:204) → `net.dial_tcp` (http_proxy.v:138)
14. P → `HttpProxy.http_do` (421) → `HttpProxy.dial` (173) → `connect_tcp` (204) → `socks.socks5_dial` (http_proxy.v:144) → `net.dial_tcp` (net/socks/socks5.v:20)
15. P → `HttpProxy.http_do` (421) → `HttpProxy.ssl_dial` (http_proxy.v:160) → `connect_tcp` (http_proxy.v:209) → `net.dial_tcp` (http_proxy.v:138)
16. P → `HttpProxy.http_do` (421) → `ssl_dial` (160) → `connect_tcp` (209) → `socks.socks5_dial` (144) → `net.dial_tcp` (socks5.v:20)
17. P → `HttpProxy.http_do` (421) → `ssl_dial` (160) → `socks.socks5_ssl_dial` (http_proxy.v:224) → `socks5_dial` (socks5.v:35) → `net.dial_tcp` (socks5.v:20)

These lead nowhere near `dial_tcp`:
- `h3_round_trip` (transport.v:723) uses QUIC/UDP.
- `vschannel_ssl_do` (backend.c.v:11) uses SChannel.
- The scheme-handler call `h(config)` (http.v:246) is an indirect call, not a direct one.

**4. Calls of `net.TcpConn.write_string`** (declared at net/tcp.c.v:322)
- net/http/http_proxy.v:176 — `client.write_string(s)!`, in `HttpProxy.http_do`
- net/pop/pop.v:138 — `c.conn.write_string(wire)`, in `pop.Client.send_cmd`
- veb/veb.v:1103 — `conn.write_string(s)!`, in `veb.send_string`
- veb/veb_livereload.v:144 — `c.write_string(head)`, in `LivereloadHub.add`
- veb/veb_livereload.v:166 — `c.write_string(payload)`, in `LivereloadHub.send`
- veb/veb_livereload.v:289 — `conn.write_string(...)`, in `Context.handle_veb_livereload_events`

These are on `SSLConn`, not `TcpConn`: net/http/backend.c.v:125 and :147.

**5. Direct calls in `os.cp_all`** (vlib/os/os.v:71)
- `real_path` — os.v:72, 73
- `exists` — os.v:74, 85, 95, 106
- `error` — os.v:75, 89, 99
- `is_dir` — os.v:78, 80, 98, 105
- `file_name` — os.v:79
- `join_path_single` — os.v:81, 103, 104
- `rm` — os.v:87
- `cp` — os.v:92
- `mkdir` — os.v:96, 107
- `ls` — os.v:101
- `cp_all` (itself) — os.v:110
- `rmdir` — os.v:111

**6. Method calls in `http.Server.listen_and_serve`** (net/http/server.v:73)
- server.v:79 — `s.listen_and_serve_tls()`, receiver `http.Server`. It calls net/http/server_tls_notd_use_openssl.v:46 by default, or net/http/server_tls_d_use_openssl.v:11 with `-d use_openssl`.
- server.v:92 — `s.listener.addr()`, receiver `net.TcpListener`, calls net/tcp.c.v:661
- server.v:96 — `l.str()`, receiver `net.Addr`, calls net/address.c.v:305
- server.v:98 — `s.listener.set_accept_timeout(...)`, receiver `net.TcpListener`, calls net/tcp.c.v:649
- server.v:119 — `s.listener.accept_only()`, receiver `net.TcpListener`, calls net/tcp.c.v:593
- server.v:120 — `err.code()`, receiver `IError`, calls the interface method at builtin/chan_option_result.v:38
- server.v:128 — `conn.set_read_timeout(...)`, receiver `&net.TcpConn`, calls net/tcp.c.v:348
- server.v:129 — `conn.set_write_timeout(...)`, receiver `&net.TcpConn`, calls net/tcp.c.v:377
- server.v:133 — `s.close()`, receiver `http.Server`, calls net/http/server.v:149

`s.on_running(mut s)` at server.v:116 calls a function-typed field (`on_running`, server.v:64), so it isn't a method call.

**7. Errors in vlib/net/http whose message mentions a redirect**
- net/http/request.v:293 — `error('http.request.do: maximum number of redirects reached (${max_redirects})')`
- net/http/request.v:314 — `error('http.request.do: invalid URL in redirect "${redirect_url}"')`
- net/http/request.v:319 — `error('http.request.do: invalid URL in redirect "${redirect_url}"')`

**8. Functions in vlib that call `net.dial_tcp` directly**
- net/tcp.c.v:17 — `net.TCPDialer.dial`
- net/http/request.v:531 — `http.Request.http_do`
- net/http/transport.v:791 — `http.Transport.dial_h1_tcp`
- net/http/http_proxy.v:138 — `http.HttpProxy.connect_tcp`
- net/openssl/ssl_connection.c.v:336 — `openssl.SSLConn.dial`
- net/socks/socks5.v:20 — `socks.socks5_dial`
- net/websocket/io.v:77 — `websocket.Client.dial_socket`
- net/ftp/ftp.v:113 — `ftp.FTP.connect`
- net/ftp/ftp.v:204 — `ftp.new_dtp`
- net/smtp/smtp.v:127 — `smtp.Client.reconnect`
- net/pop/pop.v:54 — `pop.dial`
- net/imap/imap.v:161 — `imap.Client.connect`
- db/redis/dial.c.v:8 — `redis.dial_connection`
