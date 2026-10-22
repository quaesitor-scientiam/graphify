**1.** Method calls of `wait_for_read` in vlib/net (non-test):
- vlib/net/tcp.c.v:198 (TcpConn)
- vlib/net/tcp.c.v:224 (TcpConn)
- vlib/net/udp.c.v:125 (UdpConn)
- vlib/net/udp.c.v:134 (UdpConn)
- vlib/net/raw.c.v:126 (RawConn)
- vlib/net/unix/stream.c.v:142 (StreamConn)
- vlib/net/openssl/ssl_connection.c.v:132 (SSLConn)
- vlib/net/openssl/ssl_connection.c.v:374 (SSLConn)
- vlib/net/openssl/ssl_connection.c.v:396 (SSLConn)
- vlib/net/openssl/ssl_connection.c.v:468 (SSLConn)
- vlib/net/openssl/ssl_connection.c.v:538 (SSLConn)
- vlib/net/openssl/ssl_listener.c.v:216 (SSLConn, from `accept()` at line 156)
- vlib/net/mbedtls/ssl_connection.c.v:443 (SSLConn)
- vlib/net/mbedtls/ssl_connection.c.v:916 (SSLConn)
- vlib/net/mbedtls/ssl_connection.c.v:997 (SSLConn)

The free-function calls at vlib/net/tcp.c.v:383, 654, vlib/net/udp.c.v:192, vlib/net/raw.c.v:191, vlib/net/unix/stream.c.v:218, 346 are excluded, and so are the comments.

**2.** It doesn't. On Unix `open_append` does not return fd 0. The file is opened with `C.fopen(..., 'ab')` and returned as a new `File` whose `fd` is `fileno(file.cfile)` (vlib/os/os.c.v:1262–1266, with `fileno` at vlib/os/os.c.v:371–378). The 0 comes from the temporary `File{cfile: C.fopen(...)}` at vlib/os/os.c.v:1255–1257, which never sets `fd` (the `fd int` field defaults to 0, vlib/os/file.c.v:21). That temporary is discarded. `fd: 0` only appears in the stdin/stdout/stderr constructors (vlib/os/file.c.v:159, 168, 177) and in the JS backend (vlib/os/file.js.v).

**3.** Routes from `http.get` to `net.dial_tcp`. Shared head: `get` → `fetch` (vlib/net/http/http.v:71) → `Request.do` (vlib/net/http/http.v:251) → `method_and_url_to_response` (vlib/net/http/request.v:295). Then four branches:

*Default build (mbedtls) routes:*
1. Pooled plain HTTP: request.v:387 `Transport.round_trip` (transport.v:708) → transport.v:757 `dial_h1_tcp` → transport.v:791 `net.dial_tcp`
2. Reuse disabled, plain HTTP: request.v:411 `Request.http_do` (request.v:528) → request.v:531 `net.dial_tcp`
3. Proxy, http: request.v:421 `HttpProxy.http_do` (http_proxy.v:150) → http_proxy.v:173 `dial` (http_proxy.v:203) → http_proxy.v:204 `connect_tcp` (http_proxy.v:136) → http_proxy.v:138 `net.dial_tcp`
4. Proxy, https: request.v:421 `HttpProxy.http_do` → http_proxy.v:160 `ssl_dial` (http_proxy.v:207) → http_proxy.v:209 `connect_tcp` → http_proxy.v:138 `net.dial_tcp`

*Only with `-d use_openssl`* (the mbedtls `SSLConn.dial` at vlib/net/mbedtls/ssl_connection.c.v:827 calls `mbedtls_net_connect`, not `net.dial_tcp`):
5. request.v:400 `ssl_do` (vlib/net/http/backend.c.v:9) → backend.c.v:15 `net_ssl_do` → backend.c.v:39 `SSLConn.dial` → vlib/net/openssl/ssl_connection.c.v:336 `net.dial_tcp`
6. transport.v:708 `round_trip` → transport.v:755 `tls_fresh_round_trip` (transport.v:805) → transport.v:809 `tls_fresh_round_trip_ssl` → transport.v:822 `SSLConn.dial` → openssl ssl_connection.c.v:336
7. `round_trip` → transport.v:742 `h2_round_trip` (vlib/net/http/transport_h2.v:52) → transport_h2.v:83 or :104 `h2_dial_and_do` (transport_h2.v:216) → transport_h2.v:265 `h2_dial_probe` (transport_h2.v:152) → transport_h2.v:156 `h2_dial_probe_ssl` (transport_h2.v:161) → transport_h2.v:170 `SSLConn.dial` → openssl ssl_connection.c.v:336
8. Same as 7 with transport_h2.v:83 replaced by :104 (the call of `h2_dial_and_do` from `h2_round_trip`).
9–24. `round_trip` → transport.v:742 → `h2_round_trip` → transport_h2.v:83 or :104 → `h2_dial_and_do`, then one of:
   - (a) transport_h2.v:220 `h2_await_dial` (transport_h2.v:452) → transport_h2.v:469 `h2_fallback_h1` (transport_h2.v:197)
   - (b) transport_h2.v:259 `h2_await_dial` → transport_h2.v:469 `h2_fallback_h1`
   - (c) transport_h2.v:253 `h2_fallback_h1`
   - (d) transport_h2.v:314 `h2_fallback_h1`

   Then `h2_fallback_h1` → transport_h2.v:198 `h2_use_h1_pool_or_dial` (transport_h2.v:481) → transport_h2.v:484 or :495 `tls_fresh_round_trip` (transport.v:805) → transport.v:809 → transport.v:822 `SSLConn.dial` → openssl ssl_connection.c.v:336. That is 2 call sites × 4 entries × 2 → 16 routes.

