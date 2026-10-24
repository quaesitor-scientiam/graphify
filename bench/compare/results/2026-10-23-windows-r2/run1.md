1. **`wait_for_read` method calls in vlib/net** (15 calls; the commented-out call at `vlib/net/mbedtls/ssl_connection.c.v:889` and the free-function calls are left out):
   - `vlib/net/raw.c.v:126`: `c.wait_for_read()` (RawConn)
   - `vlib/net/tcp.c.v:198`: `c.wait_for_read()` (TcpConn)
   - `vlib/net/tcp.c.v:224`: `c.wait_for_read()` (TcpConn)
   - `vlib/net/udp.c.v:125`: `c.wait_for_read()` (UdpConn)
   - `vlib/net/udp.c.v:134`: `c.wait_for_read()` (UdpConn)
   - `vlib/net/unix/stream.c.v:142`: `c.wait_for_read()` (unix.StreamConn)
   - `vlib/net/openssl/ssl_connection.c.v:132`: `s.wait_for_read(...)` (openssl.SSLConn)
   - `vlib/net/openssl/ssl_connection.c.v:374`: `s.wait_for_read(...)` (openssl.SSLConn)
   - `vlib/net/openssl/ssl_connection.c.v:396`: `s.wait_for_read(...)` (openssl.SSLConn)
   - `vlib/net/openssl/ssl_connection.c.v:468`: `s.wait_for_read(...)` (openssl.SSLConn)
   - `vlib/net/openssl/ssl_connection.c.v:538`: `s.wait_for_read(...)` (openssl.SSLConn)
   - `vlib/net/openssl/ssl_listener.c.v:216`: `conn.wait_for_read(timeout)` (openssl.SSLConn)
   - `vlib/net/mbedtls/ssl_connection.c.v:445`: `conn.wait_for_read(...)` (mbedtls.SSLConn)
   - `vlib/net/mbedtls/ssl_connection.c.v:902`: `s.wait_for_read(...)` (mbedtls.SSLConn)
   - `vlib/net/mbedtls/ssl_connection.c.v:983`: `s.wait_for_read(...)` (mbedtls.SSLConn)

2. **`os.open_append` and `fd` 0.** In this tree it doesn't return 0. The Unix branch opens the file with `C.fopen(&char(cpath), c'ab')` (`vlib/os/os.c.v:1253-1257`). The function then returns a new `File` with `fd: fileno(file.cfile)` (`vlib/os/os.c.v:1262-1266`, the fd at line 1264). On Unix, `fileno` returns `C.fileno(&C.FILE(cfile))` (`vlib/os/os.c.v:371-378`, line 377), which is the real descriptor.
   - The only zero is the default of `File.fd int` (`vlib/os/file.c.v:21`), seen in the temporary `mut file := File{}` (`vlib/os/os.c.v:1246`), which is not returned.
   - A 0 would only come from older code that returned that temporary `File{cfile: ...}` without setting `fd`.
   - The test `vlib/os/os_fd_test.v:110-112` checks `a.fd > 2` with the comment "os.open_append must carry the descriptor, not the zero default".

