1. **`wait_for_read` method calls in vlib/net** (15)
- vlib/net/raw.c.v:126 — `RawConn`
- vlib/net/tcp.c.v:198 — `TcpConn`
- vlib/net/tcp.c.v:224 — `TcpConn`
- vlib/net/udp.c.v:125 — `UdpConn`
- vlib/net/udp.c.v:134 — `UdpConn`
- vlib/net/unix/stream.c.v:142 — `unix.StreamConn`
- vlib/net/mbedtls/ssl_connection.c.v:443 — `mbedtls.SSLConn`
- vlib/net/mbedtls/ssl_connection.c.v:916 — `mbedtls.SSLConn`
- vlib/net/mbedtls/ssl_connection.c.v:997 — `mbedtls.SSLConn`
- vlib/net/openssl/ssl_connection.c.v:132 — `openssl.SSLConn`
- vlib/net/openssl/ssl_connection.c.v:374 — `openssl.SSLConn`
- vlib/net/openssl/ssl_connection.c.v:396 — `openssl.SSLConn`
- vlib/net/openssl/ssl_connection.c.v:468 — `openssl.SSLConn`
- vlib/net/openssl/ssl_connection.c.v:538 — `openssl.SSLConn`
- vlib/net/openssl/ssl_listener.c.v:216 — `openssl.SSLConn`

Left out: vlib/net/mbedtls/ssl_connection.c.v:903 is commented out. The free-function calls are at raw.c.v:191, tcp.c.v:383, tcp.c.v:654, udp.c.v:192, unix/stream.c.v:218 and unix/stream.c.v:346.

2. **`os.open_append` and `fd`**
At this commit the premise is false: `open_append` does not return `fd == 0` on Unix.
- On Unix it opens the file with `C.fopen(&char(cpath), c'ab')` (vlib/os/os.c.v:1255-1257).
- It then returns a new `File` with `fd: fileno(file.cfile)` (vlib/os/os.c.v:1262-1266).
- `fileno` returns `C.fileno(...)`, the real descriptor (vlib/os/os.c.v:371-378).

`fd` would only be 0 if that field were left out of the returned struct literal. A `File`'s `fd int` field (vlib/os/file.c.v:21) defaults to 0, and `open_append` first builds a `File` with only `cfile` set (os.c.v:1246, 1255-1257). Earlier versions returned it that way, which is where the 0 came from. The regression test vlib/os/os_fd_test.v:102-111 ("os.open_append must carry the descriptor, not the zero default") checks this.

3. **Routes from `http.get` to `net.dial_tcp`**
All six routes share this start:
- `http.get` → `fetch` (vlib/net/http/http.v:71)
- `fetch` → `Request.do` (http.v:251)
- `Request.do` → `Request.method_and_url_to_response` (vlib/net/http/request.v:295)

From there:
- **Route A:** `method_and_url_to_response` → `Transport.round_trip` (request.v:387) → `Transport.dial_h1_tcp` (vlib/net/http/transport.v:757) → `net.dial_tcp` (transport.v:791)
- **Route B:** `method_and_url_to_response` → `Request.http_do` (request.v:411) → `net.dial_tcp` (request.v:531)
- **Route C:** `method_and_url_to_response` → `HttpProxy.http_do` (request.v:421) → `HttpProxy.dial` (vlib/net/http/http_proxy.v:173) → `HttpProxy.connect_tcp` (http_proxy.v:204) → `net.dial_tcp` (http_proxy.v:138)
- **Route D:** same as C down to `HttpProxy.connect_tcp` (http_proxy.v:204) → `socks.socks5_dial` (http_proxy.v:144) → `net.dial_tcp` (vlib/net/socks/socks5.v:20)
- **Route E:** `method_and_url_to_response` → `HttpProxy.http_do` (request.v:421) → `HttpProxy.ssl_dial` (http_proxy.v:160) → `HttpProxy.connect_tcp` (http_proxy.v:209) → `net.dial_tcp` (http_proxy.v:138)
- **Route F:** same as E down to `HttpProxy.connect_tcp` (http_proxy.v:209) → `socks.socks5_dial` (http_proxy.v:144) → `net.dial_tcp` (socks5.v:20)