Not traced: the Windows-only vschannel branches.

**4.** Non-test calls of `net.TcpConn.write_string`:
- vlib/veb/veb.v:1103, in `send_string` (veb.v:1093)
- vlib/veb/veb_livereload.v:144, in `LivereloadHub.add` (veb_livereload.v:130)
- vlib/veb/veb_livereload.v:166, in `LivereloadHub.send` (veb_livereload.v:161)
- vlib/veb/veb_livereload.v:289, in `Context.handle_veb_livereload_events` (veb_livereload.v:281; `ctx.conn` is `&net.TcpConn` per vlib/veb/context.v:86)
- vlib/net/pop/pop.v:138, in `Client.send_cmd` (pop.v:134; `conn` is `&net.TcpConn`, pop.v:22)
- vlib/net/http/http_proxy.v:176, in `HttpProxy.http_do` (http_proxy.v:150; `client` from `pr.dial`, http_proxy.v:173)

Excluded: vlib/net/http/backend.c.v:125 and :147 (`ssl.SSLConn`), and the `write_string` methods of other types.

**5.** Direct calls from `os.cp_all` (vlib/os/os.v:71–115):
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
- `cp_all` (recursive): os.v:110

**6.** Method calls in `http.Server.listen_and_serve` (vlib/net/http/server.v:73–135):
- vlib/net/http/server.v:79, `s.listen_and_serve_tls()`, receiver `http.Server`. Declaration: vlib/net/http/server_tls_notd_use_openssl.v:46 (default build), or vlib/net/http/server_tls_d_use_openssl.v:11 (`-d use_openssl`).
- vlib/net/http/server.v:92, `s.listener.addr()`, receiver `net.TcpListener`. Declaration: vlib/net/tcp.c.v:661.
- vlib/net/http/server.v:96, `l.str()`, receiver `net.Addr`. Declaration: vlib/net/address.c.v:305.
- vlib/net/http/server.v:98, `s.listener.set_accept_timeout(...)`, receiver `net.TcpListener`. Declaration: vlib/net/tcp.c.v:649.
- vlib/net/http/server.v:119, `s.listener.accept_only()`, receiver `net.TcpListener`. Declaration: vlib/net/tcp.c.v:593.
- vlib/net/http/server.v:120, `err.code()`, receiver `IError`. Declaration: vlib/builtin/chan_option_result.v:38.
- vlib/net/http/server.v:128, `conn.set_read_timeout(...)`, receiver `&net.TcpConn`. Declaration: vlib/net/tcp.c.v:348.
- vlib/net/http/server.v:129, `conn.set_write_timeout(...)`, receiver `&net.TcpConn`. Declaration: vlib/net/tcp.c.v:377.
- vlib/net/http/server.v:133, `s.close()`, receiver `http.Server`. Declaration: vlib/net/http/server.v:149.

Excluded: the free functions `net.listen_tcp`, `new_handler_worker`, `flush_stdout`, `eprintln`, `time.sleep`, and the function-typed field call `s.on_running(mut s)` at server.v:116.

**7.** Errors mentioning a redirect in vlib/net/http:
- vlib/net/http/request.v:293, "maximum number of redirects reached"
- vlib/net/http/request.v:314, "invalid URL in redirect"
- vlib/net/http/request.v:319, "invalid URL in redirect"

**8.** Functions in vlib that call `net.dial_tcp` directly (non-test):
- vlib/net/tcp.c.v:17, `TCPDialer.dial` (unqualified `dial_tcp`)
- vlib/db/redis/dial.c.v:8, `dial_connection`
- vlib/net/openssl/ssl_connection.c.v:336, `SSLConn.dial`
- vlib/net/socks/socks5.v:20, `socks5_dial`
- vlib/net/smtp/smtp.v:127, `Client.reconnect`
- vlib/net/imap/imap.v:161, `Client.connect`
- vlib/net/pop/pop.v:54, `dial`
- vlib/net/ftp/ftp.v:113, `FTP.connect`
- vlib/net/ftp/ftp.v:204, `new_dtp`
- vlib/net/websocket/io.v:77, `Client.dial_socket`
- vlib/net/http/http_proxy.v:138, `HttpProxy.connect_tcp`
- vlib/net/http/transport.v:791, `Transport.dial_h1_tcp`
- vlib/net/http/request.v:531, `Request.http_do`