**1. Calls of a `wait_for_read` method in vlib/net** (14)
- vlib/net/tcp.c.v:198 and vlib/net/tcp.c.v:224: `c.wait_for_read()` on `TcpConn`, in `TcpConn.read_ptr`
- vlib/net/udp.c.v:125 and vlib/net/udp.c.v:134: on `UdpConn`, in `UdpConn.read_ptr`
- vlib/net/raw.c.v:126: on `RawConn`, in `RawConn.read_ptr`
- vlib/net/unix/stream.c.v:142: on `StreamConn`, in `StreamConn.read_ptr`
- vlib/net/mbedtls/ssl_connection.c.v:443: `conn.wait_for_read(...)`, in `do_handshake_loop`
- vlib/net/mbedtls/ssl_connection.c.v:916: in `socket_read_into_ptr`
- vlib/net/mbedtls/ssl_connection.c.v:997: in `write_ptr`
- vlib/net/openssl/ssl_connection.c.v:132: in `shutdown`
- vlib/net/openssl/ssl_connection.c.v:374 and vlib/net/openssl/ssl_connection.c.v:396: in `complete_connect`
- vlib/net/openssl/ssl_connection.c.v:468: in `socket_read_into_ptr`
- vlib/net/openssl/ssl_connection.c.v:538: in `write_ptr`
- vlib/net/openssl/ssl_listener.c.v:216: `conn.wait_for_read(timeout)` on `SSLConn`, in `accept_handshake`

Left out: vlib/net/mbedtls/ssl_connection.c.v:903 (commented out), and the test calls in vlib/net/unix/deadline_test.v and vlib/net/http/transport_idle_test.v.

**2. `os.open_append` and `fd`**
At this commit, `open_append` does not return a File with `fd` 0 on Unix:
- vlib/os/os.c.v:1246: `mut file := File{}` is a temporary, and its `fd` is 0.
- vlib/os/os.c.v:1254-1257: on Unix, that temporary is replaced with `File{ cfile: C.fopen(&char(cpath), c'ab') }`, which still has `fd` 0.
- vlib/os/os.c.v:1262-1266: the function does not return that temporary. It returns a new `File{ cfile: file.cfile, fd: fileno(file.cfile), is_opened: true }`.
- vlib/os/os.c.v:371-379: `fileno` calls `C.fileno` on Unix, which gives the real descriptor.

The `fd` field is declared at vlib/os/file.c.v:21. It would be 0 only if the function returned the temporary from lines 1255-1257 without the `fd: fileno(...)` line. That was apparently an older bug, and it is fixed in this tree.

**3. Routes from `http.get` to `net.dial_tcp`** (17)
Every route starts with the same four steps:
- `get` (vlib/net/http/http.v:70) calls `fetch` at vlib/net/http/http.v:71
- `fetch` calls `Request.do` at vlib/net/http/http.v:251
- `do` calls `method_and_url_to_response` at vlib/net/http/request.v:295

Routes 1–7 work in the default build:
1. `http_do` (request.v:528) at request.v:411, then `dial_tcp` at request.v:531.
2. `round_trip` at request.v:387, `dial_h1_tcp` at transport.v:757, then `dial_tcp` at transport.v:791.
3. `http_do` (http_proxy.v:150) at request.v:421, `ssl_dial` at http_proxy.v:160, `connect_tcp` at http_proxy.v:209, then `dial_tcp` at http_proxy.v:138.
4. The proxy `http_do` at request.v:421, `HttpProxy.dial` at http_proxy.v:173, `connect_tcp` at http_proxy.v:204, then `dial_tcp` at http_proxy.v:138.
5. Same as 3 down to `connect_tcp`, then `socks5_dial` at http_proxy.v:144, then `dial_tcp` at vlib/net/socks/socks5.v:20.
6. The proxy `http_do` at request.v:421, `ssl_dial` at http_proxy.v:160, `socks5_ssl_dial` at http_proxy.v:224, `socks5_dial` at socks5.v:35, then `dial_tcp` at socks5.v:20.
7. Same as 4 down to `connect_tcp`, then `socks5_dial` at http_proxy.v:144, then `dial_tcp` at socks5.v:20.

