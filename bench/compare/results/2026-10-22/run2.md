**1. Calls of a `wait_for_read` method in vlib/net**

- `vlib/net/tcp.c.v:198`: `c.wait_for_read()`, receiver `TcpConn`, in `TcpConn.read_ptr`
- `vlib/net/tcp.c.v:224`: `c.wait_for_read()`, receiver `TcpConn`, in `TcpConn.read_ptr`
- `vlib/net/udp.c.v:125`: `c.wait_for_read()`, receiver `UdpConn`, in `UdpConn.read_ptr`
- `vlib/net/udp.c.v:134`: `c.wait_for_read()`, receiver `UdpConn`, in `UdpConn.read_ptr`
- `vlib/net/raw.c.v:126`: `c.wait_for_read()`, receiver `RawConn`, in `RawConn.read_ptr`
- `vlib/net/unix/stream.c.v:142`: `c.wait_for_read()`, receiver `unix.StreamConn`, in `StreamConn.read_ptr`
- `vlib/net/openssl/ssl_connection.c.v:132`: `s.wait_for_read(...)`, receiver `openssl.SSLConn`, in `SSLConn.shutdown`
- `vlib/net/openssl/ssl_connection.c.v:374`: receiver `openssl.SSLConn`, in `SSLConn.complete_connect`
- `vlib/net/openssl/ssl_connection.c.v:396`: receiver `openssl.SSLConn`, in `SSLConn.complete_connect`
- `vlib/net/openssl/ssl_connection.c.v:468`: receiver `openssl.SSLConn`, in `SSLConn.socket_read_into_ptr`
- `vlib/net/openssl/ssl_connection.c.v:538`: receiver `openssl.SSLConn`, in `SSLConn.write_ptr`
- `vlib/net/openssl/ssl_listener.c.v:216`: `conn.wait_for_read(timeout)`, receiver `openssl.SSLConn`, in `SSLConn.accept_handshake`
- `vlib/net/mbedtls/ssl_connection.c.v:443`: `conn.wait_for_read(...)`, receiver `mbedtls.SSLConn`, in `SSLConn.do_handshake_loop`
- `vlib/net/mbedtls/ssl_connection.c.v:916`: receiver `mbedtls.SSLConn`, in `SSLConn.socket_read_into_ptr`
- `vlib/net/mbedtls/ssl_connection.c.v:997`: receiver `mbedtls.SSLConn`, in `SSLConn.write_ptr`

`vlib/net/mbedtls/ssl_connection.c.v:903` is commented out. The calls at `tcp.c.v:383, 654`, `udp.c.v:192`, `raw.c.v:191` and `unix/stream.c.v:218, 346` call the free function, so they don't count.

**2. `os.open_append` and `fd` 0 on Unix**

At this commit the returned File does not have `fd` 0.

- `vlib/os/os.c.v:1246`: `mut file := File{}` starts with the default `fd` of 0.
- `vlib/os/os.c.v:1255-1257`: on Unix it is replaced by `File{ cfile: C.fopen(&char(cpath), c'ab') }`. Only `cfile` is set, so this temporary File still has `fd` 0.
- `vlib/os/os.c.v:1262-1266`: that temporary is not what gets returned. The function builds a new `File{ cfile: file.cfile, fd: fileno(file.cfile), is_opened: true }`, with the fd set at line 1264.
- `vlib/os/os.c.v:371-378`: `fileno` calls `C.fileno(&C.FILE(cfile))` on Unix (line 377). That is the real descriptor of the opened stream.
- `vlib/os/file.c.v:21`: the `fd int` field defaults to 0.

So 0 shows up only in the intermediate value (or if descriptor 0 was closed and `fopen` reused it). A version that returned `file` directly would have `fd` 0, because `File{}` (line 1246) and the literal at 1255-1257 never set `fd`. The fix is the `fd: fileno(...)` at 1264.

**3. Routes from `http.get` to `net.dial_tcp`**

Every route starts with the same prefix P:
`get` → `fetch` (`vlib/net/http/http.v:71`) → `Request.do` (`vlib/net/http/http.v:251`) → `Request.method_and_url_to_response` (`vlib/net/http/request.v:295`)

Routes in the default build (mbedtls):

