# Answer key

vlang at 417c85b1ec, vlib only, non-test code only (see `questions.md` for scope).
Paths are relative to `vlib/`. Every item was confirmed at its source line.

Q1 to Q4 were keyed by an agent reading the source; Q5 to Q8 by reading the lines
given. Q3 is scored on routes 1-7, the ones every build has; the [openssl] routes
8-17 are counted apart, as extra.

## Q1. Calls of a `wait_for_read` method in vlib/net

15 items. Each receiver is a value of a type that has a `wait_for_read` method:
`RawConn` (net/raw.c.v:190), `UdpConn` (net/udp.c.v:191), `TcpConn` (net/tcp.c.v:382),
`unix.StreamConn` (net/unix/stream.c.v:217), `mbedtls.SSLConn`
(net/mbedtls/ssl_connection.c.v:1121), `openssl.SSLConn` (net/openssl/ssl_connection.c.v:666).

1. net/raw.c.v:126, `c.wait_for_read()` in `RawConn.read_ptr` (receiver `&RawConn`)
2. net/udp.c.v:125, `c.wait_for_read()` in `UdpConn.read_ptr` (`&UdpConn`)
3. net/udp.c.v:134, `c.wait_for_read()` in `UdpConn.read_ptr` (`&UdpConn`)
4. net/tcp.c.v:198, `c.wait_for_read()` in `TcpConn.read_ptr` (`TcpConn`)
5. net/tcp.c.v:224, `c.wait_for_read()` in `TcpConn.read_ptr` (`TcpConn`)
6. net/unix/stream.c.v:142, `c.wait_for_read()` in `StreamConn.read_ptr` (`unix.StreamConn`)
7. net/mbedtls/ssl_connection.c.v:443, `conn.wait_for_read(...)` in `SSLConn.do_handshake_loop` (`mbedtls.SSLConn`)
8. net/mbedtls/ssl_connection.c.v:916, `s.wait_for_read(...)` in `SSLConn.socket_read_into_ptr` (`mbedtls.SSLConn`)
9. net/mbedtls/ssl_connection.c.v:997, `s.wait_for_read(...)` in `SSLConn.write_ptr` (`mbedtls.SSLConn`)
10. net/openssl/ssl_listener.c.v:216, `conn.wait_for_read(timeout)` in `SSLConn.accept_handshake` (`openssl.SSLConn`)
11. net/openssl/ssl_connection.c.v:132, `s.wait_for_read(...)` in `SSLConn.shutdown` (`openssl.SSLConn`)
12. net/openssl/ssl_connection.c.v:374, `s.wait_for_read(...)` in `SSLConn.complete_connect` (`openssl.SSLConn`)
13. net/openssl/ssl_connection.c.v:396, `s.wait_for_read(...)` in `SSLConn.complete_connect` (`openssl.SSLConn`)
14. net/openssl/ssl_connection.c.v:468, `s.wait_for_read(...)` in `SSLConn.socket_read_into_ptr` (`openssl.SSLConn`)
15. net/openssl/ssl_connection.c.v:538, `s.wait_for_read(...)` in `SSLConn.write_ptr` (`openssl.SSLConn`)

Not items:
- net/mbedtls/ssl_connection.c.v:903, `// s.wait_for_read(deadline - time.now())!`: commented out.
- Calls of the free functions `net.wait_for_read` (net/common.c.v:233) and
  `unix.wait_for_read` (net/unix/common.c.v:147): net/raw.c.v:191, net/udp.c.v:192,
  net/tcp.c.v:383, net/tcp.c.v:654 (in `TcpListener.wait_for_accept`),
  net/unix/stream.c.v:218, net/unix/stream.c.v:341 (in `StreamListener.wait_for_accept`).
- The method declarations themselves (raw.c.v:190, udp.c.v:191, tcp.c.v:382,
  unix/stream.c.v:217, mbedtls/ssl_connection.c.v:1121, openssl/ssl_connection.c.v:666).
- Mentions in comments and docs: net/http/h2_pooled_transport.v:37 and :230,
  net/openssl/ssl_connection.c.v:268, net/README.md:26.
- Calls in `_test.v` files.

## Q2. Why `os.open_append` returns a File with `fd` 0 on Unix

Points a full answer makes:

