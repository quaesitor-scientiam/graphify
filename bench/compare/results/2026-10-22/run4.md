**1. Calls of a `wait_for_read` method in vlib/net**
- `vlib/net/tcp.c.v:198`: `c.wait_for_read()!` in `TcpConn.read_ptr`, calls `TcpConn.wait_for_read` (tcp.c.v:382)
- `vlib/net/tcp.c.v:224`: `c.wait_for_read()!` in `TcpConn.read_ptr`, calls `TcpConn.wait_for_read`
- `vlib/net/udp.c.v:125`: `c.wait_for_read()!` in `UdpConn.read_ptr`, calls `UdpConn.wait_for_read` (udp.c.v:191)
- `vlib/net/udp.c.v:134`: `c.wait_for_read()!` in `UdpConn.read_ptr`, calls `UdpConn.wait_for_read`
- `vlib/net/raw.c.v:126`: `c.wait_for_read()!` in `RawConn.read_ptr`, calls `RawConn.wait_for_read` (raw.c.v:190)
- `vlib/net/unix/stream.c.v:142`: `c.wait_for_read()!` in `StreamConn.read_ptr`, calls `StreamConn.wait_for_read` (unix/stream.c.v:217)
- `vlib/net/mbedtls/ssl_connection.c.v:443`: `conn.wait_for_read(...)` in `do_handshake_loop`, calls mbedtls `SSLConn.wait_for_read` (ssl_connection.c.v:1121)
- `vlib/net/mbedtls/ssl_connection.c.v:916`: `s.wait_for_read(...)` in `SSLConn.socket_read_into_ptr`, calls mbedtls `SSLConn.wait_for_read`
- `vlib/net/mbedtls/ssl_connection.c.v:997`: `s.wait_for_read(...)` in `SSLConn.write_ptr`, calls mbedtls `SSLConn.wait_for_read`
- `vlib/net/openssl/ssl_connection.c.v:132`: in `SSLConn.shutdown`, calls openssl `SSLConn.wait_for_read` (ssl_connection.c.v:666)
- `vlib/net/openssl/ssl_connection.c.v:374`: in `SSLConn.complete_connect`, calls openssl `SSLConn.wait_for_read`
- `vlib/net/openssl/ssl_connection.c.v:396`: in `SSLConn.complete_connect`, calls openssl `SSLConn.wait_for_read`
- `vlib/net/openssl/ssl_connection.c.v:468`: in `SSLConn.socket_read_into_ptr`, calls openssl `SSLConn.wait_for_read`
- `vlib/net/openssl/ssl_connection.c.v:538`: in `SSLConn.write_ptr`, calls openssl `SSLConn.wait_for_read`
- `vlib/net/openssl/ssl_listener.c.v:216`: `conn.wait_for_read(timeout)!` in `accept_handshake`, calls openssl `SSLConn.wait_for_read`

Left out: `vlib/net/mbedtls/ssl_connection.c.v:903` is commented out. Test-file calls are out of scope.

**2. Why `os.open_append` would return a File with `fd` 0 on Unix**
At this commit, `open_append` does not leave `fd` at 0 on Unix. The question's premise doesn't hold for this code.
- `vlib/os/os.c.v:1246`: `mut file := File{}` starts with a zero-valued `File`, so its `fd` is 0 (the field is declared at `vlib/os/file.c.v:21`). This temporary value is not what gets returned.
- `vlib/os/os.c.v:1254-1257`: on Unix, only `cfile` is set, from `C.fopen(&char(cpath), c'ab')`.
- `vlib/os/os.c.v:1263-1267`: a new `File` is returned with `fd: fileno(file.cfile)` (line 1264) and `is_opened: true`.
- `vlib/os/os.c.v:371-379`: `fileno` calls `C.fileno(...)` on Unix (line 377). `C.fileno` is declared at `vlib/builtin/cfns.c.v:144`.

So the returned `fd` is the real descriptor of the `FILE*`. It is 0 only if `fopen` actually got descriptor 0, which happens when stdin was closed beforehand, because POSIX hands out the lowest free number. The only place in os that hard-codes `fd: 0` is `stdin()` at `vlib/os/file.c.v:159`. In older versions of `open_append` the returned `File` had only `cfile` and `is_opened` set, so `fd` was left at its default of 0.

**3. Routes from `http.get` to `net.dial_tcp`**
All 17 routes share the same first steps: `get` (vlib/net/http/http.v:70) → `fetch` at http.v:71 → `Request.do` (request.v:281) at http.v:251 → `method_and_url_to_response` (request.v:366) at request.v:295. Each route below continues from there.