1. P → `Transport.round_trip` (`vlib/net/http/request.v:387`) → `Transport.dial_h1_tcp` (`vlib/net/http/transport.v:757`) → `net.dial_tcp` (`vlib/net/http/transport.v:791`)
2. P → `Request.http_do` (`vlib/net/http/request.v:411`) → `net.dial_tcp` (`vlib/net/http/request.v:531`)
3. P → `HttpProxy.http_do` (`vlib/net/http/request.v:421`) → `HttpProxy.dial` (`vlib/net/http/http_proxy.v:173`) → `HttpProxy.connect_tcp` (`vlib/net/http/http_proxy.v:204`) → `net.dial_tcp` (`vlib/net/http/http_proxy.v:138`)
4. P → `HttpProxy.http_do` (`request.v:421`) → `HttpProxy.ssl_dial` (`vlib/net/http/http_proxy.v:160`) → `HttpProxy.connect_tcp` (`http_proxy.v:209`) → `net.dial_tcp` (`http_proxy.v:138`)
5. P → `HttpProxy.http_do` (`request.v:421`) → `HttpProxy.dial` (`http_proxy.v:173`) → `HttpProxy.connect_tcp` (`http_proxy.v:204`) → `socks.socks5_dial` (`http_proxy.v:144`) → `net.dial_tcp` (`vlib/net/socks/socks5.v:20`)
6. P → `HttpProxy.http_do` (`request.v:421`) → `HttpProxy.ssl_dial` (`http_proxy.v:160`) → `HttpProxy.connect_tcp` (`http_proxy.v:209`) → `socks.socks5_dial` (`http_proxy.v:144`) → `net.dial_tcp` (`socks5.v:20`)
7. P → `HttpProxy.http_do` (`request.v:421`) → `HttpProxy.ssl_dial` (`http_proxy.v:160`) → `socks.socks5_ssl_dial` (`http_proxy.v:224`) → `socks.socks5_dial` (`vlib/net/socks/socks5.v:35`) → `net.dial_tcp` (`socks5.v:20`)

Further routes exist only with `-d use_openssl`. There `ssl.SSLConn` is `openssl.SSLConn` (`vlib/net/ssl/ssl_d_use_openssl.v:5`), and `openssl.SSLConn.dial` calls `net.dial_tcp` at `vlib/net/openssl/ssl_connection.c.v:336`. The default mbedtls `SSLConn.dial` (`vlib/net/mbedtls/ssl_connection.c.v:827`) uses `mbedtls_net_connect` and never calls `dial_tcp`. Each route below ends with → `SSLConn.dial` → `net.dial_tcp` (`openssl/ssl_connection.c.v:336`):

8. P → `Request.ssl_do` (`request.v:400`) → `net_ssl_do` (`vlib/net/http/backend.c.v:15`) → `SSLConn.dial` (`backend.c.v:39`)
9. P → `round_trip` (`request.v:387`) → `tls_fresh_round_trip` (`transport.v:755`) → `tls_fresh_round_trip_ssl` (`transport.v:809`) → `SSLConn.dial` (`transport.v:822`)
10. P → `round_trip` (`request.v:387`) → `h2_round_trip` (`transport.v:742`) → `h2_dial_and_do` (`vlib/net/http/transport_h2.v:83` or `:104`) → `h2_dial_probe` (`transport_h2.v:265`) → `h2_dial_probe_ssl` (`transport_h2.v:156`) → `SSLConn.dial` (`transport_h2.v:170`)
11. P → `round_trip` → `h2_round_trip` (`transport.v:742`) → `h2_dial_and_do` (`transport_h2.v:83/104`) → `h2_fallback_h1` (`transport_h2.v:253` or `:314`) → `h2_use_h1_pool_or_dial` (`transport_h2.v:198`) → `tls_fresh_round_trip` (`transport_h2.v:484` or `:495`) → `tls_fresh_round_trip_ssl` (`transport.v:809`) → `SSLConn.dial` (`transport.v:822`)
12. P → `round_trip` → `h2_round_trip` (`transport.v:742`) → `h2_dial_and_do` (`transport_h2.v:83/104`) → `h2_await_dial` (`transport_h2.v:220` or `:259`) → `h2_fallback_h1` (`transport_h2.v:469`) → `h2_use_h1_pool_or_dial` (`transport_h2.v:198`) → `tls_fresh_round_trip` (`transport_h2.v:484/495`) → `tls_fresh_round_trip_ssl` (`transport.v:809`) → `SSLConn.dial` (`transport.v:822`)

