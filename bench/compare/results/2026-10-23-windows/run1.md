**1. Calls of a `wait_for_read` method in vlib/net**
- vlib/net/raw.c.v:126 (`c.wait_for_read()`, RawConn)
- vlib/net/tcp.c.v:198 (TcpConn)
- vlib/net/tcp.c.v:224 (TcpConn)
- vlib/net/udp.c.v:125 (UdpConn)
- vlib/net/udp.c.v:134 (UdpConn)
- vlib/net/unix/stream.c.v:142 (StreamConn)
- vlib/net/mbedtls/ssl_connection.c.v:445 (SSLConn)
- vlib/net/mbedtls/ssl_connection.c.v:902 (SSLConn)
- vlib/net/mbedtls/ssl_connection.c.v:983 (SSLConn)
- vlib/net/openssl/ssl_connection.c.v:132 (SSLConn)
- vlib/net/openssl/ssl_connection.c.v:374 (SSLConn)
- vlib/net/openssl/ssl_connection.c.v:396 (SSLConn)
- vlib/net/openssl/ssl_connection.c.v:468 (SSLConn)
- vlib/net/openssl/ssl_connection.c.v:538 (SSLConn)
- vlib/net/openssl/ssl_listener.c.v:216 (`conn.wait_for_read(timeout)`, SSLConn)

Left out: vlib/net/mbedtls/ssl_connection.c.v:889 is commented out. The free-function calls are also left out: vlib/net/raw.c.v:191, vlib/net/tcp.c.v:383, vlib/net/tcp.c.v:654, vlib/net/udp.c.v:192, vlib/net/unix/stream.c.v:218 and vlib/net/unix/stream.c.v:346.

**2. Why `os.open_append`'s `fd` is 0 on Unix**
In this tree it isn't 0. The question's premise doesn't hold here.
- vlib/os/os.c.v:1245: `open_append` is declared. At vlib/os/os.c.v:1246, `mut file := File{}` starts with the default `fd` of 0 (field declared at vlib/os/file.c.v:21).
- vlib/os/os.c.v:1253–1257: on Unix, `file` is rebuilt with only `cfile: C.fopen(&char(cpath), c'ab')`, so `fd` stays 0 in that temporary value.
- vlib/os/os.c.v:1262–1266: the File actually returned sets `fd: fileno(file.cfile)` (line 1264) and `is_opened: true`.
- vlib/os/os.c.v:371–378: `fileno` calls `C.fileno(&C.FILE(cfile))` on Unix (line 377), which gives the real descriptor.

So the returned `fd` is 0 only if `fopen` really got descriptor 0, which needs stdin to be closed. The 0 seen in the intermediate `file` (lines 1246 and 1255–1257) never reaches the caller. Older versions of this function returned that intermediate `file` directly, without setting `fd`. That is where a 0 `fd` came from.

**3. Routes from `http.get` to `net.dial_tcp`**
Every route starts with the same four calls:
- `get` (vlib/net/http/http.v:70) calls `fetch` at http.v:71
- `fetch` calls `Request.do` at http.v:251
- `do` calls `method_and_url_to_response` at vlib/net/http/request.v:307
- below this is called **M**

