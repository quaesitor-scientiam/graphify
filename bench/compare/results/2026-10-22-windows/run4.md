1. **`wait_for_read` method calls in vlib/net** (15 calls)
- vlib/net/tcp.c.v:198: `c.wait_for_read()!` (TcpConn)
- vlib/net/tcp.c.v:224: `c.wait_for_read()!` (TcpConn)
- vlib/net/udp.c.v:125: `c.wait_for_read()!` (UdpConn)
- vlib/net/udp.c.v:134: `c.wait_for_read()!` (UdpConn)
- vlib/net/raw.c.v:126: `c.wait_for_read()!` (RawConn)
- vlib/net/unix/stream.c.v:142: `c.wait_for_read()!` (unix.StreamConn)
- vlib/net/openssl/ssl_listener.c.v:216: `conn.wait_for_read(timeout)!` (openssl.SSLConn, in accept_handshake)
- vlib/net/openssl/ssl_connection.c.v:132
- vlib/net/openssl/ssl_connection.c.v:374
- vlib/net/openssl/ssl_connection.c.v:396
- vlib/net/openssl/ssl_connection.c.v:468
- vlib/net/openssl/ssl_connection.c.v:538 (all five are `s.wait_for_read(...)`, openssl.SSLConn)
- vlib/net/mbedtls/ssl_connection.c.v:443: `conn.wait_for_read(...)` (mbedtls.SSLConn, in do_handshake_loop)
- vlib/net/mbedtls/ssl_connection.c.v:916
- vlib/net/mbedtls/ssl_connection.c.v:997 (both `s.wait_for_read(...)`, mbedtls.SSLConn)

Line 903 of vlib/net/mbedtls/ssl_connection.c.v is commented out, so it does not count.

2. **`os.open_append` and `fd`**
In this tree, `open_append` does not leave `fd` at 0 on Unix. The premise of the question does not hold.
- vlib/os/os.c.v:1246: it starts with `mut file := File{}`. That temporary File has `fd` 0, because the `File` struct (vlib/os/file.c.v:17-24, `fd int` at vlib/os/file.c.v:21) has no default for `fd`.
- vlib/os/os.c.v:1255-1257: on Unix it reassigns `file = File{ cfile: C.fopen(&char(cpath), c'ab') }`. This sets only `cfile`, so this File's `fd` is still 0.
- vlib/os/os.c.v:1262-1266: the function does not return that temporary. It builds a new `File{ cfile: file.cfile, fd: fileno(file.cfile), is_opened: true }`.
- vlib/os/os.c.v:371-379: `fileno` returns `C.fileno(...)` on Unix (vlib/os/os.c.v:377), which is the real descriptor.

So only the intermediate File at vlib/os/os.c.v:1246 and 1255 has `fd == 0`. The returned File gets 0 only if the OS really hands out descriptor 0, which happens when stdin was closed. `open_file` sets `fd` directly from `C.open` (vlib/os/file.c.v:98, 109). `open` and `create` use `fileno` (vlib/os/file.c.v:136, 148).

3. **Routes from `http.get` to `net.dial_tcp`** (17 routes; the first 7 are in the default build)
Every route starts with the same prefix, which I call P:
- get (vlib/net/http/http.v:70) → fetch, called at vlib/net/http/http.v:71
- → Request.do, called at vlib/net/http/http.v:251
- → method_and_url_to_response, called at vlib/net/http/request.v:295

