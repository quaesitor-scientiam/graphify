**1. Calls of a `wait_for_read` method in vlib/net** (13 calls)
- vlib/net/tcp.c.v:198 — `c.wait_for_read()!` (TcpConn, in `TcpConn.read_ptr`)
- vlib/net/tcp.c.v:224 — `c.wait_for_read()!` (TcpConn, in `TcpConn.read_ptr`)
- vlib/net/udp.c.v:125 — `c.wait_for_read()!` (UdpConn)
- vlib/net/udp.c.v:134 — `c.wait_for_read()!` (UdpConn)
- vlib/net/raw.c.v:126 — `c.wait_for_read()!` (RawConn)
- vlib/net/unix/stream.c.v:142 — `c.wait_for_read()!` (unix.StreamConn)
- vlib/net/openssl/ssl_connection.c.v:132 — `s.wait_for_read(...)` (openssl.SSLConn)
- vlib/net/openssl/ssl_connection.c.v:374 (openssl.SSLConn)
- vlib/net/openssl/ssl_connection.c.v:396 (openssl.SSLConn)
- vlib/net/openssl/ssl_connection.c.v:468 (openssl.SSLConn)
- vlib/net/openssl/ssl_connection.c.v:538 (openssl.SSLConn)
- vlib/net/openssl/ssl_listener.c.v:216 — `conn.wait_for_read(timeout)!` (openssl.SSLConn)
- vlib/net/mbedtls/ssl_connection.c.v:443 — `conn.wait_for_read(...)` (mbedtls.SSLConn)
- vlib/net/mbedtls/ssl_connection.c.v:916 (mbedtls.SSLConn)
- vlib/net/mbedtls/ssl_connection.c.v:997 (mbedtls.SSLConn)

That is 15 lines in all. Left out: vlib/net/mbedtls/ssl_connection.c.v:903, which is commented out. Also left out are the free-function calls at tcp.c.v:383 and 654, udp.c.v:192, raw.c.v:191, and unix/stream.c.v:218 and 346, plus the calls in test files.

**2. `os.open_append` and `fd`**
At this commit the premise doesn't hold: the File that `open_append` returns does get its `fd` set on Unix.
- vlib/os/os.c.v:1245–1267 is `open_append`.
- On Unix (the `$else` branch, vlib/os/os.c.v:1254–1258) it builds a temporary `File{ cfile: C.fopen(&char(cpath), c'ab') }`. Only `cfile` is set there, so this temporary's `fd` keeps its default of 0. The field is `fd int` at vlib/os/file.c.v:21 and has no default value.
- That temporary is not what gets returned. vlib/os/os.c.v:1263–1267 returns a new `File{ cfile: file.cfile, fd: fileno(file.cfile), is_opened: true }`. Line 1265 sets `fd` from `fileno`.
- `fileno` (vlib/os/os.c.v:371–379) calls `C.fileno(&C.FILE(cfile))` on Unix, at line 377. That gives the real descriptor.

So `fd` is 0 only in the intermediate `file` value at lines 1255–1257. The returned File's `fd` is 0 only if the stream really is descriptor 0, which happens when stdin was closed beforehand.

**3. Routes from `http.get` to `net.dial_tcp`** (17 routes; 7 in the default build)

Every route starts with the same four steps:
- `get` (vlib/net/http/http.v:70) calls `fetch` at http.v:71.
- `fetch` (http.v:241) calls `Request.do` at http.v:251.
- `do` (vlib/net/http/request.v:281) calls `method_and_url_to_response` at request.v:295.
- `method_and_url_to_response` is at request.v:366.