1. os/os.c.v:1245-1246: `open_append` starts from `mut file := File{}`, the zero value.
2. file.c.v:17-24 (field at os/file.c.v:21): `File.fd` is `fd int` with no default, so a
   `File{}` literal that leaves it out has `fd == 0`.
3. os/os.c.v:1253-1257: the Unix (`$else`) branch opens with `C.fopen(path, 'ab')` and
   builds `File{ cfile: ... }`, setting only `cfile`; `fd` is never given.
4. os/os.c.v:1259-1263: after the nil check it sets only `file.is_opened = true` and returns;
   nothing calls `fileno` (os/os.c.v:371) to get the descriptor from the `FILE*`.
5. Contrast (shows it is an omission, not by design): `os.open` (os/file.c.v:135-140) and
   `os.create` (os/file.c.v:147-151) call `fileno(cfile)` and set `fd`, and `open_file`
   sets `fd` from `C.open` (os/file.c.v:107-110).
6. Consequence: 0 is the descriptor of stdin (`os.stdin()` sets `fd: 0`, os/file.c.v:159),
   so code that uses `f.fd` of an appended file acts on stdin, not the file.
   (The Windows branch, os/os.c.v:1247-1252, also leaves `fd` unset.)

Items 1-4 are required; 5 and 6 are supporting points.

## Q3. Routes from `http.get` to `net.dial_tcp`

17 simple routes. Every route starts with the common prefix

  P = `http.get` (net/http/http.v:70) -> `http.fetch` at net/http/http.v:71
      -> `Request.do` at net/http/http.v:251
      -> `Request.method_and_url_to_response` at net/http/request.v:295

and ends at `net.dial_tcp` (net/tcp.c.v:48). Steps give the line of the call in the
caller. Where a caller calls the next function from two lines, both are given.

Build conditions: `ssl.SSLConn` is `openssl.SSLConn` only under `-d use_openssl`
(net/ssl/ssl_d_use_openssl.v); by default it is `mbedtls.SSLConn`, whose `dial`
(net/mbedtls/ssl_connection.c.v:827) connects with `C.mbedtls_net_connect` and never calls
`net.dial_tcp`. So routes through `SSLConn.dial` exist only in an OpenSSL build; they are
marked [openssl]. Steps under `$if windows && !no_vschannel ?` are marked [windows].
Routes 1-7 exist in every build.

Plain HTTP, no proxy, no pooling:
1. P -> `Request.http_do` at request.v:411 -> `net.dial_tcp` at request.v:531

Pooled transport (default for http/https without a proxy):
2. P -> `Transport.round_trip` at request.v:387 -> `Transport.dial_h1_tcp` at transport.v:670
   -> `net.dial_tcp` at transport.v:704

Proxy (`req.proxy != nil`):
3. P -> `HttpProxy.http_do` at request.v:421 -> `HttpProxy.dial` at http_proxy.v:173
   -> `HttpProxy.connect_tcp` at http_proxy.v:204 -> `net.dial_tcp` at http_proxy.v:138
4. P -> `HttpProxy.http_do` at request.v:421 -> `HttpProxy.dial` at http_proxy.v:173
   -> `HttpProxy.connect_tcp` at http_proxy.v:204 -> `socks.socks5_dial` at http_proxy.v:144
   -> `net.dial_tcp` at socks/socks5.v:20
5. P -> `HttpProxy.http_do` at request.v:421 -> `HttpProxy.ssl_dial` at http_proxy.v:160
   -> `HttpProxy.connect_tcp` at http_proxy.v:209 -> `net.dial_tcp` at http_proxy.v:138
6. P -> `HttpProxy.http_do` at request.v:421 -> `HttpProxy.ssl_dial` at http_proxy.v:160
   -> `HttpProxy.connect_tcp` at http_proxy.v:209 -> `socks.socks5_dial` at http_proxy.v:144
   -> `net.dial_tcp` at socks/socks5.v:20
7. P -> `HttpProxy.http_do` at request.v:421 -> `HttpProxy.ssl_dial` at http_proxy.v:160
   -> `socks.socks5_ssl_dial` at http_proxy.v:224 -> `socks.socks5_dial` at socks/socks5.v:35
   -> `net.dial_tcp` at socks/socks5.v:20

TLS without the pool (`disable_connection_reuse`), [openssl]:
8. P -> `Request.ssl_do` at request.v:400 -> `net_ssl_do` at backend.c.v:15
   -> `openssl.SSLConn.dial` at backend.c.v:39 -> `net.dial_tcp` at openssl/ssl_connection.c.v:336