3. **Routes from `http.get` to `net.dial_tcp`** (17). Every route starts with the same prefix P:
   - `get` (`vlib/net/http/http.v:70`) calls `fetch` at `vlib/net/http/http.v:71`
   - `fetch` calls `Request.do` at `vlib/net/http/http.v:251`
   - `do` calls `Request.method_and_url_to_response` at `vlib/net/http/request.v:307`

   Routes 1–7 are in the default build:
   1. P, then `method_and_url_to_response` calls `http_do` at `vlib/net/http/request.v:426`, which calls `net.dial_tcp` at `vlib/net/http/request.v:546`.
   2. P, then `round_trip` at `vlib/net/http/request.v:402`; `dial_h1_tcp` at `vlib/net/http/transport.v:757`; `dial_tcp` at `vlib/net/http/transport.v:792`.
   3. P, then `HttpProxy.http_do` at `vlib/net/http/request.v:436`; `ssl_dial` at `vlib/net/http/http_proxy.v:160`; `connect_tcp` at `vlib/net/http/http_proxy.v:209`; `dial_tcp` at `vlib/net/http/http_proxy.v:138`.
   4. P, then `HttpProxy.http_do` at `request.v:436`; `HttpProxy.dial` at `vlib/net/http/http_proxy.v:173`; `connect_tcp` at `vlib/net/http/http_proxy.v:204`; `dial_tcp` at `http_proxy.v:138`.
   5. P, then `HttpProxy.http_do` at `request.v:436`; `ssl_dial` at `http_proxy.v:160`; `connect_tcp` at `http_proxy.v:209`; `socks.socks5_dial` at `vlib/net/http/http_proxy.v:144`; `dial_tcp` at `vlib/net/socks/socks5.v:20`.
   6. P, then `HttpProxy.http_do` at `request.v:436`; `ssl_dial` at `http_proxy.v:160`; `socks.socks5_ssl_dial` at `vlib/net/http/http_proxy.v:224`; `socks5_dial` at `vlib/net/socks/socks5.v:35`; `dial_tcp` at `vlib/net/socks/socks5.v:20`.
   7. P, then `HttpProxy.http_do` at `request.v:436`; `HttpProxy.dial` at `http_proxy.v:173`; `connect_tcp` at `http_proxy.v:204`; `socks5_dial` at `http_proxy.v:144`; `dial_tcp` at `socks5.v:20`.

   Routes 8–17 need `-d use_openssl`. All of them end with `openssl.SSLConn.dial` calling `dial_tcp` at `vlib/net/openssl/ssl_connection.c.v:336`.

   8. P, then `ssl_do` at `vlib/net/http/request.v:415`; `net_ssl_do` at `vlib/net/http/backend.c.v:15`; `SSLConn.dial` at `vlib/net/http/backend.c.v:39`; `dial_tcp`.
   9. P, then `round_trip` at `request.v:402`; `tls_fresh_round_trip` at `vlib/net/http/transport.v:755`; `tls_fresh_round_trip_ssl` at `vlib/net/http/transport.v:810`; `SSLConn.dial` at `vlib/net/http/transport.v:823`; `dial_tcp`.
   10. (also needs Windows without `no_vschannel`) P, then `ssl_do` at `request.v:415`; `vschannel_retry_handshake` at `vlib/net/http/backend.c.v:12`; `net_ssl_do` at `vlib/net/http/vschannel_handshake.v:32`; `SSLConn.dial` at `backend.c.v:39`; `dial_tcp`.
   11. (also Windows/vschannel) P, then `round_trip` at `request.v:402`; `tls_fresh_round_trip` at `transport.v:755`; `vschannel_fresh_round_trip` at `vlib/net/http/transport.v:808`; `tls_fresh_round_trip_ssl` at `vlib/net/http/vschannel_pooled_transport_windows.c.v:270`; `SSLConn.dial` at `transport.v:823`; `dial_tcp`.
   12. P, then `round_trip` at `request.v:402`; `h2_round_trip` at `vlib/net/http/transport.v:742`; `h2_dial_and_do` at `vlib/net/http/transport_h2.v:83` and `:104`; `h2_dial_probe` at `vlib/net/http/transport_h2.v:265`; `h2_dial_probe_ssl` at `vlib/net/http/transport_h2.v:156`; `SSLConn.dial` at `vlib/net/http/transport_h2.v:170`; `dial_tcp`.
   13. (also Windows/vschannel) P, then `round_trip` at `request.v:402`; `h2_round_trip` at `transport.v:742`; `h2_dial_and_do` at `transport_h2.v:83` and `:104`; `h2_dial_probe` at `transport_h2.v:265`; `h2_dial_probe_vschannel` at `vlib/net/http/transport_h2.v:154`; `h2_dial_probe_ssl` at `vlib/net/http/vschannel_pooled_transport_windows.c.v:226`; `SSLConn.dial` at `transport_h2.v:170`; `dial_tcp`.
   14. P, then `round_trip` at `request.v:402`; `h2_round_trip` at `transport.v:742`; `h2_dial_and_do` at `transport_h2.v:83` and `:104`; `h2_fallback_h1` at `vlib/net/http/transport_h2.v:253` and `:314`; `h2_use_h1_pool_or_dial` at `vlib/net/http/transport_h2.v:198`; `tls_fresh_round_trip` at `vlib/net/http/transport_h2.v:484` and `:495`; `tls_fresh_round_trip_ssl` at `transport.v:810`; `SSLConn.dial` at `transport.v:823`; `dial_tcp`.
   15. P, then `round_trip` at `request.v:402`; `h2_round_trip` at `transport.v:742`; `h2_dial_and_do` at `transport_h2.v:83` and `:104`; `h2_await_dial` at `vlib/net/http/transport_h2.v:220` and `:259`; `h2_fallback_h1` at `vlib/net/http/transport_h2.v:469`; `h2_use_h1_pool_or_dial` at `transport_h2.v:198`; `tls_fresh_round_trip` at `transport_h2.v:484` and `:495`; `tls_fresh_round_trip_ssl` at `transport.v:810`; `SSLConn.dial` at `transport.v:823`; `dial_tcp`.
   16. (also Windows/vschannel) Same as route 14 up to `tls_fresh_round_trip`, then `vschannel_fresh_round_trip` at `transport.v:808`; `tls_fresh_round_trip_ssl` at `vschannel_pooled_transport_windows.c.v:270`; `SSLConn.dial` at `transport.v:823`; `dial_tcp`.
   17. (also Windows/vschannel) Same as route 15 up to `tls_fresh_round_trip`, then `vschannel_fresh_round_trip` at `transport.v:808`; `tls_fresh_round_trip_ssl` at `vschannel_pooled_transport_windows.c.v:270`; `SSLConn.dial` at `transport.v:823`; `dial_tcp`.