Routes 8–17 need `-d use_openssl`. They all end in `openssl.dial`, which calls `dial_tcp` at vlib/net/openssl/ssl_connection.c.v:336.
8. `ssl_do` at request.v:400, `net_ssl_do` at backend.c.v:15, `openssl.dial` at backend.c.v:39.
9. `round_trip` at request.v:387, `tls_fresh_round_trip` at transport.v:755, `tls_fresh_round_trip_ssl` at transport.v:809, `openssl.dial` at transport.v:822.
10. Windows (vschannel) too: `ssl_do` at request.v:400, `vschannel_retry_handshake` at backend.c.v:12, `net_ssl_do` at vschannel_handshake.v:32, `openssl.dial` at backend.c.v:39.
11. Windows (vschannel) too: `round_trip` at request.v:387, `tls_fresh_round_trip` at transport.v:755, `vschannel_fresh_round_trip` at transport.v:807, `tls_fresh_round_trip_ssl` at backend_vschannel_d_cross.v:270, `openssl.dial` at transport.v:822.
12. `round_trip` at request.v:387, `h2_round_trip` at transport.v:742, `h2_dial_and_do` at transport_h2.v:83/104, `h2_dial_probe` at transport_h2.v:265, `h2_dial_probe_ssl` at transport_h2.v:156, `openssl.dial` at transport_h2.v:170.
13. Windows (vschannel) too: as 12 down to `h2_dial_probe`, then `h2_dial_probe_vschannel` at transport_h2.v:154, `h2_dial_probe_ssl` at backend_vschannel_d_cross.v:226, `openssl.dial` at transport_h2.v:170.
14. As 12 down to `h2_dial_and_do`, then `h2_fallback_h1` at transport_h2.v:253/314, `h2_use_h1_pool_or_dial` at transport_h2.v:198, `tls_fresh_round_trip` at transport_h2.v:484/495, `tls_fresh_round_trip_ssl` at transport.v:809, `openssl.dial` at transport.v:822.
15. As 12 down to `h2_dial_and_do`, then `h2_await_dial` at transport_h2.v:220/259, `h2_fallback_h1` at transport_h2.v:469, then as in 14 from `h2_use_h1_pool_or_dial` to the end.
16. Windows (vschannel) too: as 14 down to `tls_fresh_round_trip`, then `vschannel_fresh_round_trip` at transport.v:807, `tls_fresh_round_trip_ssl` at backend_vschannel_d_cross.v:270, `openssl.dial` at transport.v:822.
17. Windows (vschannel) too: as 15 down to `tls_fresh_round_trip`, then `vschannel_fresh_round_trip` at transport.v:807, `tls_fresh_round_trip_ssl` at backend_vschannel_d_cross.v:270, `openssl.dial` at transport.v:822.

Paths in 3 without a directory are under vlib/net/http/.

**4. Calls of `net.TcpConn.write_string`** (6)
- vlib/net/http/http_proxy.v:176: in `HttpProxy.http_do`
- vlib/net/pop/pop.v:138: in `Client.send_cmd`
- vlib/veb/veb.v:1103: in `send_string`
- vlib/veb/veb_livereload.v:144: in `LivereloadHub.add`
- vlib/veb/veb_livereload.v:166: in `LivereloadHub.send`
- vlib/veb/veb_livereload.v:289: in `Context.handle_veb_livereload_events`

**5. Functions `os.cp_all` calls directly** (vlib/os/os.v)
- `real_path`: lines 72, 73
- `exists`: lines 74, 85, 95, 106
- `error` (builtin): lines 75, 89, 99
- `is_dir`: lines 78, 80, 98, 105
- `file_name`: line 79
- `join_path_single`: lines 81, 103, 104
- `rm`: line 87
- `cp`: line 92
- `mkdir`: lines 96, 107
- `ls`: line 101
- `cp_all` (itself, recursively): line 110
- `rmdir`: line 111

**6. Method calls in `http.Server.listen_and_serve`** (vlib/net/http/server.v)
- Line 79: `s.listen_and_serve_tls()` on `Server`. It calls vlib/net/http/server_tls_notd_use_openssl.v:46 by default, or vlib/net/http/server_tls_d_use_openssl.v:11 with `-d use_openssl`.
- Line 92: `s.listener.addr()` on `net.TcpListener`, which calls vlib/net/tcp.c.v:661.
- Line 96: `l.str()` on `net.Addr`, which calls vlib/net/address.c.v:305.
- Line 98: `s.listener.set_accept_timeout(...)` on `net.TcpListener`, which calls vlib/net/tcp.c.v:649.
- Line 116: `s.on_running(mut s)` calls the fn-typed field `Server.on_running`, declared at vlib/net/http/server.v:64.
- Line 119: `s.listener.accept_only()` on `net.TcpListener`, which calls vlib/net/tcp.c.v:593.
- Line 120: `err.code()` on `IError`, which calls vlib/builtin/chan_option_result.v:38.
- Line 128: `conn.set_read_timeout(...)` on `net.TcpConn`, which calls vlib/net/tcp.c.v:348.
- Line 129: `conn.set_write_timeout(...)` on `net.TcpConn`, which calls vlib/net/tcp.c.v:377.
- Line 133: `s.close()` on `Server`, which calls vlib/net/http/server.v:149.

**7. Errors in vlib/net/http whose message mentions a redirect** (3)
- vlib/net/http/request.v:293: `error('http.request.do: maximum number of redirects reached (${max_redirects})')`
- vlib/net/http/request.v:314: `error('http.request.do: invalid URL in redirect "${redirect_url}"')`
- vlib/net/http/request.v:319: `error('http.request.do: invalid URL in redirect "${redirect_url}"')`

**8. Functions in vlib that call `net.dial_tcp` directly** (15)
- `TCPDialer.dial`: vlib/net/tcp.c.v:17
- `openssl.SSLConn.dial`: vlib/net/openssl/ssl_connection.c.v:336
- `socks.socks5_dial`: vlib/net/socks/socks5.v:20
- `smtp.Client.reconnect`: vlib/net/smtp/smtp.v:127
- `imap.Client.connect`: vlib/net/imap/imap.v:161
- `pop.dial`: vlib/net/pop/pop.v:54
- `http.HttpProxy.connect_tcp`: vlib/net/http/http_proxy.v:138
- `websocket.Client.dial_socket`: vlib/net/websocket/io.v:77
- `ftp.FTP.connect`: vlib/net/ftp/ftp.v:113
- `ftp.new_dtp`: vlib/net/ftp/ftp.v:204
- `http.dial_h1_tcp`: vlib/net/http/transport.v:791
- `http.Request.http_do`: vlib/net/http/request.v:531
- `redis.dial_connection`: vlib/db/redis/dial.c.v:8