The rest of each route, starting from `method_and_url_to_response`:
1. `http_do` at request.v:411. Then `http_do` (request.v:528) calls `dial_tcp` at request.v:531.
2. `Transport.round_trip` at request.v:387. Then `round_trip` (vlib/net/http/transport.v:708) calls `dial_h1_tcp` at transport.v:757. Then `dial_h1_tcp` (transport.v:790) calls `dial_tcp` at transport.v:791.
3. `HttpProxy.http_do` at request.v:421. Then `http_do` (vlib/net/http/http_proxy.v:150) calls `ssl_dial` at http_proxy.v:160. Then `ssl_dial` (http_proxy.v:207) calls `connect_tcp` at http_proxy.v:209. Then `connect_tcp` (http_proxy.v:136) calls `dial_tcp` at http_proxy.v:138.
4. `HttpProxy.http_do` at request.v:421. Then `http_do` calls `dial` at http_proxy.v:173. Then `dial` (http_proxy.v:203) calls `connect_tcp` at http_proxy.v:204. Then `connect_tcp` calls `dial_tcp` at http_proxy.v:138.
5. `HttpProxy.http_do` at request.v:421, then `ssl_dial` at http_proxy.v:160, then `connect_tcp` at http_proxy.v:209. Then `connect_tcp` calls `socks.socks5_dial` at http_proxy.v:144. Then `socks5_dial` (vlib/net/socks/socks5.v:19) calls `dial_tcp` at socks5.v:20.
6. `HttpProxy.http_do` at request.v:421, then `ssl_dial` at http_proxy.v:160. Then `ssl_dial` calls `socks5_ssl_dial` at http_proxy.v:224. Then `socks5_ssl_dial` (socks5.v:27) calls `socks5_dial` at socks5.v:35. Then `socks5_dial` calls `dial_tcp` at socks5.v:20.
7. `HttpProxy.http_do` at request.v:421, then `dial` at http_proxy.v:173, then `connect_tcp` at http_proxy.v:204, then `socks5_dial` at http_proxy.v:144, then `dial_tcp` at socks5.v:20.
8. `ssl_do` at request.v:400. Then `ssl_do` (vlib/net/http/backend.c.v:9) calls `net_ssl_do` at backend.c.v:15. Then `net_ssl_do` (backend.c.v:18) calls `openssl.dial` at backend.c.v:39. Then `dial` (vlib/net/openssl/ssl_connection.c.v:329) calls `dial_tcp` at ssl_connection.c.v:336. Needs `use_openssl`.
9. `round_trip` at request.v:387. Then `round_trip` calls `tls_fresh_round_trip` at transport.v:755. Then `tls_fresh_round_trip` (transport.v:805) calls `tls_fresh_round_trip_ssl` at transport.v:809. Then `tls_fresh_round_trip_ssl` (transport.v:812) calls `openssl.dial` at transport.v:822. Then `dial` calls `dial_tcp` at ssl_connection.c.v:336. Needs `use_openssl`.
10. `ssl_do` at request.v:400. Then `ssl_do` calls `vschannel_retry_handshake` at backend.c.v:12. Then `vschannel_retry_handshake` (vlib/net/http/vschannel_handshake.v:28) calls `net_ssl_do` at vschannel_handshake.v:32. Then `net_ssl_do` calls `openssl.dial` at backend.c.v:39, and `dial` calls `dial_tcp` at ssl_connection.c.v:336. Needs windows && !no_vschannel && use_openssl.
11. `round_trip` at request.v:387, then `tls_fresh_round_trip` at transport.v:755. Then `tls_fresh_round_trip` calls `vschannel_fresh_round_trip` at transport.v:807. Then `vschannel_fresh_round_trip` (vlib/net/http/vschannel_pooled_transport_windows.c.v:261) calls `tls_fresh_round_trip_ssl` at line 270 of that file. Then `tls_fresh_round_trip_ssl` calls `openssl.dial` at transport.v:822, and `dial` calls `dial_tcp` at ssl_connection.c.v:336. Needs windows && !no_vschannel && use_openssl.
12. `round_trip` at request.v:387. Then `round_trip` calls `h2_round_trip` at transport.v:742. Then `h2_round_trip` (vlib/net/http/transport_h2.v:52) calls `h2_dial_and_do` at transport_h2.v:83 and 104. Then `h2_dial_and_do` (transport_h2.v:216) calls `h2_dial_probe` at transport_h2.v:265. Then `h2_dial_probe` (transport_h2.v:152) calls `h2_dial_probe_ssl` at transport_h2.v:156. Then `h2_dial_probe_ssl` (transport_h2.v:161) calls `openssl.dial` at transport_h2.v:170, and `dial` calls `dial_tcp` at ssl_connection.c.v:336. Needs `use_openssl`.
13. Same as route 12 as far as `h2_dial_probe`. Then `h2_dial_probe` calls `h2_dial_probe_vschannel` at transport_h2.v:154. Then `h2_dial_probe_vschannel` (vschannel_pooled_transport_windows.c.v:206) calls `h2_dial_probe_ssl` at line 226 of that file. Then `h2_dial_probe_ssl` calls `openssl.dial` at transport_h2.v:170, and `dial` calls `dial_tcp` at ssl_connection.c.v:336. Needs windows && !no_vschannel && use_openssl.
14. `round_trip` at request.v:387, then `h2_round_trip` at transport.v:742, then `h2_dial_and_do` at transport_h2.v:83 and 104. Then `h2_dial_and_do` calls `h2_fallback_h1` at transport_h2.v:253 and 314. Then `h2_fallback_h1` (transport_h2.v:197) calls `h2_use_h1_pool_or_dial` at transport_h2.v:198. Then `h2_use_h1_pool_or_dial` (transport_h2.v:481) calls `tls_fresh_round_trip` at transport_h2.v:484 and 495. Then `tls_fresh_round_trip` calls `tls_fresh_round_trip_ssl` at transport.v:809, which calls `openssl.dial` at transport.v:822, which calls `dial_tcp` at ssl_connection.c.v:336. Needs `use_openssl`.
15. Same as route 14, except `h2_dial_and_do` first calls `h2_await_dial` at transport_h2.v:220 and 259. Then `h2_await_dial` (transport_h2.v:452) calls `h2_fallback_h1` at transport_h2.v:469. From there it goes the same way as route 14 to `dial_tcp` at ssl_connection.c.v:336. Needs `use_openssl`.
16. Same as route 14 as far as `tls_fresh_round_trip` (transport_h2.v:484 and 495). Then `tls_fresh_round_trip` calls `vschannel_fresh_round_trip` at transport.v:807. Then `vschannel_fresh_round_trip` calls `tls_fresh_round_trip_ssl` at vschannel_pooled_transport_windows.c.v:270. Then `tls_fresh_round_trip_ssl` calls `openssl.dial` at transport.v:822, and `dial` calls `dial_tcp` at ssl_connection.c.v:336. Needs windows && !no_vschannel && use_openssl.
17. Same as route 15 (going through `h2_await_dial` at transport_h2.v:220 and 259, then `h2_fallback_h1` at transport_h2.v:469, then `h2_use_h1_pool_or_dial` at 198, then `tls_fresh_round_trip` at 484 and 495). Then it continues as route 16: `vschannel_fresh_round_trip` at transport.v:807, `tls_fresh_round_trip_ssl` at vschannel_pooled_transport_windows.c.v:270, `openssl.dial` at transport.v:822, and `dial_tcp` at ssl_connection.c.v:336. Needs windows && !no_vschannel && use_openssl.