Routes 1–7 need no build flags:
1. → `http_do` (request.v:528) at request.v:411 → `net.dial_tcp` (vlib/net/tcp.c.v:48) at request.v:531
2. → `round_trip` (transport.v:708) at request.v:387 → `dial_h1_tcp` (transport.v:790) at transport.v:757 → `dial_tcp` at transport.v:791
3. → proxy `http_do` (http_proxy.v:150) at request.v:421 → `ssl_dial` (http_proxy.v:207) at http_proxy.v:160 → `connect_tcp` (http_proxy.v:136) at http_proxy.v:209 → `dial_tcp` at http_proxy.v:138
4. → proxy `http_do` at request.v:421 → proxy `dial` (http_proxy.v:203) at http_proxy.v:173 → `connect_tcp` at http_proxy.v:204 → `dial_tcp` at http_proxy.v:138
5. → proxy `http_do` at request.v:421 → `ssl_dial` at http_proxy.v:160 → `connect_tcp` at http_proxy.v:209 → `socks5_dial` (vlib/net/socks/socks5.v:19) at http_proxy.v:144 → `dial_tcp` at socks5.v:20
6. → proxy `http_do` at request.v:421 → `ssl_dial` at http_proxy.v:160 → `socks5_ssl_dial` (socks5.v:27) at http_proxy.v:224 → `socks5_dial` at socks5.v:35 → `dial_tcp` at socks5.v:20
7. → proxy `http_do` at request.v:421 → proxy `dial` at http_proxy.v:173 → `connect_tcp` at http_proxy.v:204 → `socks5_dial` at http_proxy.v:144 → `dial_tcp` at socks5.v:20

Routes 8–17 need `-d use_openssl`. Routes 10, 11, 13, 16 and 17 also need Windows with vschannel enabled.

8. → `ssl_do` (backend.c.v:9) at request.v:400 → `net_ssl_do` (backend.c.v:18) at backend.c.v:15 → openssl `SSLConn.dial` (vlib/net/openssl/ssl_connection.c.v:329) at backend.c.v:39 → `dial_tcp` at ssl_connection.c.v:336
9. → `round_trip` at request.v:387 → `tls_fresh_round_trip` (transport.v:805) at transport.v:755 → `tls_fresh_round_trip_ssl` (transport.v:812) at transport.v:809 → `SSLConn.dial` at transport.v:822 → `dial_tcp` at ssl_connection.c.v:336
10. → `ssl_do` at request.v:400 → `vschannel_retry_handshake` (vschannel_handshake.v:28) at backend.c.v:12 → `net_ssl_do` at vschannel_handshake.v:32 → `SSLConn.dial` at backend.c.v:39 → `dial_tcp` at ssl_connection.c.v:336
11. → `round_trip` at request.v:387 → `tls_fresh_round_trip` at transport.v:755 → `vschannel_fresh_round_trip` (backend_vschannel_d_cross.v:11) at transport.v:807 → `tls_fresh_round_trip_ssl` at backend_vschannel_d_cross.v:270 → `SSLConn.dial` at transport.v:822 → `dial_tcp` at ssl_connection.c.v:336
12. → `round_trip` at request.v:387 → `h2_round_trip` (transport_h2.v:52) at transport.v:742 → `h2_dial_and_do` (transport_h2.v:216) at transport_h2.v:83, 104 → `h2_dial_probe` (transport_h2.v:152) at transport_h2.v:265 → `h2_dial_probe_ssl` (transport_h2.v:161) at transport_h2.v:156 → `SSLConn.dial` at transport_h2.v:170 → `dial_tcp` at ssl_connection.c.v:336
13. Same as route 12 up to `h2_dial_probe`, then → `h2_dial_probe_vschannel` (backend_vschannel_d_cross.v:7) at transport_h2.v:154 → `h2_dial_probe_ssl` at backend_vschannel_d_cross.v:226 → `SSLConn.dial` at transport_h2.v:170 → `dial_tcp` at ssl_connection.c.v:336
14. → `round_trip` at request.v:387 → `h2_round_trip` at transport.v:742 → `h2_dial_and_do` at transport_h2.v:83, 104 → `h2_fallback_h1` (transport_h2.v:197) at transport_h2.v:253, 314 → `h2_use_h1_pool_or_dial` (transport_h2.v:481) at transport_h2.v:198 → `tls_fresh_round_trip` at transport_h2.v:484, 495 → `tls_fresh_round_trip_ssl` at transport.v:809 → `SSLConn.dial` at transport.v:822 → `dial_tcp` at ssl_connection.c.v:336
15. Same as route 14, except `h2_dial_and_do` → `h2_await_dial` (transport_h2.v:452) at transport_h2.v:220, 259 → `h2_fallback_h1` at transport_h2.v:469 → … then the rest of route 14
16. Same as route 14, except `tls_fresh_round_trip` → `vschannel_fresh_round_trip` at transport.v:807 → `tls_fresh_round_trip_ssl` at backend_vschannel_d_cross.v:270 → `SSLConn.dial` at transport.v:822 → `dial_tcp` at ssl_connection.c.v:336
17. Same as route 15, except `tls_fresh_round_trip` → `vschannel_fresh_round_trip` at transport.v:807 → `tls_fresh_round_trip_ssl` at backend_vschannel_d_cross.v:270 → `SSLConn.dial` at transport.v:822 → `dial_tcp` at ssl_connection.c.v:336

