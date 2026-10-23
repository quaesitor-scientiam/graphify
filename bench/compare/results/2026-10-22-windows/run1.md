**1. Calls of a `wait_for_read` method in vlib/net**
- vlib/net/tcp.c.v:198 — `c.wait_for_read()` (TcpConn)
- vlib/net/tcp.c.v:224 — `c.wait_for_read()` (TcpConn)
- vlib/net/udp.c.v:125 — `c.wait_for_read()` (UdpConn)
- vlib/net/udp.c.v:134 — `c.wait_for_read()` (UdpConn)
- vlib/net/raw.c.v:126 — `c.wait_for_read()` (RawConn)
- vlib/net/unix/stream.c.v:142 — `c.wait_for_read()` (unix.StreamConn)
- vlib/net/mbedtls/ssl_connection.c.v:443 — `conn.wait_for_read(...)` (mbedtls.SSLConn)
- vlib/net/mbedtls/ssl_connection.c.v:916 — `s.wait_for_read(...)` (mbedtls.SSLConn)
- vlib/net/mbedtls/ssl_connection.c.v:997 — `s.wait_for_read(...)` (mbedtls.SSLConn)
- vlib/net/openssl/ssl_listener.c.v:216 — `conn.wait_for_read(timeout)` (openssl.SSLConn)
- vlib/net/openssl/ssl_connection.c.v:132 — `s.wait_for_read(...)` (openssl.SSLConn)
- vlib/net/openssl/ssl_connection.c.v:374 — `s.wait_for_read(...)` (openssl.SSLConn)
- vlib/net/openssl/ssl_connection.c.v:396 — `s.wait_for_read(...)` (openssl.SSLConn)
- vlib/net/openssl/ssl_connection.c.v:468 — `s.wait_for_read(...)` (openssl.SSLConn)
- vlib/net/openssl/ssl_connection.c.v:538 — `s.wait_for_read(...)` (openssl.SSLConn)

Left out: vlib/net/mbedtls/ssl_connection.c.v:903 is commented out. The free-function calls at vlib/net/tcp.c.v:383 and 654, udp.c.v:192, raw.c.v:191, and unix/stream.c.v:218 and 346 don't count.

**2. `os.open_append` and `fd` on Unix**
In this tree the premise doesn't hold: the File that `open_append` returns has its `fd` set from the C stream, so it is not 0.
- vlib/os/file.c.v:21 — `File.fd int` has no default, so a bare `File{}` has `fd == 0`.
- vlib/os/os.c.v:1246 — `mut file := File{}` (fd is 0).
- vlib/os/os.c.v:1255-1257 — on Unix, `file = File{ cfile: C.fopen(&char(cpath), c'ab') }` sets only `cfile`, so this temporary File still has `fd == 0`.
- vlib/os/os.c.v:1262-1266 — but the function returns a new `File{ cfile: file.cfile, fd: fileno(file.cfile), is_opened: true }`. Line 1264 sets `fd` from `fileno`.
- vlib/os/os.c.v:371-379 — `fileno` calls `C.fileno(&C.FILE(cfile))` on Unix (line 377), which returns the real descriptor.

So only the temporary `file` (1246, 1255-1257) has `fd == 0`. A returned File would have `fd == 0` only if an older version returned `file` directly without line 1264.

**3. Routes from `http.get` to `net.dial_tcp`**
Every route starts with the same prefix:
get (vlib/net/http/http.v:70) → fetch, called at http.v:71 → Request.do, called at http.v:251 → method_and_url_to_response, called at request.v:295.

