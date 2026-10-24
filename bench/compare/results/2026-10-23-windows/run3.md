**1. Calls of a `wait_for_read` method in vlib/net**

There are 16 calls. The commented-out call at `vlib/net/mbedtls/ssl_connection.c.v:889` is left out.
- `vlib/net/raw.c.v:126`: `c.wait_for_read()`, on `RawConn`
- `vlib/net/tcp.c.v:198`: `c.wait_for_read()`, on `TcpConn`
- `vlib/net/tcp.c.v:224`: `c.wait_for_read()`, on `TcpConn`
- `vlib/net/udp.c.v:125`: `c.wait_for_read()`, on `UdpConn`
- `vlib/net/udp.c.v:134`: `c.wait_for_read()`, on `UdpConn`
- `vlib/net/unix/stream.c.v:142`: `c.wait_for_read()`, on `unix.StreamConn`
- `vlib/net/openssl/ssl_connection.c.v:132`: `s.wait_for_read(...)`, on `openssl.SSLConn`
- `vlib/net/openssl/ssl_connection.c.v:374`: on `openssl.SSLConn`
- `vlib/net/openssl/ssl_connection.c.v:396`: on `openssl.SSLConn`
- `vlib/net/openssl/ssl_connection.c.v:468`: on `openssl.SSLConn`
- `vlib/net/openssl/ssl_connection.c.v:538`: on `openssl.SSLConn`
- `vlib/net/openssl/ssl_listener.c.v:216`: `conn.wait_for_read(timeout)`, on `openssl.SSLConn`, in `accept_handshake`
- `vlib/net/mbedtls/ssl_connection.c.v:445`: `conn.wait_for_read(...)`, on `mbedtls.SSLConn`, in `do_handshake_loop`
- `vlib/net/mbedtls/ssl_connection.c.v:902`: on `mbedtls.SSLConn`
- `vlib/net/mbedtls/ssl_connection.c.v:983`: on `mbedtls.SSLConn`

**2. `os.open_append` and `fd == 0`**

At this commit the premise is false: `fd` is not 0 on Unix.
- `vlib/os/os.c.v:1255-1257`: on Unix the file is opened with `C.fopen(&char(cpath), c'ab')`.
- `vlib/os/os.c.v:1262-1266`: the returned `File` is built with `fd: fileno(file.cfile)` (line 1264), along with `cfile` and `is_opened: true`.
- `vlib/os/os.c.v:371-378`: `fileno` returns `C.fileno(...)` on Unix (line 377), which is the real descriptor.
- `vlib/os/os_fd_test.v:102-111` tests this: "os.open_append must carry the descriptor, not the zero default."

The answer to "why 0" would be a returned `File{}` literal that leaves `fd` out, so it keeps the int default of 0. At this commit the code sets `fd` explicitly, so that does not happen.

**3. Routes from `http.get` to `net.dial_tcp`**

There are 17 routes. Every route starts with this prefix, P:
`http.get` → `fetch` (`vlib/net/http/http.v:71`) → `Request.do` (`vlib/net/http/http.v:251`) → `Request.method_and_url_to_response` (`vlib/net/http/request.v:307`).

Two shared tails are used below:
- **D:** `ssl.SSLConn.dial`, which is the OpenSSL one under `-d use_openssl`, → `net.dial_tcp` (`vlib/net/openssl/ssl_connection.c.v:336`). The mbedtls `dial` (`vlib/net/mbedtls/ssl_connection.c.v:821`) does not call `dial_tcp`.
- **T1:** `Transport.tls_fresh_round_trip` → `tls_fresh_round_trip_ssl` (`vlib/net/http/transport.v:810`) → `SSLConn.dial` (`vlib/net/http/transport.v:823`) → D.
- **T2:** `Transport.tls_fresh_round_trip` → `vschannel_fresh_round_trip` (`vlib/net/http/transport.v:808`) → `tls_fresh_round_trip_ssl` (`vlib/net/http/vschannel_pooled_transport_windows.c.v:270`) → `SSLConn.dial` (`vlib/net/http/transport.v:823`) → D.