All paths above are under vlib/net/http/ unless shown otherwise.

**4. Calls of `net.TcpConn.write_string` (non-test vlib)**
- `vlib/net/http/http_proxy.v:176`: in `HttpProxy.http_do`
- `vlib/net/pop/pop.v:138`: in `Client.send_cmd`
- `vlib/veb/veb_livereload.v:144`: in `LivereloadHub.add`
- `vlib/veb/veb_livereload.v:166`: in `LivereloadHub.send`
- `vlib/veb/veb_livereload.v:289`: in `Context.handle_veb_livereload_events`
- `vlib/veb/veb.v:1103`: in `send_string`

**5. Functions `os.cp_all` calls directly (vlib/os/os.v:71)**
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
- `cp_all` (recursive): line 110
- `rmdir`: line 111

**6. Method calls in `http.Server.listen_and_serve` (vlib/net/http/server.v)**
- Line 79: `s.listen_and_serve_tls()`, receiver `http.Server`. Declared at `vlib/net/http/server_tls_notd_use_openssl.v:46`, or at `vlib/net/http/server_tls_d_use_openssl.v:11` with `-d use_openssl`.
- Line 92: `s.listener.addr()`, receiver `net.TcpListener`, declared at `vlib/net/tcp.c.v:661`
- Line 96: `l.str()`, receiver `net.Addr`, declared at `vlib/net/address.c.v:305`
- Line 98: `s.listener.set_accept_timeout(...)`, receiver `net.TcpListener`, declared at `vlib/net/tcp.c.v:649`
- Line 116: `s.on_running(mut s)` calls a function-typed field of `Server` (declared at `vlib/net/http/server.v:64`), not a method.
- Line 119: `s.listener.accept_only()`, receiver `net.TcpListener`, declared at `vlib/net/tcp.c.v:593`
- Line 120: `err.code()`, receiver `IError`, declared at `vlib/builtin/chan_option_result.v:38`
- Line 128: `conn.set_read_timeout(...)`, receiver `net.TcpConn`, declared at `vlib/net/tcp.c.v:348`
- Line 129: `conn.set_write_timeout(...)`, receiver `net.TcpConn`, declared at `vlib/net/tcp.c.v:377`
- Line 133: `s.close()`, receiver `http.Server`, declared at `vlib/net/http/server.v:149`

**7. Errors in vlib/net/http whose message mentions a redirect**
- `vlib/net/http/request.v:293`: `return error('http.request.do: maximum number of redirects reached (${max_redirects})')`
- `vlib/net/http/request.v:314`: `return error('http.request.do: invalid URL in redirect "${redirect_url}"')`
- `vlib/net/http/request.v:319`: `return error('http.request.do: invalid URL in redirect "${redirect_url}"')`

**8. Functions in vlib that call `net.dial_tcp` directly (non-test)**
- `net.TCPDialer.dial`: `vlib/net/tcp.c.v:17`
- `redis.dial_connection`: `vlib/db/redis/dial.c.v:8`
- `openssl.SSLConn.dial`: `vlib/net/openssl/ssl_connection.c.v:336`
- `socks.socks5_dial`: `vlib/net/socks/socks5.v:20`
- `smtp.Client.reconnect`: `vlib/net/smtp/smtp.v:127`
- `http.HttpProxy.connect_tcp`: `vlib/net/http/http_proxy.v:138`
- `http.http_do`: `vlib/net/http/request.v:531`
- `http.dial_h1_tcp`: `vlib/net/http/transport.v:791`
- `imap.Client.connect`: `vlib/net/imap/imap.v:161`
- `pop.dial`: `vlib/net/pop/pop.v:54`
- `websocket.Client.dial_socket`: `vlib/net/websocket/io.v:77`
- `ftp.FTP.connect`: `vlib/net/ftp/ftp.v:113`
- `ftp.FTP.new_dtp`: `vlib/net/ftp/ftp.v:204`