Routes:
1. P → Request.http_do (request.v:411) → dial_tcp (request.v:531)
2. P → Transport.round_trip (request.v:387) → dial_h1_tcp (transport.v:757) → dial_tcp (transport.v:791)
3. P → HttpProxy.http_do (request.v:421) → ssl_dial (http_proxy.v:160) → connect_tcp (http_proxy.v:209) → dial_tcp (http_proxy.v:138)
4. P → HttpProxy.http_do (request.v:421) → dial (http_proxy.v:173) → connect_tcp (http_proxy.v:204) → dial_tcp (http_proxy.v:138)
5. P → HttpProxy.http_do (request.v:421) → ssl_dial (http_proxy.v:160) → connect_tcp (http_proxy.v:209) → socks.socks5_dial (http_proxy.v:144) → dial_tcp (vlib/net/socks/socks5.v:20)
6. P → HttpProxy.http_do (request.v:421) → ssl_dial (http_proxy.v:160) → socks5_ssl_dial (http_proxy.v:224) → socks5_dial (socks5.v:35) → dial_tcp (socks5.v:20)
7. P → HttpProxy.http_do (request.v:421) → dial (http_proxy.v:173) → connect_tcp (http_proxy.v:204) → socks5_dial (http_proxy.v:144) → dial_tcp (socks5.v:20)

Routes 8–17 need `-d use_openssl`. They end in openssl.SSLConn.dial, which calls dial_tcp at vlib/net/openssl/ssl_connection.c.v:336.

8. P → ssl_do (request.v:400) → net_ssl_do (backend.c.v:15) → SSLConn.dial (backend.c.v:39) → dial_tcp (ssl_connection.c.v:336)
9. P → round_trip (request.v:387) → tls_fresh_round_trip (transport.v:755) → tls_fresh_round_trip_ssl (transport.v:809) → SSLConn.dial (transport.v:822) → dial_tcp
10. P → ssl_do (request.v:400) → vschannel_retry_handshake (backend.c.v:12, Windows) → net_ssl_do (vschannel_handshake.v:32) → SSLConn.dial (backend.c.v:39) → dial_tcp
11. P → round_trip (request.v:387) → tls_fresh_round_trip (transport.v:755) → vschannel_fresh_round_trip (transport.v:807, Windows) → tls_fresh_round_trip_ssl (vschannel_pooled_transport_windows.c.v:270) → SSLConn.dial (transport.v:822) → dial_tcp
12. P → round_trip (request.v:387) → h2_round_trip (transport.v:742) → h2_dial_and_do (transport_h2.v:83, 104) → h2_dial_probe (transport_h2.v:265) → h2_dial_probe_ssl (transport_h2.v:156) → SSLConn.dial (transport_h2.v:170) → dial_tcp
13. Same as 12 up to h2_dial_probe (transport_h2.v:265) → h2_dial_probe_vschannel (transport_h2.v:154, Windows) → h2_dial_probe_ssl (vschannel_pooled_transport_windows.c.v:226) → SSLConn.dial (transport_h2.v:170) → dial_tcp
14. P → round_trip (request.v:387) → h2_round_trip (transport.v:742) → h2_dial_and_do (transport_h2.v:83, 104) → h2_fallback_h1 (transport_h2.v:253, 314) → h2_use_h1_pool_or_dial (transport_h2.v:198) → tls_fresh_round_trip (transport_h2.v:484, 495) → tls_fresh_round_trip_ssl (transport.v:809) → SSLConn.dial (transport.v:822) → dial_tcp
15. Same as 14, but h2_dial_and_do → h2_await_dial (transport_h2.v:220, 259) → h2_fallback_h1 (transport_h2.v:469) → … then as 14
16. Same as 14, but tls_fresh_round_trip → vschannel_fresh_round_trip (transport.v:807, Windows) → tls_fresh_round_trip_ssl (vschannel_pooled_transport_windows.c.v:270) → SSLConn.dial (transport.v:822) → dial_tcp
17. Same as 15, with the vschannel_fresh_round_trip step from 16

File names without a directory are under vlib/net/http/, except socks5.v (vlib/net/socks/) and ssl_connection.c.v (vlib/net/openssl/).

4. **Calls of `net.TcpConn.write_string`** (4 calls)
- vlib/net/http/http_proxy.v:176: `client.write_string(s)!`, in `HttpProxy.http_do` (`client` comes from `pr.dial`, which returns `&net.TcpConn`)
- vlib/net/pop/pop.v:138: `c.conn.write_string(wire)`, in `pop.Client.send_cmd`
- vlib/veb/veb.v:1103: `conn.write_string(s)!`, in `veb.send_string` (`mut conn net.TcpConn`)
- vlib/veb/veb_livereload.v:289: `conn.write_string(...)`, in `veb.Context.handle_veb_livereload_events` (`ctx.conn` is `&net.TcpConn`, vlib/veb/context.v:86)