4. **Calls of `net.TcpConn.write_string` (non-test vlib)**:
   - `vlib/net/http/http_proxy.v:176`, in `HttpProxy.http_do`
   - `vlib/net/pop/pop.v:138`, in `pop.Client.send_cmd`
   - `vlib/veb/veb.v:1103`, in `veb.send_string`
   - `vlib/veb/veb_livereload.v:144`, in `LivereloadHub.add`
   - `vlib/veb/veb_livereload.v:166`, in `LivereloadHub.send`
   - `vlib/veb/veb_livereload.v:289`, in `Context.handle_veb_livereload_events`

5. **Functions `os.cp_all` calls directly** (`vlib/os/os.v:71`):
   - `real_path` (`vlib/os/os.c.v:1065`): lines 72, 73
   - `exists` (`vlib/os/os.c.v:508`): lines 74, 85, 95, 106
   - `error` (builtin, `vlib/builtin/chan_option_result.v:109`): lines 75, 89, 99
   - `is_dir` (`vlib/os/os_stat_default.c.v:108`, or `vlib/os/os_stat_windows.c.v:204` on Windows): lines 78, 80, 98, 105
   - `file_name` (`vlib/os/os.v:423`): line 79
   - `join_path_single` (`vlib/os/os.v:783`): lines 81, 103, 104
   - `rm` (`vlib/os/os.c.v:593`): line 87
   - `cp` (`vlib/os/os.c.v:286`): line 92
   - `mkdir` (`vlib/os/os_nix.c.v:355`, or `vlib/os/os_windows.c.v:428`): lines 96, 107
   - `ls` (`vlib/os/os_nix.c.v:325`, or `vlib/os/os_windows.c.v:384`): line 101
   - `cp_all` (recursive call): line 110
   - `rmdir` (`vlib/os/os.c.v:635`): line 111

