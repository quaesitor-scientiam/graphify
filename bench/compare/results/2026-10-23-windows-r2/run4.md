**1. Calls of a `wait_for_read` method in vlib/net** (15 calls)
- vlib/net/unix/stream.c.v:142: `c.wait_for_read()`, receiver `unix.StreamConn`
- vlib/net/udp.c.v:125: `c.wait_for_read()`, receiver `UdpConn`
- vlib/net/udp.c.v:134: `c.wait_for_read()`, receiver `UdpConn`
- vlib/net/tcp.c.v:198: `c.wait_for_read()`, receiver `TcpConn`
- vlib/net/tcp.c.v:224: `c.wait_for_read()`, receiver `TcpConn`
- vlib/net/raw.c.v:126: `c.wait_for_read()`, receiver `RawConn`
- vlib/net/openssl/ssl_listener.c.v:216: `conn.wait_for_read(timeout)`, receiver `openssl.SSLConn`
- vlib/net/openssl/ssl_connection.c.v:132, 374, 396, 468, 538: `s.wait_for_read(...)`, receiver `openssl.SSLConn`
- vlib/net/mbedtls/ssl_connection.c.v:445: `conn.wait_for_read(...)`, receiver `mbedtls.SSLConn`
- vlib/net/mbedtls/ssl_connection.c.v:902, 983: `s.wait_for_read(...)`, receiver `mbedtls.SSLConn`

Left out: vlib/net/mbedtls/ssl_connection.c.v:889 is commented out. The free-function calls are also left out: tcp.c.v:383, 654; udp.c.v:192; raw.c.v:191; unix/stream.c.v:218, 346.

**2. `os.open_append` and `fd` 0 on Unix**
In this commit, `open_append` does not leave `fd` at 0:
- vlib/os/os.c.v:1246: `mut file := File{}` starts with `fd` at its zero value.
- vlib/os/os.c.v:1255-1257: on Unix it builds `File{ cfile: C.fopen(&char(cpath), c'ab') }` with only `cfile` set, so `fd` is still 0 there.
- vlib/os/os.c.v:1262-1266: but the value it returns is a new `File{ cfile: file.cfile, fd: fileno(file.cfile), is_opened: true }`.
- vlib/os/os.c.v:371-378: `fileno` calls `C.fileno` on Unix (377), which gives the real descriptor.
- vlib/os/file.c.v:21: `fd int` is a plain `pub:` field whose default is 0.

So `fd` is 0 only in the temporary `File` at 1246/1255. Older versions returned that `File{cfile: ...}` directly, without `fd:`, so `fd` kept its default of 0. Here the return at 1264 sets it.

**3. Routes from `http.get` to `net.dial_tcp`** (17 routes)
Every route starts with the same prefix P:
- `get` (vlib/net/http/http.v:70)
- → `fetch` @ vlib/net/http/http.v:71
- → `Request.do` @ vlib/net/http/http.v:251
- → `Request.method_and_url_to_response` @ vlib/net/http/request.v:307