9. [windows] P -> `Request.ssl_do` at request.v:400 -> `vschannel_retry_handshake` at backend.c.v:12
   -> `net_ssl_do` at vschannel_handshake.v:32 -> `openssl.SSLConn.dial` at backend.c.v:39
   -> `net.dial_tcp` at openssl/ssl_connection.c.v:336

Pooled TLS, [openssl] (let T = `Transport.round_trip` at request.v:387, and
D = `openssl.SSLConn.dial` -> `net.dial_tcp` at openssl/ssl_connection.c.v:336):
10. P -> T -> `Transport.tls_fresh_round_trip` at transport.v:668
    -> `Transport.tls_fresh_round_trip_ssl` at transport.v:722 -> `SSLConn.dial` at transport.v:735 -> D
11. [windows] P -> T -> `Transport.tls_fresh_round_trip` at transport.v:668
    -> `Transport.vschannel_fresh_round_trip` at transport.v:720
    -> `Transport.tls_fresh_round_trip_ssl` at vschannel_pooled_transport_windows.c.v:270
    -> `SSLConn.dial` at transport.v:735 -> D

Pooled HTTP/2 (`enable_http2`), [openssl]; let H = T -> `Transport.h2_round_trip` at
transport.v:655 -> `Transport.h2_dial_and_do` at transport_h2.v:83 and :104:
12. P -> H -> `h2_dial_probe` at transport_h2.v:265 -> `h2_dial_probe_ssl` at transport_h2.v:156
    -> `SSLConn.dial` at transport_h2.v:170 -> D
13. [windows] P -> H -> `h2_dial_probe` at transport_h2.v:265
    -> `h2_dial_probe_vschannel` at transport_h2.v:154
    -> `h2_dial_probe_ssl` at vschannel_pooled_transport_windows.c.v:226
    -> `SSLConn.dial` at transport_h2.v:170 -> D
14. P -> H -> `Transport.h2_fallback_h1` at transport_h2.v:253 and :314
    -> `Transport.h2_use_h1_pool_or_dial` at transport_h2.v:198
    -> `Transport.tls_fresh_round_trip` at transport_h2.v:483 and :494
    -> `Transport.tls_fresh_round_trip_ssl` at transport.v:722 -> `SSLConn.dial` at transport.v:735 -> D
15. [windows] as 14, but `Transport.tls_fresh_round_trip` -> `Transport.vschannel_fresh_round_trip`
    at transport.v:720 -> `Transport.tls_fresh_round_trip_ssl` at
    vschannel_pooled_transport_windows.c.v:270 -> `SSLConn.dial` at transport.v:735 -> D
16. P -> H -> `Transport.h2_await_dial` at transport_h2.v:220 and :259
    -> `Transport.h2_fallback_h1` at transport_h2.v:468
    -> `Transport.h2_use_h1_pool_or_dial` at transport_h2.v:198
    -> `Transport.tls_fresh_round_trip` at transport_h2.v:483 and :494
    -> `Transport.tls_fresh_round_trip_ssl` at transport.v:722 -> `SSLConn.dial` at transport.v:735 -> D
17. [windows] as 16, but through `Transport.vschannel_fresh_round_trip` at transport.v:720
    -> `Transport.tls_fresh_round_trip_ssl` at vschannel_pooled_transport_windows.c.v:270
    -> `SSLConn.dial` at transport.v:735 -> D

Scoring note: an answer that resolves `ssl.SSLConn` to the default mbedtls backend
finds exactly routes 1-7; it should be scored on those 7, with 8-17 credited
when given and not counted as misses only if the answer says it assumed the default
backend.

Not items:
- `fetch` -> `h(config)` (http.v:246): a call through a registered scheme handler, a
  function value, not a direct call.
- `Request.do` -> `req.on_redirect(...)` (request.v:323): a function-pointer field.
- `net.TCPDialer.dial` (net/tcp.c.v:17) and `SOCKS5Dialer.dial` (socks/socks5.v:68):
  reached only through the `net.Dialer` interface, and not from `http.get`.
- `http.dial_tcp_via_proxy` (http_proxy.v:23): calls `HttpProxy.dial`, but only websocket
  (websocket/io.v:79) calls it; not on a route from `http.get`.
