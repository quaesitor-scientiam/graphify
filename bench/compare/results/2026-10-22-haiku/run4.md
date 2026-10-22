**1.** 15 method calls of `wait_for_read` in non-test vlib/net code. Free-function calls are excluded, and so is the commented-out call at `vlib/net/mbedtls/ssl_connection.c.v:903`.
- `vlib/net/tcp.c.v:198`, receiver `TcpConn`, in `read_ptr`
- `vlib/net/tcp.c.v:224`, receiver `TcpConn`, in `read_ptr`
- `vlib/net/udp.c.v:125`, receiver `UdpConn`, in `read_ptr`
- `vlib/net/udp.c.v:134`, receiver `UdpConn`, in `read_ptr`
- `vlib/net/raw.c.v:126`, receiver `RawConn`, in `read_ptr`
- `vlib/net/unix/stream.c.v:142`, receiver `StreamConn`, in `read_ptr`
- `vlib/net/mbedtls/ssl_connection.c.v:443`, receiver `SSLConn`, in `do_handshake_loop`
- `vlib/net/mbedtls/ssl_connection.c.v:916`, receiver `SSLConn`, in `socket_read_into_ptr`
- `vlib/net/mbedtls/ssl_connection.c.v:997`, receiver `SSLConn`, in `write_ptr`
- `vlib/net/openssl/ssl_connection.c.v:132`, receiver `SSLConn`, in `shutdown`
- `vlib/net/openssl/ssl_connection.c.v:374`, receiver `SSLConn`, in `complete_connect`
- `vlib/net/openssl/ssl_connection.c.v:396`, receiver `SSLConn`, in `complete_connect`
- `vlib/net/openssl/ssl_connection.c.v:468`, receiver `SSLConn`, in `socket_read_into_ptr`
- `vlib/net/openssl/ssl_connection.c.v:538`, receiver `SSLConn`, in `write_ptr`
- `vlib/net/openssl/ssl_listener.c.v:216`, receiver `SSLConn`, in `accept_handshake`

**2.** The premise is false. On Unix, `open_append` does not return `fd` 0.
- `vlib/os/os.c.v:1262-1266` builds the returned `File` with `fd: fileno(file.cfile)` at `vlib/os/os.c.v:1264`.
- `vlib/os/os.c.v:371-378` defines `fileno`. On non-Windows it returns `C.fileno(...)` (`vlib/os/os.c.v:377`), which is the real descriptor of the opened `FILE*`.
- The only Unix `fd: 0` is in `stdin()` at `vlib/os/file.c.v:159`. The other is `vlib/os/file.js.v:63`, which belongs to the JS backend.