There are 17 routes:
1. M → `Request.http_do` at request.v:426 → `net.dial_tcp` at request.v:546
2. M → `Transport.round_trip` at request.v:402 → `dial_h1_tcp` at transport.v:757 → `dial_tcp` at transport.v:792
3. M → `HttpProxy.http_do` at request.v:436 → `ssl_dial` at http_proxy.v:160 → `connect_tcp` at http_proxy.v:209 → `dial_tcp` at http_proxy.v:138
4. M → `HttpProxy.http_do` at request.v:436 → `HttpProxy.dial` at http_proxy.v:173 → `connect_tcp` at http_proxy.v:204 → `dial_tcp` at http_proxy.v:138
5. M → `HttpProxy.http_do` at request.v:436 → `ssl_dial` at http_proxy.v:160 → `connect_tcp` at http_proxy.v:209 → `socks.socks5_dial` at http_proxy.v:144 → `dial_tcp` at vlib/net/socks/socks5.v:20
6. M → `HttpProxy.http_do` at request.v:436 → `ssl_dial` at http_proxy.v:160 → `socks5_ssl_dial` at http_proxy.v:224 → `socks5_dial` at socks5.v:35 → `dial_tcp` at socks5.v:20
7. M → `HttpProxy.http_do` at request.v:436 → `HttpProxy.dial` at http_proxy.v:173 → `connect_tcp` at http_proxy.v:204 → `socks5_dial` at http_proxy.v:144 → `dial_tcp` at socks5.v:20
8. M → `Request.ssl_do` at request.v:415 → `net_ssl_do` at backend.c.v:15 → `openssl SSLConn.dial` at backend.c.v:39 → `dial_tcp` at vlib/net/openssl/ssl_connection.c.v:336 (needs `use_openssl`)
9. M → `round_trip` at request.v:402 → `tls_fresh_round_trip` at transport.v:755 → `tls_fresh_round_trip_ssl` at transport.v:810 → `SSLConn.dial` at transport.v:823 → `dial_tcp` at ssl_connection.c.v:336 (needs `use_openssl`)
10. M → `ssl_do` at request.v:415 → `vschannel_retry_handshake` at backend.c.v:12 → `net_ssl_do` at vschannel_handshake.v:32 → `SSLConn.dial` at backend.c.v:39 → `dial_tcp` at ssl_connection.c.v:336 (needs windows, no vschannel disable, and `use_openssl`)
11. M → `round_trip` at request.v:402 → `tls_fresh_round_trip` at transport.v:755 → `vschannel_fresh_round_trip` at transport.v:808 → `tls_fresh_round_trip_ssl` at vschannel_pooled_transport_windows.c.v:270 → `SSLConn.dial` at transport.v:823 → `dial_tcp` at ssl_connection.c.v:336 (needs windows and `use_openssl`)
12. M → `round_trip` at request.v:402 → `h2_round_trip` at transport.v:742 → `h2_dial_and_do` at transport_h2.v:83 and 104 → `h2_dial_probe` at transport_h2.v:265 → `h2_dial_probe_ssl` at transport_h2.v:156 → `SSLConn.dial` at transport_h2.v:170 → `dial_tcp` at ssl_connection.c.v:336 (needs `use_openssl`)
13. Same as 12 down to `h2_dial_probe` → `h2_dial_probe_vschannel` at transport_h2.v:154 → `h2_dial_probe_ssl` at vschannel_pooled_transport_windows.c.v:226 → `SSLConn.dial` at transport_h2.v:170 → `dial_tcp` at ssl_connection.c.v:336 (needs windows and `use_openssl`)
14. M → `round_trip` at request.v:402 → `h2_round_trip` at transport.v:742 → `h2_dial_and_do` at transport_h2.v:83 and 104 → `h2_fallback_h1` at transport_h2.v:253 and 314 → `h2_use_h1_pool_or_dial` at transport_h2.v:198 → `tls_fresh_round_trip` at transport_h2.v:484 and 495 → `tls_fresh_round_trip_ssl` at transport.v:810 → `SSLConn.dial` at transport.v:823 → `dial_tcp` at ssl_connection.c.v:336 (needs `use_openssl`)
15. Same as 14, except `h2_dial_and_do` → `h2_await_dial` at transport_h2.v:220 and 259 → `h2_fallback_h1` at transport_h2.v:469 → then as in 14 (needs `use_openssl`)
16. Same as 14, except `tls_fresh_round_trip` → `vschannel_fresh_round_trip` at transport.v:808 → `tls_fresh_round_trip_ssl` at vschannel_pooled_transport_windows.c.v:270 → `SSLConn.dial` at transport.v:823 → `dial_tcp` at ssl_connection.c.v:336 (needs windows and `use_openssl`)
17. Same as 15 with the vschannel step from 16: `h2_await_dial` → `h2_fallback_h1` at transport_h2.v:469 → `h2_use_h1_pool_or_dial` → `tls_fresh_round_trip` → `vschannel_fresh_round_trip` at transport.v:808 → `tls_fresh_round_trip_ssl` at vschannel_pooled_transport_windows.c.v:270 → `SSLConn.dial` at transport.v:823 → `dial_tcp` at ssl_connection.c.v:336 (needs windows and `use_openssl`)

Routes 1–7 exist in the default build. The mbedtls `SSLConn.dial` never calls `dial_tcp`.

