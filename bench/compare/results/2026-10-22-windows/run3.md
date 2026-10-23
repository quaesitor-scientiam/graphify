All eight questions are answered below. All paths are relative to the V tree and test code is left out. Two answers need a caveat: Q2's premise doesn't hold at this commit, and Q3 adds TLS routes that only exist in builds made with `-d use_openssl`.

**1. `wait_for_read` method calls in vlib/net** (the free-function calls at raw.c.v:191, udp.c.v:192, tcp.c.v:383/654, unix/stream.c.v:218/346 are left out, as is the commented-out mbedtls line 903)
- vlib/net/raw.c.v:126 — `c.wait_for_read()` (RawConn)
- vlib/net/udp.c.v:125 — `c.wait_for_read()` (UdpConn)
- vlib/net/udp.c.v:134 — `c.wait_for_read()` (UdpConn)
- vlib/net/tcp.c.v:198 — `c.wait_for_read()` (TcpConn)
- vlib/net/tcp.c.v:224 — `c.wait_for_read()` (TcpConn)
- vlib/net/unix/stream.c.v:142 — `c.wait_for_read()` (StreamConn)
- vlib/net/openssl/ssl_listener.c.v:216 — `conn.wait_for_read(timeout)` (openssl SSLConn)
- vlib/net/openssl/ssl_connection.c.v:132, :374, :396, :468, :538 — `s.wait_for_read(...)` (openssl SSLConn)
- vlib/net/mbedtls/ssl_connection.c.v:443 — `conn.wait_for_read(...)` in `SSLConn.do_handshake_loop` (mbedtls SSLConn)
- vlib/net/mbedtls/ssl_connection.c.v:916, :997 — `s.wait_for_read(...)` (mbedtls SSLConn)

**2. `os.open_append` and `fd`**
At this commit the returned File's `fd` is not 0 on Unix.
- The Unix branch opens the file with `C.fopen(&char(cpath), c'ab')` at vlib/os/os.c.v:1253-1257.
- The intermediate `file := File{ cfile: ... }` sets only `cfile`, so its `fd` (field declared at vlib/os/file.c.v:21) is 0. That temporary is not what the function returns.
- The returned value is a new `File{ cfile: file.cfile, fd: fileno(file.cfile), is_opened: true }` (vlib/os/os.c.v:1262-1266, with `fd` at :1264).
- `os.fileno` calls `C.fileno(&C.FILE(cfile))` on non-Windows (vlib/os/os.c.v:371-378), so `fd` is the real descriptor.

A 0 `fd` would only come from code that read the intermediate `file` (os.c.v:1255-1257), or from an older version that built the File without `fd:`.

**3. Routes from `http.get` to `net.dial_tcp`**
Every route starts with the same prefix:
- `http.get` → `fetch` (vlib/net/http/http.v:71)
- `fetch` → `Request.do` (vlib/net/http/http.v:251)
- `Request.do` → `Request.method_and_url_to_response` (vlib/net/http/request.v:295)

From `method_and_url_to_response`, the routes are:
1. → `Transport.round_trip` (request.v:387) → `Transport.dial_h1_tcp` (transport.v:757) → `net.dial_tcp` (transport.v:791)
2. → `Request.http_do` (request.v:411) → `net.dial_tcp` (request.v:531)
3. → `HttpProxy.http_do` (request.v:421) → `HttpProxy.dial` (http_proxy.v:173) → `HttpProxy.connect_tcp` (http_proxy.v:204) → `net.dial_tcp` (http_proxy.v:138)
4. → `HttpProxy.http_do` (request.v:421) → `HttpProxy.dial` (http_proxy.v:173) → `HttpProxy.connect_tcp` (http_proxy.v:204) → `socks.socks5_dial` (http_proxy.v:144) → `net.dial_tcp` (vlib/net/socks/socks5.v:20)
5. → `HttpProxy.http_do` (request.v:421) → `HttpProxy.ssl_dial` (http_proxy.v:160) → `HttpProxy.connect_tcp` (http_proxy.v:209) → `net.dial_tcp` (http_proxy.v:138)
6. → `HttpProxy.http_do` (request.v:421) → `HttpProxy.ssl_dial` (http_proxy.v:160) → `HttpProxy.connect_tcp` (http_proxy.v:209) → `socks.socks5_dial` (http_proxy.v:144) → `net.dial_tcp` (socks5.v:20)
7. → `HttpProxy.http_do` (request.v:421) → `HttpProxy.ssl_dial` (http_proxy.v:160) → `socks.socks5_ssl_dial` (http_proxy.v:224) → `socks.socks5_dial` (socks5.v:35) → `net.dial_tcp` (socks5.v:20)