Through `Transport.round_trip` (`vlib/net/http/request.v:402`):
1. P → `round_trip` → `dial_h1_tcp` (`vlib/net/http/transport.v:757`) → `net.dial_tcp` (`vlib/net/http/transport.v:792`)
2. P → `round_trip` → `tls_fresh_round_trip` (`vlib/net/http/transport.v:755`) → T1
3. P → `round_trip` → `tls_fresh_round_trip` (`vlib/net/http/transport.v:755`) → T2
4. P → `round_trip` → `h2_round_trip` (`vlib/net/http/transport.v:742`) → `h2_dial_and_do` (`vlib/net/http/transport_h2.v:83`, 104) → `h2_dial_probe` (`vlib/net/http/transport_h2.v:265`) → `h2_dial_probe_ssl` (`vlib/net/http/transport_h2.v:156`) → `SSLConn.dial` (`vlib/net/http/transport_h2.v:170`) → D
5. Same as 4, but `h2_dial_probe` → `h2_dial_probe_vschannel` (`vlib/net/http/transport_h2.v:154`) → `h2_dial_probe_ssl` (`vlib/net/http/vschannel_pooled_transport_windows.c.v:226`) → `SSLConn.dial` (`vlib/net/http/transport_h2.v:170`) → D
6. P → `round_trip` → `h2_round_trip` (742) → `h2_dial_and_do` (83, 104) → `h2_fallback_h1` (`vlib/net/http/transport_h2.v:253`, 314) → `h2_use_h1_pool_or_dial` (`vlib/net/http/transport_h2.v:198`) → `tls_fresh_round_trip` (`vlib/net/http/transport_h2.v:484`, 495) → T1
7. Same as 6, ending in T2
8. P → `round_trip` → `h2_round_trip` (742) → `h2_dial_and_do` (83, 104) → `h2_await_dial` (`vlib/net/http/transport_h2.v:220`, 259) → `h2_fallback_h1` (`vlib/net/http/transport_h2.v:469`) → `h2_use_h1_pool_or_dial` (198) → `tls_fresh_round_trip` (484, 495) → T1
9. Same as 8, ending in T2

Through `Request.ssl_do` (`vlib/net/http/request.v:415`):
10. P → `ssl_do` → `net_ssl_do` (`vlib/net/http/backend.c.v:15`) → `SSLConn.dial` (`vlib/net/http/backend.c.v:39`) → D
11. P → `ssl_do` → `vschannel_retry_handshake` (`vlib/net/http/backend.c.v:12`) → `net_ssl_do` (`vlib/net/http/vschannel_handshake.v:32`) → `SSLConn.dial` (`vlib/net/http/backend.c.v:39`) → D

Through `Request.http_do`:
12. P → `Request.http_do` (`vlib/net/http/request.v:426`) → `net.dial_tcp` (`vlib/net/http/request.v:546`)

Through `HttpProxy.http_do` (`vlib/net/http/request.v:436`):
13. P → `HttpProxy.http_do` → `ssl_dial` (`vlib/net/http/http_proxy.v:160`) → `connect_tcp` (`vlib/net/http/http_proxy.v:209`) → `net.dial_tcp` (`vlib/net/http/http_proxy.v:138`)
14. P → `HttpProxy.http_do` → `ssl_dial` (160) → `connect_tcp` (209) → `socks.socks5_dial` (`vlib/net/http/http_proxy.v:144`) → `net.dial_tcp` (`vlib/net/socks/socks5.v:20`)
15. P → `HttpProxy.http_do` → `ssl_dial` (160) → `socks.socks5_ssl_dial` (`vlib/net/http/http_proxy.v:224`) → `socks5_dial` (`vlib/net/socks/socks5.v:35`) → `net.dial_tcp` (`vlib/net/socks/socks5.v:20`)
16. P → `HttpProxy.http_do` → `HttpProxy.dial` (`vlib/net/http/http_proxy.v:173`) → `connect_tcp` (`vlib/net/http/http_proxy.v:204`) → `net.dial_tcp` (`vlib/net/http/http_proxy.v:138`)
17. P → `HttpProxy.http_do` → `HttpProxy.dial` (173) → `connect_tcp` (204) → `socks.socks5_dial` (`vlib/net/http/http_proxy.v:144`) → `net.dial_tcp` (`vlib/net/socks/socks5.v:20`)

`h3_round_trip` (`vlib/net/http/transport.v:723`) uses QUIC/UDP and never reaches `dial_tcp`. The registered scheme handler in `fetch` (`vlib/net/http/http.v:246`) is a function-pointer call, so it is not a direct call.

**4. Calls of `net.TcpConn.write_string`**

