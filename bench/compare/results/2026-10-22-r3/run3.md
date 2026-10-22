**1. Calls of a `wait_for_read` method in vlib/net**
- vlib/net/tcp.c.v:198: `c.wait_for_read()!` (TcpConn)
- vlib/net/tcp.c.v:224: `c.wait_for_read()!` (TcpConn)
- vlib/net/udp.c.v:125: `c.wait_for_read()!` (UdpConn)
- vlib/net/udp.c.v:134: `c.wait_for_read()!` (UdpConn)
- vlib/net/raw.c.v:126: `c.wait_for_read()!` (RawConn)
- vlib/net/unix/stream.c.v:142: `c.wait_for_read()!` (unix.StreamConn)
- vlib/net/mbedtls/ssl_connection.c.v:443: `conn.wait_for_read(...)`, in SSLConn.do_handshake_loop (mbedtls.SSLConn)
- vlib/net/mbedtls/ssl_connection.c.v:916: `s.wait_for_read(...)` (mbedtls.SSLConn)
- vlib/net/mbedtls/ssl_connection.c.v:997: `s.wait_for_read(...)` (mbedtls.SSLConn)
- vlib/net/openssl/ssl_connection.c.v:132 (openssl.SSLConn)
- vlib/net/openssl/ssl_connection.c.v:374 (openssl.SSLConn)
- vlib/net/openssl/ssl_connection.c.v:396 (openssl.SSLConn)
- vlib/net/openssl/ssl_connection.c.v:468 (openssl.SSLConn)
- vlib/net/openssl/ssl_connection.c.v:538 (openssl.SSLConn)
- vlib/net/openssl/ssl_listener.c.v:216: `conn.wait_for_read(timeout)!`, in SSLConn.accept_handshake (openssl.SSLConn)

Left out: the commented-out call at vlib/net/mbedtls/ssl_connection.c.v:903, and the free-function calls at tcp.c.v:383 and 654, udp.c.v:192, raw.c.v:191, and unix/stream.c.v:218 and 346.

**2. Why `os.open_append` returns a File with `fd` 0 on Unix**
It doesn't. The question's premise is wrong. `open_append` (vlib/os/os.c.v:1245) first builds `mut file := File{}` (os.c.v:1246), whose `fd` is the default 0. On Unix it then sets only `cfile` from `C.fopen(&char(cpath), c'ab')` (os.c.v:1255-1257). But it does not return that temporary. It returns a new `File{ cfile: file.cfile, fd: fileno(file.cfile), is_opened: true }` (os.c.v:1262-1266). The `fd` value comes from line 1264, and `os.fileno` (os.c.v:371-379) returns `C.fileno(&C.FILE(cfile))` on Unix (os.c.v:377). So the returned `fd` is the real descriptor of the opened stream. Only the throwaway intermediate `file` has `fd == 0` (the `fd int` field is declared at vlib/os/file.c.v:21).

**3. Routes from `http.get` to `net.dial_tcp`**
Every route starts with the same prefix, P:
get →(vlib/net/http/http.v:71) fetch →(http.v:251) Request.do →(vlib/net/http/request.v:295) Request.method_and_url_to_response.

The function `dial_tcp` is declared at vlib/net/tcp.c.v:48. In the steps below, `SSLConn.dial` is openssl.SSLConn.dial (reached via net.ssl under `-d use_openssl`; the mbedtls dial uses `mbedtls_net_connect` instead).