- `mbedtls.SSLConn.dial` (mbedtls/ssl_connection.c.v:827): does not call `net.dial_tcp`.
- `Transport.h3_round_trip` (transport.v:636): dials QUIC over UDP (`quic.dial`,
  h3_udp_dial_d_http3.v:116), with no fallback to TCP.
- `vschannel_ssl_do` (backend.c.v:11) and its callees: connect through SChannel in C
  (`C.vschannel_h2_connect`), not `net.dial_tcp`.
- Commented-out lines in `HttpProxy.http_do` (http_proxy.v:164-167).
- Other `net.dial_tcp` callers not reachable from `http.get`: ftp, pop, imap, smtp,
  websocket, db/redis.
- A route that repeats a function (for example a second pass through
  `tls_fresh_round_trip`) is not simple and does not count.

## Q4. Calls of `net.TcpConn.write_string` in vlib

6 items. The method is declared at net/tcp.c.v:322 (`pub fn (mut c TcpConn) write_string`).

1. net/http/http_proxy.v:176, in `HttpProxy.http_do`: `client.write_string(s)`.
   `client` comes from `pr.dial(...)` (http_proxy.v:173), which returns `!&net.TcpConn`
   (http_proxy.v:203).
2. net/pop/pop.v:138, in `pop.Client.send_cmd`: `c.conn.write_string(wire)`.
   Field `pop.Client.conn` is `&net.TcpConn` (pop/pop.v:22).
3. veb/veb.v:1103, in `veb.send_string`: `conn.write_string(s)`.
   Parameter `mut conn net.TcpConn` (veb.v:1093).
4. veb/veb_livereload.v:144, in `LivereloadHub.add`: `c.write_string(head)`.
   `c := unsafe { conn }` where parameter `conn &net.TcpConn` (veb_livereload.v:130).
5. veb/veb_livereload.v:166, in `LivereloadHub.send`: `c.write_string(payload)`.
   `c` comes from `for conn in hub.conns`, field `conns []&net.TcpConn` (veb_livereload.v:60).
6. veb/veb_livereload.v:289, in `Context.handle_veb_livereload_events`: `conn.write_string(...)`.
   `conn := ctx.conn`, field `veb.Context.conn &net.TcpConn` (veb/context.v:86).

Not items:
- net/http/backend.c.v:125 (`do_request`) and :147 (`h1_exchange_ssl`):
  `ssl_conn.write_string`, receiver `ssl.SSLConn`, not TcpConn.
- `strings.Builder` receivers (`sb`, `b`, `out`, `res`, `builder`, `err_builder` in
  net/tcp.c.v:159-165, and the like): about 1,470 sites in vlib.
- net/urllib/urllib.v:225-236 `t.write_string`: a `strings.Builder`.
- picohttpparser/response.c.v:26-109 `r.write_string`: `picohttpparser.Response`'s own method.
- os/file.c.v:261 and veb/assets/assets.v:265: `os.File.write_string`.
- veb/sse/sse.v:55, :82 and net/smtp/smtp.v:277: TcpConn receivers, but they call `write`,
  not `write_string`.
- regex/regex_util.v:492, :565: commented out (and a Builder).
- Test files, for example net/error_ownership_test.v:23, net/ftp/ftp_internal_test.v:31,
  net/ssl/ssl_read_all_test.v:27, net/udp_test.v:69 (a UdpConn).
- The declaration at net/tcp.c.v:322 itself.

## Q5. Functions `os.cp_all` (os/os.v:71) calls directly

12 items, each with its call lines:

1. `real_path`: 72, 73
2. `exists`: 74, 85, 95, 106
3. `error` (builtin): 75, 89, 99
4. `is_dir`: 78, 80, 98, 105
5. `file_name`: 79
6. `join_path_single`: 81, 103, 104
7. `rm`: 87
8. `cp`: 92
9. `mkdir`: 96, 107
10. `ls`: 101
11. `cp_all` (itself): 110
12. `rmdir`: 111

Not items: `return err` at 111 is no call.

## Q6. Method calls in `http.Server.listen_and_serve` (net/http/server.v:73)

9 items: line, receiver type, declaration.

1. 79 `s.listen_and_serve_tls()`: `Server`, net/http/server_tls_notd_use_openssl.v:46
   (the `-d use_openssl` one is server_tls_d_use_openssl.v:11; either is right)
