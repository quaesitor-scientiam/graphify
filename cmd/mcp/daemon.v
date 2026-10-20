module main

// One daemon answers the tool calls of every session's server, so that the V
// tree's graph, and its index, are read once and not once a session: each server is
// started by its client and relays the tool calls it gets to the daemon, over a
// Unix socket in the user's cache directory, as one line of JSON each way. The
// first server to find no daemon starts one. The daemon keeps an App for each
// session's directory, which share the base graphs (BaseCache), and goes away when
// no server has been connected to it for daemon_idle(), or once none is when
// its binary has been rebuilt; the socket is named after the binary, so a server
// built since starts a daemon of its own. On Windows the daemon is a copy of the
// binary beside its socket, since a running .exe can't be rebuilt, started detached
// (daemon_windows.c.v). GRAPHIFY_MCP_DAEMON=0 has each server read its graphs itself.
import os
import net.unix
import sync
import time
import x.json2
import crypto.sha256

// daemon_idle is how many seconds a daemon, and an App no session asks for, outlive
// their last use: GRAPHIFY_DAEMON_IDLE, or 15 minutes.
fn daemon_idle() i64 {
	n := os.getenv('GRAPHIFY_DAEMON_IDLE').i64()
	return if n > 0 { n } else { 15 * 60 }
}

// daemon_enabled reports whether the server relays to a daemon.
fn daemon_enabled() bool {
	return os.getenv('GRAPHIFY_MCP_DAEMON') != '0'
}

// server_exe is the server's binary: this one, or for a daemon running from a copy of
// it (on Windows), the one the copy was made of, which the server that started the
// daemon names in GRAPHIFY_MCP_EXE. The daemon is named after it, watches it for a
// rebuild, and finds the graphify CLI beside it.
fn server_exe() string {
	exe := os.getenv('GRAPHIFY_MCP_EXE')
	return if exe != '' { exe } else { os.executable() }
}

// daemon_dir is where the daemon's socket and log are: GRAPHIFY_DAEMON_DIR, or the
// user's cache directory; a directory of the user's under the system's temporary
// one when a socket's path there would be longer than a Unix socket's may be.
fn daemon_dir() string {
	dir := os.getenv('GRAPHIFY_DAEMON_DIR')
	wanted := if dir != '' { dir } else { os.join_path(os.cache_dir(), 'graphify') }
	// `/mcp-` + 16 + `.sock`, within the sun_path of 104 bytes (108 on Linux), or of
	// 108 on Windows, with its terminating zero
	if wanted.len + 26 <= max_socket_path {
		return wanted
	}
	$if windows {
		return os.join_path(os.temp_dir(), 'graphify')
	}
	return os.join_path('/tmp', 'graphify-${os.getuid()}')
}

const max_socket_path = $if windows { 107 } $else { 103 }

// daemon_name names the daemon for this server's binary and what it serves, so that
// servers started alike share one, and a server rebuilt since starts its own.
fn daemon_name(cfg Config) string {
	exe := server_exe()
	key := [file_stamp(exe), os.real_path(cfg.graph_path), cfg.projects_dir, cfg.src_dir].join('\n')
	return 'mcp-${sha256.hexhash(key)[..16]}'
}

// how long a server waits for the daemon's answer: longer than the daemon takes to
// read the V tree's graph, or to layer a project on it, for the first call
const answer_timeout = 10 * time.minute