**4. Calls of `net.TcpConn.write_string`** (6 calls)
- vlib/net/http/http_proxy.v:176 — in `HttpProxy.http_do`
- vlib/net/pop/pop.v:138 — in `pop.Client.send_cmd`
- vlib/veb/veb.v:1103 — in `veb.send_string`
- vlib/veb/veb_livereload.v:144 — in `LivereloadHub.add`
- vlib/veb/veb_livereload.v:166 — in `LivereloadHub.send`
- vlib/veb/veb_livereload.v:289 — in `Context.handle_veb_livereload_events`

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
- `cp_all` (calls itself) — os.v:110
- `rmdir` — os.v:111

**6. Method calls in `http.Server.listen_and_serve`** (vlib/net/http/server.v:73)
- Line 79: `s.listen_and_serve_tls()`. The receiver is `http.Server`. It calls vlib/net/http/server_tls_notd_use_openssl.v:46 in the default build, or vlib/net/http/server_tls_d_use_openssl.v:11 with `-d use_openssl`.
- Line 92: `s.listener.addr()`. The receiver is `net.TcpListener`, declared at vlib/net/tcp.c.v:661.
- Line 96: `l.str()`. The receiver is `net.Addr`, declared at vlib/net/address.c.v:305.
- Line 98: `s.listener.set_accept_timeout(...)`. The receiver is `net.TcpListener`, declared at vlib/net/tcp.c.v:649.
- Line 116: `s.on_running(mut s)`. This calls a function stored in a field of `http.Server` (the field is at vlib/net/http/server.v:64), not a method.
- Line 119: `s.listener.accept_only()`. The receiver is `net.TcpListener`, declared at vlib/net/tcp.c.v:593.
- Line 120: `err.code()`. The receiver is `IError`, declared at vlib/builtin/chan_option_result.v:38 (an interface method).
- Line 128: `conn.set_read_timeout(...)`. The receiver is `net.TcpConn`, declared at vlib/net/tcp.c.v:348.
- Line 129: `conn.set_write_timeout(...)`. The receiver is `net.TcpConn`, declared at vlib/net/tcp.c.v:377.
- Line 133: `s.close()`. The receiver is `http.Server`, declared at vlib/net/http/server.v:149.

**7. Errors in vlib/net/http whose message mentions a redirect** (3)
- vlib/net/http/request.v:293 — `error('http.request.do: maximum number of redirects reached (${max_redirects})')`
- vlib/net/http/request.v:314 — `error('http.request.do: invalid URL in redirect "${redirect_url}"')`
- vlib/net/http/request.v:319 — `error('http.request.do: invalid URL in redirect "${redirect_url}"')`

**8. Functions that call `net.dial_tcp` directly** (14 functions, 15 calls)
- `net.TCPDialer.dial` — vlib/net/tcp.c.v:17
- `openssl.SSLConn.dial` — vlib/net/openssl/ssl_connection.c.v:336
- `socks.socks5_dial` — vlib/net/socks/socks5.v:20
- `imap.Client.connect` — vlib/net/imap/imap.v:161
- `smtp.Client.reconnect` — vlib/net/smtp/smtp.v:127
- `pop.dial` — vlib/net/pop/pop.v:54
- `ftp.FTP.connect` — vlib/net/ftp/ftp.v:113
- `ftp.FTP.new_dtp` — vlib/net/ftp/ftp.v:204
- `redis.dial_connection` — vlib/db/redis/dial.c.v:8
- `websocket.Client.dial_socket` — vlib/net/websocket/io.v:77
- `http.HttpProxy.connect_tcp` — vlib/net/http/http_proxy.v:138
- `http.Transport.dial_h1_tcp` — vlib/net/http/transport.v:791
- `http.Request.http_do` — vlib/net/http/request.v:531