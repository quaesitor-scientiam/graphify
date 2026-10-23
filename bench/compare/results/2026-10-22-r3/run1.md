**1. Calls of a `wait_for_read` method in vlib/net**
- vlib/net/tcp.c.v:198: `c.wait_for_read()!` on TcpConn
- vlib/net/tcp.c.v:224: `c.wait_for_read()!` on TcpConn
- vlib/net/udp.c.v:125: `c.wait_for_read()!` on UdpConn
- vlib/net/udp.c.v:134: `c.wait_for_read()!` on UdpConn
- vlib/net/raw.c.v:126: `c.wait_for_read()!` on RawConn
- vlib/net/unix/stream.c.v:142: `c.wait_for_read()!` on unix.StreamConn
- vlib/net/mbedtls/ssl_connection.c.v:443: `conn.wait_for_read(...)` on mbedtls.SSLConn
- vlib/net/mbedtls/ssl_connection.c.v:916: `s.wait_for_read(...)` on mbedtls.SSLConn
- vlib/net/mbedtls/ssl_connection.c.v:997: `s.wait_for_read(...)` on mbedtls.SSLConn
- vlib/net/openssl/ssl_connection.c.v:132: on openssl.SSLConn
- vlib/net/openssl/ssl_connection.c.v:374: on openssl.SSLConn
- vlib/net/openssl/ssl_connection.c.v:396: on openssl.SSLConn
- vlib/net/openssl/ssl_connection.c.v:468: on openssl.SSLConn
- vlib/net/openssl/ssl_connection.c.v:538: on openssl.SSLConn
- vlib/net/openssl/ssl_listener.c.v:216: `conn.wait_for_read(timeout)!` on openssl.SSLConn

Left out:
- vlib/net/mbedtls/ssl_connection.c.v:903 is commented out.
- Calls of the free functions are left out: tcp.c.v:383, 654; udp.c.v:192; raw.c.v:191; unix/stream.c.v:218, 346.

**2. `os.open_append` and `fd`**
At this commit, `open_append` does not return a File whose `fd` is 0 on Unix. The premise doesn't hold.
- vlib/os/os.c.v:1245 to 1267 is the only definition.
- vlib/os/os.c.v:1256: on Unix the file is opened with `C.fopen(&char(cpath), c'ab')`.
- vlib/os/os.c.v:1264: the returned File sets `fd: fileno(file.cfile)`.
- vlib/os/os.c.v:371 to 378: `fileno` calls `C.fileno` (line 377, declared at vlib/builtin/cfns.c.v:144), which returns the real descriptor.
- vlib/os/file.c.v:21: `fd int` defaults to 0, but only the temporary `File{}` at os.c.v:1246 and the one built at 1255 to 1257 leave it at that default. Neither is returned.

So `fd` is 0 only if `fopen` really got descriptor 0 (for example, when stdin was closed). The only places in os that set `fd: 0` on purpose are `stdin()` at vlib/os/file.c.v:159 and the JS backend at vlib/os/file.js.v:63.

**3. Routes from `http.get` to `net.dial_tcp`**
All 17 routes share the same first four steps. I'll call that prefix P:
- `get` (vlib/net/http/http.v:70)
- → `fetch`, called at vlib/net/http/http.v:71
- → `Request.do`, called at vlib/net/http/http.v:251
- → `Request.method_and_url_to_response`, called at vlib/net/http/request.v:295

The routes after P:
1. → `Request.http_do`, called at request.v:411 → `net.dial_tcp`, called at vlib/net/http/request.v:531
2. → `Transport.round_trip`, called at request.v:387 → `dial_h1_tcp`, called at vlib/net/http/transport.v:757 → `dial_tcp`, called at transport.v:791
3. → `HttpProxy.http_do`, called at request.v:421 → `ssl_dial`, called at vlib/net/http/http_proxy.v:160 → `connect_tcp`, called at http_proxy.v:209 → `dial_tcp`, called at http_proxy.v:138
4. → `HttpProxy.http_do`, called at request.v:421 → `HttpProxy.dial`, called at http_proxy.v:173 → `connect_tcp`, called at http_proxy.v:204 → `dial_tcp`, called at http_proxy.v:138
5. → `HttpProxy.http_do`, called at request.v:421 → `ssl_dial`, called at http_proxy.v:160 → `connect_tcp`, called at http_proxy.v:209 → `socks.socks5_dial`, called at http_proxy.v:144 → `dial_tcp`, called at vlib/net/socks/socks5.v:20
6. → `HttpProxy.http_do`, called at request.v:421 → `ssl_dial`, called at http_proxy.v:160 → `socks.socks5_ssl_dial`, called at http_proxy.v:224 → `socks5_dial`, called at socks5.v:35 → `dial_tcp`, called at socks5.v:20
7. → `HttpProxy.http_do`, called at request.v:421 → `HttpProxy.dial`, called at http_proxy.v:173 → `connect_tcp`, called at http_proxy.v:204 → `socks5_dial`, called at http_proxy.v:144 → `dial_tcp`, called at socks5.v:20