**3.** There are 17 routes from `http.get` to `net.dial_tcp`. Each line is a call site, given as file:line of the caller, then the callee. Every route shares the prefix `vlib/net/http/http.v:71` (get→fetch), `vlib/net/http/http.v:251` (fetch→do), `vlib/net/http/request.v:295` (do→method_and_url_to_response). The `[use_openssl]`, `[windows]` and `[cross]` notes give the build each route needs.
1. `request.v:411` →`http_do` (`request.v:528`); `request.v:531` →`dial_tcp`
2. `request.v:387` →`round_trip` (`transport.v:708`); `transport.v:757` →`dial_h1_tcp` (`transport.v:790`); `transport.v:791` →`dial_tcp`
3. `request.v:421` →`http_do` (`http_proxy.v:150`); `http_proxy.v:160` →`ssl_dial` (`http_proxy.v:207`); `http_proxy.v:209` →`connect_tcp` (`http_proxy.v:136`); `http_proxy.v:138` →`dial_tcp`
4. `request.v:421` →`http_do`; `http_proxy.v:173` →`dial` (`http_proxy.v:203`); `http_proxy.v:204` →`connect_tcp`; `http_proxy.v:138` →`dial_tcp`
5. `request.v:421` →`http_do`; `http_proxy.v:160` →`ssl_dial`; `http_proxy.v:209` →`connect_tcp`; `http_proxy.v:144` →`socks5_dial` (`vlib/net/socks/socks5.v:19`); `socks5.v:20` →`dial_tcp`
6. `request.v:421` →`http_do`; `http_proxy.v:160` →`ssl_dial`; `http_proxy.v:224` →`socks5_ssl_dial` (`socks5.v:27`); `socks5.v:35` →`socks5_dial`; `socks5.v:20` →`dial_tcp`
7. `request.v:421` →`http_do`; `http_proxy.v:173` →`dial`; `http_proxy.v:204` →`connect_tcp`; `http_proxy.v:144` →`socks5_dial`; `socks5.v:20` →`dial_tcp`
8. `request.v:400` →`ssl_do` (`vlib/net/http/backend.c.v:9`); `backend.c.v:15` →`net_ssl_do` (`backend.c.v:18`); `backend.c.v:39` →`dial` (`vlib/net/openssl/ssl_connection.c.v:329`); `ssl_connection.c.v:336` →`dial_tcp` [use_openssl]
9. `request.v:387` →`round_trip`; `transport.v:755` →`tls_fresh_round_trip` (`transport.v:805`); `transport.v:809` →`tls_fresh_round_trip_ssl` (`transport.v:812`); `transport.v:822` →`dial`; `ssl_connection.c.v:336` →`dial_tcp` [use_openssl]
10. `request.v:400` →`ssl_do`; `backend.c.v:12` →`vschannel_retry_handshake` (`vlib/net/http/vschannel_handshake.v:28`); `vschannel_handshake.v:32` →`net_ssl_do`; `backend.c.v:39` →`dial`; `ssl_connection.c.v:336` →`dial_tcp` [windows, use_openssl]
11. `request.v:387` →`round_trip`; `transport.v:755` →`tls_fresh_round_trip`; `transport.v:807` →`vschannel_fresh_round_trip` (`vlib/net/http/vschannel_pooled_transport_windows.c.v:261`, cross stub `backend_vschannel_d_cross.v:11`); `vschannel_pooled_transport_windows.c.v:270` →`tls_fresh_round_trip_ssl`; `transport.v:822` →`dial`; `ssl_connection.c.v:336` →`dial_tcp` [windows, use_openssl]
12. `request.v:387` →`round_trip`; `transport.v:742` →`h2_round_trip` (`vlib/net/http/transport_h2.v:52`); `transport_h2.v:83` (or `:104`) →`h2_dial_and_do` (`transport_h2.v:216`); `transport_h2.v:265` →`h2_dial_probe` (`transport_h2.v:152`); `transport_h2.v:156` →`h2_dial_probe_ssl` (`transport_h2.v:161`); `transport_h2.v:170` →`dial`; `ssl_connection.c.v:336` →`dial_tcp` [use_openssl]
13. As 12 up to `transport_h2.v:152`; `transport_h2.v:154` →`h2_dial_probe_vschannel` (`backend_vschannel_d_cross.v:7`, Windows body `vschannel_pooled_transport_windows.c.v:206`); `vschannel_pooled_transport_windows.c.v:226` →`h2_dial_probe_ssl`; `transport_h2.v:170` →`dial`; `ssl_connection.c.v:336` →`dial_tcp` [windows, use_openssl]
14. `request.v:387` →`round_trip`; `transport.v:742` →`h2_round_trip`; `transport_h2.v:83` →`h2_dial_and_do`; `transport_h2.v:253` (or `:314`) →`h2_fallback_h1` (`transport_h2.v:197`); `transport_h2.v:198` →`h2_use_h1_pool_or_dial` (`transport_h2.v:481`); `transport_h2.v:484` (or `:495`) →`tls_fresh_round_trip`; `transport.v:809` →`tls_fresh_round_trip_ssl`; `transport.v:822` →`dial`; `ssl_connection.c.v:336` →`dial_tcp` [use_openssl]
15. As 14 to `h2_dial_and_do`; `transport_h2.v:220` (or `:259`) →`h2_await_dial` (`transport_h2.v:452`); `transport_h2.v:469` →`h2_fallback_h1`; then as 14 from `h2_use_h1_pool_or_dial` [use_openssl]
16. As 14 to `tls_fresh_round_trip`; `transport.v:807` →`vschannel_fresh_round_trip`; `vschannel_pooled_transport_windows.c.v:270` →`tls_fresh_round_trip_ssl`; `transport.v:822` →`dial`; `ssl_connection.c.v:336` →`dial_tcp` [windows, use_openssl]
17. As 15 to `h2_fallback_h1`; then as 16 from `h2_use_h1_pool_or_dial` [windows, use_openssl]