With `-d use_openssl` there are more routes: `ssl.SSLConn` becomes `openssl.SSLConn` (vlib/net/ssl/ssl_d_use_openssl.v:5), and `openssl.SSLConn.dial` calls `net.dial_tcp` (vlib/net/openssl/ssl_connection.c.v:336). That adds every route to an `ssl_conn.dial` call:
- vlib/net/http/backend.c.v:39, inside `net_ssl_do`, reached through `Request.ssl_do` (request.v:400)
- transport.v:822, inside `tls_fresh_round_trip_ssl`, reached through `tls_fresh_round_trip` (transport.v:755, 809)
- vlib/net/http/transport_h2.v:170, inside `h2_dial_probe_ssl`, on the h2 paths that start from `round_trip` (transport.v:742)

In the default mbedtls build, `SSLConn.dial` connects with `mbedtls_net_connect` (vlib/net/mbedtls/ssl_connection.c.v:859) and never calls `net.dial_tcp`.

4. **Calls of `net.TcpConn.write_string`** (6)
- vlib/veb/veb.v:1103 — in `send_string`
- vlib/veb/veb_livereload.v:144 — in `LivereloadHub.add`
- vlib/veb/veb_livereload.v:166 — in `LivereloadHub.send`
- vlib/veb/veb_livereload.v:289 — in `Context.handle_veb_livereload_events`
- vlib/net/pop/pop.v:138 — in `pop.Client.send_cmd`
- vlib/net/http/http_proxy.v:176 — in `HttpProxy.http_do`

5. **Functions `os.cp_all` calls directly** (vlib/os/os.v)
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

6. **Method calls in `http.Server.listen_and_serve`** (vlib/net/http/server.v)
- 79: `s.listen_and_serve_tls()` — `http.Server` → vlib/net/http/server_tls_notd_use_openssl.v:46 (default build), or vlib/net/http/server_tls_d_use_openssl.v:11 with `-d use_openssl`
- 92: `s.listener.addr()` — `net.TcpListener` → vlib/net/tcp.c.v:661
- 96: `l.str()` — `net.Addr` → vlib/net/address.c.v:305
- 98: `s.listener.set_accept_timeout(...)` — `net.TcpListener` → vlib/net/tcp.c.v:649
- 119: `s.listener.accept_only()` — `net.TcpListener` → vlib/net/tcp.c.v:593
- 120: `err.code()` — `IError` → vlib/builtin/chan_option_result.v:38 (interface method; implementations at :67 and :92)
- 128: `conn.set_read_timeout(...)` — `net.TcpConn` → vlib/net/tcp.c.v:348
- 129: `conn.set_write_timeout(...)` — `net.TcpConn` → vlib/net/tcp.c.v:377
- 133: `s.close()` — `http.Server` → vlib/net/http/server.v:149

Line 116, `s.on_running(mut s)`, calls a function stored in a field, not a method. Line 87 (`net.listen_tcp`) and line 105 (`new_handler_worker`) are free-function calls.

7. **Errors in vlib/net/http whose message mentions a redirect** (3)
- vlib/net/http/request.v:293 — `return error('http.request.do: maximum number of redirects reached (${max_redirects})')`
- vlib/net/http/request.v:314 — `return error('http.request.do: invalid URL in redirect "${redirect_url}"')`
- vlib/net/http/request.v:319 — `return error('http.request.do: invalid URL in redirect "${redirect_url}"')`

8. **Functions in vlib that call `net.dial_tcp` directly** (14 calls)
- vlib/net/tcp.c.v:17 — `net.TCPDialer.dial`
- vlib/net/openssl/ssl_connection.c.v:336 — `openssl.SSLConn.dial`
- vlib/net/socks/socks5.v:20 — `socks.socks5_dial`
- vlib/net/smtp/smtp.v:127 — `smtp.Client.reconnect`
- vlib/net/http/http_proxy.v:138 — `http.HttpProxy.connect_tcp`
- vlib/net/http/transport.v:791 — `http.Transport.dial_h1_tcp`
- vlib/net/http/request.v:531 — `http.Request.http_do`
- vlib/net/imap/imap.v:161 — `imap.Client.connect`
- vlib/net/pop/pop.v:54 — `pop.dial`
- vlib/net/ftp/ftp.v:113 — `ftp.FTP.connect`
- vlib/net/ftp/ftp.v:204 — `ftp.new_dtp`
- vlib/net/websocket/io.v:77 — `websocket.Client.dial_socket`
- vlib/db/redis/dial.c.v:8 — `redis.dial_connection`