There are 17 routes:
1. P →(request.v:411) Request.http_do →(request.v:531) net.dial_tcp
2. P →(request.v:421) HttpProxy.http_do →(vlib/net/http/http_proxy.v:173) HttpProxy.dial →(http_proxy.v:204) HttpProxy.connect_tcp →(http_proxy.v:138) net.dial_tcp
3. P →(request.v:421) HttpProxy.http_do →(http_proxy.v:173) HttpProxy.dial →(http_proxy.v:204) connect_tcp →(http_proxy.v:144) socks.socks5_dial →(vlib/net/socks/socks5.v:20) net.dial_tcp
4. P →(request.v:421) HttpProxy.http_do →(http_proxy.v:160) HttpProxy.ssl_dial →(http_proxy.v:209) connect_tcp →(http_proxy.v:138) net.dial_tcp
5. P →(request.v:421) HttpProxy.http_do →(http_proxy.v:160) ssl_dial →(http_proxy.v:209) connect_tcp →(http_proxy.v:144) socks5_dial →(socks5.v:20) net.dial_tcp
6. P →(request.v:421) HttpProxy.http_do →(http_proxy.v:160) ssl_dial →(http_proxy.v:224) socks.socks5_ssl_dial →(socks5.v:35) socks5_dial →(socks5.v:20) net.dial_tcp
7. P →(request.v:400) Request.ssl_do →(vlib/net/http/backend.c.v:15) net_ssl_do →(backend.c.v:39) SSLConn.dial →(vlib/net/openssl/ssl_connection.c.v:336) net.dial_tcp
8. P →(request.v:400) Request.ssl_do →(backend.c.v:12) vschannel_retry_handshake →(vlib/net/http/vschannel_handshake.v:32) net_ssl_do →(backend.c.v:39) SSLConn.dial →(openssl/ssl_connection.c.v:336) net.dial_tcp
9. P →(request.v:387) Transport.round_trip →(vlib/net/http/transport.v:757) Transport.dial_h1_tcp →(transport.v:791) net.dial_tcp
10. P →(request.v:387) round_trip →(transport.v:755) tls_fresh_round_trip →(transport.v:809) tls_fresh_round_trip_ssl →(transport.v:822) SSLConn.dial →(openssl/ssl_connection.c.v:336) net.dial_tcp
11. P →(request.v:387) round_trip →(transport.v:755) tls_fresh_round_trip →(transport.v:807) vschannel_fresh_round_trip →(vlib/net/http/vschannel_pooled_transport_windows.c.v:270) tls_fresh_round_trip_ssl →(transport.v:822) SSLConn.dial →(openssl/ssl_connection.c.v:336) net.dial_tcp

Routes 12–17 all begin with:
P →(request.v:387) round_trip →(transport.v:742) Transport.h2_round_trip →(vlib/net/http/transport_h2.v:83 / 104) h2_dial_and_do

12. … →(transport_h2.v:265) h2_dial_probe →(transport_h2.v:156) h2_dial_probe_ssl →(transport_h2.v:170) SSLConn.dial →(openssl/ssl_connection.c.v:336) net.dial_tcp
13. … →(transport_h2.v:265) h2_dial_probe →(transport_h2.v:154) h2_dial_probe_vschannel →(vschannel_pooled_transport_windows.c.v:226) h2_dial_probe_ssl →(transport_h2.v:170) SSLConn.dial →(openssl/ssl_connection.c.v:336) net.dial_tcp
14. … →(transport_h2.v:253 / 314) h2_fallback_h1 →(transport_h2.v:198) h2_use_h1_pool_or_dial →(transport_h2.v:484 / 495) tls_fresh_round_trip →(transport.v:809) tls_fresh_round_trip_ssl →(transport.v:822) SSLConn.dial →(openssl/ssl_connection.c.v:336) net.dial_tcp
15. Same as 14, but tls_fresh_round_trip →(transport.v:807) vschannel_fresh_round_trip →(vschannel_pooled_transport_windows.c.v:270) tls_fresh_round_trip_ssl →(transport.v:822) SSLConn.dial →(openssl/ssl_connection.c.v:336) net.dial_tcp
16. … →(transport_h2.v:220 / 259) h2_await_dial →(transport_h2.v:469) h2_fallback_h1 →(transport_h2.v:198) h2_use_h1_pool_or_dial →(transport_h2.v:484 / 495) tls_fresh_round_trip →(transport.v:809) tls_fresh_round_trip_ssl →(transport.v:822) SSLConn.dial →(openssl/ssl_connection.c.v:336) net.dial_tcp
17. Same as 16, but tls_fresh_round_trip →(transport.v:807) vschannel_fresh_round_trip →(vschannel_pooled_transport_windows.c.v:270) tls_fresh_round_trip_ssl →(transport.v:822) SSLConn.dial →(openssl/ssl_connection.c.v:336) net.dial_tcp

