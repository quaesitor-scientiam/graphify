**Q1. `wait_for_read` method calls in vlib/net (non-test, non-comment): 18**
- vlib/net/tcp.c.v:198
- vlib/net/tcp.c.v:224
- vlib/net/udp.c.v:125
- vlib/net/udp.c.v:134
- vlib/net/unix/stream.c.v:142
- vlib/net/raw.c.v:126
- vlib/net/mbedtls/ssl_connection.c.v:443
- vlib/net/mbedtls/ssl_connection.c.v:916
- vlib/net/mbedtls/ssl_connection.c.v:997
- vlib/net/openssl/ssl_connection.c.v:132
- vlib/net/openssl/ssl_connection.c.v:374
- vlib/net/openssl/ssl_connection.c.v:396
- vlib/net/openssl/ssl_connection.c.v:468
- vlib/net/openssl/ssl_connection.c.v:538
- vlib/net/openssl/ssl_listener.c.v:216

Excluded: vlib/net/mbedtls/ssl_connection.c.v:903 (commented out), vlib/net/unix/deadline_test.v:27 and :105, vlib/net/http/transport_idle_test.v:29 (tests).

**Q2. The premise doesn't hold in this tree: `open_append` does not return fd 0 on Unix.**
- vlib/os/os.c.v:1255-1257 builds an intermediate `File{ cfile: C.fopen(...) }`. Its `fd` is unset, so it is 0, but that value is never returned.
- vlib/os/os.c.v:1262-1266 returns a new `File` with `fd: fileno(file.cfile)` (line 1264).
- vlib/os/os.c.v:371-377 `fileno` returns `C.fileno(...)` on Unix, the real descriptor.
- vlib/os/os_fd_test.v:110-112 asserts `a.fd > 2` for `open_append`.

**Q3. Routes from `http.get` to `net.dial_tcp`: 17 routes (7 in the default build).** Each step is the call site. Common prefix for all routes: vlib/net/http/http.v:71 (get→fetch), vlib/net/http/http.v:251 (fetch→do), vlib/net/http/request.v:295 (do→method_and_url_to_response). Destination: vlib/net/tcp.c.v:48.

Default build:
1. request.v:411 (→http_do), request.v:531 (→dial_tcp)
2. request.v:387 (→round_trip, transport.v:708), transport.v:757 (→dial_h1_tcp), transport.v:791 (→dial_tcp)
3. request.v:421 (→http_do, http_proxy.v:150), http_proxy.v:160 (→ssl_dial), http_proxy.v:209 (→connect_tcp), http_proxy.v:138 (→dial_tcp)
4. request.v:421, http_proxy.v:173 (→dial), http_proxy.v:204 (→connect_tcp), http_proxy.v:138
5. request.v:421, http_proxy.v:160, http_proxy.v:209, http_proxy.v:144 (→socks5_dial, vlib/net/socks/socks5.v:19), socks5.v:20
6. request.v:421, http_proxy.v:160, http_proxy.v:224 (→socks5_ssl_dial), socks5.v:35 (→socks5_dial), socks5.v:20
7. request.v:421, http_proxy.v:173, http_proxy.v:204, http_proxy.v:144, socks5.v:20

Build-conditional (the tool marks each one; the last step is vlib/net/openssl/ssl_connection.c.v:336, `SSLConn.dial`, which needs `use_openssl`):
8. [use_openssl] request.v:400 (→ssl_do, backend.c.v:9), backend.c.v:15 (→net_ssl_do), backend.c.v:39 (→SSLConn.dial), openssl:336
9. [use_openssl] request.v:387, transport.v:755 (→tls_fresh_round_trip), transport.v:809 (→tls_fresh_round_trip_ssl), transport.v:822 (→SSLConn.dial), openssl:336
10. [windows, vschannel, use_openssl] request.v:400, backend.c.v:12 (→vschannel_retry_handshake), vschannel_handshake.v:32 (→net_ssl_do), backend.c.v:39, openssl:336
11. [windows, vschannel, use_openssl] request.v:387, transport.v:755, transport.v:807 (→vschannel_fresh_round_trip), vschannel_pooled_transport_windows.c.v:270 (→tls_fresh_round_trip_ssl), transport.v:822, openssl:336
12. [use_openssl] request.v:387, transport.v:742 (→h2_round_trip), transport_h2.v:83 or :104 (→h2_dial_and_do), transport_h2.v:265 (→h2_dial_probe), transport_h2.v:156 (→h2_dial_probe_ssl), transport_h2.v:170 (→SSLConn.dial), openssl:336
13. [windows, vschannel, use_openssl] request.v:387, transport.v:742, transport_h2.v:83 or :104, transport_h2.v:265, transport_h2.v:154 (→h2_dial_probe_vschannel), vschannel_pooled_transport_windows.c.v:226 (→h2_dial_probe_ssl), transport_h2.v:170, openssl:336
14. [use_openssl] request.v:387, transport.v:742, transport_h2.v:83 or :104, transport_h2.v:253 or :314 (→h2_fallback_h1), transport_h2.v:198 (→h2_use_h1_pool_or_dial), transport_h2.v:484 or :495 (→tls_fresh_round_trip), transport.v:809, transport.v:822, openssl:336
15. [use_openssl] request.v:387, transport.v:742, transport_h2.v:83 or :104, transport_h2.v:220 or :259 (→h2_await_dial), transport_h2.v:469 (→h2_fallback_h1), transport_h2.v:198, transport_h2.v:484 or :495, transport.v:809, transport.v:822, openssl:336
16. [windows, vschannel, use_openssl] request.v:387, transport.v:742, transport_h2.v:83 or :104, transport_h2.v:253 or :314, transport_h2.v:198, transport_h2.v:484 or :495, transport.v:807, vschannel_pooled_transport_windows.c.v:270, transport.v:822, openssl:336
17. [windows, vschannel, use_openssl] request.v:387, transport.v:742, transport_h2.v:83 or :104, transport_h2.v:220 or :259, transport_h2.v:469, transport_h2.v:198, transport_h2.v:484 or :495, transport.v:807, vschannel_pooled_transport_windows.c.v:270, transport.v:822, openssl:336