// connect_daemon connects to the daemon for `cfg`, starting one when there is none,
// and waits for it to listen; nil when none can be had.
fn connect_daemon(cfg Config) &unix.StreamConn {
	dir := daemon_dir()
	os.mkdir_all(dir) or { return unsafe { nil } }
	socket := os.join_path(dir, daemon_name(cfg) + '.sock')
	if mut conn := unix.connect_stream(socket) {
		conn.set_read_timeout(answer_timeout)
		return conn
	}
	start_daemon(cfg) or {
		eprintln('graphify-mcp: cannot start the daemon: ${err}')
		return unsafe { nil }
	}
	// it listens before it reads a graph
	for _ in 0 .. 100 {
		time.sleep(100 * time.millisecond)
		if mut conn := unix.connect_stream(socket) {
			eprintln('graphify-mcp: started the daemon at ${socket}')
			conn.set_read_timeout(answer_timeout)
			return conn
		}
	}
	eprintln('graphify-mcp: the daemon did not listen at ${socket}')
	return unsafe { nil }
}

// start_daemon runs this server's binary as the daemon for `cfg`. Its stdio is
// pipes, not the client's: it puts its own in place of them (run_daemon). On Windows
// it runs a copy of the binary, made beside the socket and named after the daemon,
// detached (start_detached).
fn start_daemon(cfg Config) ! {
	mut args := ['--daemon', cfg.graph_path]
	if cfg.src_dir != '' {
		args << cfg.src_dir
	}
	if cfg.projects_dir != '' {
		args << ['--projects', cfg.projects_dir]
	}
	$if windows {
		exe := server_exe()
		daemon_exe := os.join_path(daemon_dir(), daemon_name(cfg) + '.exe')
		// one made for a daemon of the same build is the same binary
		if !os.exists(daemon_exe) {
			os.cp(exe, daemon_exe)!
		}
		os.setenv('GRAPHIFY_MCP_EXE', exe, true)
		start_detached(daemon_exe, args)!
		return
	}
	mut p := os.new_process(os.executable())
	p.set_args(args)
	p.set_redirect_stdio()
	p.run()
	if p.status == .exited && p.code != 0 {
		return error('exit code ${p.code}')
	}
}

// ask relays the tool call to the daemon and reads its answer; none when the
// daemon has gone.
fn (mut s Session) ask(name string, arguments string) ?(string, bool) {
	mut conn := s.remote
	request := json2.encode({
		'dir':       json2.Any(s.here)
		'name':      json2.Any(name)
		'arguments': json2.Any(arguments)
	})
	conn.write_string(request + '\n') or { return none }
	line := read_line(mut conn, mut s.pending) or { return none }
	answer := (json2.decode[json2.Any](line) or { return none }).as_map()
	text := (answer['text'] or { return none }).str()
	is_error := (answer['is_error'] or { json2.Any(false) }).bool()
	return text, is_error
}

// read_line reads from `conn` up to a newline, keeping what it read past it in
// `pending` for the next line.
fn read_line(mut conn unix.StreamConn, mut pending []u8) !string {
	mut buf := []u8{len: 65536}
	for {
		i := pending.index(`\n`)
		if i >= 0 {
			line := pending[..i].bytestr()
			pending = pending[i + 1..].clone()
			return line
		}
		n := conn.read(mut buf)!
		if n <= 0 {
			return error('closed')
		}
		pending << buf[..n]
	}
	return error('closed')
}

// Daemon is the state of the daemon: an App for each session's directory, the base
// graphs they share, and the servers connected. `mu` lets one tool call at a time
// use them.
@[heap]
struct Daemon {
	cfg Config
mut:
	mu      &sync.Mutex = sync.new_mutex()
	apps    map[string]&App
	bases   &BaseCache = &BaseCache{}
	conns   int
	used_at i64
}