2. 92 `s.listener.addr()`: `net.TcpListener`, net/tcp.c.v:661
3. 96 `l.str()`: `net.Addr`, net/address.c.v:305
4. 98 `s.listener.set_accept_timeout(...)`: `net.TcpListener`, net/tcp.c.v:649
5. 119 `s.listener.accept_only()`: `net.TcpListener`, net/tcp.c.v:593
6. 120 `err.code()`: `IError`, builtin/chan_option_result.v:38
7. 128 `conn.set_read_timeout(...)`: `net.TcpConn`, net/tcp.c.v:348
8. 129 `conn.set_write_timeout(...)`: `net.TcpConn`, net/tcp.c.v:377
9. 133 `s.close()`: `Server`, net/http/server.v:149

Not items: `s.on_running(mut s)` (116) and `s.on_stopped(mut s)` (142) call
function-typed fields; `net.listen_tcp` (87) and `time.sleep` (113, 125) are module
functions.

## Q7. Errors in vlib/net/http whose message mentions a redirect

3 items:

1. net/http/request.v:293: `maximum number of redirects reached`
2. net/http/request.v:314: `invalid URL in redirect`
3. net/http/request.v:319: `invalid URL in redirect`

## Q8. Functions in vlib that call `net.dial_tcp` directly

13 items:

1. `net.TCPDialer.dial`: net/tcp.c.v:17
2. `ftp.FTP.connect`: net/ftp/ftp.v:113
3. `ftp.new_dtp`: net/ftp/ftp.v:204
4. `websocket.Client.dial_socket`: net/websocket/io.v:77
5. `pop.dial`: net/pop/pop.v:54
6. `imap.Client.connect`: net/imap/imap.v:161
7. `http.Request.http_do`: net/http/request.v:531
8. `http.HttpProxy.connect_tcp`: net/http/http_proxy.v:138
9. `http.Transport.dial_h1_tcp`: net/http/transport.v:704
10. `socks.socks5_dial`: net/socks/socks5.v:20
11. `smtp.Client.reconnect`: net/smtp/smtp.v:127
12. `openssl.SSLConn.dial`: net/openssl/ssl_connection.c.v:336
13. `redis.dial_connection`: db/redis/dial.c.v:8

## Changes at ffc38ada48

Re-keyed by the grader of the 2026-10-22 round, at the source. 73 commits after
417c85b1ec. The item count stays 69; to grade at ffc38ada48 or later, apply these.

- **Q2: the premise no longer holds.** vlang/v#30945 ("os: set File.fd in
  open_append", 0cf85b0310) made `open_append` return
  `File{ cfile: file.cfile, fd: fileno(file.cfile), is_opened: true }`
  (os/os.c.v:1262-1266, `fd` at :1264). So on Unix `fd` is the real descriptor.
  - Points 1 to 3 still hold at the same lines.
  - Point 4 is replaced: the function now returns a new File with
    `fd: fileno(...)` (os/os.c.v:1262-1266). A full answer says the premise is false
    and why.
  - Point 5's lines still hold, but no longer as a contrast: `open_append` now sets
    `fd` as `open` and `create` do. Point 6, the consequence for stdin, no longer applies.
  - os/os_fd_test.v:102 tests the fix.
- **Q3: the same routes, with these lines moved.**
  - net/http/transport.v moved: 655 → 742 (`h2_round_trip`), 668 → 755
    (`tls_fresh_round_trip`), 670 → 757 (`dial_h1_tcp`), 704 → 791
    (`net.dial_tcp`), 720 → 807 (`vschannel_fresh_round_trip`), 722 → 809
    (`tls_fresh_round_trip_ssl`), 735 → 822 (`ssl_conn.dial`).
  - net/http/transport_h2.v moved: 468 → 469, 483 → 484, 494 → 495.
  - Every other line of the routes is unchanged.
  - The not-item `Transport.h3_round_trip` is now called at net/http/transport.v:723, not 636.
- **Q8:** item 9, `http.Transport.dial_h1_tcp`, moved to net/http/transport.v:791. No
  new callers outside tests.
- **Q1:** the 15 items are unchanged. One not-item moved: the free-function call in
  `StreamListener.wait_for_accept` is now at net/unix/stream.c.v:346.
- **Q4 to Q7:** unchanged.
- **Q6, in the key itself:** `s.on_stopped(mut s)` at net/http/server.v:142 is in
  `Server.stop`, not in `listen_and_serve`, so it isn't one of Q6's not-items. It
  changes no score.