After P:
1. → `Request.http_do` @ request.v:426 → `net.dial_tcp` @ request.v:546
2. → `Transport.round_trip` @ request.v:402 → `dial_h1_tcp` @ transport.v:757 → `dial_tcp` @ transport.v:792
3. → `HttpProxy.http_do` @ request.v:436 → `ssl_dial` @ http_proxy.v:160 → `connect_tcp` @ http_proxy.v:209 → `dial_tcp` @ http_proxy.v:138
4. → `HttpProxy.http_do` @ request.v:436 → `HttpProxy.dial` @ http_proxy.v:173 → `connect_tcp` @ http_proxy.v:204 → `dial_tcp` @ http_proxy.v:138
5. → `HttpProxy.http_do` @ 436 → `ssl_dial` @ http_proxy.v:160 → `connect_tcp` @ 209 → `socks.socks5_dial` @ http_proxy.v:144 → `dial_tcp` @ socks/socks5.v:20
6. → `HttpProxy.http_do` @ 436 → `ssl_dial` @ 160 → `socks.socks5_ssl_dial` @ http_proxy.v:224 → `socks5_dial` @ socks5.v:35 → `dial_tcp` @ socks5.v:20
7. → `HttpProxy.http_do` @ 436 → `HttpProxy.dial` @ 173 → `connect_tcp` @ 204 → `socks5_dial` @ http_proxy.v:144 → `dial_tcp` @ socks5.v:20
8. → `ssl_do` @ request.v:415 → `net_ssl_do` @ backend.c.v:15 → `openssl.SSLConn.dial` @ backend.c.v:39 → `dial_tcp` @ openssl/ssl_connection.c.v:336 (needs `-d use_openssl`)
9. → `round_trip` @ 402 → `tls_fresh_round_trip` @ transport.v:755 → `tls_fresh_round_trip_ssl` @ transport.v:810 → `SSLConn.dial` @ transport.v:823 → `dial_tcp` @ ssl_connection.c.v:336 (needs `use_openssl`)
10. → `ssl_do` @ 415 → `vschannel_retry_handshake` @ backend.c.v:12 → `net_ssl_do` @ vschannel_handshake.v:32 → `SSLConn.dial` @ backend.c.v:39 → `dial_tcp` @ ssl_connection.c.v:336 (needs windows, vschannel and `use_openssl`)
11. → `round_trip` @ 402 → `tls_fresh_round_trip` @ 755 → `vschannel_fresh_round_trip` @ transport.v:808 → `tls_fresh_round_trip_ssl` @ vschannel_pooled_transport_windows.c.v:270 → `SSLConn.dial` @ transport.v:823 → `dial_tcp` @ ssl_connection.c.v:336
12. → `round_trip` @ 402 → `h2_round_trip` @ transport.v:742 → `h2_dial_and_do` @ transport_h2.v:83/104 → `h2_dial_probe` @ transport_h2.v:265 → `h2_dial_probe_ssl` @ transport_h2.v:156 → `SSLConn.dial` @ transport_h2.v:170 → `dial_tcp` @ ssl_connection.c.v:336
13. Same as 12 up to `h2_dial_probe`, then → `h2_dial_probe_vschannel` @ transport_h2.v:154 → `h2_dial_probe_ssl` @ vschannel_pooled_transport_windows.c.v:226 → `SSLConn.dial` @ transport_h2.v:170 → `dial_tcp` @ 336
14. → `round_trip` @ 402 → `h2_round_trip` @ 742 → `h2_dial_and_do` @ 83/104 → `h2_fallback_h1` @ transport_h2.v:253/314 → `h2_use_h1_pool_or_dial` @ transport_h2.v:198 → `tls_fresh_round_trip` @ transport_h2.v:484/495 → `tls_fresh_round_trip_ssl` @ transport.v:810 → `SSLConn.dial` @ 823 → `dial_tcp` @ 336
15. Same as 14, but `h2_dial_and_do` → `h2_await_dial` @ transport_h2.v:220/259 → `h2_fallback_h1` @ transport_h2.v:469 → (rest as in 14)
16. Same as 14, but `tls_fresh_round_trip` → `vschannel_fresh_round_trip` @ transport.v:808 → `tls_fresh_round_trip_ssl` @ vschannel_pooled_transport_windows.c.v:270 → `SSLConn.dial` @ 823 → `dial_tcp` @ 336
17. Same as 15, with the vschannel step from 16.

Routes 1–7 exist in the default build; 8–17 need `-d use_openssl`, and some also need Windows with vschannel.

**4. Calls of `net.TcpConn.write_string` (non-test)** (6 calls)
- vlib/net/http/http_proxy.v:176, in `HttpProxy.http_do`
- vlib/net/pop/pop.v:138, in `pop.Client.send_cmd`
- vlib/veb/veb.v:1103, in `veb.send_string`
- vlib/veb/veb_livereload.v:144, in `LivereloadHub.add`
- vlib/veb/veb_livereload.v:166, in `LivereloadHub.send`
- vlib/veb/veb_livereload.v:289, in `Context.handle_veb_livereload_events`