// run_daemon is the daemon: it leaves its client's session, so that it outlives the
// server that started it, listens, reads the base graph, and answers the servers
// that connect until none has for daemon_idle().
fn run_daemon(cfg Config) {
	dir := daemon_dir()
	os.mkdir_all(dir) or { exit(1) }
	name := daemon_name(cfg)
	detach(os.join_path(dir, name + '.log'))
	socket := os.join_path(dir, name + '.sock')
	// another started at the same time
	if mut other := unix.connect_stream(socket) {
		other.close() or {}
		exit(0)
	}
	os.rm(socket) or {}
	remove_dead_daemons(dir, name)
	mut listener := unix.listen_stream(socket) or {
		eprintln('graphify-mcp daemon: cannot listen at ${socket}: ${err}')
		exit(1)
	}
	eprintln('graphify-mcp daemon: listening at ${socket}')
	exe := server_exe()
	exe_stamp := file_stamp(exe)
	mut d := &Daemon{
		cfg:     cfg
		used_at: time.now().unix()
	}
	// the base graph is read while the first server waits for its answer
	d.mu.lock()
	d.bases.get(cfg.graph_path, cfg.src_dir) or {
		eprintln('graphify-mcp daemon: cannot load ${cfg.graph_path}: ${err}')
	}
	gc_collect()
	d.mu.unlock()
	// look whether it is done at least once a minute
	listener.set_accept_timeout(time.second * if daemon_idle() < 60 {
		daemon_idle()
	} else {
		60
	})
	for {
		// accept blocks with no timeout of its own: wait_for_accept has one
		listener.wait_for_accept() or {
			if d.done(exe, exe_stamp) {
				break
			}
			continue
		}
		mut conn := listener.accept() or { continue }
		// a server is quiet between its client's tool calls, for as long as it is
		conn.set_read_timeout(time.infinite)
		d.mu.lock()
		d.conns++
		d.used_at = time.now().unix()
		d.mu.unlock()
		spawn d.serve_conn(mut conn)
	}
	listener.close() or {}
	os.rm(socket) or {}
	eprintln('graphify-mcp daemon: done')
}

// orphan_age is how long a daemon's log has to have gone unwritten for a daemon with no
// socket to count as gone, and not as one that has made its log and is about to listen.
const orphan_age = 60

// remove_dead_daemons removes the socket, the log, and on Windows the copy of the
// binary, of each daemon in `dir` that no longer listens, other than `own`, the one
// doing the clearing, which has a log and no socket yet. Two kinds are gone: a daemon
// killed, which leaves its socket with nothing listening at it, and a daemon that went
// down on its own, which removes only its socket and leaves the rest: that one counts
// once its log is `orphan_age` old, and when it has a log at all (a copy made for a
// daemon about to start has none). A copy still running can't be removed, and stays.
fn remove_dead_daemons(dir string, own string) {
	remove_gone_daemons(dir, own, orphan_age)
}

// remove_gone_daemons is remove_dead_daemons with the age of log, in seconds, that a
// daemon with no socket needs to count as gone.
fn remove_gone_daemons(dir string, own string, min_age i64) {
	mut names := map[string]bool{}
	for file in os.ls(dir) or { return } {
		if is_daemon_file(file) {
			names[file.all_before_last('.')] = true
		}
	}
	now := time.now().unix()
	for name, _ in names {
		if name == own {
			continue
		}
		base := os.join_path(dir, name)
		socket := base + '.sock'
		log := base + '.log'
		if os.exists(socket) {
			if mut conn := unix.connect_stream(socket) {
				conn.close() or {}
				continue
			}
		} else if !os.exists(log) || now - os.file_last_mod_unix(log) < min_age {
			continue
		}
		os.rm(socket) or {}
		os.rm(log) or {}
		os.rm(base + '.exe') or {}
	}
}

// is_daemon_file reports whether `file` is named as a daemon's: what daemon_name gives
// (`mcp-` and 16 hex digits) and `.sock`, `.log` or `.exe`. The directory can be one
// other things write to (GRAPHIFY_DAEMON_DIR), with files of their own named `mcp-...`.
fn is_daemon_file(file string) bool {
	// `mcp-` is 4 bytes, the 16 digits end at 20, and the extension follows a dot
	if file.len < 22 || !file.starts_with('mcp-') || file[20] != `.` {
		return false
	}
	for c in file[4..20] {
		if !(c.is_digit() || (c >= `a` && c <= `f`)) {
			return false
		}
	}
	return file[21..] in ['sock', 'log', 'exe']
}