There are 6 calls.
- `vlib/net/http/http_proxy.v:176`: `client.write_string(s)`, in `HttpProxy.http_do`
- `vlib/net/pop/pop.v:138`: `c.conn.write_string(wire)`, in `pop.Client.send_cmd`
- `vlib/veb/veb.v:1103`: `conn.write_string(s)`, in `veb.send_string`
- `vlib/veb/veb_livereload.v:144`: `c.write_string(head)`, in `LivereloadHub.add`
- `vlib/veb/veb_livereload.v:166`: `c.write_string(payload)`, in `LivereloadHub.send`
- `vlib/veb/veb_livereload.v:289`: `conn.write_string('HTTP/1.1 503 ...')`, in `veb.Context.handle_veb_livereload_events`

**5. Direct calls in `os.cp_all` (`vlib/os/os.v:71`)**

- `real_path`: `vlib/os/os.v:72`, 73
- `exists`: `vlib/os/os.v:74`, 85, 95, 106
- `error` (builtin): `vlib/os/os.v:75`, 89, 99
- `is_dir`: `vlib/os/os.v:78`, 80, 98, 105
- `file_name`: `vlib/os/os.v:79`
- `join_path_single`: `vlib/os/os.v:81`, 103, 104
- `rm`: `vlib/os/os.v:87`
- `cp`: `vlib/os/os.v:92`
- `mkdir`: `vlib/os/os.v:96`, 107
- `ls`: `vlib/os/os.v:101`
- `cp_all` (recursive): `vlib/os/os.v:110`
- `rmdir`: `vlib/os/os.v:111`

**6. Method calls in `http.Server.listen_and_serve` (`vlib/net/http/server.v:73`)**

- Line 79: `s.listen_and_serve_tls()` on `http.Server`. Declared at `vlib/net/http/server_tls_notd_use_openssl.v:46`, or `vlib/net/http/server_tls_d_use_openssl.v:11` under `-d use_openssl`.
- Line 92: `s.listener.addr()` on `net.TcpListener`, declared at `vlib/net/tcp.c.v:661`.
- Line 96: `l.str()` on `net.Addr`, declared at `vlib/net/address.c.v:305`.
- Line 98: `s.listener.set_accept_timeout(...)` on `net.TcpListener`, declared at `vlib/net/tcp.c.v:649`.
- Line 119: `s.listener.accept_only()` on `net.TcpListener`, declared at `vlib/net/tcp.c.v:593`.
- Line 120: `err.code()` on `IError`, declared at `vlib/builtin/chan_option_result.v:38` (interface method).
- Line 128: `conn.set_read_timeout(...)` on `&net.TcpConn`, declared at `vlib/net/tcp.c.v:348`.
- Line 129: `conn.set_write_timeout(...)` on `&net.TcpConn`, declared at `vlib/net/tcp.c.v:377`.
- Line 133: `s.close()` on `http.Server`, declared at `vlib/net/http/server.v:149`.

Line 116, `s.on_running(mut s)`, calls a function-typed field, not a method.

**7. Redirect-related errors in vlib/net/http**

- `vlib/net/http/request.v:305`: `error('http.request.do: maximum number of redirects reached (${max_redirects})')`
- `vlib/net/http/request.v:329`: `error('http.request.do: invalid URL in redirect "${redirect_url}"')`
- `vlib/net/http/request.v:334`: `error('http.request.do: invalid URL in redirect "${redirect_url}"')`

**8. Functions that call `net.dial_tcp` directly**

- `net.TCPDialer.dial`: `vlib/net/tcp.c.v:17`
- `websocket.Client.dial_socket`: `vlib/net/websocket/io.v:77`
- `socks.socks5_dial`: `vlib/net/socks/socks5.v:20`
- `smtp.Client.reconnect`: `vlib/net/smtp/smtp.v:127`
- `pop.dial`: `vlib/net/pop/pop.v:54`
- `openssl.SSLConn.dial`: `vlib/net/openssl/ssl_connection.c.v:336`
- `imap.Client.connect`: `vlib/net/imap/imap.v:161`
- `http.Transport.dial_h1_tcp`: `vlib/net/http/transport.v:792`
- `http.Request.http_do`: `vlib/net/http/request.v:546`
- `http.HttpProxy.connect_tcp`: `vlib/net/http/http_proxy.v:138`
- `ftp.FTP.connect`: `vlib/net/ftp/ftp.v:113`
- `ftp.new_dtp`: `vlib/net/ftp/ftp.v:204`
- `redis.dial_connection`: `vlib/db/redis/dial.c.v:8`