**5. Functions `os.cp_all` calls directly** (vlib/os/os.v)
- `real_path`: 72, 73
- `exists`: 74, 85, 95, 106
- `error`: 75, 89, 99
- `is_dir`: 78, 80, 98, 105
- `file_name`: 79
- `join_path_single`: 81, 103, 104
- `rm`: 87
- `cp`: 92
- `mkdir`: 96, 107
- `ls`: 101
- `cp_all` (calls itself): 110
- `rmdir`: 111

**6. Method calls in `http.Server.listen_and_serve`** (vlib/net/http/server.v)
| Line | Call | Receiver type | Declaration it calls |
|---|---|---|---|
| 79 | `s.listen_and_serve_tls()` | `http.Server` | vlib/net/http/server_tls_notd_use_openssl.v:46 (with `-d use_openssl`: vlib/net/http/server_tls_d_use_openssl.v:11) |
| 92 | `s.listener.addr()` | `net.TcpListener` | vlib/net/tcp.c.v:661 |
| 96 | `l.str()` | `net.Addr` | vlib/net/address.c.v:305 |
| 98 | `s.listener.set_accept_timeout(...)` | `net.TcpListener` | vlib/net/tcp.c.v:649 |
| 119 | `s.listener.accept_only()` | `net.TcpListener` | vlib/net/tcp.c.v:593 |
| 120 | `err.code()` | `IError` | vlib/builtin/chan_option_result.v:38 |
| 128 | `conn.set_read_timeout(...)` | `net.TcpConn` | vlib/net/tcp.c.v:348 |
| 129 | `conn.set_write_timeout(...)` | `net.TcpConn` | vlib/net/tcp.c.v:377 |
| 133 | `s.close()` | `http.Server` | vlib/net/http/server.v:149 |

Line 116, `s.on_running(mut s)`, calls the fn held in the field declared at server.v:64. It is not a method call.

**7. Errors in vlib/net/http whose message mentions a redirect**
- vlib/net/http/request.v:305: `error('http.request.do: maximum number of redirects reached (${max_redirects})')`
- vlib/net/http/request.v:329: `error('http.request.do: invalid URL in redirect "${redirect_url}"')`
- vlib/net/http/request.v:334: `error('http.request.do: invalid URL in redirect "${redirect_url}"')`

**8. Functions in vlib that call `net.dial_tcp` directly** (14 calls in 13 functions)
- vlib/db/redis/dial.c.v:8, in `redis.dial_connection`
- vlib/net/tcp.c.v:17, in `TCPDialer.dial`
- vlib/net/http/request.v:546, in `Request.http_do`
- vlib/net/http/transport.v:792, in `Transport.dial_h1_tcp`
- vlib/net/http/http_proxy.v:138, in `HttpProxy.connect_tcp`
- vlib/net/smtp/smtp.v:127, in `smtp.Client.reconnect`
- vlib/net/ftp/ftp.v:113, in `FTP.connect`
- vlib/net/ftp/ftp.v:204, in `ftp.new_dtp`
- vlib/net/websocket/io.v:77, in `websocket.Client.dial_socket`
- vlib/net/socks/socks5.v:20, in `socks.socks5_dial`
- vlib/net/openssl/ssl_connection.c.v:336, in `openssl.SSLConn.dial`
- vlib/net/imap/imap.v:161, in `imap.Client.connect`
- vlib/net/pop/pop.v:54, in `pop.dial`

**Skeptical review**
- Q3: the graph search was limited to routes at most 10 calls longer than the shortest. I did not check by hand for routes longer than that, or for calls made through interfaces or function values.
- Q4: the grep that went through `write_string` calls file by file only looked at files that name `TcpConn`. A `TcpConn` passed in under another type alias would not be found. The graph's extra callers (`get`, `add`, `send`, `send_string`, ...) were checked only by grep.
- Q2: the question says `fd` is 0, but this code sets it at os.c.v:1264. The expected answer may be the explanation at 1255–1257 (on Unix the `File` is built with only `cfile` set).
- Q1: the receiver types at ssl_listener.c.v:216 and mbedtls 445 come from the enclosing `SSLConn` methods.

**Revised answer**
No change.