// done drops each App no session has asked for in daemon_idle(), and reports whether
// the daemon is done: no server connected, and none for daemon_idle(), or the binary
// rebuilt since it started.
fn (mut d Daemon) done(exe string, exe_stamp string) bool {
	d.mu.lock()
	defer {
		d.mu.unlock()
	}
	now := time.now().unix()
	idle := daemon_idle()
	mut used := {
		d.cfg.graph_path: true
	}
	for dir, app in d.apps {
		if now - app.used_at >= idle {
			d.apps.delete(dir)
			continue
		}
		used[app.base_path] = true
	}
	d.bases.keep(used)
	gc_collect()
	if d.conns > 0 {
		return false
	}
	return now - d.used_at >= idle || file_stamp(exe) != exe_stamp
}

// serve_conn answers the tool calls one server relays, one line each, until it
// disconnects.
fn (mut d Daemon) serve_conn(mut conn unix.StreamConn) {
	mut pending := []u8{}
	for {
		line := read_line(mut conn, mut pending) or { break }
		text, is_error := d.answer(line)
		answer := json2.encode({
			'text':     json2.Any(text)
			'is_error': json2.Any(is_error)
		})
		conn.write_string(answer + '\n') or { break }
	}
	conn.close() or {}
	d.mu.lock()
	d.conns--
	d.used_at = time.now().unix()
	d.mu.unlock()
}

// answer runs the tool call in `line` on the App of the session's directory it
// names, made when it is the first call from there.
fn (mut d Daemon) answer(line string) (string, bool) {
	request := (json2.decode[json2.Any](line) or { return 'bad request', true }).as_map()
	dir := (request['dir'] or { json2.Any('') }).str()
	name := (request['name'] or { json2.Any('') }).str()
	args := (request['arguments'] or { json2.Any('{}') }).str()
	d.mu.lock()
	defer {
		d.mu.unlock()
	}
	key := if dir == '' { '' } else { os.real_path(dir) }
	mut app := d.apps[key] or {
		eprintln('graphify-mcp daemon: a session in ${dir}')
		a := new_app(d.cfg, dir, d.bases) or { return 'graphify-mcp: ${err}', true }
		d.apps[key] = a
		a
	}
	return app.answer(name, args)
}

fn C.setsid() int

// detach puts the daemon in a session of its own, so that it outlives its client's,
// with its output going to `log`, and closes what it got from the server that
// started it: a copy of the client's stdin kept open would keep that server from
// seeing its client go.
fn detach(log string) {
	$if windows {
		detach_windows(log)
	} $else {
		C.setsid()
		for fd in 3 .. 256 {
			os.fd_close(fd)
		}
		// open_file sets a File's fd; os.open and open_append leave it 0
		null := os.open_file('/dev/null', 'r') or { return }
		os.fd_dup2(null.fd, 0)
		out := os.open_file(log, 'a') or { return }
		os.fd_dup2(out.fd, 1)
		os.fd_dup2(out.fd, 2)
	}
}

// win_quote quotes one argument of a Windows command line so that the program's
// argv has it as it is: in quotes when it has a space, a tab or a quote, with a
// quote and the backslashes before one, or before the closing quote, escaped.
fn win_quote(arg string) string {
	if arg != '' && !arg.contains_any(' \t"') {
		return arg
	}
	mut out := []u8{cap: arg.len + 2}
	out << `"`
	mut slashes := 0
	for c in arg {
		if c == `\\` {
			slashes++
			continue
		}
		if c == `"` {
			for _ in 0 .. slashes * 2 + 1 {
				out << `\\`
			}
		} else {
			for _ in 0 .. slashes {
				out << `\\`
			}
		}
		slashes = 0
		out << c
	}
	for _ in 0 .. slashes * 2 {
		out << `\\`
	}
	out << `"`
	return out.bytestr()
}