On Windows, the vschannel variants reach the same SSL dial:
- `ssl_do` → `vschannel_retry_handshake` (`backend.c.v:12`) → `net_ssl_do` (`vlib/net/http/vschannel_handshake.v:32`)
- `tls_fresh_round_trip` → `vschannel_fresh_round_trip` (`transport.v:807`) → `tls_fresh_round_trip_ssl` (`vlib/net/http/vschannel_pooled_transport_windows.c.v:270`)
- `h2_dial_probe` → `h2_dial_probe_vschannel` (`transport_h2.v:154`) → `h2_dial_probe_ssl` (`vschannel_pooled_transport_windows.c.v:226`)

**4. Calls of `net.TcpConn.write_string`**

- `vlib/net/http/http_proxy.v:176`: `client.write_string(s)`, in `HttpProxy.http_do`
- `vlib/net/pop/pop.v:138`: `c.conn.write_string(wire)`, in `pop.Client.send_cmd`
- `vlib/veb/veb.v:1103`: `conn.write_string(s)`, in `veb.send_string`
- `vlib/veb/veb_livereload.v:144`: `c.write_string(head)`, in `LivereloadHub.add`
- `vlib/veb/veb_livereload.v:166`: `c.write_string(payload)`, in `LivereloadHub.send`
- `vlib/veb/veb_livereload.v:289`: `conn.write_string(...)`, in `Context.handle_veb_livereload_events`

**5. Functions `os.cp_all` calls directly (`vlib/os/os.v:71-115`)**

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
- `cp_all` (recursive): line 110
- `rmdir`: line 111

**6. Method calls in `http.Server.listen_and_serve` (`vlib/net/http/server.v:73`)**

- Line 79: `s.listen_and_serve_tls()`, receiver `http.Server`. Declared at `vlib/net/http/server_tls_notd_use_openssl.v:46` (default build) and `vlib/net/http/server_tls_d_use_openssl.v:11` (`-d use_openssl`).
- Line 92: `s.listener.addr()`, receiver `net.TcpListener` → `vlib/net/tcp.c.v:661`
- Line 96: `l.str()`, receiver `net.Addr` → `vlib/net/address.c.v:305`
- Line 98: `s.listener.set_accept_timeout(...)`, receiver `net.TcpListener` → `vlib/net/tcp.c.v:649`
- Line 119: `s.listener.accept_only()`, receiver `net.TcpListener` → `vlib/net/tcp.c.v:593`
- Line 120: `err.code()`, receiver `IError` → `vlib/builtin/chan_option_result.v:38` (interface method; interface at line 36)
- Line 128: `conn.set_read_timeout(...)`, receiver `net.TcpConn` → `vlib/net/tcp.c.v:348`
- Line 129: `conn.set_write_timeout(...)`, receiver `net.TcpConn` → `vlib/net/tcp.c.v:377`
- Line 133: `s.close()`, receiver `http.Server` → `vlib/net/http/server.v:149`

`s.on_running(mut s)` at line 116 calls a function-pointer field, not a method. `new_handler_worker` (line 105), `net.listen_tcp` (87), `eprintln`, `println`, `flush_stdout` and `time.sleep` are free functions.

**7. Errors in vlib/net/http whose message mentions a redirect**

- `vlib/net/http/request.v:293`: `error('http.request.do: maximum number of redirects reached (${max_redirects})')`
- `vlib/net/http/request.v:314`: `error('http.request.do: invalid URL in redirect "${redirect_url}"')`
- `vlib/net/http/request.v:319`: `error('http.request.do: invalid URL in redirect "${redirect_url}"')`

**8. Functions that call `net.dial_tcp` directly**

- `net.TCPDialer.dial`: `vlib/net/tcp.c.v:17`
- `openssl.SSLConn.dial`: `vlib/net/openssl/ssl_connection.c.v:336`
- `socks.socks5_dial`: `vlib/net/socks/socks5.v:20`
- `smtp.Client.reconnect`: `vlib/net/smtp/smtp.v:127`
- `http.HttpProxy.connect_tcp`: `vlib/net/http/http_proxy.v:138`
- `http.Transport.dial_h1_tcp`: `vlib/net/http/transport.v:791`
- `http.Request.http_do`: `vlib/net/http/request.v:531`
- `imap.Client.connect`: `vlib/net/imap/imap.v:161`
- `pop.dial`: `vlib/net/pop/pop.v:54`
- `websocket.Client.dial_socket`: `vlib/net/websocket/io.v:77`
- `ftp.FTP.connect`: `vlib/net/ftp/ftp.v:113`
- `ftp.new_dtp`: `vlib/net/ftp/ftp.v:204`
- `redis.dial_connection`: `vlib/db/redis/dial.c.v:8`