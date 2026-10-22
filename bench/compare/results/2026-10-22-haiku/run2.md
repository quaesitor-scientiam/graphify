**Q1.** 15 method calls of `wait_for_read` in vlib/net (non-test):
- vlib/net/tcp.c.v:198 (`TcpConn.read_ptr`)
- vlib/net/tcp.c.v:224 (`TcpConn.read_ptr`)
- vlib/net/raw.c.v:126
- vlib/net/udp.c.v:125
- vlib/net/udp.c.v:134
- vlib/net/unix/stream.c.v:142
- vlib/net/mbedtls/ssl_connection.c.v:443
- vlib/net/mbedtls/ssl_connection.c.v:916
- vlib/net/mbedtls/ssl_connection.c.v:997
- vlib/net/openssl/ssl_connection.c.v:132
- vlib/net/openssl/ssl_connection.c.v:374
- vlib/net/openssl/ssl_connection.c.v:396
- vlib/net/openssl/ssl_connection.c.v:468
- vlib/net/openssl/ssl_connection.c.v:538
- vlib/net/openssl/ssl_listener.c.v:216

Excluded: the free-function calls at vlib/net/tcp.c.v:383, 654, vlib/net/raw.c.v:191, vlib/net/udp.c.v:192, vlib/net/unix/stream.c.v:218, 346. Also the commented-out calls at vlib/net/mbedtls/ssl_connection.c.v:903 and the comment at vlib/net/openssl/ssl_connection.c.v:268.

**Q2.** The premise doesn't hold at this commit. `open_append` does not return fd 0. Its body builds a temporary `File` with no fd (vlib/os/os.c.v:1254-1258, so the field is 0 there), then returns a new `File` whose `fd` is `fileno(file.cfile)` (vlib/os/os.c.v:1262-1266). On Unix, `fileno` calls `C.fileno` (vlib/os/os.c.v:371-377). The test vlib/os/os_fd_test.v:110-112 asserts `a.fd > 2`.

**Q3.** Default build (mbedtls): four routes, all starting `http.get` (vlib/net/http/http.v:70) → `fetch` (http.v:71) → `Request.do` (http.v:251 calls `req.do()`, `fetch` at http.v:241) → `method_and_url_to_response` (vlib/net/http/request.v:295):
1. request.v:411 → `Request.http_do` (request.v:528) → `net.dial_tcp` at request.v:531
2. request.v:387 → `Transport.round_trip` (transport.v:708) → transport.v:757 → `Transport.dial_h1_tcp` (transport.v:790) → `net.dial_tcp` at transport.v:791
3. request.v:421 → `HttpProxy.http_do` (http_proxy.v:150) → http_proxy.v:173 → `HttpProxy.dial` (http_proxy.v:203) → http_proxy.v:204 → `HttpProxy.connect_tcp` (http_proxy.v:136) → `net.dial_tcp` at http_proxy.v:138
4. request.v:421 → `HttpProxy.http_do` → http_proxy.v:160 → `HttpProxy.ssl_dial` (http_proxy.v:207) → http_proxy.v:209 → `HttpProxy.connect_tcp` → `net.dial_tcp` at http_proxy.v:138

TLS routes: the default `ssl.SSLConn` is mbedtls, whose `dial` (vlib/net/mbedtls/ssl_connection.c.v:827) doesn't reach `net.dial_tcp`, so no TLS route exists in that build. Under `-d use_openssl`, the TLS dials reach it at vlib/net/openssl/ssl_connection.c.v:336 via, for example, request.v:400 → vlib/net/http/backend.c.v:15 → backend.c.v:39; or request.v:387 → transport.v:755 → transport.v:809 → transport.v:822; or transport.v:742 → vlib/net/http/transport_h2.v:104 → transport_h2.v:265 → transport_h2.v:156 → transport_h2.v:170. I did not enumerate every TLS variant.

**Q4.** Two calls of `TcpConn.write_string` (the method is defined at vlib/net/tcp.c.v:322):
- vlib/net/pop/pop.v:138, in `Client.send_cmd` (pop.v:134)
- vlib/net/http/http_proxy.v:176, in `HttpProxy.http_do` (http_proxy.v:150)

**Q5.** `os.cp_all` (vlib/os/os.v:71) calls directly:
- `real_path`: os.v:72, 73
- `exists`: os.v:74, 85, 95, 106
- `error` (builtin): os.v:75, 89, 99
- `is_dir`: os.v:78, 80, 98, 105
- `file_name`: os.v:79
- `join_path_single`: os.v:81, 103, 104
- `rm`: os.v:87
- `cp`: os.v:92
- `mkdir`: os.v:96, 107
- `ls`: os.v:101
- `rmdir`: os.v:111
- `cp_all` (itself, recursive): os.v:110

**Q6.** Method calls in `Server.listen_and_serve` (vlib/net/http/server.v:73):
- line 79, `s.listen_and_serve_tls()`, receiver `Server` → vlib/net/http/server_tls_notd_use_openssl.v:46 (the `-d use_openssl` variant is server_tls_d_use_openssl.v:11)
- line 92, `s.listener.addr()`, receiver `net.TcpListener` → vlib/net/tcp.c.v:661
- line 96, `l.str()`, receiver `net.Addr` → vlib/net/address.c.v:305
- line 98, `s.listener.set_accept_timeout(...)`, receiver `net.TcpListener` → vlib/net/tcp.c.v:649
- line 119, `s.listener.accept_only()`, receiver `net.TcpListener` → vlib/net/tcp.c.v:593
- line 120, `err.code()`, receiver `IError` → vlib/builtin/chan_option_result.v:38
- line 128, `conn.set_read_timeout(...)`, receiver `net.TcpConn` → vlib/net/tcp.c.v:348
- line 129, `conn.set_write_timeout(...)`, receiver `net.TcpConn` → vlib/net/tcp.c.v:377
- line 133, `s.close()`, receiver `Server` → vlib/net/http/server.v:149

Not counted: `s.on_running(mut s)` at line 116 (a call of a function-typed field, not a method), and free functions such as `net.listen_tcp`, `new_handler_worker`, `flush_stdout`, `time.sleep`, `println`.

**Q7.** Three places in vlib/net/http:
- vlib/net/http/request.v:293 (`maximum number of redirects reached`)
- vlib/net/http/request.v:314 (`invalid URL in redirect`)
- vlib/net/http/request.v:319 (`invalid URL in redirect`)

**Q8.** Thirteen non-test functions call `net.dial_tcp` directly:
- `TCPDialer.dial`: vlib/net/tcp.c.v:17
- `SSLConn.dial` (openssl): vlib/net/openssl/ssl_connection.c.v:336
- `dial`: vlib/net/pop/pop.v:54
- `Client.reconnect`: vlib/net/smtp/smtp.v:127
- `Client.connect`: vlib/net/imap/imap.v:161
- `socks5_dial`: vlib/net/socks/socks5.v:20
- `FTP.connect`: vlib/net/ftp/ftp.v:113
- `new_dtp`: vlib/net/ftp/ftp.v:204
- `dial_socket`: vlib/net/websocket/io.v:77
- `HttpProxy.connect_tcp`: vlib/net/http/http_proxy.v:138
- `Transport.dial_h1_tcp`: vlib/net/http/transport.v:791
- `Request.http_do`: vlib/net/http/request.v:531
- `dial_connection`: vlib/db/redis/dial.c.v:8