**4. Calls of `net.TcpConn.write_string`**
- vlib/net/http/http_proxy.v:176, in `HttpProxy.http_do`
- vlib/net/pop/pop.v:138, in `Client.send_cmd`
- vlib/veb/veb.v:1103, in `send_string`
- vlib/veb/veb_livereload.v:144, in `LivereloadHub.add`
- vlib/veb/veb_livereload.v:166, in `LivereloadHub.send`
- vlib/veb/veb_livereload.v:289, in `Context.handle_veb_livereload_events`

**5. Direct calls in `os.cp_all` (vlib/os/os.v:71)**
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
- `cp_all` (calls itself): line 110
- `rmdir`: line 111

**6. Method calls in `http.Server.listen_and_serve` (vlib/net/http/server.v:73)**

| Line | Call | Receiver type | Declaration |
|---|---|---|---|
| 79 | `s.listen_and_serve_tls()` | `http.Server` | vlib/net/http/server_tls_notd_use_openssl.v:46 (default); vlib/net/http/server_tls_d_use_openssl.v:11 under `-d use_openssl` |
| 92 | `s.listener.addr()` | `net.TcpListener` | vlib/net/tcp.c.v:661 |
| 96 | `l.str()` | `net.Addr` | vlib/net/address.c.v:305 |
| 98 | `s.listener.set_accept_timeout(...)` | `net.TcpListener` | vlib/net/tcp.c.v:649 |
| 116 | `s.on_running(mut s)` | `http.Server` | a call through the fn field `on_running`, declared at server.v:64 |
| 119 | `s.listener.accept_only()` | `net.TcpListener` | vlib/net/tcp.c.v:593 |
| 120 | `err.code()` | `IError` | vlib/builtin/chan_option_result.v:38 |
| 128 | `conn.set_read_timeout(...)` | `&net.TcpConn` | vlib/net/tcp.c.v:348 |
| 129 | `conn.set_write_timeout(...)` | `&net.TcpConn` | vlib/net/tcp.c.v:377 |
| 133 | `s.close()` | `http.Server` | vlib/net/http/server.v:149 |

**7. Errors in vlib/net/http whose message mentions a redirect**
- vlib/net/http/request.v:305: `error('http.request.do: maximum number of redirects reached (${max_redirects})')`
- vlib/net/http/request.v:329: `error('http.request.do: invalid URL in redirect "${redirect_url}"')`
- vlib/net/http/request.v:334: `error('http.request.do: invalid URL in redirect "${redirect_url}"')`

**8. Functions in vlib that call `net.dial_tcp` directly**
- `net.TCPDialer.dial`: vlib/net/tcp.c.v:17
- `db.redis.dial_connection`: vlib/db/redis/dial.c.v:8
- `ftp.FTP.connect`: vlib/net/ftp/ftp.v:113
- `ftp.new_dtp`: vlib/net/ftp/ftp.v:204
- `socks.socks5_dial`: vlib/net/socks/socks5.v:20
- `smtp.Client.reconnect`: vlib/net/smtp/smtp.v:127
- `imap.Client.connect`: vlib/net/imap/imap.v:161
- `websocket.Client.dial_socket`: vlib/net/websocket/io.v:77
- `pop.dial`: vlib/net/pop/pop.v:54
- `http.HttpProxy.connect_tcp`: vlib/net/http/http_proxy.v:138
- `http.Transport.dial_h1_tcp`: vlib/net/http/transport.v:792
- `http.Request.http_do`: vlib/net/http/request.v:546
- `openssl.SSLConn.dial`: vlib/net/openssl/ssl_connection.c.v:336

**Skeptical review**
- Q3: the routes come from the graph's call edges. Edges marked inferred (method dispatch by name) could miss an interface-dispatched path, such as a `net.Dialer` used inside http.
- Q4: I searched by receiver name and by files that mention `TcpConn`. A call through an oddly named variable, or an embedded or aliased TcpConn, could have been missed.
- Q6: `on_running` is a call through a fn field, not a true method. A key may leave it out. The `${err}` interpolations in the function call `str()` implicitly and are not listed.
- Q7: errors coming back from the user's `on_redirect` callback (request.v:338) are not counted, because their message is set by the user.

**Revised answer**
No change.