5. **Direct calls in `os.cp_all`** (vlib/os/os.v:71)
- real_path: 72, 73
- exists: 74, 85, 95, 106
- error (builtin): 75, 89, 99
- is_dir: 78, 80, 98, 105
- file_name: 79
- join_path_single: 81, 103, 104
- rm: 87
- cp: 92
- mkdir: 96, 107
- ls: 101
- cp_all (recursive): 110
- rmdir: 111

6. **Method calls in `http.Server.listen_and_serve`** (vlib/net/http/server.v:73)

| Line | Call | Receiver type | Declaration |
|---|---|---|---|
| 79 | `s.listen_and_serve_tls()` | `http.Server` | vlib/net/http/server_tls_notd_use_openssl.v:46 (default build); vlib/net/http/server_tls_d_use_openssl.v:11 under `-d use_openssl` |
| 92 | `s.listener.addr()` | `net.TcpListener` | vlib/net/tcp.c.v:661 |
| 96 | `l.str()` | `net.Addr` | vlib/net/address.c.v:305 |
| 98 | `s.listener.set_accept_timeout(...)` | `net.TcpListener` | vlib/net/tcp.c.v:649 |
| 116 | `s.on_running(mut s)` | `http.Server` | not a method: it calls the `fn (mut s Server)` field declared at vlib/net/http/server.v:64 |
| 119 | `s.listener.accept_only()` | `net.TcpListener` | vlib/net/tcp.c.v:593 |
| 120 | `err.code()` | `IError` | interface method, vlib/builtin/chan_option_result.v:38 |
| 128 | `conn.set_read_timeout(...)` | `&net.TcpConn` | vlib/net/tcp.c.v:348 |
| 129 | `conn.set_write_timeout(...)` | `&net.TcpConn` | vlib/net/tcp.c.v:377 |
| 133 | `s.close()` | `http.Server` | vlib/net/http/server.v:149 |

These are plain function calls, not method calls: eprintln (75, 88, 93, 124), net.listen_tcp (87), new_handler_worker (105), println (109), flush_stdout (110) and time.sleep (113, 125).

7. **Errors in vlib/net/http whose message mentions a redirect** (3 places)
- vlib/net/http/request.v:293: `return error('http.request.do: maximum number of redirects reached (${max_redirects})')`
- vlib/net/http/request.v:314: `return error('http.request.do: invalid URL in redirect "${redirect_url}"')`
- vlib/net/http/request.v:319: `return error('http.request.do: invalid URL in redirect "${redirect_url}"')`

8. **Functions in vlib that call `net.dial_tcp` directly** (14 call sites in 13 functions)
- `net.TCPDialer.dial`: vlib/net/tcp.c.v:17
- `redis.dial_connection`: vlib/db/redis/dial.c.v:8
- `websocket.Client.dial_socket`: vlib/net/websocket/io.v:77
- `socks.socks5_dial`: vlib/net/socks/socks5.v:20
- `smtp.Client.reconnect`: vlib/net/smtp/smtp.v:127
- `ftp.FTP.connect`: vlib/net/ftp/ftp.v:113
- `ftp.new_dtp`: vlib/net/ftp/ftp.v:204
- `imap.Client.connect`: vlib/net/imap/imap.v:161
- `pop.dial`: vlib/net/pop/pop.v:54
- `openssl.SSLConn.dial`: vlib/net/openssl/ssl_connection.c.v:336
- `http.Transport.dial_h1_tcp`: vlib/net/http/transport.v:791
- `http.Request.http_do`: vlib/net/http/request.v:531
- `http.HttpProxy.connect_tcp`: vlib/net/http/http_proxy.v:138