The graph reported the vschannel call sites in vlib/net/http/backend_vschannel_d_cross.v:226 and :270. That file contains only stubs that call nothing, so I used the Windows file where those calls actually are.

**Q4. Calls of `net.TcpConn.write_string` in vlib (non-test): 6**
- vlib/net/pop/pop.v:138, in `Client.send_cmd` (pop.v:134)
- vlib/net/http/http_proxy.v:176, in `HttpProxy.http_do` (http_proxy.v:150)
- vlib/veb/veb.v:1103, in `send_string` (veb.v:1093)
- vlib/veb/veb_livereload.v:144, in `LivereloadHub.add` (veb_livereload.v:130)
- vlib/veb/veb_livereload.v:166, in `LivereloadHub.send` (veb_livereload.v:161)
- vlib/veb/veb_livereload.v:289, in `Context.handle_veb_livereload_events` (veb_livereload.v:281)

Excluded: the `strings.Builder` calls (for example vlib/net/tcp.c.v:159, 160, 165), and `ssl_conn.write_string` in vlib/net/http/backend.c.v:125 and :147, which is `SSLConn` (not `TcpConn`).

**Q5. Direct calls made by `os.cp_all` (vlib/os/os.v:71-115)**
- `real_path`: 72, 73
- `exists`: 74, 85, 95, 106
- `error` (V builtin): 75, 89, 99
- `is_dir`: 78, 80, 98, 105
- `file_name`: 79
- `join_path_single`: 81, 103, 104
- `rm`: 87
- `cp`: 92
- `mkdir`: 96, 107
- `ls`: 101
- `cp_all` (itself, recursive): 110
- `rmdir`: 111

**Q6. Method calls in `http.Server.listen_and_serve` (vlib/net/http/server.v:73-135)**
- 79: `s.listen_and_serve_tls()`, receiver `http.Server`. Declaration: vlib/net/http/server_tls_notd_use_openssl.v:46 (default build), or vlib/net/http/server_tls_d_use_openssl.v:11 (with `use_openssl`).
- 92: `s.listener.addr()`, receiver `net.TcpListener`. Declaration: vlib/net/tcp.c.v:661.
- 96: `l.str()`, receiver `net.Addr`. Declaration: vlib/net/address.c.v:305.
- 98: `s.listener.set_accept_timeout(...)`, receiver `net.TcpListener`. Declaration: vlib/net/tcp.c.v:649.
- 119: `s.listener.accept_only()`, receiver `net.TcpListener`. Declaration: vlib/net/tcp.c.v:593.
- 120: `err.code()`, receiver `IError`. Declaration: vlib/builtin/chan_option_result.v:38 (interface method).
- 128: `conn.set_read_timeout(...)`, receiver `&net.TcpConn`. Declaration: vlib/net/tcp.c.v:348.
- 129: `conn.set_write_timeout(...)`, receiver `&net.TcpConn`. Declaration: vlib/net/tcp.c.v:377.
- 133: `s.close()`, receiver `http.Server`. Declaration: vlib/net/http/server.v:149.

Excluded: vlib/net/http/server.v:116 `s.on_running(mut s)` (a function-typed field, not a method), and the free functions `new_handler_worker`, `net.listen_tcp`, `flush_stdout`, `eprintln`, `time.sleep`.

**Q7. Errors that mention a redirect in vlib/net/http (non-test): 3**
- vlib/net/http/request.v:293: `maximum number of redirects reached`
- vlib/net/http/request.v:314: `invalid URL in redirect`
- vlib/net/http/request.v:319: `invalid URL in redirect`

Excluded: vlib/net/http/request.v:323 `req.on_redirect(...)!` (it propagates the user callback's error, whose text isn't in net/http), and vlib/net/http/README.md:288 (documentation).

**Q8. Functions in vlib (non-test) that call `net.dial_tcp` directly: 13 functions, 13 call sites**
1. vlib/net/tcp.c.v:17, `TCPDialer.dial` (tcp.c.v:16)
2. vlib/net/pop/pop.v:54, `dial` (pop.v:29)
3. vlib/net/smtp/smtp.v:127, `Client.reconnect` (smtp.v:121)
4. vlib/net/imap/imap.v:161, `Client.connect` (imap.v:157)
5. vlib/net/openssl/ssl_connection.c.v:336, `SSLConn.dial` (ssl_connection.c.v:329), openssl build only
6. vlib/net/socks/socks5.v:20, `socks5_dial` (socks5.v:19)
7. vlib/net/websocket/io.v:77, `Client.dial_socket` (io.v:74)
8. vlib/net/ftp/ftp.v:113, `FTP.connect` (ftp.v:112)
9. vlib/net/ftp/ftp.v:204, `new_dtp` (ftp.v:190)
10. vlib/net/http/http_proxy.v:138, `HttpProxy.connect_tcp` (http_proxy.v:136)
11. vlib/net/http/transport.v:791, `Transport.dial_h1_tcp` (transport.v:790)
12. vlib/net/http/request.v:531, `Request.http_do` (request.v:528)
13. vlib/db/redis/dial.c.v:8, `dial_connection` (dial.c.v:6)

Excluded: all test files, and `net/tcp_read_timeout_test.c.v`, which calls unqualified `dial_tcp`.