Routes 8 to 17 end in openssl's `SSLConn.dial`, which calls `dial_tcp` at vlib/net/openssl/ssl_connection.c.v:336. They only exist with `-d use_openssl`. Routes 10, 11, 13, 16 and 17 also need `windows && !no_vschannel`.

8. → `ssl_do`, called at request.v:400 → `net_ssl_do`, called at vlib/net/http/backend.c.v:15 → `SSLConn.dial`, called at backend.c.v:39 → `dial_tcp`, called at ssl_connection.c.v:336
9. → `round_trip`, called at request.v:387 → `tls_fresh_round_trip`, called at transport.v:755 → `tls_fresh_round_trip_ssl`, called at transport.v:809 → `SSLConn.dial`, called at transport.v:822 → `dial_tcp`, called at ssl_connection.c.v:336
10. → `ssl_do`, called at request.v:400 → `vschannel_retry_handshake`, called at backend.c.v:12 → `net_ssl_do`, called at vlib/net/http/vschannel_handshake.v:32 → `SSLConn.dial`, called at backend.c.v:39 → `dial_tcp`, called at ssl_connection.c.v:336
11. → `round_trip`, called at request.v:387 → `tls_fresh_round_trip`, called at transport.v:755 → `vschannel_fresh_round_trip`, called at transport.v:807 → `tls_fresh_round_trip_ssl`, called at vlib/net/http/vschannel_pooled_transport_windows.c.v:270 → `SSLConn.dial`, called at transport.v:822 → `dial_tcp`, called at ssl_connection.c.v:336

Routes 12 to 17 continue from `round_trip` (called at request.v:387) → `h2_round_trip`, called at transport.v:742 → `h2_dial_and_do`, called at vlib/net/http/transport_h2.v:83 and 104:

12. → `h2_dial_probe`, called at transport_h2.v:265 → `h2_dial_probe_ssl`, called at transport_h2.v:156 → `SSLConn.dial`, called at transport_h2.v:170 → `dial_tcp`, called at ssl_connection.c.v:336
13. → `h2_dial_probe`, called at transport_h2.v:265 → `h2_dial_probe_vschannel`, called at transport_h2.v:154 → `h2_dial_probe_ssl`, called at vschannel_pooled_transport_windows.c.v:226 → `SSLConn.dial`, called at transport_h2.v:170 → `dial_tcp`, called at ssl_connection.c.v:336
14. → `h2_fallback_h1`, called at transport_h2.v:253 and 314 → `h2_use_h1_pool_or_dial`, called at transport_h2.v:198 → `tls_fresh_round_trip`, called at transport_h2.v:484 and 495 → `tls_fresh_round_trip_ssl`, called at transport.v:809 → `SSLConn.dial`, called at transport.v:822 → `dial_tcp`, called at ssl_connection.c.v:336
15. → `h2_await_dial`, called at transport_h2.v:220 and 259 → `h2_fallback_h1`, called at transport_h2.v:469 → `h2_use_h1_pool_or_dial`, called at transport_h2.v:198 → `tls_fresh_round_trip`, called at transport_h2.v:484 and 495 → `tls_fresh_round_trip_ssl`, called at transport.v:809 → `SSLConn.dial`, called at transport.v:822 → `dial_tcp`, called at ssl_connection.c.v:336
16. Same as 14, except `tls_fresh_round_trip` → `vschannel_fresh_round_trip`, called at transport.v:807 → `tls_fresh_round_trip_ssl`, called at vschannel_pooled_transport_windows.c.v:270 → `SSLConn.dial`, called at transport.v:822 → `dial_tcp`, called at ssl_connection.c.v:336
17. Same as 15, except `tls_fresh_round_trip` → `vschannel_fresh_round_trip`, called at transport.v:807 → `tls_fresh_round_trip_ssl`, called at vschannel_pooled_transport_windows.c.v:270 → `SSLConn.dial`, called at transport.v:822 → `dial_tcp`, called at ssl_connection.c.v:336