6. **Method calls in `http.Server.listen_and_serve`** (`vlib/net/http/server.v:73`):
   - line 79: `s.listen_and_serve_tls()`, receiver `http.Server`, declared at `vlib/net/http/server_tls_notd_use_openssl.v:46` (with `-d use_openssl`: `vlib/net/http/server_tls_d_use_openssl.v:11`)
   - line 92: `s.listener.addr()`, receiver `net.TcpListener`, declared at `vlib/net/tcp.c.v:661`
   - line 96: `l.str()`, receiver `net.Addr`, declared at `vlib/net/address.c.v:305`
   - line 98: `s.listener.set_accept_timeout(...)`, receiver `net.TcpListener`, declared at `vlib/net/tcp.c.v:649`
   - line 119: `s.listener.accept_only()`, receiver `net.TcpListener`, declared at `vlib/net/tcp.c.v:593`
   - line 120: `err.code()`, receiver `IError`, declared at `vlib/builtin/chan_option_result.v:38` (an interface method)
   - line 128: `conn.set_read_timeout(...)`, receiver `&net.TcpConn`, declared at `vlib/net/tcp.c.v:348`
   - line 129: `conn.set_write_timeout(...)`, receiver `&net.TcpConn`, declared at `vlib/net/tcp.c.v:377`
   - line 133: `s.close()`, receiver `http.Server`, declared at `vlib/net/http/server.v:149`
   - Not a method call: line 116, `s.on_running(mut s)`, calls the fn stored in the `Server.on_running` field (`vlib/net/http/server.v:64`).

7. **Errors in vlib/net/http whose message mentions a redirect**:
   - `vlib/net/http/request.v:305`: `'http.request.do: maximum number of redirects reached (...)'`
   - `vlib/net/http/request.v:329`: `'http.request.do: invalid URL in redirect "..."'`
   - `vlib/net/http/request.v:334`: `'http.request.do: invalid URL in redirect "..."'`

8. **Functions in vlib that call `net.dial_tcp` directly** (non-test):
   - `net.TCPDialer.dial`: `vlib/net/tcp.c.v:17`
   - `redis.dial_connection`: `vlib/db/redis/dial.c.v:8`
   - `socks.socks5_dial`: `vlib/net/socks/socks5.v:20`
   - `websocket.Client.dial_socket`: `vlib/net/websocket/io.v:77`
   - `smtp.Client.reconnect`: `vlib/net/smtp/smtp.v:127`
   - `pop.dial`: `vlib/net/pop/pop.v:54`
   - `imap.Client.connect`: `vlib/net/imap/imap.v:161`
   - `openssl.SSLConn.dial`: `vlib/net/openssl/ssl_connection.c.v:336`
   - `http.dial_h1_tcp`: `vlib/net/http/transport.v:792`
   - `http.Request.http_do`: `vlib/net/http/request.v:546`
   - `http.HttpProxy.connect_tcp`: `vlib/net/http/http_proxy.v:138`
   - `ftp.FTP.connect`: `vlib/net/ftp/ftp.v:113`
   - `ftp.FTP.new_dtp`: `vlib/net/ftp/ftp.v:204`

**Skeptical review:**
- Q3 comes from the graph's route count (17). I checked that `mbedtls` never calls `dial_tcp` and spot-checked the proxy and socks steps, but I did not re-read every step of the h2 and vschannel routes.
- Q4: I found receivers by grepping `.write_string(` and judging each receiver's type by hand. A TcpConn reached through an unusual variable name in a directory I didn't scan could be missing.
- Q2's premise doesn't hold for this tree. If the answer key expects the older bug (the bare `File{cfile: ...}` without `fd`), my explanation won't match it.
- Q6: whether `err.code()` and the `on_running` field call count as method calls depends on the key.

**Revised answer:** No change.