From method_and_url_to_response (vlib/net/http/request.v:366) the routes continue:
1. → Request.http_do, request.v:411 → net.dial_tcp, request.v:531
2. → Transport.round_trip, request.v:387 → dial_h1_tcp, transport.v:757 → net.dial_tcp, transport.v:791
3. → HttpProxy.http_do, request.v:421 → ssl_dial, http_proxy.v:160 → connect_tcp, http_proxy.v:209 → net.dial_tcp, http_proxy.v:138
4. → HttpProxy.http_do, request.v:421 → HttpProxy.dial, http_proxy.v:173 → connect_tcp, http_proxy.v:204 → net.dial_tcp, http_proxy.v:138
5. → HttpProxy.http_do, request.v:421 → ssl_dial, http_proxy.v:160 → connect_tcp, http_proxy.v:209 → socks.socks5_dial, http_proxy.v:144 → net.dial_tcp, socks/socks5.v:20
6. → HttpProxy.http_do, request.v:421 → ssl_dial, http_proxy.v:160 → socks.socks5_ssl_dial, http_proxy.v:224 → socks5_dial, socks5.v:35 → net.dial_tcp, socks5.v:20
7. → HttpProxy.http_do, request.v:421 → HttpProxy.dial, http_proxy.v:173 → connect_tcp, http_proxy.v:204 → socks5_dial, http_proxy.v:144 → net.dial_tcp, socks5.v:20
8. → ssl_do, request.v:400 → net_ssl_do, backend.c.v:15 → openssl SSLConn.dial, backend.c.v:39 → net.dial_tcp, openssl/ssl_connection.c.v:336
9. → round_trip, request.v:387 → tls_fresh_round_trip, transport.v:755 → tls_fresh_round_trip_ssl, transport.v:809 → SSLConn.dial, transport.v:822 → net.dial_tcp, ssl_connection.c.v:336
10. → ssl_do, request.v:400 → vschannel_retry_handshake, backend.c.v:12 → net_ssl_do, vschannel_handshake.v:32 → SSLConn.dial, backend.c.v:39 → net.dial_tcp, ssl_connection.c.v:336
11. → round_trip, request.v:387 → tls_fresh_round_trip, transport.v:755 → vschannel_fresh_round_trip, transport.v:807 → tls_fresh_round_trip_ssl, vschannel_pooled_transport_windows.c.v:270 → SSLConn.dial, transport.v:822 → net.dial_tcp, ssl_connection.c.v:336
12. → round_trip, request.v:387 → h2_round_trip, transport.v:742 → h2_dial_and_do, transport_h2.v:83/104 → h2_dial_probe, transport_h2.v:265 → h2_dial_probe_ssl, transport_h2.v:156 → SSLConn.dial, transport_h2.v:170 → net.dial_tcp, ssl_connection.c.v:336
13. → round_trip, request.v:387 → h2_round_trip, transport.v:742 → h2_dial_and_do, transport_h2.v:83/104 → h2_dial_probe, transport_h2.v:265 → h2_dial_probe_vschannel, transport_h2.v:154 → h2_dial_probe_ssl, vschannel_pooled_transport_windows.c.v:226 → SSLConn.dial, transport_h2.v:170 → net.dial_tcp, ssl_connection.c.v:336
14. → round_trip, request.v:387 → h2_round_trip, transport.v:742 → h2_dial_and_do, transport_h2.v:83/104 → h2_fallback_h1, transport_h2.v:253/314 → h2_use_h1_pool_or_dial, transport_h2.v:198 → tls_fresh_round_trip, transport_h2.v:484/495 → tls_fresh_round_trip_ssl, transport.v:809 → SSLConn.dial, transport.v:822 → net.dial_tcp, ssl_connection.c.v:336
15. Same as 14, but h2_dial_and_do → h2_await_dial, transport_h2.v:220/259 → h2_fallback_h1, transport_h2.v:469 → … (rest as 14)
16. Same as 14, but tls_fresh_round_trip → vschannel_fresh_round_trip, transport.v:807 → tls_fresh_round_trip_ssl, vschannel_pooled_transport_windows.c.v:270 → SSLConn.dial, transport.v:822 → net.dial_tcp, ssl_connection.c.v:336
17. Same as 15, with the vschannel_fresh_round_trip step from 16.

Routes 1-7 are in the default build. Routes 8-17 need `-d use_openssl`, because the default mbedtls `SSLConn.dial` (vlib/net/mbedtls/ssl_connection.c.v:827) connects with `mbedtls_net_connect` and never calls `net.dial_tcp`. Routes 10, 11, 13, 16 and 17 also need Windows without `no_vschannel`.