**4. Calls of `net.TcpConn.write_string` in vlib**
- vlib/net/http/http_proxy.v:176, in `HttpProxy.http_do`
- vlib/net/pop/pop.v:138, in `pop.Client.send_cmd`
- vlib/veb/veb.v:1103, in `veb.send_string`
- vlib/veb/veb_livereload.v:144, in `LivereloadHub.add`
- vlib/veb/veb_livereload.v:166, in `LivereloadHub.send`
- vlib/veb/veb_livereload.v:289, in `Context.handle_veb_livereload_events`

**5. Direct calls of `os.cp_all` (vlib/os/os.v:71)**
- `real_path`: lines 72, 73
- `exists`: lines 74, 85, 95, 106
- `error`: lines 75, 89, 99
- `is_dir`: lines 78, 80, 98, 105
- `file_name`: line 79
- `join_path_single`: lines 81, 103, 104
- `rm`: line 87
- `cp`: line 92
- `mkdir`: lines 96, 107
- `ls`: line 101
- `cp_all`, recursively: line 110
- `rmdir`: line 111

**6. Method calls in `http.Server.listen_and_serve` (vlib/net/http/server.v)**
- Line 79: `s.listen_and_serve_tls()` on Server. It calls vlib/net/http/server_tls_notd_use_openssl.v:46 in the default build, or vlib/net/http/server_tls_d_use_openssl.v:11 with `-d use_openssl`.
- Line 92: `s.listener.addr()` on net.TcpListener, declared at vlib/net/tcp.c.v:661.
- Line 96: `l.str()` on net.Addr, declared at vlib/net/address.c.v:305.
- Line 98: `s.listener.set_accept_timeout(...)` on net.TcpListener, declared at vlib/net/tcp.c.v:649.
- Line 119: `s.listener.accept_only()` on net.TcpListener, declared at vlib/net/tcp.c.v:593.
- Line 120: `err.code()` on IError, declared at vlib/builtin/chan_option_result.v:38.
- Line 128: `conn.set_read_timeout(...)` on &net.TcpConn, declared at vlib/net/tcp.c.v:348.
- Line 129: `conn.set_write_timeout(...)` on &net.TcpConn, declared at vlib/net/tcp.c.v:377.
- Line 133: `s.close()` on Server, declared at vlib/net/http/server.v:149.

Line 116, `s.on_running(mut s)`, is a call through a function-pointer field declared at server.v:64, not a method.

**7. Errors in vlib/net/http that mention a redirect**
- vlib/net/http/request.v:293: `return error('http.request.do: maximum number of redirects reached (${max_redirects})')`
- vlib/net/http/request.v:314: `return error('http.request.do: invalid URL in redirect "${redirect_url}"')`
- vlib/net/http/request.v:319: `return error('http.request.do: invalid URL in redirect "${redirect_url}"')`

**8. Functions in vlib that call `net.dial_tcp` directly**
- `net.TCPDialer.dial`: vlib/net/tcp.c.v:17
- `openssl.SSLConn.dial`: vlib/net/openssl/ssl_connection.c.v:336
- `socks.socks5_dial`: vlib/net/socks/socks5.v:20
- `smtp.Client.reconnect`: vlib/net/smtp/smtp.v:127
- `imap.Client.connect`: vlib/net/imap/imap.v:161
- `pop.dial`: vlib/net/pop/pop.v:54
- `http.HttpProxy.connect_tcp`: vlib/net/http/http_proxy.v:138
- `http.Transport.dial_h1_tcp`: vlib/net/http/transport.v:791
- `http.Request.http_do`: vlib/net/http/request.v:531
- `websocket.Client.dial_socket`: vlib/net/websocket/io.v:77
- `ftp.FTP.connect`: vlib/net/ftp/ftp.v:113
- `ftp.new_dtp`: vlib/net/ftp/ftp.v:204
- `redis.dial_connection`: vlib/db/redis/dial.c.v:8