**4.** Six calls of `TcpConn.write_string` in non-test vlib code. The `backend.c.v` and `ssl_conn.write_string` calls are on `SSLConn`, and the `strings.Builder` calls are excluded.
- `vlib/veb/veb_livereload.v:144`, in `LivereloadHub.add`
- `vlib/veb/veb_livereload.v:166`, in `LivereloadHub.send`
- `vlib/veb/veb_livereload.v:289`, in `Context.handle_veb_livereload_events`
- `vlib/veb/veb.v:1103`, in `send_string`
- `vlib/net/pop/pop.v:138`, in `Client.send_cmd`
- `vlib/net/http/http_proxy.v:176`, in `HttpProxy.http_do`

**5.** `os.cp_all` (`vlib/os/os.v:71-115`) calls these functions directly, with the lines of each call:
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
- `cp_all` (recursive call on itself): 110
- `rmdir`: 111

**6.** Method calls in `Server.listen_and_serve` (`vlib/net/http/server.v:73-135`):
- Line 79, `s.listen_and_serve_tls()`, receiver `http.Server` (`server.v:31`). Declared at `vlib/net/http/server_tls_notd_use_openssl.v:46` (without use_openssl) and `vlib/net/http/server_tls_d_use_openssl.v:11` (with use_openssl).
- Line 92, `s.listener.addr()`, receiver `net.TcpListener`. Declared at `vlib/net/tcp.c.v:661`.
- Line 96, `l.str()`, receiver `net.Addr`. Declared at `vlib/net/address.c.v:305`.
- Line 98, `s.listener.set_accept_timeout(...)`, receiver `net.TcpListener`. Declared at `vlib/net/tcp.c.v:649`.
- Line 119, `s.listener.accept_only()`, receiver `net.TcpListener`. Declared at `vlib/net/tcp.c.v:593`.
- Line 120, `err.code()`, receiver `IError`. Declared at `vlib/builtin/chan_option_result.v:38` (the JS build has its own at `vlib/builtin/js/builtin.v:28`).
- Line 128, `conn.set_read_timeout(...)`, receiver `&net.TcpConn`. Declared at `vlib/net/tcp.c.v:348`.
- Line 129, `conn.set_write_timeout(...)`, receiver `&net.TcpConn`. Declared at `vlib/net/tcp.c.v:377`.
- Line 133, `s.close()`, receiver `http.Server`. Declared at `vlib/net/http/server.v:149`.

Not counted: the free functions `net.listen_tcp`, `new_handler_worker`, `time.sleep`, `flush_stdout` and `eprintln`, and the function-field call `s.on_running(mut s)` at line 116.

**7.** Three places in vlib/net/http return an error whose message mentions a redirect:
- `vlib/net/http/request.v:293`: `maximum number of redirects reached`
- `vlib/net/http/request.v:314`: `invalid URL in redirect`
- `vlib/net/http/request.v:319`: `invalid URL in redirect`

**8.** Thirteen functions in non-test vlib code call `net.dial_tcp` directly, one call each:
- `vlib/net/tcp.c.v:17`, in `TCPDialer.dial`
- `vlib/net/pop/pop.v:54`, in `dial`
- `vlib/net/imap/imap.v:161`, in `connect`
- `vlib/net/socks/socks5.v:20`, in `socks5_dial`
- `vlib/net/smtp/smtp.v:127`, in `reconnect`
- `vlib/net/openssl/ssl_connection.c.v:336`, in `SSLConn.dial`
- `vlib/net/http/http_proxy.v:138`, in `connect_tcp`
- `vlib/net/http/transport.v:791`, in `dial_h1_tcp`
- `vlib/net/http/request.v:531`, in `http_do`
- `vlib/net/ftp/ftp.v:113`, in `connect`
- `vlib/net/ftp/ftp.v:204`, in `new_dtp`
- `vlib/net/websocket/io.v:77`, in `dial_socket`
- `vlib/db/redis/dial.c.v:8`, in `dial_connection`