**4. Calls of `net.TcpConn.write_string` in vlib**
- vlib/net/http/http_proxy.v:176 — in `HttpProxy.http_do` (`client` comes from `pr.dial`, which returns `&net.TcpConn`)
- vlib/net/pop/pop.v:138 — in `pop.Client.send_cmd` (`c.conn` is `&net.TcpConn`)
- vlib/veb/veb.v:1103 — in `veb.send_string(mut conn net.TcpConn, ...)`
- vlib/veb/veb_livereload.v:144 — in `LivereloadHub.add`
- vlib/veb/veb_livereload.v:166 — in `LivereloadHub.send`
- vlib/veb/veb_livereload.v:289 — in `veb.Context.handle_veb_livereload_events` (`ctx.conn` is `&net.TcpConn`)

**5. Functions `os.cp_all` calls directly** (vlib/os/os.v:71-115)
- real_path — lines 72, 73
- exists — 74, 85, 95, 106
- error (builtin) — 75, 89, 99
- is_dir — 78, 80, 98, 105
- file_name — 79
- join_path_single — 81, 103, 104
- rm — 87
- cp — 92
- mkdir — 96, 107
- ls — 101
- cp_all (recursive) — 110
- rmdir — 111

**6. Method calls in `http.Server.listen_and_serve`** (vlib/net/http/server.v:73-135)
- 79 `s.listen_and_serve_tls()` — receiver `http.Server` → vlib/net/http/server_tls_notd_use_openssl.v:46 (default build), or vlib/net/http/server_tls_d_use_openssl.v:11 with `-d use_openssl`
- 92 `s.listener.addr()` — receiver `net.TcpListener` → vlib/net/tcp.c.v:661
- 96 `l.str()` — receiver `net.Addr` → vlib/net/address.c.v:305
- 98 `s.listener.set_accept_timeout(...)` — receiver `net.TcpListener` → vlib/net/tcp.c.v:649
- 116 `s.on_running(mut s)` — a call through the fn-typed field `on_running` of `http.Server`, declared at vlib/net/http/server.v:64 (not a real method)
- 119 `s.listener.accept_only()` — receiver `net.TcpListener` → vlib/net/tcp.c.v:593
- 120 `err.code()` — receiver `IError` → vlib/builtin/chan_option_result.v:38
- 128 `conn.set_read_timeout(...)` — receiver `&net.TcpConn` → vlib/net/tcp.c.v:348
- 129 `conn.set_write_timeout(...)` — receiver `&net.TcpConn` → vlib/net/tcp.c.v:377
- 133 `s.close()` — receiver `http.Server` → vlib/net/http/server.v:149

**7. Errors in vlib/net/http whose message mentions a redirect**
- vlib/net/http/request.v:293 — `error('http.request.do: maximum number of redirects reached (${max_redirects})')`
- vlib/net/http/request.v:314 — `error('http.request.do: invalid URL in redirect "${redirect_url}"')`
- vlib/net/http/request.v:319 — `error('http.request.do: invalid URL in redirect "${redirect_url}"')`

**8. Functions in vlib that call `net.dial_tcp` directly**
- `net.TCPDialer.dial` — vlib/net/tcp.c.v:17
- `redis.dial_connection` — vlib/db/redis/dial.c.v:8
- `ftp.FTP.connect` — vlib/net/ftp/ftp.v:113
- `ftp.FTP.new_dtp` — vlib/net/ftp/ftp.v:204
- `http.HttpProxy.connect_tcp` — vlib/net/http/http_proxy.v:138
- `http.Request.http_do` — vlib/net/http/request.v:531
- `http.Transport.dial_h1_tcp` — vlib/net/http/transport.v:791
- `imap.Client.connect` — vlib/net/imap/imap.v:161
- `openssl.SSLConn.dial` — vlib/net/openssl/ssl_connection.c.v:336
- `pop.dial` — vlib/net/pop/pop.v:54
- `smtp.Client.reconnect` — vlib/net/smtp/smtp.v:127
- `socks.socks5_dial` — vlib/net/socks/socks5.v:20
- `websocket.Client.dial_socket` — vlib/net/websocket/io.v:77