Only with `-d use_openssl`: there `ssl.SSLConn` is `openssl.SSLConn` (vlib/net/ssl/ssl_d_use_openssl.v:5). Its `dial` calls `net.dial_tcp` (vlib/net/openssl/ssl_connection.c.v:336), which adds TLS routes:
- `method_and_url_to_response` → `ssl_do` (request.v:400) → `net_ssl_do` (backend.c.v:15) → `SSLConn.dial` (backend.c.v:39) → `dial_tcp`
- `round_trip` → `tls_fresh_round_trip` (transport.v:755) → `tls_fresh_round_trip_ssl` (transport.v:809) → `SSLConn.dial` (transport.v:822) → `dial_tcp`
- `round_trip` → `h2_round_trip` (transport.v:742) → `h2_dial_and_do` (transport_h2.v:83/104) → `h2_dial_probe` (transport_h2.v:265) → `h2_dial_probe_ssl` (transport_h2.v:156) → `SSLConn.dial` (transport_h2.v:170) → `dial_tcp`
- `h2_dial_and_do` → `h2_fallback_h1` (transport_h2.v:253/314) → `h2_use_h1_pool_or_dial` (transport_h2.v:198) → `tls_fresh_round_trip` (transport_h2.v:484/495) → (as in the second route above) → `dial_tcp`
- `h2_dial_and_do` → `h2_await_dial` (transport_h2.v:220/259) → `h2_fallback_h1` (transport_h2.v:469) → … → `dial_tcp`

In the default mbedtls build, `SSLConn.dial` uses `mbedtls_net_connect` (vlib/net/mbedtls/ssl_connection.c.v:859) and does not reach `dial_tcp`.

**4. `net.TcpConn.write_string` calls** (declared at vlib/net/tcp.c.v:322)
- vlib/net/http/http_proxy.v:176 — in `HttpProxy.http_do` (`client` comes from `pr.dial`, a `&net.TcpConn`)
- vlib/net/pop/pop.v:138 — in `Client.send_cmd` (`c.conn &net.TcpConn`)
- vlib/veb/veb.v:1103 — in `send_string(mut conn net.TcpConn, ...)`
- vlib/veb/veb_livereload.v:144 — in `LivereloadHub.add`
- vlib/veb/veb_livereload.v:166 — in `LivereloadHub.send`
- vlib/veb/veb_livereload.v:289 — in `Context.handle_veb_livereload_events` (`ctx.conn &net.TcpConn`)

**5. Functions `os.cp_all` calls directly** (vlib/os/os.v:71)
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

**6. Method calls in `http.Server.listen_and_serve`** (vlib/net/http/server.v:73)
- :79 `s.listen_and_serve_tls()` — Server → vlib/net/http/server_tls_notd_use_openssl.v:46 (default build), or vlib/net/http/server_tls_d_use_openssl.v:11 with `-d use_openssl`
- :92 `s.listener.addr()` — net.TcpListener → vlib/net/tcp.c.v:661
- :96 `l.str()` — net.Addr → vlib/net/address.c.v:305
- :98 `s.listener.set_accept_timeout(...)` — net.TcpListener → vlib/net/tcp.c.v:649
- :119 `s.listener.accept_only()` — net.TcpListener → vlib/net/tcp.c.v:593
- :120 `err.code()` — IError (interface method, declared at vlib/builtin/chan_option_result.v:38)
- :128 `conn.set_read_timeout(...)` — net.TcpConn → vlib/net/tcp.c.v:348
- :129 `conn.set_write_timeout(...)` — net.TcpConn → vlib/net/tcp.c.v:377
- :133 `s.close()` — Server → vlib/net/http/server.v:149

Not methods: :116 `s.on_running(mut s)` calls a function-typed field, and :87 `net.listen_tcp` and :105 `new_handler_worker` are free functions.

**7. Errors in vlib/net/http that mention a redirect**
- vlib/net/http/request.v:293 — `'http.request.do: maximum number of redirects reached (${max_redirects})'`
- vlib/net/http/request.v:314 — `'http.request.do: invalid URL in redirect "${redirect_url}"'`
- vlib/net/http/request.v:319 — `'http.request.do: invalid URL in redirect "${redirect_url}"'`

**8. Functions in vlib that call `net.dial_tcp` directly**
- `net.TCPDialer.dial` — vlib/net/tcp.c.v:17
- `redis.dial_connection` — vlib/db/redis/dial.c.v:8
- `websocket.Client.dial_socket` — vlib/net/websocket/io.v:77
- `imap.Client.connect` — vlib/net/imap/imap.v:161
- `ftp.FTP.connect` — vlib/net/ftp/ftp.v:113
- `ftp.new_dtp` — vlib/net/ftp/ftp.v:204
- `socks.socks5_dial` — vlib/net/socks/socks5.v:20
- `smtp.Client.reconnect` — vlib/net/smtp/smtp.v:127
- `http.HttpProxy.connect_tcp` — vlib/net/http/http_proxy.v:138
- `pop.dial` — vlib/net/pop/pop.v:54
- `openssl.SSLConn.dial` — vlib/net/openssl/ssl_connection.c.v:336
- `http.Request.http_do` — vlib/net/http/request.v:531
- `http.Transport.dial_h1_tcp` — vlib/net/http/transport.v:791