**4. Calls of `net.TcpConn.write_string` (declared at vlib/net/tcp.c.v:322)**
- vlib/veb/veb.v:1103, in `veb.send_string`
- vlib/veb/veb_livereload.v:144, in `LivereloadHub.add`
- vlib/veb/veb_livereload.v:166, in `LivereloadHub.send`
- vlib/veb/veb_livereload.v:289, in `Context.handle_veb_livereload_events`
- vlib/net/pop/pop.v:138, in `pop.Client.send_cmd` (receiver `c.conn`, type `&net.TcpConn`)
- vlib/net/http/http_proxy.v:176, in `HttpProxy.http_do` (receiver `client`, from `pr.dial`, type `&net.TcpConn`)

**5. Functions `os.cp_all` calls directly (vlib/os/os.v:71)**
- real_path: os.v:72, 73
- exists: os.v:74, 85, 95, 106
- error (builtin): os.v:75, 89, 99
- is_dir: os.v:78, 80, 98, 105
- file_name: os.v:79
- join_path_single: os.v:81, 103, 104
- rm: os.v:87
- cp: os.v:92
- mkdir: os.v:96, 107
- ls: os.v:101
- cp_all (recursive): os.v:110
- rmdir: os.v:111

**6. Method calls in `http.Server.listen_and_serve` (vlib/net/http/server.v:73)**
- server.v:79: `s.listen_and_serve_tls()`, receiver http.Server. Declared at vlib/net/http/server_tls_notd_use_openssl.v:46 (default build) and vlib/net/http/server_tls_d_use_openssl.v:11 (`-d use_openssl`).
- server.v:92: `s.listener.addr()`, receiver net.TcpListener. Declared at vlib/net/tcp.c.v:661.
- server.v:96: `l.str()`, receiver net.Addr. Declared at vlib/net/address.c.v:305.
- server.v:98: `s.listener.set_accept_timeout(...)`, receiver net.TcpListener. Declared at vlib/net/tcp.c.v:649.
- server.v:119: `s.listener.accept_only()`, receiver net.TcpListener. Declared at vlib/net/tcp.c.v:593.
- server.v:120: `err.code()`, receiver IError. Declared at vlib/builtin/chan_option_result.v:38 (interface method; implementations at :67 and :92).
- server.v:128: `conn.set_read_timeout(...)`, receiver &net.TcpConn. Declared at vlib/net/tcp.c.v:348.
- server.v:129: `conn.set_write_timeout(...)`, receiver &net.TcpConn. Declared at vlib/net/tcp.c.v:377.
- server.v:133: `s.close()`, receiver http.Server. Declared at vlib/net/http/server.v:149.

Not counted as a method call: server.v:116 `s.on_running(mut s)`, which calls a function-typed field.

**7. Errors in vlib/net/http whose message mentions a redirect**
- vlib/net/http/request.v:293: `error('http.request.do: maximum number of redirects reached (${max_redirects})')`
- vlib/net/http/request.v:314: `error('http.request.do: invalid URL in redirect "${redirect_url}"')`
- vlib/net/http/request.v:319: `error('http.request.do: invalid URL in redirect "${redirect_url}"')`

**8. Functions in vlib that call `net.dial_tcp` directly**
- `net.TCPDialer.dial`: vlib/net/tcp.c.v:17
- `redis.dial_connection`: vlib/db/redis/dial.c.v:8
- `imap.Client.connect`: vlib/net/imap/imap.v:161
- `pop.dial`: vlib/net/pop/pop.v:54
- `openssl.SSLConn.dial`: vlib/net/openssl/ssl_connection.c.v:336
- `socks.socks5_dial`: vlib/net/socks/socks5.v:20
- `smtp.Client.reconnect`: vlib/net/smtp/smtp.v:127
- `websocket.Client.dial_socket`: vlib/net/websocket/io.v:77
- `ftp.FTP.connect`: vlib/net/ftp/ftp.v:113
- `ftp.new_dtp`: vlib/net/ftp/ftp.v:204
- `http.HttpProxy.connect_tcp`: vlib/net/http/http_proxy.v:138
- `http.Transport.dial_h1_tcp`: vlib/net/http/transport.v:791
- `http.Request.http_do`: vlib/net/http/request.v:531